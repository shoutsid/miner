# frozen_string_literal: true

require "fileutils"
require "json"
require "set"

require_relative "test_helper"
require_relative "stub_helper"

# The service loop, driven with fakes: what it does per cycle, and what it survives.
#
# Nothing here starts a child process or reaches a network. The Python suite this was ported
# from patched `service.envs.build`, `service.versions.release_history` and the differential
# the ecosystem adapter reaches; the seams are the same three, and they are the same *because*
# they are the places the real work happens rather than places chosen for being easy to stub.
# In particular the differential is patched where the adapter calls it
# (`Mine.findings_between`) — patching the name this module once imported would leave the
# adapter calling the real one, which needs an environment on disk and would fail on the probe
# script's directory.
class ServiceTest < MinerTest
  Service = AgentsFyiMiner::Service
  Errors = AgentsFyiMiner::Errors
  Envs = AgentsFyiMiner::Envs
  Ledger = AgentsFyiMiner::Ledger
  Finding = AgentsFyiMiner::Finding
  Mechanism = AgentsFyiMiner::Mechanism
  Pair = AgentsFyiMiner::Pair

  include StubHelper

  HISTORY = {
    "sqlalchemy" => %w[1.4.0 1.4.54 2.0.0 2.0.54],
    # Three crossings, so a cycle has more work than one write's worth.
    "click" => %w[7.1.2 8.0.0 8.1.0 8.1.7]
  }.freeze

  REPORT = {
    "id" => "00000000-0000-0000-0000-000000000001",
    "library" => "sqlalchemy",
    "version" => "2.0.5",
    "subject_kind" => "package",
    "status" => "open",
    "resolution" => nil,
    "hidden" => false,
    "signatures" => ["typeerror", "unexpected keyword argument 'convert_unicode'"],
    "submitted_by" => "someone-else",
    "updated_at" => "2026-01-01T00:00:00Z"
  }.freeze

  # `threading.Barrier`, which Ruby has no equivalent of: `count` parties must arrive before any of
  # them continues. Written out rather than avoided because the assertion *is* concurrency — three
  # examinations waiting on each other can only all finish if three are running at once.
  class Barrier
    def initialize(count, timeout: 5)
      @count = count
      @timeout = timeout
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @waiting = 0
      @generation = 0
    end

    def wait
      @mutex.synchronize do
        generation = @generation
        @waiting += 1
        if @waiting >= @count
          @waiting = 0
          @generation += 1
          @condition.broadcast
        else
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
          while @generation == generation
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            @condition.wait(@mutex, remaining)
          end
        end
      end
    end
  end

  # A client, with the parts of the service it talks to answerable from a test.
  class FakeSession
    attr_accessor :pages, :submit_outcome, :raise_on, :calls, :bodies, :transient, :after_call

    def initialize(pages = [], submit: "filed", raise_on: [])
      @pages = Array(pages).dup
      @submit_outcome = submit
      @raise_on = Array(raise_on).map(&:to_s)
      @calls = []
      # Bodies by id, so the solver can fetch one the way it fetches from the real API rather than
      # being handed the feed's own copy.
      @bodies = {}
      # Whether a refusal models the corpus being unavailable instead of the corpus saying no. The
      # two must be treated differently and cannot be told apart by the message.
      @transient = false
      @after_call = nil
    end

    def me
      @calls << ["me"]
      { "id" => "operator-1" }
    end

    def changes(since: nil, since_id: nil, limit: 100)
      @calls << ["changes", since, since_id]
      page = @pages.shift || { "items" => [], "has_more" => false,
                               "next_since" => since, "next_since_id" => since_id }
      page["items"].each { |item| @bodies[item["id"].to_s] = item }
      page
    end

    def report(report_id)
      @calls << ["report", report_id]
      unless @bodies.key?(report_id)
        # A 404: the corpus read this request and declined it, so the same request is declined
        # again. `transient` models the other kind of unreadable report — the corpus being briefly
        # unavailable — and the two are decided differently, which is why the flag exists.
        raise Errors::CorpusError.new("no such report #{report_id}", permanent: !@transient)
      end
      @bodies[report_id]
    end

    def claim(report_id)
      @calls << ["claim", report_id]
      raise Errors::CorpusError, "another operator holds this" if @raise_on.include?("claim")

      nil
    end

    def release(report_id)
      @calls << ["release", report_id]
      nil
    end

    def propose_resolution(report_id, payload)
      @calls << ["resolution", report_id, payload]
      raise Errors::CorpusError, "refused" if @raise_on.include?("resolution")

      nil
    end

    def verify(report_id, payload)
      @calls << ["verify", report_id, payload]
      nil
    end

    def submit_mined(finding, from_version:, published_at: nil, pace: 1.0)
      # Recorded, so a test can ask whether the release date the history fetch kept actually reached
      # the filing rather than only that a cycle ran.
      @calls << ["submit", finding.title, published_at]
      if @raise_on.include?("submit")
        # A 4xx: the corpus read this finding and declined it, so the same request will be declined
        # again. `transient` models the other kind.
        raise Errors::CorpusError.new("refused", permanent: !@transient)
      end
      @submit_outcome
    end

    def record_release_facts(library, facts)
      # One call per page, so a test can count the pages a gem's history was sent in rather than only
      # that it was sent.
      @calls << ["facts", library, facts]
      if @raise_on.include?("facts")
        raise Errors::CorpusError.new("refused", permanent: !@transient)
      end

      { "recorded" => facts.length }
    end

    def report_unexaminable(records, machine:, ecosystem: "python")
      # The machine is recorded with the records and not swallowed: a test has to be able to see
      # which stamp travelled, because a fact sent under the wrong one is a fact the service can
      # never retire.
      @calls << ["unexaminable", ecosystem, machine, records]
      raise Errors::CorpusError, "refused" if @raise_on.include?("unexaminable")

      { "recorded" => records.length }
    end

    def contribute_advisories(records, ecosystem: "ruby")
      # The whole picture, recorded so a test can see the leads that travelled rather than only that
      # a request was made.
      @calls << ["advisories", ecosystem, records]
      raise Errors::CorpusError, "refused" if @raise_on.include?("advisories")

      { "recorded" => records.length }
    end
  end

  # A fake that pages like the real feed: rows after the cursor, oldest first.
  #
  # `one_page` hands back the same page whatever cursor it is given, which cannot express the
  # difference between a walk from the beginning of the corpus and a walk from a position inside it —
  # the question the cursor tests exist to ask.
  class FeedSession < FakeSession
    def initialize(rows, **kwargs)
      super([], **kwargs)
      @rows = rows
    end

    def changes(since: nil, since_id: nil, limit: 100)
      @calls << ["changes", since, since_id]
      ordered = @rows.sort_by { |row| [row["updated_at"], row["id"].to_s] }
      if since
        cursor = [since, since_id.to_s]
        # written as the spaceship the sort above already relies on.
        ordered = ordered.select do |row|
          ([row["updated_at"], row["id"].to_s] <=> cursor).positive?
        end
      end
      page = ordered.first(limit)
      page.each { |item| @bodies[item["id"].to_s] = item }
      { "items" => page,
        "has_more" => ordered.length > page.length,
        "next_since" => page.empty? ? since : page.last["updated_at"],
        "next_since_id" => page.empty? ? since_id : page.last["id"].to_s }
    end
  end

  attr_reader :deadlines

  def setup
    super
    @deadlines = []
    @findings = []
    @replaced = []
    test = self

    # Every deadline the service asked an install for, in order, so a test can ask what the pricing
    # decided rather than only that a cycle ran.
    replace(Envs, :build, lambda do |package, version, home:, deadline: Envs::INSTALL_TIMEOUT|
      test.deadlines << deadline
      Envs::Env.new(package: package, version: version, root: home + "#{package}-#{version}")
    end)
    replace(AgentsFyiMiner::Versions, :release_history,
      lambda do |package, cache: nil, offline: false, max_age: nil|
        HISTORY.fetch(package) { raise AgentsFyiMiner::Versions::NoHistory, "no history for #{package}" }
      end)
    replace(AgentsFyiMiner::Mine, :findings_between, ->(*_args, **_kwargs) { test.findings.dup })
  end

  def teardown
    # A trap outlives the call that installed it, and `run` installs one that points at a service
    # which is finished by the time the next test starts.
    %w[TERM INT].each do |name|
      Signal.trap(name, "DEFAULT")
    rescue ArgumentError, ThreadError
      nil
    end
    @replaced.reverse_each do |mod, name, original|
      mod.singleton_class.send(:define_method, name, original)
    end
    super
  end

  def findings = @findings

  def replace(mod, name, body)
    original = mod.method(name)
    mod.singleton_class.send(:define_method, name, body)
    @replaced << [mod, name, original]
  end

  def finding
    Finding.new(
      library: "sqlalchemy",
      version: "2.0.54",
      mechanism: Mechanism::PARAMETER_REMOVED,
      title: "sqlalchemy 2.0.54 removed the convert_unicode= argument",
      problem: "gone",
      resolution: "`convert_unicode=` is gone in sqlalchemy 2.0.54. Pin below this release.",
      parameter: "convert_unicode"
    )
  end

  # One page of the change feed, with the cursor pair the service returns.
  def one_page(items = [])
    [{ "items" => items, "has_more" => false,
       "next_since" => "2026-02-01T00:00:00Z", "next_since_id" => "x" }]
  end

  # A service with the network and the package installer taken out.
  def make(session, findings: [], watchlist: ["sqlalchemy"], store: nil, **kwargs)
    @findings = findings
    store ||= @home + "ledger.json"
    ledger = kwargs.delete(:ledger) || Ledger.load(store)
    Service.new(session: session, home: @home, state: store, watchlist: watchlist,
      ledger: ledger, **kwargs)
  end

  def load(store = nil) = Ledger.load(store || (@home + "ledger.json"))

  def pair_named(index)
    Pair.of(package: "pkg#{index}", from_version: "1.0", to_version: "2.0")
  end

  # A gem this deployment has read, as two documents on disk: the versions payload (which is
  # what the settle pass enumerates — `cached_gems`) and the compact index's document, which
  # is what the facts are read from now that they carry dependencies. Both, because the
  # production path fetches the index once and caches it, and a test that left it out would
  # reach the network.
  def cached_gem(home, package, releases)
    FileUtils.mkdir_p(home + "index")
    (home + "index" + "#{package}#{AgentsFyiMiner::RubyVersions::CACHE_SUFFIX}").write(
      JSON.generate(
        "releases" => Array.new(releases) do |index|
          { "number" => "1.0.#{index}", "ruby_version" => ">= 2.7.0", "prerelease" => false }
        end
      )
    )
    lines = Array.new(releases) { |index| "1.0.#{index} rack:~> 1.0|checksum:aa,ruby:>= 2.7.0" }
    (home + "index" + "#{package}#{AgentsFyiMiner::RubyIndex::CACHE_SUFFIX}").write(lines.join("\n"))
  end

  # --- the deadline the pricing decides ---------------------------------------------------

  def test_a_release_with_a_priced_payload_gets_a_deadline_above_the_floor
    # The wiring rather than the arithmetic: what the service asks `Envs.build` for.
    #
    # A sizes file in the index cache and a measured rate is everything the pricing needs. Without
    # them the deadline is the flat floor of five minutes, which is what every release had before —
    # and which is what the machine-learning tail could never finish inside, so each attempt paid it
    # in full and discarded every byte.
    FileUtils.mkdir_p(@home + "index")
    (@home + "index" + "sqlalchemy.sizes.json").write(
      JSON.generate("2.0.54" => 700 * 1024 * 1024)
    )
    pair = Pair.of(package: "sqlalchemy", from_version: "2.0.54", to_version: "2.0.55")
    miner = make(FakeSession.new(one_page), findings: [])
    miner.instance_variable_set(:@rate, 2_800_000.0)
    miner.build(pair, "2.0.54")

    priced = @deadlines.first
    refute_nil priced
    assert_operator priced, :>, Envs::INSTALL_TIMEOUT
    assert_operator priced, :<=, Envs::MAX_INSTALL_TIMEOUT
  end

  def test_a_release_the_index_did_not_price_keeps_the_flat_deadline
    # Nothing is invented for a release with no sizes beside its history.
    pair = Pair.of(package: "sqlalchemy", from_version: "2.0.54", to_version: "2.0.55")
    miner = make(FakeSession.new(one_page), findings: [])
    miner.instance_variable_set(:@rate, 2_800_000.0)
    miner.build(pair, "2.0.54")

    assert_equal [Envs::INSTALL_TIMEOUT], @deadlines
  end

  # --- filing ---------------------------------------------------------------------------

  def test_a_cycle_files_what_it_found_and_records_the_pair
    session = FakeSession.new(one_page)
    miner = make(session, findings: [finding])
    stats = miner.one_cycle

    assert_equal 1, stats.findings
    assert_equal 1, stats.filed
    assert_includes session.calls, ["submit", finding.title, nil]
    assert_equal 1, load.yielded("sqlalchemy")
  end

  def test_the_release_date_the_index_gave_reaches_the_filing
    # The date travels with the report, because it is what lets a reader tell a fact their training
    # data could hold from one it could not. Read from the sidecar the history fetch writes, and
    # nothing is asked for when the sidecar is there.
    FileUtils.mkdir_p(@home + "index")
    (@home + "index" + "sqlalchemy.dates.json").write(
      JSON.generate("2.0.54" => "2026-06-01T09:30:00.000000Z")
    )

    session = FakeSession.new(one_page)
    make(session, findings: [finding]).one_cycle

    assert_includes session.calls, ["submit", finding.title, "2026-06-01T09:30:00.000000Z"]
  end

  def test_a_filing_the_cache_cannot_date_asks_the_index_rather_than_losing_it
    # Driven through `file` alone, because the planner's own walk also reads the history: a cycle
    # would have the fetch happen while planning and hide whether the filing path can recover a date
    # on its own.
    #
    # This is the shape the live deployment produced — `about-time 3.3.0` filed with a null at 20:40
    # — and a null is permanent, so the value is asked for once at the moment it can still be stored
    # rather than written off as absence.
    asked = []
    replace(AgentsFyiMiner::Versions, :release_history,
      lambda do |package, cache: nil, offline: false, max_age: nil|
        asked << package
        # As the real one does, and it has to: a fake that assumed the directory existed would
        # raise into `release_date`'s handler and read as "no date", which is the answer this
        # test exists to tell apart from having one.
        FileUtils.mkdir_p(cache)
        (cache + "#{package}.dates.json").write(
          JSON.generate("2.0.54" => "2026-06-01T09:30:00.000000Z")
        )
        HISTORY.fetch(package)
      end)
    session = FakeSession.new(one_page)
    miner = make(session, findings: [])

    miner.file(finding, Pair.of(package: "sqlalchemy", from_version: "1.4.54", to_version: "2.0.54"),
      Service::Stats.new)

    assert_equal ["sqlalchemy"], asked
    assert_includes session.calls, ["submit", finding.title, "2026-06-01T09:30:00.000000Z"]
  end

  # --- failures the cycle survives --------------------------------------------------------

  def test_a_pair_that_cannot_be_built_is_recorded_for_a_later_attempt
    # A service that exits because one package would not install is a service that stops on the first
    # hard package.
    replace(Envs, :build, ->(*_args, **_kwargs) { raise Errors::MinerError, "no wheel for this interpreter" })
    session = FakeSession.new(one_page)
    miner = make(session, findings: [])
    stats = miner.one_cycle

    record = load.pair("sqlalchemy", "1.4.54", "2.0.54")
    assert_equal 1, stats.skipped
    assert_equal Ledger::FAILED, record.outcome
    assert_equal 1, record.attempts
  end

  def test_a_release_that_cannot_be_built_is_settled_once_rather_than_attempted_three_times
    # The other half of the same failure, and the one that costs the schedule: a release the
    # environment cannot produce is a fact about the release, so it is settled on the first attempt,
    # recorded against the release, and counted apart from the transient skips — a cycle that spent
    # its whole budget here looks, in every other number, exactly like one that examined twelve pairs.
    failure = Errors::MinerError.new(
      "could not install wrapt==1.13.3: No matching distribution found",
      permanent: true, release: "wrapt 1.13.3"
    )
    replace(Envs, :build, ->(*_args, **_kwargs) { raise failure })
    session = FakeSession.new(one_page)
    miner = make(session, findings: [])
    stats = miner.one_cycle

    record = load.pair("sqlalchemy", "1.4.54", "2.0.54")
    assert_equal Ledger::UNEXAMINABLE, record.outcome
    assert_equal "wrapt 1.13.3", record.release
    # Not due again, ever: this is the difference from `FAILED`, which comes back.
    refute miner.ledger.due?("sqlalchemy", "1.4.54", "2.0.54", now: Time.now.to_f + 10**6)
    assert_equal 1, stats.unexaminable
    assert_includes stats.summary, "unexaminable"
  end

  def test_a_cycle_reports_what_this_machine_cannot_build_to_the_service
    # The half the service cannot observe: nothing was filed and nothing was searched for, the
    # release simply would not build. The queue's own tail is what it makes honest, so the fact has
    # to leave this process rather than only reach the log.
    failure = Errors::MinerError.new(
      "could not install wrapt==1.13.3: No matching distribution found",
      permanent: true, release: "wrapt 1.13.3"
    )
    replace(Envs, :build, ->(*_args, **_kwargs) { raise failure })
    session = FakeSession.new(one_page)
    miner = make(session, findings: [])
    stats = miner.one_cycle

    reported = session.calls.find { |call| call.first == "unexaminable" }
    refute_nil reported, "the cycle recorded the fact and never told the service"
    assert_equal ["python", miner.ledger.unexaminable_picture.fetch(:machine)], reported[1, 2]
    assert_equal [{ package: "sqlalchemy", release: "wrapt 1.13.3",
                    reason: "could not install wrapt==1.13.3: No matching distribution found" }],
      reported[3]
    assert(stats.notes.any? { |note| note.include?("reported 1 release(s)") })
  end

  def test_a_report_the_service_declines_does_not_cost_the_cycle_that_produced_it
    # The report is a courtesy and the ledger is the work: a service that refused it — briefly
    # unreachable, or reading a body it will not take — must not leave the facts unsaved, or the
    # machine relearns the same release every cycle for ever.
    failure = Errors::MinerError.new("no wheel for this interpreter", permanent: true,
      release: "wrapt 1.13.3")
    replace(Envs, :build, ->(*_args, **_kwargs) { raise failure })
    session = FakeSession.new(one_page, raise_on: ["unexaminable"])
    miner = make(session, findings: [])
    stats = miner.one_cycle

    assert_equal Ledger::UNEXAMINABLE, load.pair("sqlalchemy", "1.4.54", "2.0.54").outcome
    assert_equal 1, stats.unexaminable
  end

  def test_a_paused_index_is_not_told_what_it_cannot_examine
    # A pause is a decision rather than a fault, and this is a write for an index the service is not
    # taking evidence about — logged with the reason, and the cycle goes on: the pairs that could not
    # be filed are still unsettled, so the work is there when the pause lifts.
    failure = Errors::MinerError.new("no wheel for this interpreter", permanent: true,
      release: "wrapt 1.13.3")
    replace(Envs, :build, ->(*_args, **_kwargs) { raise failure })
    session = FakeSession.new(one_page)
    miner = make(session, findings: [])
    paused = Errors::CollectionPaused.new("collection paused: maintenance", ecosystem: "python")
    replace(session, :report_unexaminable,
      ->(*_args, **_kwargs) { raise paused })

    stats = miner.one_cycle

    assert_equal Ledger::UNEXAMINABLE, load.pair("sqlalchemy", "1.4.54", "2.0.54").outcome
    refute(stats.notes.any? { |note| note.include?("reported") })
  end

  def test_a_finding_the_corpus_declines_settles_the_pair
    # The corpus read this finding and said no, so re-examining the pair reaches the same refusal.
    # Minutes of work to hear the same answer is what the ledger exists to prevent.
    session = FakeSession.new(one_page, raise_on: ["submit"])
    miner = make(session, findings: [finding])
    stats = miner.one_cycle

    assert_equal 1, stats.pairs_mined
    assert_equal 0, stats.filed
    assert(stats.notes.any? { |note| note.include?("filing failed") })
    assert_equal Ledger::DONE, load.pair("sqlalchemy", "1.4.54", "2.0.54").outcome
  end

  def test_a_finding_that_could_not_be_sent_leaves_the_pair_unsettled
    # A dropped connection is not a refusal: the finding is real, it is not in the corpus, and
    # recording the pair as examined would lose it silently. The environments are already built, so
    # re-deriving it is cheap.
    session = FakeSession.new(one_page, raise_on: ["submit"])
    session.transient = true
    miner = make(session, findings: [finding])
    miner.one_cycle

    record = load.pair("sqlalchemy", "1.4.54", "2.0.54")
    assert_equal Ledger::FAILED, record.outcome
    assert_includes record.note, "not filed"
    refute load.settled_pair?("sqlalchemy", "1.4.54", "2.0.54")
  end

  def test_a_cycle_that_hits_the_quota_waits_instead_of_crashing
    session = FakeSession.new(one_page, raise_on: ["submit"])
    session.define_singleton_method(:submit_mined) do |*_args, **_kwargs|
      raise Errors::RateLimited.new("quota spent", retry_after: 7)
    end
    miner = make(session, findings: [finding])
    total = miner.run(cycles: 2, pace: false)

    assert(total.notes.any? { |note| note.include?("rate limited") })
  end

  def test_a_paused_index_waits_without_settling_the_pair
    # A pause is not a verdict on the pair, and this is the handler where getting that wrong retires
    # the work: the filing helper's own `CorpusError` branch returns an outcome, the caller records
    # it, and the pair is settled — which is the loss `AGENTS.md` records for the quota meeting that
    # branch, with a longer window, since an index is paused for hours rather than for the rest of a
    # minute.
    #
    # So the assertion is the ledger, not the note: the pair must still be unsettled, and the run must
    # have said why it stopped.
    session = FakeSession.new(one_page, raise_on: ["submit"])
    session.define_singleton_method(:submit_mined) do |*_args, **_kwargs|
      raise Errors::CollectionPaused.new("the python queue is paused: Ruby is being brought up first.")
    end
    miner = make(session, findings: [finding])
    total = miner.run(cycles: 2, pace: false)

    assert(total.notes.any? { |note| note.include?("collection paused") })
    refute load.settled_pair?("sqlalchemy", "1.4.54", "2.0.54")
  end

  def test_an_unreachable_corpus_does_not_end_the_service
    session = FakeSession.new(one_page)
    session.define_singleton_method(:changes) do |**_kwargs|
      raise Errors::CorpusError, "could not be reached"
    end
    miner = make(session, findings: [])
    total = miner.run(cycles: 1, pace: false)

    assert(total.notes.any? { |note| note.include?("could not be reached") })
  end

  def test_an_unexpected_failure_costs_a_cycle_not_the_process
    # A background service that exits on an unexpected error stops the work everybody else is waiting
    # on. The traceback is logged in full, so a real bug is still loud; surviving it is what keeps the
    # miner mining.
    session = FakeSession.new(one_page)
    miner = make(session, findings: [])
    miner.define_singleton_method(:refresh_ledger) { |_stats| raise "something nobody planned for" }
    total = miner.run(cycles: 2, pace: false)

    assert(total.notes.any? { |note| note.include?("cycle failed") })
  end

  def test_an_unreachable_index_is_one_package_withheld_not_a_dead_service
    # A DNS blip while reading PyPI ended the process in production: the service restarted, and the
    # corpus stopped growing until somebody noticed. The index is a third party, and its being down is
    # a fact about one package.
    replace(AgentsFyiMiner::Versions, :release_history,
      lambda do |_package, cache: nil, offline: false, max_age: nil|
        raise SocketError, "[Errno -5] No address associated with hostname"
      end)
    session = FakeSession.new(one_page)
    miner = make(session, findings: [])
    stats = miner.one_cycle

    assert_equal 0, stats.pairs_mined
    assert(stats.notes.any? { |note| note.include?("No address associated") })
  end

  # --- the loop ---------------------------------------------------------------------------

  def test_the_stop_flag_ends_the_loop_between_cycles
    # `docker stop` sends SIGTERM and waits; the cycle finishes and the ledger is written rather than
    # the process being killed mid-write.
    session = FakeSession.new(one_page)
    miner = make(session, findings: [])
    session.define_singleton_method(:me) do
      result = FakeSession.instance_method(:me).bind_call(self)
      miner.stop = true
      result
    end
    miner.run(cycles: 0, pace: false)

    assert_equal 1, session.calls.count { |call| call.first == "changes" }
  end

  def test_a_cycle_that_retired_an_unbuildable_release_is_not_treated_as_idle
    # A cycle that produced nothing to mine and a cycle that found nothing to do look identical in
    # the pair count, and they are not the same thing at all: the first spent its whole budget
    # establishing that releases cannot be built here, which is progress through a backlog, and
    # sleeping ten minutes between batches of that would take hours over a list whose answer is
    # already known.
    failure = Errors::MinerError.new("could not install pkg==1.0: No matching distribution found",
      permanent: true, release: "pkg 1.0")
    replace(Envs, :build, ->(*_args, **_kwargs) { raise failure })
    miner = make(FakeSession.new(one_page), findings: [])
    waits = []
    miner.define_singleton_method(:wait) { |seconds, pace:| waits << seconds }
    miner.run(cycles: 2, pace: true)

    assert miner.ledger.unexaminable("sqlalchemy").any?
    # A bounded run waits between its cycles and not after the last one, so one wait for two cycles —
    # and it is the cycle interval rather than the ten-minute idle.
    assert_equal [Service::CYCLE_SECONDS], waits
  end

  def test_the_heartbeat_is_touched_at_the_end_of_every_cycle
    # The process being up says nothing about whether it is still working, and a miner that silently
    # stopped mining looks exactly like one that is thinking.
    beat = @home + "heartbeat"
    session = FakeSession.new(one_page)
    miner = make(session, findings: [], heartbeat: beat)

    refute beat.exist?
    miner.run(cycles: 2, pace: false)
    assert beat.exist?
    assert_operator beat.read.to_f, :>, 0
  end

  # --- the write budget -------------------------------------------------------------------

  def test_the_write_budget_stops_a_cycle_rather_than_the_service
    # The service's quota is 60 writes an hour, and the miner holds one operator's key. Spending it
    # all in one cycle would make the corpus less able to hear from the agents it exists for.
    session = FakeSession.new(one_page)
    miner = make(session, findings: [finding], watchlist: %w[click sqlalchemy],
      budget: 2, writes_per_hour: 1)
    stats = miner.one_cycle

    assert_equal 1, stats.filed
    assert(stats.notes.any? { |note| note.include?(Service::BUDGET_SPENT) })
  end

  def test_a_pair_the_budget_held_back_is_not_marked_examined
    # Nothing was filed, so the work is not done: the next cycle has to resume it rather than believe
    # the corpus already has the finding.
    session = FakeSession.new(one_page)
    miner = make(session, findings: [finding], watchlist: %w[click sqlalchemy],
      budget: 2, writes_per_hour: 1)
    miner.one_cycle
    store = load

    assert_equal 1, store.settled("click") + store.settled("sqlalchemy")
  end

  def test_the_budget_is_a_rolling_window_not_a_counter_on_the_hour
    # A counter reset on the hour would let the miner spend forty writes at ten to the hour and forty
    # more at the hour: eighty in ten minutes, exactly the burst the quota exists to stop.
    budget = Service::WriteBudget.new(per_window: 2, window: 3600.0)

    assert budget.allow(now: 0.0)
    assert budget.allow(now: 3599.0)
    refute budget.allow(now: 3599.9)
    assert budget.allow(now: 3600.0)
    refute budget.allow(now: 3600.1)
  end

  def test_asking_whether_a_write_fits_does_not_spend_one
    budget = Service::WriteBudget.new(per_window: 1, window: 3600.0)

    refute budget.exhausted?(now: 0.0)
    refute budget.exhausted?(now: 0.0)
    assert budget.allow(now: 0.0)
    assert budget.exhausted?(now: 0.0)
  end

  def test_no_budget_means_no_counting
    # The default, and the mechanism's own reason for existing: `0` is not a limit of zero, it is the
    # absence of one, and the count would be a slow leak in a process that runs for weeks.
    budget = Service::WriteBudget.new(per_window: 0)

    assert budget.unlimited?
    100.times { assert budget.allow }
    assert_empty budget.spent
    refute budget.exhausted?
  end

  # --- the corpus's backlog ----------------------------------------------------------------

  def test_the_change_feed_is_walked_from_the_cursor_the_ledger_remembers
    # A cursor is a position, and the position is stored with the work it describes: re-reading the
    # whole corpus every cycle would not scale, and re-reading it *and* re-considering it would be
    # worse.
    miner = make(FeedSession.new([REPORT]), findings: [],
      ledger: Ledger.new(cursor_since: "2026-01-01T00:00:00Z", cursor_id: "seed"))
    miner.one_cycle

    assert_includes miner.session.calls, ["changes", "2026-01-01T00:00:00Z", "seed"]
    assert_equal "2026-01-01T00:00:00Z", load.cursor_since
  end

  def test_the_first_cycle_reads_the_whole_feed_when_a_cursor_is_already_past_it
    # A cursor is an optimisation for staying current, not a substitute for knowing what is in the
    # corpus. A report filed before this miner existed sits behind it for ever, so the first cycle of
    # a process walks from the beginning — once, and bounded.
    miner = make(FeedSession.new([REPORT]), findings: [finding],
      ledger: Ledger.new(cursor_since: "2027-01-01T00:00:00Z", cursor_id: "later"))
    stats = miner.one_cycle

    assert_includes miner.session.calls, ["changes", nil, nil]
    assert_equal 1, stats.answered
    assert(stats.notes.any? { |note| note.include?("reconciled") })
    assert_equal "2027-01-01T00:00:00Z", load.cursor_since

    # Once only: the second cycle is back on the cursor, and the cursor has not been moved backwards
    # by the reconciliation.
    miner.session.calls.clear
    miner.one_cycle
    refute_includes miner.session.calls, ["changes", nil, nil]
  end

  def test_a_report_the_change_feed_will_never_offer_again_is_still_answered
    # The feed is a cursor — a position — so a report filed before this miner started sits behind it
    # for ever. The backlog is what makes the solver a search for open questions rather than a reader
    # of recent changes; without it, the corpus's existing unanswered reports would never be visited by
    # the process built to answer them.
    session = FakeSession.new([])
    session.bodies = { REPORT["id"] => REPORT }
    miner = make(session, findings: [finding], ledger: Ledger.new(backlog: { REPORT["id"] => 1.0 }))
    stats = miner.one_cycle

    assert_equal 1, stats.answered
  end

  def test_a_report_nothing_can_answer_is_dropped_rather_than_fetched_forever
    # Keeping a platform outage in the work list would mean re-reading it every cycle to reach the
    # same conclusion, and the backlog would become the corpus.
    session = FakeSession.new([])
    session.bodies = { REPORT["id"] => REPORT.merge("subject_kind" => "platform") }
    miner = make(session, findings: [], ledger: Ledger.new(backlog: { REPORT["id"] => 1.0 }))
    miner.one_cycle

    refute load.seen?(REPORT["id"])
  end

  def test_a_report_the_corpus_no_longer_has_is_dropped_rather_than_asked_for_again
    # A permanent refusal is the corpus's answer, not a bad minute: the same request reaches it again
    # next cycle and the cycle after that. Five reports that had been deleted were re-fetched on every
    # pass for ever, one of them a warning in the log each time, each spending one of the `limit * 4`
    # looks the loop is bounded by. An outage is the other kind and must keep its entry — see the test
    # below.
    session = FakeSession.new([])
    miner = make(session, findings: [], ledger: Ledger.new(backlog: { REPORT["id"] => 1.0 }))
    miner.one_cycle

    refute load.seen?(REPORT["id"])
  end

  def test_a_report_that_could_not_be_read_over_an_outage_keeps_its_place
    # Dropping the entry here would lose work over a DNS blip, which is exactly what the `limit * 4`
    # skip was written to avoid — so the entry survives, and the next cycle asks again.
    session = FakeSession.new([])
    session.transient = true
    miner = make(session, findings: [], ledger: Ledger.new(backlog: { REPORT["id"] => 1.0 }))
    miner.one_cycle

    assert load.seen?(REPORT["id"])
  end

  def test_the_miner_does_not_verify_its_own_reports
    # The service counts a confirmation only from an operator other than a report's author, so voting
    # on our own would spend three writes to record a row that no number reads — and would look like
    # independent reproduction in a corpus where it is nothing of the kind.
    #
    # `me` reports operator-1, so this is a report this miner filed itself.
    mine = REPORT.merge("submitted_by" => "operator-1", "status" => "resolved_unverified",
      "resolution" => "rename to convert_unicode")
    session = FakeSession.new(one_page([mine]))
    miner = make(session, findings: [finding])
    stats = miner.one_cycle

    assert_equal 0, stats.answered
    refute_includes session.calls.map(&:first), "claim"
    assert(stats.notes.any? { |note| note.include?("this miner's own") })
  end

  # --- answering --------------------------------------------------------------------------

  def test_a_report_the_miner_can_reproduce_is_answered_and_the_claim_released
    session = FakeSession.new(one_page([REPORT]))
    miner = make(session, findings: [finding])
    stats = miner.one_cycle

    assert_equal 1, stats.answered
    kinds = session.calls.map(&:first)
    assert_includes kinds, "claim"
    assert_includes kinds, "resolution"
    assert_includes kinds, "release"
    assert_operator kinds.index("claim"), :<, kinds.index("resolution")
    assert_operator kinds.index("resolution"), :<, kinds.index("release")
  end

  def test_an_open_report_still_claims_before_the_work
    # The reservation is what stops two miners deriving the same fix, and that reason has not gone away
    # for the reports that are genuinely unsolved.
    session = FakeSession.new(one_page([REPORT]))
    miner = make(session, findings: [finding])
    miner.one_cycle

    kinds = session.calls.map(&:first)
    assert_operator kinds.index("claim"), :<, kinds.index("resolution")
    assert_operator kinds.index("resolution"), :<, kinds.index("release")
  end

  def test_a_report_that_already_has_a_fix_is_reproduced_without_being_claimed
    # A claim is a reservation on *unsolved* work. The corpus refuses one on a report that already
    # carries a fix — deliberately, because such a report is not waiting for anybody — so a solver
    # that claimed first got a 409 and bailed out before it could reach the reproduction it had been
    # selected to give.
    #
    # Found by running the real command against the live service; every unit test passed, because the
    # fake session happily accepted a claim the service never would.
    fixed = REPORT.merge("status" => "resolved_unverified", "resolution" => "rename to encoding=")
    session = FakeSession.new(one_page([fixed]))
    # The service's own rule, modelled here: a report with a fix cannot be claimed.
    session.define_singleton_method(:claim) do |report_id|
      @calls << ["claim", report_id]
      report = @bodies[report_id]
      raise Errors::CorpusError, "already carries a resolution" if report && report["resolution"]

      nil
    end

    with_fix = finding
    with_fix.replacement = "encoding"
    with_fix.resolution = "Rename the argument: `convert_unicode=` is `encoding=`."
    with_fix.mechanism = Mechanism::PARAMETER_RENAMED
    session.bodies[fixed["id"]] = fixed

    miner = make(session, findings: [with_fix])
    stats = miner.one_cycle

    kinds = session.calls.map(&:first)
    refute_includes kinds, "claim"
    assert_includes kinds, "verify"
    refute_includes kinds, "release"
    assert_equal 1, stats.answered
  end

  def test_a_report_the_miner_cannot_explain_is_not_re_derived_every_cycle
    # Minutes of environment building per cycle to hear the same "no" is the waste the ledger exists to
    # prevent.
    session = FakeSession.new(one_page([REPORT]))
    miner = make(session, findings: [])
    miner.one_cycle
    session.pages = one_page([REPORT])
    miner.one_cycle

    assert_equal 1, session.calls.count { |call| call.first == "claim" }
    assert_equal "no_mechanism", load.report(REPORT["id"]).outcome
  end

  def test_a_report_somebody_else_holds_is_left_to_them
    session = FakeSession.new(one_page([REPORT]), raise_on: ["claim"])
    miner = make(session, findings: [finding])
    stats = miner.one_cycle

    assert_equal 1, stats.skipped
    refute_nil load.report(REPORT["id"])
  end

  # --- the examining, in parallel -----------------------------------------------------------

  def test_several_upgrades_are_examined_at_once
    # One pair at a time left seventeen of this host's twenty cores unused and made the corpus grow at
    # the speed of a single wheel install. The examining is subprocess-bound, so this is the only dial
    # that makes it faster.
    seen = []
    lock = Mutex.new
    barrier = Barrier.new(3)
    miner = Service.new(session: FakeSession.new([]), home: @home, state: @home + "ledger.json",
      watchlist: [], ledger: Ledger.new, workers: 3)
    miner.define_singleton_method(:examine) do |pair|
      lock.synchronize { seen << pair.package }
      barrier.wait # only completes if three run concurrently
      [[], nil]
    end
    miner.mine_all((0...3).map { |index| pair_named(index) }, Service::Stats.new)

    assert_equal %w[pkg0 pkg1 pkg2], seen.sort
  end

  def test_the_bookkeeping_stays_on_one_thread
    # The ledger is one file, the filings are one operator's writes, and the counter that decides how
    # much gets filed is one number. Only the examining is parallel, so the pair records are written
    # where nothing races them.
    miner = Service.new(session: FakeSession.new([]), home: @home, state: @home + "ledger.json",
      watchlist: [], ledger: Ledger.new, workers: 4)
    miner.define_singleton_method(:examine) { |_pair| [[], nil] }
    threads = []
    lock = Mutex.new
    original = miner.ledger.method(:record_pair)
    miner.ledger.define_singleton_method(:record_pair) do |*args, **kwargs|
      lock.synchronize { threads << Thread.current.object_id }
      original.call(*args, **kwargs)
    end
    miner.mine_all((0...5).map { |index| pair_named(index) }, Service::Stats.new)

    assert_equal [Thread.current.object_id], threads.uniq
  end

  def test_a_failure_in_one_examination_costs_one_pair_not_the_cycle
    # A defect in the examining is a defect; it should cost the pair it was examining rather than every
    # pair in the batch and the cycle that ran them.
    miner = Service.new(session: FakeSession.new([]), home: @home, state: @home + "ledger.json",
      watchlist: [], ledger: Ledger.new, workers: 3)
    miner.define_singleton_method(:examine) do |pair|
      raise "a bug nobody planned for" if pair.package == "pkg2"

      [[], nil]
    end
    stats = Service::Stats.new
    miner.mine_all((0...4).map { |index| pair_named(index) }, stats)

    assert_equal 3, stats.pairs_mined
    assert_equal 1, stats.skipped
    assert_equal 0, miner.ledger.settled("pkg2")
  end

  # --- what a gem's releases declare --------------------------------------------------------

  def test_a_gems_history_longer_than_one_page_is_pushed_in_pages
    # The route takes at most `REQUIREMENTS_PAGE` releases and its body cap refuses a whole history, so
    # sending a gem at once was refused for every gem past 500 — `sorbet-runtime` declares 1,939 here,
    # `aws-partitions` 1,291 — which made the facts inert for exactly the gems with the most to say.
    # Pages, and every release reaches the service in one of them.
    count = Service::REQUIREMENTS_PAGE + 7
    cached_gem(@home, "big-gem", count)
    session = FakeSession.new(one_page)
    miner = make(session)

    miner.record_requirements("big-gem")

    pushes = session.calls.select { |call| call.first == "facts" }
    # Every page full but the last, and every release in exactly one of them.
    assert_equal [Service::REQUIREMENTS_PAGE, 7], pushes.map { |call| call[2].length }
    sent = pushes.flat_map { |call| call[2].map { |fact| fact["version"] } }
    assert_equal (0...count).map { |index| "1.0.#{index}" }.sort, sent.sort
    assert_equal sent.length, sent.uniq.length
  end

  def test_a_page_the_corpus_could_not_take_leaves_the_gem_to_be_sent_again
    # An outage is not an answer: the gem stays unsettled so another cycle sends it. Marking it settled
    # after a failure would leave the corpus holding half a history and no record that the rest was
    # ever meant to be there.
    cached_gem(@home, "big-gem", Service::REQUIREMENTS_PAGE + 7)
    session = FakeSession.new(one_page, raise_on: ["facts"])
    session.transient = true
    miner = make(session)

    refute miner.record_requirements("big-gem")
    assert_empty miner.requirements_settled
  end

  def test_a_gem_the_corpus_refused_is_settled_rather_than_asked_about_for_ever
    # A 4xx is the corpus reading this gem and declining it, which is the same answer every time — a
    # gem name past the route's 120 characters can never be accepted. The transient case above is the
    # one worth retrying; this one is minutes of asking for an answer that will not change.
    cached_gem(@home, "big-gem", 3)
    session = FakeSession.new(one_page, raise_on: ["facts"])
    miner = make(session)

    assert miner.record_requirements("big-gem")
    assert_equal Set["big-gem"], miner.requirements_settled
  end

  def test_a_cached_gem_the_plan_never_reaches_still_has_its_requirements_recorded
    # The gap this pass exists for. Facts used to be pushed only where the planner read a history, so a
    # gem whose pairs were all mined kept its document on this volume and still had no requirement in
    # the corpus: measured on the deployment, 466 cached gem documents and 445 recorded, and the
    # twenty-one missing were the largest — every gem whose history ran past the old one-request cap.
    # Nothing here plans anything, which is the point.
    %w[activesupport sorbet-runtime stripe].each { |gem| cached_gem(@home, gem, 4) }
    session = FakeSession.new(one_page)
    miner = make(session)

    settled = miner.settle_cached_requirements(Service::REQUIREMENTS_SETTLE_PER_CYCLE)

    assert_equal 3, settled
    assert_equal %w[activesupport sorbet-runtime stripe],
      session.calls.select { |call| call.first == "facts" }.map { |call| call[1] }
  end

  def test_the_settle_pass_is_bounded_and_picks_up_where_it_stopped
    # Bounded per cycle so a pass over every cached gem cannot put the mining it runs beside behind it —
    # and bounded on the *pass* rather than on a position, so the gems it did not reach are the next
    # cycle's work instead of being skipped for ever.
    (0...3).each { |index| cached_gem(@home, "gem-#{index}", 2) }
    session = FakeSession.new(one_page)
    miner = make(session)

    first = miner.settle_cached_requirements(2)
    second = miner.settle_cached_requirements(2)

    assert_equal [2, 1], [first, second]
    assert_equal %w[gem-0 gem-1 gem-2],
      session.calls.select { |call| call.first == "facts" }.map { |call| call[1] }
  end

  def test_a_document_that_could_not_be_read_is_not_settled_but_does_not_stall_the_walk
    # A gem that sends nothing needs one of two opposite treatments and they are not the same case. An
    # empty mapping means *nothing was read*, which `RubyVersions.release_requirements` states in its
    # own docstring — so the gem must not be settled, because a later fetch is exactly what fixes it and
    # settling it here would leave that fetch with nobody to carry it to the corpus. The walk still has
    # to get past it: the unreadable document is deliberately first in sorted order, and a walk that
    # stopped on it would spend every cycle here and never reach the gems behind it.
    FileUtils.mkdir_p(@home + "index")
    (@home + "index" + "aaa-unreadable-gem#{AgentsFyiMiner::RubyVersions::CACHE_SUFFIX}").write(
      "not a document at all"
    )
    cached_gem(@home, "real-gem", 2)
    session = FakeSession.new(one_page)
    miner = make(session)

    settled = miner.settle_cached_requirements(Service::REQUIREMENTS_SETTLE_PER_CYCLE)

    assert_equal 1, settled
    assert_equal Set["real-gem"], miner.requirements_settled
    assert_equal ["real-gem"], session.calls.select { |call| call.first == "facts" }.map { |call| call[1] }

    # Looked at, so the next cycle does not spend its turn on it again — but still not settled, so the
    # schedule path will push it if its document is ever readable.
    assert_equal 0, miner.settle_cached_requirements(Service::REQUIREMENTS_SETTLE_PER_CYCLE)
    assert_equal Set["aaa-unreadable-gem", "real-gem"], miner.requirements_attempted
  end

  # --- the reviewed advisories --------------------------------------------------------------

  # A lead read from the volume and handed to the service, and the same read drives the planner, so a
  # cycle is never a cycle behind the picture it posted. The slow clock is asserted too: a second call
  # inside the window posts nothing.
  def test_the_reviewed_advisories_are_read_from_the_volume_and_contributed_on_a_slow_clock
    lead = { "library" => "rack", "advisory_id" => "GHSA-aaaa-bbbb-cccc", "severity" => "high",
             "fixed_in" => "2.2.6.1", "source_url" => "https://example.test/a" }
    write("index/advisories-ruby.json", [lead])
    session = FakeSession.new(one_page)
    miner = ruby_miner(session)
    stats = Service::Stats.new

    miner.refresh_advisories(stats, now: 100.0)

    sent = session.calls.select { |call| call.first == "advisories" }
    assert_equal 1, sent.length
    assert_equal "ruby", sent.first[1]
    assert_equal "rack", sent.first[2].first.fetch("library")
    assert_equal ["rack"], miner.leads_for(AgentsFyiMiner::Ecosystems::RUBY).keys

    miner.refresh_advisories(stats, now: 200.0)
    assert_equal 1, session.calls.count { |call| call.first == "advisories" }
  end

  # A source that cannot be read with no cache is not a failed cycle: the planner runs with no leads,
  # which is exactly what it did before advisories existed.
  def test_an_unreadable_advisory_source_leaves_the_cycle_to_run_without_leads
    session = FakeSession.new(one_page)
    miner = ruby_miner(session)

    with_stub(AgentsFyiMiner::Advisories, :fetch_page, ->(_url) { raise SocketError, "no route" }) do
      stats = Service::Stats.new
      miner.refresh_advisories(stats, now: 1.0)

      assert_empty miner.leads_for(AgentsFyiMiner::Ecosystems::RUBY)
      assert_equal 0, session.calls.count { |call| call.first == "advisories" }
    end
  end

  # A paused index refuses the picture, and that is info rather than a fault: the leads are still
  # loaded from the cache, so the planner works them while the pause lasts.
  def test_a_paused_index_refuses_the_picture_without_losing_the_leads
    write("index/advisories-ruby.json",
      [{ "library" => "rack", "advisory_id" => "GHSA-aaaa-bbbb-cccc", "severity" => "high",
         "fixed_in" => "2.2.6.1", "source_url" => "https://example.test/a" }])
    session = FakeSession.new(one_page)
    session.define_singleton_method(:contribute_advisories) do |_records, ecosystem: "ruby"|
      @calls << ["advisories", ecosystem]
      raise Errors::CollectionPaused.new("rack is paused", ecosystem: ecosystem)
    end
    miner = ruby_miner(session)

    miner.refresh_advisories(Service::Stats.new, now: 1.0)

    assert_equal ["rack"], miner.leads_for(AgentsFyiMiner::Ecosystems::RUBY).keys
  end

  private

  # A service mining RubyGems, which is the one index the reviewed advisories are read for.
  def ruby_miner(session)
    Service.new(session: session, home: @home, state: @home + "ledger.json",
      watchlist: [], ledger: Ledger.new, ecosystems: [AgentsFyiMiner::Ecosystems::RUBY])
  end
end
