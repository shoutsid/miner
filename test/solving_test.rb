# frozen_string_literal: true

require_relative "test_helper"

# Linking an executed finding to somebody else's report, and refusing to guess.
#
# The samples are the corpus's own, as everywhere in this suite: `sqlalchemy`'s
# `convert_unicode=` (the removal that makes this whole module useful) and `httpx`'s `proxies`
# → `proxy` (the rename whose *resolution text* is the thing being matched against, in every
# spelling an operator might have written it).
class SolvingTest < MinerTest
  S = AgentsFyiMiner::Solving
  MECHANISM = AgentsFyiMiner::Mechanism

  HISTORY = %w[1.4.0 1.4.54 2.0.0 2.0.5 2.0.54].freeze
  PAIR = AgentsFyiMiner::Pair.of(package: "sqlalchemy", from_version: "1.4.54",
    to_version: "2.0.54")

  # A report as the corpus serves one. String keys, because that is what a JSON body is and
  # what every rule in `solving.rb` reads — a test that built it with symbols would be testing a
  # hash the service never sends.
  def report(**overrides)
    body = {
      "id" => "00000000-0000-0000-0000-000000000001",
      "library" => "sqlalchemy",
      "version" => "2.0.5",
      "subject_kind" => "package",
      "status" => "open",
      "resolution" => nil,
      "signatures" => ["typeerror", "unexpected keyword argument 'convert_unicode'"],
      "updated_at" => "2026-01-01T00:00:00Z"
    }
    overrides.each { |key, value| body[key.to_s] = value }
    body
  end

  def removed(parameter = "convert_unicode")
    AgentsFyiMiner::Finding.new(
      library: "sqlalchemy",
      version: "2.0.54",
      mechanism: MECHANISM::PARAMETER_REMOVED,
      title: "sqlalchemy 2.0.54 removed the #{parameter}= argument",
      problem: "gone",
      resolution: "`#{parameter}=` is gone in sqlalchemy 2.0.54. Pin below this release.",
      parameter: parameter,
      call_sites: 6,
      repaired_call_sites: 0
    )
  end

  def renamed(parameter = "proxies", replacement = "proxy")
    AgentsFyiMiner::Finding.new(
      library: "httpx",
      version: "0.28.1",
      mechanism: MECHANISM::PARAMETER_RENAMED,
      title: "httpx 0.28.1 renamed #{parameter}= to #{replacement}=",
      problem: "renamed",
      resolution: "Rename the argument: `#{parameter}=` is `#{replacement}=` in httpx 0.28.1.",
      parameter: parameter,
      replacement: replacement,
      call_sites: 11,
      repaired_call_sites: 11
    )
  end

  def test_the_argument_an_error_refused_is_read_out_of_a_stored_signature
    # The service lowercases every token it stores, so the name read back is lowercased whatever
    # the caller wrote.
    stored = ["typeerror", "unexpected keyword argument 'Convert_Unicode'"]

    assert_equal ["convert_unicode"], S.named_arguments(stored)
  end

  def test_an_open_report_naming_the_argument_is_a_question_this_miner_can_answer
    assert S.needs_a_fix?(report)
    assert S.answerable?(report)
  end

  def test_a_report_that_already_has_a_fix_is_never_given_a_second_one
    # The corpus adopts a report's first proposal, so a second is a competing answer rather than
    # the missing half of a failure.
    refute S.needs_a_fix?(report(resolution: "pin to 1.4"))
    assert S.needs_reproduction?(report(resolution: "pin to 1.4", status: "resolved_unverified"))
  end

  def test_a_verified_report_is_not_reproduced_again
    # It has the confirmations it needs, and re-confirming spends the write quota on a number
    # that is already right.
    refute S.needs_reproduction?(report(resolution: "fix", status: "resolved_verified"))
  end

  def test_a_report_that_never_named_a_version_is_not_answerable
    refute S.answerable?(report(version: "unknown"))
  end

  def test_a_platform_report_is_not_a_package_release_to_compare
    refute S.answerable?(report(subject_kind: "platform"))
  end

  def test_a_timeout_is_not_a_question_the_differential_can_answer
    refute S.answerable?(report(signatures: %w[timeout connecttimeout]))
  end

  def test_the_pair_compared_is_the_report_s_own_line_against_the_one_below
    # A caller on 2.0.5 is on a line whose crossing is what removed the argument, and patches
    # within a line have identical signatures.
    assert_equal [PAIR], S.pairs_for_report(report, HISTORY)
  end

  def test_a_report_on_the_newest_release_still_resolves_to_its_line
    assert_equal "2.0.54", S.pairs_for_report(report(version: "2.0.54"), HISTORY)[0].to_version
  end

  def test_a_report_about_a_library_with_one_line_has_no_upgrade_to_compare
    assert_equal [], S.pairs_for_report(report(library: "single"), %w[1.0.0 1.0.1])
  end

  def test_the_argument_name_is_the_whole_link_between_a_finding_and_a_report
    # The symbol is deliberately not required to match: the mechanism is what clusters
    # twenty-three call sites into one finding, and a report from somebody whose call site is
    # `Session(...)` is the same break as one established on `create_engine(...)`.
    assert_equal "convert_unicode", S.match(removed, report)
    assert_nil S.match(removed("unicode_error"), report)
  end

  def test_a_matching_argument_that_matches_nothing_is_not_a_link
    assert_nil S.match(removed(""), report)
  end

  def test_an_open_report_gets_the_fix_the_miner_executed
    answer = S.answer_for(report, removed, PAIR)

    refute_nil answer
    assert_equal "resolution", answer.kind
    assert_includes answer.payload["environment"], "convert_unicode"
    assert_includes answer.payload["environment"], "executing the same call"
    assert_includes answer.payload["notes"], "not necessarily"
  end

  def test_a_fix_that_names_the_replacement_the_miner_ran_is_reproduced
    # The vote is cast by executing, and only when the recorded fix is the change that was
    # executed.
    answer = S.answer_for(
      report(
        library: "httpx",
        version: "0.28.1",
        signatures: ["unexpected keyword argument 'proxies'"],
        resolution: "rename proxies= to proxy= in the client call",
        status: "resolved_unverified"
      ),
      renamed,
      AgentsFyiMiner::Pair.of(package: "httpx", from_version: "0.27.2", to_version: "0.28.1")
    )

    refute_nil answer
    assert_equal "verification", answer.kind
    assert_equal "reproduced", answer.payload["outcome"]
    assert_includes answer.payload["environment"], "proxy="
  end

  def test_a_fix_that_does_not_name_the_replacement_is_not_voted_for
    # `pin below this release` may well be right, and execution has not tested it, so reporting
    # it as reproduced would be evidence invented.
    answer = S.answer_for(
      report(
        library: "httpx",
        version: "0.28.1",
        signatures: ["unexpected keyword argument 'proxies'"],
        resolution: "pin httpx below 0.28 until the client is updated",
        status: "resolved_unverified"
      ),
      renamed,
      AgentsFyiMiner::Pair.of(package: "httpx", from_version: "0.27.2", to_version: "0.28.1")
    )

    assert_nil answer
  end

  # The boundary between "the resolution names the replacement" and "the resolution contains its
  # letters" is the whole of the rule below, and the words where the two readings disagree are the
  # short ones: `id`, `on`, `to`.
  def test_a_replacement_contained_in_a_longer_word_is_not_the_recorded_fix
    # `id` is inside "invalid", which is how a resolution that never names the replacement passed
    # the gate that exists to establish that it does.
    body = report(resolution: "The argument is invalid in this release; pin below it.")

    assert_nil S.verification_payload(renamed("proxies", "id"), body)
  end

  def test_a_replacement_that_is_a_prefix_of_another_word_is_not_the_recorded_fix
    body = report(resolution: "Only release 0.28 and later accept this call.")

    assert_nil S.verification_payload(renamed("proxies", "on"), body)
  end

  def test_a_replacement_inside_another_word_is_not_the_recorded_fix
    body = report(resolution: "Fold the argument into a dict before constructing the client.")

    assert_nil S.verification_payload(renamed("proxies", "to"), body)
  end

  def test_a_resolution_naming_the_removed_argument_and_not_the_replacement_is_refused
    # The half-finished fix, which a containment test cannot tell from the real one: it says the
    # old name and never the new one.
    body = report(resolution: "Rename proxies= in the client call.")

    assert_nil S.verification_payload(renamed("proxies", "proxy"), body)
  end

  def test_a_replacement_the_corpus_spells_with_its_module_still_counts
    # The corpus writes the qualified name where the finding's replacement is the leaf; that
    # spelling adds a qualifier without changing what was executed.
    body = report(resolution: "Construct it with `httpx.Client` instead of the module function.")
    payload = S.verification_payload(renamed("proxies", "Client"), body)

    refute_nil payload
    assert_equal "reproduced", payload["outcome"]
  end

  def test_a_replacement_that_is_a_call_shape_still_counts_where_it_ends_in_a_paren
    # A word boundary cannot anchor this one: the name ends in `)`, so it would need a word
    # character after it that the prose does not put there.
    body = report(resolution: "Replace the call with client.get(x, timeout=5) in the helper.")
    payload = S.verification_payload(renamed("proxies", "client.get(x, timeout=5)"), body)

    refute_nil payload
    assert_includes payload["environment"], "client.get(x, timeout=5)"
  end

  def test_a_finding_about_another_argument_leaves_the_report_alone
    assert_nil S.answer_for(report, removed("preserve_parameter_order"), PAIR)
  end
end
