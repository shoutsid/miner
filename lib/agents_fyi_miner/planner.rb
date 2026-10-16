# frozen_string_literal: true

require "set"

require_relative "errors"
require_relative "log"
require_relative "pair"
require_relative "rubyversions"
require_relative "solving"
require_relative "versions"

module AgentsFyiMiner
  # What the miner should work on next, and why that and not something else.
  #
  # A single `publish` run does not need this module: the operator named a package and the run
  # did that package. A service needs it, because "mine everything" is not an instruction a
  # machine can carry out — the index holds hundreds of thousands of packages and every one of
  # them has dozens of releases — so the whole job is choosing, and a miner whose choice is
  # arbitrary is one that spends its life re-installing `requests` patch by patch.
  #
  # Three signals decide the order, and each exists because its absence produces a specific
  # kind of waste.
  #
  # *Demand comes before breadth.* The corpus knows what agents are actually hitting: a report
  # sitting `open` is somebody's unanswered question, and the library it names is a library
  # worth the next hour. That is also the only signal in the system that comes from outside the
  # miner, which makes it the only one that can tell the miner it is wrong about what matters.
  #
  # *Productive packages come before barren ones.* A package that has produced nothing across
  # three examined releases has either changed less than the index suggests or broken its
  # callers in a way this differential cannot see. It is not abandoned — it is deferred behind
  # everything that is still paying.
  #
  # *Least recently touched comes first within a tier.* Without it, a tier's head would be
  # worked forever while the tail waited, because the head's next pair is always available. The
  # ledger records when each pair was examined, so this is a read rather than a counter.
  #
  # Nothing here touches the network or the corpus: the caller supplies the reports and a
  # function that returns a package's release history, so the schedule can be tested by
  # asserting which work came back.
  module Planner
    # How many examined releases with nothing found moves a package behind the ones that are
    # still producing. Three rather than one: a single silent pair is a package whose last
    # release happened to change nothing, which is normal.
    BARREN_LIMIT = 3

    # How far back through a package's history the miner will go.
    #
    # The crossings are enumerated newest-first, so an unbounded walk keeps going until it runs
    # out of history — and it reached the point of spending a cycle on `jinja2 2.6 -> 2.7.3` and
    # `sqlalchemy 0.8 -> 0.9`, releases from 2013 that cannot even be installed on this
    # interpreter. Their findings would be true and worthless: nobody upgrades a 2013 release
    # today, and the ones that break are exactly the ones whose dependencies no longer build.
    #
    # Twelve line crossings is roughly three years of releases for a mature package, which
    # covers every upgrade a caller plausibly makes from a lockfile. Past that the honest
    # statement is that this miner does not know about it, and it is a stated limit rather than
    # discovered by a cycle that never ends.
    MAX_CROSSINGS = 12

    # How many release histories one cycle may ask the index for.
    #
    # Deliberately *not* a bound on how many packages a cycle considers, which is what this was,
    # and the difference is the difference between a miner that keeps mining and one that stops
    # for good. A package with nothing to mine has no pair to record, so it is never stamped as
    # touched and sorts to the front of the queue for ever — and once twelve such packages
    # reached the front, every cycle chose them, found nothing, and slept. Measured on the live
    # corpus: reaching twelve packages that *did* have work meant looking at 629, of which 605
    # had never been fetched. The scheduler's own comment always said the cap was there to bound
    # index traffic rather than to bound the schedule; this is what that means. Past the cap the
    # walk uses cached histories, which is why it can afford to keep looking and why an empty
    # package costs nothing.
    DEFAULT_FETCHES = 24

    # How many pairs one cycle may mine.
    #
    # This is a batch size, not a speed limit: the pairs in it are examined at the same time, so
    # a larger number costs the cycle's wall clock almost nothing while making its progress
    # worth reading. It is bounded because a cycle is also a log line and a ledger write, and
    # "everything left in the watchlist" would be one enormous batch whose failure loses all of
    # it.
    DEFAULT_BUDGET = 24

    # Every way a release history can fail to arrive except the index answering with a payload.
    #
    # Ruby's standard library splits that same fact across several: `SystemCallError` for the
    # disk, `SocketError` and the two `Net` timeouts for the network, `IOError` for a stream
    # that ended. Each ladder adds a `NoHistory` for "not on the index", which is a
    # *judgement* rather than a syscall, and both ladders spell it the same way on purpose.
    # Anything outside this list propagates, which is the point: a bug in the walk should be
    # seen rather than filed as an unreachable index. The network half is referenced **once**:
    # `RubyVersions::NETWORK_ERRORS` is the identical list, spelled the same way in the
    # sibling file, and a second copy here would be a third thing to keep in step.
    HISTORY_FAILURES = [
      Versions::NoHistory, RubyVersions::NoHistory,
      Versions::IndexError, RubyVersions::IndexError,
      *Versions::NETWORK_ERRORS
    ].freeze

    # The cache predicate for a caller that has none: nothing is on disk, so every package is
    # worth asking the index about until the budget says otherwise.
    NEVER_CACHED = ->(_package) { false }

    # The work for one cycle, with the reason each thing is in it.
    class Plan
      attr_reader :pairs, :reports, :demand, :withheld, :kinds

      def initialize(pairs: [], reports: [], demand: [], withheld: {}, kinds: {})
        @pairs = pairs
        @reports = reports
        @demand = demand
        @withheld = withheld
        @kinds = kinds
        freeze
      end

      def empty? = pairs.empty? && reports.empty?

      # One line for the log: what was chosen, and what was left out.
      def describe
        parts = ["#{pairs.length} pair(s)"]
        parts << "#{reports.length} report(s) to answer" unless reports.empty?
        parts << "demand: #{demand.first(5).join(', ')}" unless demand.empty?
        parts << "skipped: #{withheld.keys.sort.first(5).join(', ')}" unless withheld.empty?
        if empty? && !withheld.empty?
          # Nothing to do is the one outcome that has to explain itself, because it is the one
          # that looks the same whether the miner has finished the list or is stuck behind
          # something. "0 pair(s)" is what a miner that had worked through its whole watchlist
          # logged every ten minutes for hours while the container reported healthy, and the
          # reason was in `withheld` — one entry per package — the whole time.
          parts << "nothing due: #{exhausted}"
        end
        parts.join("; ")
      end

      # Why there is no work, counted by kind rather than by package.
      #
      # The kinds are the planner's own branches, so this cannot list a reason the walk does not
      # produce. Which one dominates is what tells a reader whether to widen the list (everything
      # here is mined), fix an interpreter (releases that cannot be built), or wait (a retry
      # pending).
      def exhausted
        kinds.sort_by { |kind, count| [-count, kind] }
             .map { |kind, count| "#{count} #{kind}" }
             .join(", ")
      end

      def to_s = describe
    end

    class << self
      # Choose this cycle's work: which upgrades to mine, which reports to answer.
      #
      # Reports are chosen before pairs because they are the scarcer resource — an open report is
      # a question somebody asked and is waiting on — and a cycle that answered one and mined two
      # is worth more than one that mined three.
      #
      # The walk over the ranking does not stop at the first packages; it stops when it has
      # enough *work*. `max_fetches` bounds what that walk may ask the index for, and everything
      # past it is served from the cache, so a package with nothing to mine can be passed over
      # for the price of reading a file.
      #
      # `cache_has` says which packages that price applies to, and the walk needs it because "may
      # I ask the index" and "must I" are different questions: a package whose history is already
      # on disk is served offline, at no cost to the budget, so the fee is only paid by packages
      # the cache does not cover. Without it the budget is spent on the front of the order
      # whether or not anything is being fetched.
      #
      # `crossings_of` is the ladder a history becomes pairs through, and it is a parameter
      # because a ladder belongs to an index: PyPI's versions are ordered by a numeric core and
      # RubyGems' by `Gem::Version`, and the pair each produces has to carry the index it came
      # from. Omitted, this is the PyPI ladder, which is what every caller before Ruby was.
      def plan(reports:, watchlist:, ledger:, history_for:, now:, budget: DEFAULT_BUDGET,
               report_budget: 1, per_package: 1, barren_limit: BARREN_LIMIT,
               max_fetches: DEFAULT_FETCHES, max_crossings: MAX_CROSSINGS,
               cache_has: NEVER_CACHED, crossings_of: nil)
        ladder = crossings_of || Versions.method(:crossings)
        demand = demanded(reports)
        chosen_reports = reports_to_answer(reports, ledger, now: now, budget: report_budget)
        order = package_order(demand: demand, watchlist: watchlist, ledger: ledger,
          barren_limit: barren_limit)

        due = {}
        withheld = {}
        kinds = Hash.new(0)

        # Record why a package produced nothing this cycle.
        #
        # Both halves are needed: the prose names the release or the count a reader has to act
        # on, and the kind is what the dry line can count.
        keep = lambda do |package, kind, reason|
          withheld[package] = reason
          kinds[kind] += 1
        end

        asked = 0
        fetches = 0
        order.each do |package|
          break if supply(due, per_package) >= budget

          asked += 1
          # A fetch is a request to the index, and the budget is a bound on *those*. It is not a
          # bound on how many packages a cycle considers — that is what it was first written as,
          # and the walk then stopped at the head of the order with the budget spent on histories
          # the cache already held. The head of the order is the packages nothing has ever
          # touched, which is a self-renewing population: one that produces no pair is never
          # stamped as touched, so it returns first every cycle. Measured on the live miner, 411
          # of the thousand watchlist entries had no cached history, and every one of them sat
          # behind that head while the cycle ended with nothing to mine.
          #
          # Whether the fetch budget is already spent is asked *before* the decision, because it
          # is the one thing that explains a failure raised by a read this plan chose not to make
          # — see the rescue below.
          spent = fetches >= max_fetches
          refresh = !spent && !cache_has.call(package)
          fetches += 1 if refresh
          begin
            history = history_for.call(package, refresh: refresh)
          rescue *HISTORY_FAILURES => e
            if spent
              # We did not ask the index: the budget was gone, so a history that was not on disk
              # failed for this cycle's own reason rather than the index's. Reporting it as "the
              # index could not be read" sent an operator to look at the network every time a
              # cycle ran out of fetches — which is exactly the stuck case these reasons exist to
              # name — so the two are kept apart: only a fetch that was actually attempted can
              # say the index failed.
              keep.call(
                package,
                "the fetch budget for this cycle was spent",
                "no cached history, and #{max_fetches} index fetch(es) already spent"
              )
              next
            end
            # A package that is not on the index, and an index that is briefly unreachable, are
            # both "not this cycle". Letting a DNS blip end the process would make the corpus's
            # growth depend on the network being up at the moment a cycle happened to start.
            message = e.message.to_s
            keep.call(package, "the index could not be read",
              message.empty? ? e.class.name : message)
            next
          end
          crossings = ladder.call(package, history, limit: max_crossings)
          found = crossings.select do |pair|
            ledger.due?(package, pair.from_version, pair.to_version, now: now)
          end
          if found.any?
            due[package] = found
            next
          end
          # Nothing due, and the reasons need telling apart rather than lumping into "nothing
          # left to mine": a pair waiting out a retry is coming back, a pair the environment
          # cannot produce is not, and a package whose history has been walked is finished. Only
          # the last of those is the miner having done its job, and a reader who cannot tell them
          # apart cannot tell a stuck miner from a finished one.
          waiting = crossings.reject do |pair|
            ledger.settled_pair?(package, pair.from_version, pair.to_version)
          end
          if waiting.any?
            keep.call(package, "waiting to be tried again",
              "#{waiting.length} pair(s) waiting to be tried again")
          elsif ledger.unexaminable(package).any?
            # A statement about the package rather than about the schedule: the miner cannot
            # examine these releases on this machine, and no number of cycles will change that.
            # Naming the release and the reason is the difference between "the miner is ignoring
            # `wrapt`" and "wrapt 1.13.3 has no wheel for this interpreter".
            facts = ledger.unexaminable(package)
            keep.call(
              package,
              "cannot be examined on this machine",
              "#{facts.length} release(s) cannot be examined here: #{facts[0]}" \
              "#{" (and #{facts.length - 1} more)" if facts.length > 1}"
            )
          elsif ledger.settled(package).positive? &&
                ledger.settled(package) >= crossings_available(package, history, max_crossings,
                  ladder: ladder)
            # The two sentences are a reader's whole distinction between "this package is
            # finished" and "this package has nothing to walk", so the test above asserts both
            # are reachable in one dry cycle.
            #
            # Said differently from a package with an unreadable index, because the two need
            # different things from the reader: this one is finished, and the other one is not
            # this cycle.
            keep.call(package, "already mined in the window",
              "history exhausted (#{max_crossings} newest crossings mined)")
          else
            keep.call(package, "nothing left to mine", "nothing left to mine")
          end
        end

        # Said here rather than in the ordering, because "lower priority" is only true of the
        # packages the walk did not reach — and counted, because a walk that stopped with work
        # behind it is not the same state as one that looked at everything. It is the number that
        # says "the list is long enough".
        order.drop(asked).each do |package|
          next if withheld.key?(package)

          keep.call(package, "not reached this cycle",
            "not this cycle: lower priority than the packages ahead")
        end

        # Round-robin rather than depth-first, so a cycle is spread across packages instead of
        # exhausting one package's history while eleven others wait.
        pairs = []
        [per_package, 1].max.times do |round_number|
          order.first(asked).each do |package|
            break if pairs.length >= budget

            candidates = due.fetch(package, [])
            pairs << candidates[round_number] if round_number < candidates.length
          end
          break if pairs.length >= budget
        end

        Plan.new(pairs: pairs, reports: chosen_reports, demand: demand,
          withheld: withheld, kinds: kinds)
      end

      # The libraries the corpus is being asked about, most asked-for first.
      #
      # Only reports the solver could actually answer, because a demand signal it cannot act on
      # is noise in the ordering: a report about a platform outage names a library the
      # differential will never have a release of.
      def demanded(reports)
        counts = Hash.new(0)
        reports.each do |report|
          next unless Solving.answerable?(report)

          counts[report["library"]] += 1
        end
        counts.sort_by { |library, count| [-count, library] }.map(&:first)
      end

      # Whether this report is a question the differential could answer.
      #
      # Public because the service asks it *before* the plan, to avoid queueing a report it will
      # never answer: a platform outage names no version, and keeping one in the work list for
      # ever would mean re-fetching it every cycle to reach the same conclusion.
      def wanted?(report)
        Solving.needs_a_fix?(report) || Solving.needs_reproduction?(report)
      end

      # The packages to consider, in the order to consider them.
      #
      # Three keys, in order: demand first, then packages that are still producing, then packages
      # that have gone quiet, and within each the least recently touched. A package never touched
      # sorts first inside its tier, which is what makes a fresh install of the service walk the
      # whole watchlist before revisiting one.
      #
      # The whole ranking comes back rather than a leading slice of it. Truncating here is how
      # the service came to do nothing at all: the slice is chosen by "never touched", so the
      # packages that can never be touched — the ones with no crossing to examine — take it and
      # hold it. How far into this list a cycle walks is `plan`'s decision, because only `plan`
      # knows what a package cost to look at and whether it found anything.
      #
      def package_order(demand:, watchlist:, ledger:, barren_limit:)
        candidates = (demand + watchlist).uniq
        demand_set = demand.to_set
        live = watchlist.reject { |package| demand_set.include?(package) }
        # The position of each package in the breadth order, built once. `live.index` was the
        # same answer at the cost of a scan per candidate, and a duplicate keeps its FIRST
        # position here, which is what `index` returned.
        positions = {}
        live.each_with_index { |package, index| positions[package] ||= index }

        tier = lambda do |package|
          next 0 if demand_set.include?(package)

          totals = ledger.package_totals(package)
          totals.settled >= barren_limit && totals.yielded.zero? ? 2 : 1
        end

        # The index is part of the key and not decoration: Python's `sorted` is stable and
        # Ruby's `sort_by` is not, so two candidates that tie on all three keys would come back
        # in an order this process chose — and the order decides what gets mined.
        candidates.each_with_index
                  .sort_by { |package, index|
          [tier.call(package), last_touched(ledger, package),
                                               positions.fetch(package, -1), index] }
                  .map(&:first)
      end

      # When this package was last worked on, or 0 for never.
      #
      # Read from the ledger's derived index rather than by walking the pairs: this is one of the
      # three questions the ordering asks about every candidate, and the three of them together
      # used to be three full scans of the ledger per cycle.
      def last_touched(ledger, package) = ledger.package_totals(package).last

      private

      # How many pairs these packages can still give this cycle.
      #
      # Counted rather than taken, because the walk's stopping test has to be "have I got enough
      # work" and not "have I looked at enough packages".
      def supply(due, per_package)
        due.values.sum { |found| [[per_package, 1].max, found.length].min }
      end

      # How many crossings this package has inside the bound.
      #
      # Asked of the same function that produced the work — the index's own ladder, so
      # "finished" and "still has work" cannot disagree: a second count of the same thing is a
      # second thing to keep true.
      def crossings_available(package, history, max_crossings, ladder:)
        ladder.call(package, history, limit: max_crossings).length
      end

      # Open reports worth a differential run, most valuable first.
      #
      # Sorted oldest first within each group: an unanswered report that has been sitting since
      # the corpus was small is one nobody else has got to, and the fix is worth more to whoever
      # is still hitting it than to the reporter. Reports a fix is already in force on come
      # second — the answer exists, and what is missing is a reproduction, which is cheaper to
      # give.
      def reports_to_answer(reports, ledger, now:, budget:)
        candidates = reports.select do |report|
          ledger.due_report?(report["id"].to_s, now: now) && wanted?(report)
        end
        candidates.each_with_index
                  .sort_by do |report, index|
                    [report["resolution"] ? 1 : 0, report["updated_at"] || "", index]
                  end
                  .map(&:first)
                  .first(budget)
      end
    end
  end
end
