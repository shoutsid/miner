# frozen_string_literal: true

require_relative "test_helper"

# The comparison a signature diff cannot make: what a release's own values *are*.
#
# Driven with two inventory-shaped objects rather than two installed releases, because the pass is
# a comparison of readings and the readings are what a test can state exactly: a constant that was
# a string and is a table, a value whose class moved, an attribute that exists in only one release.
class BehaviourTest < MinerTest
  B = AgentsMiner::Behaviour
  Inventory = Struct.new(:module, :entries, :values)

  def test_a_value_whose_type_changed_is_one_observation_with_both_readings
    # The case the pass exists for: the name and the signature are identical, and a caller that
    # reads it gets something else.
    found = B.observations(
      inventory("TABLE" => { "type" => "str", "repr" => "'alpha'" }),
      inventory("TABLE" => { "type" => "dict", "repr" => "{'a': 1}" })
    )

    assert_equal 1, found.length
    observation = found.first
    assert_equal "TABLE", observation.symbol
    assert_equal "behaviour", observation.kind
    assert_equal "returns_type", observation.relation
    assert_equal "str `'alpha'`", observation.accepted_output
    assert_equal "dict `{'a': 1}`", observation.observed_after
  end

  def test_a_value_of_the_same_type_that_renders_differently_is_the_weaker_relation
    # `'1.0.0'` to `'2.0.0'`: the class did not move, so a report that claimed a type change would
    # send a reader looking for the wrong thing.
    found = B.observations(
      inventory("VERSION" => { "type" => "str", "repr" => "'1.0.0'" }),
      inventory("VERSION" => { "type" => "str", "repr" => "'2.0.0'" })
    )

    assert_equal ["returns_equal"], found.map(&:relation)
    assert_equal "str `'1.0.0'`", found.first.accepted_output
  end

  def test_a_value_that_did_not_change_is_not_a_finding
    # The common case, and it has to stay empty: an inventory of a release pair that changed
    # nothing is what tells the cycle the package was examined and yielded nothing.
    found = B.observations(
      inventory("FLAG" => { "type" => "bool", "repr" => "True" }),
      inventory("FLAG" => { "type" => "bool", "repr" => "True" })
    )

    assert_empty found
  end

  def test_a_value_present_in_one_release_only_is_the_symbol_pass_s_business
    # A constant that went away is a removal, and the symbol pass already executes a reference to
    # it. Reporting it here as well would file one removal twice under two mechanisms.
    found = B.observations(
      inventory("GONE" => { "type" => "str", "repr" => "'x'" }),
      inventory({})
    )

    assert_empty found
  end

  def test_one_pair_reports_at_most_a_handful_of_values
    # A release whose constants are generated — a registry, a table, a matrix — has hundreds of
    # values, and a finding per value would bury the one a caller can act on.
    older = {}
    newer = {}
    50.times do |index|
      older["K#{index}"] = { "type" => "str", "repr" => "'old'" }
      newer["K#{index}"] = { "type" => "str", "repr" => "'new'" }
    end

    assert_equal B::MAX_ENTRIES, B.observations(inventory(older), inventory(newer)).length
  end

  def test_the_finding_states_both_readings_and_names_no_call
    # What a reader gets: the attribute, what it was, what it is, and the sentence that says
    # nothing was called — because a report implying a call site that does not exist is the
    # fabricated evidence this client is held against.
    observation = B.observations(
      inventory("TABLE" => { "type" => "str", "repr" => "'alpha'" }),
      inventory("TABLE" => { "type" => "dict", "repr" => "{'a': 1}" })
    ).first
    finding = AgentsMiner.summarise("example", "2.0.0", "1.0.0", [observation])

    assert_equal AgentsMiner::Mechanism::BEHAVIOUR_CHANGED, finding.mechanism
    assert_equal "TABLE", finding.subject
    assert_equal "example 2.0.0 changed what example.TABLE is", finding.title
    assert_includes finding.problem, "str `'alpha'`"
    assert_includes finding.problem, "dict `{'a': 1}`"
    assert_includes finding.problem, "returns_type"
    assert_includes finding.resolution, "No name and no parameter changed"

    payload = AgentsMiner::Reporting.payload_for(finding, from_version: "1.0.0")
    assert_equal "behaviour_changed", payload.fetch("change_kind")
    assert_includes payload.fetch("attempted"), "without calling it"
    refute_includes payload.fetch("attempted"), "accepted the argument"
    assert_includes payload.fetch("attempted"), "dict `{'a': 1}`"
    # A behaviour finding has no callable, so there is no scenario proposal to make from it.
    assert_nil AgentsMiner::Reporting.scenario_proposal_for(finding, from_version: "1.0.0")
  end

  private

  def inventory(values)
    Inventory.new("example", [], values)
  end
end
