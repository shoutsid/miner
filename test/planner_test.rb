# frozen_string_literal: true

require "set"

require_relative "test_helper"

# Choosing the next hour's work, asserted as an order rather than a vibe.
#
# Nothing here installs anything or reaches a network: the caller hands the plan a release
# history, so what is asserted is which work came back and which reasons came with it. What is
# asserted is the same, branch for branch.
class PlannerTest < MinerTest
  L = AgentsMiner::Ledger
  P = AgentsMiner::Planner
  V = AgentsMiner::Versions

  HISTORY = {
    "httpx" => %w[0.26.0 0.27.0 0.27.2 0.28.0 0.28.1],
    "sqlalchemy" => %w[1.4.54 2.0.0 2.0.54],
    "click" => %w[7.1.2 8.0.0 8.1.0 8.1.7],
    "wrapt" => %w[1.13.3 1.14.0 1.15.0]
  }.freeze

  def setup
    super
    @fetches = []
  end

  # A release history, recording every package the plan asked to *fetch*.
  #
  # The distinction is the point of `max_fetches`: a plan may look at as many packages as it
  # likes, and only the ones it asks the index about cost anything.
  def history_for(package, refresh: true)
    @fetches << package if refresh
    unless HISTORY.key?(package)
      raise AgentsMiner::Versions::NoHistory, "#{package} is not on the index (404)"
    end

    HISTORY[package]
  end

  def report(**overrides)
    body = {
      "id" => "00000000-0000-0000-0000-00000000abcd",
      "library" => "sqlalchemy",
      "version" => "1.4.54",
      "subject_kind" => "package",
      "status" => "open",
      "resolution" => nil,
      "signatures" => ["unexpected keyword argument 'convert_unicode'"],
      "updated_at" => "2026-01-01T00:00:00Z"
    }
    overrides.each { |key, value| body[key.to_s] = value }
    body
  end

  def test_a_library_the_corpus_is_asking_about_is_chosen_first
    # A report sitting open is somebody's unanswered question, and it is the only signal in the
    # system that comes from outside the miner.
    chosen = P.plan(
      reports: [report], watchlist: %w[httpx sqlalchemy], ledger: L.new,
      history_for: method(:history_for), now: 1_000.0, budget: 1
    )

    assert_equal %w[sqlalchemy], chosen.pairs.map(&:package)
    assert_equal ["sqlalchemy"], chosen.demand
  end

  def test_the_most_asked_for_library_is_named_first
    # Two reports about one library outrank one report about another, because the corpus is
    # saying which question is being asked more.
    reports = [report(id: "a"), report(id: "b"), report(id: "c", library: "httpx")]

    assert_equal %w[sqlalchemy httpx], P.demanded(reports)
  end

  def test_a_package_that_has_produced_nothing_is_deferred_behind_one_that_has
    # Three silent releases is a package changing less than the index suggests, or breaking
    # callers in a way this differential cannot see. It is not abandoned — it is behind
    # everything that is still paying.
    store = L.new
    store.record_pair("click", "7.1.2", "8.0.0", outcome: L::EMPTY, now: 100.0)
    store.record_pair("click", "8.0.0", "8.1.0", outcome: L::EMPTY, now: 100.0)
    store.record_pair("click", "8.1.0", "8.1.7", outcome: L::EMPTY, now: 100.0)
    store.record_pair("httpx", "0.26.0", "0.27.2", outcome: L::DONE, findings: 4, now: 100.0)

    chosen = P.plan(reports: [], watchlist: %w[click httpx], ledger: store,
      history_for: method(:history_for), now: 1_000.0, budget: 2)

    assert_equal %w[httpx click], chosen.pairs.map(&:package)
  end

  def test_a_barren_package_is_still_mined_when_nothing_else_is_left
    # Deferred is not abandoned: a service with an idle cycle should spend it on the packages
    # that are merely unlikely, not on sleeping.
    #
    # The three recorded pairs are *patch* crossings, and the ladder's crossings are line
    # crossings — `8.0.0->8.1.7` is one the ledger has never seen, which is why there is work
    # here at all.
    store = L.new
    store.record_pair("click", "7.1.2", "8.0.0", outcome: L::EMPTY, now: 1.0)
    store.record_pair("click", "8.0.0", "8.1.0", outcome: L::EMPTY, now: 2.0)
    store.record_pair("click", "8.1.0", "8.1.7", outcome: L::EMPTY, now: 3.0)

    chosen = P.plan(reports: [], watchlist: ["click"], ledger: store,
      history_for: method(:history_for), now: 4.0, budget: 1)

    assert_equal %w[click], chosen.pairs.map(&:package)
  end

  # The score recomputed from the ledger's records rather than called.
  #
  # Written out rather than shared with the planner: a helper that called the same method would
  # agree with it by construction and catch nothing. The literal orders beside the comparisons
  # are the second guard — a bug in both would still have to produce those.
  def scan_order(store, demand, watchlist, leads: {})
    candidates = (demand.keys + leads.keys + watchlist).uniq
    positions = {}
    watchlist.each_with_index { |package, index| positions[package] ||= index }

    scored = candidates.map do |package|
      prefix = "#{package} "
      owned = store.pairs.select { |key, _record| key.start_with?(prefix) }
      settled = owned.count { |_key, record| L::SETTLED_PAIR.include?(record.outcome) }
      yielded = owned.sum do |_key, record|
        L::SETTLED_PAIR.include?(record.outcome) ? record.findings : 0
      end
      last = owned.filter_map { |_key, record| record.at }.max || 0.0
      weight = 1 + demand.fetch(package, 0) + (leads.key?(package) ? P::LEAD_BONUS : 0)
      [package, weight * (yielded + 1).fdiv(settled + P::YIELD_PRIOR), last]
    end

    scored.each_with_index
          .sort_by do |(package, value, last), index|
            [-value, last, positions.fetch(package, -1), index]
          end
          .map { |(package, _value, _last), _index| package }
  end

  def test_the_order_is_the_one_the_value_of_information_rule_produces
    # The planner used to sort by three hard tiers; it now scores demand times yield. This
    # recomputes the score from the same pairs and asserts the two agree, with the literal order
    # as the guard that a bug in both cannot make the test agree with itself.
    store = L.new
    store.record_pair("httpx", "0.26.0", "0.27.2", outcome: L::DONE, findings: 1, now: 500.0)
    store.record_pair("click", "7.1.2", "8.0.0", outcome: L::EMPTY, now: 100.0)
    store.record_pair("click", "8.0.0", "8.1.0", outcome: L::EMPTY, now: 200.0)
    store.record_pair("click", "8.1.0", "8.1.7", outcome: L::EMPTY, now: 300.0)
    store.record_pair("sqlalchemy", "1.4.54", "2.0.0", outcome: L::DONE, findings: 2, now: 400.0)
    demand = { "sqlalchemy" => 1 }
    watchlist = %w[httpx click sqlalchemy wrapt]

    ordered = P.package_order(demand: demand, watchlist: watchlist, ledger: store)

    assert_equal scan_order(store, demand, watchlist), ordered
    # Demand puts sqlalchemy (2.0) first; httpx's one finding on one pair (0.67) beats the
    # unseen wrapt (0.5), which still beats the three-times-empty click (0.2).
    assert_equal %w[sqlalchemy httpx wrapt click], ordered
  end

  def test_a_never_examined_package_outranks_one_examined_and_empty
    # The floor the score exists for: a hard tier ranked both in the same place, so a package
    # whose three silent releases say nothing could sit ahead of one nobody had ever looked at.
    store = L.new
    3.times do |index|
      store.record_pair("click", "8.#{index}.0", "8.#{index + 1}.0",
        outcome: L::EMPTY, now: 100.0 + index)
    end

    ordered = P.package_order(demand: {}, watchlist: %w[click unseen], ledger: store)

    assert_equal %w[unseen click], ordered
    assert_equal scan_order(store, {}, %w[click unseen]), ordered
  end

  def test_demand_counts_reports_rather_than_merely_noticing_a_library
    reports = [report(id: "a", library: "sqlalchemy"), report(id: "b", library: "sqlalchemy"),
               report(id: "c", library: "httpx")]

    counts = P.demand_counts(reports)

    assert_equal({ "sqlalchemy" => 2, "httpx" => 1 }, counts)
    assert_equal %w[sqlalchemy httpx], P.ordered_demand(counts)
    # Both are unseen, so the weight is the whole of the difference.
    assert_equal %w[sqlalchemy httpx],
      P.package_order(demand: counts, watchlist: %w[httpx sqlalchemy], ledger: L.new)
  end

  def test_the_package_touched_longest_ago_goes_first
    # Without this the head of a tier is worked forever: its next pair is always available, and
    # the tail never gets a turn.
    store = L.new
    store.record_pair("httpx", "0.26.0", "0.27.2", outcome: L::DONE, findings: 1, now: 500.0)
    store.record_pair("click", "7.1.2", "8.0.0", outcome: L::DONE, findings: 1, now: 100.0)

    chosen = P.plan(reports: [], watchlist: %w[httpx click], ledger: store,
      history_for: method(:history_for), now: 1_000.0, budget: 1)

    assert_equal %w[click], chosen.pairs.map(&:package)
  end

  def test_one_pair_per_package_before_a_second_pair_of_any
    # A cycle spread across packages is what keeps the corpus growing in breadth rather than
    # exhausting one package's history while eleven wait.
    chosen = P.plan(reports: [], watchlist: %w[httpx click], ledger: L.new,
      history_for: method(:history_for), now: 1_000.0, budget: 2)

    assert_equal %w[httpx click], chosen.pairs.map(&:package)
  end

  def test_the_pairs_of_a_package_are_taken_newest_first
    # A finding from the release cycle somebody is upgrading through is worth more than one from
    # three years ago, which is a finding nobody will meet again.
    chosen = P.plan(reports: [], watchlist: ["httpx"], ledger: L.new,
      history_for: method(:history_for), now: 1_000.0, budget: 1)

    assert_equal "0.28.1", chosen.pairs[0].to_version
    assert_equal "0.27.2", chosen.pairs[0].from_version
  end

  def test_a_package_with_nothing_left_to_mine_says_so
    store = L.new
    store.record_pair("httpx", "0.26.0", "0.27.2", outcome: L::EMPTY, now: 1.0)
    store.record_pair("httpx", "0.27.2", "0.28.1", outcome: L::EMPTY, now: 1.0)

    chosen = P.plan(reports: [], watchlist: ["httpx"], ledger: store,
      history_for: method(:history_for), now: 1_000.0, budget: 1)

    assert_empty chosen.pairs
    assert_includes chosen.withheld, "httpx"
  end

  def test_a_package_is_not_chased_back_into_releases_nobody_upgrades_from
    # The crossings are enumerated newest-first, so an unbounded walk keeps going until the
    # history runs out — and it reached `jinja2 2.6 -> 2.7.3`, a 2013 release that cannot even be
    # installed on this interpreter. Such a finding is true and worthless: nobody upgrades a 2013
    # release today, and exactly those releases are the ones whose dependencies no longer build.
    history = (0...40).map { |minor| "1.#{minor}.0" }
    chosen = P.plan(reports: [], watchlist: ["wide"], ledger: L.new,
      history_for: ->(_package, refresh: true) { history },
      now: 1_000.0, budget: P::MAX_CROSSINGS, per_package: P::MAX_CROSSINGS)

    assert_equal P::MAX_CROSSINGS, chosen.pairs.length
    # And what it does mine is the recent end of the history, not the old one.
    assert_equal "1.39.0", chosen.pairs[0].to_version
    assert_equal "1.27.0", chosen.pairs.last.from_version
  end

  def test_a_package_whose_bounded_history_is_mined_is_reported_as_finished
    # `history exhausted` and `nothing left to mine` are different things to a reader: one is
    # finished and the other still has work this cycle could not reach.
    history = (0...20).map { |minor| "1.#{minor}.0" }
    store = L.new
    V.crossings("wide", history, limit: P::MAX_CROSSINGS).each do |pair|
      store.record_pair("wide", pair.from_version, pair.to_version, outcome: L::EMPTY, now: 1.0)
    end

    chosen = P.plan(reports: [], watchlist: ["wide"], ledger: store,
      history_for: ->(_package, refresh: true) { history },
      now: 1_000.0, budget: 1)

    assert_empty chosen.pairs
    assert_includes chosen.withheld["wide"], "exhausted"
  end

  def test_a_dry_cycle_says_why_it_is_dry
    # Nothing to do is the one outcome that has to explain itself.
    #
    # It is also the one that looks the same whether the miner has finished the list or is stuck
    # behind something: "0 pair(s)" is what a miner that had worked through its whole watchlist
    # logged every ten minutes for hours while the container reported healthy, and the reason was
    # in `withheld` — one entry per package — the whole time.
    history = (0...20).map { |minor| "1.#{minor}.0" }
    store = L.new
    V.crossings("wide", history, limit: P::MAX_CROSSINGS).each do |pair|
      store.record_pair("wide", pair.from_version, pair.to_version, outcome: L::EMPTY, now: 1.0)
    end

    chosen = P.plan(
      reports: [], watchlist: %w[wide narrow], ledger: store,
      history_for: ->(package, refresh: true) { package == "wide" ? history : ["1.0"] },
      now: 1_000.0, budget: 1
    )

    assert_empty chosen
    line = chosen.describe
    assert_includes line, "nothing due"
    assert_includes line, "1 already mined in the window"
    assert_includes line, "1 nothing left to mine"
  end

  def test_the_packages_the_walk_never_reached_are_counted_rather_than_ignored
    # The count that says "the list is long enough" rather than "the list is finished" — a walk
    # that stopped with work behind it is not the same state as one that looked at everything and
    # found nothing.
    history = (0...20).map { |minor| "1.#{minor}.0" }
    chosen = P.plan(reports: [], watchlist: %w[wide wider widest], ledger: L.new,
      history_for: ->(_package, refresh: true) { history },
      now: 1_000.0, budget: 1)

    assert_equal 1, chosen.pairs.length
    assert_equal 2, chosen.kinds["not reached this cycle"]
  end

  def test_a_cycle_with_work_does_not_pad_its_line_with_the_reasons
    # The dry line is for the case where there is nothing else to read.
    history = (0...20).map { |minor| "1.#{minor}.0" }
    chosen = P.plan(reports: [], watchlist: ["wide"], ledger: L.new,
      history_for: ->(_package, refresh: true) { history },
      now: 1_000.0, budget: 1)

    refute_empty chosen.pairs
    refute_includes chosen.describe, "nothing due"
  end

  def test_a_package_whose_releases_cannot_be_built_here_gives_up_its_slot
    # The pair budget is the scarcest thing this service has, and a pair that cannot be examined
    # spends one of the twelve slots a cycle has. Nine of twelve pairs skipped and nothing filed,
    # cycle after cycle, is that happening: the walk fills the budget with crossings through a
    # release pip cannot produce, and the pairs behind them that *could* be examined are never
    # reached. With the release recorded as unexaminable the crossing is not due, so the walk
    # passes it and the budget goes to work.
    store = L.new
    V.crossings("wrapt", %w[1.13.3 1.14.0 1.15.0], limit: P::MAX_CROSSINGS).each do |pair|
      store.record_pair(
        "wrapt", pair.from_version, pair.to_version,
        outcome: L::UNEXAMINABLE,
        note: "could not install wrapt==1.13.3: no matching distribution",
        release: "wrapt 1.13.3", now: 1.0
      )
    end

    chosen = P.plan(reports: [], watchlist: %w[wrapt httpx], ledger: store,
      history_for: method(:history_for), now: 1_000.0, budget: 2)

    # The budget could hold two pairs, and the only one it found is the examinable package's:
    # the crossings through `wrapt 1.13.3` are not work any more.
    assert_equal %w[httpx], chosen.pairs.map(&:package)
    assert_includes chosen.withheld["wrapt"], "wrapt 1.13.3"
    assert_includes chosen.withheld["wrapt"], "cannot be examined here"
  end

  def test_one_unbuildable_release_is_reported_once_however_many_pairs_use_it
    # `wrapt 1.13.3` is the old side of two crossings, and both failed to build it; a reader told
    # about it twice would go looking for two problems.
    store = L.new
    %w[1.14.0 1.15.0].each do |to_version|
      store.record_pair(
        "wrapt", "1.13.3", to_version,
        outcome: L::UNEXAMINABLE,
        note: "could not install wrapt==1.13.3: no matching distribution",
        release: "wrapt 1.13.3", now: 1.0
      )
    end

    facts = store.unexaminable("wrapt")

    assert_equal 1, facts.length
    assert facts[0].start_with?("wrapt 1.13.3")
  end

  def test_a_package_partly_examinable_is_not_reported_as_unexaminable
    # One unbuildable release is not a statement about the whole package: the crossings that do
    # not run through it are still work, and a package reported as unexaminable while it has due
    # pairs would tell a reader the opposite.
    history = %w[1.0.0 1.1.0 2.0.0]
    store = L.new
    store.record_pair(
      "pkg", "1.0.0", "1.1.0",
      outcome: L::UNEXAMINABLE,
      note: "could not install pkg==1.0.0: no matching distribution",
      release: "pkg 1.0.0", now: 1.0
    )

    chosen = P.plan(reports: [], watchlist: ["pkg"], ledger: store,
      history_for: ->(_package, refresh: true) { history },
      now: 1_000.0, budget: 1)

    # `1.1.0->2.0.0` does not need the release that cannot be built, so it is due.
    assert_equal %w[1.1.0], chosen.pairs.map(&:from_version)
    refute_includes chosen.withheld, "pkg"
  end

  def test_a_pair_waiting_out_a_retry_is_not_reported_as_nothing_left
    # Three reasons for an empty package, and a reader needs which one: finished, coming back, or
    # impossible here. A transient failure is the one that comes back, and calling it `nothing
    # left to mine` retires a package that was only waiting.
    store = L.new
    V.crossings("httpx", HISTORY["httpx"], limit: P::MAX_CROSSINGS).each do |pair|
      store.record_pair(
        "httpx", pair.from_version, pair.to_version,
        outcome: L::FAILED, note: "could not install httpx: connection reset",
        next_at: 9_000.0, now: 1.0
      )
    end

    chosen = P.plan(reports: [], watchlist: ["httpx"], ledger: store,
      history_for: method(:history_for), now: 1_000.0, budget: 1)

    assert_empty chosen.pairs
    assert_includes chosen.withheld["httpx"], "waiting to be tried again"
  end

  def test_a_library_that_is_not_on_the_index_is_reported_rather_than_retried_in_silence
    # `postgres` is a thing agents write reports about and not a thing with releases, and the plan
    # says which package that was rather than quietly producing one pair fewer.
    chosen = P.plan(reports: [], watchlist: ["postgres"], ledger: L.new,
      history_for: method(:history_for), now: 1_000.0, budget: 1)

    assert_includes chosen.withheld, "postgres"
    assert_includes chosen.withheld["postgres"], "not on the index"
  end

  def test_a_report_with_no_named_argument_is_not_a_question_for_this_miner
    # A timeout has a fix, but not one that executing a release's signatures can establish, and
    # inventing one would be worse than leaving it open.
    chosen = P.plan(reports: [report(signatures: %w[timeout connecttimeout])],
      watchlist: ["httpx"], ledger: L.new,
      history_for: method(:history_for), now: 1_000.0, budget: 1)

    assert_empty chosen.reports
    refute_empty chosen.pairs # breadth still happens
  end

  def test_a_report_that_never_named_a_version_is_left_alone
    # The service writes the literal `unknown` rather than refusing the report, so the planner has
    # to recognise it: there is no release line to compare.
    chosen = P.plan(reports: [report(version: "unknown")], watchlist: ["httpx"], ledger: L.new,
      history_for: method(:history_for), now: 1_000.0, budget: 1)

    assert_empty chosen.reports
  end

  def test_a_report_already_scored_by_this_miner_is_not_chosen_again
    store = L.new
    store.record_report("00000000-0000-0000-0000-00000000abcd", outcome: L::NO_MECHANISM)

    chosen = P.plan(reports: [report], watchlist: ["httpx"], ledger: store,
      history_for: method(:history_for), now: 1_000.0, budget: 1)

    assert_empty chosen.reports
  end

  def test_the_plan_says_what_it_left_out_and_why
    store = L.new
    store.record_pair("httpx", "0.26.0", "0.27.2", outcome: L::EMPTY, now: 1.0)
    store.record_pair("httpx", "0.27.2", "0.28.1", outcome: L::EMPTY, now: 1.0)

    chosen = P.plan(reports: [], watchlist: ["httpx"], ledger: store,
      history_for: method(:history_for), now: 1_000.0, budget: 1)

    assert_includes chosen.describe, "httpx"
  end

  def test_a_package_the_plan_cannot_work_on_does_not_hold_the_cycle
    # The stall this scheduler had for real. A package with no crossing to examine records no
    # pair, so it is never stamped as touched and sorts to the front of the queue for ever — and
    # once enough of those were in front, every cycle chose them, found nothing, and slept while
    # 64 pairs sat due behind them. The walk has to keep going until it has work or runs out of
    # packages.
    barren = %w[mdurl annotated-doc python-multipart multiprocess]
    histories = barren.to_h { |name| [name, ["1.0.0"]] }
    histories["httpx"] = HISTORY["httpx"]

    chosen = P.plan(
      reports: [], watchlist: [*barren, "httpx"], ledger: L.new,
      history_for: ->(package, refresh: true) { histories[package] }, now: 1_000.0, budget: 4
    )

    assert_equal %w[httpx], chosen.pairs.map(&:package)
  end

  def test_past_the_allowance_the_walk_pays_a_file_read_and_not_a_request
    # The walk is bounded by what it asks the index for, not by how many packages it considers:
    # reaching the first package with work meant passing 605 that had never been fetched, and a
    # cap on packages stopped before any of them. Past the allowance a cached history is used,
    # which is why the walk can afford to keep looking.
    @fetches.clear
    histories = (0...40).to_h { |n| ["blank-#{n}", ["1.0.0"]] }
    histories["httpx"] = %w[0.27.2 0.28.0 0.28.1]

    chosen = P.plan(
      reports: [], watchlist: histories.keys, ledger: L.new,
      history_for: lambda { |package, refresh: true|
        @fetches << package if refresh
        histories.fetch(package, ["1.0.0"])
      },
      now: 1_000.0, budget: 1, max_fetches: 5
    )

    assert_equal %w[httpx], chosen.pairs.map(&:package)
    assert_equal 5, @fetches.length
  end

  def test_a_package_whose_history_is_already_here_does_not_spend_the_allowance
    # The allowance is a bound on *requests*, and this is the half that was missing: a package
    # whose history is on disk is served offline, at no cost, so it must not consume a fetch.
    # Measured on the live miner, 411 of the thousand watchlist entries had no cached history and
    # every one of them sat behind a self-renewing head of never-touched packages — packages that
    # produce no pair are never stamped as touched, so they return first every cycle — and the
    # cycle ended with nothing to mine while the budget had been spent on histories the cache
    # already held.
    @fetches.clear
    histories = { "cached-1" => ["1.0.0"], "cached-2" => ["1.0.0"],
                  "fresh" => %w[0.27.2 0.28.0 0.28.1] }

    chosen = P.plan(
      reports: [], watchlist: histories.keys, ledger: L.new,
      history_for: lambda { |package, refresh: true|
        @fetches << package if refresh
        histories[package]
      },
      now: 1_000.0, budget: 1, max_fetches: 0,
      # The first two are on disk and the third is not, which is the only thing that decides
      # which of them may be asked for.
      cache_has: ->(package) { package.start_with?("cached") }
    )

    # No fetch was allowed and no fetch was needed: the cached histories were read and the walk
    # reached the package with work.
    assert_equal %w[fresh], chosen.pairs.map(&:package)
    assert_empty @fetches
  end

  def test_a_walk_that_ran_out_of_fetches_says_so_rather_than_blaming_the_index
    # The fetch budget is this cycle's own limit, and the reason has to say so.
    #
    # Past the budget the walk reads the cache, so a package with no cached history fails without
    # the index ever being asked. That failure used to be filed under "the index could not be
    # read", which sent an operator to look at the network every time a cycle ran out of fetches —
    # the exact stuck case the reason-counting exists to name, wrong precisely when it is read.
    chosen = P.plan(
      reports: [], watchlist: ["uncached"], ledger: L.new,
      history_for: lambda { |package, refresh: true|
        return %w[1.0.0 2.0.0] if refresh

        # What `release_history` does offline with nothing on disk: there is no cached history,
        # and the plan allowed itself no fetch to fill one.
        raise AgentsMiner::Versions::NoHistory, "#{package} has no cached history"
      },
      now: 1_000.0, budget: 1, max_fetches: 0, cache_has: ->(_package) { false }
    )

    assert_empty chosen
    assert_equal({ "the fetch budget for this cycle was spent" => 1 }, chosen.kinds)
    refute_includes chosen.kinds, "the index could not be read"
  end

  def test_a_history_that_genuinely_cannot_be_read_still_says_the_index_failed
    # The new distinction must not swallow the case it was carved out of.
    #
    # A fetch that was actually attempted and failed is still the index — the same reason as
    # before — so the two kinds have to stay separable in both directions.
    chosen = P.plan(
      reports: [], watchlist: ["unreachable"], ledger: L.new,
      history_for: lambda { |package, refresh: true|
        raise SocketError, "#{package}: Name or service not known"
      },
      now: 1_000.0, budget: 1, max_fetches: 5, cache_has: ->(_package) { false }
    )

    assert_equal({ "the index could not be read" => 1 }, chosen.kinds)
  end

  # A reviewed advisory is a lead, and the planner's two jobs with one are both here: it adds the
  # package to the candidates even when nothing else named it, and it targets the crossing the fix
  # landed in — a patch crossing the line ladder never produces.
  def test_a_lead_adds_its_package_and_targets_the_crossing_its_fix_landed_in
    history = { "rack" => %w[2.2.5 2.2.6 2.2.6.1 2.2.7] }
    chosen = P.plan(
      reports: [], watchlist: [], ledger: L.new, now: 0.0,
      history_for: ->(package, refresh: true) { history.fetch(package) },
      leads: { "rack" => [lead("GHSA-aaaa-bbbb-cccc", "high", "2.2.6.1")] },
      advisory_of: AgentsMiner::Ecosystems::RUBY.method(:advisory_pair)
    )

    assert_equal [["2.2.6", "2.2.6.1"]],
      chosen.pairs.map { |pair| [pair.from_version, pair.to_version] }
  end

  # A lead reaches past the window bound — that is the point of it — but only to its own pair, never
  # by widening the walk: a package with thirteen line crossings still gets twelve plus the
  # advisory's one, and a lead whose fix is beyond the bound does not pull the rest of the history
  # in with it.
  def test_a_lead_reaches_past_the_window_for_its_own_pair_only
    history = { "big" => (1..20).map { |n| "1.#{n}.0" } }
    chosen = P.plan(
      reports: [], watchlist: [], ledger: L.new, now: 0.0, per_package: 100, budget: 100,
      history_for: ->(package, refresh: true) { history.fetch(package) },
      leads: { "big" => [lead("GHSA-aaaa-bbbb-cccc", "high", "1.2.0")] },
      advisory_of: AgentsMiner::Ecosystems::RUBY.method(:advisory_pair)
    )

    pairs = chosen.pairs.map { |pair| [pair.from_version, pair.to_version] }
    assert_includes pairs, ["1.1.0", "1.2.0"]
    # The window is the newest twelve lines plus the one the lead named.
    assert_equal 13, pairs.length
  end

  # One crossing is one piece of work however it was named: a lead whose fix is a line crossing the
  # ladder already produced adds nothing twice.
  def test_an_advisory_pair_the_ladder_already_produced_is_not_planned_twice
    history = { "rack" => %w[1.9.9 2.0.0] }
    chosen = P.plan(
      reports: [], watchlist: [], ledger: L.new, now: 0.0,
      history_for: ->(package, refresh: true) { history.fetch(package) },
      leads: { "rack" => [lead("GHSA-aaaa-bbbb-cccc", "high", "2.0.0")] },
      advisory_of: AgentsMiner::Ecosystems::RUBY.method(:advisory_pair)
    )

    assert_equal [["1.9.9", "2.0.0"]],
      chosen.pairs.map { |pair| [pair.from_version, pair.to_version] }
  end

  # Corpus evidence still decides the order: a lead sits above the breadth list and below a report,
  # so a package somebody filed an unanswered report about is worked before one only GitHub named.
  def test_demand_is_worked_before_a_lead
    history = { "sqlalchemy" => %w[1.4.54 2.0.0 2.0.54], "rack" => %w[2.2.5 2.2.6 2.2.6.1] }
    chosen = P.plan(
      reports: [report], watchlist: [], ledger: L.new, now: 0.0, per_package: 1, budget: 1,
      history_for: ->(package, refresh: true) { history.fetch(package) },
      leads: { "rack" => [lead("GHSA-aaaa-bbbb-cccc", "critical", "2.2.6.1")] },
      advisory_of: AgentsMiner::Ecosystems::RUBY.method(:advisory_pair)
    )

    assert_equal ["sqlalchemy"], chosen.pairs.map(&:package)
  end

  def lead(id, severity, fixed_in)
    { "id" => id, "severity" => severity, "fixed_in" => fixed_in }
  end
end
