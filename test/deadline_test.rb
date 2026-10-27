# frozen_string_literal: true

require_relative "test_helper"

# How long an install may take, priced from the bytes it has to move.
#
# `INSTALL_TIMEOUT` was a flat five minutes and it could not serve both ends of the watchlist:
# generous for the hundreds of small packages that are most of the queue, and hopeless for the
# machine-learning tail, where one wheel is 688 MB. What makes the second case expensive rather
# than merely slow is that a killed install keeps nothing — pip discards a partial download — so
# a release the deadline cannot cover is attempted for ever, paying the full timeout each time
# and discarding every byte.
#
# Every number here is invented, because the decision is arithmetic over a payload and a rate and
# does not need a link to test. That is the point: the measurement that produced the real numbers
# was made by downloading into a working deployment, which is exactly what this module's caller
# must not have to do to be trusted.
class DeadlineTest < MinerTest
  E = AgentsMiner::Envs
  MB = 1024 * 1024

  def test_a_release_of_unknown_size_keeps_the_flat_timeout
    # Nothing is invented for a release the index did not price.
    assert_equal E::INSTALL_TIMEOUT, E.install_deadline(nil, rate: 2_000_000.0, workers: 6)
    assert_equal E::INSTALL_TIMEOUT, E.install_deadline(0, rate: nil, workers: 1)
  end

  def test_a_small_payload_keeps_the_floor
    # Ten megabytes is seconds of work, and the floor is what the miner always had.
    assert_equal E::INSTALL_TIMEOUT, E.install_deadline(10 * MB, rate: 1_000_000.0, workers: 1)
  end

  def test_a_large_payload_gets_longer_than_the_floor
    # 800 MB at a megabyte a second is a little over thirteen minutes, not ten.
    assert_equal((800 * MB) / 1_000_000,
      E.install_deadline(800 * MB, rate: 1_000_000.0, workers: 1))
  end

  def test_the_link_is_divided_among_the_workers_sharing_it
    # Six workers on a six-megabyte link each get one, which is the whole problem.
    shared = E.install_deadline(800 * MB, rate: 6_000_000.0, workers: 6)
    alone = E.install_deadline(800 * MB, rate: 1_000_000.0, workers: 1)

    assert_equal alone, shared
    # And the same release on the same link with nobody to share it with is quick enough that the
    # floor is what applies.
    assert_equal E::INSTALL_TIMEOUT, E.install_deadline(800 * MB, rate: 6_000_000.0, workers: 1)
  end

  def test_an_unmeasured_link_is_treated_as_slow_rather_than_fast
    # A container that has only been probing cannot say how fast it is.
    #
    # Reading that as a fast link would price a gigabyte at seconds and hand back a deadline too
    # short to fetch it — the direction whose cost is a discarded download.
    assert_equal E::MAX_INSTALL_TIMEOUT, E.install_deadline(1024 * MB, rate: nil, workers: 6)
    assert_equal E::MAX_INSTALL_TIMEOUT, E.install_deadline(1024 * MB, rate: 0.0, workers: 6)
    # And a small release is still small, whatever is unknown about the link.
    assert_equal E::INSTALL_TIMEOUT, E.install_deadline(4 * MB, rate: nil, workers: 6)
  end

  def test_no_release_is_given_less_than_the_floor_or_more_than_the_ceiling
    # The two bounds, over the whole plausible range of payloads and links.
    [nil, 0, 1, 100 * MB, 688 * MB, 8 * 1024 * MB].each do |payload|
      [nil, 0.0, 50_000.0, 2_800_000.0, 100_000_000.0].each do |rate|
        [1, 6, 24].each do |workers|
          deadline = E.install_deadline(payload, rate: rate, workers: workers)

          assert_operator deadline, :>=, E::INSTALL_TIMEOUT, "#{payload} at #{rate} on #{workers}"
          assert_operator deadline, :<=, E::MAX_INSTALL_TIMEOUT, "#{payload} at #{rate} on #{workers}"
        end
      end
    end
  end

  def test_a_retry_doubles_what_the_last_attempt_had
    # A pair that ran out of time is the evidence that its deadline was too short.
    #
    # This is how a release that is cheap *itself* and drags in a large dependency tree gets
    # there: only its own files are priced, so its first attempt is deliberately under-priced and
    # the retry corrects for it.
    payload = 500 * MB
    first = E.install_deadline(payload, rate: 1_000_000.0, workers: 1, attempts: 0)
    second = E.install_deadline(payload, rate: 1_000_000.0, workers: 1, attempts: 1)

    assert_equal first * E::INSTALL_RETRY_FACTOR, second
  end

  def test_a_retry_never_exceeds_the_ceiling
    # The escalation has to stop somewhere, or a release that cannot be fetched is attempted with
    # a longer and longer deadline for ever — which is the loop this whole module exists to end.
    huge = 64 * 1024 * MB
    (1..7).each do |attempts|
      assert_equal E::MAX_INSTALL_TIMEOUT,
        E.install_deadline(huge, rate: 100_000.0, workers: 1, attempts: attempts)
    end
  end

  def test_the_scratch_sweep_stays_short_enough_to_reclaim_within_a_cycle
    # A guard against a well-meaning increase, because longer here is not safer.
    #
    # The sweep removes what a killed install left behind, and it is called at the top of a cycle
    # before any worker exists — so nothing can be installing while it runs, and anything present
    # is already abandoned. Its threshold's only job is to not race an install killed moments
    # earlier. Raising it toward the new install ceiling would look like prudence and would
    # actually stop reclaiming: one measured sweep returned 2,767 MB, and a threshold in hours
    # would let that accumulate on the volume instead.
    assert_operator E::SCRATCH_ORPHAN_SECONDS, :>, E::INSTALL_TIMEOUT
    assert_operator E::SCRATCH_ORPHAN_SECONDS, :<, 3600
  end
end
