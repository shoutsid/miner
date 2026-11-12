# frozen_string_literal: true

require_relative "test_helper"
require_relative "stub_helper"

# **The comparison written out for somebody else to run.**
#
# The miner executes the differential; this is the record of it, built from the finding's own fields.
# A finding that carries the probe expression — a symbol or argument pass — gets a **runnable**
# record (a script and a command); a behaviour comparison calls nothing and gets the description
# form. `verify` is what makes `runnable` mean something: the record is re-run in the release's own
# environment and the exception it raises is compared with the one recorded.
class ReproductionTest < MinerTest
  include StubHelper

  R = AgentsMiner::Reproduction
  Finding = AgentsMiner::Finding
  RubyEnvs = AgentsMiner::RubyEnvs
  Envs = AgentsMiner::Envs

  def finding(**overrides)
    defaults = {
      library: "actionpack", version: "5.1.0", mechanism: "symbol_removed",
      title: "actionpack 5.1.0 removed before_filter", problem: "NoMethodError",
      ecosystem: "ruby", symbol: "before_filter", module_name: "actionpack",
      expression: "ActionController::Base.before_filter",
      exception: "undefined method 'before_filter' for ActionController::Base (NoMethodError)",
      runtime: "ruby 2.7.8"
    }
    Finding.new(**defaults.merge(overrides))
  end

  def test_a_ruby_finding_with_an_expression_becomes_a_runnable_record
    record = R.for(finding, from_version: "5.0.7.2")

    assert_equal 1, record.fetch("format")
    assert_equal "ruby", record.fetch("language")
    assert_equal "5.0.7.2", record.fetch("from_version")
    assert_includes record.fetch("manifest"), %(gem "actionpack", "5.1.0")
    assert_includes record.fetch("script"), 'require "actionpack"'
    assert_includes record.fetch("script"), "ActionController::Base.before_filter"
    assert_equal "bundle install && ruby repro.rb", record.fetch("command")
    assert_equal "repro.rb", record.fetch("filename")
    assert_equal "ActionController::Base.before_filter", record.fetch("expression")
    assert_equal "NoMethodError", record.dig("expected", "exception")
    assert_equal false, record.fetch("verified"), "a record is unverified until it is run"
  end

  # A finding with no probe expression — a behaviour comparison, which reads a value and calls
  # nothing — is a description: no script, no command, and the read says so.
  def test_a_finding_with_no_expression_is_a_description
    record = R.for(finding(expression: "", mechanism: "behaviour_changed"),
      from_version: "5.0.7.2")

    refute_nil record
    refute record.key?("command")
    refute record.key?("filename")
    assert_includes record.fetch("manifest"), "actionpack"
    assert_equal "NoMethodError", record.dig("expected", "exception")
  end

  # A Python finding writes a requirement line and imports rather than requires.
  def test_a_python_finding_uses_the_index_it_came_from
    record = R.for(finding(ecosystem: "python", library: "httpx", version: "0.28.1",
      module_name: "httpx", expression: "httpx.Client",
      exception: "TypeError: Client.__init__() got an unexpected keyword argument 'proxies'",
      mechanism: "parameter_removed"), from_version: "0.27.2")

    assert_equal "python", record.fetch("language")
    assert_includes record.fetch("manifest"), "httpx==0.28.1"
    assert_includes record.fetch("script"), "import httpx"
    assert_equal "pip install -r requirements.txt && python repro.py", record.fetch("command")
    assert_equal "TypeError", record.dig("expected", "exception")
  end

  def test_a_finding_with_no_window_names_no_reproduction
    assert_nil R.for(finding, from_version: "")
    assert_nil R.for(finding(version: ""), from_version: "5.0.7.2")
  end

  def test_a_finding_with_no_exception_class_records_no_expected_block
    record = R.for(finding(exception: "syntax error, unexpected end-of-input"), from_version: "5.0.7.2")

    refute_nil record
    refute record.key?("expected")
    assert_includes record.fetch("manifest"), "actionpack"
  end

  # **A verified reproduction keeps its command.** The comparison was re-run in the release's own
  # environment and raised the class the record says it would.
  def test_verify_keeps_a_record_that_reproduced
    record = R.for(finding, from_version: "5.0.7.2")
    env = AgentsMiner::RubyEnvs::Env.new(package: "actionpack", version: "5.1.0",
      root: dir("env"), require_path: "actionpack")

    with_stub(RubyEnvs, :probe, ->(_env, _expression, suffix: "") {
      "undefined method 'before_filter' for ActionController::Base (NoMethodError)\n"
    }) do
      verified = R.verify(record, env: env, ecosystem: "ruby")
      assert_equal true, verified.fetch("verified")
      assert_equal "NoMethodError", verified.dig("observed", "exception")
      assert_equal "bundle install && ruby repro.rb", verified.fetch("command")
    end
  end

  # **A reproduction that did not reproduce is downgraded, not filed as runnable.** The script ran
  # clean (or raised something else), so the record loses its command and says what was observed.
  def test_verify_downgrades_a_record_that_did_not_reproduce
    record = R.for(finding, from_version: "5.0.7.2")
    env = AgentsMiner::RubyEnvs::Env.new(package: "actionpack", version: "5.1.0",
      root: dir("env"), require_path: "actionpack")

    with_stub(RubyEnvs, :probe, ->(_env, _expression, suffix: "") { "" }) do
      verified = R.verify(record, env: env, ecosystem: "ruby")
      assert_equal false, verified.fetch("verified")
      refute verified.key?("command"), "a reproduction that did not run must not name a command"
      refute verified.key?("filename")
      assert_includes verified.fetch("manifest"), "actionpack"
    end
  end

  # A probe that could not be made is not a reproduction either.
  def test_verify_downgrades_a_record_when_the_probe_never_ran
    record = R.for(finding, from_version: "5.0.7.2")
    env = AgentsMiner::RubyEnvs::Env.new(package: "actionpack", version: "5.1.0",
      root: dir("env"), require_path: "actionpack")

    with_stub(RubyEnvs, :probe, ->(_env, _expression, suffix: "") { "TIMEOUT" }) do
      verified = R.verify(record, env: env, ecosystem: "ruby")
      assert_equal false, verified.fetch("verified")
      refute verified.key?("command")
    end
  end

  # The Python side re-runs the reference through the same probe the differential used, and its
  # exception is the leading class of the last line.
  def test_verify_runs_the_python_reference_and_reads_the_leading_class
    record = R.for(finding(ecosystem: "python", library: "httpx", version: "0.28.1",
      module_name: "httpx", expression: "httpx.Client",
      exception: "TypeError: Client.__init__() got an unexpected keyword argument 'proxies'",
      mechanism: "parameter_removed"), from_version: "0.27.2")
    env = AgentsMiner::Envs::Env.new(package: "httpx", version: "0.28.1", root: dir("env"))

    with_stub(Envs, :probe_reference, ->(_env, _module, _expression, suffix: "") {
      "Traceback (most recent call last):\n  File \"call_site.py\", line 3, in <module>\n" \
        "TypeError: Client.__init__() got an unexpected keyword argument 'proxies'\n"
    }) do
      verified = R.verify(record, env: env, ecosystem: "python")
      assert_equal true, verified.fetch("verified")
      assert_equal "TypeError", verified.dig("observed", "exception")
    end
  end
end
