# frozen_string_literal: true

require "json"

require_relative "test_helper"

# Choosing upgrades from the index's own history.
class VersionsTest < MinerTest
  V = AgentsFyiMiner::Versions

  def pair(from, to, package: "pkg")
    AgentsFyiMiner::Pair.of(package: package, from_version: from, to_version: to)
  end

  def test_releases_are_ordered_by_their_numbers_not_as_strings
    # `0.10` sorts before `0.9` as text, which would make the "previous release" of a package
    # an older one than the release before it.
    assert_equal(-1, V.sort_key("0.9") <=> V.sort_key("0.10"))
  end

  def test_a_prerelease_sorts_after_the_numbers_it_belongs_to
    assert_equal(-1, V.sort_key("1.0.0") <=> V.sort_key("1.0.1rc1"))
  end

  def test_a_release_with_no_numbers_is_still_orderable
    assert_equal [1, []], V.sort_key("dev")
  end

  def test_the_predecessor_is_the_previous_line_not_the_previous_patch
    # Consecutive patch releases of a mature package almost never remove an argument; ten
    # watchlisted packages produced nothing at all while the miner asked that question. What
    # breaks people is crossing a series.
    history = %w[1.1.0 1.2.0 1.2.1 1.2.2]

    assert_equal [pair("1.1.0", "1.2.2")], V.pairs_for("pkg", history)
  end

  def test_the_newest_release_of_the_earlier_line_is_the_one_compared
    # A caller a version behind is on the last patch of it, not the first.
    history = %w[1.1.0 1.1.1 1.1.7 1.2.0]

    assert_equal [pair("1.1.7", "1.2.0")], V.pairs_for("pkg", history)
  end

  def test_a_prerelease_is_never_the_target_of_an_upgrade
    # An agent is rarely on a pre-release, and one who is has a different problem from the one
    # this miner can reproduce.
    history = %w[1.0.0 1.1.0 1.1.1rc1 1.1.1]

    assert_equal [pair("1.0.0", "1.1.1")], V.pairs_for("pkg", history)
  end

  def test_a_wider_span_reaches_further_back_through_the_lines
    # A caller skipping versions meets breaks a one-line pair would not show, which is what
    # `--span` is for.
    history = %w[1.0.0 1.1.0 1.2.0 1.3.0]

    assert_equal [pair("1.1.0", "1.3.0")], V.pairs_for("pkg", history, span: 2)
    assert_equal [pair("1.0.0", "1.3.0")], V.pairs_for("pkg", history, span: 3)
  end

  def test_a_history_with_one_release_yields_no_pair
    assert_empty V.pairs_for("pkg", ["1.0.0"])
  end

  def test_an_empty_history_yields_no_pair
    assert_empty V.pairs_for("pkg", [])
  end

  def test_build_metadata_does_not_hide_a_numeric_release
    assert_equal [pair("1.0.0", "1.1.0+build.7")], V.pairs_for("pkg", ["1.0.0", "1.1.0+build.7"])
  end

  def test_a_history_with_one_line_yields_no_pair
    # Nothing to move from: every release is in the series the caller is already on, so there
    # is no upgrade to mine.
    assert_empty V.pairs_for("pkg", %w[2.0.0 2.0.1 2.0.2])
  end

  def test_a_zero_major_line_is_read_as_a_line
    # `0.x` projects treat the minor as the breaking axis, which is exactly the httpx case
    # this was built on: 0.27 to 0.28 removed four arguments.
    history = %w[0.26.0 0.27.0 0.27.2 0.28.0 0.28.1]

    assert_equal [pair("0.27.2", "0.28.1")], V.pairs_for("pkg", history)
  end

  def test_a_version_with_one_number_is_read_as_a_whole_line
    assert_equal [3, 0], V.line_of("3")
  end

  def test_build_metadata_does_not_change_which_line_a_release_is_in
    assert_equal [1, 2], V.line_of("1.2.3+build.7")
  end

  def test_a_history_on_disk_is_not_counted_as_a_reason_to_ask_the_index
    # The fetch allowance is a bound on requests. A cached history is a file read, so it is
    # free — and a package the cache covers has to be distinguishable from one it does not, or
    # the walk spends its whole allowance at the head of the order.
    #
    # "Cached" is the version list *and* the dates beside it. A history with no dates is one
    # `release_history` asks the index to complete, so calling it free would spend the
    # allowance on requests this answer says will not happen — the same bug as the one it was
    # written to fix, with its sign flipped.
    refute V.history_is_cached("httpx", cache: @home)

    write("httpx.json", %w[0.27.2 0.28.1])
    refute V.history_is_cached("httpx", cache: @home)

    write("httpx.dates.json", { "0.28.1" => "2024-04-01T00:00:00Z" })
    assert V.history_is_cached("httpx", cache: @home)

    # Expiry is the caller's, and an expired copy is one the index is asked about.
    stale = Time.now - (7 * 3600)
    File.utime(stale, stale, @home + "httpx.json")
    refute V.history_is_cached("httpx", cache: @home)
    refute V.history_is_cached("httpx", cache: @home, max_age: nil)
  end

  def test_a_sidecar_that_recorded_no_dates_is_a_reading_too
    # `{}` is the index having no upload times to offer, not an absent sidecar.
    #
    # A package whose releases are all yanked, or whose files carry no timestamp, would
    # otherwise be asked about once a cycle for ever.
    write("httpx.json", ["0.27.2"])
    write("httpx.dates.json", "{}")

    assert V.history_is_cached("httpx", cache: @home)
  end

  def test_a_sidecar_that_is_not_a_reading_is_not_one
    # A truncated sidecar is what a process killed mid-write leaves, and trusting it would
    # keep the dates it never finished writing.
    write("httpx.json", ["0.27.2"])
    write("httpx.dates.json", "{not json")

    refute V.history_is_cached("httpx", cache: @home)
  end

  def test_an_unreadable_cache_file_is_not_a_cached_history
    # A truncated file is what a process killed mid-write leaves, and treating it as cached
    # would leave the package unfetchable and unreadable at once.
    write("httpx.json", "[0.27.2, ")

    refute V.history_is_cached("httpx", cache: @home)
  end

  def test_every_crossing_of_every_line_is_a_pair
    # A service has to have something to do tomorrow, and "the newest release" stops being
    # newest. So the whole ladder is enumerated, not just its top.
    assert_equal [pair("1.2.0", "1.3.0"), pair("1.1.0", "1.2.0"), pair("1.0.0", "1.1.0")],
      V.crossings("pkg", %w[1.0.0 1.1.0 1.2.0 1.3.0])
  end

  def test_a_crossing_lists_newest_first_because_that_is_where_callers_are
    assert_equal "3.0.0", V.crossings("pkg", %w[1.0.0 2.0.0 3.0.0]).first.to_version
  end

  def test_a_crossing_the_history_skipped_is_still_a_crossing
    # A package that jumped from 1.0 to 3.0 has one upgrade, not a missing one.
    assert_equal [pair("1.0.0", "3.0.0")], V.crossings("pkg", %w[1.0.0 3.0.0])
  end

  def test_the_newest_release_of_each_line_is_the_one_compared
    # A caller behind by a line is on that line's last patch, not its first.
    pairs = V.crossings("pkg", %w[1.0.0 1.1.0 1.1.9 1.2.0 1.2.3])

    assert_equal pair("1.1.9", "1.2.3"), pairs.first
  end

  def test_crossings_can_be_capped
    # A bounded cycle does not want four hundred pairs to choose from.
    assert_equal 2, V.crossings("pkg", %w[1.0.0 1.1.0 1.2.0 1.3.0], limit: 2).length
  end

  def test_a_prerelease_is_never_the_target_of_a_crossing
    pairs = V.crossings("pkg", %w[1.0.0 1.1.0 1.2.0rc1 1.2.0])

    assert_equal "1.2.0", pairs.first.to_version
  end
end
