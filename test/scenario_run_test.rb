# frozen_string_literal: true

require_relative "test_helper"

# Executing somebody else's scenario as written.
#
# The thing this file is really holding is the difference between "the two releases were asked and
# answered" and "this machine could not ask". The first is evidence the service turns into a
# verification; the second counts for nothing, and a verifier that confused them would confirm or
# contradict claims it never ran.
#
# The Python program is driven through a fake environment that returns the line an interpreter
# would have printed — the parsing and the body assembly are what this side decides. The Ruby
# program is executed for real against the standard library, because it needs no network and a
# template that has never run is a template nobody knows works.
class ScenarioRunTest < MinerTest
  S = AgentsMiner::ScenarioRun

  # A built environment, with the interpreter replaced by a canned answer.
  class FakeEnv
    attr_reader :root

    def initialize(root, output)
      @root = root
      @output = output
    end

    def run_script(_argv, timeout: nil)
      Struct.new(:status, :stdout, :stderr).new(0, @output, "")
    end
  end

  def scenario(**overrides)
    {
      "id" => "s-1",
      "ecosystem" => "python",
      "library" => "httpx",
      "from_version" => "0.27.2",
      "to_version" => "0.28.1",
      "target" => { "constant" => "httpx.Client", "callable" => "stream" },
      "setup" => [{ "kind" => "import", "value" => "import httpx" }],
      "call" => { "arguments" => [{ "kind" => "string", "value" => "url" }], "constructor" => [] },
      "probe" => { "relation" => "raises_class", "expected" => "TypeError" }
    }.merge(overrides.transform_keys(&:to_s))
  end

  def build_for(outputs)
    seen = []
    builder = lambda do |library, version|
      seen << [library, version]
      root = @home + "#{library}-#{version}"
      # A built environment's directory exists before a script is written into it, which is what
      # `Envs.build` guarantees and what the fake has to model.
      FileUtils.mkdir_p(root)
      FakeEnv.new(root, outputs.fetch(version))
    end
    [builder, seen]
  end

  # **The test host runs under Bundler and the miner image does not.** A child interpreter inherits
  # `BUNDLE_GEMFILE` and resolves the root bundle instead of the gem environment it was handed — a
  # fact about this machine rather than about the executor, which is why the two Ruby tests scrub
  # those variables for the duration and put them back.
  def without_bundler
    # Every `BUNDLE*`/`BUNDLER*` variable, including the `BUNDLER_ORIG_*` pair: `bundle exec`
    # restores the ones it removed in any child that loads bundler, so deleting only the two it
    # sets is a scrub the child undoes.
    names = (ENV.keys.grep(/\ABUNDLE/) + %w[RUBYLIB RUBYOPT RUBYGEMS_GEMDEPS]).uniq
    saved = names.to_h { |name| [name, ENV[name]] }
    names.each { |name| ENV.delete(name) }
    yield
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def test_both_releases_answering_is_a_reached_run_with_what_each_saw
    builder, seen = build_for(
      "0.27.2" => "@@scenario {\"returned\": \"ok\"}\n",
      "0.28.1" => "@@scenario {\"raised\": \"TypeError\"}\n"
    )

    body = S.execute(scenario, build: builder)

    assert_equal "reached", body["result"]
    assert_equal({ "returned" => "ok" }, body["from_output"])
    assert_equal({ "raised" => "TypeError" }, body["to_output"])
    assert_equal [["httpx", "0.27.2"], ["httpx", "0.28.1"]], seen
    assert_includes body["environment"], "httpx 0.27.2 and 0.28.1"
    assert body["duration_ms"] >= 0
  end

  # **The line is taken from the end.** A release that prints while it is imported — a deprecation
  # warning, a banner — must not be read as a failure of the claim.
  def test_an_observation_is_found_below_whatever_the_release_printed
    builder, = build_for(
      "0.27.2" => "welcome to httpx\n@@scenario {\"returned\": \"ok\"}\n",
      "0.28.1" => "@@scenario {\"raised\": \"TypeError\"}\n"
    )

    body = S.execute(scenario, build: builder)

    assert_equal "reached", body["result"]
    assert_equal({ "returned" => "ok" }, body["from_output"])
  end

  # A release that could not be installed is not a refutation, and the run says which side it was.
  def test_a_release_that_cannot_be_built_makes_the_pair_unreached
    builder = lambda do |_library, version|
      raise AgentsMiner::Errors::MinerError.new("pip could not install it", permanent: true,
        release: "httpx #{version}") if version == "0.28.1"

      FakeEnv.new(@home + "httpx-#{version}", "@@scenario {\"returned\": \"ok\"}\n")
    end

    body = S.execute(scenario, build: builder)

    assert_equal "unreached", body["result"]
    assert_includes body["detail"], "0.28.1"
    refute body.key?("from_output"), "an unreached run carries no comparison"
  end

  # Half a comparison is not a comparison: one side answering is not a run.
  def test_a_side_that_printed_no_observation_makes_the_pair_unreached
    builder, = build_for(
      "0.27.2" => "@@scenario {\"returned\": \"ok\"}\n",
      "0.28.1" => "Traceback (most recent call last):\nModuleNotFoundError: no httpx\n"
    )

    body = S.execute(scenario, build: builder)

    assert_equal "unreached", body["result"]
    assert_includes body["detail"], "no observation"
  end

  # **A step this client does not run is refused before anything is installed**, with the step named:
  # a verifier that guessed at a fixture would be reporting on a program nobody wrote.
  def test_a_setup_step_that_is_not_an_import_is_refused_by_name
    error = assert_raises(S::Unreadable) do
      S.execute(scenario("setup" => [{ "kind" => "fixture", "value" => "a.csv" }]),
        build: ->(_library, _version) { raise "must not be built" })
    end

    assert_includes error.message, "\"fixture\""
  end

  def test_an_argument_kind_this_client_does_not_build_is_refused
    error = assert_raises(S::Unreadable) do
      S.execute(scenario("call" => { "arguments" => [{ "kind" => "object", "value" => {} }] }),
        build: ->(_library, _version) { raise "must not be built" })
    end

    assert_includes error.message, "\"object\""
  end

  def test_a_scenario_without_a_release_pair_is_refused
    error = assert_raises(S::Unreadable) { S.execute(scenario("to_version" => ""), build: nil) }

    assert_includes error.message, "from_version"
  end

  # The Ruby program, run for real against the standard library: a callable that returns a value on
  # both sides, and one that raises. No network and no gem install, so this can assert the template.
  def test_the_ruby_program_returns_an_observation_from_a_real_interpreter
    ruby_scenario = scenario(
      "ecosystem" => "ruby", "library" => "json", "from_version" => "2.7.0",
      "to_version" => "2.8.0",
      "target" => { "constant" => "JSON", "callable" => "generate" },
      "setup" => [{ "kind" => "import", "value" => "require json" }],
      "call" => { "arguments" => [{ "kind" => "string", "value" => "{}" }], "constructor" => [] }
    )
    builder = lambda do |_library, version|
      root = @home + "ruby-#{version}"
      FileUtils.mkdir_p(root)
      Struct.new(:root).new(root)
    end

    body = without_bundler { S.execute(ruby_scenario, build: nil, build_gem: builder) }

    assert_equal "reached", body["result"], body["detail"]
    # `JSON.generate` returns the *text* it produced, quotes included — the observation is the
    # release's own answer, not this client's reading of it.
    assert_equal({ "returned" => "\"{}\"" }, body["from_output"])
    assert_equal({ "returned" => "\"{}\"" }, body["to_output"])
  end

  def test_the_ruby_program_reports_a_class_the_call_raised
    ruby_scenario = scenario(
      "ecosystem" => "ruby", "library" => "json", "from_version" => "2.7.0",
      "to_version" => "2.8.0",
      "target" => { "constant" => "JSON", "callable" => "parse" },
      "setup" => [{ "kind" => "import", "value" => "require json" }],
      "call" => { "arguments" => [{ "kind" => "string", "value" => "not json" }] }
    )
    builder = lambda do |_library, version|
      root = @home + "raise-#{version}"
      FileUtils.mkdir_p(root)
      Struct.new(:root).new(root)
    end

    body = without_bundler { S.execute(ruby_scenario, build: nil, build_gem: builder) }

    assert_equal "reached", body["result"], body["detail"]
    # The whole name, because that is what a report quotes and what `raises_class` compares.
    assert_equal({ "raised" => "JSON::ParserError" }, body["to_output"])
  end

  # A constant the release does not define is setup, not an answer: `raises_class` must not be
  # satisfied by a `NameError` from resolving the name the scenario asked for.
  def test_a_constant_the_release_does_not_define_is_unreached_not_raised
    ruby_scenario = scenario(
      "ecosystem" => "ruby", "library" => "json", "from_version" => "2.7.0",
      "to_version" => "2.8.0",
      "target" => { "constant" => "Jsonn", "callable" => "generate" },
      "setup" => [{ "kind" => "import", "value" => "require json" }],
      "call" => { "arguments" => [] }
    )
    builder = lambda do |_library, version|
      root = @home + "missing-#{version}"
      FileUtils.mkdir_p(root)
      Struct.new(:root).new(root)
    end

    body = without_bundler { S.execute(ruby_scenario, build: nil, build_gem: builder) }

    assert_equal "unreached", body["result"]
    assert_includes body["detail"], "Jsonn"
  end
end
