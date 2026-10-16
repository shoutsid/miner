# frozen_string_literal: true

require "json"

require_relative "test_helper"

# The one-off `solve`: which reports it will work on, and which it leaves alone.
#
# Two subjects in one file, which is deliberate: both are about the *contract with the service*
# rather than about arithmetic of the miner's own. The first half is the walk that decides which
# reports are this miner's to answer — and the omission it records was a real one, where the command
# selected sixteen of its own reports and set about running a full differential against each, minutes
# apiece, to reach a conclusion the corpus already held. The second half reads the service's own
# `change_kind` enum out of its schema and checks that every mechanism this client can establish is a
# value the service accepts, because a kind the service refuses is a report that cannot be filed at
# all and the failure appears as a 422 in a container nobody is reading.
#
# What *is* testable about them without installing anything is the walk, and that is what
# these tests cover.
class CliReportsTest < MinerTest
  R = AgentsFyiMiner::CliReports

  REPORT = {
    "id" => "00000000-0000-0000-0000-000000000001",
    "library" => "sqlalchemy",
    "version" => "2.0.5",
    "subject_kind" => "package",
    "status" => "open",
    "resolution" => nil,
    "submitted_by" => "someone-else",
    "hidden" => false,
    "signatures" => ["unexpected keyword argument 'convert_unicode'"],
    "updated_at" => "2026-01-01T00:00:00Z"
  }.freeze

  # A corpus that answers the two reads this walk makes and counts them. `me` is the identity the
  # walk compares a report's author against, which is the whole subject of the first test.
  class FakeCorpus
    attr_reader :changes_calls

    def initialize(rows, operator_id: "operator-1")
      @rows = rows
      @operator_id = operator_id
      @changes_calls = 0
    end

    def me = { "id" => @operator_id }

    def changes(since: nil, since_id: nil, limit: 100)
      @changes_calls += 1
      page = since.nil? ? @rows : []
      { "items" => page, "has_more" => false, "next_since" => since, "next_since_id" => since_id }
    end
  end

  # The service counts a confirmation only from an operator other than a report's author, so working
  # on our own is a row no number reads — and the command was written without the check at all, so it
  # set about running a full differential against sixteen of its own reports, minutes each, to reach
  # a conclusion the corpus already held.
  def test_a_report_this_account_filed_is_not_a_question_for_it
    session = FakeCorpus.new([REPORT.merge("submitted_by" => "operator-1")])

    assert_empty R.open_questions(session)
  end

  def test_another_operators_open_report_is_selected
    session = FakeCorpus.new([REPORT])

    assert_equal [REPORT["id"]], R.open_questions(session).map { |report| report["id"] }
  end

  def test_a_report_with_no_argument_to_link_on_is_left_alone
    session = FakeCorpus.new([REPORT.merge("signatures" => ["timeout"])])

    assert_empty R.open_questions(session)
  end

  def test_a_hidden_report_is_never_worked_on
    session = FakeCorpus.new([REPORT.merge("hidden" => true)])

    assert_empty R.open_questions(session)
  end

  def test_the_limit_bounds_how_many_reports_one_run_takes_on
    rows = (0...10).map { |index| REPORT.merge("id" => "id-#{index}") }

    assert_equal 3, R.open_questions(FakeCorpus.new(rows), limit: 3).length
  end

  def test_an_unreadable_corpus_is_not_treated_as_a_report_to_solve
    # An outage must be an outage: read as an empty page it would report "nothing open that this
    # miner could answer", which is the one answer that stops anybody looking.
    down = Class.new(FakeCorpus) do
      def me = raise(AgentsFyiMiner::Errors::CorpusError, "could not be reached")
    end.new([])

    assert_raises(AgentsFyiMiner::Errors::CorpusError) { R.open_questions(down) }
  end

  # --- the vocabulary, against the service's own schema --------------------------------

  # Read from the *schema* rather than from the service's source, because the client does not depend
  # on the service in either direction: `db/structure.sql` is the deployed database's own
  # `CREATE TYPE public.change_kind AS ENUM (...)`, which is data and outlives the code that wrote it.
  SCHEMA_CANDIDATES = [
    Pathname.new(__dir__) + "../../../db/structure.sql",
    Pathname.new(ENV.fetch("MINER_REPO", "/repo")) + "db/structure.sql"
  ].freeze

  CHANGE_KIND_TYPE = /CREATE TYPE public\.change_kind AS ENUM \(((?:\s+'[a-z_]+',?)+\s*)\)/

  def service_kinds
    schema = SCHEMA_CANDIDATES.find(&:file?)
    skip "no repository copy of db/structure.sql to check against" if schema.nil?

    body = CHANGE_KIND_TYPE.match(schema.read(encoding: "utf-8"))
    assert body, "change_kind's declaration could not be found in the schema"
    body[1].scan(/'([a-z_]+)'/).flatten
  end

  def test_the_service_accepts_every_mechanism_the_miner_can_establish
    assert_equal AgentsFyiMiner::Mechanism::ALL.sort, service_kinds.sort
  end

  def test_the_reader_actually_finds_the_services_declaration
    # A guard on the guard: the comparison above is a set equality and would pass vacuously against a
    # pattern that matched nothing.
    assert_equal 5, service_kinds.length
  end

  # --- what a filed finding carries ----------------------------------------------------

  def observation(**overrides)
    AgentsFyiMiner::Observation.new(
      symbol: "Client", parameter: "proxies",
      exception: "TypeError: unexpected keyword argument 'proxies'",
      accepted_before: true, accepted_after: false,
      traceback: "Traceback (most recent call last):\nTypeError: nope", **overrides
    )
  end

  def payload_for(library, version, from_version, observations)
    finding = AgentsFyiMiner.summarise(library, version, from_version, Array(observations))
    AgentsFyiMiner::Reporting.payload_for(finding, from_version: from_version)
  end

  def test_a_finding_carries_all_three_boundary_fields_on_the_wire
    # The columns exist to be filled. A payload that dropped one would leave the corpus unable to
    # place the change in somebody else's upgrade, which is the whole reason the fields were added.
    payload = payload_for("httpx", "0.28.1", "0.27.2",
      [observation(repair: "proxy")])

    assert_equal "0.27.2", payload["from_version"]
    assert_equal "proxies", payload["subject"]
    assert_equal "parameter_renamed", payload["change_kind"]
    assert_includes service_kinds, payload["change_kind"]
  end

  def test_the_subject_sent_is_the_bare_name_the_service_stores
    # The library is a field beside it, so a subject that repeated the library would never match a
    # caller asking about their own imports.
    payload = payload_for("httpx", "0.28.1", "0.27.2", [observation])

    assert_equal "proxies", payload["subject"]
    refute_includes payload["subject"], "."
  end

  def test_a_rename_sends_the_name_the_caller_has_to_change_to
    # The destination is the edit. A payload that dropped it would leave the fix in prose, which is
    # the thing the structured fields were added to avoid.
    payload = payload_for("httpx", "0.28.1", "0.27.2", [
                            observation(symbol: "Client", parameter: "",
                              exception: "AttributeError: module 'httpx' has no attribute 'Client'",
                              repair: "AsyncClient", kind: "symbol")
                          ])

    assert_equal "Client", payload["subject"]
    assert_equal "AsyncClient", payload["replacement"]
    assert_equal "symbol_renamed", payload["change_kind"]
  end

  def test_a_move_sends_the_path_rather_than_nothing
    # A move keeps its destination in `moved` rather than `replacement`, and the payload has one
    # field for it: which of the miner's two fields held it is the miner's business, not the
    # corpus's.
    payload = payload_for("wsproto", "1.3.2", "1.2.0", [
                            observation(symbol: "Event", parameter: "",
                              exception: "AttributeError: module 'wsproto' has no attribute 'Event'",
                              moved: "wsproto.events.Event", kind: "symbol")
                          ])

    assert_equal "symbol_moved", payload["change_kind"]
    assert_equal "wsproto.events.Event", payload["replacement"]
  end

  def test_a_removal_sends_no_destination
    # Nothing replaced it, and the service stores null for exactly that.
    payload = payload_for("httpx", "0.28.1", "0.27.2", [
                            observation(symbol: "Client", parameter: "",
                              exception: "AttributeError: module 'httpx' has no attribute 'Client'",
                              kind: "symbol")
                          ])

    assert_equal "symbol_removed", payload["change_kind"]
    assert_nil payload["replacement"]
  end
end
