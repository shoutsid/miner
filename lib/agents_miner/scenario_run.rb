# frozen_string_literal: true

require "json"

require_relative "envs"
require_relative "errors"
require_relative "machine"
require_relative "rubyenvs"

module AgentsMiner
  # **A scenario somebody else wrote, executed as written, with the observation coming from the
  # interpreter rather than from this module's opinion of it.**
  #
  # The corpus stores a scenario as structured steps — two releases, a setup list, a callable and the
  # values it is called with, and a probe — precisely so that no service has to execute a script
  # somebody uploaded. This is the client half of that decision: the steps are read here, turned into
  # a small program for the interpreter the release was installed for, and run against *both*
  # releases in separate environments. What comes back is one line the program prints, and it is the
  # only thing this module believes.
  #
  # Three properties are the whole point, and each is a refusal rather than a check:
  #
  # * **A shape this client cannot build is `unreached`, never a guess.** An argument kind nobody
  #   defined, a setup step that is not an import, a constant that does not resolve — all of them
  #   mean "this release was not asked", which counts for nothing. The alternative is a verdict
  #   derived from a program that never ran the claim.
  # * **A failure to install is `unreached` too.** A release this machine cannot produce says
  #   nothing about the claim, and treating an install failure as a refutation is how a corpus
  #   acquires dissents nobody made.
  # * **The observation is bounded.** A returned value is reduced to a JSON type the probe can
  #   compare, and to `{"__class__": ...}` for anything else, so a run body stays small and a
  #   comparison of two types is not silently a comparison of two strings.
  #
  # The probe is not interpreted here: `Scenario::Probe` on the service reads the two observations
  # and decides `changed`, `reverted` or `unchanged`. This module only has to be honest about what it
  # saw.
  module ScenarioRun
    # The one line the generated program prints that this module reads. Anything else in the output
    # is the interpreter talking to itself — an import traceback, a warning — and is evidence of
    # nothing.
    MARKER = "@@scenario "

    # The bound on a returned value's *description*, not on the value the program computed: a release
    # that returns a megabyte of text is still a returned string, and the probe compares types and
    # the equality of small things.
    RETURNED_CHARS = 200

    # The argument kinds this client builds. A kind added to the corpus has to be added here in the
    # same change, or every scenario using it reads as unexecutable — which is honest, and is a worse
    # answer than executing it.
    ARGUMENT_KINDS = %w[string integer number float boolean null].freeze

    # **This client will not execute a step it does not understand.** Raised while reading the
    # scenario, before an interpreter is started, and its message is what the caller reports: a
    # reader learns which step was the obstacle rather than only that nothing happened.
    class Unreadable < StandardError; end

    # What a scenario turned into: the steps, checked for the shapes this client can build.
    Plan = Data.define(:ecosystem, :library, :from_version, :to_version, :constant, :callable,
      :imports, :constructor, :arguments) do
      def ruby? = ecosystem == "ruby"
    end

    class Plan
      def self.read(scenario)
        values = scenario.is_a?(Hash) ? scenario : {}
        library = values["library"].to_s.strip
        from = values["from_version"].to_s.strip
        to = values["to_version"].to_s.strip
        target = values["target"].is_a?(Hash) ? values["target"] : {}
        constant = (target["constant"] || target["module"]).to_s.strip
        callable = target["callable"].to_s.strip

        raise Unreadable, "a scenario names its library, from_version and to_version" if
          library.empty? || from.empty? || to.empty?
        raise Unreadable, "the scenario names no callable (target.callable)" if callable.empty?

        # A callable with no constant is a module-level function: the library's own module is the
        # scope, and the callable is looked up in it.
        constant = library if constant.empty?

        new(ecosystem: values["ecosystem"].to_s.empty? ? "python" : values["ecosystem"].to_s,
          library: library, from_version: from, to_version: to, constant: constant,
          callable: callable, imports: imports(values["setup"]),
          constructor: arguments(values["call"], "constructor"),
          arguments: arguments(values["call"], "arguments"))
      end

      # The setup steps this client can run. An import is a name to load; anything else — a fixture
      # to write, a server to start — is a step nobody has defined here, and pretending to have run
      # it would be the fabricated evidence this whole path exists to avoid.
      def self.imports(setup)
        Array(setup).filter_map do |step|
          next nil if step.nil?

          kind = (step["kind"] || step["step"]).to_s
          unless kind == "import"
            raise Unreadable, "the scenario asks for setup step #{kind.inspect}, which this " \
                              "client does not run (only \"import\")"
          end

          value = step["value"].to_s.strip.sub(/\A(?:import|require)\s+/, "").strip
          raise Unreadable, "the scenario's import step names nothing to import" if value.empty?

          value
        end
      end

      # The values a call is made with, each one a kind and a value.
      #
      # `null` carries no value and the others require one: an argument whose value is missing is a
      # scenario that could be read two ways, and a client that chose one of them would be running a
      # program nobody wrote.
      def self.arguments(call, field)
        values = call.is_a?(Hash) ? call[field] : nil
        return [] if values.nil?
        raise Unreadable, "the scenario's call.#{field} should be a list" unless values.is_a?(Array)

        values.map do |entry|
          unless entry.is_a?(Hash)
            raise Unreadable, "the scenario's call.#{field} entries should be objects"
          end

          kind = entry["kind"].to_s
          unless ARGUMENT_KINDS.include?(kind)
            raise Unreadable, "the scenario passes an argument of kind #{kind.inspect}, which " \
                              "this client does not build (#{ARGUMENT_KINDS.join(', ')})"
          end
          if !entry.key?("value") && kind != "null"
            raise Unreadable, "the scenario's #{kind} argument has no value"
          end

          { "kind" => kind, "value" => entry["value"] }
        end
      end
    end

    # The steps, or `Unreadable` naming the one that stopped it.
    #
    # Public so a caller can ask "can this machine run that claim?" before spending an install on it:
    # a claim written against another client's vocabulary is a request rather than a build, and a
    # loop that discovered that only inside `execute` would pay for the distinction the wrong way
    # round.
    def self.plan(scenario) = Plan.read(scenario)

    # `body` is what `POST /api/scenarios/{id}/runs` takes. It is the caller's decision whether to
    # send a run whose `result` is `unreached` — the service stores it and counts it for nothing, and
    # a caller that reports one has said something true about this machine.
    def self.execute(scenario, build:, build_gem: nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      plan = Plan.read(scenario)
      builder = plan.ruby? ? build_gem : build
      raise Unreadable, "no builder for the #{plan.ecosystem} index" if builder.nil?

      sides = [plan.from_version, plan.to_version].map do |version|
        [version, run_side(plan, version, build: builder)]
      end
      body(plan, sides, started)
    end

    # One release, one observation.
    def self.run_side(plan, version, build:)
      env = build.call(plan.library, version)
      observation(interpreter_output(plan, env, version), plan: plan, version: version)
    rescue Errors::MinerError => e
      # An install that could not happen, or a probe that did not finish. Named with the release,
      # because "the older one would not build" and "the newer one would not build" are different
      # sentences to a reader deciding whether to try again.
      { "unreached" => "#{plan.library} #{version} could not be executed: #{e.message}" }
    rescue StandardError => e
      { "unreached" => "#{plan.library} #{version} could not be executed: #{e.class}: #{e.message}" }
    end

    # Run the generated program in that release's environment.
    def self.interpreter_output(plan, env, version)
      suffix = suffix_for(plan, version)
      return ruby_output(plan, env, suffix) if plan.ruby?

      script = env.root + "scenario#{suffix}.py"
      script.write(PYTHON_SOURCE, encoding: "utf-8")
      begin
        Envs.probe_output(env.run_script(
          [script.basename.to_s, plan.constant, plan.callable, JSON.generate(plan.constructor),
           JSON.generate(plan.arguments), *plan.imports]
        ))
      ensure
        Envs.drop(script)
      end
    end

    # Ruby's own runner, so the script is written and cleaned up by the module that already owns that
    # file handling for a gem environment.
    def self.ruby_output(plan, env, suffix)
      argv = [plan.constant, plan.callable, JSON.generate(plan.constructor),
              JSON.generate(plan.arguments), *plan.imports]
      RubyEnvs.run_probe(env, RUBY_SOURCE, argv, suffix: "scenario#{suffix}")
    end

    # Named for the release as well as the library, because two sides of one scenario run at the same
    # moment in two environments and a script named for the pair would be one file two workers write.
    def self.suffix_for(plan, version)
      "-#{plan.library}-#{version}".gsub(/[^A-Za-z0-9.-]/, "_")
    end

    # What the program said, reduced to an observation or an unreached reason.
    #
    # The marker line is taken from the *end* of the output: the interpreter prints whatever the
    # release printed before it, and a release that logs on import must not be read as a failure.
    def self.observation(output, plan:, version:)
      line = output.to_s.lines.reverse.find { |candidate| candidate.start_with?(MARKER) }
      if line.nil?
        return { "unreached" => "#{plan.library} #{version} printed no observation " \
                                "(#{output.to_s.strip[0, 300]})" }
      end

      parsed = JSON.parse(line.delete_prefix(MARKER))
      if parsed.key?("unreached")
        return { "unreached" => "#{plan.library} #{version}: #{parsed['unreached']}" }
      end

      parsed.slice("raised", "returned")
    rescue JSON::ParserError => e
      { "unreached" => "#{plan.library} #{version}: unreadable observation (#{e.message[0, 200]})" }
    end

    # Both sides, in the body the service reads.
    #
    # A run reaches only when *both* releases answered. One side `unreached` makes the pair
    # `unreached`, because the probe compares two observations and half a comparison is not a
    # comparison — the service's own rule, and the one that keeps an install failure from becoming a
    # refutation.
    def self.body(plan, sides, started)
      unreached = sides.filter_map { |_version, observation| observation["unreached"] }
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      out = { "duration_ms" => elapsed, "environment" => environment_for(plan) }

      if unreached.empty?
        out["result"] = "reached"
        out["from_output"] = sides[0][1]
        out["to_output"] = sides[1][1]
        out["detail"] = "The verifier executed the scenario's own steps on both releases."
      else
        out["result"] = "unreached"
        out["detail"] = "The scenario could not be executed: #{unreached.join('; ')}"[0, 2_000]
      end
      out
    end

    # The environment is a sentence about this machine, because the service digests it and compares
    # one verifier's run against another's.
    def self.environment_for(plan)
      runtime = plan.ruby? ? RubyEnvs.runtime : Machine.interpreter
      "#{runtime}; #{plan.library} #{plan.from_version} and #{plan.to_version} installed in " \
        "isolation by the verifier"
    end

    # --- the generated programs -----------------------------------------------

    # The Python program: load the imports the scenario asks for, resolve the constant it names,
    # construct the target with the constructor's arguments, call the callable, and print one line.
    #
    # **Setup and the call are two different failures**, and collapsing them is how a verifier
    # reports a claim it never ran: a module that will not import, or a constant that does not exist,
    # is `unreached` — nothing about the releases was asked — while an exception out of the call
    # itself is the observation the probe is looking for.
    #
    # `importlib` rather than `eval`: a scenario's constant is a dotted path, and the longest prefix
    # that imports is the module — `httpx.Client` is the module `httpx` and the attribute `Client`,
    # while `httpx._client.Client` is a deeper module.
    PYTHON_SOURCE = <<~'PYTHON'
      import importlib
      import json
      import sys

      MARKER = "@@scenario "
      RETURNED_CHARS = 200


      def describe(value, depth=0):
          if value is None or isinstance(value, bool):
              return value
          if isinstance(value, int) or isinstance(value, float):
              return value
          if isinstance(value, str):
              return value[:RETURNED_CHARS]
          if depth >= 2:
              return {"__class__": type(value).__name__}
          if isinstance(value, (list, tuple)):
              return [describe(item, depth + 1) for item in list(value)[:50]]
          if isinstance(value, dict):
              return {str(key)[:100]: describe(item, depth + 1)
                      for key, item in list(value.items())[:50]}
          return {"__class__": type(value).__name__}


      def build(entry):
          kind = entry.get("kind")
          if kind == "string":
              return str(entry.get("value"))
          if kind == "integer":
              return int(entry.get("value"))
          if kind in ("number", "float"):
              return float(entry.get("value"))
          if kind == "boolean":
              return entry.get("value") is True
          if kind == "null":
              return None
          raise ValueError("argument kind %r is not one this client builds" % (kind,))


      def resolve(path):
          parts = path.split(".")
          for cut in range(len(parts), 0, -1):
              try:
                  module = importlib.import_module(".".join(parts[:cut]))
              except Exception:
                  continue
              scope = module
              for name in parts[cut:]:
                  scope = getattr(scope, name)
              return scope
          raise ImportError("cannot import %r" % (path,))


      def main(argv):
          constant, callable_name, constructor_json, arguments_json = argv[0:4]
          imports = argv[4:]
          for name in imports:
              importlib.import_module(name)
          ctor = [build(entry) for entry in json.loads(constructor_json)]
          args = [build(entry) for entry in json.loads(arguments_json)]
          scope = resolve(constant)
          return (scope, callable_name, ctor, args)


      try:
          scope, callable_name, ctor, args = main(sys.argv[1:])
      except BaseException as error:
          print(MARKER + json.dumps({"unreached": "%s: %s" % (type(error).__name__, error)}))
          sys.exit(0)

      try:
          target = scope if not ctor else scope(*ctor)
          returned = getattr(target, callable_name)(*args)
      except BaseException as error:
          print(MARKER + json.dumps({"raised": type(error).__name__}))
          sys.exit(0)

      print(MARKER + json.dumps({"returned": describe(returned)}))
    PYTHON

    # The Ruby program, which is the same three steps with Ruby's spelling of them.
    #
    # `const_get(name, false)` rather than `const_get(name)`: a scenario names a constant in the
    # release, and searching the ancestors of `Object` would find a core class of the same name and
    # report a call against something the release never defined. The two failures are kept apart for
    # the reason the Python program keeps them apart — a `LoadError` or an unresolved constant is not
    # the claim being answered.
    RUBY_SOURCE = <<~'RUBY'
      require "json"

      MARKER = "@@scenario "
      RETURNED_CHARS = 200

      def describe(value, depth = 0)
        case value
        when nil, true, false, Integer, Float then value
        when String then value[0, RETURNED_CHARS]
        when Array
          return { "__class__" => "Array" } if depth >= 2

          value.first(50).map { |item| describe(item, depth + 1) }
        when Hash
          return { "__class__" => "Hash" } if depth >= 2

          value.first(50).to_h { |key, item| [key.to_s[0, 100], describe(item, depth + 1)] }
        else
          { "__class__" => value.class.name }
        end
      end

      def build(entry)
        case entry["kind"]
        when "string" then entry["value"].to_s
        when "integer" then Integer(entry["value"])
        when "number", "float" then Float(entry["value"])
        when "boolean" then entry["value"] == true
        when "null" then nil
        else raise ArgumentError, "argument kind #{entry['kind'].inspect} is not one this client builds"
        end
      end

      def resolve(path)
        path.split("::").reject(&:empty?).inject(Object) do |scope, name|
          scope.const_get(name, false)
        end
      end

      constant, callable_name, constructor_json, arguments_json, *imports = ARGV
      begin
        imports.each { |name| require name }
        ctor = JSON.parse(constructor_json).map { |entry| build(entry) }
        args = JSON.parse(arguments_json).map { |entry| build(entry) }
        scope = resolve(constant)
      rescue Exception => error
        puts MARKER + JSON.generate({ "unreached" => "#{error.class}: #{error.message}" })
        exit 0
      end

      begin
        target = ctor.empty? ? scope : scope.new(*ctor)
        returned = target.public_send(callable_name, *args)
      rescue Exception => error
        # The whole name, not the last segment: a report writes what the interpreter printed, and
        # `JSON::ParserError` is not `ParserError` to a probe that compares class names.
        puts MARKER + JSON.generate({ "raised" => error.class.name })
        exit 0
      end

      puts MARKER + JSON.generate({ "returned" => describe(returned) })
    RUBY

    private_class_method :run_side, :interpreter_output, :ruby_output, :suffix_for, :observation,
      :body, :environment_for
  end
end
