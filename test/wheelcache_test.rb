# frozen_string_literal: true

require_relative "test_helper"

# The shared wheel cache: where it is, and the bound that keeps it a cache.
#
# Two things are worth pinning here and both are about the *bound* rather than about pip. The
# first is that the cache the miners prune is the cache pip writes to — a prune aimed at a
# different directory measures nothing, reports success, and bounds nothing, which is a failure
# that looks exactly like a healthy deployment. The second is that the unit of deletion is whole
# cache entries: pip's cache is a directory per key, and removing the files inside one while
# leaving the directory would be handing pip a half-entry it may try to read.
#
# The failure mode is what makes this safe to test against the real layout rather than a mock:
# deleting a cache entry can only cause a re-download. That was verified against a live cache
# before this was written — an entry was removed, the packages installed again, and they came
# back from a single re-download.
class WheelCacheTest < MinerTest
  def test_the_cache_being_bounded_is_the_one_pip_writes_to
    # `PIP_CACHE_DIR` is what pip reads, so it is what this has to agree with. A prune that
    # measured somewhere else would find nothing, return `(0, 0)`, and read in the log exactly
    # like a cache comfortably inside its budget.
    ENV["PIP_CACHE_DIR"] = (@home + "elsewhere").to_s

    assert_equal @home + "elsewhere", AgentsMiner::WheelCache.cache_dir(@home + "home")
  end

  def test_a_blank_cache_variable_is_not_a_cache_directory
    # The compose file forwards every knob as `${VAR:-}`, so a variable nobody set arrives as an
    # empty string — and an empty path is the *current directory*, which is the shape of bug
    # this rule exists for: a prune of the whole working tree, or of nothing, depending on which
    # way the empty string is read.
    ENV["PIP_CACHE_DIR"] = ""

    assert_equal @home + ".cache" + "pip",
      AgentsMiner::WheelCache.cache_dir(@home + ".cache" + "agents-miner")
  end

  def test_with_nothing_configured_it_is_the_sibling_of_the_clients_home
    # Which is where pip puts it anyway — `~/.cache/pip` beside `~/.cache/agents-miner` — so
    # the bound works for a client started without the image's environment, as a test or a
    # one-off run is.
    ENV.delete("PIP_CACHE_DIR")
    home = @home + ".cache" + "agents-miner"

    assert_equal @home + ".cache" + "pip", AgentsMiner::WheelCache.cache_dir(home)
  end

  def test_a_cache_inside_its_budget_is_left_alone
    cache = @home + "pip"
    make_entry(cache, "ab", "cd", megabytes: 1)

    assert_equal [0, 0], AgentsMiner::WheelCache.prune(cache, budget: 10 * 1024 * 1024)
    assert (cache + "http-v2" + "ab" + "cd").exist?
  end

  def test_a_cache_with_no_directory_at_all_is_not_an_error
    # A first start, or a client whose wheels are all still to be fetched.
    assert_equal [0, 0], AgentsMiner::WheelCache.prune(@home + "absent")
    assert_equal 0, AgentsMiner::WheelCache.size(@home + "absent")
  end

  def test_the_least_recently_used_entries_go_first
    # An entry is only worth keeping while something is about to install it again, and the oldest
    # is the one that has waited longest.
    cache = @home + "pip"
    old = make_entry(cache, "aa", "old", megabytes: 2, age: 100_000)
    fresh = make_entry(cache, "bb", "new", megabytes: 2, age: 10_000)

    removed, = AgentsMiner::WheelCache.prune(cache, budget: 3 * 1024 * 1024)

    assert_equal 1, removed
    refute old.exist?
    assert fresh.exist?
  end

  def test_an_entry_written_a_moment_ago_is_left_alone
    # Another process may be downloading into it right now, and deleting it costs that process
    # the work for no saving at all.
    cache = @home + "pip"
    live = make_entry(cache, "aa", "live", megabytes: 4, age: 1)

    removed, = AgentsMiner::WheelCache.prune(cache, budget: 1, quiet: 300)

    assert_equal 0, removed
    assert live.exist?
  end

  def test_a_whole_entry_is_removed_rather_than_the_files_inside_it
    # pip's cache is a directory per key. Deleting the files and leaving the directory would hand
    # pip an entry that exists and is empty, which is not the same thing as one that is absent.
    cache = @home + "pip"
    entry = make_entry(cache, "aa", "one", megabytes: 4, age: 100_000)

    AgentsMiner::WheelCache.prune(cache, budget: 1)

    refute entry.exist?
  end

  def test_the_entries_are_the_innermost_directories_holding_files
    # Found by shape rather than by hard-coding pip's two directory names: a layout pip changes
    # would otherwise be a prune that deleted nothing.
    cache = @home + "pip"
    make_entry(cache, "aa", "one")
    make_entry(cache, "aa", "two")
    built = dir("pip", "wheels", "built")
    (built + "pkg-1.0-py3-none-any.whl").write("x")

    found = AgentsMiner::WheelCache.entries(cache).map { |path| path.basename.to_s }.sort

    assert_equal %w[built one two], found
  end

  def test_the_size_is_the_disk_and_not_the_length_of_the_files
    # The same reading `Envs.directory_size` documents, and it matters more here than it looks: a
    # wheel is one large file, but pip's cache also holds thousands of small index responses,
    # each of which the filesystem rounds up to a block.
    #
    # A fixture of one large file cannot see this: one big file's length and its blocks are
    # the same number to within a block, while sixty-four one-byte files are 64 bytes of
    # length and 64 blocks of disk.
    cache = @home + "pip"
    entry = dir("pip", "http-v2", "aa", "many")
    64.times { |index| (entry + "head#{index}").write("x") }

    unit = entry.stat.blksize
    unit = 4096 if unit.zero?
    lengths = entry.children.sum { |child| child.stat.size }

    assert_equal 64, lengths
    assert_operator AgentsMiner::WheelCache.size(cache), :>, lengths,
      "the size is file lengths, so a budget checked against it is wrong"
    assert_operator AgentsMiner::WheelCache.size(cache), :>=, 64 * unit
  end

  private

  # One cache entry, shaped the way pip writes them: a directory of files.
  def make_entry(cache, fanout, key, megabytes: 1, age: 10_000)
    entry = cache + "http-v2" + fanout + key
    FileUtils.mkdir_p(entry)
    (entry + "response.body").write("x" * (megabytes * 1024 * 1024))
    (entry + "metadata").write("{}")
    stamp = Time.now - age
    File.utime(stamp, stamp, entry.to_s)
    entry
  end
end
