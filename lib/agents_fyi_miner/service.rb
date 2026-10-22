# frozen_string_literal: true

require "fileutils"
require "pathname"
require "set"
require "thread"

require_relative "advisories"
require_relative "bandwidth"
require_relative "corpus"
require_relative "ecosystems"
require_relative "envs"
require_relative "errors"
require_relative "feed"
require_relative "ledger"
require_relative "log"
require_relative "pair"
require_relative "planner"
require_relative "rubyversions"
require_relative "rubyindex"
require_relative "solving"
require_relative "versions"

module AgentsFyiMiner
  # One miner, working continuously against one corpus.
  #
  # The long-running form of this client: mine, solve, sleep, repeat, and survive being restarted.
  # Every other entry point is a *run* — invoked for a purpose, finished in an hour, and allowed to
  # hold its whole plan in memory. This one runs for weeks, it is restarted by a deploy, an upgrade
  # or a power cut, and it shares one write quota with every operator on the service. Three facts,
  # and the design follows from each:
  #
  # * the plan lives in the ledger, not in memory, so a restart resumes rather than restarts;
  # * the corpus is read before it is written to — what is worth working on is a property of the
  #   corpus, and the miner is the only part of the system that can ask;
  # * nothing is written in a tight loop. The quota is 60 writes an hour and the miner paces itself
  #   well under it, because a miner that spends the service's protection on itself has made the
  #   service worse for the callers it exists to help.
  #
  # The cycle is deliberately short and its output is a line per step. A background service whose
  # progress cannot be read from its logs is one that either looks dead or looks busy, and both are
  # indistinguishable from broken.
  class Service
    # How long between cycles when there is work, and when there is not.
    #
    # No wait at all between cycles that did something, because there is no reason to have one: a
    # cycle is minutes of interpreter starts, and pausing afterwards only makes the corpus grow more
    # slowly. The work is self-limiting — the plan is built from what has not been examined, so a
    # cycle that finishes the last of it returns immediately with nothing to do and lands in the
    # idle wait below.
    #
    # The idle wait is not a throttle either. It is what a cycle with nothing left does instead of
    # busy-looping the corpus's change feed: the watchlist is finite, and the next thing that makes
    # work is a release being published or somebody filing a report. Ten minutes is how long it
    # takes to notice.
    CYCLE_SECONDS = 0
    IDLE_SECONDS = 10 * 60

    # What a failed pair waits before it is tried again. A package that could not be installed
    # because the index was briefly unavailable is worth retrying in an hour; one that cannot be
    # imported at all will fail the same way, and the attempt ceiling in the ledger is what stops
    # that costing for ever.
    RETRY_SECONDS = 60 * 60

    # How long a report waits after a failed attempt. Longer than a pair's, because a report is
    # somebody else's question and answering it twice in an hour is worse than answering it
    # tomorrow.
    REPORT_RETRY_SECONDS = 6 * 60 * 60

    # How many writes this miner allows itself in an hour. Zero is no limit.
    #
    # This is off by default, deliberately. It began as a fraction of the service's write quota, on
    # the reasoning that one machine should not spend the whole allowance — and that reasoning was
    # about a *scarce* quota, which it no longer is. With the service's limit set far above what any
    # honest client reaches, the only thing a self-imposed cap does is make the corpus grow more
    # slowly than the work the miner has already done. What actually bounds the writes is the work:
    # a finding is filed when a release really removed something, which is a handful per release, so
    # a run of three hundred crossings is a few dozen writes.
    #
    # The mechanism stays because it is the right one to have in hand if this ever needs holding
    # back — `--writes-per-hour` turns it on — and because a limit that is a *choice* rather than an
    # accident should be visible in the code that has it.
    WRITES_PER_HOUR = 0

    # The window those writes are counted over.
    WRITE_WINDOW_SECONDS = 3600

    # How much of the corpus the once-per-process reconciliation walk reads. Bounded because it is
    # somebody else's corpus and its size is not this service's to decide: 20,000 reports at the
    # 200 a page the feed serves is a few dozen reads against a quota of 600 a minute, and past
    # that the backlog is "the most recent many thousand reports", which is stated here rather
    # than discovered by a walk that never returns. It is a few times the corpus this deployment
    # holds, so a reconciliation reaches the reports it exists to pick up.
    RECONCILE_PAGES = 100

    # How many releases one facts write carries. The service takes at most 500 per request
    # (`releases.MAX_FACTS_PER_REQUEST`, which the discovery document also states) and refuses a
    # longer list, so this is a page size and not a preference: a gem whose history is longer is
    # sent in several requests, in order. The same shape as `Cli::QUEUE_PAGES` — a bound the
    # service serves, mirrored here so the client pages to it rather than discovering it by being
    # refused.
    REQUIREMENTS_PAGE = 500

    # How many cached gems' requirements one cycle may settle. A bound on a *cycle*, not on a
    # position: the set is a few hundred requests against a 60,000/hour write quota, so the pass
    # wants to finish in minutes rather than to ration itself — it exists to repair a gap left by
    # pushing facts only where the planner read a history, and the reason it is bounded at all is
    # that a pass over every cached gem must not put the mining it runs beside behind it.
    REQUIREMENTS_SETTLE_PER_CYCLE = 100

    # How long between reads of the reviewed advisory set. Six hours: the source changes as
    # advisories are published and withdrawn, and a lead is the smallest thing this miner works on,
    # so there is nothing to gain from reading it more often — the fetch is cached on the volume,
    # which means calling this every cycle costs a `stat` and not a request.
    ADVISORIES_REFRESH_SECONDS = 6 * 3600

    # How long a *failed* read waits before it is tried again.
    #
    # Not the refresh window: a refusal is the one case where waiting the full six hours is wrong,
    # because the refusal is usually momentary — the unauthenticated GitHub API allows sixty requests
    # an hour, and a read is about twelve — and the alternative to retrying is six hours without
    # leads for a failure that has already passed. Half an hour keeps a persistent outage to a couple
    # of requests an hour while still recovering from a rate limit within the hour it resets.
    ADVISORIES_RETRY_SECONDS = 30 * 60

    # Said when the miner stops itself because its allowance is spent.
    BUDGET_SPENT = "write budget spent; leaving the rest for the next cycle"

    # How many upgrades the miner examines at once.
    #
    # The work is one wheel install and two interpreter starts per candidate, against packages the
    # miner has never seen, so it is almost entirely spent waiting on a child process — one pair at
    # a time left most of the host idle and made the corpus grow at the speed of a single install.
    # Six is chosen against the container's own CPU allowance rather than the host's core count:
    # past that, installs contend for the same cores and each pair gets slower without the aggregate
    # getting faster.
    #
    # It is also the divisor in `Envs.install_deadline`, because these workers contend for the link
    # as much as for cores: six installs pulling at once is what makes each of them too slow to
    # finish a large wheel inside any flat timeout.
    DEFAULT_WORKERS = 6

    # A ceiling on what this container downloads, in MB per second. 0 means none.
    #
    # Off by default, and enforced only when asked for, for the same reason `WRITES_PER_HOUR` is:
    # the link belongs to whoever runs this, and how much of it a background service may take is
    # their decision rather than a default this code should assume. Measured on the deployment this
    # was written for, the miner pulls about 2.8 MB/s while mining — set this below that to leave
    # room for everything else, and expect the corpus to grow proportionally slower.
    #
    # One honest limit: this bounds how many downloads run at once, not how fast any one of them
    # goes. pip reads as fast as its socket allows and offers no rate control, so a single very
    # large wheel can still exceed this on its own. See `Bandwidth::Throttle`.
    DOWNLOAD_MBPS = 0.0

    # The corpus's writes, as a number this process decides rather than one the service does.
    #
    # Held by the service rather than inferred from a 429, because the difference is which side of
    # the limit the miner stops on: a 429 is the service refusing a write it has already received,
    # and a budget is the miner not making one.
    #
    class WriteBudget
      attr_reader :per_window, :window, :spent

      def initialize(per_window: WRITES_PER_HOUR, window: WRITE_WINDOW_SECONDS)
        @per_window = per_window
        @window = window
        # Not tracked at all when there is no limit: a window that grows by every write the service
        # makes would be a slow memory leak in a process that runs for weeks, and there is nothing
        # to count towards.
        @spent = []
      end

      # Whether this budget is really an absence of one.
      def unlimited? = per_window <= 0

      # Whether the allowance is used up, asked without spending from it.
      def exhausted?(now: nil)
        !unlimited? && remaining(now: now).zero?
      end

      def remaining(now: nil)
        return per_window.zero? ? 0 : per_window if unlimited?

        moment = now.nil? ? Time.now.to_f : now
        @spent = live(moment)
        [per_window - @spent.length, 0].max
      end

      # Whether one more write fits, reserving it if so.
      #
      # Reserving rather than reporting: the caller is about to write, and a check that only read
      # the number would let two findings in the same cycle both be told the last slot was free.
      def allow(now: nil)
        return true if unlimited?

        moment = now.nil? ? Time.now.to_f : now
        @spent = live(moment)
        return false if @spent.length >= per_window

        @spent << moment
        true
      end

      private

      # The writes still inside the window — a *rolling* one rather than a counter reset on the
      # hour: a counter would let the miner spend its allowance at ten to the hour and the whole of
      # it again at the hour, which is twice the burst it meant to allow.
      def live(now) = @spent.select { |moment| now - moment < window }
    end

    # What one cycle did, which is also what the next one's log line says.
    class Stats
      # The counters, in one list, because `Service.accumulate` adds a run's cycles up generically —
      # there are two loops with two different `Stats` (the miner's and the verifier's), and a
      # second copy of this list would be a place for a new counter to be silently forgotten.
      COUNTERS = %i[pairs_mined findings filed answered skipped unexaminable].freeze

      attr_accessor(*COUNTERS)
      attr_reader :notes

      def initialize
        COUNTERS.each { |name| instance_variable_set("@#{name}", 0) }
        @notes = []
      end

      def summary
        line = "#{pairs_mined} pair(s) mined, #{findings} finding(s), #{filed} filed, " \
               "#{answered} report(s) answered, #{skipped} skipped"
        # Skips that are *not* skips: the environment could not produce the release at all, so the
        # pair is settled rather than retried. Counted apart from `skipped` because the two want
        # opposite responses from a reader — a transient skip rate is the network, and this one is a
        # fact about the package's releases — and because a cycle that spent its whole pair budget
        # here looks, in every other number, exactly like one that examined twelve pairs and found
        # nothing.
        line += " (#{unexaminable} of them unexaminable here)" if unexaminable.positive?
        line
      end
    end

    attr_reader :session, :home, :state, :watchlist, :ledger, :ecosystems, :watchlists, :ledgers,
      :budget, :report_budget, :dry_run, :heartbeat, :writes, :workers,
      :requirements_settled, :requirements_attempted, :operator_id
    attr_accessor :stop

    def initialize(session:, home:, state:, watchlist:, ledger:, budget: Planner::DEFAULT_BUDGET,
                   report_budget: 1, dry_run: false, heartbeat: nil,
                   writes_per_hour: WRITES_PER_HOUR, workers: DEFAULT_WORKERS,
                   ecosystems: nil, watchlists: nil)
      @session = session
      @home = Pathname.new(home)
      @state = Pathname.new(state)
      @watchlist = watchlist
      @ledger = ledger
      # Which indexes this process mines. Each one brings its own watchlist and its own
      # ledger: a pair and a release are identified by name and versions, a name can exist in
      # two indexes, and one file holding both would let a gem settle a package's pair.
      @ecosystems = (ecosystems || [Ecosystems::PYTHON]).to_a
      @watchlists = { @ecosystems.first.name => watchlist.to_a }
      # Gems whose declared Ruby requirements this process has already pushed; the write is
      # idempotent, so this only saves repeating a request.
      @requirements_settled = Set.new
      # What the gap-filling walk has already looked at. Separate from the set above because the two
      # answer different questions: "the corpus can answer for this gem" and "this walk has spent
      # its turn on this gem". A gem whose document is not readable settles neither, and without
      # this the walk would re-examine it first every cycle and starve the gems behind it.
      @requirements_attempted = Set.new
      (watchlists || {}).each { |name, names| @watchlists[name] = names.to_a }
      @ledgers = { @ecosystems.first.name => ledger }
      @budget = budget
      @report_budget = report_budget
      @dry_run = dry_run
      # Touched at the end of every cycle. Its age is the only honest liveness signal this container
      # has: the process being up says nothing about whether it is still working, and a miner that
      # silently stopped mining looks exactly like one that is thinking.
      @heartbeat = heartbeat.nil? ? nil : Pathname.new(heartbeat)
      @writes = WriteBudget.new(per_window: writes_per_hour)
      # How many upgrades are examined at once. See `mine_all`: the work is subprocess-bound, so
      # this is the only dial that makes the corpus grow faster, and everything else in the loop is
      # deliberately single-threaded.
      @workers = [workers, 1].max
      @stop = false
      # What this miner pulled per second over the last cycle, and the raw reading the next one
      # subtracts from. Kept here rather than measured on demand so the window is a cycle — minutes
      # of installs, rather than however long that particular call happened to take.
      @rate = nil
      @meter = nil
      # Resolved on the first cycle rather than in the constructor, so a corpus that is briefly
      # unreachable does not stop the service from starting.
      @operator_id = nil
      # The reviewed advisories this process last read, grouped by gem, and when it read them.
      # In memory rather than in the ledger: a lead changes nothing that survives a restart, and
      # the picture itself is cached on the volume, so a fresh process re-reads it from there.
      @advisory_leads = {}
      @advisories_at = nil
      # Whether the corpus's existing backlog still has to be read. In memory rather than in the
      # ledger: it is a fact about this process, and one stored anywhere else would be a flag that
      # could get stuck on.
      @reconcile = true
      @log = Log.logger("agents_fyi_miner.service")
    end

    # Work until stopped, or for a bounded number of cycles.
    #
    # `cycles` and `pace` are what make this testable at all: a service whose loop can only be
    # entered for the rest of time can be tested by starting it and hoping, which is not a test.
    # `pace: false` removes the waiting rather than shortening it, so a test asserts the loop and
    # the interval is not tested at all.
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
          @log.warning("write quota spent; waiting %.0fs (%s)", wait_for, e)
          total.notes << format("rate limited, waited %.0fs", wait_for)
        rescue Errors::CollectionPaused => e
          # Not an outage and not a quota: an index this miner works is not taking new evidence, and
          # the reason is a person's rather than a load's. Info rather than warning because nothing
          # is wrong and nothing is lost — the pairs that could not be filed are still unsettled, so
          # the work is there when the pause lifts — and the wait is the interval the service asked
          # for, which is minutes to hours rather than the idle cycle's ten minutes.
          wait_for = [e.retry_after, 1.0].max
          @log.info("collection paused; waiting %.0fs (%s)", wait_for, e)
          total.notes << "collection paused: #{e}"
        rescue Errors::CorpusError => e
          # After the pause branch rather than instead of it: a pause *is* a `CorpusError`, so this
          # one has to come second or it swallows the refusal and waits the idle cycle. An
          # unreachable corpus is still not a reason to exit — the service is supposed to be here
          # when it comes back — and it is the branch that names the trouble in the cycle's notes,
          # which is the only place a reader sees it.
          @log.warning("corpus unreachable: %s", e)
          total.notes << e.message.to_s
        rescue StandardError => e
          # The last resort, and it exists for one reason: a background service that exits on an
          # unexpected error stops the work everybody else is waiting on, and the alternative to
          # surviving it is a container that restarts in a loop and mines nothing. The traceback is
          # logged in full, so a real bug is still loud — but a transient one costs a cycle instead
          # of the process.
          @log.error("cycle failed; continuing: %s: %s", e.class, e.message)
          Array(e.backtrace).each { |line| @log.error("  %s", line) }
          total.notes << "cycle failed; see the log"
        else
          Service.accumulate(total, stats)
          @log.info("cycle %d: %s", cycle, stats.summary)
          # The plan and the reasons are the only way to tell a service that is thinking from one
          # that is stuck: the totals alone look the same either way.
          stats.notes.each { |note| @log.info("  %s", note) }
          # Waiting ten minutes is right for a cycle with nothing to do and wrong for one that spent
          # its pair budget learning that a release cannot be built here. The second is progress —
          # each fact retires every crossing through that release — and treating it as idleness
          # would take hours to work through a backlog of hundreds, ten minutes a batch.
          busy = stats.pairs_mined.positive? || stats.answered.positive? ||
                 stats.unexaminable.positive?
          wait_for = busy ? CYCLE_SECONDS : IDLE_SECONDS
        end
        touch
        break if cycles.positive? && cycle >= cycles

        wait(wait_for, pace: pace)
      end
      total
    end

    # Read the corpus, decide, work, and write down what happened.
    def one_cycle
      stats = Stats.new
      sample_rate
      if @operator_id.nil?
        id = @session.me["id"].to_s
        @operator_id = id.empty? ? nil : id
      end

      refresh_ledger(stats)
      # Room is made before deciding what to do, not after, and for *every* index this process
      # mines: each has its own environments, its own download cache and its own install scratch,
      # and each of those has a budget. See `Ecosystems`: the Python side answers with three caches
      # and the Ruby side with two, and the labels come back from the ecosystem so the cycle's
      # report reads the same way for both.
      @ecosystems.each do |ecosystem|
        ecosystem.prune(@home, budget: Envs::ENV_BUDGET_BYTES).each do |label, removed, freed|
          stats.notes << "pruned #{removed} #{label}, #{freed / (1024 * 1024)} MB" if removed.positive?
        end
      end
      # A build killed by its timeout cannot remove its own working directory, so some of every
      # cycle's installs leave one behind. See `sweep_scratch`.
      @ecosystems.each do |ecosystem|
        ecosystem.sweep(@home).each do |label, removed, freed|
          stats.notes << "swept #{removed} #{label}, #{freed / (1024 * 1024)} MB" if removed.positive?
        end
      end
      # Before the plan, because the plan is where the old push happened and this is the pass that
      # reaches the gems it does not: a document on this volume is a fact this deployment has already
      # read, and the corpus should be able to answer for it whether or not the schedule ever calls
      # it up again.
      settled = settle_cached_requirements(REQUIREMENTS_SETTLE_PER_CYCLE)
      if settled.positive?
        stats.notes << "recorded Ruby requirements for #{settled} cached gem(s)"
      end
      # On a slow clock, and before the plan: a reviewed advisory is one of the three inputs the
      # order is built from, so reading it after the plan would be a cycle behind.
      refresh_advisories(stats)
      # One plan per index, because a plan is an order over one index's watchlist: merging
      # them would have to compare a package's score with a gem's, and the two queues were
      # built by the service's own ranking per index. The reports are answered once — they
      # belong to the corpus rather than to an index — and only the first plan is asked for
      # them while the solver is Python-only.
      #
      # The pair budget is *divided* rather than given to each index, and that is a fairness
      # decision with a measured reason: `budget` bounds a cycle's length, so handing the whole of
      # it to every index would multiply the cycle by the number of indexes. Handing it all to the
      # first is what a single-index miner did, and it starves the rest — the Ruby pairs would sit
      # behind twenty-four Python installs, which are minutes each, so a hundred-gem index would
      # take days to reach. The remainder stays with the first index, so a budget smaller than the
      # number of indexes still does something.
      work = nil
      pairs_by_index = []
      share = [@budget / @ecosystems.length, 1].max
      @ecosystems.each_with_index do |ecosystem, position|
        allowance = share +
                    (position.zero? ? @budget - (share * @ecosystems.length) : 0)
        answered = position.zero? ? to_answer(stats, limit: [@report_budget, 1].max * 4) : []
        planned = Planner.plan(
          reports: answered,
          watchlist: watchlist_for(ecosystem),
          ledger: ledger_for(ecosystem),
          history_for: ->(package, refresh:) { history(package, ecosystem: ecosystem, refresh: refresh) },
          cache_has: ->(package) { history_is_cached(package, ecosystem: ecosystem) },
          crossings_of: ecosystem.method(:crossings),
          # The leads are read here rather than fetched inside the planner: the planner is pure and
          # must stay testable without a network or a cache, so the caller hands it what it read.
          leads: leads_for(ecosystem),
          advisory_of: ecosystem.method(:advisory_pair),
          now: Time.now.to_f,
          budget: allowance,
          report_budget: @report_budget
        )
        work = planned if position.zero?
        stats.notes << "[#{ecosystem.name}] #{planned.describe}"
        # The plan names which packages it skipped; these say why, which is the difference between
        # "the miner is ignoring rich" and "rich is not on the index" — or, worse, "the index was
        # briefly unreachable and nobody can see that from the totals".
        planned.withheld.first(4).each do |package, reason|
          stats.notes << "[#{ecosystem.name}] withheld #{package}: #{reason}"
        end
        pairs_by_index << planned.pairs.to_a
      end
      # Interleaved rather than one index's pairs after another: workers take them in order, so
      # appending the first index's twelve would still put every gem behind twelve installs.
      # Alternating starts both indexes on the first free worker, and costs nothing when there is
      # only one index. `zip_longest` in the Python client, written out as a column-by-column walk
      # because Ruby's `Array#zip` truncates to the shortest.
      depth = pairs_by_index.map(&:length).max || 0
      pairs = (0...depth).flat_map do |column|
        pairs_by_index.filter_map { |group| group[column] }
      end
      # The budget is checked between items rather than only at the top, because a pair that turns
      # up fifteen findings would otherwise write all fifteen past the allowance in one burst. When
      # it runs out the rest of the plan is simply not done: nothing is marked examined, so the next
      # cycle resumes where this one stopped — and the environments are already built, so resuming
      # is seconds rather than the minutes the pair cost.
      (work.nil? ? [] : work.reports).each do |report|
        if @writes.exhausted?
          stats.notes << BUDGET_SPENT
          break
        end
        answer(report, stats)
      end
      mine_all(pairs, stats)
      if @writes.unlimited?
        stats.notes << "no write budget set"
      else
        stats.notes << "#{@writes.remaining} write(s) left this hour"
      end
      @ledgers.each { |name, one| Ledger.save(one, state_for(name)) }
      # After the save and not before: the ledger is a cycle's work and the picture is a courtesy,
      # so a service that refuses the report cannot cost the cycle it describes.
      @ledgers.each { |name, one| report_unexaminable(name, one, stats) }
      stats
    end

    # --- reading the corpus ----------------------------------------------------------------

    # Walk the change feed forward, and remember as far as it got.
    #
    # The cursor is a pair and both halves are stored: a timestamp alone is not a position when
    # several reports share one, which is exactly what a batch write produces.
    #
    # What the walk produces is not a work list but an inventory — every visible report id goes into
    # the ledger's backlog. The work list is then built from the backlog, not from this page, and
    # that distinction is the whole reason an old report gets answered: a cursor is a *position*,
    # and a report filed before this miner existed sits behind it for ever.
    def refresh_ledger(stats)
      if @reconcile
        # Once per process, and only when a cursor already exists: the cursor is an optimisation for
        # staying *current*, and a report the feed passed before this miner existed is behind it for
        # ever. Walking the feed from the beginning on the first cycle of a process is what makes the
        # solver a search for open questions in the corpus instead of a reader of recent changes —
        # and it is bounded, because the alternative is a start-up cost that grows with somebody
        # else's corpus.
        seen = Feed.reconcile(@session, @ledger, pages: RECONCILE_PAGES)
        stats.notes << "reconciled #{seen} report(s) from the start of the feed" if seen.positive?
      end
      @reconcile = false
      seen = walk(since: @ledger.cursor_since, since_id: @ledger.cursor_id, pages: 20)
      outstanding = @ledger.unresolved_seen.length
      stats.notes << "#{seen} change(s) read; #{outstanding} report(s) still unanswered"
    end

    # Read the feed forward, filing every report it mentions in the backlog.
    #
    # One line, because the walk is shared with the verifier: the cursor's rules — a pair rather than
    # a timestamp, taken from the page rather than the clock — are the same rules whether the reader
    # is about to answer a report or confirm one.
    def walk(since:, since_id:, pages:, advance: true)
      Feed.walk(@session, @ledger, since: since, since_id: since_id, pages: pages, advance: advance)
    end

    # The bodies of the reports worth a differential run, oldest first.
    #
    # A report is dropped from the backlog the moment a look shows nothing here will ever answer it
    # — hidden, this miner's own, or a question the differential cannot act on. That is not
    # tidiness: an entry kept for ever would be re-fetched every cycle to reach the same conclusion,
    # and the backlog would grow into the corpus it is supposed to search.
    def to_answer(stats, limit:)
      bodies = []
      inspected = 0
      ours = 0
      settled = 0
      Feed.both_ends(@ledger.unresolved_seen).each do |report_id|
        break if bodies.length >= limit || inspected >= limit * 4
        # A report the feed says is neither open nor awaiting reproduction costs no request, and no
        # *look*: `inspected` is the bound on the walk, so spending it on settled reports is what
        # keeps a deep backlog in front of the reports filed today.
        unless Solving.wants_status?(@ledger.status_of(report_id))
          @ledger.drop_seen(report_id)
          settled += 1
          next
        end
        inspected += 1
        begin
          report = @session.report(report_id)
        rescue Errors::CorpusError => e
          # A report that cannot be read is not a decision to make. A *transient* failure is skipped,
          # because dropping the entry would lose work over an outage — but a permanent one is the
          # corpus reading this request and declining it, so next cycle is the same request for the
          # same answer. Five reports that had been deleted were re-fetched every cycle for ever,
          # each one a warning in the log and one slot of the `limit * 4` looks above.
          @ledger.drop_seen(report_id) if e.permanent?
          @log.warning("could not read %s: %s", report_id, e)
          next
        end
        if is_ours?(report)
          # Not a question this miner can answer: the service counts a confirmation only from an
          # operator other than a report's author, so a vote here would record a row no number
          # reads. Dropped, so it is not re-read every cycle to reach that conclusion again.
          @ledger.drop_seen(report_id)
          ours += 1
          next
        end
        if report["hidden"] || !Planner.wanted?(report)
          @ledger.drop_seen(report_id)
          next
        end
        if report.fetch("ecosystem", "python") != "python"
          # A report about a gem. Not dropped from the backlog either — a later version of
          # this miner will answer it, and forgetting it would lose the question.
          next
        end
        bodies << report
      end
      if ours.positive?
        stats.notes << "#{ours} report(s) are this miner's own; a confirmation from its author is not one"
      end
      if settled.positive?
        stats.notes << "#{settled} report(s) already settled; passed over without a request"
      end
      bodies
    end

    # Whether this miner filed the report it is looking at.
    def is_ours?(report) = Solving.ours?(report, @operator_id)

    # --- one process, several indexes -------------------------------------------------------

    # The adapter for one ecosystem, by name or by object.
    def index(ecosystem)
      name = ecosystem.respond_to?(:name) ? ecosystem.name : ecosystem.to_s
      Ecosystems::BY_NAME.fetch(name, Ecosystems::PYTHON)
    end

    # This index's ledger, loaded from its own file on first use.
    #
    # A separate file rather than namespaced keys, because the two ledgers answer the same
    # questions about different subjects and a namespace is a detail every reader would have
    # to remember. The first ecosystem keeps the state path the operator configured — an
    # existing deployment's ledger is the PyPI one — and the rest get a sibling named for the
    # index, so a miner that gains Ruby does not lose what it knows about Python.
    def ledger_for(ecosystem)
      one = index(ecosystem)
      known = @ledgers[one.name]
      return known if known

      path = state_for(one.name)
      ledger = path.exist? ? Ledger.load(path) : Ledger.new
      # Whose facts this file holds. Set here rather than passed to every writer, because it is a
      # property of the index the ledger belongs to and not of the call: the Ruby ledger's records
      # are about this machine's Ruby, and before this they were stamped with whatever interpreter
      # the service happened to run.
      ledger.machine = one.machine
      @ledgers[one.name] = ledger
      ledger
    end

    # Where one index's ledger lives. The first keeps the configured path.
    def state_for(name)
      return @state if name == @ecosystems.first.name

      suffix = @state.extname
      suffix = ".json" if suffix.empty?
      @state.sub_ext("-#{name}#{suffix}")
    end

    # The packages this index works, in order.
    def watchlist_for(ecosystem) = (@watchlists[index(ecosystem).name] || []).to_a

    # The reviewed advisories this index's leads came from, grouped by gem.
    def leads_for(ecosystem) = @advisory_leads[index(ecosystem).name] || {}

    # Read the reviewed advisories and hand the service the picture, on a slow clock.
    #
    # Best-effort in every direction, and deliberately, for the reason `report_unexaminable` gives: a
    # lead only orders the queue's middle tier and names one crossing, so a start that cannot reach
    # GitHub or cannot reach the service with the picture is a start with a slightly less informed
    # queue rather than a start that failed. The leads a *cycle* uses come from the cached picture,
    # which is read here whether or not the post succeeds.
    #
    # Only RubyGems, because the reviewed RubyGems set is what the service ingests and a lead is keyed
    # by a gem's name.
    def refresh_advisories(stats, now: Time.now.to_f)
      return unless @advisories_at.nil? || (now - @advisories_at) >= ADVISORIES_REFRESH_SECONDS

      read = false
      @ecosystems.each do |ecosystem|
        next unless ecosystem.name == "ruby"

        leads = read_advisories(stats)
        next if leads.nil?

        read = true
        @advisory_leads[ecosystem.name] = Advisories.leads_by_library(leads)
        contribute_advisories(ecosystem, leads, stats)
      end
      # **A read that failed is not a read that happened.** Advancing the stamp unconditionally would
      # suppress the next attempt for the whole six-hour window, so one transient refusal — a rate
      # limit (the unauthenticated API allows sixty requests an hour), a timeout, a source having an
      # afternoon — would cost six hours of leads for a failure that a minute later would not occur.
      # That is the same shape `AGENTS.md` records for a retry delay that is written and never read,
      # and for a transient failure settled for good. A failure backs off for `ADVISORIES_RETRY_SECONDS`
      # instead, which is long enough that repeated failures during an outage cost a handful of
      # requests rather than a burst.
      @advisories_at = read ? now : now - ADVISORIES_REFRESH_SECONDS + ADVISORIES_RETRY_SECONDS
    end

    # The picture, from the cache unless the cache is stale. A source that cannot be read and a cache
    # that does not exist are both "no leads this time": the planner simply runs with none, which is
    # exactly what it did before advisories existed.
    def read_advisories(stats)
      leads = Advisories.picture(cache: @home + "index")
      stats.notes << "advisories: read #{leads.length} reviewed lead(s)"
      leads
    rescue *Advisories::UNREADABLE => e
      stats.notes << "advisories: could not be read: #{e.message}"
      nil
    end

    # **A quota refusal is caught here rather than re-raised, and that is not the swallow the miner's
    # trap lists.** The trap is about a filing path, where a swallowed `RateLimited` marks a pair
    # examined and loses the finding; here nothing is lost — the picture is cached, the next cycle
    # sends the same one, and the quota is surfaced by the next filing through the handler that knows
    # how long to wait. Re-raising would discard a cycle's reading for a request that is re-sent for
    # free, which is the same reasoning `report_unexaminable` is written on.
    def contribute_advisories(ecosystem, leads, stats)
      @session.contribute_advisories(leads, ecosystem: ecosystem.name)
      stats.notes << "advisories: contributed #{leads.length} lead(s) for #{ecosystem.name}"
    rescue Errors::CollectionPaused => e
      @log.info("not contributing the %s advisory picture: %s", ecosystem.name, e.message)
    rescue Errors::CorpusError => e
      @log.warning("could not contribute the %s advisory picture: %s", ecosystem.name, e.message)
    end

    # Tell the service what this index's machine cannot build, from the ledger that established it.
    #
    # Best-effort, the same way the breadth seed is: a queue whose tail is narrower than it could
    # be is not a reason to lose the cycle that produced the facts. A paused index is a decision
    # rather than a fault — info, with the reason, and the picture is simply not recorded.
    #
    # **`RateLimited` is caught here rather than re-raised, and that is not the swallow the miner's
    # own trap lists.** Nothing is lost by dropping this report: the facts are in the ledger, the
    # next cycle sends the same picture, and the quota is surfaced by the next filing through the
    # very handler that knows how long to wait. Re-raising would instead discard a cycle's summary
    # for a request that is re-sent for free.
    def report_unexaminable(name, ledger, stats)
      picture = ledger.unexaminable_picture
      @session.report_unexaminable(picture.fetch(:records), machine: picture.fetch(:machine),
        ecosystem: name)
      counted = picture.fetch(:records).length
      stats.notes << "[#{name}] reported #{counted} release(s) this machine cannot examine"
    rescue Errors::CollectionPaused => e
      @log.info("not reporting what %s cannot examine: %s", name, e.message)
    rescue Errors::CorpusError => e
      @log.warning("could not report what %s cannot examine: %s", name, e.message)
    end

    # One package's releases, from the cache unless the index may be asked.
    #
    # `refresh` is the planner's per-cycle allowance rather than a property of the package: the
    # schedule walks past every watchlist entry that has nothing to mine, and most of those have a
    # cached history, so the number of *looks* is unbounded while the number of *fetches* is not.
    def history(package, ecosystem:, refresh: true)
      one = index(ecosystem)
      releases = one.history(package, home: @home, refresh: refresh)
      record_requirements(package) if one.name == "ruby"
      releases
    end

    # Push what a gem's cached releases declare about Ruby, once per process.
    #
    # Returns whether the *corpus* is still usable — `false` means an outage, and the walk above
    # stops on it — rather than whether a request was made. The two ways of doing nothing have to be
    # told apart by the caller: a gem with an empty document has been answered as far as this pass is
    # concerned, while a gem whose page met an outage has not, and a walk that could not separate
    # them either stalls on the first empty document it meets or records half a history as a whole
    # one.
    #
    # Best-effort on purpose. The requirement is a fact about the release, not part of the miner's
    # own work, so a refused or failed push is logged and costs nothing else. A quota refusal is
    # re-raised: it is the one failure the loop acts on by waiting, and swallowing it would make the
    # miner look healthy while every later write is also refused.
    #
    # Paged, because one request is bounded and a gem's history is not: the service takes at most
    # `REQUIREMENTS_PAGE` releases per request, and the largest gems here declare thousands. Sending
    # the whole history in one body was refused for every gem past 500 releases — 422 on the item cap
    # or 413 on the body cap — so the facts for exactly the gems with the most to say were never
    # recorded.
    def record_requirements(package)
      return true if @requirements_settled.include?(package)

      # **Both fields from one document.** `RubyIndex` reads `/info/<gem>`, which carries each
      # release's Ruby floor *and* its runtime dependencies — the fact a Rails move turns on
      # (`devise 2.2.4` declares `railties ~> 3.1`) and the one the versions endpoint does not
      # have at all. One reading, one source, so a fact about a release cannot be assembled out
      # of two documents fetched at different times.
      facts = begin
        RubyIndex.release_facts(package, cache: @home + "index")
      rescue RubyIndex::NoDocument => e
        # Nothing cached and the index would not answer. The gem stays unsettled, for the
        # reason the empty mapping below states: a document unreadable when this ran is what
        # a later fetch fixes.
        @log.warning("could not read what %s declares: %s", package, e)
        return true
      end
      if facts.empty?
        # Not settled, and deliberately: an empty mapping means *nothing was read* —
        # `RubyIndex.release_facts` says so in its own docstring — not that the releases
        # declare nothing. A document that was unreadable when this ran is exactly what a later
        # fetch fixes, and settling it here would leave that fetch with nobody to carry it to the
        # corpus. The schedule path re-reads it; the walk keeps its own note of what it has looked
        # at.
        return true
      end
      pages = facts.sort.map do |version, fact|
        { "version" => version, "ruby_requirement" => fact["ruby_requirement"],
          "dependencies" => fact["dependencies"] }
      end
      pages.each_slice(REQUIREMENTS_PAGE) do |page|
        @session.record_release_facts(package, page)
      rescue Errors::RateLimited, Errors::CollectionPaused
        # Re-raised, both of them, and for the same reason: the handler below logs this and
        # carries on to the next gem, so a paused index would walk the whole set of cached gems
        # posting into a closed door and report each refusal as a warning about that gem.
        raise
      rescue Errors::CorpusError => e
        @log.warning("could not record %s's Ruby requirements: %s", package, e)
        # A 4xx is the corpus reading this gem and declining it, so a retry reaches the same
        # refusal and the gem is settled — a gem name past the route's 120 characters would
        # otherwise be asked about for ever. An outage is not, and stays unsettled so another
        # cycle retries it.
        @requirements_settled << package if e.permanent?
        return e.permanent?
      end
      @requirements_settled << package
      true
    end

    # Every gem whose RubyGems document this deployment has already read.
    #
    # The same directory `history` reads through, so the gap-filling pass below cannot disagree with
    # the schedule about which gems have been fetched.
    def cached_gems
      cache = @home + "index"
      return [] unless cache.directory?

      suffix = RubyVersions::CACHE_SUFFIX
      cache.children.map { |child| child.basename.to_s }
           .select { |name| name.end_with?(suffix) }
           .map { |name| name[0...-suffix.length] }
           .sort
    end

    # Push the requirements of gems whose documents are already on disk.
    #
    # The push used to happen only where the planner read a gem's history, which made the corpus's
    # facts a by-product of the mining schedule: a gem whose pairs were all mined, or which the plan
    # never reached, had its document on this volume and no requirement in the corpus. Measured on
    # the deployment when this was added — 466 cached gem documents, 445 gems recorded — and the
    # twenty-one missing were the largest and most popular: `activesupport`, `stripe`, `aws-sdk-ec2`,
    # `sorbet-runtime`, every gem whose history ran past the old one-request cap. The corpus had read
    # them and could not answer for any of them.
    #
    # So a stopped walk is not the same as a finished one: this one walks the gems rather than the
    # plan. It stops early only when the corpus is unavailable, and returns how many gems it newly
    # brought the corpus an answer for.
    def settle_cached_requirements(limit)
      settled = 0
      examined = 0
      cached_gems.each do |package|
        break if examined >= limit
        next if @requirements_attempted.include?(package)

        @requirements_attempted << package
        examined += 1
        already = @requirements_settled.include?(package)
        # The corpus is unavailable, so every later gem would meet the same answer. The quota path
        # re-raises above this; the rest of the set is left for the next cycle.
        break unless record_requirements(package)

        settled += 1 if !already && @requirements_settled.include?(package)
      end
      settled
    end

    # Whether this package's history is on disk, so asking the index would spend a fetch to learn
    # nothing. See `Planner.plan`: the walk's fetch budget is a bound on requests, and this is what
    # tells it which reads are free.
    def history_is_cached(package, ecosystem:) = index(ecosystem).history_is_cached(package, home: @home)

    # --- mining ----------------------------------------------------------------------------

    # Measure what this miner pulled since the last cycle.
    #
    # Once a cycle rather than continuously: a cycle is minutes of installs, which is a long enough
    # window for a rate to mean something and recent enough to describe the link as it is now.
    # Nothing is inferred from one reading — the first cycle of a process has no earlier one — and
    # `Envs.install_deadline` reads an unknown rate as a slow link rather than a fast one, because
    # that is the direction whose cost is an idle worker instead of a discarded download.
    def sample_rate
      reading = Bandwidth::Reading.new(bytes: Bandwidth.received_bytes, at: monotonic)
      previous = @meter
      @meter = reading
      return if previous.nil?

      rate = Bandwidth.rate_between(previous, reading)
      @rate = rate unless rate.nil?
    end

    # Build one release of a pair, allowing as long as its payload needs.
    #
    # The attempt count comes from the *pair* rather than from this build, because a retry is the
    # evidence that the priced deadline was too short. That is how a release which is cheap itself
    # and drags in a large dependency tree gets there: `Versions.release_size` prices only the
    # release's own files, since those are what the index hands over without another request, so its
    # first attempt is under-priced on purpose and the retry corrects for it. RubyGems publishes no
    # size at all, so that side is a flat ceiling that doubles per attempt — the difference lives in
    # the ecosystem, not here.
    def build(pair, version)
      one = index(pair.ecosystem)
      record = ledger_for(pair.ecosystem).pair(pair.package, pair.from_version, pair.to_version)
      attempts = record.nil? ? 0 : record.attempts
      deadline = one.deadline(pair.package, version, home: @home, rate: @rate,
        workers: @workers, attempts: attempts)
      if deadline > one.install_timeout
        # Worth a line, and only in this case: a deadline above the floor is the whole of the new
        # behaviour, and it is the release that used to be killed at five minutes with every byte it
        # moved discarded. Nothing logs the ordinary ones, because most installs are small and a line
        # each would bury this one.
        @log.info("allowing %ds for %s %s (%s)", deadline, pair.package, version, pair.ecosystem)
      end
      one.build(pair.package, version, home: @home, deadline: deadline, attempt: attempts)
    end

    # Examine several upgrades at once, and file what each found in order.
    #
    # The examining is what takes the time — a wheel install and two interpreter starts per
    # candidate, against a package the miner has never seen — and it is entirely subprocess-bound, so
    # most of it is one core idling while a child works. One pair at a time left seventeen of this
    # host's twenty cores unused and made the corpus grow at the speed of a single pip install.
    #
    # The *bookkeeping* stays on this thread, deliberately. The ledger is one file, the filings are
    # one operator's writes, and the counter that decides how much of a run gets filed is one number:
    # three things that would need locking if several threads touched them, and no speed at all to be
    # gained by it. So a worker returns what it found and this loop records it, which is also what
    # keeps the log in a stable order.
    def mine_all(pairs, stats)
      return if pairs.empty?

      # Admitted before anything is started, not checked as work finishes. An examination is minutes
      # of installs and interpreter starts, and doing one whose findings cannot be filed is worse
      # than not starting it: the pair would be re-examined next cycle for nothing. With no budget
      # set — the default — this admits everything and costs one comparison per pair.
      admitted = []
      pairs.each do |pair|
        if @writes.exhausted?
          stats.notes << BUDGET_SPENT
          break
        end
        admitted << pair
      end
      return if admitted.empty?

      workers = [[@workers, admitted.length].min, 1].max
      @log.info("examining %d upgrade(s) on %d worker(s)", admitted.length, workers)
      work = Queue.new
      admitted.each { |pair| work << pair }
      results = Queue.new
      threads = Array.new(workers) do
        Thread.new do
          loop do
            pair = begin
              work.pop(true)
            rescue ThreadError
              break
            end
            begin
              findings, error = examine(pair)
              results << [pair, findings, error, nil]
            rescue StandardError => e
              # A defect in the examining is a defect; it should cost the pair it was examining
              # rather than every pair in the batch and the cycle that ran them. Catching it here
              # rather than in `examine` keeps `examine` honest about the failures it knows about.
              results << [pair, nil, nil, e]
            end
          end
        end
      end
      # Consumed in completion order, so a slow package does not hold up the recording of the ones
      # behind it. Every result is recorded here, on the cycle's thread.
      admitted.length.times do
        pair, findings, error, raised = results.pop
        if raised
          @log.error("examining %s %s->%s failed: %s: %s",
            pair.package, pair.from_version, pair.to_version, raised.class, raised.message)
          Array(raised.backtrace).each { |line| @log.error("  %s", line) }
          ledger_for(pair.ecosystem).record_pair(
            pair.package, pair.from_version, pair.to_version,
            outcome: Ledger::FAILED,
            next_at: Time.now.to_f + RETRY_SECONDS,
            note: "#{raised.class}: #{raised.message}"[0, 200]
          )
          stats.skipped += 1
          next
        end
        record(pair, findings, error, stats)
      end
      threads.each(&:join)
    end

    # Build both releases and run the differential. No ledger, no network.
    #
    # Everything this does to shared state is guarded where it happens — the environment directory by
    # `Envs.build`, the scratch script by the probe suffix — so this is the one part of the cycle
    # that is safe to run beside itself.
    #
    # The error travels as the exception rather than as its message, because it carries two facts the
    # ledger needs and one of them it cannot re-derive: a release that cannot be built here is
    # permanent, and it is one fact about every pair that runs through it rather than one per pair.
    def examine(pair)
      one = index(pair.ecosystem)
      begin
        before = build(pair, pair.from_version)
        after = build(pair, pair.to_version)
        findings = one.findings(pair.package, pair.from_version, pair.to_version, before, after,
          suffix: "-#{pair.from_version}-#{pair.to_version}".tr("/", "_"))
      rescue Errors::MinerError => e
        return [[], e]
      end
      [findings, nil]
    end

    # Write down what one examination did, and file what it found.
    #
    # `error` is whatever stopped the examination: normally an `Errors::MinerError`, which carries
    # whether asking again could change the answer and which release it was about, and otherwise the
    # exception a caller's own defect raised — for which the safe reading is "try again", because
    # nothing has been established about the release.
    def record(pair, findings, error, stats)
      one = ledger_for(pair.ecosystem)
      if error
        stats.skipped += 1
        # Read tolerantly rather than assumed: normally it is an `Errors::MinerError`, but a caller
        # may hand this any failure of its own, and the safe reading of one that does not say is
        # "try again" — nothing has been established about the release.
        permanent = error.respond_to?(:permanent?) && error.permanent?
        release = error.respond_to?(:release) ? error.release.to_s : ""
        if permanent
          # Settled on this attempt rather than after three, and recorded against the *release*
          # rather than only against this pair. Without the second half the schedule answers the same
          # question once per crossing: `wrapt 1.13.3` cannot be built, so `1.13.3->1.13.4`,
          # `1.13.3->1.14.0` and ten more each pay for a fresh pip attempt and each spend one of this
          # cycle's pair slots on work that cannot happen — which is how a cycle ends up skipping nine
          # of its twelve pairs and filing nothing while examinable pairs wait behind them.
          stats.unexaminable += 1
          one.record_pair(pair.package, pair.from_version, pair.to_version,
            outcome: Ledger::UNEXAMINABLE,
            note: error.message.to_s[0, 200],
            release: release)
          @log.warning("unexaminable %s %s->%s: %s", pair.package, pair.from_version,
            pair.to_version, error.message.to_s[0, 200])
          return
        end
        one.record_pair(pair.package, pair.from_version, pair.to_version,
          outcome: Ledger::FAILED,
          next_at: Time.now.to_f + RETRY_SECONDS,
          note: error.message.to_s[0, 200],
          release: release)
        @log.warning("skip %s %s->%s: %s", pair.package, pair.from_version, pair.to_version,
          error.message.to_s[0, 200])
        return
      end

      outcomes = findings.map { |finding| @dry_run ? "filed" : file(finding, pair, stats) }
      filed = outcomes.count("filed")
      # Only a *deferred* outcome leaves work undone. A finding the corpus read and declined is
      # settled — re-examining the pair reaches the same refusal — while one that could not be sent
      # because the corpus was briefly unavailable is knowledge that is not in the corpus yet and must
      # not be quietly dropped by recording the pair as examined.
      held_back = outcomes.count("deferred")
      # A pair whose findings could not all be filed is *not* settled: the work was done and the
      # knowledge is not in the corpus yet, so marking it examined would lose it silently — and
      # re-deriving it is cheap next cycle, because both environments are already built.
      #
      # `FAILED` for a pair held back, `DONE` for one that filed something, and `EMPTY` for
      # one that examined cleanly and found nothing — the last of those is a result rather
      # than a failure, and it is what stops the schedule asking the same question every cycle
      # for ever. Three tests caught it at once (the pair's outcome, its yield, and how many
      # pairs a cycle settled), which is what a missing `positive?` looks like from outside.
      verdict = if held_back.positive?
        Ledger::FAILED
      elsif findings.empty?
        Ledger::EMPTY
      else
        Ledger::DONE
                end
      one.record_pair(
        pair.package, pair.from_version, pair.to_version,
        outcome: verdict,
        findings: findings.length,
        filed: filed,
        next_at: held_back ? Time.now.to_f + RETRY_SECONDS : nil,
        note: held_back ? "#{held_back} finding(s) not filed" : ""
      )
      stats.pairs_mined += 1
      stats.findings += findings.length
      stats.filed += filed
    end

    # One upgrade, examined and filed, with the ledger written either way.
    #
    # Nothing here raises: a service that exits because one package could not be installed is a
    # service that stops on the first hard package. The ledger records the failure, and the pair is
    # retried on a later cycle until the attempt ceiling settles it.
    #
    # Kept as the serial entry point because a caller that wants one pair examined — or that is
    # already inside a worker — should not have to build a pool to do it.
    def mine(pair, stats)
      findings, error = examine(pair)
      record(pair, findings, error, stats)
    end

    # File one finding and say what happened to it.
    #
    # Four outcomes rather than a count, because the caller's next move differs: `filed` is knowledge
    # in the corpus, `skipped` is the corpus answering that it already has it, `deferred` is a finding
    # that could not be sent and must be worked out again, and `refused` is the corpus reading this
    # finding and declining it, which re-deriving would only repeat.
    def file(finding, pair, stats)
      unless @writes.allow
        # Declines rather than raises. A spent allowance is not a failure of this filing, and raising
        # escaped the whole cycle — which is how a budget meant to slow the miner down instead threw
        # away the examinations running beside it. Admission is checked before an examination starts;
        # this is the backstop for a pair that produced more findings than the allowance had left.
        stats.notes << BUDGET_SPENT
        return "deferred"
      end
      begin
        outcome = @session.submit_mined(
          finding,
          from_version: pair.from_version,
          # When the release that breaks was published, read from the index this pair belongs to —
          # asked for once when the cache cannot say, because this is the only moment the fact can be
          # stored. A null here is permanent, and the column exists to answer what changed after a
          # reader's training data ends.
          published_at: index(pair.ecosystem).release_date(pair.package, pair.to_version, home: @home),
          pace: 1.0
        )
      rescue Errors::RateLimited
        # Not a filing failure: the quota is spent, and the loop knows how long to wait. Reached from
        # the service's own 429 rather than from this miner's budget, which is handled above.
        raise
      rescue Errors::CollectionPaused
        # The one handler in this file where swallowing the refusal would settle the pair: the
        # handler below returns an outcome, and the caller records that outcome as this pair's verdict
        # — so a pause would mark the pair examined and the finding would never be filed, which is the
        # loss `AGENTS.md` records for the quota meeting the same handler.
        raise
      rescue Errors::CorpusError => e
        @log.warning("could not file %s: %s", finding.title, e)
        stats.notes << "filing failed: #{e}"
        return e.permanent? ? "refused" : "deferred"
      end
      @log.info("%s %s", outcome, finding.title)
      outcome == "filed" ? "filed" : "skipped"
    end

    # --- solving ---------------------------------------------------------------------------

    # Attach an executed fix to somebody else's report, or say why not.
    #
    # Claimed before the work and released after it, in that order, because a differential run is
    # minutes of environment building: without a claim two miners derive the same fix and one of them
    # has wasted the work, which is the whole reason the corpus has claims.
    def answer(report, stats)
      report_id = report["id"].to_s
      if @dry_run
        @log.info("would answer %s", report_id)
        stats.answered += 1
        return
      end
      # A claim is a reservation on *unsolved* work, so it is taken only when there is a gap to fill.
      # Claiming first regardless looked right and was wrong in a way only a real service shows: the
      # corpus refuses a claim on a report that already carries a fix — deliberately, because such a
      # report is not waiting for anybody — so the solver bailed out with a 409 before it could reach
      # the reproduction it had been selected to give. Reproduction reserves nothing: the fix exists,
      # and somebody running it holds nobody up.
      claimed = false
      if Solving.needs_a_fix?(report)
        begin
          @session.claim(report_id)
          claimed = true
        rescue Errors::RateLimited, Errors::CollectionPaused
          # Both are re-raised: the branches below record a verdict about this report, a pause is not
          # one, and `no_mechanism` on the ledger would retire a question because an index was closed
          # for the afternoon.
          raise
        rescue Errors::CorpusError => e
          # Somebody else is on it. The ledger records it so the miner stops asking every cycle.
          @ledger.record_report(report_id, outcome: Ledger::NO_MECHANISM,
            next_at: Time.now.to_f + REPORT_RETRY_SECONDS,
            note: e.message.to_s[0, 200])
          stats.skipped += 1
          @log.info("%s is not available: %s", report_id, e)
          return
        end
      end

      begin
        # The report's own index. The solver is Python-only for now and the feed hands it only Python
        # reports, so this is the PyPI ladder — but the lookup is by the report's field rather than
        # assumed, so the day the solver learns Ruby this line is already right.
        history = self.history(report["library"], ecosystem: report.fetch("ecosystem", "python"))
      rescue *Planner::HISTORY_FAILURES => e
        # Retried rather than settled: an unreachable index is not a fact about this report,
        # and marking it `no_pair` would retire a question because the network was down.
        give_up(report_id, Ledger::FAILED, e.message.to_s, retry_instead: true, claimed: claimed)
        stats.skipped += 1
        return
      end

      pairs = Solving.pairs_for_report(report, history)
      if pairs.empty?
        give_up(report_id, Ledger::NO_PAIR, "no release line to compare", claimed: claimed)
        stats.skipped += 1
        return
      end

      pair = pairs.first
      begin
        before = build(pair, pair.from_version)
        after = build(pair, pair.to_version)
        # Through the index's own differential, like the mining path: the solver is settling a
        # claim about *this* package's releases, and a Python probe run against a gem would be
        # evidence about nothing.
        findings = index(report.fetch("ecosystem", "python"))
                   .findings(pair.package, pair.from_version, pair.to_version, before, after,
                     suffix: "")
      rescue Errors::MinerError => e
        give_up(report_id, Ledger::FAILED, e.message.to_s, retry_instead: true, claimed: claimed)
        stats.skipped += 1
        @log.warning("could not examine %s: %s", report_id, e)
        return
      end

      linked = Service.linked(report, findings, pair)
      if linked.nil?
        give_up(report_id, Ledger::NO_MECHANISM,
          "#{findings.length} finding(s), none naming this report's argument",
          claimed: claimed)
        stats.skipped += 1
        @log.info("%s: nothing in %s->%s explains it", report_id, pair.from_version, pair.to_version)
        return
      end

      finding, answer = linked
      unless @writes.allow
        give_up(report_id, Ledger::NO_MECHANISM, "no write budget this hour", claimed: claimed)
        stats.skipped += 1
        return
      end
      begin
        if answer.kind == "resolution"
          @session.propose_resolution(report_id, answer.payload)
        else
          @session.verify(report_id, answer.payload)
        end
      rescue Errors::RateLimited
        # Nothing was written, so the report stays due and the loop waits the quota out; marking it
        # failed here would retry it in six hours.
        raise
      rescue Errors::CollectionPaused
        # Nothing was written here either, and `give_up` below writes a retry interval of hours —
        # which would outlast a pause that lifts in minutes and turn a closed door into a report
        # nobody answers this afternoon.
        raise
      rescue Errors::CorpusError => e
        give_up(report_id, Ledger::FAILED, e.message.to_s, retry_instead: true, claimed: claimed)
        stats.skipped += 1
        @log.warning("could not answer %s: %s", report_id, e)
        return
      ensure
        # Released only if it was taken, because a reservation that outlives the work tells every
        # later caller to wait for something already done — and there is nothing to release on a
        # report that was never claimable in the first place.
        safe_release(report_id) if claimed
      end

      @ledger.record_report(report_id, outcome: Ledger::PROPOSED, note: answer.kind)
      stats.answered += 1
      @log.info("%s (%s: %s)", answer.summary, answer.kind, finding.parameter)
    end

    def give_up(report_id, outcome, note, retry_instead: false, claimed: true)
      retry_outcome = retry_instead ? Ledger::FAILED : outcome
      @ledger.record_report(report_id, outcome: retry_outcome,
        next_at: Time.now.to_f + REPORT_RETRY_SECONDS,
        note: note.to_s[0, 200])
      safe_release(report_id) if claimed
    end

    def safe_release(report_id)
      @session.release(report_id)
    rescue Errors::CorpusError => e
      @log.warning("could not release the claim on %s: %s", report_id, e)
    end

    # Say the loop is still turning, in a file something else can read.
    def touch
      return if @heartbeat.nil?

      FileUtils.mkdir_p(@heartbeat.dirname)
      @heartbeat.write(Time.now.to_f.to_s)
    end

    # Sleep, but in a way a test does not have to sit through.
    #
    # `pace` appears in every call rather than being checked once, because a cycle that is interrupted
    # must still be interruptible: the delay is replaced by nothing in a test, not by a shorter one.
    def wait(seconds, pace: true)
      return unless pace

      # Woken in slices so a stop signal is honoured promptly rather than after twenty minutes of
      # sleep.
      deadline = monotonic + seconds
      while !@stop && monotonic < deadline
        sleep([5.0, deadline - monotonic].min)
      end
    end

    # The finding that explains this report, and the write it justifies.
    def self.linked(report, findings, pair)
      findings.each do |finding|
        answer = Solving.answer_for(report, finding, pair)
        return [finding, answer] unless answer.nil?
      end
      nil
    end

    # Turn SIGTERM and SIGINT into a clean stop.
    #
    # `docker stop` sends SIGTERM and then waits. A service that ignored it would be killed mid-write
    # after the grace period, and the file it was writing is the ledger that says what not to redo —
    # so the signal sets a flag and the cycle finishes, which is also why the sleep is taken in
    # slices.
    #
    # Returns the handlers it replaced, so a test can put them back: a trap outlives the call
    # that installed it, and one left pointing at a service that has stopped would swallow a
    # later SIGINT in the same process.
    def self.install_stop_handlers(service, signals: %w[TERM INT])
      signals.to_h do |name|
        [name, begin
          Signal.trap(name) do
            Log.logger("agents_fyi_miner.service").info("stopping on signal %s", name)
            service.stop = true
          end
        rescue ArgumentError, ThreadError
          nil
        end]
      end
    end

    # How many pairs have been examined, for the startup line.
    #
    # A service that logs what it is about to do and not what it already knows cannot be told apart
    # from one that has lost its history — and losing it is exactly what a volume that was not mounted
    # looks like.
    def self.known_work(ledger)
      ledger.pairs.each_value.count { |record| Ledger::SETTLED_PAIR.include?(record.outcome) }
    end

    # Add one cycle's totals to a run's, field by field.
    #
    # The first version of this asked the verifier's `Stats` for the miner's list, so every
    # run of the verify loop died with `undefined method 'pairs_mined' for an instance of
    # Verifier::Stats` before it had checked anything: a shared name list is a claim about two
    # classes that nothing checks, and the object's own fields cannot disagree with it.
    # Anything that is not a counter is the notes, which are appended rather than summed.
    #
    # A field the total does not have is a bug rather than a zero: both `Stats` are the same class on
    # both sides of a call from either loop, so a missing setter means this was handed a run's totals
    # from the other loop — which, silently skipped, would be a cycle's numbers dropped from the
    # summary an operator reads at shutdown.
    def self.accumulate(total, stats)
      stats.instance_variables.each do |ivar|
        name = ivar.to_s.delete_prefix("@")
        next if name == "notes"

        unless total.respond_to?(name) && stats.respond_to?(name)
          raise ArgumentError, "#{total.class} has no #{name} to add #{stats.class} into"
        end

        total.public_send("#{name}=", total.public_send(name) + stats.public_send(name))
      end
      total.notes.concat(stats.notes)
      total
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
