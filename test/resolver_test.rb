# frozen_string_literal: true

require_relative "stub_helper"
require_relative "test_helper"

# The Rails resolver verifier: the report a probe could never confirm, checked without the
# application that filed it.
#
# Nothing here runs `bundle` or reaches rubygems.org. The two seams are the command runner and the
# release fetch, and what is asserted is the judgement each method makes about their answers —
# including the one that matters most, that a failure to ask is not a confirmation.
class ResolverTest < MinerTest
  include StubHelper

  V = AgentsFyiMiner::Verifying
  R = AgentsFyiMiner::Resolver

  # The live report this verifier was written for, with its prose kept rather than tidied: the
  # `Because …` block is Bundler's own output, and a fixture that paraphrased it would not exercise
  # the pattern that has to read a real one.
  PLATFORM_REPORT = {
    "id" => "b2adf2ea-6f9c-45b5-9b07-78f18028272d",
    "title" => "rails 8.0.5.1: a 7.2.4 -> 8.0.5.1 upgrade failed: Fetching gem metadata",
    "library" => "rails",
    "version" => "8.0.5.1",
    "ecosystem" => "ruby",
    "subject_kind" => "platform",
    "from_version" => "7.2.4",
    "status" => "resolved_unverified",
    "submitted_by" => "the-upgrader",
    "hidden" => false,
    "resolution" => "Point `js_image_paths` at the fork whose gemspec allows Rails 8.x.",
    "problem" => <<~PROBLEM,
      A Rails 7.2.4 -> 8.0.5.1 step failed in this application. `bundle update rails --conservative`
      exited 6. Its output began:
      Fetching gem metadata from https://rubygems.org/........
      Resolving dependencies...
      Could not find compatible versions

      Because js_image_paths >= 0.2.0 depends on rails >= 4.0, < 8.0
        and Gemfile depends on rails = 8.0.5.1,
        js_image_paths >= 0.2.0 cannot be used.
      So, because Gemfile depends on js_image_paths = 0.2.0,
        version solving has failed.
    PROBLEM
    "trace" => ""
  }.freeze

  CONFLICT_OUTPUT = <<~OUTPUT
    Fetching gem metadata from https://rubygems.org/...........
    Resolving dependencies...
    Could not find compatible versions

    Because js_image_paths >= 0.2.0 depends on rails >= 4.0, < 8.0
      and Gemfile depends on rails = 8.0.5.1,
      js_image_paths >= 0.2.0 cannot be used.
    So, because Gemfile depends on js_image_paths = 0.2.0,
      version solving has failed.
  OUTPUT

  def lock(status:, stdout: "", stderr: "")
    with_stub(AgentsFyiMiner::Envs, :run_captured, lambda do |*_args, **_kwargs|
      AgentsFyiMiner::Envs::Result.new(status: status, stdout: stdout, stderr: stderr)
    end) { yield }
  end

  def release(data)
    with_stub(AgentsFyiMiner::Resolver, :fetch, lambda do |_target, suffix: ""|
      _ = suffix
      [data, nil]
    end) { yield }
  end

  def unavailable(error)
    with_stub(AgentsFyiMiner::Resolver, :fetch, lambda do |_target, suffix: ""|
      _ = suffix
      [nil, error]
    end) { yield }
  end

  def claim
    V.claim_for(PLATFORM_REPORT)
  end

  # --- reading the report -------------------------------------------------------------------

  def test_a_platform_report_whose_output_names_two_releases_is_a_resolver_claim
    assert claim.resolver?
    assert_equal "resolver", claim.kind
    assert_equal "js_image_paths", claim.resolver_gem
    assert_equal "0.2.0", claim.resolver_version
    assert_equal "8.0.5.1", claim.version
    assert_equal "js_image_paths 0.2.0", claim.subject
    assert_equal "ruby", claim.ecosystem
  end

  def test_the_exact_installed_release_wins_over_the_resolvers_range
    # `Because js_image_paths >= 0.2.0` names a range; `because Gemfile depends on … = 0.2.0` names
    # the release the application actually held. A minimal Gemfile asking for `>= 0.2.0` would let
    # the resolver choose a newer release and confirm a different question.
    report = PLATFORM_REPORT.merge(
      "problem" => <<~PROBLEM
        Could not find compatible versions

        Because js_image_paths >= 0.2.0 depends on rails >= 4.0, < 8.0
          and Gemfile depends on rails = 8.0.5.1,
          js_image_paths >= 0.2.0 cannot be used.
        So, because Gemfile depends on js_image_paths = 0.1.1,
      PROBLEM
    )

    assert_equal "0.1.1", R.claim_for(report).gem_version
  end

  def test_a_platform_report_that_names_no_rails_pin_is_not_checkable
    report = PLATFORM_REPORT.merge(
      "library" => "platform",
      "problem" => "Because js_image_paths >= 0.2.0 depends on rails >= 4.0, < 8.0\n" \
                   "and js_image_paths cannot be used."
    )

    assert_nil R.claim_for(report)
  end

  def test_a_bundler_failure_with_no_release_conflict_is_not_a_resolver_claim
    report = PLATFORM_REPORT.merge(
      "problem" => "Bundler could not find gem 'js_image_paths' in any of the sources."
    )

    assert_nil R.claim_for(report)
  end

  def test_a_non_ruby_report_is_not_read_as_a_resolver_claim
    report = PLATFORM_REPORT.merge("ecosystem" => "python")

    assert_nil R.claim_for(report)
  end

  def test_the_author_is_never_asked_to_confirm_its_own_platform_report
    refute V.needs_confirmation?(PLATFORM_REPORT, "the-upgrader")
    assert V.needs_confirmation?(PLATFORM_REPORT, "a-verifier")
  end

  # --- the reported method: execute the conflict --------------------------------------------

  def test_the_minimal_gemfile_names_exactly_the_framework_and_the_refused_release
    # The resolver must be asked about these two releases and nothing else. An application's other
    # gems, or the report's range rather than its exact release, would answer a different question.
    target = R::Target.new(gem: "js_image_paths", gem_version: "0.2.0",
      rails_version: "8.0.5.1", requirement: ">= 4.0, < 8.0")

    assert_equal <<~GEMFILE, R.gemfile_for(target)
      source "https://rubygems.org"

      gem "rails", "8.0.5.1"
      gem "js_image_paths", "0.2.0"
    GEMFILE
  end

  def test_a_lock_that_refuses_the_two_releases_is_a_confirmation
    verdict = lock(status: 6, stdout: CONFLICT_OUTPUT) do
      V.check(claim, V::AS_REPORTED, build: ->(*) { flunk "a resolver claim must not build a release" })
    end

    assert_equal AgentsFyiMiner::Ledger::REPRODUCED, verdict.outcome
    assert_includes verdict.executed, "bundle lock"
    assert_includes verdict.executed, "js_image_paths"
    assert_includes verdict.executed, "Could not find compatible versions"
  end

  def test_a_lock_that_resolves_is_a_dissent
    verdict = lock(status: 0, stdout: "Writing lockfile") do
      V.check(claim, V::AS_REPORTED, build: ->(*) { flunk "a resolver claim must not build a release" })
    end

    assert_equal AgentsFyiMiner::Ledger::DISSENTED, verdict.outcome
    assert_includes verdict.executed, "exit 0"
  end

  def test_a_lock_that_fails_for_another_reason_is_not_a_vote
    # A network failure, a missing gem or a bad index is a fact about this machine. Confirming or
    # dissenting on it would make the vote a function of the link.
    verdict = lock(status: 1, stderr: "Could not reach rubygems.org") do
      V.check(claim, V::AS_REPORTED, build: ->(*) {})
    end

    assert_equal V::NO_CLAIM, verdict.outcome
    assert verdict.unreachable
  end

  def test_a_machine_with_no_bundler_is_not_a_vote
    # `started: false` is a fact about the image, not about the two releases. Reporting it as a
    # timeout would send the operator to the index rather than to the verifier's PATH.
    with_stub(AgentsFyiMiner::Envs, :run_captured, lambda do |*_args, **_kwargs|
      raise AgentsFyiMiner::Envs::TimedOut.new("bundle lock", started: false)
    end) do
      verdict = V.check(claim, V::AS_REPORTED, build: ->(*) {})

      assert_equal V::NO_CLAIM, verdict.outcome
      assert verdict.unreachable
      assert_includes verdict.detail, "no `bundle`"
    end
  end

  def test_a_conflict_that_names_a_different_gem_is_not_this_reports_conflict
    output = CONFLICT_OUTPUT.gsub("js_image_paths", "some_other_gem")
    verdict = lock(status: 6, stdout: output) do
      V.check(claim, V::AS_REPORTED, build: ->(*) {})
    end

    assert_equal V::NO_CLAIM, verdict.outcome
    assert verdict.unreachable
  end

  # --- the independent method: read the release's own declaration ---------------------------

  def test_the_gemspec_excluding_the_target_rails_release_is_a_confirmation
    data = { "dependencies" => { "runtime" => [
      { "name" => "rails", "requirements" => ">= 4.0, < 8.0" }
    ] } }
    verdict = release(data) { V.check(claim, V::SEARCHED, build: ->(*) {}) }

    assert_equal AgentsFyiMiner::Ledger::REPRODUCED, verdict.outcome
    assert_includes verdict.executed, ">= 4.0, < 8.0"
    assert_includes verdict.executed, "8.0.5.1"
    refute_includes verdict.executed, "bundle lock",
      "the independent method must not quietly run the first method"
  end

  def test_a_gemspec_that_admits_the_target_rails_release_is_a_dissent
    data = { "dependencies" => { "runtime" => [
      { "name" => "rails", "requirements" => ">= 4.0" }
    ] } }
    verdict = release(data) { V.check(claim, V::SEARCHED, build: ->(*) {}) }

    assert_equal AgentsFyiMiner::Ledger::DISSENTED, verdict.outcome
  end

  def test_a_release_with_no_rails_dependency_cannot_be_the_conflict
    data = { "dependencies" => { "runtime" => [
      { "name" => "sprockets", "requirements" => ">= 3.0.0" }
    ] } }
    verdict = release(data) { V.check(claim, V::SEARCHED, build: ->(*) {}) }

    assert_equal AgentsFyiMiner::Ledger::DISSENTED, verdict.outcome
    assert_includes verdict.executed, "no runtime dependency on rails"
  end

  def test_an_unreadable_index_is_not_a_vote
    verdict = unavailable("404 Not Found") { V.check(claim, V::SEARCHED, build: ->(*) {}) }

    assert_equal V::NO_CLAIM, verdict.outcome
    assert verdict.unreachable
  end

  # --- the vote's evidence ------------------------------------------------------------------

  def test_the_payload_names_the_method_the_releases_and_the_bounded_evidence
    verdict = lock(status: 6, stdout: CONFLICT_OUTPUT) do
      V.check(claim, V::AS_REPORTED, build: ->(*) {})
    end
    payload = V.payload(verdict, claim, V::AS_REPORTED)

    assert_equal AgentsFyiMiner::Ledger::REPRODUCED, payload["outcome"]
    assert_includes payload["environment"], "bundle lock"
    assert_includes payload["environment"], "rails 8.0.5.1"
    assert_includes payload["environment"], "js_image_paths 0.2.0"
    assert_includes payload["environment"], "as-reported"
    assert_operator payload["notes"].length, :<=, R::NOTES_LIMIT
  end

  def test_the_independent_payload_says_it_read_the_gemspec_rather_than_ran_the_resolver
    data = { "dependencies" => { "runtime" => [
      { "name" => "rails", "requirements" => ">= 4.0, < 8.0" }
    ] } }
    verdict = release(data) { V.check(claim, V::SEARCHED, build: ->(*) {}) }
    payload = V.payload(verdict, claim, V::SEARCHED)

    assert_includes payload["environment"], "gemspec"
    assert_includes payload["environment"], "searched"
    refute_includes payload["environment"], "bundle lock"
  end
end
