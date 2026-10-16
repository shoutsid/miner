# frozen_string_literal: true

require "pathname"

module AgentsFyiMiner
  # What this container is pulling, measured from its own interface counter.
  #
  # This miner's network use is its *job* rather than an accident of it — it installs releases
  # in order to execute them — but two decisions need the size of that use and neither can be
  # read off the work queue. How long one install may take is a function of how many bytes it
  # has to move and how fast this machine moves them, because a killed install keeps nothing
  # (see `Envs.install_deadline`). And an operator on a link they share with everything else
  # wants a ceiling on what a background service takes from it. Both come from the same
  # reading, so both come from here.
  #
  # `/proc/net/dev` is this container's own counter, which is the number that matters: what
  # *this* process pulled, without counting the service's replies or the other clients'
  # separate traffic. It needs no privileges and no dependency to read.
  #
  # One caution that this module exists to make explicit, because it cost a session: **do not
  # measure this deployment's throughput by downloading into it while it is working.** Every
  # rate taken that way is a rate under contention that the measurement itself created, and it
  # describes a saturated pipe as if it were the link's capacity, while taking bandwidth from
  # the corpus the measurement is supposed to be about. Read the counter and the cache
  # instead; they are already the observation.
  module Bandwidth
    PROC_NET_DEV = Pathname.new("/proc/net/dev")

    # Bytes this container has received since it started, or nothing if unreadable.
    #
    # Loopback is excluded: it is traffic this container sent itself, and nothing in this image
    # talks to itself over a socket.
    #
    # `nil` rather than `0` on failure, deliberately. A counter that cannot be read is a
    # machine that cannot say how fast it is going, which is a different fact from going at no
    # speed — and the two produce opposite decisions wherever this is used.
    def self.received_bytes(path = PROC_NET_DEV)
      text = begin
        path.read(encoding: "utf-8")
      rescue SystemCallError, IOError
        return nil
      end

      total = 0
      read = false
      text.each_line do |line|
        name, separator, rest = line.partition(":")
        # The two banner lines: `Inter-|   Receive ... |  Transmit` and the column names under
        # it. Neither is an interface.
        next if separator.empty?

        interface = name.strip
        next if interface.empty? || interface == "lo"

        fields = rest.split
        next if fields.empty?

        begin
          total += Integer(fields[0], 10)
        rescue ArgumentError, TypeError
          next
        end
        read = true
      end
      read ? total : nil
    end

    # One look at the counter, and when it was taken.
    Reading = Data.define(:bytes, :at)

    # Bytes per second between two readings, or nothing when they cannot be compared.
    #
    # Two readings that cannot be compared are *not* a rate of zero, and the difference decides
    # behaviour: a rate of zero reads as "this machine is not moving bytes", while the truth is
    # "this machine cannot say". An unreadable counter and a counter that went *backwards* — a
    # container restarted under a counter that survives nothing — are both the second kind.
    def self.rate_between(earlier, later)
      return nil if earlier.bytes.nil? || later.bytes.nil?
      return nil if later.bytes < earlier.bytes

      elapsed = later.at - earlier.at
      return nil if elapsed <= 0

      (later.bytes - earlier.bytes) / elapsed.to_f
    end

    # A ceiling on what this process takes from the network, or no ceiling at all.
    #
    # Enforced by bounding **how many downloads run at once**, and that is a correction rather
    # than a first design. The first version delayed the *start* of an install while the recent
    # rate was over the ceiling, on the reasoning that fewer starts means less traffic.
    # Measured on the live miner it did not work: 2.60 MB/s against a 2.00 ceiling over ten
    # minutes, barely under the 2.82 MB/s the miner pulls unthrottled. The reason is that an
    # install already running is not slowed by delaying the next one — six workers were in
    # flight for most of the cycle, and their aggregate is set by what pip's sockets do rather
    # than by how long the queue behind them waits. Delaying starts makes a cycle longer; it
    # does not move the number the ceiling is about.
    #
    # So the count is what is adapted: while the measured rate is over the ceiling a stream is
    # taken away, and while it is comfortably under one is given back. That converges on
    # however many concurrent downloads this link carries without exceeding the ceiling. The
    # floor is one download, and one stream can still exceed the ceiling on its own — pip has
    # no rate control at all, so a single very large wheel is not something a userspace process
    # can slow down. A ceiling below the speed of one download is therefore unreachable, and
    # this says so rather than pretending.
    class Throttle
      # Bytes per second. 0 means no ceiling, which is the default: a limit is a choice an
      # operator makes about their own link, so it is off unless asked for. The same reasoning
      # as `MINER_WRITES_PER_HOUR`.
      attr_reader :limit

      # The most downloads that may run at once, which is what the ceiling is enforced against.
      # A caller that knows the worker count passes it, so an unthrottled process is never made
      # slower than it was.
      attr_reader :streams

      # `read` and `clock` are injected rather than called directly for one reason: a rate is
      # only a rate over an interval, and the only way to test a control loop that acts on a
      # rate is to hand it intervals. The suite drives them as lists of numbers — see
      # `bandwidth_test.rb`, which also says why measuring this by downloading is the wrong
      # method.
      def initialize(limit: 0.0, streams: 1, read: nil, clock: nil)
        @limit = limit
        @streams = [streams, 1].max
        @allowed = @streams
        @running = 0
        # `Bandwidth.method(...)` rather than `method(...)`: the counter is the module's own, and
        # `method(:received_bytes)` on an instance of this class looks for an *instance* method of
        # that name — which does not exist, so the module would fail to load the moment the
        # process-wide throttle below was built.
        @read = read || Bandwidth.method(:received_bytes)
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @last = nil
        # One lock and one condition for two pieces of state that have to move together: how
        # many downloads are running, and how many are allowed. The lock is what makes
        # `@running >= @allowed` a decision rather than a guess — two callers that read it
        # without it would both enter and the ceiling would be whatever the scheduler did.
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end

      # How many downloads may run at once right now.
      def allowed
        @mutex.synchronize { @allowed }
      end

      # Set the ceiling for this process, and start the control loop over.
      #
      # The previous reading is dropped rather than kept: it was taken under the old
      # configuration, and a rate measured across a change of ceiling would be a measurement of
      # two different things. Anybody waiting is woken, because the allowance may have risen.
      def configure(limit, streams: 1)
        @mutex.synchronize do
          @limit = limit
          @streams = [streams, 1].max
          @allowed = @streams
          @last = nil
          @condition.broadcast
        end
      end

      # Hold one download slot for the length of an install, and return what the block returned.
      #
      # Blocks while as many downloads are already running as the ceiling currently allows. On
      # the way out, the finished download's contribution is measured and the allowance adjusted
      # — once per completed download rather than once per call, because a rate needs an
      # interval to be a rate.
      #
      # With no ceiling configured this does nothing at all, so a process that was never asked
      # to be slowed is never slowed. That is also why the guard is *outside* the lock: the
      # common case is the unthrottled one, and it must not pay for a mutex.
      def slot(&block)
        raise ArgumentError, "a slot is held for a block; call it as `slot { … }`." unless block

        return yield if @limit <= 0

        @mutex.synchronize do
          @condition.wait(@mutex) while @running >= @allowed
          @running += 1
        end
        begin
          yield
        ensure
          @mutex.synchronize do
            @running -= 1
            adjust
            @condition.broadcast
          end
        end
      end

      private

      # Take a stream away while the rate is over the ceiling, give one back under it.
      #
      # Additive in both directions rather than anything cleverer: the quantity being controlled
      # is a property of a third party's sockets and of this host's link, so a control law that
      # assumed a model of either would be assuming more than the measurement supports. Called
      # with the lock held, which is what makes the read-modify-write of the allowance one step.
      def adjust
        reading = Reading.new(bytes: @read.call, at: @clock.call)
        previous = @last
        @last = reading
        return if previous.nil?

        rate = Bandwidth.rate_between(previous, reading)
        return if rate.nil?

        if rate > @limit
          @allowed = [1, @allowed - 1].max
        elsif rate < @limit / 2
          @allowed = [@streams, @allowed + 1].min
        end
      end
    end

    # The one ceiling this process runs under. Module-level because it describes a resource the
    # whole process shares — every install in every thread and every mode pulls from the same
    # link — and because the alternative is threading a throttle through the five places that
    # build an environment, which would make it look like a property of those calls rather than
    # of the deployment.
    THROTTLE = Throttle.new

    # Cap this process's downloads at this rate. 0 means no cap at all.
    def self.set_limit(bytes_per_second, streams: 1) = THROTTLE.configure(bytes_per_second, streams: streams)

    # The cap this process is running under, in bytes per second.
    def self.limit = THROTTLE.limit

    # Hold one download slot, for the length of one install: `Bandwidth.download_slot { … }`.
    #
    # Written with a body rather than as an endless method, because a method that takes a block
    # is the one shape `def x = y` is easiest to get wrong in — and the alternative to a block
    # here would be a lease object the caller has to release, which is the same rule spelled in a
    # way a caller can forget.
    def self.download_slot(&block)
      THROTTLE.slot(&block)
    end
  end
end
