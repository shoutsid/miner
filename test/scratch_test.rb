# frozen_string_literal: true

require_relative "test_helper"

# pip's scratch directory: where it is, and who cleans up after a kill.
#
# `/tmp` in these containers is a tmpfs, which is RAM, and pip unpacks every wheel and every sdist
# build into `TMPDIR`. That made the scratch directory a memory leak with a filesystem API:
# measured on this deployment it held 4.1 GB within thirty-five minutes — 769 `pip-unpack-*`
# directories and 28 build directories — and the container sat pinned against its own memory
# limit, killing installs and then the process, roughly every twenty-two minutes.
#
# The two halves are pinned here. The *location* has to be the volume, and it has to be the one
# place the home is decided, or a client started by hand gets RAM while one started by the
# entrypoint gets disk. The *sweep* exists because pip can only remove its own scratch when it is
# allowed to finish, and a build killed by `INSTALL_TIMEOUT` never is.
class ScratchTest < MinerTest
  E = AgentsMiner::Envs

  def make_scratch(root, name, megabytes: 1, age: 10_000)
    entry = dir(root.basename.to_s, name)
    (entry + "unpacked.bin").write("x" * (megabytes * 1024 * 1024))
    stamp = Time.now.to_f - age
    File.utime(stamp, stamp, entry)
    entry
  end

  def test_the_scratch_goes_on_the_volume_when_nothing_says_otherwise
    # Not `/tmp`: that is a tmpfs here, and a gigabyte wheel unpacked into it is a gigabyte of the
    # container's memory limit.
    ENV.delete("TMPDIR")
    home = @home + "agents-miner"

    root = E.use_scratch_dir(home)

    assert_equal home + "tmp", root
    assert root.directory?
    assert_equal root.to_s, ENV["TMPDIR"]
  end

  def test_a_scratch_directory_already_chosen_is_not_overruled
    # Someone who has pointed `TMPDIR` somewhere is making a decision about their own machine, and
    # the sweep follows it rather than fighting it.
    chosen = @home + "somewhere-else"
    ENV["TMPDIR"] = chosen.to_s

    root = E.use_scratch_dir(@home + "agents-miner")

    assert_equal chosen, root
    assert_equal chosen.to_s, ENV["TMPDIR"]
  end

  def test_the_sweep_clears_what_it_was_told_to_sweep
    # The location the sweep measures and the location pip writes are the same question asked
    # twice, and a sweep of the wrong directory reports success while bounding nothing.
    ENV["TMPDIR"] = (@home + "scratch").to_s
    make_scratch(@home + "scratch", "pip-unpack-abc")

    assert_equal @home + "scratch", E.scratch_dir(@home + "elsewhere")
  end

  def test_an_abandoned_scratch_directory_is_removed
    # pip cannot clean up after a kill — by `INSTALL_TIMEOUT`, or by the container dying
    # mid-install — so it is left for ever otherwise.
    root = @home + "tmp"
    left = make_scratch(root, "pip-unpack-orphan", megabytes: 2)

    removed, freed = E.sweep_scratch(root)

    assert_equal 1, removed
    assert_operator freed, :>=, 2 * 1024 * 1024
    refute left.exist?
  end

  def test_a_scratch_directory_a_live_install_owns_is_left_alone
    # The threshold is derived from `INSTALL_TIMEOUT` rather than guessed: an install that had
    # been running longer than the timeout has already been killed, so age alone separates an
    # orphan from a working directory. Removing a live one would fail the install using it.
    root = @home + "tmp"
    live = make_scratch(root, "pip-unpack-live", megabytes: 2, age: 1)

    removed, = E.sweep_scratch(root)

    assert_equal 0, removed
    assert live.exist?
  end

  def test_the_threshold_is_longer_than_any_install_that_is_allowed_to_finish
    # Stated as the property rather than as a number, because the number is the consequence:
    # nothing a running pip owns can be swept.
    assert_operator E::SCRATCH_ORPHAN_SECONDS, :>, E::INSTALL_TIMEOUT
  end

  def test_a_scratch_directory_with_nothing_in_it_is_not_an_error
    # Every cycle runs this, including the first one after a restart.
    assert_equal [0, 0], E.sweep_scratch(@home + "absent")
    assert_equal [0, 0], E.sweep_scratch(@home)
  end

  def test_the_sweep_removes_a_whole_entry_and_not_the_files_inside_it
    # pip names each directory for the install that owns it; a half-removed one is not a state
    # anything should have to interpret.
    root = @home + "tmp"
    entry = make_scratch(root, "pip-unpack-whole", megabytes: 2)
    FileUtils.mkdir_p(entry + "nested")
    (entry + "nested" + "deep.bin").write("y" * 1024)
    # Aged after the contents, because writing into a directory is what moves its mtime — which
    # is the property the sweep relies on to tell an orphan from a working directory, and would
    # have hidden this if the fixture set it first.
    stamp = Time.now.to_f - 10_000
    File.utime(stamp, stamp, entry)

    E.sweep_scratch(root)

    refute entry.exist?
  end
end
