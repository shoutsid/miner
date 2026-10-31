# frozen_string_literal: true

require_relative "test_helper"

# The release that broke it, found by running the releases between the endpoints.
#
# Every test drives `Bisect` with a lambda rather than an installer: the search is the judgement,
# and the judgement is what a synthetic ladder can hold exactly — a break in the middle, a release
# that cannot be built, a window that opens again after it closed. Installing real releases to test
# a binary search would make the answer depend on the index's afternoon.
class BisectTest < MinerTest
  Bisect = AgentsMiner::Bisect

  LADDER = %w[1.0.0 1.1.0 1.2.0 1.3.0 1.4.0 1.5.0 1.6.0 1.7.0 1.8.0 1.9.0 1.10.0 1.11.0 1.12.0].freeze

  def test_the_first_refusing_release_in_the_middle_of_a_window
    # Twelve releases between the endpoints, a break at 1.7.0, and the answer is that release —
    # not the 1.12.0 the differential ran.
    result = search(LADDER, from: "1.0.0", to: "1.12.0") { |version| refused_from?(version, "1.7.0") }

    assert_equal "1.7.0", result.version
    assert result.established?
    assert_equal %w[1.6.0 1.7.0], result.window
  end

  def test_installs_are_bounded_by_the_logarithm_of_the_window
    # The cost rule the design states, asserted rather than described: `ceil(log2(k))` probes for a
    # window of `k` releases between the endpoints. A sweep would have been eleven installs here,
    # and eleven installs per finding is the difference between this running and not running.
    k = 12
    ceiling = Math.log2(k).ceil

    result = search(LADDER, from: "1.0.0", to: "1.12.0") { |version| refused_from?(version, "1.7.0") }

    assert_operator result.probes.length, :<=, ceiling
    # Every probe is a release in the window, and none of them is an endpoint the differential
    # already ran.
    probed = result.probes.map(&:first)
    assert_empty probed - LADDER[1...-1]
    refute_includes probed, "1.0.0"
    refute_includes probed, "1.12.0"
  end

  def test_a_release_that_does_not_refuse_is_never_read_as_the_answer
    # The release the caller moved to still refuses, and every middle release still accepts: the
    # boundary is the endpoint itself, and saying so is the correct answer rather than a failure.
    result = search(%w[1.0.0 1.1.0 1.2.0], from: "1.0.0", to: "1.2.0") { |version| version == "1.2.0" }

    assert_equal "1.2.0", result.version
    assert_equal %w[1.1.0 1.2.0], result.window
  end

  def test_an_unasked_release_never_reads_as_not_broken
    # The middle release cannot be installed here. The search stops rather than stepping over it:
    # treating the failure as "still works" would move the boundary up and name a release nobody
    # ran, which is the one answer this must never give.
    ladder = %w[1.0.0 1.1.0 1.2.0 1.3.0 1.4.0 1.5.0 1.6.0 1.7.0 1.8.0 1.9.0]

    result = search(ladder, from: "1.0.0", to: "1.9.0") do |version|
      version == "1.5.0" ? nil : refused_from?(version, "1.7.0")
    end

    refute result.established?
    assert_nil result.version
    # The window it got to is kept, because it is the honest statement of what was ruled out.
    refute_nil result.window
    assert_equal "1.5.0", result.probes.last.first
    assert_nil result.probes.last.last
  end

  def test_an_adjacent_pair_has_nothing_to_search_and_spends_nothing
    # The common case: the ladder already compares consecutive lines. There is no middle release,
    # so there is no probe, and the answer is the report's own window.
    result = search(%w[1.0.0 1.1.0], from: "1.0.0", to: "1.1.0") { |_version| true }

    refute result.established?
    refute result.searched?
    assert_equal %w[1.0.0 1.1.0], result.window
  end

  def test_a_release_the_index_no_longer_lists_yields_no_window
    # The endpoints came from the same list, so a missing one means the list moved under the
    # search. Guessing an order from the version strings would probe releases the index does not
    # serve, which is how a bisection reports a boundary no install reproduces.
    result = search(%w[1.0.0 1.1.0 1.2.0], from: "0.9.0", to: "1.2.0") { |_version| true }

    refute result.established?
    refute result.searched?
  end

  def test_a_window_that_opens_again_reports_the_boundary_it_found
    # Non-monotone: the break is present at 1.4.0, absent at 1.5.0, present again from 1.6.0. A
    # binary search cannot prove there is only one boundary, and it does not claim to — it names
    # the first refusal it found, with the pair it sits in, so a reader can see the gap it closed.
    ladder = %w[1.0.0 1.1.0 1.2.0 1.3.0 1.4.0 1.5.0 1.6.0 1.7.0]

    result = search(ladder, from: "1.0.0", to: "1.7.0") do |version|
      version == "1.4.0" || (%w[1.6.0 1.7.0].include?(version))
    end

    assert result.established?
    assert_includes ladder, result.version
    assert_equal 1, result.probes.count { |_version, refused| refused }, "one refusal is the whole search"
    # The release below the answer accepted, which is what makes it a boundary rather than an
    # upper bound.
    below = ladder[ladder.index(result.version) - 1]
    assert_equal below, result.window.first
    assert_equal result.version, result.window.last
  end

  private

  def search(ladder, from:, to:, &probe)
    Bisect.introduced(releases: ladder, from_version: from, to_version: to, &probe)
  end

  # A synthetic ladder where every release at or after `first` refuses, and every one before it
  # accepts — the monotone shape a bisection is allowed to assume.
  def refused_from?(version, first)
    (version.split(".").map(&:to_i) <=> first.split(".").map(&:to_i)) >= 0
  end
end
