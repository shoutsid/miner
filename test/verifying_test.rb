# frozen_string_literal: true

require_relative "stub_helper"
require_relative "test_helper"

# What a report's own words can be turned into, and what a check then proves.
#
# Nothing here installs anything: `build` is a fake that returns an environment whose probes are the
# interpreter's output written down — the four probe functions are stubbed, and the answers are
# keyed by release so a differential can be expressed at all. That is the point: every judgement
# this module makes is about *output*, and a test that needed a wheel would be a test that fails on
# a plane. What it must never do is confirm a report the execution contradicts, so the fakes are the
# two shapes a real run has: a refusal and a resolution.
#
class VerifyingTest < MinerTest
  include StubHelper

  V = AgentsFyiMiner::Verifying

  def refusal(name, parameter)
    "Traceback (most recent call last):\n  " \
      "File \"call_site.py\", line 3, in <module>\n    " \
      "#{name}(#{parameter}='_marker')\n" \
      "TypeError: #{name}.__init__() got an unexpected keyword argument '#{parameter}'"
  end

  def attribute_refusal(module_name, symbol)
    "Traceback (most recent call last):\n  " \
      "File \"call_site.py\", line 3, in <module>\n    " \
      "#{module_name}.#{symbol}\n" \
      "AttributeError: module '#{module_name}' has no attribute '#{symbol}'"
  end

  ARGUMENT_REPORT = {
    "id" => "00000000-0000-0000-0000-000000000001",
    "library" => "httpx",
    "version" => "0.28.1",
    "subject_kind" => "package",
    "status" => "resolved_unverified",
    "resolution" => "Rename the argument: `app=` is `transport=` in httpx 0.28.1. The new " \
                    "signature refuses `app=` and accepts `transport=`.",
    "problem" => "Upgrading httpx from 0.27.2 to 0.28.1 breaks calls that pass `app=`. Found by " \
                 "executing the same call against both releases: 2 call sites accepted it on " \
                 "0.27.2 and were refused on 0.28.1 (AsyncClient(app=…), Client(app=…)).\n\n" \
                 "TypeError: AsyncClient.__init__() got an unexpected keyword argument 'app'",
    "signatures" => ["typeerror", "unexpected keyword argument 'app'"],
    "submitted_by" => "the-miner",
    "hidden" => false
  }.freeze

  SYMBOL_REPORT = {
    "id" => "00000000-0000-0000-0000-000000000002",
    "library" => "sqlalchemy",
    "version" => "1.4.54",
    "subject_kind" => "package",
    "status" => "resolved_unverified",
    "resolution" => "Import it from where it lives now: `IdentityOptions` is " \
                    "`sqlalchemy.sql.schema.IdentityOptions` in sqlalchemy 1.4.54.",
    "problem" => "Upgrading sqlalchemy from 1.3.24 to 1.4.54 breaks code that names " \
                 "`sqlalchemy.IdentityOptions`. Found by executing the same reference against " \
                 "both releases: it resolved on 1.3.24 and raised on 1.4.54.\n\n" \
                 "AttributeError: module 'sqlalchemy' has no attribute 'IdentityOptions'",
    "signatures" => ["attributeerror", "object has no attribute"],
    "submitted_by" => "the-miner",
    "hidden" => false
  }.freeze

  # A release whose answers are written down, per the key above, and the builder `build:` takes.
  #
  # The four probe functions are replaced together, because they are only meaningful together: a
  # differential stubbed in one direction and not the other answers from two different releases.
  def scripted(answers)
    @answers = answers
    probes = {
      probe: ->(env, _module_name, symbol, parameter, suffix: "") do
        @answers[[env.version, "call", symbol, parameter]] || ""
      end,
      probe_symbol: ->(env, _module_name, symbol, suffix: "") do
        @answers[[env.version, "symbol", symbol]] || ""
      end,
      probe_dotted: ->(env, dotted, suffix: "") do
        @answers[[env.version, "dotted", dotted]] || ""
      end,
      inventory: ->(env, suffix: "") do
        AgentsFyiMiner::Envs::Inventory.new(
          module: @answers["module"] || "pkg",
          entries: @answers[[env.version, "inventory"]] || []
        )
      end
    }
    builder = lambda do |library, version|
      AgentsFyiMiner::Envs::Env.new(package: library, version: version, root: @home)
    end
    with_stubs(AgentsFyiMiner::Envs, probes) { yield builder }
  end

  # --- reading a report ---------------------------------------------------------------------

  def test_a_report_yields_the_argument_its_own_symptoms_name
    claim = V.claim_for(ARGUMENT_REPORT)

    refute_nil claim
    assert_equal "app", claim.parameter
    assert_equal "argument", claim.kind
    assert_equal "httpx", claim.library
    assert_equal "0.28.1", claim.version
  end

  def test_the_call_sites_come_from_the_report_rather_than_from_the_release
    # A check that picked its own call site would be verifying a claim nobody made, and the report's
    # list is exactly the evidence it is offering.
    assert_equal %w[AsyncClient Client], V.claim_for(ARGUMENT_REPORT).sites
  end

  def test_the_release_the_report_came_from_is_read_from_its_own_sentence
    # It cannot be derived without the index, and a guess about which line below this one is the
    # upgrade somebody made is a guess the report does not ask for.
    assert_equal "0.27.2", V.claim_for(ARGUMENT_REPORT).from_version
  end

  def test_the_release_a_report_declares_beats_a_sentence_about_it
    # `from_version` is a field since `0018`, filed from the same template the prose came from — and
    # reading only the prose refused a report that had stated exactly what the check needed, then
    # retired it as uncheckable.
    report = ARGUMENT_REPORT.merge("from_version" => "0.27.2",
      "problem" => "httpx 0.28.1 broke calls that pass `app=`.")

    assert_equal "0.27.2", V.claim_for(report).from_version
  end

  def test_a_comma_after_the_release_is_not_part_of_the_release
    # `from 0.27.0, to 0.28.0` used to read as the release `0.27.0,` — a string handed to the
    # installer as something to fetch, so the check failed for a reason that had nothing to do with
    # the report.
    report = ARGUMENT_REPORT.merge(
      "problem" => "Upgrading httpx from 0.27.0, to 0.28.1 broke calls that pass `app=`."
    )

    assert_equal "0.27.0", V.claim_for(report).from_version
  end

  def test_the_replacement_comes_from_the_fix_and_only_when_it_names_one
    assert_equal "transport", V.claim_for(ARGUMENT_REPORT).replacement

    without = ARGUMENT_REPORT.merge("resolution" => "`app=` is gone in httpx 0.28.1. Pin below.")

    assert_equal "", V.claim_for(without).replacement
  end

  def test_a_report_naming_two_refused_arguments_is_not_checkable
    # Which one it is about is stated nowhere that can be read, and a confirmation of the wrong one
    # is a true sentence about a different question.
    two = ARGUMENT_REPORT.merge("signatures" => ["typeerror",
                                                "unexpected keyword argument 'app'",
                                                "unexpected keyword argument 'cert'"])

    assert_nil V.claim_for(two)
  end

  def test_a_report_with_no_version_to_position_is_not_checkable
    assert_nil V.claim_for(ARGUMENT_REPORT.merge("version" => "unknown"))
  end

  def test_a_symbol_report_yields_the_reference_its_own_quoted_line_names
    claim = V.claim_for(SYMBOL_REPORT)

    refute_nil claim
    assert_equal "symbol", claim.kind
    assert_equal "sqlalchemy.IdentityOptions", claim.dotted
    assert_equal "sqlalchemy.sql.schema.IdentityOptions", claim.moved
  end

  def test_a_report_whose_symptoms_say_nothing_specific_is_not_checkable
    assert_nil V.claim_for(SYMBOL_REPORT.merge("problem" => "it broke", "signatures" => []))
  end

  def test_a_stored_lowercase_token_is_read_back_as_the_reports_spelling
    # Symptom tokens are lowercased before they are stored, so `documentAST` reaches this module as
    # `documentast` — and a call site searched for in the stored spelling is not the one the report
    # names, so the check abstained on a report that was true.
    report = {
      "library" => "astropy", "version" => "6.0.0", "subject_kind" => "package",
      "status" => "resolved_unverified", "submitted_by" => "somebody",
      "resolution" => "Rename the argument: `documentAST=` is `align_to_data=`.",
      "problem" => "Upgrading astropy from 5.0 to 6.0 breaks calls that pass `documentAST=`. " \
                   "Found by executing the same call against both releases: 1 call site " \
                   "accepted it on 5.0 and was refused on 6.0 (align_to_data(documentAST=…)).\n\n" \
                   "TypeError: got an unexpected keyword argument 'documentast'",
      "signatures" => ["unexpected keyword argument 'documentast'"]
    }

    claim = V.claim_for(report)

    assert_equal "documentAST", claim.parameter
    assert_equal ["align_to_data"], claim.sites
  end

  def test_the_author_is_never_asked_to_confirm_its_own_report
    # The service counts a confirmation only from another operator, so this would write a row no
    # number reads while looking like independent reproduction.
    refute V.needs_confirmation?(ARGUMENT_REPORT, "the-miner")
    assert V.needs_confirmation?(ARGUMENT_REPORT, "somebody-else")
  end

  def test_an_open_report_is_not_confirmed_and_a_verified_one_is_left_alone
    refute V.needs_confirmation?(ARGUMENT_REPORT.merge("status" => "open"), "x")
    refute V.needs_confirmation?(ARGUMENT_REPORT.merge("status" => "resolved_verified"), "x")
  end

  def test_a_hidden_report_is_not_confirmed
    refute V.needs_confirmation?(ARGUMENT_REPORT.merge("hidden" => true), "x")
  end

  # --- checking an argument ------------------------------------------------------------------

  def test_the_fix_running_against_the_release_it_is_for_is_a_confirmation
    answers = {
      "module" => "httpx",
      ["0.28.1", "call", "AsyncClient", "app"] => refusal("AsyncClient", "app"),
      ["0.28.1", "call", "Client", "app"] => refusal("Client", "app"),
      ["0.28.1", "call", "AsyncClient", "transport"] => ""
    }
    verdict = scripted(answers) { |build| V.as_reported(V.claim_for(ARGUMENT_REPORT), build: build) }

    assert_equal AgentsFyiMiner::Ledger::REPRODUCED, verdict.outcome
    assert_includes verdict.executed, "transport"
  end

  def test_a_fix_the_release_refuses_as_well_is_not_a_confirmation
    # The problem is real and the advice does not run. That is a `partial`, which the corpus does not
    # count, and it is the answer a reader most needs to see.
    answers = {
      "module" => "httpx",
      ["0.28.1", "call", "AsyncClient", "app"] => refusal("AsyncClient", "app"),
      ["0.28.1", "call", "AsyncClient", "transport"] => refusal("AsyncClient", "transport")
    }
    verdict = scripted(answers) { |build| V.as_reported(V.claim_for(ARGUMENT_REPORT), build: build) }

    assert_equal AgentsFyiMiner::Ledger::PARTIAL, verdict.outcome
    assert_includes verdict.executed, "not accepted there either"
  end

  def test_a_call_site_that_never_refused_the_argument_is_a_dissent
    answers = { "module" => "httpx",
                ["0.28.1", "call", "AsyncClient", "app"] => "ran fine" }
    verdict = scripted(answers) { |build| V.as_reported(V.claim_for(ARGUMENT_REPORT), build: build) }

    assert_equal AgentsFyiMiner::Ledger::DISSENTED, verdict.outcome
  end

  def test_a_removal_is_confirmed_by_the_older_release_accepting_the_argument
    # Without that half the check would confirm every argument in existence: no release accepts a
    # keyword it never had.
    report = ARGUMENT_REPORT.merge("resolution" => "`app=` is gone in httpx 0.28.1. Pin below.")
    answers = {
      "module" => "httpx",
      ["0.28.1", "call", "AsyncClient", "app"] => refusal("AsyncClient", "app"),
      ["0.28.1", "call", "Client", "app"] => refusal("Client", "app"),
      ["0.27.2", "call", "AsyncClient", "app"] => ""
    }
    verdict = scripted(answers) { |build| V.as_reported(V.claim_for(report), build: build) }

    assert_equal AgentsFyiMiner::Ledger::REPRODUCED, verdict.outcome
    assert_includes verdict.executed, "accepted the argument"
  end

  def test_an_argument_the_older_release_refused_too_is_a_dissent
    report = ARGUMENT_REPORT.merge("resolution" => "`app=` is gone in httpx 0.28.1. Pin below.")
    answers = {
      "module" => "httpx",
      ["0.28.1", "call", "AsyncClient", "app"] => refusal("AsyncClient", "app"),
      ["0.27.2", "call", "AsyncClient", "app"] => refusal("AsyncClient", "app")
    }
    verdict = scripted(answers) { |build| V.as_reported(V.claim_for(report), build: build) }

    assert_equal AgentsFyiMiner::Ledger::DISSENTED, verdict.outcome
    assert_includes verdict.executed, "nothing was taken away"
  end

  def test_a_probe_that_never_ran_is_not_a_contradiction
    # The third answer: a release that could not be asked has said nothing about the report, so the
    # verdict is no vote marked `unreachable` — which is what makes the loop come back to it instead
    # of retiring a report no release was ever asked about.
    answers = {
      "module" => "httpx",
      ["0.28.1", "call", "AsyncClient", "app"] => "TIMEOUT",
      ["0.28.1", "call", "Client", "app"] => "TIMEOUT"
    }
    verdict = scripted(answers) { |build| V.as_reported(V.claim_for(ARGUMENT_REPORT), build: build) }

    assert_equal AgentsFyiMiner::Verifying::NO_CLAIM, verdict.outcome
    assert verdict.unreachable, "a probe that did not run has to be marked, not settled"
    refute verdict.vote?
  end

  def test_a_reference_that_still_resolves_is_a_dissent
    # Keyed by the *bare* symbol, which is what the probe is handed: `module` and `symbol` are two
    # fields on the claim and the message that names both is `dotted`. Keying the stub on the dotted
    # spelling is a miss, and a miss is an empty answer — which reads as "the name resolved" and
    # would have made these two tests pass for the wrong reason.
    answers = { "module" => "sqlalchemy",
                ["1.4.54", "symbol", "IdentityOptions"] => "" }
    verdict = scripted(answers) do |build|
      V.reference(V.claim_for(SYMBOL_REPORT), build: build)
    end

    assert_equal AgentsFyiMiner::Ledger::DISSENTED, verdict.outcome
    assert_includes verdict.executed, "still exports the name"
  end

  def test_a_reference_raised_on_the_release_it_came_from_is_a_dissent
    # The resolution is written as a plain removal rather than as the move `SYMBOL_REPORT` carries,
    # because a fix that names a destination is *checked first* and this test is about the other
    # branch: one release cannot establish that a removal happened, so the release the report came
    # from is asked as well. With the move left in, the fix probe answers and the verdict is a
    # confirmation — which is what this test said when it was first ported.
    report = SYMBOL_REPORT.merge(
      "resolution" => "`sqlalchemy.IdentityOptions` is gone in sqlalchemy 1.4.54. Pin below."
    )
    answers = {
      "module" => "sqlalchemy",
      ["1.4.54", "symbol", "IdentityOptions"] =>
        attribute_refusal("sqlalchemy", "IdentityOptions"),
      ["1.3.24", "symbol", "IdentityOptions"] =>
        attribute_refusal("sqlalchemy", "IdentityOptions")
    }
    verdict = scripted(answers) do |build|
      V.reference(V.claim_for(report), build: build)
    end

    assert_equal AgentsFyiMiner::Ledger::DISSENTED, verdict.outcome
    assert_includes verdict.executed, "already gone"
  end

  def test_a_fix_that_cannot_be_run_is_still_a_confirmation_of_the_problem
    # The corpus counts the *problem*, and a fix that could not be executed here is a reason to say
    # the fix was not run rather than to withhold the confirmation.
    answers = {
      "module" => "httpx",
      ["0.28.1", "call", "AsyncClient", "app"] => refusal("AsyncClient", "app"),
      ["0.28.1", "call", "AsyncClient", "transport"] => "TIMEOUT"
    }
    verdict = scripted(answers) { |build| V.as_reported(V.claim_for(ARGUMENT_REPORT), build: build) }

    assert_equal AgentsFyiMiner::Ledger::REPRODUCED, verdict.outcome
    assert_includes verdict.executed, "could not be run"
  end

  # --- the fix may not be the thing the report says is broken --------------------------------

  def test_the_path_a_report_says_is_gone_is_not_its_own_fix
    # A removal's resolution opens by naming the path the caller already has, and a regex looking for
    # a dotted location read that as the fix's destination: the fix "failed to resolve" and two true
    # reports were filed `partial`.
    report = SYMBOL_REPORT.merge(
      "resolution" => "`sqlalchemy.IdentityOptions` is gone in sqlalchemy 1.4.54. Pin below."
    )

    assert_equal "", V.claim_for(report).moved
  end

  def test_two_spellings_of_one_name_do_not_make_the_name_its_own_fix
    # `pymupdf 1.24.14 removed pymupdf.JM_Warning` says the distribution spelling in its problem and
    # quotes the interpreter against the *module* — `module 'fitz' has no attribute 'JM_Warning'` — so
    # the path the comparison excludes is `fitz.JM_Warning` while the resolution names
    # `pymupdf.JM_Warning`. Compared without case, which is what catches it.
    report = {
      "library" => "pymupdf", "version" => "1.24.14", "subject_kind" => "package",
      "status" => "resolved_unverified", "submitted_by" => "somebody",
      "problem" => "Upgrading pymupdf from 1.24.13 to 1.24.14 breaks code that names " \
                   "`pymupdf.JM_Warning`. Found by executing the same reference against both " \
                   "releases: it resolved on 1.24.13 and raised on 1.24.14.\n\n" \
                   "AttributeError: module 'fitz' has no attribute 'JM_Warning'",
      "signatures" => ["attributeerror", "object has no attribute"],
      "resolution" => "`pymupdf.JM_Warning` is gone in pymupdf 1.24.14. Pin below."
    }

    assert_equal "", V.claim_for(report).moved
  end

  # --- the payload -----------------------------------------------------------------------------

  def test_the_payload_carries_the_execution_and_the_releases_it_ran_against
    verdict = V::Verdict.of(outcome: AgentsFyiMiner::Ledger::REPRODUCED, executed: "ran the call")
    payload = V.payload(verdict, V.claim_for(ARGUMENT_REPORT), V::AS_REPORTED)

    assert_equal AgentsFyiMiner::Ledger::REPRODUCED, payload["outcome"]
    assert_equal "ran the call", payload["notes"]
    assert_includes payload["environment"], "httpx 0.27.2 and httpx 0.28.1"
    assert_includes payload["environment"], "verified by executing against"
    assert_includes payload["environment"], "method: as-reported"
  end

  def test_a_verdict_that_is_not_a_vote_is_not_counted_as_one
    refute V::Verdict.of(outcome: V::NO_CLAIM, unreachable: true).vote?
    assert V::Verdict.of(outcome: AgentsFyiMiner::Ledger::PARTIAL).vote?
  end
end
