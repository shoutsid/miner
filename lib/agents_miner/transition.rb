# frozen_string_literal: true

require "json"
require "time"

require_relative "envs"
require_relative "errors"

module AgentsMiner
  # **A service, platform or agent transition, executed as declared and recorded as examinations.**
  #
  # The corpus's examination object is not about gems. It is one executed transition, in one
  # environment, with a four-valued outcome, and the plan's non-gem shape is the same object with a
  # different `check_kind` set: a service move is examined by deploying it, asking whether it is
  # healthy, and running the contract somebody already wrote. This is the client half of that
  # shape — it reads a declaration, runs the commands the declaration names, and hands the result
  # to `POST /api/releases/examinations` through `Corpus#record_examinations`.
  #
  # **It runs nothing it was not told to run.** A service deploy is somebody's release process, not
  # a convention this file can guess, so every command lives in the declaration. What this module
  # owns is the judgement the corpus stores: whether a command ran and exited as declared
  # (`clean`), ran and did not (`findings`), or never ran at all (`unexaminable`).
  #
  # The declaration is a JSON object, and every field it may carry is in `FIELDS`:
  #
  #   {
  #     "subject_kind": "service",          // service, platform or agent (package is the gems' own)
  #     "ecosystem": "ruby",                // the language the thing is written in; the schema has two
  #     "library": "checkout-api",
  #     "from_version": "2.1.0",
  #     "to_version": "2.2.0",
  #     "interpreter": "ruby 3.3.12",       // optional
  #     "framework": "rails 7.1",           // optional
  #     "machine": "the deploy host",       // optional
  #     "environment": { "RAILS_ENV": "production" },
  #     "checks": [
  #       { "kind": "deploy",   "command": ["bin/deploy", "2.2.0"] },
  #       { "kind": "health",   "command": ["curl", "-fsS", "http://localhost:3000/up"] },
  #       { "kind": "contract", "command": ["bundle", "exec", "rspec", "spec/contracts"] }
  #     ]
  #   }
  #
  # A check may name `cwd`, `timeout` (seconds), `name` and `expect_exit` (0 by default). The
  # environment is *structured* — names to values — because that is what the reader stores; the
  # child inherits this process's environment unless the declaration names one, which is what a
  # deploy script already expects.
  module Transition
    # The three checks the schema declares for a non-gem subject. `differential`, `resolve`,
    # `install`, `load`, `boot` and `scenario` are the gem miner's, and a transition that sent one
    # of those would be answering a different question in the same field.
    CHECKS = %w[deploy health contract].freeze
    # Every subject the schema declares. `package` is accepted rather than refused because the
    # object is general, but this client's declaration is for the three the gem miner does not
    # work; see `DEFAULT_SUBJECT_KIND`.
    SUBJECT_KINDS = %w[package service platform agent].freeze
    DEFAULT_SUBJECT_KIND = "service"
    # `EcosystemColumn::VALUES` in the service, and deliberately two: a value the schema does not
    # declare is a 422 the miner would read as a corpus outage.
    ECOSYSTEMS = %w[python ruby].freeze
    DEFAULT_ECOSYSTEM = "ruby"
    # What the service's `Examination::Body` bounds an environment value to, and how much of a
    # command's output the evidence keeps.
    TAIL = 2_000

    class Invalid < StandardError; end

    # One command the declaration asked for.
    Check = Data.define(:kind, :command, :cwd, :timeout, :name, :expect_exit)

    # A validated declaration, ready to run.
    Plan = Data.define(
      :subject_kind, :ecosystem, :library, :from_version, :to_version,
      :interpreter, :framework, :machine, :environment, :checks
    )

    class << self
      # Read and validate a declaration file. Raises `Invalid` with the field a person has to fix,
      # because a declaration is hand-written and a stack trace is not an answer about JSON.
      def read(path)
        parse(JSON.parse(File.read(path)))
      rescue SystemCallError => e
        raise Invalid, "the declaration at #{path} could not be read (#{e.message})"
      rescue JSON::ParserError => e
        raise Invalid, "the declaration at #{path} is not JSON (#{e.message})"
      end

      def parse(raw)
        raise Invalid, "the declaration must be a JSON object" unless raw.is_a?(Hash)

        subject_kind = raw.fetch("subject_kind", DEFAULT_SUBJECT_KIND).to_s
        unless SUBJECT_KINDS.include?(subject_kind)
          raise Invalid, "subject_kind #{subject_kind.inspect} is not one of #{SUBJECT_KINDS.join(', ')}"
        end

        ecosystem = raw.fetch("ecosystem", DEFAULT_ECOSYSTEM).to_s
        unless ECOSYSTEMS.include?(ecosystem)
          raise Invalid, "ecosystem #{ecosystem.inspect} is not one of #{ECOSYSTEMS.join(', ')}: " \
                         "the schema declares only those two"
        end

        library = required(raw, "library")
        from_version = required(raw, "from_version")
        to_version = required(raw, "to_version")
        environment = raw["environment"] || {}
        unless environment.is_a?(Hash)
          raise Invalid, "environment must be an object of names to values"
        end

        raw_checks = raw["checks"]
        unless raw_checks.is_a?(Array) && !raw_checks.empty?
          raise Invalid, "checks must be a non-empty list of deploy, health or contract commands"
        end

        Plan.new(
          subject_kind: subject_kind, ecosystem: ecosystem, library: library,
          from_version: from_version, to_version: to_version,
          interpreter: optional(raw, "interpreter"), framework: optional(raw, "framework"),
          machine: optional(raw, "machine"),
          environment: environment.transform_keys(&:to_s),
          checks: raw_checks.each_with_index.map { |check, index| check_at(check, index) }
        )
      end

      # Run every declared check and build one examination cell per check.
      #
      # `runner` is `Envs.run_captured` by default and is the one seam a test replaces: a test must
      # not deploy a service to prove the judgement about an exit code.
      def cells(plan, runner: Envs.method(:run_captured), now: Time.now)
        plan.checks.map { |check| cell(plan, check, runner: runner, now: now) }
      end

      private

      def cell(plan, check, runner:, now:)
        evidence, outcome, findings = execute(check, runner)
        {
          "ecosystem" => plan.ecosystem,
          "subject_kind" => plan.subject_kind,
          "library" => plan.library,
          "from_version" => plan.from_version,
          "to_version" => plan.to_version,
          "check_kind" => check.kind,
          "outcome" => outcome,
          "interpreter" => plan.interpreter,
          "framework" => plan.framework,
          "environment" => plan.environment,
          "checks" => [{
            "name" => check.name || check.kind,
            "status" => outcome,
            "detail" => evidence["detail"] || evidence["output_tail"].to_s[0, 200]
          }],
          "finding_count" => findings,
          "report_ids" => [],
          "evidence" => evidence,
          "machine" => plan.machine,
          "examined_at" => now.utc.iso8601
        }.reject { |_key, value| value.nil? }
      end

      # The judgement, and the evidence it was made from. Three answers rather than two: a command
      # that could not start measured nothing about the transition, which is `unexaminable` and not
      # a finding about the release.
      def execute(check, runner)
        result = runner.call(check.command, cwd: check.cwd, timeout: check.timeout, env: nil)
        code = result.status.to_i
        clean = code == check.expect_exit
        [
          { "command" => check.command.join(" "), "exit_code" => code,
            "output_tail" => tail(result.stdout.to_s + result.stderr.to_s) },
          clean ? "clean" : "findings",
          clean ? 0 : 1
        ]
      rescue Envs::TimedOut => e
        detail = if e.started?
          "the command ran past its #{check.timeout}s deadline"
        else
          "the command could not be started (#{e.message})"
        end
        [
          { "command" => check.command.join(" "), "exit_code" => nil,
            "output_tail" => tail(e.stdout.to_s + e.stderr.to_s), "detail" => detail },
          "unexaminable", 0
        ]
      rescue SystemCallError => e
        [
          { "command" => check.command.join(" "), "exit_code" => nil, "output_tail" => "",
            "detail" => "the command could not be started (#{e.message})" },
          "unexaminable", 0
        ]
      end

      def check_at(raw, index)
        raise Invalid, "checks[#{index}] must be an object" unless raw.is_a?(Hash)

        kind = raw["kind"].to_s
        unless CHECKS.include?(kind)
          raise Invalid, "checks[#{index}].kind #{kind.inspect} is not one of #{CHECKS.join(', ')}"
        end

        command = raw["command"]
        unless command.is_a?(Array) && !command.empty? &&
            command.all? { |part| part.is_a?(String) && !part.empty? }
          raise Invalid, "checks[#{index}].command must be a non-empty list of non-empty strings"
        end

        Check.new(
          kind: kind, command: command, cwd: optional(raw, "cwd"),
          timeout: raw["timeout"].nil? ? Envs::RUN_TIMEOUT : Float(raw["timeout"]),
          name: optional(raw, "name"),
          expect_exit: Integer(raw.fetch("expect_exit", 0))
        )
      rescue ArgumentError, TypeError => e
        raise Invalid, "checks[#{index}] is malformed (#{e.message})"
      end

      def required(raw, field)
        value = raw[field].to_s.strip
        raise Invalid, "#{field} is required and must not be blank" if value.empty?

        value
      end

      def optional(raw, field)
        value = raw[field].to_s.strip
        value.empty? ? nil : value
      end

      def tail(text)
        text = text.to_s
        text.length > TAIL ? text[-TAIL..] : text
      end
    end
  end
end
