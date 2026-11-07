# frozen_string_literal: true

require_relative "test_helper"

# **A non-gem transition, executed as declared and judged by the process's own exit.**
#
# The corpus stores an examination because an execution happened, so the client half is the part
# that runs something. Nothing here installs or deploys: the runner is replaced, because a test
# that started a real service would be measuring the machine rather than the judgement this file
# is about. What is asserted is the judgement — `clean`, `findings`, `unexaminable` — and the cell
# the service will read.
class TransitionTest < MinerTest
  T = AgentsMiner::Transition

  def declaration(overrides = {})
    {
      "subject_kind" => "service", "ecosystem" => "ruby",
      "library" => "checkout-api", "from_version" => "2.1.0", "to_version" => "2.2.0",
      "interpreter" => "ruby 3.3.12", "framework" => "rails 7.1",
      "environment" => { "RAILS_ENV" => "production" },
      "checks" => [
        { "kind" => "deploy", "command" => ["bin/deploy", "2.2.0"] },
        { "kind" => "health", "command" => ["curl", "-fsS", "http://localhost:3000/up"] },
        { "kind" => "contract", "command" => ["bundle", "exec", "rspec"] }
      ]
    }.merge(overrides)
  end

  # A runner that answers each command by position: `0` exits clean, anything else is the exit
  # status, and an exception is raised rather than returned.
  def runner(*answers)
    calls = []
    lambda do |argv, cwd:, timeout:, env:|
      calls << { argv: argv, cwd: cwd, timeout: timeout, env: env }
      answer = answers.shift
      raise answer if answer.is_a?(Exception)

      AgentsMiner::Envs::Result.new(status: answer || 0, stdout: "ran #{argv.join(' ')}", stderr: "")
    end
  end

  def test_three_checks_become_three_cells_and_only_the_exit_decides_the_outcome
    plan = T.parse(declaration)
    cells = T.cells(plan, runner: runner(0, 0, 0), now: Time.at(1_700_000_000))

    assert_equal %w[deploy health contract], cells.map { |cell| cell["check_kind"] }
    assert_equal %w[clean clean clean], cells.map { |cell| cell["outcome"] }
    assert(cells.all? { |cell| cell["subject_kind"] == "service" })
    assert(cells.all? { |cell| cell["ecosystem"] == "ruby" })
    assert(cells.all? { |cell| cell["library"] == "checkout-api" })
    assert(cells.all? { |cell| cell["from_version"] == "2.1.0" && cell["to_version"] == "2.2.0" })
    # The environment is structured, not prose: it is what the reader stores and what a caller
    # filters on.
    assert_equal({ "RAILS_ENV" => "production" }, cells.first["environment"])
    assert_equal "2023-11-14T22:13:20Z", cells.first["examined_at"]
  end

  def test_a_non_zero_exit_is_findings_and_not_unexaminable
    plan = T.parse(declaration)
    cell = T.cells(plan, runner: runner(1), now: Time.at(0)).first

    assert_equal "findings", cell["outcome"]
    assert_equal 1, cell["finding_count"]
    assert_equal 1, cell["evidence"]["exit_code"]
    assert_equal "findings", cell["checks"].first["status"]
  end

  # A command that could not start measured nothing about the transition. It is `unexaminable`,
  # which is a fact about the machine rather than a finding about the release.
  def test_a_command_that_cannot_start_is_unexaminable
    plan = T.parse(declaration)
    cell = T.cells(plan, runner: runner(AgentsMiner::Envs::TimedOut.new("bin/deploy", started: false)),
      now: Time.at(0)).first

    assert_equal "unexaminable", cell["outcome"]
    assert_equal 0, cell["finding_count"]
    assert_nil cell["evidence"]["exit_code"]
    assert_includes cell["evidence"]["detail"], "could not be started"
  end

  # A deadline is the other absence: the command ran and did not finish, which is still not a
  # finding about the release.
  def test_a_deadline_is_unexaminable
    plan = T.parse(declaration)
    cell = T.cells(plan,
      runner: runner(AgentsMiner::Envs::TimedOut.new("bin/deploy", stdout: "partial", started: true)),
      now: Time.at(0)).first

    assert_equal "unexaminable", cell["outcome"]
    assert_includes cell["evidence"]["detail"], "deadline"
    assert_includes cell["evidence"]["output_tail"], "partial"
  end

  # A health probe is `clean` on the exit the declaration names: a check that expects a refusal is
  # still a check with an answer.
  def test_a_check_may_name_the_exit_it_expects
    plan = T.parse(declaration("checks" => [
      { "kind" => "health", "command" => ["check"], "expect_exit" => 3 }
    ]))
    cell = T.cells(plan, runner: runner(3), now: Time.at(0)).first

    assert_equal "clean", cell["outcome"]
  end

  def test_every_check_field_the_cell_carries_reaches_the_service_reader
    plan = T.parse(declaration)
    cell = T.cells(plan, runner: runner(0), now: Time.at(0)).first

    refute_nil cell["evidence"]["command"]
    assert cell["checks"].is_a?(Array)
    assert cell["report_ids"].is_a?(Array)
  end

  def test_a_declaration_without_checks_is_refused_by_name
    error = assert_raises(T::Invalid) { T.parse(declaration("checks" => [])) }

    assert_includes error.message, "checks"
  end

  def test_an_unknown_check_kind_is_refused_by_name
    error = assert_raises(T::Invalid) do
      T.parse(declaration("checks" => [{ "kind" => "smoke", "command" => ["true"] }]))
    end

    assert_includes error.message, "smoke"
    assert_includes error.message, "deploy, health, contract"
  end

  # The schema declares two ecosystems; a third is a 422 the client would read as an outage.
  def test_an_ecosystem_the_schema_does_not_declare_is_refused
    error = assert_raises(T::Invalid) { T.parse(declaration("ecosystem" => "go")) }

    assert_includes error.message, "go"
  end

  def test_a_blank_required_field_is_refused_by_name
    error = assert_raises(T::Invalid) { T.parse(declaration("library" => "  ")) }

    assert_includes error.message, "library"
  end

  def test_a_declaration_file_is_read_and_a_missing_one_is_refused_with_the_path
    file = write("transition.json", declaration)

    assert_equal "checkout-api", T.read(file).library

    error = assert_raises(T::Invalid) { T.read(@home.join("absent.json")) }
    assert_includes error.message, "absent.json"
  end
end
