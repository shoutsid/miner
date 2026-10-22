# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"

require_relative "bandwidth"
require_relative "errors"
require_relative "machine"

module AgentsFyiMiner
  # Gem environments, and running Ruby inside them.
  #
  # Every claim this miner makes is an executed claim, so this module is the foundation: if it
  # reports a gem as loaded when it is not, or a failure that did not happen, every finding
  # downstream is a fabrication with a citation.
  #
  # **The install is `gem install --install-dir`.** There is no virtualenv, so the isolation is
  # `GEM_HOME` and `GEM_PATH` pointing at one directory, and dependencies land in that same
  # directory by default — which is what makes an environment self-contained. A probe *must* set
  # both: `ruby -I <lib>` loads a file without activating its gemspec, so dependencies are never
  # resolved and `Gem.loaded_specs` is nil.
  #
  # **A half-installed gem exists.** A native build that fails — the slim image ships no
  # compiler — leaves the payload in `gems/` and **no** spec in `specifications/`, and pip's
  # equivalent trap is why `envs.installed` checks for a `.dist-info` rather than an interpreter.
  # `installed?` here wants the spec file for exactly this `package-version`, because "the
  # directory is there" is what a failed build leaves behind.
  #
  # **A probe that could not be made is not evidence.** `Gem::MissingSpecError`
  # (`Could not find 'dep' (…) among N total gem(s)`) is a require that never reached the gem —
  # the same third answer `envs.unreached` exists for, and it must not be read as "the name is
  # gone". `cannot load such file -- x (LoadError)` is the other half: the gem loaded and the
  # *file* is not there.
  #
  # The measured cost of that is one request-free scan per environment: 0.006 s for `faraday`,
  # 108 modules for `rspec-core`. It also has a measured blind spot — a C extension defines
  # its methods in C, so `json` reports zero modules and zero methods under a
  # `source_location` filter, and the fallback below is stated rather than hidden.
  module RubyEnvs
    # The floor on how long a gem install may take, and what a probe gets when nothing says
    # otherwise. It is generous on purpose: an install killed at the floor has to be bought
    # again, so the cost of a floor that is too low is a corpus that never gets an answer,
    # while the cost of one that is too high is bounded by the ceiling below.
    INSTALL_TIMEOUT = 600
    RUN_TIMEOUT = 120

    # What an install gets at most, and what a retry multiplies its deadline by.
    #
    # The PyPI side prices its deadline from the release's own bytes; RubyGems does not publish a
    # size in the versions endpoint at all — measured, the key is absent from the payload and
    # absent from `/info/<gem>` — so there is nothing to price from and a flat ceiling is the
    # honest rule. The retry factor stays because the evidence it encodes is the same: an install
    # that ran out of time had the environment already on its way, so the second attempt gets
    # more room.
    MAX_INSTALL_TIMEOUT = 3600
    INSTALL_RETRY_FACTOR = 2

    # What the gem's own directory is called under the cache root, and the scratch directory its
    # installs unpack into.
    #
    # The scratch directory is not a detail: `/tmp` in this container is a tmpfs, and a gem's
    # install unpacks the `.gem` there before moving it into place. The PyPI side measured 4.1 GB
    # of tmpfs in thirty-five minutes from the same habit, which is why `TMPDIR` is redirected
    # rather than left alone.
    ENVS_DIR = "rubyenvs"
    SCRATCH_DIR = "rubyenvs-scratch"

    # A gem name or method name that is safe to build an expression out of. Both halves are
    # checked on this side as well as in the script that produced them, because what they are
    # interpolated into is a Ruby `eval`.
    OWNER = /\A[A-Za-z_][A-Za-z0-9_:]*\z/
    METHOD_NAME = /\A[a-z_][A-Za-z0-9_]*[?!]?\z/
    CONSTANT = /\A[A-Z][A-Za-z0-9_:]*\z/
    # A reference a caller could write: a constant path, or one of those with one method on the
    # end. What the move search is allowed to hand back.
    REFERENCE = /\A[A-Za-z_][A-Za-z0-9_:]*(?:[.#][a-z_][A-Za-z0-9_]*[?!]?)?\z/

    # The marker a signal-killed probe carries. A process the kernel ended reports a *negative*
    # return code and usually writes nothing, so its output has to name the kill or `resolves?` —
    # which is `output.strip.empty?` — reads the empty string as "the reference resolved". It is
    # listed in `UNREACHED` below, which is the third answer: a probe that did not run proves
    # nothing.
    KILLED_MARKER = "KILLED BY SIGNAL"

    # How Ruby says a name is not there. Three spellings, and the version matters: Ruby 3.3 prints
    # ``undefined method `x' for``, 3.4 prints `undefined method 'x'`.
    REFUSED_SYMBOL = ["undefined method", "uninitialized constant", "private method"].freeze

    # What a probe says when the release never got to answer for itself. Two texts, and they are
    # a documented distinction rather than one bucket: a dependency that is missing
    # (`Gem::MissingSpecError`, `Could not find '<dep>' … among N total gem(s)`) means the
    # environment is unusable, while a `LoadError` for a path means the gem loaded and the file
    # is not in it.
    UNREACHED = [
      "TIMEOUT",
      # A process the kernel ended exits negative and usually writes nothing; the marker is what
      # stops that empty output reading as a resolved reference.
      KILLED_MARKER,
      "Gem::MissingSpecError",
      "Could not find '",
      "LoadError",
      "Errno::ENOENT",
      "Errno::ENETUNREACH",
      "command not found"
    ].freeze

    # The prefixes `gem` uses to announce a failure, which is how the reason is found without a
    # list of its messages. `gem` prints one line per dependency that installed cleanly, so the
    # head of a failed install is news that other things worked, and it ends with paperwork
    # rather than the reason — `Results logged to …`. The lines that begin with one of these are
    # the announcements in between, and they are captured from real runs rather than imagined:
    # `ERROR: Failed to build gem native extension.`

    # One installed gem release, and how to run code against it.
    Env = Data.define(:package, :version, :root, :require_path) do
      # What `require` needs, which is not always the gem name: `rspec-core` is required as
      # `rspec/core`. The caller resolves it from the gemspec.
      def self.of(package:, version:, root:, require_path: "")
        new(package: package, version: version, root: root,
          require_path: require_path.to_s.empty? ? package.tr("-", "/") : require_path)
      end

      def gem_home = root.to_s

      # Run one probe against this environment: `env.run(["--flag"], suffix: "x")`.
      #
      # A delegation and not a second path — `RubyEnvs.run_probe` is the one place a child is
      # started, and this exists because a caller holding an environment asking *it* to run is
      # the shape the PyPI side's `Env#run_script` has, and the two clients read better when they
      # read alike.
      def run(argv, source: RubyEnvs::PROBE_SOURCE, suffix: "", timeout: RubyEnvs::RUN_TIMEOUT)
        RubyEnvs.run_probe(self, source, argv, suffix: suffix, timeout: timeout)
      end
    end

    # What one child process said, in the shape the two callers need.
    #
    Result = Data.define(:status, :output, :timed_out)

    # One name a gem defines, in the shape a probe needs.
    #
    # The member is `method_name` rather than `method`, and that is not a preference: `Data`
    # generates a reader per member, so a member called `method` shadows `Object#method` on every
    # one of these values — reflection on a name that is *about* a method would be the one thing
    # such a value could not do. The wire key the inventory script prints is still `method`; this
    # is the name of the field on this side.
    Entry = Data.define(:name, :kind, :owner, :method_name, :keywords) do
      def self.of(name:, kind:, owner:, method_name: "", keywords: [])
        new(name: name, kind: kind, owner: owner, method_name: method_name.to_s, keywords: keywords)
      end

      # The Ruby expression that reaches this name, or nil when it cannot be built.
      #
      # Built here rather than emitted by the inventory script because it is the thing that
      # gets `eval`ed: the owner and the method are checked against the identifier shapes Ruby
      # allows, so a name that came back from a gem cannot put anything but a reference into
      # the probe.
      def expression
        return RubyEnvs::CONSTANT.match?(owner) ? owner : nil if kind == "constant"
        return nil unless RubyEnvs::OWNER.match?(owner) && RubyEnvs::METHOD_NAME.match?(method_name)

        kind == "instance" ? "#{owner}.allocate.#{method_name}" : "#{owner}.#{method_name}"
      end
    end

    # What one release defines, and whether it could be read at all.
    class Inventory
      attr_reader :package, :version, :entries, :error

      def initialize(package:, version:, entries:, loaded:, native: false, error: "")
        @package = package
        @version = version
        @entries = entries
        @loaded = loaded
        @native = native
        @error = error
      end

      def loaded? = @loaded

      def native? = @native

      def by_name = @entries.to_h { |entry| [entry.name, entry] }
    end

    # The directory one release is installed into.
    #
    # The gem name and version rather than a hash, because the whole point of the layout is
    # that an operator can look at it: `rake-13.1.0` says which crossing is being examined, and
    # a digest would not.
    def self.release_of(package, version) = "#{package}-#{version}"

    def self.env_root(home) = Pathname.new(home) + ENVS_DIR

    def self.scratch_dir(home) = Pathname.new(home) + SCRATCH_DIR

    # How long an install may take, doubling per attempt up to the ceiling.
    def self.install_deadline(attempt = 0, base: INSTALL_TIMEOUT)
      [base * (INSTALL_RETRY_FACTOR**attempt), MAX_INSTALL_TIMEOUT].min
    end

    # Whether a gem version is one this machine cannot install, ever.
    #
    # The strings are the ones `gem install` actually prints, captured rather than imagined: a
    # native extension with no compiler fails as `make failedNo such file or directory - make`
    # — no space, a real quirk of the message — under RubyGems' own `Failed to build gem native
    # extension`, and a version that is not on the index answers `Could not find a valid gem`.
    # Every one of those is a fact about the release and the machine, settled on the first
    # attempt and recorded against the release: twelve crossings share one release, and
    # retrying it twelve times buys nothing.
    def self.cannot_be_built?(output)
      [
        "Failed to build gem native extension",
        "make failed",
        "Could not find a valid gem",
        "You have to install development tools first",
        "ERROR:  Error installing",
        "Gem::Ext::BuildError",
        "requires a compiler"
      ].any? { |marker| output.to_s.include?(marker) }
    end

    # The lines of an installer's output that say why it failed.
    #
    # Taking the end of the output is not enough, which the live ledger showed: a record of
    # `rubyXL 3.3.33` reading `could not install …` said `Successfully installed rexml-3.4.4`,
    # because the caller cut the message to two hundred characters from the front and the head
    # is a list of what worked; and the same cut taken from the back says `Results logged to …`,
    # which is where the installer put its notes rather than why it stopped.
    #
    # So the announcements are what is kept, and `limit` of them: at most three, which fits
    # inside the two hundred characters a record stores, and one for the case where an
    # installer said nothing in the shape this recognises — a reason is worth more than an
    # empty field even when it is a guess at which line is the reason.
    #
    # The Ruby files were ported in the same round, so this delegates the moment that module
    # is loaded and otherwise carries the same rule itself. Collapsing it to the delegation
    # alone is the change to make once `envs.rb` is in the tree — two copies of a rule that
    # must agree is the thing this repository removes. The worked example, from a real `gem
    # install rubyXL -v 3.3.33`: the head is `Successfully installed rubyzip-3.7.0` and the
    # tail is `Results logged to …`, so the reason is the two `ERROR:` lines in between and
    # neither end of the output.
    def self.failure_reason(output, limit: 3)
      Envs.failure_reason(output, limit: limit)
    end

    # Remove a probe's own script, and never raise for it.
    #
    # The evidence is what the interpreter printed, not the file it ran, so the script is
    # finished with once the run has returned — and an environment is shared by two workers and
    # reused for weeks, so a file left per examination accumulates without bound. Never raising
    # matters on the failure paths this also runs on.
    def self.drop(*paths)
      paths.each { |path| FileUtils.rm_f(path) }
    end

    def self.installed?(root, package, version)
      root = Pathname.new(root)
      return false unless root.directory?

      # The specification is the test and not the directory, because a build that failed leaves
      # `gems/<gem>-<version>/` in place with nothing in `specifications/` — an environment that
      # looks installed, cannot be required, and would make every probe against it report the
      # gem as gone.
      #
      # The version is matched as a prefix so a platform build counts:
      # `nokogiri-1.16.0-x86_64-linux.gemspec` is the release `1.16.0` as this platform installs
      # it.
      prefix = "#{package}-#{version}"
      (root + "specifications").glob("*.gemspec").any? do |spec|
        stem = spec.basename.to_s.delete_suffix(".gemspec")
        stem == prefix || stem.start_with?("#{prefix}-")
      end
    end

    # The environment `gem install` runs in.
    #
    # `GEM_HOME` and `GEM_PATH` are the isolation — the gem and its dependencies go into one
    # directory and nothing sees the system's gems. `TMPDIR` is the scratch directory on the
    # volume rather than `/tmp`, which is RAM here. `HOME` is inside the install root so a gem
    # that writes to `~/.gem` writes into the throwaway tree rather than into the container's
    # home.
    def self.install_env(root, scratch)
      FileUtils.mkdir_p(scratch)
      ENV.to_h.merge(
        "GEM_HOME" => root.to_s,
        "GEM_PATH" => root.to_s,
        "GEM_SPEC_CACHE" => scratch.to_s,
        "HOME" => root.to_s,
        "TMPDIR" => scratch.to_s,
        "RUBYOPT" => ""
      )
    end

    # Run a child process, capture both streams, and stop it at the deadline.
    #
    # Two reader threads rather than reading after the wait, because a child that fills a
    # pipe buffer would otherwise deadlock against its own parent. The one place a child
    # process is started, and it is `Envs.run_captured` — one implementation for both index
    # builders rather than two that can drift.
    #
    # The shape here is this module's own, and the two facts it carries are the ones its
    # callers read: `output` is what the interpreter printed (both streams, in the order a
    # terminal would have shown them) and `timed_out` is the third answer — a probe that
    # never finished is not a reference that resolved.
    def self.capture(argv, timeout:, env: nil, cwd: nil)
      result = Envs.run_captured(argv, timeout: timeout, env: env, cwd: cwd)
      Result.new(status: result.status, output: "#{result.stdout}#{result.stderr}", timed_out: false)
    rescue Envs::TimedOut => e
      unless e.started?
        raise Errors::MinerError.new("#{argv.first} could not be run: #{e.message}",
          permanent: false)
      end

      Result.new(status: nil, output: "#{e.stdout}#{e.stderr}", timed_out: true)
    end

    # Run a command that has to succeed, and return its combined output.
    #
    # `release` travels with the failure because it is the fact the caller records: a release
    # is one thing to build whatever any single report or crossing says about it, and a caller
    # that only learns "the install failed" pays for it once per report that mentions it.
    def self.checked(argv, what:, timeout:, env:, release: "")
      result = capture(argv, timeout: timeout, env: env)
      if result.timed_out
        raise Errors::MinerError.new("#{what} timed out after #{timeout}s",
          permanent: false, release: release)
      end

      if result.status.negative?
        # A negative code is the kernel killing this process — a memory limit, or a SIGKILL on
        # redeploy — not the gem being unbuildable, so it stays transient. Settled as permanent
        # it would drop every crossing that shares this release until the interpreter moves.
        raise Errors::MinerError.new("#{what} was killed by signal #{result.status.abs}",
          permanent: false, release: release)
      end
      unless result.status.zero?
        raise Errors::MinerError.new("#{what} failed: #{failure_reason(result.output)}",
          permanent: cannot_be_built?(result.output), release: release)
      end

      result.output
    end

    # Install one gem release into its own directory, and return how to reach it.
    #
    # Deliberately slow and obvious, for the reason the PyPI side states: the gem under test is
    # hostile by design, so it is installed into a directory of its own and never imported by
    # this process.
    def self.build(package, version, home:, require_path: nil, attempt: 0, timeout: nil)
      root = env_root(home) + release_of(package, version)
      deadline = timeout.nil? ? install_deadline(attempt) : timeout
      lock_for(root).synchronize do
        # Inside the lock, because a second worker on a shared release must not see a directory
        # that exists and conclude the install finished.
        if installed?(root, package, version)
          return Env.of(package: package, version: version, root: root, require_path: require_path)
        end

        scratch = scratch_dir(home)
        environment = install_env(root, scratch)
        FileUtils.mkdir_p(root)
        begin
          Bandwidth.download_slot do
            checked(
              ["gem", "install", package, "-v", version, "--install-dir", root.to_s,
               "--no-document", "--no-user-install"],
              what: "installing #{package} #{version}",
              timeout: deadline,
              env: environment,
              # The same spelling the ledger keys a release under, so the caller's
              # release-level record and this failure name one thing.
              release: Errors.release_of(package, version)
            )
          end
        rescue StandardError
          # A build that raised leaves a directory that is not an environment, and handing it
          # out later would report the gem as missing for ever.
          FileUtils.rm_rf(root)
          raise
        end
        unless installed?(root, package, version)
          FileUtils.rm_rf(root)
          raise Errors::MinerError.new(
            "installing #{package} #{version} left no specification for it",
            permanent: true, release: Errors.release_of(package, version)
          )
        end
      end
      Env.of(package: package, version: version, root: root, require_path: require_path)
    end

    # Remove what an install that was killed could not clean up itself.
    #
    # `gem` removes its unpack directory on a normal exit and cannot on a timeout or a kill, so
    # some of every cycle's installs leave one behind. The sweep is at the top of the cycle
    # where no install is live, which is what makes the short threshold safe — the same
    # reasoning, and the same reverted "fix", as the PyPI side.
    def self.sweep_scratch(home, older_than: INSTALL_TIMEOUT * 2)
      root = scratch_dir(home)
      return [0, 0] unless root.directory?

      cutoff = Time.now.to_f - older_than
      removed = 0
      freed = 0
      root.children.each do |entry|
        begin
          next if entry.stat.mtime.to_f >= cutoff

          if entry.directory?
            size = directory_size(entry)
            FileUtils.rm_rf(entry)
          else
            # One file, so its own length is what it spent: nothing to round.
            size = entry.stat.size
            FileUtils.rm_f(entry)
          end
        rescue SystemCallError
          next
        end
        removed += 1
        freed += size
      end
      [removed, freed]
    end

    # Delete the least recently used environments until the cache fits its budget.
    #
    # Environments are the expensive thing on the volume and the one thing that must not be
    # deleted under a running probe — deleting one fabricates a finding. So this runs between
    # cycles and skips anything touched inside `quiet`.
    def self.prune(home, budget:, quiet: 900)
      root = env_root(home)
      return [0, 0] unless root.directory?

      entries = root.children.filter_map do |entry|
        next unless entry.directory?

        begin
          touched = entry.stat.mtime.to_f
        rescue SystemCallError
          next
        end
        [touched, directory_size(entry), entry]
      end
      # `st_blocks * 512` and not `st_size`: an environment is thousands of small files that the
      # filesystem rounds up to whole blocks, and a budget measured with the wrong number is not
      # a budget. The PyPI side sat over its bound for ever on exactly this.
      total = entries.sum { |_touched, size, _entry| size }
      removed = 0
      freed = 0
      now = Time.now.to_f
      entries.sort_by { |touched, _size, _entry| touched }.each do |touched, size, entry|
        break if total <= budget
        next if now - touched < quiet

        FileUtils.rm_rf(entry)
        unless entry.exist?
          # The environment is gone, so its lock is dead weight in a registry that would
          # otherwise grow with every environment this process ever built. Only when it is
          # really gone: the removal above cannot tell us, and forgetting the lock for a path
          # that survived would hand a second lock to a live path — the one thing the registry
          # exists to prevent.
          forget_lock(entry)
        end
        total -= size
        removed += 1
        freed += size
      end
      [removed, freed]
    end

    # What a directory costs the disk, in the units the disk spends.
    #
    # Blocks and not file lengths: a site-packages or gems tree is thousands of small files the
    # filesystem rounds up to a whole block, so `st_size` under-reports what was set aside —
    # measured at about 10% on a real cache, which is the difference that decides whether a
    # budget is exceeded.
    def self.directory_size(path)
      Pathname.new(path).glob("**/*").sum do |item|
        item.file? ? item.stat.blocks * 512 : 0
      rescue SystemCallError
        0
      end
    end

    # One lock per environment path, not around the function.
    #
    # Two crossings of one gem share a release (`1.0->2.0` and `2.0->3.0` both need `2.0`), so
    # the same directory is asked for by two workers at once — and two installs into one
    # directory leave an environment that is half of each, whose findings would be fabricated
    # rather than merely wrong. The same rule and the same reason as `Envs.lock_for`.
    def self.lock_for(root)
      key = root.to_s
      LOCKS_GUARD.synchronize { LOCKS[key] ||= Mutex.new }
    end

    # Drop the lock for a gem environment that no longer exists.
    #
    # The registry is keyed by path and would otherwise grow for the life of the process — one
    # entry per environment ever built, including every one `prune` has since reclaimed. Called
    # only from `prune`, which runs between cycles where nothing is live; a path that comes back
    # gets a fresh lock, the same state a new process starts in.
    def self.forget_lock(root)
      LOCKS_GUARD.synchronize { LOCKS.delete(root.to_s) }
    end

    # Run a probe inside one environment, and return everything it printed.
    #
    # The `suffix` in the script's name is this examination's identity: one worker's script must
    # never be the file another worker runs — see `Envs.probe`, where that failure is written
    # out, and the same applies here with the same consequence. The file is removed once the
    # interpreter has printed, because the evidence is the output and not the file it came from.
    def self.run_probe(env, source, argv, suffix: "", timeout: RUN_TIMEOUT)
      script = env.root + "probe-#{suffix.to_s.empty? ? 'shared' : suffix}.rb"
      script.write(source, encoding: "utf-8")
      environment = install_env(env.root, env.root + "tmp")
      begin
        result = capture(["ruby", script.to_s, *argv], timeout: timeout, env: environment)
      rescue Errors::MinerError
        drop(script)
        raise
      end
      if result.timed_out
        drop(script)
        return "TIMEOUT"
      end
      if result.status.negative?
        drop(script)
        return "#{KILLED_MARKER} #{result.status.abs}\n#{result.output}"
      end

      output = result.output
      drop(script)
      output
    end

    # --- what the interpreter's output means --------------------------------------

    # The last segment of a reference: `Foo::Bar.baz` -> `baz`, `Foo::Bar` -> `Bar`.
    #
    # Three separators, and all three are real: `::` names the owner of a constant, `.` names a
    # singleton method and `#` an instance method. Missing the `#` makes every instance
    # method's leaf `Parser#parse` instead of `parse`, which no interpreter message ever
    # matches — so the name reads as "not refused" and the removal is never reported. Also what
    # a *move* is searched for, because a name that moves keeps its leaf.
    def self.leaf_of(name)
      tail = name.to_s
      ["#", "."].each { |separator| tail = tail.rpartition(separator).last }
      tail.rpartition("::").last
    end

    # Whether the interpreter's own message names this identifier.
    #
    # A whole token rather than a substring, because Ruby writes the name in three shapes and
    # quoting is only one of them: ``undefined method `x' for`` (Ruby 3.3), `undefined method
    # 'x' for` (3.4), and `uninitialized constant Foo::Bar` — the last with no quotes at all,
    # which is why matching on quoting alone read every removed constant as "not refused".
    def self.names?(output, name)
      output.to_s.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(name)}(?![A-Za-z0-9_])/)
    end

    # Whether the interpreter refused *this name*, not merely failed.
    #
    # The name is checked as well as the message, for the reason the PyPI side states: a gem
    # that failed for an unrelated reason must not be recorded as having removed a method.
    def self.refused_symbol?(output, symbol)
      REFUSED_SYMBOL.any? { |phrase| output.to_s.include?(phrase) } &&
        names?(output, leaf_of(symbol))
    end

    # Whether the interpreter refused *this keyword*, not merely failed.
    #
    # Ruby prints one message for both shapes — `unknown keyword: :x` for a plain method and
    # `unknown keywords: :x, :y` for a `Struct` or `Data` — so the test is the phrase plus the
    # keyword, and never the phrase alone.
    def self.refused_parameter?(output, parameter)
      output.to_s.include?("unknown keyword") && output.to_s.include?(":#{parameter}")
    end

    # Whether a probe failed before the gem could answer for itself.
    def self.unreached?(output) = UNREACHED.any? { |marker| output.to_s.include?(marker) }

    # Whether a probe ran and the release answered, either way.
    def self.answers?(output) = !unreached?(output)

    # Whether a reference ran without raising anything.
    #
    # An empty run is a reference that resolved: the probe prints nothing on success and lets
    # the interpreter print whatever it raised, so the reading is taken from Ruby's own output
    # rather than from an exit code a wrapper reports.
    def self.resolves?(output) = output.to_s.strip.empty?

    # The last non-blank line, which is the exception a caller has to act on.
    def self.exception_line(output)
      lines = output.to_s.strip.split("\n").map(&:strip).reject(&:empty?)
      lines.empty? ? "" : lines.last
    end

    # The interpreter's own error text, with this machine's paths removed.
    #
    # Returned rather than rebuilt, because a report whose evidence was written by the miner is
    # a claim about a failure while this is the failure. The one edit is the environment's
    # directory: without it every traceback would carry one contributor's cache path, which no
    # reader can act on.
    def self.traceback_of(output, root: nil)
      text = output.to_s.strip
      return text if root.nil?

      text.gsub("#{root.to_s.sub(%r{/+\z}, '')}/", "")
    end

    # --- reading a gem's surface --------------------------------------------------


    # The name a stored reference spells, or nil when it is not one.
    #
    # The reverse of `Inventory`'s output, and the only place that direction is written down. A
    # report stores its subject as the release spells it — `Bundler::Graph`,
    # `Bundler::CurrentRuby#ruby_35_18?`, `Rake::Win32.normalize` — and turning that back into
    # something a probe can evaluate means deciding which of Ruby's three shapes it is, which
    # is exactly the decision `Entry#expression` already makes in the other direction. A
    # subject that no release could have defined is refused here rather than passed to an
    # interpreter.
    #
    # The separator is the type, not decoration: `#` is an instance method, `.` a singleton
    # method, and a bare `Foo::Bar` a constant. Reading a `Foo#bar` as `Foo::bar` would probe a
    # constant that never existed and report a removal that never happened — the failure this
    # function exists to make impossible.
    def self.entry_of(reference)
      text = reference.to_s
      return nil unless REFERENCE.match?(text)

      candidate =
        if text.include?("#")
          owner, _, method_name = text.partition("#")
          Entry.of(name: text, kind: "instance", owner: owner, method_name: method_name)
        elsif text.include?(".")
          owner, _, method_name = text.rpartition(".")
          Entry.of(name: text, kind: "singleton", owner: owner, method_name: method_name)
        else
          Entry.of(name: text, kind: "constant", owner: text)
        end
      candidate.expression ? candidate : nil
    end

    # Read the gem's own surface, or say why it could not be read.
    #
    # A gem that cannot be required is not an empty gem, and the two are told apart here:
    # `loaded` is false with the error kept verbatim, so a caller can record the release as
    # unexaminable instead of reporting that it defines nothing.
    def self.inventory(env, suffix: "", limit: 4000)
      output = run_probe(
        env, INVENTORY_SOURCE,
        # The gem name as well as the require path: the script asks
        # `Gem.loaded_specs[gem_name]` for the directory that counts as the gem's own, and a
        # distribution is not always what it is required as (`rspec-core` is required as
        # `rspec/core`).
        [env.package, env.require_path, limit.to_s],
        suffix: suffix, timeout: RUN_TIMEOUT
      )
      header = nil
      entries = []
      output.split("\n").each do |raw|
        line = raw.strip
        next unless line.start_with?("{")

        begin
          row = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        if row["t"] == "header"
          header = row
          next
        end
        next unless row.is_a?(Hash) && row["name"].is_a?(String)

        entries << Entry.of(
          name: row["name"], kind: row["t"].to_s, owner: row["owner"].to_s,
          method_name: row["method"].to_s, keywords: row["params"] || []
        )
      end
      if header.nil?
        # No header at all means the script never got as far as printing one: a require that
        # failed before the rescue, a missing interpreter, or a timeout. Kept as an unloaded
        # inventory with the raw output for a reason.
        return Inventory.new(
          package: env.package, version: env.version, entries: [], loaded: false,
          error: exception_line(output).empty? ? "inventory produced no output" : exception_line(output)
        )
      end

      Inventory.new(
        package: env.package, version: env.version, entries: entries,
        loaded: !!header["loaded"], native: !!header["native"],
        error: (header["error"] || "").to_s
      )
    end

    # Evaluate one reference against one release, and return what Ruby printed.
    def self.probe(env, expression, suffix: "")
      run_probe(env, PROBE_SOURCE, [env.require_path, expression],
        suffix: suffix, timeout: RUN_TIMEOUT)
    end

    # Call one method passing one keyword, and return what Ruby printed.
    def self.probe_keyword(env, expression, keyword, suffix: "")
      run_probe(env, PROBE_SOURCE, [env.require_path, expression, keyword],
        suffix: suffix, timeout: RUN_TIMEOUT)
    end

    # Where this release defines a name of that leaf, if it is anywhere.
    #
    # A location that the release answered, not a spelling it might have: the same standard the
    # PyPI side's `Envs.moved` holds, and for the same reason — the fix a report hands a caller
    # has to be something that resolved.
    def self.moved(env, kind, leaf, suffix: "")
      output = run_probe(
        env, MOVED_SOURCE,
        # The gem name first, then the require path, then what to look for: the search is
        # scoped to what this gem *defines*, and it can only know that from its own spec.
        [env.package, env.require_path, kind, leaf],
        suffix: suffix, timeout: RUN_TIMEOUT
      )
      return [] if unreached?(output)

      output.split("\n").map(&:strip).select { |line| REFERENCE.match?(line) }
    end

    # The interpreter the probes run under, asked once per process.
    #
    # A report states the runtime its evidence came from, and for a gem that is not the process
    # filing the report: `Gem::Version`'s rules and a gem's own behaviour both move with the
    # Ruby version, so it is a fact a reader can act on. The fallback is the bare word `ruby` —
    # a report that could not ask still has to say something true rather than nothing.
    def self.runtime
      RUNTIME_LOCK.synchronize do
        @runtime ||= begin
          # `ruby -v` writes `ruby 3.3.12 (2026-07-16 revision …) [x86_64-linux]`, and the first
          # two words are the fact: the interpreter and its version. Anything else — no
          # interpreter, a timeout — leaves the bare word, which is still true.
          result = begin
            capture(["ruby", "-v"], timeout: 10)
          rescue Errors::MinerError
            nil
          end
          words = result ? result.output.to_s.strip.split("\n").first.to_s.split.first(2) : []
          words.empty? ? "ruby" : words.join(" ")
        end
      end
    end

    # This machine as a *gem's* builder, for the ledger's stamp: `ruby 3.3.12 cc`.
    #
    # The Ruby half of `Machine.python`, and it exists because the stamp used to be the
    # Python one for every record — so 1,844 gem pairs on this deployment were stamped
    # `cpython 3.12`, and a fact about Ruby would have outlived the Ruby it was established
    # on. The interpreter comes from `runtime`, which asks the interpreter rather than
    # restating what the image was built with, and the toolchain from the shared probe,
    # because a gem's C extension is decided by the same `cc` on this machine whichever
    # index is being mined.
    def self.machine = "#{runtime} #{Machine.toolchain}"

    # The registry of per-environment locks, and the guard for the instant it takes to hand one
    # out. Public because `prune` and the suite both check that a reclaimed environment's lock is
    # gone: a registry that only grows is the leak the forgetting exists to bound.
    #
    # `Style/MutableConstant` is disabled rather than satisfied: this is a live registry, handed
    # entries by `lock_for` and read by `forget_lock` from a second thread, so freezing the
    # literal would raise on the first `LOCKS[key] ||= …`. The guard beside it is what makes the
    # mutation the right thing to do.
    LOCKS = {} # rubocop:disable Style/MutableConstant
    LOCKS_GUARD = Mutex.new
    RUNTIME_LOCK = Mutex.new

    # The inventory, as a Ruby program. It prints one JSON object per line: a header, then one
    # entry per constant, singleton method and instance method the gem *defines*.
    #
    # Two details are load-bearing. A definition is recognised by its `source_location` being
    # under the gem's own path, which is what tells a name the gem defines apart from one it
    # re-exports from a dependency — and what makes a C extension invisible, because its methods
    # have no Ruby source at all: `json` reports zero modules this way. That fallback is stated
    # in the header as `native: true` so a caller can see the surface it got was the shallow one.
    #
    # And only names that can be interpolated into an expression are emitted, because the probe
    # evaluates what it is given; the miner checks again before it builds one.
    #
    # A single-quoted heredoc, so the script's own `#{…}` interpolations stay in the script — they
    # are the *probe's* interpolations, not this file's.
    INVENTORY_SOURCE = <<~'GEM_INVENTORY'
      require "json"
      gem_name, require_path, limit = ARGV[0], ARGV[1], (ARGV[2] || "4000").to_i
      begin
        require require_path
      rescue Exception => e
        puts({"t" => "header", "loaded" => false, "error" => "#{e.class}: #{e.message}"}.to_json)
        exit 0
      end
      spec = Gem.loaded_specs[gem_name]
      if spec.nil?
        puts({"t" => "header", "loaded" => false, "error" => "gem not activated: #{gem_name}"}.to_json)
        exit 0
      end
      dir = spec.full_gem_path
      def in_gem?(location, dir)
        !location.nil? && location[0].to_s.start_with?(dir + "/")
      end
      def safe_owner?(name)
        name.match?(/\A[A-Za-z_][A-Za-z0-9_:]*\z/)
      end
      def safe_method?(name)
        name.to_s.match?(/\A[a-z_][A-Za-z0-9_]*[?!]?\z/)
      end
      def keywords(method)
        method.parameters.each_with_object([]) do |(kind, name), found|
          found << name.to_s if (kind == :key || kind == :keyreq) && name
        end
      end
      entries = []
      seen = {}
      emit = lambda do |kind, name, owner, method_name, params|
        return if seen[name]
        seen[name] = true
        row = {"t" => kind, "name" => name, "owner" => owner}
        row["method"] = method_name if method_name
        row["params"] = params if params
        entries << row
      end
      ObjectSpace.each_object(Module) do |mod|
        name = mod.name
        next if name.nil?
        # The three modules every object already has, skipped because their gem-owned
        # constants *are* the top-level ones and are emitted as such below. Left in,
        # `Object` reports its gem-owned constant as `Object::Colorize` — a reference
        # nobody writes, and one that would read as a removal the day the constant
        # moved while the real name stayed.
        next if name == "Object" || name == "Kernel" || name == "BasicObject"
        next unless safe_owner?(name)
        owner_defined = false
        if mod.is_a?(Class)
          mod.instance_methods(false).each do |sym|
            next unless safe_method?(sym)
            begin
              method = mod.instance_method(sym)
            rescue NameError
              next
            end
            next unless in_gem?(method.source_location, dir)
            owner_defined = true
            emit.call("instance", "#{name}##{sym}", name, sym.to_s, keywords(method))
          end
        end
        mod.singleton_methods(false).each do |sym|
          next unless safe_method?(sym)
          begin
            method = mod.method(sym)
          rescue NameError
            next
          end
          next unless in_gem?(method.source_location, dir)
          owner_defined = true
          emit.call("singleton", "#{name}.#{sym}", name, sym.to_s, keywords(method))
        end
        # A gem's nested constants are most of what it publishes — `Colorize::VERSION`,
        # `Foo::Error` — and a top-level-only scan misses every one of them. Measured
        # against colorize: 0.8.1 defines `Colorize::ClassMethods` and 1.0.0 adds
        # `Colorize::VERSION` and two error classes, none of which appear on `Object`.
        mod.constants(false).each do |const|
          symbol = const.to_sym
          next unless symbol.to_s.match?(/\A[A-Z][A-Za-z0-9_]*\z/)
          location = (mod.const_source_location(symbol) rescue nil)
          next unless in_gem?(location, dir)
          full = "#{name}::#{const}"
          next unless safe_owner?(full)
          owner_defined = true
          emit.call("constant", full, full, nil, nil)
        end
        if owner_defined && entries.size >= limit
          break
        end
      end
      native = entries.empty?
      if native
        # The C-extension fallback: no Ruby source to locate, so take the names on the
        # gem's own top-level constants without the definition filter.
        top = Object.constants(false).select do |const|
          location = (Object.const_source_location(const) rescue nil)
          in_gem?(location, dir)
        end
        top.each do |const|
          full = const.to_s
          next unless safe_owner?(full)
          mod = Object.const_get(const) rescue nil
          next unless mod.is_a?(Module)
          emit.call("constant", full, full, nil, nil)
          next if entries.size >= limit
          if mod.is_a?(Class)
            mod.instance_methods(false).first(200).each do |sym|
              next unless safe_method?(sym)
              emit.call("instance", "#{full}##{sym}", full, sym.to_s, nil)
            end
          end
          mod.singleton_methods(false).first(200).each do |sym|
            next unless safe_method?(sym)
            emit.call("singleton", "#{full}.#{sym}", full, sym.to_s, nil)
          end
        end
      end
      top = Object.constants(false).select do |const|
        location = (Object.const_source_location(const) rescue nil)
        in_gem?(location, dir)
      end
      top.each do |const|
        full = const.to_s
        next unless safe_owner?(full)
        emit.call("constant", full, full, nil, nil)
      end
      header = {"t" => "header", "loaded" => true, "native" => native,
                "dir" => dir, "entries" => entries.size}
      puts header.to_json
      entries.first(limit).each { |row| puts row.to_json }
    GEM_INVENTORY

    # The probe: evaluate one reference, or one call with one keyword. Nothing is rescued, so what
    # a caller reads is Ruby's own error text.
    PROBE_SOURCE = <<~'PROBE_RUBY'
      require_path, expression, keyword = ARGV[0], ARGV[1], ARGV[2]
      require require_path
      if keyword && !keyword.empty?
        eval("#{expression}(#{keyword}: 0)")
      else
        eval(expression)
      end
    PROBE_RUBY

    # Where a name went. A constant keeps its name and moves down a level, which is why this
    # searches by name; a method keeps its name and moves to another owner, which is why the
    # method search is by owner rather than by spelling.
    MOVED_SOURCE = <<~'MOVED_RUBY'
      gem_name, require_path, kind, leaf = ARGV[0], ARGV[1], ARGV[2], ARGV[3]
      require require_path
      spec = Gem.loaded_specs[gem_name]
      exit 0 if spec.nil?
      dir = spec.full_gem_path
      def in_gem?(location, dir)
        !location.nil? && location[0].to_s.start_with?(dir + "/")
      end
      found = []
      if kind == "constant"
        ObjectSpace.each_object(Module) do |mod|
          name = mod.name
          next if name.nil?
          next unless name.end_with?("::" + leaf)
          symbol = leaf.to_sym
          next unless mod.constants(false).include?(symbol)
          location = (mod.const_source_location(symbol) rescue nil)
          next unless in_gem?(location, dir)
          found << name
        end
      elsif kind == "instance"
        symbol = leaf.to_sym
        ObjectSpace.each_object(Class) do |mod|
          name = mod.name
          next if name.nil?
          next unless mod.instance_methods(false).include?(symbol)
          method = (mod.instance_method(symbol) rescue nil)
          next unless in_gem?(method && method.source_location, dir)
          found << "#{name}##{leaf}"
        end
      else
        symbol = leaf.to_sym
        ObjectSpace.each_object(Module) do |mod|
          name = mod.name
          next if name.nil?
          next unless mod.singleton_methods(false).include?(symbol)
          method = (mod.method(symbol) rescue nil)
          next unless in_gem?(method && method.source_location, dir)
          found << "#{name}.#{leaf}"
        end
      end
      found.uniq.sort.each { |name| puts name }
    MOVED_RUBY
  end
end
