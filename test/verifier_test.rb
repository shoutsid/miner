# frozen_string_literal: true

require_relative "test_helper"

# The verifier's loop, driven with fakes: who it votes on, and who it refuses to.
#
# The service counts a confirmation only from an operator that is not the author, so the two
# failures this file exists to prevent are a vote on its own report and a vote that was never cast
# because the report was quietly dropped. Both look exactly like a working verifier from the
# outside.
#
# Two seams replace `monkeypatch`: `stub` swaps a *module's own* method (`Envs.build`,
# `Verifying.check`) and `stub_method` swaps a class's instance method (`Ledger#record_report`).
# Both restore what they replaced in `teardown`, because these are process-global and a test that
# left one behind would decide the next test's answer — and the block runs against the *test*
# (`instance_exec`), so a stub can still call `assert` or read `@home`.
class VerifierTest < MinerTest
  V = AgentsMiner::Verifier

  REPORTED = {
    "id" => "00000000-0000-0000-0000-000000000001",
    "library" => "httpx",
    "version" => "0.28.1",
    "ecosystem" => "python",
    "subject_kind" => "package",
    "status" => "resolved_unverified",
    "resolution" => "`app=` is gone in httpx 0.28.1. Pin below this release.",
    "problem" => "Upgrading httpx from 0.27.2 to 0.28.1 breaks calls that pass `app=`. Found by " \
                 "executing the same call against both releases: 1 call site accepted it on " \
                 "0.27.2 and were refused on 0.28.1 (AsyncClient(app=…)).\n\n" \
                 "TypeError: AsyncClient.__init__() got an unexpected keyword argument 'app'",
    "signatures" => ["typeerror", "unexpected keyword argument 'app'"],
    "submitted_by" => "the-miner",
    "hidden" => false,
    "updated_at" => "2026-01-01T00:00:00Z"
  }.freeze

  # A Rails move that failed while Bundler was choosing versions. Its subject is `platform`,
  # because the thing that broke is the move rather than a package — and the old reader refused
  # every non-package report before it looked at the output that names the two releases.
  RESOLVER_REPORT = {
    "id" => "00000000-0000-0000-0000-0000000000b9",
    "library" => "rails",
    "version" => "8.0.5.1",
    "ecosystem" => "ruby",
    "subject_kind" => "platform",
    "status" => "resolved_unverified",
    "submitted_by" => "the-upgrader",
    "hidden" => false,
    "updated_at" => "2026-01-01T00:00:00Z",
    "resolution" => "Point `js_image_paths` at the fork whose gemspec allows Rails 8.x.",
    "problem" => <<~PROBLEM
      Could not find compatible versions

      Because js_image_paths >= 0.2.0 depends on rails >= 4.0, < 8.0
        and Gemfile depends on rails = 8.0.5.1,
        js_image_paths >= 0.2.0 cannot be used.
      So, because Gemfile depends on js_image_paths = 0.2.0,
    PROBLEM
  }.freeze

  GEM_REPORT = {
    "id" => "00000000-0000-0000-0000-0000000000a1",
    "library" => "colorize",
    "version" => "1.0.0",
    "ecosystem" => "ruby",
    "from_version" => "0.8.1",
    "subject" => "String#magenta",
    "subject_kind" => "package",
    "change_kind" => "symbol_removed",
    "status" => "resolved_unverified",
    "resolution" => "`String#magenta` is gone in colorize 1.0.0. Pin below this release.",
    "problem" => "Upgrading colorize from 0.8.1 to 1.0.0 breaks code that names " \
                 "`String#magenta`. Found by executing the same reference against both " \
                 "releases: it resolved on 0.8.1 and raised on 1.0.0.",
    "signatures" => ["nomethoderror", "colorize"],
    "submitted_by" => "the-miner",
    "hidden" => false,
    "updated_at" => "2026-01-01T00:00:00Z"
  }.freeze

  # The feed, as the route answers it: one page, with the service's own position of the last row
  # it sent. Rows are ordered and paged by `(updated_at, id)`, which is the cursor the ledger
  # remembers.
  def page(rows, since: nil, since_id: nil, limit: 100)
    ordered = rows.sort_by { |row| [row["updated_at"], row["id"].to_s] }
    if since
      cursor = [since, since_id.to_s]
      # Same ordering, different operator — the kind of difference that makes a ported test
      # fail for a reason that has nothing to do with the code under test.
      ordered = ordered.select { |row| ([row["updated_at"], row["id"].to_s] <=> cursor).positive? }
    end
    shown = ordered.first(limit)
    last = shown.last
    {
      "items" => shown,
      "has_more" => ordered.length > shown.length,
      "next_since" => last ? last["updated_at"] : since,
      "next_since_id" => last ? last["id"].to_s : since_id
    }
  end

  # The corpus, with the feed, the bodies and the writes recorded.
  class FakeSession
    attr_accessor :rows, :bodies, :transient, :after_submit, :paused
    attr_reader :calls, :submit_error

    def initialize(rows = [], submit_error: nil, transient: false)
      @rows = rows
      @bodies = rows.to_h { |row| [row["id"].to_s, row] }
      @calls = []
      @submit_error = submit_error
      @transient = transient
      @after_submit = nil
      @paused = {}
    end

    def me
      @calls << [:me]
      { "id" => "verifier-1" }
    end

    def changes(since: nil, since_id: nil, limit: 100)
      @calls << [:changes, since, since_id]
      # A page per read, which is the shape the route serves; the walk asks again only while
      # `has_more`. The builder is the test's own, so it is reached through the block the test
      # installs — `pager`.
      @pager.call(@rows, since: since, since_id: since_id, limit: limit)
    end

    # Whether the index is collecting, as the queue's own body says. A test that does not set
    # this is a deployment where everything collects, which is the ordinary case.
    def collection_paused?(ecosystem)
      @calls << [:collection_paused, ecosystem]
      @paused.fetch(ecosystem.to_s, false)
    end

    attr_writer :pager

    def report(report_id)
      @calls << [:report, report_id]
      unless @bodies.key?(report_id)
        # The corpus reading this request and declining it, as a deleted report answers for ever.
        # `transient` is the other kind, an outage.
        raise AgentsMiner::Errors::CorpusError.new("no such report #{report_id}",
          permanent: !@transient)
      end
      @bodies[report_id]
    end

    def verify(report_id, payload)
      @calls << [:verify, report_id, payload]
      raise @submit_error if @submit_error

      @after_submit&.call(report_id)
    end
  end

  def fake_session(rows = [], **kwargs)
    session = FakeSession.new(rows, **kwargs)
    session.pager = method(:page)
    session
  end

  # Replace a module's own method, the way `monkeypatch.setattr(envs, "build", …)` did.
  def stub(receiver, name, body)
    singleton = receiver.singleton_class
    had = begin
      singleton.instance_method(name)
    rescue NameError
      nil
    end
    test = self
    singleton.send(:define_method, name) { |*args, **kwargs| test.instance_exec(*args, **kwargs, &body) }
    (@undos ||= []) << lambda do
      if had
        singleton.send(:define_method, name, had)
      else
        singleton.send(:remove_method, name)
      end
    end
    nil
  end

  # Replace a class's *instance* method, the way `monkeypatch.setattr(Ledger, "record_report", …)`
  # did — a different seam from `stub`, because a class method and an instance method of the same
  # class are two different things.
  #
  # The receiver is handed to the body as its first argument. Without it the block would be
  # `instance_exec`'d on the *test*, and the ledger the call was made on would be gone — so a test
  # that wants to reach the replaced method has nothing to reach it with. It is passed explicitly
  # rather than left as `self` because a Ruby block cannot be run with two different `self`es.
  def stub_method(klass, name, body)
    had = klass.instance_method(name)
    test = self
    klass.send(:define_method, name) do |*args, **kwargs, &blk|
      test.instance_exec(self, *args, **kwargs, &body)
    end
    (@undos ||= []) << -> { klass.send(:define_method, name, had) }
    nil
  end

  def teardown
    (@undos || []).reverse_each(&:call)
    super
  end

  def verdict(outcome, executed = "", detail: "", unreachable: false)
    AgentsMiner::Verifying::Verdict.new(outcome: outcome, executed: executed, detail: detail,
      unreachable: unreachable)
  end

  # A verifier with the installer and the probes taken out. `verdicts` scripts what the check
  # returns, keyed by the claim's version.
  def verifier_for(session, verdicts: {}, role: AgentsMiner::Verifying::AS_REPORTED, state: nil,
                   ledger: nil, **rest)
    @check_calls = []
    stub(AgentsMiner::Envs, :build, lambda { |library, version, home:|
      AgentsMiner::Envs::Env.new(package: library, version: version,
        root: @home + "#{library}-#{version}")
    })
    stub(AgentsMiner::Envs, :prune, ->(_home, budget: nil, quiet: nil) { [0, 0] })
    stub(AgentsMiner::RubyEnvs, :prune, ->(_home, budget:, quiet: 900) { [0, 0] })
    stub(AgentsMiner::WheelCache, :prune, ->(_cache, budget: nil, quiet: nil) { [0, 0] })
    stub(AgentsMiner::Verifying, :check, lambda { |claim, chosen_role, build:, suffix: ""|
      @check_calls << [claim.subject, chosen_role, suffix]
      scripted = verdicts[claim.version]
      raise scripted if scripted.is_a?(Exception)

      scripted || verdict(AgentsMiner::Ledger::REPRODUCED, "ran the call")
    })
    store = state || (@home + "ledger-#{role}.json")
    V.new(session: session, home: @home, state: store, role: role,
      ledger: ledger || AgentsMiner::Ledger.load(store), **rest)
  end

  # --- the vote ------------------------------------------------------------

  def test_a_report_nobody_confirmed_is_confirmed_by_execution
    session = fake_session([REPORTED])
    instance = verifier_for(session)
    stats = instance.one_cycle

    votes = session.calls.select { |call| call[0] == :verify }
    assert_equal 1, votes.length
    payload = votes[0][2]
    assert_equal AgentsMiner::Ledger::REPRODUCED, payload["outcome"]
    assert_includes payload["environment"], "httpx 0.28.1"
    assert_equal "ran the call", payload["notes"]
    assert_equal 1, stats.reproduced
    assert_equal AgentsMiner::Ledger::REPRODUCED,
      AgentsMiner::Ledger.load(instance.state).report(REPORTED["id"]).outcome
  end

  def test_the_verifier_never_confirms_its_own_report
    # The service counts a confirmation only from another operator, so this would write a row no
    # number reads while looking like independent reproduction.
    mine = REPORTED.merge("submitted_by" => "verifier-1")
    session = fake_session([mine])
    stats = verifier_for(session).one_cycle

    assert_empty session.calls.select { |call| call[0] == :verify }
    assert_equal 0, stats.reproduced
  end

  def test_a_report_from_an_index_this_verifier_does_not_work_is_dropped_without_a_read
    # The feed row carries the ecosystem, so the scope decision costs no body read and — the half
    # that matters — no look. A verifier that read first would spend its walk on the other index
    # before reaching the one it was asked to work.
    session = fake_session([REPORTED, GEM_REPORT])
    instance = verifier_for(session, ecosystems: [AgentsMiner::Ecosystems::RUBY])

    instance.one_cycle

    assert_nil session.calls.find { |call| call[0] == :report && call[1] == REPORTED["id"] },
      "the Python report is out of scope, so its body is never fetched"
    voted = session.calls.select { |call| call[0] == :verify }.map { |call| call[1] }
    assert_equal [GEM_REPORT["id"]], voted
    ledger = AgentsMiner::Ledger.load(instance.state)
    refute ledger.seen?(REPORTED["id"]), "a scope the deployment chose is not reconsidered every pass"
    assert ledger.seen?(GEM_REPORT["id"])
  end

  def test_a_paused_index_keeps_its_reports_without_installing_them
    # A pause is a decision somebody made and can undo, so the report stays in the backlog. What
    # it must not do is cost two installs to learn that the vote would be refused: the queue states
    # the pause, and the verifier asks before it reads a report.
    session = fake_session([GEM_REPORT])
    session.paused = { "ruby" => true }
    instance = verifier_for(session, ecosystems: [AgentsMiner::Ecosystems::RUBY])

    stats = instance.one_cycle

    assert_empty session.calls.select { |call| call[0] == :verify }
    assert_nil session.calls.find { |call| call[0] == :report },
      "the index is paused, so there is nothing worth reading a report for"
    assert_equal 1, stats.paused
    assert_includes stats.summary, "left for a paused index"
    assert AgentsMiner::Ledger.load(instance.state).seen?(GEM_REPORT["id"])
  end

  def test_one_refused_vote_does_not_abort_the_cycle_or_lose_the_rest
    # The failure this pins: `record` used to re-raise `CollectionPaused`, which threw away every
    # other result in the batch and skipped the ledger save. The next cycle bought the same
    # installs again, so an independent verifier could sit on one paused report for hours.
    session = fake_session([REPORTED, GEM_REPORT])
    session.after_submit = lambda do |report_id|
      next unless report_id == REPORTED["id"]

      raise AgentsMiner::Errors::CollectionPaused.new("python is paused", ecosystem: "python")
    end
    instance = verifier_for(session)

    stats = instance.one_cycle

    voted = session.calls.select { |call| call[0] == :verify }.map { |call| call[1] }
    assert_includes voted, GEM_REPORT["id"], "the other index's report is still voted on"
    assert_equal 1, stats.paused
    ledger = AgentsMiner::Ledger.load(instance.state)
    assert ledger.seen?(REPORTED["id"]), "the refused report stays due and is not recorded as failed"
    assert_nil ledger.report(REPORTED["id"])
    assert_equal AgentsMiner::Ledger::REPRODUCED, ledger.report(GEM_REPORT["id"]).outcome
  end

  def test_a_report_the_corpus_no_longer_has_is_dropped_rather_than_read_forever
    # A verifier's work list is a backlog too, so it has the same trap the miner's had: a report
    # the corpus has deleted answers 404 for ever, and keeping the entry spends one of every cycle
    # on it.
    session = fake_session([]) # the feed does not carry it and the corpus has not got it
    instance = verifier_for(session,
      ledger: AgentsMiner::Ledger.new(backlog: { REPORTED["id"] => 1.0 }))

    instance.one_cycle

    refute AgentsMiner::Ledger.load(instance.state).seen?(REPORTED["id"])
  end

  def test_a_report_that_could_not_be_read_over_an_outage_keeps_its_place
    # The other half of the rule, and why the drop is on `permanent`: an outage is not the corpus
    # answering, and the retry delay `due_report?` schedules exists for exactly this.
    session = fake_session([], transient: true)
    instance = verifier_for(session,
      ledger: AgentsMiner::Ledger.new(backlog: { REPORTED["id"] => 1.0 }))

    instance.one_cycle

    assert AgentsMiner::Ledger.load(instance.state).seen?(REPORTED["id"])
  end

  def test_an_open_report_is_dropped_until_it_gains_a_fix
    # Dropped and not settled: an open report is not a refusal, it is one that will become
    # checkable, and settling it would be a verifier that quietly stopped looking. The change feed
    # re-announces it, which is what makes dropping safe.
    session = fake_session([REPORTED.merge("status" => "open", "resolution" => nil)])
    instance = verifier_for(session)
    instance.one_cycle
    assert_empty session.calls.select { |call| call[0] == :verify }
    assert_nil AgentsMiner::Ledger.load(instance.state).report(REPORTED["id"])

    # Somebody proposes a fix: the report is updated, so it is at the end of the feed again with a
    # later timestamp.
    session.rows = [REPORTED.merge("updated_at" => "2026-01-02T00:00:00Z")]
    session.bodies = { REPORTED["id"] => session.rows[0] }
    stats = instance.one_cycle
    assert_equal 1, stats.reproduced
  end

  def test_a_report_already_confirmed_is_left_alone
    session = fake_session([REPORTED.merge("status" => "resolved_verified")])
    stats = verifier_for(session).one_cycle

    assert_empty session.calls.select { |call| call[0] == :verify }
    assert_equal 0, stats.checked
  end

  def test_a_dissent_is_recorded_rather_than_a_confirmation
    # The valuable half: an execution that disagrees with the report must move the corpus no closer
    # to `resolved_verified`.
    session = fake_session([REPORTED])
    instance = verifier_for(session,
      verdicts: { "0.28.1" => verdict(AgentsMiner::Ledger::DISSENTED, "it resolved") })
    stats = instance.one_cycle

    assert_equal 1, stats.dissent
    assert_equal 0, stats.reproduced
    assert_equal AgentsMiner::Ledger::DISSENTED,
      session.calls.find { |call| call[0] == :verify }[2]["outcome"]
    assert_equal AgentsMiner::Ledger::DISSENTED,
      AgentsMiner::Ledger.load(instance.state).report(REPORTED["id"]).outcome
  end

  def test_a_partial_is_recorded_and_the_loop_keeps_going
    session = fake_session([REPORTED])
    instance = verifier_for(session,
      verdicts: { "0.28.1" => verdict(AgentsMiner::Ledger::PARTIAL, "the fix was refused") })
    stats = instance.one_cycle

    assert_equal 1, stats.partial
    assert_equal AgentsMiner::Ledger::PARTIAL,
      session.calls.find { |call| call[0] == :verify }[2]["outcome"]
  end

  def test_a_report_with_nothing_to_execute_casts_no_vote
    session = fake_session([REPORTED.merge("problem" => "it broke", "signatures" => [])])
    instance = verifier_for(session)
    stats = instance.one_cycle

    assert_equal 0, stats.no_claim # it never reaches the check
    assert_empty session.calls.select { |call| call[0] == :verify }
    assert_nil AgentsMiner::Ledger.load(instance.state).report(REPORTED["id"])
  end

  def test_a_report_with_nothing_executable_in_it_is_dropped
    # `NO_CLAIM` when it is about the report: there is nothing here to run, and a revision of it is
    # picked up when the feed announces one. No record is written, which is what makes dropping the
    # right answer rather than a loss.
    session = fake_session([REPORTED])
    instance = verifier_for(
      session,
      verdicts: { "0.28.1" => verdict(AgentsMiner::Verifying::NO_CLAIM, "",
        detail: "the report names no reference to run") }
    )
    stats = instance.one_cycle

    assert_equal 1, stats.no_claim
    assert_empty session.calls.select { |call| call[0] == :verify }
    assert_nil AgentsMiner::Ledger.load(instance.state).report(REPORTED["id"])
  end

  def test_a_release_that_could_not_be_asked_leaves_the_report_in_the_backlog
    # `NO_CLAIM` when it is about the machine, which is the half that must not be dropped. A killed
    # install or a timeout used to retire the report: nothing re-adds it to the backlog except a
    # change to the report itself, and no record was written, so the attempt bound could not bring
    # it back either — a true report lost to the machine's own bad luck, under a summary that
    # called it "nothing executable here".
    session = fake_session([REPORTED])
    instance = verifier_for(
      session,
      verdicts: { "0.28.1" => verdict(AgentsMiner::Verifying::NO_CLAIM, "",
        detail: "httpx 0.28.1 could not be asked about `AsyncClient(app=…)`",
        unreachable: true) }
    )
    stats = instance.one_cycle

    assert_equal 1, stats.skipped
    assert_equal 0, stats.no_claim
    assert_empty session.calls.select { |call| call[0] == :verify }
    record = AgentsMiner::Ledger.load(instance.state).report(REPORTED["id"])
    assert_equal AgentsMiner::Ledger::FAILED, record.outcome
    assert_operator record.next_at, :>, Time.now.to_f
  end

  def test_a_release_that_will_not_install_is_left_due_rather_than_settled
    # A wheel that cannot be installed is not evidence about somebody's report, and settling it on
    # an outage would lose the work permanently.
    session = fake_session([REPORTED])
    instance = verifier_for(session,
      verdicts: { "0.28.1" => AgentsMiner::Errors::MinerError.new("no wheel") })
    stats = instance.one_cycle

    assert_equal 1, stats.skipped
    assert_empty session.calls.select { |call| call[0] == :verify }
    record = AgentsMiner::Ledger.load(instance.state).report(REPORTED["id"])
    assert_equal AgentsMiner::Ledger::FAILED, record.outcome
    assert_operator record.next_at, :>, Time.now.to_f
  end

  def test_a_refused_vote_is_not_a_confirmation_and_is_retried
    session = fake_session([REPORTED],
      submit_error: AgentsMiner::Errors::CorpusError.new("refused", permanent: true))
    instance = verifier_for(session)
    stats = instance.one_cycle

    assert_equal 1, stats.skipped
    assert_equal AgentsMiner::Ledger::FAILED,
      AgentsMiner::Ledger.load(instance.state).report(REPORTED["id"]).outcome
  end

  def test_a_rate_limited_vote_leaves_the_report_due_and_the_loop_waits
    # A 429 is the service's protection, not this report's failure: marking it failed would retry
    # it in six hours and lose the wait the service asked for.
    session = fake_session([REPORTED],
      submit_error: AgentsMiner::Errors::RateLimited.new("429", retry_after: 30))
    instance = verifier_for(session)

    assert_raises(AgentsMiner::Errors::RateLimited) { instance.one_cycle }
    assert_nil AgentsMiner::Ledger.load(instance.state).report(REPORTED["id"])
  end

  def test_a_report_is_checked_once_and_not_every_cycle
    session = fake_session([REPORTED])
    instance = verifier_for(session)
    instance.one_cycle
    instance.one_cycle

    assert_equal 1, session.calls.count { |call| call[0] == :verify }
  end

  def test_the_feed_is_walked_from_the_cursor_the_ledger_remembers
    session = fake_session([REPORTED])
    instance = verifier_for(session)
    instance.one_cycle

    assert_equal REPORTED["updated_at"], AgentsMiner::Ledger.load(instance.state).cursor_since
    instance.one_cycle
    reads = session.calls.select { |call| call[0] == :changes }
    # The second cycle asks from the cursor rather than from the beginning.
    assert reads.any? { |call| call[1] == REPORTED["updated_at"] }
  end

  def test_a_bounded_run_stops_even_after_a_rate_limit
    # The bound is tested on every path. Once it was only tested after a successful cycle, and a
    # rate-limited bounded run never ended — a test that hangs is the expensive way to find that
    # out.
    session = fake_session([REPORTED],
      submit_error: AgentsMiner::Errors::RateLimited.new("429", retry_after: 1))
    instance = verifier_for(session)
    total = instance.run(cycles: 2, pace: false)

    assert_equal false, instance.stop
    assert(total.notes.any? { |note| note.include?("rate limited") })
  end

  def test_a_check_that_failed_is_not_retried_until_its_wait_is_over
    # The retry time a failed check writes is what keeps three attempts to ride out an outage
    # *spread out*. It was written and never read, so the three attempts happened in three
    # consecutive cycles — a release that was briefly unavailable settled the report as uncheckable
    # for good, in three minutes, and the corpus said so about a report that was true.
    session = fake_session([REPORTED])
    instance = verifier_for(session,
      verdicts: { "0.28.1" => AgentsMiner::Errors::MinerError.new("no wheel yet") })
    instance.one_cycle

    record = AgentsMiner::Ledger.load(instance.state).report(REPORTED["id"])
    assert_equal AgentsMiner::Ledger::FAILED, record.outcome
    assert_operator record.next_at, :>, Time.now.to_f

    # The next cycle, inside the wait: the report is not even read from the corpus.
    session.calls.clear
    attempted = @check_calls.length
    stats = instance.one_cycle
    assert_equal attempted, @check_calls.length
    refute session.calls.any? { |call| call[0] == :report }
    assert(stats.notes.any? { |note| note.include?("waiting out a failed attempt") })
  end

  def test_the_interval_between_cycles_is_the_verifiers_own
    # Ten minutes is how long the miner takes to notice a *release*, and a release is a rare event.
    # A report is not: the miner files dozens an hour, and every one of them sits unconfirmed until
    # this loop reads the feed again. Borrowing that constant left 24 true reports waiting while
    # nothing was wrong — the corpus's own promotion latency, set by a number chosen for a
    # different job. The two loops share `Service`'s vocabulary, so a test has to say the waiting
    # is not shared with it.
    assert_operator V::IDLE_SECONDS, :<, AgentsMiner::Service::IDLE_SECONDS

    # Two cycles, because the bound is tested before the wait: a one-cycle run stops without ever
    # reaching it.
    waits = []
    busy = verifier_for(fake_session([REPORTED]), state: @home + "busy.json")
    stub(busy, :wait, ->(seconds, pace:) { waits << seconds })
    busy.run(cycles: 2, pace: true)
    assert_equal [AgentsMiner::Service::CYCLE_SECONDS], waits

    idle_waits = []
    idle = verifier_for(fake_session([]), state: @home + "idle.json")
    stub(idle, :wait, ->(seconds, pace:) { idle_waits << seconds })
    idle.run(cycles: 2, pace: true)
    assert_equal [V::IDLE_SECONDS], idle_waits
  end

  def test_a_cycle_that_crashes_does_not_stop_the_service
    session = fake_session([REPORTED])
    instance = verifier_for(session)
    stub(instance, :refresh, ->(_stats) { raise "the corpus answered something else" })

    total = instance.run(cycles: 1, pace: false)

    assert_includes total.notes, "cycle failed; see the log"
  end

  def test_the_check_runs_beside_itself_and_the_ledger_from_one_thread
    # Examining is subprocess-bound and parallel; the ledger, the votes and the counters are one
    # operator's bookkeeping. "We happen not to have raced yet" is not the same property — and the
    # thread's own object_id is what is recorded, because an unnamed Ruby thread has no name to
    # compare.
    threads = {}
    rows = (1..4).map { |n| REPORTED.merge("id" => format("00000000-0000-0000-0000-00000000000%d", n)) }
    session = fake_session(rows)
    instance = verifier_for(session, workers: 4)

    original = AgentsMiner::Ledger.instance_method(:record_report)
    stub_method(AgentsMiner::Ledger, :record_report,
      ->(receiver, report_id, **kwargs) {
        threads[Thread.current.object_id] = true
        original.bind_call(receiver, report_id, **kwargs)
      })
    instance.one_cycle

    assert_equal 4, session.calls.count { |call| call[0] == :verify }
    assert_equal 1, threads.length, "the ledger was written from more than one thread"
  end

  def test_each_check_is_given_its_own_scratch_suffix
    # Two reports about one release are checked at the same moment and share an environment, so a
    # single scratch file would be overwritten between the write and the run — and the evidence
    # filed would be the other report's execution.
    rows = (1..3).map { |n| REPORTED.merge("id" => format("00000000-0000-0000-0000-00000000000%d", n)) }
    session = fake_session(rows)
    instance = verifier_for(session)
    instance.one_cycle

    suffixes = @check_calls.map { |_subject, _role, suffix| suffix }
    assert_equal 3, suffixes.length
    assert_equal 3, suffixes.uniq.length
  end

  def test_the_loop_reports_what_it_did
    session = fake_session([REPORTED])
    instance = verifier_for(session)
    stats = instance.one_cycle

    assert stats.summary.start_with?("1 report(s) checked: 1 reproduced")
  end

  def test_an_unknown_role_is_refused_at_construction
    assert_raises(ArgumentError) { verifier_for(fake_session([]), role: "vibes") }
  end

  # --- gems ----------------------------------------------------------------

  def test_a_gem_claim_is_checked_by_the_gem_installer
    # Which installer runs is the claim's answer, not this process's: asking pip for `colorize`
    # fails to find a package of that name, and a check that cannot build anything casts no vote on
    # a report that is true.
    #
    # `examine` is driven directly rather than through a cycle, because the scripted check in the
    # fixture is what a cycle replaces — and the thing under test is which `build` that check is
    # handed.
    built = []
    session = fake_session([GEM_REPORT])
    instance = verifier_for(session)
    claim = AgentsMiner::Verifying.claim_for(GEM_REPORT)
    stub(instance, :build_gem, lambda { |library, version|
      built << [library, version]
      AgentsMiner::RubyEnvs::Env.of(package: library, version: version, root: @home,
        require_path: library)
    })
    stub(AgentsMiner::Verifying, :check, lambda { |got, _role, build:, suffix: ""|
      build.call(got.library, got.version)
      build.call(got.library, got.from_version)
      verdict(AgentsMiner::Ledger::REPRODUCED, "ran the reference")
    })

    result, error = instance.send(:examine, claim, GEM_REPORT["id"])

    assert_nil error
    assert_equal AgentsMiner::Ledger::REPRODUCED, result.outcome
    assert claim.is_ruby?
    # Both releases of the gem, installed as gems — and nothing pip was asked for.
    assert_equal [%w[colorize 1.0.0], %w[colorize 0.8.1]], built
  end

  def test_a_platform_resolver_report_is_checked_without_a_release_environment
    # The resolver report is not a package claim, and the framework it names must not be treated as
    # a gem this machine has to install. The check is a `bundle lock` against two versions; a
    # release fact about Rails says nothing about whether the resolver can choose it.
    session = fake_session([RESOLVER_REPORT])
    instance = verifier_for(session)
    instance.ledger.record_release("rails 8.0.5.1", "no interpreter can build it",
      machine: instance.ledger.machine)

    stats = instance.one_cycle

    assert_equal 1, stats.reproduced
    assert_equal 1, session.calls.count { |call| call[0] == :verify }
    assert_includes @check_calls.map(&:first), "js_image_paths 0.2.0"
  end

  def test_a_gem_claim_is_offered_to_the_checker_at_all
    # A gem report has an executable subject, so the verifier must not drop it as unanswerable —
    # which is what every Ruby report was before this round.
    claim = AgentsMiner::Verifying.claim_for(GEM_REPORT)

    refute_nil claim
    assert claim.is_ruby?
    assert_equal "String.allocate.magenta", claim.reference
    assert_equal true, AgentsMiner::Verifying.needs_confirmation?(GEM_REPORT, "another-operator")
  end

  def test_a_release_this_machine_cannot_build_is_charged_once
    # Measured on this deployment: `kornia 0.5.11` timed out for one report after another, each
    # paying the install in full — twenty-four reports sharing one unbuildable release, which is a
    # cycle's whole budget spent asking the same question twenty-four times. The fact belongs to
    # the release, so it is recorded once and the rest of the reports about it are settled without
    # an attempt.
    #
    # The real check runs here, not the fixture's scripted one: the failure has to reach `record`
    # as an *exception* carrying its release, and a string would lose both that and whether asking
    # again could change the answer.
    rows = (1..3).map { |n| REPORTED.merge("id" => format("00000000-0000-0000-0000-0000000000b%d", n), "library" => "kornia") }
    session = fake_session(rows)
    attempts = []
    stub(AgentsMiner::Envs, :prune, ->(_home, budget: nil, quiet: nil) { [0, 0] })
    store = @home + "ledger.json"
    instance = V.new(session: session, home: @home, state: store,
      role: AgentsMiner::Verifying::AS_REPORTED,
      ledger: AgentsMiner::Ledger.load(store),
      # One worker, so the rule is deterministic: the first report to fail writes
      # the record and the others read it. With several, the ones already in flight
      # pay too — which is the bound, and it is the worker count rather than the
      # number of reports, which is what the twenty-four-install cycle was not.
      workers: 1)
    stub(instance, :build, lambda { |library, version|
      attempts << [library, version]
      raise AgentsMiner::Errors::MinerError.new(
        "installing #{library} #{version} failed:\nFailed building wheel",
        permanent: true, release: "#{library} #{version}"
      )
    })

    first = instance.one_cycle
    second = instance.one_cycle

    # One install attempt for the release, whatever the number of reports about it.
    assert_equal [%w[kornia 0.28.1]], attempts
    assert_equal 3, first.skipped
    assert instance.ledger.cannot_build("kornia 0.28.1")
    # And the next cycle does not try again: the other two are settled from the record, without an
    # install.
    assert_equal 0, second.skipped
    assert_equal [%w[kornia 0.28.1]], attempts
  end

  def test_a_release_fact_from_another_interpreter_does_not_skip_the_report
    # The pair rule, applied to the verifier's own record. A release refused because there was no
    # wheel for the old Python is a question the newer image has gone back to asking; skipping on
    # the stale stamp means a release this machine *can* build is never built, once per report that
    # names it, for ever. The install must be attempted.
    stub(AgentsMiner::Envs, :prune, ->(_home, budget: nil, quiet: nil) { [0, 0] })
    store = @home + "ledger.json"
    session = fake_session([REPORTED.merge("id" => "00000000-0000-0000-0000-0000000000c1",
      "library" => "kornia")])
    instance = V.new(session: session, home: @home, state: store,
      role: AgentsMiner::Verifying::AS_REPORTED,
      ledger: AgentsMiner::Ledger.load(store), workers: 1)
    instance.ledger.record_release("kornia 0.28.1", "no wheel for the old interpreter")
    instance.ledger.release_interpreters["kornia 0.28.1"] = "cpython 1.0"

    attempts = []
    stub(instance, :build, lambda { |library, version|
      attempts << [library, version]
      # Transient, so this attempt does not re-establish a permanent fact.
      raise AgentsMiner::Errors::MinerError.new("a bad minute building #{library} #{version}",
        release: "")
    })

    instance.one_cycle

    assert_equal [%w[kornia 0.28.1]], attempts
  end

  # --- the walk ------------------------------------------------------------

  def test_a_report_the_feed_says_is_settled_costs_no_request
    # The feed carries every report's status, and the reader was fetching the body to learn what
    # the row already said — 96 requests a cycle, spent on the *look* budget that decides how far
    # down the backlog the walk reaches. Measured here: 2,933 backlog entries, nearly all already
    # confirmed, and a report filed an hour ago behind every one of them.
    settled = (1..5).map do |n|
      REPORTED.merge("id" => format("00000000-0000-0000-0000-0000000000c%d", n),
        "status" => "resolved_verified")
    end
    fresh = REPORTED.merge("id" => "00000000-0000-0000-0000-0000000000c9",
      "status" => "resolved_unverified")
    session = fake_session(settled + [fresh])
    instance = verifier_for(session)

    stats = instance.one_cycle

    fetched = session.calls.select { |call| call[0] == :report }.map { |call| call[1] }
    assert_equal [fresh["id"]], fetched, "only the report that could still be confirmed"
    assert(stats.notes.any? { |note| note.include?("already settled") })
    refute instance.ledger.seen?(settled[0]["id"]), "and not carried for ever"
  end

  def test_a_report_the_feed_has_not_described_is_read_rather_than_assumed
    # An empty status is not "settled": a report nothing is known about is exactly the one worth
    # reading. What the *body* then says decides the vote, and this fake body carries no status —
    # so it is fetched and then dropped by `needs_confirmation?`, which is the correct reading of a
    # report with no status at all. The assertion is the fetch.
    row = REPORTED.merge("id" => "00000000-0000-0000-0000-0000000000d1")
    row.delete("status")
    session = fake_session([row])
    instance = verifier_for(session)

    stats = instance.one_cycle

    assert(session.calls.any? { |call| call[0] == :report })
    refute(stats.notes.any? { |note| note.include?("already settled") })
  end

  def test_the_walk_takes_from_both_ends_of_the_backlog
    # Oldest-first is right and, on its own, starves: the corpus holds a deep pool of old
    # unconfirmed reports, each costing minutes, so a gem filed an hour ago sat behind all of them.
    # The order alternates, and the report filed last is reached in the same cycle rather than
    # after two hundred older ones.
    old = (1..5).map do |n|
      REPORTED.merge("id" => format("00000000-0000-0000-0000-0000000000e%d", n),
        "library" => "ancient",
        "updated_at" => "2026-01-0#{n}T00:00:00Z",
        "status" => "resolved_unverified")
    end
    newest = REPORTED.merge("id" => "00000000-0000-0000-0000-0000000000f9",
      "library" => "colorize",
      "updated_at" => "2026-09-29T00:00:00Z",
      "status" => "resolved_unverified")
    session = fake_session(old + [newest])
    instance = verifier_for(session, role: AgentsMiner::Verifying::SEARCHED)

    instance.one_cycle

    # The order is the assertion, and it is read from what the cycle *asked for* rather than from
    # what the workers reported. Bodies are fetched one at a time in the walk; the checks run on
    # however many workers the deployment asked for, so the order the executions happen to be
    # appended in is a schedule rather than a decision.
    order = session.calls.select { |call| call[0] == :report }.map { |call| call[1][-2..] }
    assert_equal %w[e1 f9 e2 e5 e3 e4], order
    # And every one of them was reached in the one cycle: the newest report is checked in the same
    # pass rather than after the older five.
    # Sorted on *both* sides: the execution order is a schedule, so what this asks is only whether
    # each of the six was reached in the one pass. Comparing a sorted list against the interleaved
    # one is a test that can never pass, which is how this read for two runs.
    checked = @check_calls.map { |_subject, _role, suffix| suffix.split("-")[-1][-2..] }
    assert_equal %w[e1 f9 e2 e5 e3 e4].sort, checked.sort
  end
end
