# frozen_string_literal: true

require "fileutils"
require "thread"

require_relative "corpus"
require_relative "ecosystems"
require_relative "envs"
require_relative "errors"
require_relative "feed"
require_relative "ledger"
require_relative "log"
require_relative "rubyenvs"
require_relative "service"
require_relative "solving"
require_relative "verifying"
require_relative "wheelcache"

module AgentsFyiMiner
  # The verifier's loop: find reports nobody has confirmed, and confirm or dissent.
  #
  # The miner is one operator of this service; this is the second and third, and they exist
  # because of one rule in the service: a report's status reaches `resolved_verified` only when
  # *distinct operators other than its author* have reproduced it. Every report the miner files
  # is therefore unreachable from the top of the ladder by construction — the corpus had 164
  # reports, no verifications, and a ladder whose last rung no report could ever touch.
  #
  # It is the same shape of service as the miner and deliberately not the same loop. There is
  # nothing to schedule here: the work is "a report with a fix and no confirmation", the corpus
  # is asked for it, and the answer is a single release to install rather than two to compare.
  # So the loop is the feed, the backlog, the examination and the vote, and everything it shares
  # with the miner — the cursor walk, the ledger, the write budget — is shared rather than
  # copied (`Feed` is that sharing, and its own header says why).
  #
  # What it is *not* is a rubber stamp. A check that cannot be built casts no vote; a check whose
  # execution disagrees with the report records a dissent, which moves the corpus no closer to
  # `resolved_verified` and is the more valuable answer of the two.
  class Verifier
    # How many pages of the feed a cycle reads when it is only staying current. The
    # reconciliation walk on the first cycle is the long one, and it is bounded by
    # `Feed::DEFAULT_PAGES`.
    CATCHUP_PAGES = 20

    # How long an idle cycle waits before looking again, which is *not* the miner's ten minutes
    # and that is the point.
    #
    # The miner's ten minutes is how long it takes to notice a new release, and a release is a
    # rare event. A report is not: the miner files dozens an hour, and every one of them sits at
    # `resolved_unverified` until this loop reads the feed again. Measured on this deployment, a
    # ten-minute idle wait left 24 true reports waiting to be confirmed while nothing was wrong
    # — the corpus's own promotion latency, set by a constant chosen for a different job. A
    # minute costs one feed read and, only when there is something to do, one release to install.
    IDLE_SECONDS = 60

    # What one cycle confirmed, which is also what its log line says.
    class Stats
      attr_accessor :checked, :reproduced, :partial, :dissent, :no_claim, :skipped, :notes

      def initialize
        @checked = 0
        @reproduced = 0
        @partial = 0
        @dissent = 0
        @no_claim = 0
        @skipped = 0
        @notes = []
      end

      # One line, in the order the counters are read: how much was looked at, then what the
      # looking found. `checked` is first because it is the number that says whether the cycle
      # as a whole reached anything.
      def summary
        "#{@checked} report(s) checked: #{@reproduced} reproduced, #{@partial} partial, " \
          "#{@dissent} dissented, #{@no_claim} not checkable, #{@skipped} skipped"
      end
    end

    # One verifying operator, working continuously against one corpus.
    def initialize(session:, home:, state:, role:, ledger:, budget: 6,
                   workers: Service::DEFAULT_WORKERS, dry_run: false, heartbeat: nil,
                   writes_per_hour: Service::WRITES_PER_HOUR)
      unless Verifying::ROLES.include?(role)
        raise ArgumentError, "unknown verification role #{role.inspect}"
      end

      @session = session
      @home = Pathname.new(home)
      @state = Pathname.new(state)
      @role = role
      @ledger = ledger
      @budget = budget
      @workers = [workers, 1].max
      @dry_run = dry_run
      # Touched at the end of every cycle, for the same reason the miner's is: the process being
      # up says nothing about whether it is still working.
      @heartbeat = heartbeat.nil? ? nil : Pathname.new(heartbeat)
      # The miner's budget object rather than a second copy of it: one limit, one rolling
      # window, and one place that decides what fits.
      @writes = Service::WriteBudget.new(per_window: writes_per_hour)
      @stop = false
      # Resolved on the first cycle rather than here, so a corpus that is briefly unreachable does
      # not stop the service from starting.
      @operator_id = nil
      # Whether the corpus's existing backlog still has to be read: a report the feed passed
      # before this verifier existed is behind the cursor for ever, and it is exactly the report
      # nobody has confirmed.
      @reconcile = true
      # `release -> reason` for the builds that failed *while this cycle's checks were running*,
      # which is a set the ledger cannot answer for yet: the work list is built before any of it
      # runs, so two reports about one release are admitted together and the record the first one
      # writes is read by a worker that has not started. Bounded by the number of workers is what
      # `examine` promises; without this it was bounded by nothing at all, and a release that
      # cannot be built was installed once per report in the list.
      @failed_builds = {}
      @failed_lock = Mutex.new
    end

    attr_reader :session, :home, :state, :role, :ledger, :budget, :workers, :dry_run, :heartbeat,
      :writes
    attr_accessor :stop

    def logger = Log.logger("agents_fyi_miner.verifier")

    # --- the loop ------------------------------------------------------------

    # Work until stopped, or for a bounded number of cycles.
    #
    # The bound is tested on every path, not only the successful one: a bounded run that
    # `continue`d past its own check ran for ever once, and a test that hangs is the expensive way
    # to learn that. In Ruby the same trap has a second spelling — `next` inside a `rescue` arm is
    # how the bound gets skipped — so the check sits after the whole `begin`/`rescue`/`else`, where
    # every path passes through it.
    def run(cycles: 0, pace: true)
      Service.install_stop_handlers(self)
      total = Stats.new
      cycle = 0
      until @stop
        cycle += 1
        wait_for = IDLE_SECONDS
        begin
          stats = one_cycle
        rescue Errors::RateLimited => e
          wait_for = [e.retry_after, 1.0].max
          logger.warning("write quota spent; waiting %.0fs (%s)", wait_for, e.message)
          total.notes << format("rate limited, waited %.0fs", wait_for)
        rescue Errors::CollectionPaused => e
          # This verifier learns about a pause later than the miner does, and from a different
          # place: its work list is its own ledger of report ids, and an id carries no index — the
          # report does, when it is read. So it finds out when its first vote is refused, waits,
          # and finds out again. The alternative is a second request per cycle to ask which indexes
          # are open, which is a request spent to learn something the refusal already says.
          wait_for = [e.retry_after, 1.0].max
          logger.info("collection paused; waiting %.0fs (%s)", wait_for, e.message)
          total.notes << "collection paused: #{e.message}"
        rescue Errors::CorpusError => e
          logger.warning("corpus unreachable: %s", e.message)
          total.notes << e.message
        rescue StandardError => e
          # Same reason as the miner's: a background service that exits on an unexpected error
          # stops work everybody else is waiting on, and the failure it was doing is a report
          # somebody filed. The class and the first frame are the two things that make it a bug
          # report rather than a mystery, and `Log` has no traceback formatter to lean on.
          logger.error("cycle failed; continuing: %s: %s (%s)", e.class, e.message,
            e.backtrace&.first)
          total.notes << "cycle failed; see the log"
        else
          Service.accumulate(total, stats)
          logger.info("cycle %d: %s", cycle, stats.summary)
          stats.notes.each { |note| logger.info("  %s", note) }
          wait_for = stats.checked.positive? ? Service::CYCLE_SECONDS : IDLE_SECONDS
        end
        touch
        break if cycles.positive? && cycle >= cycles

        wait(wait_for, pace: pace)
      end
      total
    end

    # Say the loop is still turning, in a file something else can read.
    def touch
      return if @heartbeat.nil?

      FileUtils.mkdir_p(@heartbeat.dirname)
      @heartbeat.write(Time.now.to_f.to_s)
    end

    def wait(seconds, pace:)
      return unless pace

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      while !@stop && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        left = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.0].max
        sleep([5.0, left].min)
      end
    end

    # Read the corpus, check what nobody has confirmed, and vote.
    def one_cycle
      stats = Stats.new
      if @operator_id.nil?
        mine = @session.me
        @operator_id = mine.fetch("id", "").to_s
        @operator_id = nil if @operator_id.empty?
      end

      refresh(stats)
      # Environments are a cache with a budget — one release per report adds up faster than a pair
      # per package does — and they are pruned between cycles rather than during one, because
      # deleting a directory a worker is probing turns a real check into a fabricated one.
      removed, freed = Envs.prune(@home + "envs")
      if removed.positive?
        stats.notes << "pruned #{removed} environment(s), #{freed / (1024 * 1024)} MB"
      end
      # The shared wheel cache, which all three clients write and any of them may bound — it is a
      # cache, so an entry this deletes is one the next install fetches again rather than one
      # anything was relying on. See `WheelCache`.
      cached, cache_free = WheelCache.prune(WheelCache.cache_dir(@home))
      if cached.positive?
        stats.notes << "pruned #{cached} wheel cache entr(ies), #{cache_free / (1024 * 1024)} MB"
      end
      # The same abandoned scratch the miner sweeps: a check's install can be killed by its
      # timeout, and pip cannot clean up after that. See `Envs.sweep_scratch`.
      scratched, scratch_free = Envs.sweep_scratch(Envs.scratch_dir(@home))
      if scratched.positive?
        stats.notes << "swept #{scratched} abandoned scratch dir(s), " \
                       "#{scratch_free / (1024 * 1024)} MB"
      end
      # And the gem side's two, under the same home and the same rule: an operator that checks
      # gems has environments of its own to bound, and gem's scratch is what a killed install
      # leaves behind just as pip's is.
      gems, gem_free = RubyEnvs.prune(@home, budget: Envs::ENV_BUDGET_BYTES)
      if gems.positive?
        stats.notes << "pruned #{gems} gem environment(s), #{gem_free / (1024 * 1024)} MB"
      end
      gem_scratch, gem_scratch_free = RubyEnvs.sweep_scratch(@home)
      if gem_scratch.positive?
        stats.notes << "swept #{gem_scratch} abandoned gem scratch dir(s), " \
                       "#{gem_scratch_free / (1024 * 1024)} MB"
      end

      work = to_check(stats)
      check_all(work, stats) unless work.empty?
      unless @writes.unlimited?
        stats.notes << "#{@writes.remaining} write(s) left this hour"
      end
      Ledger.save(@ledger, @state)
      stats
    end

    # --- reading the corpus --------------------------------------------------

    # Walk the change feed forward, and remember as far as it got.
    def refresh(stats)
      if @reconcile
        seen = Feed.reconcile(@session, @ledger)
        if seen.positive?
          stats.notes << "reconciled #{seen} report(s) from the start of the feed"
        end
      end
      @reconcile = false
      seen = Feed.walk(@session, @ledger, since: @ledger.cursor_since,
        since_id: @ledger.cursor_id, pages: CATCHUP_PAGES)
      outstanding = @ledger.unresolved_seen.length
      stats.notes << "#{seen} change(s) read; #{outstanding} report(s) still unconfirmed"
    end

    # The reports worth checking, oldest first, with the claim to run.
    #
    # A report this operator cannot act on — its own, hidden, still open, already confirmed, or
    # with no claim that can be turned into an execution — is *dropped* from the backlog rather
    # than settled. The difference matters: an open report is not a refusal, it is a report that
    # will become checkable the moment somebody proposes a fix, and the change feed re-announces
    # it then. Settling it would be a service that quietly stopped looking.
    def to_check(stats)
      work = []
      inspected = 0
      theirs = 0
      waiting = 0
      unbuildable = 0
      settled = 0
      now = Time.now.to_f
      Feed.both_ends(@ledger.unresolved_seen).each do |report_id|
        break if work.length >= @budget || inspected >= @budget * 4

        # Before the lookup, and not counted against the cap: a check that failed wrote a retry
        # time, and a report this operator is not going to run this cycle should not cost a
        # request to the corpus to establish that. The delay is what keeps three attempts to ride
        # out an outage *spread out* — reading it was the half that was missing, so a release that
        # was briefly unavailable three cycles running settled the report as uncheckable for good,
        # in three minutes.
        unless @ledger.due_report?(report_id, now: now)
          waiting += 1
          next
        end
        # A report the feed says is already settled costs no request, and — the half that matters
        # — no *look*: `inspected` is what bounds the walk, so spending it on reports that cannot
        # be confirmed leaves the cycle stopping short of the ones that can. Measured on this
        # deployment, the as-reported verifier had 2,933 backlog entries, nearly all of them
        # already confirmed, and a report filed an hour ago sat behind every one of them.
        unless Verifier.confirming_status?(@ledger.status_of(report_id))
          @ledger.drop_seen(report_id)
          settled += 1
          next
        end
        inspected += 1
        begin
          report = @session.report(report_id)
        rescue Errors::CorpusError => e
          # Not a decision to make: a report that cannot be read is skipped this cycle, and the
          # loop above is bounded. The bound is only a bound if it is not spent on the same row
          # every time, though, so a *permanent* refusal — the corpus saying this report is not
          # there, which is what a deleted one answers for ever — is dropped, while a transient one
          # (an outage, a quota) is left for the retry that `due_report?` exists to schedule.
          @ledger.drop_seen(report_id) if e.permanent?
          logger.warning("could not read %s: %s", report_id, e.message)
          next
        end
        if Solving.ours?(report, @operator_id)
          theirs += 1
          @ledger.drop_seen(report_id)
          next
        end
        unless Verifying.needs_confirmation?(report, @operator_id)
          @ledger.drop_seen(report_id)
          next
        end
        claim = Verifying.claim_for(report)
        if claim.nil?
          # `needs_confirmation?` already refuses this, so reaching here is a bug rather than a
          # report shape; dropping it keeps one bad report from stopping the cycle.
          @ledger.drop_seen(report_id)
          next
        end
        # A release this machine has already established it cannot produce. The fact is the
        # release's, so the second report about it costs nothing: it is settled here rather than
        # paying for the install again — and, at the twenty-fourth, rather than paying for it
        # twenty-four times, which is what the count of `kornia 0.5.11` timeouts in one cycle was.
        blocked = unbuildable_for(claim)
        if blocked
          @ledger.record_report(report_id, outcome: Ledger::FAILED,
            note: "#{blocked} cannot be produced here"[0, 200])
          unbuildable += 1
          next
        end
        work << [report, claim]
      end
      if unbuildable.positive?
        stats.notes << "#{unbuildable} report(s) about a release this machine cannot produce"
      end
      if theirs.positive?
        stats.notes << "#{theirs} report(s) are this operator's own; a confirmation from its " \
                       "author is not one"
      end
      if waiting.positive?
        stats.notes << "#{waiting} report(s) waiting out a failed attempt"
      end
      if settled.positive?
        stats.notes << "#{settled} report(s) already settled; passed over without a request"
      end
      work
    end

    # --- checking ------------------------------------------------------------

    # Whether a report the feed reports at this status could still be confirmed.
    #
    # The one status a confirmation means anything at, plus the empty status — a report whose
    # status the feed has not told this client about yet is read rather than assumed, because
    # assuming is how a report nobody has checked gets skipped. Everything else — an open report
    # with no fix, one already confirmed, one hidden — is settled as far as *this* operator is
    # concerned, and the feed announces a change the moment one of them changes.
    def self.confirming_status?(status)
      ["", Verifying::UNVERIFIED_STATUS].include?(status)
    end

    # The release of this claim this machine cannot produce, if there is one.
    #
    # Either side of the differential counts: a check that cannot build the release the report came
    # from has nothing to compare against, and the install it would pay for is the same one that
    # already failed.
    def unbuildable_for(claim)
      [claim.version, claim.from_version].each do |version|
        next if version.nil? || version.to_s.empty?

        release = Envs.release_of(claim.library, version)
        return release if @ledger.cannot_build(release, machine: machine_for(claim))
      end
      nil
    end

    # Whose build a claim's release fact is about.
    #
    def machine_for(claim)
      ecosystem = Ecosystems::BY_NAME[claim.ecosystem] || Ecosystems::PYTHON
      ecosystem.machine
    end

    # Run several checks at once, and record every result on this thread.
    #
    # Same split as the miner's: the examining is a wheel install and an interpreter start, so
    # it is worth doing beside itself, while the ledger and the vote are one operator's
    # bookkeeping and stay here.
    def check_all(work, stats)
      admitted = []
      work.each do |item|
        if @writes.exhausted?
          stats.notes << Service::BUDGET_SPENT
          break
        end
        admitted << item
      end
      return if admitted.empty?

      # A new cycle's failures, so last cycle's cannot settle a report whose release this machine
      # may build now (a release is installed again after a rebuild, and the ledger's own record is
      # the durable half of this rule).
      @failed_lock.synchronize { @failed_builds = {} }
      workers = [[@workers, admitted.length].min, 1].max
      logger.info("checking %d report(s) on %d worker(s) as %s", admitted.length, workers, @role)
      results = Queue.new
      per_worker = (admitted.length.to_f / workers).ceil
      admitted.each_slice(per_worker).map do |slice|
        Thread.new do
          slice.each do |report, claim|
            begin
              verdict, error = examine(claim, report["id"].to_s)
            rescue StandardError => e
              logger.error("checking %s failed: %s: %s", report["id"], e.class, e.message)
              verdict = nil
              error = "#{e.class}: #{e.message}"
            end
            results << [report, claim, verdict, error]
          end
        end
      end.each(&:join)

      admitted.length.times do
        report, claim, verdict, error = results.pop
        record(report, claim, verdict, error, stats)
      end
    end

    # Install the releases the claim is about and run this operator's check.
    #
    # Everything it touches is guarded where it happens — the environment directory by
    # `Envs.build`, every scratch file by the suffix — so this is the one part of the cycle that is
    # safe to run beside itself. The suffix is the report's identity, not the role's: two reports
    # about one release are checked at the same moment by this operator, and they share an
    # environment. The whole id rather than a prefix of it, because a prefix is only unique until
    # two ids happen to share one.
    #
    # Which installer runs is the *claim's* answer, not this process's: a report about a gem is
    # checked by installing gem releases, and asking pip for `colorize` would fail to find a
    # package of that name and cast no vote on a report that is true.
    def examine(claim, report_id)
      suffix = "-#{@role}-#{report_id.delete("-")}"
      # Checked here as well as in `to_check`, because the work list is built before any of it
      # runs: twenty-four reports about one release are admitted together, so a record written by
      # the first one to fail is only read by a worker that has not started yet. That is the whole
      # of the measured cost — six `kornia 0.5.11` installs in one cycle of twenty-four, each timed
      # out in full — and reading the record at the point of the install is what bounds it by the
      # number of workers rather than by the number of reports.
      blocked = unbuildable_for(claim)
      blocked = sibling_failure(claim) if blocked.nil?
      blocked = nil if blocked.nil? || blocked.to_s.empty?
      if blocked
        return [nil, Errors::MinerError.new("#{blocked} cannot be produced here",
          permanent: true, release: blocked)]
      end

      installer = claim.is_ruby? ? method(:build_gem) : method(:build)
      [Verifying.check(claim, @role, build: installer, suffix: suffix), nil]
    rescue Errors::MinerError => e
      # The exception rather than its message: it carries whether asking again could change the
      # answer and which release it was about, and both halves are what `record` needs. Flattened
      # to a string, every failure read as "try again", and a release that cannot be installed on
      # this machine was paid for once per report that mentioned it.
      note_failed_build(e)
      [nil, e]
    end

    # Tell the other workers this release is not buildable, before `record` does.
    #
    # The worker that discovers it is the only one that could — the cycle's thread is waiting on
    # the join for that same thread — so the note is taken here rather than from the ledger record,
    # which lands a moment later.
    def note_failed_build(error)
      return unless error.respond_to?(:permanent?) && error.permanent?

      release = error.respond_to?(:release) ? error.release.to_s : ""
      return if release.empty?

      @failed_lock.synchronize { @failed_builds[release] ||= error.message[0, 200] }
    end

    # The release of this claim another worker failed to build a moment ago.
    #
    # Empty when nothing has, which is the common case: it is here so the install a worker is about
    # to pay for is not paid twice for one release in one cycle.
    def sibling_failure(claim)
      known = @failed_lock.synchronize { @failed_builds.dup }
      return "" if known.empty?

      [claim.version, claim.from_version].each do |version|
        next if version.nil? || version.to_s.empty?

        release = Envs.release_of(claim.library, version)
        return release if known.key?(release)
      end
      ""
    end

    # How a version becomes an environment.
    #
    # Passed into `Verifying` rather than imported there, so the module that decides what a claim
    # *means* never decides where environments live — and so a check that needs two releases asks
    # for both without knowing about the cache, the home directory or the lock that keeps two
    # workers out of one path.
    def build(library, version)
      Envs.build(library, version, home: @home + "envs")
    end

    # The same thing for a gem: install the release into the gem root.
    #
    def build_gem(library, version)
      RubyEnvs.build(library, version, home: @home)
    end

    # Write down what one check decided, and vote if it decided anything.
    def record(report, claim, verdict, error, stats)
      report_id = report["id"].to_s
      if verdict.nil?
        # A release that could not be installed or imported is not evidence about the report:
        # recorded as failed, so it is tried again rather than settled by an outage. Unless the
        # installer said the failure is a fact about the release — then it is recorded against the
        # *release*, because a release this machine cannot produce will not become producible by
        # asking again about twenty-three other reports that share it, and `to_check` settles those
        # without paying for the install.
        permanent = error.respond_to?(:permanent?) && error.permanent?
        release = error.respond_to?(:release) ? error.release.to_s : ""
        reason = error.to_s
        if permanent && !release.empty?
          @ledger.record_release(release, reason, machine: machine_for(claim))
          @ledger.record_report(report_id, outcome: Ledger::FAILED,
            note: "#{release} cannot be produced here: #{reason}"[0, 200])
          stats.skipped += 1
          logger.warning("unexaminable %s: %s", release, reason[0, 200])
          return
        end
        @ledger.record_report(report_id, outcome: Ledger::FAILED,
          next_at: Time.now.to_f + Service::REPORT_RETRY_SECONDS,
          note: reason[0, 200])
        stats.skipped += 1
        logger.warning("could not check %s: %s", report_id, reason)
        return
      end
      stats.checked += 1
      unless verdict.vote?
        if verdict.unreachable
          # Nothing about this report was established — the machine could not ask the release.
          # Recorded as a transient failure so `due_report?` brings it back, because the drop below
          # is permanent: nothing re-adds a report to the backlog except a change to the report,
          # and no record is written for `MAX_REPORT_ATTEMPTS` to work from. A killed install or a
          # timeout would otherwise retire a report that was true, for good, and the cycle's own
          # summary would call it "nothing executable here".
          @ledger.record_report(report_id, outcome: Ledger::FAILED,
            next_at: Time.now.to_f + Service::REPORT_RETRY_SECONDS,
            note: verdict.detail[0, 200])
          stats.skipped += 1
          logger.warning("%s could not be reached: %s", report_id, verdict.detail)
          return
        end
        # Nothing executable in this report's own words. Dropped rather than recorded, so a
        # revision of it is picked up when it arrives.
        @ledger.drop_seen(report_id)
        stats.no_claim += 1
        logger.info("%s: no claim to check (%s)", report_id, verdict.detail)
        return
      end
      if @dry_run
        # The evidence, not a summary of it: a dry run exists to be read before anything is
        # written, and what gets written *is* the evidence.
        logger.info("would vote %s on %s: %s", verdict.outcome, report_id, verdict.executed)
        Verifier.count(stats, verdict.outcome)
        return
      end
      unless @writes.allow
        @ledger.drop_seen(report_id)
        stats.notes << Service::BUDGET_SPENT
        return
      end
      begin
        @session.verify(report_id, Verifying.payload(verdict, claim, @role))
      rescue Errors::RateLimited
        # Nothing was written, so the report stays due and the loop waits the quota out; marking it
        # failed here would retry it in six hours.
        raise
      rescue Errors::CollectionPaused
        # The same reasoning as the quota above and one more: the handler below records a verdict
        # about this report, and a pause is not a verdict about a report. Written from here, the
        # retry it schedules would outlast a pause that lifts in minutes.
        raise
      rescue Errors::CorpusError => e
        @ledger.record_report(report_id, outcome: Ledger::FAILED,
          next_at: Time.now.to_f + Service::REPORT_RETRY_SECONDS,
          note: e.message[0, 200])
        stats.skipped += 1
        logger.warning("could not record a vote on %s: %s", report_id, e.message)
        return
      end
      @ledger.record_report(report_id, outcome: verdict.outcome, note: verdict.detail[0, 200])
      Verifier.count(stats, verdict.outcome)
      logger.info("%s on %s (%s): %s", verdict.outcome, report_id, @role,
        verdict.detail.to_s.empty? ? claim.subject : verdict.detail)
    end

    # One check's outcome, in the counter the cycle's summary reads.
    #
    # One place for the mapping, because a dry run and a real vote must agree about what they did: a
    # run that reported different totals depending on whether it was allowed to write would be a run
    # whose summary cannot be trusted to describe the work.
    def self.count(stats, outcome)
      if outcome == Ledger::REPRODUCED
        stats.reproduced += 1
      elsif outcome == Ledger::PARTIAL
        stats.partial += 1
      else
        stats.dissent += 1
      end
    end

    private :build, :build_gem, :record, :examine, :check_all, :to_check, :refresh, :touch, :wait,
      :note_failed_build, :sibling_failure, :unbuildable_for, :machine_for
  end
end
