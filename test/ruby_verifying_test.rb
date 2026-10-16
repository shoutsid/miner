# frozen_string_literal: true

require_relative "stub_helper"
require_relative "test_helper"

# Checking a gem's report: the same three outcomes as the PyPI side, reached by running a *reference*
# rather than a call site.
#
# The Ruby client files no argument claims — its keyword pass is not a call-site analysis, so a
# parameter claim about a gem has no execution behind it — which is why the whole of this file is
# about a name and the two places it can be: still there (a dissent) or gone (a confirmation, with
# the release it came from asked as well).
#
# Nothing installs anything: the one probe function is stubbed, and the strings below are the
# interpreter's own, copied from real runs rather than imagined — `uninitialized constant …
# Bundler::Graph` with no quoting is Ruby 3.3's spelling and is exactly the shape a quoting-only
# match read as "not refused".
class RubyVerifyingTest < MinerTest
  include StubHelper

  V = AgentsFyiMiner::Verifying
  R = AgentsFyiMiner::RubyEnvs

  GEM_REPORT = {
    "id" => "00000000-0000-0000-0000-000000000003",
    "library" => "bundler",
    "version" => "2.6.0",
    # The field that says which index the two releases belong to, and the one thing `claim_for`
    # branches on: without it this fixture was read down the PyPI path, found no `signatures` and no
    # quoted reference, and answered nil — twelve tests failing on a fixture that was missing the
    # field rather than on the code that reads it.
    "ecosystem" => "ruby",
    "subject_kind" => "package",
    "status" => "resolved_unverified",
    "change_kind" => "symbol_removed",
    "subject" => "Bundler::Graph",
    "from_version" => "",
    "submitted_by" => "the-miner",
    "hidden" => false,
    "resolution" => "`Bundler::Graph` is gone in bundler 2.6.0. Pin below.",
    "problem" => "Upgrading bundler from 2.5.0 to 2.6.0 breaks code that names " \
                 "`Bundler::Graph`. Found by executing both releases and reading the same name " \
                 "from each: it resolved on 2.5.0 and raised on 2.6.0.\n\n" \
                 "NameError: uninitialized constant Bundler::Graph",
    "attempted" => "Bundler::Graph"
  }.freeze

  def refusal(symbol)
    "NameError: uninitialized constant #{symbol}"
  end

  # One release whose answers are written down, keyed by release and expression.
  def scripted(answers)
    @answers = answers
    probes = {
      probe: ->(env, expression, suffix: "") { @answers[[env.version, expression]] || "" }
    }
    builder = lambda do |library, version|
      R::Env.of(package: library, version: version, root: @home, require_path: library)
    end
    with_stubs(R, probes) { yield builder }
  end

  # --- reading a gem's report ----------------------------------------------------------------

  def test_a_gem_report_yields_the_reference_its_own_subject_names
    claim = V.claim_for(GEM_REPORT)

    refute_nil claim
    assert claim.is_ruby?
    assert_equal "Bundler::Graph", claim.reference
    assert_equal "constant", claim.reference_kind
    assert_equal "Graph", claim.leaf
    assert_equal "Bundler::Graph", claim.subject
  end

  def test_the_release_a_gem_report_came_from_is_read_from_its_own_sentence
    assert_equal "2.5.0", V.claim_for(GEM_REPORT).from_version
  end

  def test_a_gem_report_of_a_mechanism_the_client_does_not_file_is_not_checkable
    # The Ruby client files symbol findings and nothing else, so a parameter claim about a gem has no
    # execution behind it to check — and guessing one would confirm a mechanism nobody established.
    report = GEM_REPORT.merge("change_kind" => "argument_renamed")

    assert_nil V.claim_for(report)
  end

  def test_a_gem_subject_that_could_not_be_a_reference_is_refused_rather_than_guessed
    # A subject no release could have defined is refused rather than passed to an interpreter.
    assert_nil V.claim_for(GEM_REPORT.merge("subject" => "not a reference!"))
  end

  def test_an_instance_method_keeps_its_separator
    # Reading `Foo#bar` as `Foo::bar` would probe a constant that never existed and report a removal
    # that never happened.
    report = GEM_REPORT.merge("subject" => "Bundler::CurrentRuby#ruby_35_18?")
    claim = V.claim_for(report)

    assert_equal "instance", claim.reference_kind
    assert_equal "ruby_35_18?", claim.leaf
  end

  def test_a_gem_report_whose_fix_is_the_name_it_says_is_gone_has_no_fix
    # A removal's resolution opens by naming the reference the caller already has, and reading that as
    # the destination would turn every removal into a move back to where the caller is.
    assert_equal "", V.claim_for(GEM_REPORT).moved
  end

  def test_a_gem_rename_is_read_from_the_fixes_own_reference
    report = GEM_REPORT.merge(
      "resolution" => "`Bundler::Graph` is gone in bundler 2.6.0. It is " \
                      "`Bundler::Parsers::Graph` now."
    )

    assert_equal "Bundler::Parsers::Graph", V.claim_for(report).moved
  end

  # --- checking a gem's reference ------------------------------------------------------------

  def test_a_reference_that_still_resolves_is_a_dissent
    # An empty run is a reference that resolved, so the release the report names still defines the
    # name it says it lost.
    answers = { ["2.6.0", "Bundler::Graph"] => "" }
    verdict = scripted(answers) do |build|
      V.check(V.claim_for(GEM_REPORT), V::AS_REPORTED, build: build)
    end

    assert_equal AgentsFyiMiner::Ledger::DISSENTED, verdict.outcome
    assert_includes verdict.executed, "still defines the name"
  end

  def test_a_gem_release_that_will_not_load_is_not_a_vote
    # The third answer: a gem that could not be required says nothing about the report, so the verdict
    # abstains and is marked, which is what makes the loop come back to it rather than retire it.
    answers = { ["2.6.0", "Bundler::Graph"] => "LoadError: cannot load such file -- bundler" }
    verdict = scripted(answers) do |build|
      V.check(V.claim_for(GEM_REPORT), V::AS_REPORTED, build: build)
    end

    assert_equal V::NO_CLAIM, verdict.outcome
    assert verdict.unreachable
    refute verdict.vote?
  end

  def test_a_reference_that_resolved_on_the_release_it_came_from_is_a_confirmation
    answers = {
      ["2.6.0", "Bundler::Graph"] => refusal("Bundler::Graph"),
      ["2.5.0", "Bundler::Graph"] => ""
    }
    verdict = scripted(answers) do |build|
      V.check(V.claim_for(GEM_REPORT), V::AS_REPORTED, build: build)
    end

    assert_equal AgentsFyiMiner::Ledger::REPRODUCED, verdict.outcome
    assert_includes verdict.executed, "resolved before and raising now"
  end

  def test_a_reference_the_release_it_came_from_already_refused_is_a_dissent
    answers = {
      ["2.6.0", "Bundler::Graph"] => refusal("Bundler::Graph"),
      ["2.5.0", "Bundler::Graph"] => refusal("Bundler::Graph")
    }
    verdict = scripted(answers) do |build|
      V.check(V.claim_for(GEM_REPORT), V::AS_REPORTED, build: build)
    end

    assert_equal AgentsFyiMiner::Ledger::DISSENTED, verdict.outcome
    assert_includes verdict.executed, "already gone"
  end

  def test_a_gem_report_with_no_release_to_compare_against_gets_no_vote
    # "This release took it away" is a claim about a change, and one release cannot establish it.
    report = GEM_REPORT.merge("problem" => "Upgrading bundler broke code that names `Bundler::Graph`.")
    claim = V.claim_for(report)

    assert_equal "", claim.from_version
    answers = { ["2.6.0", "Bundler::Graph"] => refusal("Bundler::Graph") }
    verdict = scripted(answers) { |build| V.check(claim, V::AS_REPORTED, build: build) }

    assert_equal V::NO_CLAIM, verdict.outcome
    refute verdict.unreachable, "nothing failed here: the report named no before-release"
  end

  def test_a_gem_fix_that_does_not_resolve_is_a_partial
    # The problem reproduces and the advice does not run, which the corpus does not count and which is
    # the answer a reader most needs to see.
    report = GEM_REPORT.merge(
      "resolution" => "`Bundler::Graph` is gone in bundler 2.6.0. It is " \
                      "`Bundler::Parsers::Graph` now."
    )
    answers = {
      ["2.6.0", "Bundler::Graph"] => refusal("Bundler::Graph"),
      ["2.6.0", "Bundler::Parsers::Graph"] => refusal("Bundler::Parsers::Graph")
    }
    verdict = scripted(answers) { |build| V.check(V.claim_for(report), V::AS_REPORTED, build: build) }

    assert_equal AgentsFyiMiner::Ledger::PARTIAL, verdict.outcome
    assert_includes verdict.executed, "did not resolve"
  end

  def test_the_payload_names_the_two_releases_and_the_method
    verdict = V::Verdict.of(outcome: AgentsFyiMiner::Ledger::REPRODUCED, executed: "ran it")
    payload = V.payload(verdict, V.claim_for(GEM_REPORT), V::SEARCHED)

    assert_equal "ran it", payload["notes"]
    assert_includes payload["environment"], "bundler 2.5.0 and bundler 2.6.0"
    assert_includes payload["environment"], "method: searched"
  end
end
