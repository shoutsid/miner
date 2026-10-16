# frozen_string_literal: true

require_relative "test_helper"

# Measuring this container's own downloads, and the ceiling built on it.
#
# Everything here is offline on purpose, and that is not only about speed. The first attempt to
# understand this deployment's download behaviour was made by downloading *into* it while it was
# working, and every number that produced was a number under contention the measurement had
# created — a saturated pipe reported as if it were the link's capacity, paid for with bandwidth
# the corpus wanted. So the counter is read from a file this test writes, the clock is a list of
# numbers, and the control loop is driven rather than waited on.
#
# What is worth pinning is the difference between *no rate* and *a rate of zero*. An unreadable
# counter and a counter that went backwards both mean "this machine cannot say", and both are
# read by callers as a reason to be careful. Reporting either as zero would read as a fast link,
# which is the direction that costs a discarded download.
class BandwidthTest < MinerTest
  PROC = <<~PROC
    Inter-|   Receive                              |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes packets
        lo: 9999999       1    0    0    0     0          0         0      0       0
      eth0:    4000       7    0    0    0     0          0         0   1234       7
      eth1:    1000       3    0    0    0     0          0         0    100       3
  PROC

  def test_a_counter_sums_the_real_interfaces_and_not_loopback
    # Loopback is traffic this container sent itself, which is not the link.
    path = write("dev", PROC)

    assert_equal 5000, AgentsFyiMiner::Bandwidth.received_bytes(path)
  end

  def test_an_unreadable_counter_is_not_a_reading
    # `nil` rather than `0`: a machine that cannot say is not a machine at zero.
    assert_nil AgentsFyiMiner::Bandwidth.received_bytes(@home + "absent")
  end

  def test_banner_lines_alone_are_not_a_reading
    # The header of `/proc/net/dev` has no interface under it, so there is no number.
    path = write("dev", PROC.lines.first)

    assert_nil AgentsFyiMiner::Bandwidth.received_bytes(path)
  end

  def test_a_rate_is_the_bytes_between_two_readings_over_the_time
    earlier = AgentsFyiMiner::Bandwidth::Reading.new(bytes: 1_000, at: 10.0)
    later = AgentsFyiMiner::Bandwidth::Reading.new(bytes: 3_000, at: 12.0)

    assert_equal 1_000.0, AgentsFyiMiner::Bandwidth.rate_between(earlier, later)
  end

  def test_a_counter_that_went_backwards_is_not_a_rate
    # A container restarted under a counter that survives nothing is not a speed.
    earlier = AgentsFyiMiner::Bandwidth::Reading.new(bytes: 9_000, at: 10.0)
    later = AgentsFyiMiner::Bandwidth::Reading.new(bytes: 10, at: 20.0)

    assert_nil AgentsFyiMiner::Bandwidth.rate_between(earlier, later)
  end

  def test_two_readings_at_one_moment_are_not_a_rate
    # Dividing by an elapsed time of zero is a crash, and the honest answer is none.
    same = 10.0

    assert_nil AgentsFyiMiner::Bandwidth.rate_between(
      AgentsFyiMiner::Bandwidth::Reading.new(bytes: 1, at: same),
      AgentsFyiMiner::Bandwidth::Reading.new(bytes: 9, at: same)
    )
  end

  def test_an_unreadable_reading_is_not_a_rate
    assert_nil AgentsFyiMiner::Bandwidth.rate_between(
      AgentsFyiMiner::Bandwidth::Reading.new(bytes: nil, at: 1.0),
      AgentsFyiMiner::Bandwidth::Reading.new(bytes: 9, at: 2.0)
    )
  end

  def test_with_no_ceiling_a_slot_is_free
    # A process that was never asked to be slowed must not be slowed.
    throttle = driven(readings: [0, 0], moments: [0.0, 1.0], limit: 0.0, streams: 4)

    throttle.slot do
      throttle.slot do
        throttle.slot do
          throttle.slot { assert true }
        end
      end
    end

    assert_equal throttle.streams, throttle.allowed
  end

  def test_the_ceiling_is_enforced_by_how_many_downloads_run_at_once
    # The correction this made, in one test.
    #
    # Delaying the *start* of an install does not slow the installs already running, so the first
    # version of this could not hold a ceiling at all — measured live at 2.60 MB/s against a
    # target of 2.00. What can hold it is how many run at once.
    throttle = driven(readings: [0] * 8, moments: [0.0] * 8, limit: 1_000_000.0, streams: 1)
    released = Queue.new
    started = Queue.new
    guard = Mutex.new
    entered = []

    first = Thread.new do
      throttle.slot do
        guard.synchronize { entered << "first" }
        started << true
        released.pop(timeout: 2.0)
      end
    end
    assert started.pop(timeout: 2.0), "the first slot was never entered"

    second = Thread.new { throttle.slot { guard.synchronize { entered << "second" } } }
    # The second slot cannot be entered while the first is held.
    second.join(0.2)
    assert_equal ["first"], entered

    released << true
    first.join(2.0)
    second.join(2.0)
    assert_equal %w[first second], entered
  end

  def test_a_rate_over_the_ceiling_takes_a_stream_away
    # 2 MB/s measured against a 1 MB/s ceiling: one fewer download was allowed.
    throttle = driven(readings: [0, 20_000_000, 20_000_000], moments: [0.0, 10.0, 10.0],
      limit: 1_000_000.0, streams: 4)
    throttle.slot {}
    # The first completion has nothing to compare against, so it changes nothing.
    assert_equal 4, throttle.allowed
    throttle.slot {}
    assert_equal 3, throttle.allowed
  end

  def test_a_rate_well_under_the_ceiling_gives_a_stream_back
    # Room to spare is room to fetch more of the queue at once, and only room to spare.
    #
    # The allowance starts at the configured maximum, so recovery can only be *seen* after it has
    # been pushed down: 2 MB/s against a 1 MB/s ceiling takes a stream away, and 0.1 MB/s then
    # gives it back. A rate merely equal to the ceiling is not comfortably under it and does
    # neither.
    throttle = driven(readings: [0, 20_000_000, 21_000_000], moments: [0.0, 10.0, 20.0],
      limit: 1_000_000.0, streams: 3)
    throttle.slot {}
    assert_equal 3, throttle.allowed
    throttle.slot {}
    assert_equal 2, throttle.allowed
    throttle.slot {}
    assert_equal 3, throttle.allowed
  end

  def test_a_rate_equal_to_the_ceiling_leaves_the_allowance_alone
    # Meeting the ceiling is neither exceeding it nor comfortably under it.
    #
    # One measurable completion, at exactly the ceiling: 10 MB over ten seconds against a limit of
    # 1 MB/s. A controller that moved on either side of this would oscillate around its own
    # target, which is why this is a single step and not a sequence — starting from an
    # over-ceiling reading would leave the allowance already reduced and would be measuring the
    # step before it instead.
    throttle = driven(readings: [0, 10_000_000], moments: [0.0, 10.0],
      limit: 1_000_000.0, streams: 2)
    2.times { throttle.slot {} }

    assert_equal 2, throttle.allowed
  end

  def test_the_allowance_never_falls_below_one_download
    # One stream is the floor, and it is a limit rather than a target — pip has no rate control,
    # so a single very large wheel cannot be slowed by anything here.
    throttle = driven(readings: [0, 100_000_000, 200_000_000, 300_000_000],
      moments: [0.0, 10.0, 20.0, 30.0], limit: 1_000_000.0, streams: 1)
    3.times { throttle.slot {} }

    assert_equal 1, throttle.allowed
  end

  def test_the_allowance_never_rises_above_the_process_stream_count
    # A ceiling that is being met comfortably must not invent concurrency the operator never
    # allowed — the worker count is the maximum it was configured with.
    throttle = driven(readings: [0, 1, 2, 3, 4], moments: [0.0, 10.0, 20.0, 30.0, 40.0],
      limit: 1_000_000.0, streams: 2)
    4.times { throttle.slot {} }

    assert_equal 2, throttle.allowed
  end

  def test_a_counter_that_cannot_be_read_changes_nothing
    # Not knowing the speed is not evidence for loosening or tightening the ceiling.
    throttle = driven(readings: [nil, nil, nil], moments: [0.0, 10.0, 20.0],
      limit: 1_000.0, streams: 3)
    2.times { throttle.slot {} }

    assert_equal 3, throttle.allowed
  end

  def test_the_process_ceiling_is_off_until_somebody_sets_it
    # A limit is a choice about somebody's connection, so it is not a default here.
    before = AgentsFyiMiner::Bandwidth.limit

    assert_equal 0.0, before
    AgentsFyiMiner::Bandwidth.set_limit(2_000_000.0, streams: 6)
    assert_equal 2_000_000.0, AgentsFyiMiner::Bandwidth.limit
  ensure
    AgentsFyiMiner::Bandwidth.set_limit(before)
  end

  def test_configuring_the_ceiling_restarts_the_measurement
    # A rate taken across a change of ceiling measures two different things.
    throttle = driven(readings: [0, 20_000_000, 20_000_000], moments: [0.0, 10.0, 10.0],
      limit: 1_000.0, streams: 4)
    throttle.slot {}
    throttle.slot {}
    assert_equal 3, throttle.allowed

    throttle.configure(1_000_000.0, streams: 2)

    assert_equal 2, throttle.allowed
    assert_equal 1_000_000.0, throttle.limit
  end

  private

  # A throttle whose counter and clock are lists this test walks by hand.
  #
  # An index and a lock rather than an `Enumerator`: `Enumerator#next` runs a Fiber, and a
  # Fiber belongs to the thread that created it — so the concurrency test below, which enters
  # one slot on a second thread, fails with `fiber called across threads` instead of testing
  # the throttle. The last value repeats when a list runs out, so a control loop that reads
  # more often than the test listed values is still driveable.
  def driven(readings:, moments:, limit:, streams:)
    AgentsFyiMiner::Bandwidth::Throttle.new(
      limit: limit, streams: streams, read: stepper(readings), clock: stepper(moments)
    )
  end

  # One value per call, thread-safely, repeating the last when the list runs out.
  def stepper(list)
    remaining = list.dup
    lock = Mutex.new
    -> { lock.synchronize { remaining.length > 1 ? remaining.shift : remaining.first } }
  end
end
