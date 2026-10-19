# frozen_string_literal: true

require_relative "test_helper"

# The request a finding becomes, and what it says about where it came from.
#
# The tests that read as prose assertions are the ones that would otherwise be silent failures: the
# service stores `attempted` as the evidence, so a sentence describing a call a symbol finding never
# made is a report whose evidence contradicts its own trace.
class ReportingTest < MinerTest
  MECHANISM = AgentsFyiMiner::Mechanism
  REPORTING = AgentsFyiMiner::Reporting

  def a_finding(**overrides)
    fields = {
      symbol: "Client",
      parameter: "proxies",
      exception: "TypeError: Client.__init__() got an unexpected keyword argument 'proxies'",
      accepted_before: true,
      accepted_after: false,
      repair: "proxy",
      traceback: "Traceback (most recent call last):\nTypeError: nope"
    }.merge(overrides)
    summarise("httpx", "0.28.1", "0.27.2", [AgentsFyiMiner::Observation.new(**fields)])
  end

  def payload_for(finding, from_version) = REPORTING.payload_for(finding, from_version: from_version)

  def test_the_version_filed_is_the_release_that_refuses_the_call
    # A caller searches for what they have installed, and what they have is the release they are
    # being broken by.
    payload = payload_for(a_finding, "0.27.2")

    assert_equal "0.28.1", payload["version"]
  end

  def test_the_report_says_it_was_reproduced_rather_than_merely_observed
    # A mined finding is not an agent's field report, so its provenance travels in `environment`.
    payload = payload_for(a_finding, "0.27.2")

    assert_includes payload["environment"],
      "reproduced by executing the same call against both releases"
  end

  def test_the_release_that_accepted_the_call_is_recorded
    # Without the other half of the evidence a reader cannot tell a break from a typo, and that
    # distinction is the entire claim.
    payload = payload_for(a_finding, "0.27.2")

    assert_includes payload["attempted"], "0.27.2"
    assert_includes payload["attempted"], "accepted"
  end

  def test_the_kind_is_a_package_because_that_is_what_was_executed
    assert_equal "package", payload_for(a_finding, "0.27.2")["subject_kind"]
  end

  def test_the_library_and_the_trace_reach_the_corpus
    payload = payload_for(a_finding, "0.27.2")

    assert_equal "httpx", payload["library"]
    assert payload["trace"].start_with?("Traceback")
  end

  def test_the_precheck_draft_is_the_submit_body_less_the_fields_it_refuses
    # `POST /reports/precheck` takes a narrower model than `POST /reports` and is strict about it:
    # sending the whole body is a 422 that reads like the finding being unacceptable rather than the
    # request being too complete.
    draft = REPORTING.precheck_payload_for(payload_for(a_finding, "0.27.2"))

    assert_empty draft.keys - REPORTING::PRECHECK_FIELDS
    refute_includes draft.keys, "environment"
    refute_includes draft.keys, "attempted"
  end

  def test_the_precheck_draft_keeps_everything_the_comparison_reads
    # Dropping a compared field would make the precheck answer a question about a different draft
    # than the one that would be submitted.
    payload = payload_for(a_finding, "0.27.2")
    draft = REPORTING.precheck_payload_for(payload)

    %w[title library version subject_kind problem resolution trace].each do |field|
      assert_equal payload[field], draft[field], field
    end
  end

  def test_an_absent_optional_field_is_sent_empty_rather_than_as_null
    # The service's strict models reject a null where a string is expected, and its blank-to-none
    # validator drops an empty string — so an empty field and an absent one mean the same thing
    # there, and only one of them is accepted on the way in. A report with no trace is the case that
    # found this: it was filed as a 422 the miner reported as "nothing to file".
    finding = a_finding
    finding.resolution = nil
    finding.trace = ""
    payload = payload_for(finding, "0.27.2")

    assert_equal "", payload["resolution"]
    assert_equal "", payload["trace"]
    draft = REPORTING.precheck_payload_for(payload)
    assert_equal "", draft["resolution"]
    assert_equal "", draft["trace"]
  end

  def test_the_attempt_is_described_as_the_thing_that_was_run
    # A symbol finding's evidence is that a reference resolved and then raised. A body saying it
    # "accepted the argument" describes a call this finding never made, and the service stores that
    # field as the attempt.
    called = a_finding
    assert_includes payload_for(called, "0.27.2")["attempted"], "accepted the argument"

    released = a_finding(symbol: "Markup", parameter: "", repair: nil, kind: "symbol")
    released.library = "jinja2"
    released.version = "3.1.6"
    body = payload_for(released, "3.0.3")["attempted"]

    assert_includes body, "resolved it"
    refute_includes body, "accepted the argument"
    assert_includes body, "jinja2.Markup"
  end

  def test_the_attempt_names_both_the_break_and_where_the_name_went
    # A move has two executions behind it and the attempt has to carry both: the reference that
    # raised where the caller wrote it and the one that resolved where the release keeps it. Only
    # the first is a removal, and the fix is the second.
    moved = a_finding(symbol: "Event", parameter: "", repair: nil, kind: "symbol",
      moved: "wsproto.events.Event")
    moved.library = "wsproto"
    moved.version = "1.3.2"
    body = payload_for(moved, "1.2.0")["attempted"]

    assert_includes body, "wsproto.Event"
    assert_includes body, "Reading `wsproto.events.Event`"
    assert_includes body, "still exported"
  end

  # `filable` is on `Errors` now — the corpus client's vocabulary, where `Corpus` reads it.

  def test_a_finding_the_corpus_would_refuse_is_not_filed
    # `duplicate` is what submit refuses, so filing it asks a question the miner already has the
    # answer to.
    refute AgentsFyiMiner::Errors.filable?("duplicate")
  end

  def test_a_finding_with_every_identifying_symptom_already_present_is_not_filed
    # `likely_duplicate` means a candidate carries every symptom in the draft including one that
    # identifies it. That is the same failure, and the honest answer is to verify the report rather
    # than file a second one — which the miner cannot do, because it has not run anybody's fix.
    refute AgentsFyiMiner::Errors.filable?("likely_duplicate")
  end

  def test_a_finding_the_corpus_merely_finds_close_is_filed
    # The case this rule exists for. `similar` covers a draft close to something recorded without
    # being close enough to refuse, and the advice for the variant where the titles read alike but
    # the symptoms disagree is that submitting would not be refused — so stopping at `new` would
    # decline exactly the findings the duplicate rule has just said are distinct.
    assert AgentsFyiMiner::Errors.filable?("similar")
  end

  def test_a_finding_the_corpus_has_never_seen_is_filed
    assert AgentsFyiMiner::Errors.filable?("new")
  end

  def test_an_unrecognised_verdict_is_not_taken_as_permission_to_write
    # A verdict the miner does not know is not a yes. Filing is a write to a shared corpus, so the
    # unknown case has to fail towards silence.
    refute AgentsFyiMiner::Errors.filable?("unknown")
    refute AgentsFyiMiner::Errors.filable?("")
  end

  private

  def summarise(library, version, from_version, group)
    AgentsFyiMiner.summarise(library, version, from_version, group)
  end
end
