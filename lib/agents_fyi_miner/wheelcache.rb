# frozen_string_literal: true

require "fileutils"
require "pathname"

module AgentsFyiMiner
  # The shared wheel cache, and the bound on how much of the disk it may take.
  #
  # `pip_cache` is mounted into all three clients, because they install the same releases and a
  # wheel is an artifact PyPI published a hash for — so a copy of it is not a claim about
  # anything, and the three of them between them fetch each distinct wheel once. That is the
  # whole of its value, and this module is the other half of it: a cache with no bound is a slow
  # disk-full outage, which is the failure the environment cache already has a budget to
  # prevent.
  #
  # Why it is pruned here rather than left to grow: measured on this deployment, the cache went
  # from empty to 1.7 GB in about forty minutes of ordinary mining, and it grows with every
  # *distinct* wheel the corpus reaches — which, across a thousand packages and their releases,
  # is tens of thousands. A cache that grows with the work is a cache that eventually fills the
  # disk, and the disk is shared with the database's volume.
  #
  # The failure mode is why this is safe to do without pip's help. Deleting a cache entry can
  # only cause the next install to re-download it — verified against a real cache, not assumed:
  # an entry was removed and the packages installed again, which succeeded from a single
  # re-download. pip treats its cache as a cache. Nothing here can leave an install with the
  # wrong bytes, which is the asymmetry that makes this different from pruning an *environment*:
  # an environment is executed in, so deleting one under a running probe would produce a
  # fabricated finding, and that is why `Envs.prune` runs between cycles and this could honestly
  # run at any time.
  module WheelCache
    # How much disk the wheels may take.
    #
    # Larger than the environment budget on purpose, and for a reason rather than a feeling: an
    # environment is a *working set* — it exists to be the thing a probe is running in, and one
    # that has been probed is disposable once its finding is filed. A wheel cache is the
    # opposite: its entries stay useful for as long as the corpus might install that release
    # again, which includes every verifier re-deriving a report, and re-fetching is what the
    # budget is trying to avoid. So this is sized to hold what the corpus has actually installed
    # rather than a cycle's worth of it.
    WHEEL_BUDGET_BYTES = 12 * 1024**3

    # How long an entry is left alone whatever the budget says.
    #
    # A cache entry being written right now is one another process is downloading into; deleting
    # it mid-write costs that process its download for no reason. Short, unlike the environment's
    # equivalent, because there is nothing here that a deletion corrupts — only work that has to
    # be repeated.
    WHEEL_QUIET_SECONDS = 300

    # Where the wheels are, given the home a client was told to work in.
    #
    # `PIP_CACHE_DIR` when it is set, because that is the variable pip itself reads and the
    # image sets it — the two would otherwise be free to disagree, and the way that shows up is
    # a prune that measures one directory while pip fills another, which reports success and
    # bounds nothing. Blank is unset, which is the rule `Settings.text` states on the service
    # side and the reason `docker-compose.yml` forwards every knob as `${VAR:-}`: a variable the
    # compose file forwards but nobody set arrives as an *empty string*, and `Pathname.new("")`
    # is the current directory rather than nothing.
    #
    # Otherwise the sibling of this client's home, which is where pip puts it by default anyway
    # (`~/.cache/pip` beside `~/.cache/agents-fyi-miner`). Derived rather than repeated so the
    # three clients cannot each acquire their own idea of it: they share one cache on purpose,
    # and a per-client constant is how that stops being true.
    def self.cache_dir(home)
      configured = ENV["PIP_CACHE_DIR"].to_s
      configured.empty? ? home.parent + "pip" : Pathname.new(configured)
    end

    # How much disk the cache occupies, in the units the disk spent.
    #
    # Blocks rather than file lengths, for the reason `Envs.directory_size` documents: a wheel is
    # one large file, but pip's cache also holds thousands of small index responses and header
    # files, and those round up to a block each.
    def self.size(cache)
      entries(cache).sum { |path| entry_size(path) }
    end

    # The cache's own entries, each of which is deleted whole or not at all.
    #
    # pip's layout is a directory per cache key, one level under a fan-out directory
    # (`http-v2/<a>/<hash>/…`) for downloaded responses and one for wheels it built itself. The
    # unit that can be removed safely is the innermost directory holding the files, so that is
    # what this finds rather than hard-coding those two names: a layout pip changes would
    # otherwise be a prune that deleted nothing, or worse, deleted a directory that is not an
    # entry.
    #
    # A leaf directory with no files in it is not an entry either — pip leaves empty directories
    # behind after a partial write, and counting them is counting nothing.
    #
    # Walked by hand rather than with `Pathname#glob`, because a glob's `*` does not descend into
    # the way pip names things the way `rglob("*")` did: the recursion here visits every child
    # including a dotted one, which is the behaviour the bound was measured with.
    def self.entries(cache)
      return [] unless cache.exist?

      found = []
      queue = children_of(cache).select { |child| File.directory?(child) }
      until queue.empty?
        current = queue.shift
        children = children_of(current)
        nested = children.select { |child| File.directory?(child) }
        if nested.empty?
          found << current if children.any? { |child| File.file?(child) }
        else
          queue.concat(nested)
        end
      end
      found
    end

    # The disk one cache entry occupies.
    #
    # `st_blocks * 512` and not `st_size`, and the difference is a measurement rather than a
    # preference: summing file lengths under-reported one client's environment cache by about
    # 10% — 9.1 GB of environments summed to 8.2 GB — which put an 8 GiB budget *just* satisfied
    # and left the cache over its bound indefinitely while `prune` returned `(0, 0)`. The number
    # a limit is checked against has to be the quantity the resource is spent in.
    def self.entry_size(path)
      total = 0
      each_descendant(path) do |entry|
        begin
          next if File.lstat(entry).symlink?
        rescue SystemCallError
          next
        end

        info = begin
          File.stat(entry)
        rescue SystemCallError
          next
        end
        total += info.blocks * 512
      end
      total
    end

    # Delete least-recently-used cache entries until the cache fits the budget.
    #
    # Returns (entries removed, bytes freed), so a cycle can say what it did rather than silently
    # making room — the same contract as `Envs.prune`, and reported for the same reason: a bound
    # that acts invisibly is a bound nobody can tell is working.
    #
    # Least-recently-used by directory mtime, which pip touches when it writes an entry, so
    # "oldest" means "longest since anything looked at it". An entry only in the cache because it
    # was fetched once and never reused is exactly the one worth dropping.
    def self.prune(cache, budget: WHEEL_BUDGET_BYTES, quiet: WHEEL_QUIET_SECONDS)
      return [0, 0] unless cache.exist?

      measured = []
      total = 0
      entries(cache).each do |path|
        size_of = entry_size(path)
        total += size_of
        modified = begin
          path.stat.mtime.to_f
        rescue SystemCallError
          next
        end
        measured << [modified, path, size_of]
      end
      return [0, 0] if total <= budget

      now = Time.now.to_f
      removed = 0
      freed = 0
      measured.sort_by { |modified, _path, _size| modified }.each do |modified, path, size_of|
        break if total - freed <= budget
        next if now - modified < quiet

        begin
          # `rm_rf` rather than `rmtree`: it is the one that carries `ignore_errors`, and an
          # entry another process removed a moment ago is a deletion that has already happened
          # rather than a failure to report.
          FileUtils.rm_rf(path)
        rescue StandardError
          next
        end
        # The check is one `stat` per deletion and buys an honest number.
        next if path.exist?

        removed += 1
        freed += size_of
      end
      [removed, freed]
    end

    # The immediate children of a directory, or nothing when it cannot be read. A directory that
    # vanished under the walk — another client pruning the same shared cache — is not an error.
    def self.children_of(dir)
      Dir.children(dir).map { |name| dir + name }
    rescue SystemCallError
      []
    end

    # Every path *under* this one, depth-first — the path itself is not one of them, which is
    # what `rglob("*")` did and what makes the arithmetic match: a directory's own inode is not
    # a byte an entry spent on its contents.
    def self.each_descendant(path, &block)
      stack = children_of(path)
      until stack.empty?
        current = stack.pop
        yield current
        children_of(current).each do |child|
          # Descended only where it is not a link: a symlink into another directory would
          # otherwise be counted twice, once here and once where it points.
          begin
            next if File.lstat(child).symlink?
          rescue SystemCallError
            next
          end

          stack << child
        end
      end
    end
  end
end
