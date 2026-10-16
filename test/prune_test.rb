# frozen_string_literal: true

require_relative "test_helper"

# Keeping the environment cache bounded, which is what stops a disk-full outage.
class PruneTest < MinerTest
  E = AgentsFyiMiner::Envs
  MB = 1024 * 1024

  # A directory that looks like a built environment of a given size.
  def make_env(name, megabytes: 1, age: 10_000)
    root = dir(name)
    (root + "bin").mkpath
    (root + "bin" + "python").write("")
    (root + "lib").mkpath
    (root + "lib" + "payload.bin").write("x" * (megabytes * MB))
    stamp = Time.now.to_f - age
    File.utime(stamp, stamp, root)
    root
  end

  # The filesystem's allocation unit.
  def unit_for(path) = File.stat(path.to_s).blksize

  def test_a_cache_inside_the_budget_is_left_alone
    make_env("small-1.0", megabytes: 1)

    assert_equal [0, 0], E.prune(@home, budget: 10 * MB)
    assert (@home + "small-1.0").exist?
  end

  def test_the_least_recently_used_environments_go_first
    # An environment is only worth keeping while something is about to use it, and the oldest is
    # the one that has waited longest.
    old = make_env("old-1.0", megabytes: 2, age: 100_000)
    fresh = make_env("fresh-2.0", megabytes: 2, age: 10_000)

    removed, freed = E.prune(@home, budget: 3 * MB)

    assert_equal 1, removed
    assert_operator freed, :>=, 2 * MB
    refute old.exist?
    assert fresh.exist?
  end

  def test_pruning_stops_as_soon_as_the_budget_is_met
    # Asserted as the property rather than as arithmetic: the cache ends inside the budget, and
    # what survives is the newest of it. Byte-exact expectations here would be testing the
    # filesystem's directory sizes.
    make_env("a-1.0", megabytes: 2, age: 300_000)
    make_env("b-1.0", megabytes: 2, age: 200_000)
    make_env("c-1.0", megabytes: 2, age: 100_000)
    budget = 5 * MB

    removed, freed = E.prune(@home, budget: budget)

    assert_equal 1, removed
    assert_operator freed, :>=, 2 * MB
    remaining = @home.children.sum { |path| E.directory_size(path) }
    assert_operator remaining, :<=, budget
    refute (@home + "a-1.0").exist?
    assert (@home + "b-1.0").exist?
    assert (@home + "c-1.0").exist?
  end

  def test_an_environment_touched_recently_is_treated_as_in_use
    # A cycle examines several pairs at once. Deleting a directory another worker is probing turns
    # a real finding into a fabricated one — the traceback would name a file that was there when
    # the script was written and is not there when it runs.
    live = make_env("in-use-1.0", megabytes: 4, age: 1)

    removed, = E.prune(@home, budget: 1, quiet: 900)

    assert_equal 0, removed
    assert live.exist?
  end

  def test_a_cache_with_no_directory_at_all_is_not_an_error
    # A first start has nothing to prune, and a startup that raised over it would be a miner that
    # never mines.
    assert_equal [0, 0], E.prune(@home + "absent")
  end

  def test_a_partial_environment_is_pruned_like_any_other
    # A build that failed leaves a directory with no interpreter in it, and it is the kind of
    # thing that accumulates silently: every failed install leaves one.
    broken = dir("broken-1.0")
    (broken + "lib").mkpath
    (broken + "lib" + "partial.bin").write("x" * (2 * MB))
    stamp = Time.now.to_f - 100_000
    File.utime(stamp, stamp, broken)

    removed, = E.prune(@home, budget: 1)

    assert_equal 1, removed
    refute broken.exist?
  end

  def test_the_size_measured_is_the_disk_and_not_the_length_of_the_files
    # The bug this replaced: `prune` summed `st_size`, and a site-packages directory is thousands
    # of small modules each of which the filesystem rounds up to a whole block. Measured on this
    # deployment, the verifier's 9.1 GB of environments summed to 8.2 GB of file lengths — just
    # inside an 8 GiB budget, so the one number that decided whether anything was deleted was the
    # one that was wrong, and the cache sat over its bound indefinitely.
    root = dir("many-small-1.0")
    (root + "lib").mkpath
    64.times { |index| (root + "lib" + "module#{index}.py").write("x") }
    unit = unit_for(root)

    lengths = root.glob("**/*").select { |entry| entry.file? && !entry.symlink? }
                   .sum { |entry| entry.stat.size }

    assert_equal 64, lengths, "sixty-four files of one byte each"
    assert_operator E.directory_size(root), :>=, 64 * unit
  end

  def test_a_cache_of_small_files_is_bounded_by_the_disk_it_uses
    # The same bug from the caller's side. Three environments whose contents are a few hundred
    # bytes between them and whose allocation is a megabyte each: read as lengths the whole cache
    # fits the budget and nothing is deleted, which is how a bound on a disk comes to hold nothing.
    unit = unit_for(@home)
    [["old-1.0", 300_000], ["middle-1.0", 200_000], ["new-1.0", 100_000]].each do |name, age|
      root = dir(name)
      (root + "lib").mkpath
      256.times { |index| (root + "lib" + "module#{index}.py").write("x") }
      stamp = Time.now.to_f - age
      File.utime(stamp, stamp, root)
    end

    removed, = E.prune(@home, budget: (256 * unit * 2.5).to_i)

    assert_equal 1, removed
    refute (@home + "old-1.0").exist?
    assert (@home + "new-1.0").exist?
  end
end
