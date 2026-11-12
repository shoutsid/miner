# frozen_string_literal: true

require "pathname"

require_relative "reporting"

module AgentsMiner
  # **The same comparison, written out so somebody else can run it.**
  #
  # A report is a claim that two releases were executed and the newer one refused the call. That
  # claim is checkable only if a reader can run it too, and the corpus's answer until now was
  # "install the release and try" — which is the work the miner already did, described nowhere.
  #
  # This builds the *record* of that execution: the release, the reference the probe executed, the
  # script that makes it, and the exception the newer release raised. When the finding carries the
  # probe expression — a symbol or argument pass, which executes a reference — the record is
  # **runnable**: it names a command and a script. A behaviour comparison reads a value and calls
  # nothing, so it gets the description form (no command) instead of a script that would not run.
  #
  # **`verify` is what makes `runnable` mean something.** `for` emits `verified: false`; the caller
  # that holds the release's environment runs the comparison once more in it and compares the
  # exception to the one recorded. A reproduction the miner could not run is downgraded to the
  # description form, because a command nobody executed is a claim dressed as one.
  module Reproduction
    FORMAT = 1

    class << self
      # Nil when the finding names no two releases to reproduce between: a reproduction of nothing is
      # not a reproduction, and the cell simply carries none.
      def for(finding, from_version:)
        return nil if finding.library.to_s.empty? || finding.version.to_s.empty?
        return nil if from_version.to_s.empty?

        ruby = finding.ecosystem.to_s == "ruby"
        expression = finding.expression.to_s
        record = {
          "format" => FORMAT,
          "language" => ruby ? "ruby" : "python",
          "ecosystem" => finding.ecosystem,
          "library" => finding.library,
          "from_version" => from_version.to_s,
          "to_version" => finding.version.to_s,
          "runtime" => Reporting.runtime_of(finding),
          "manifest" => manifest_for(finding),
          "script" => script_for(finding, expression),
          "expected" => expected_for(finding),
          # **A runnable record names the command and the file; a description names neither.** The
          # distinction is the read's `status`, and it is made here rather than by the reader
          # guessing: a script with no command is a comparison nobody can run.
          "command" => expression.empty? ? nil : command_for(finding),
          "filename" => expression.empty? ? nil : filename_for(finding),
          # The probe's own text, kept so `verify` can re-run the comparison through the same
          # `RubyEnvs.probe` the differential used — the require path is the environment's, not a
          # guess from the distribution name.
          "expression" => expression.empty? ? nil : expression,
          "verified" => false
        }
        record.reject { |_key, value| value.nil? || value == "" }
      end

      # **Run the comparison once more in the release's own environment and compare what it raises.**
      #
      # This is the difference between a reproduction and a description: the reference is executed
      # again, exactly as the differential executed it, and the exception class it produces is
      # compared with the one recorded. A mismatch, a script that ran clean, or a probe that could
      # not be made leaves the record a description — never a claim.
      #
      # Returns the record with `verified` and `observed` set, and with `command`/`filename` dropped
      # when the comparison did not reproduce. `env` is the environment the finding was established
      # in, so this re-runs the same comparison rather than re-deriving it from another install.
      def verify(record, env:, ecosystem: "ruby")
        expected = record.dig("expected", "exception").to_s
        expression = record["expression"].to_s
        return unverified(record) if expected.empty? || expression.empty?

        output = run(env, record, ecosystem)
        observed = observed_class(output, ecosystem)
        return unverified(record.merge("observed" => { "exception" => observed,
                                                       "output" => output.to_s[0, 2_000] })) unless observed == expected

        record.merge("verified" => true,
          "observed" => { "exception" => observed, "output" => output.to_s[0, 2_000] })
      end

      private

      # A record that did not reproduce: the description form, with what was seen kept beside it so a
      # reader can tell a script that ran clean from one that raised something else.
      def unverified(record)
        record.reject { |key, _value| %w[command filename].include?(key) }
              .merge("verified" => false)
      end

      def run(env, record, ecosystem)
        if ecosystem.to_s == "ruby"
          RubyEnvs.probe(env, record["expression"].to_s, suffix: "repro")
        else
          module_name = record["library"].to_s
          Envs.probe_reference(env, module_name, record["expression"].to_s, suffix: "repro")
        end
      rescue StandardError
        ""
      end

      # The exception's class, in the shape the two interpreters print it. The rule is
      # `Reporting.exception_class`'s, applied to output rather than to the finding's stored
      # sentence — one rule, so the two cannot disagree about how a class is spelled.
      def observed_class(output, ecosystem)
        text = output.to_s.strip
        return "" if text.empty?

        line = text.lines.reverse.find { |candidate| candidate.match?(/\S/) }.to_s.strip
        return line[/\(([A-Za-z0-9_:]+)\)\z/, 1].to_s if ecosystem.to_s == "ruby"

        line[/\A([A-Za-z_][A-Za-z0-9_.]*)(?::|\z)/, 1].to_s
      end

      # The manifest that installs the release the call refused on. A gem gets a Gemfile; anything
      # else gets the requirement line its index would read.
      def manifest_for(finding)
        if finding.ecosystem.to_s == "ruby"
          %(source "https://rubygems.org"\ngem "#{finding.library}", "#{finding.version}"\n)
        else
          "#{finding.library}==#{finding.version}\n"
        end
      end

      def filename_for(finding)
        finding.ecosystem.to_s == "ruby" ? "repro.rb" : "repro.py"
      end

      # The command a reader runs, from the manifest and the script beside it.
      def command_for(finding)
        if finding.ecosystem.to_s == "ruby"
          "bundle install && ruby #{filename_for(finding)}"
        else
          "pip install -r requirements.txt && python #{filename_for(finding)}"
        end
      end

      # What the script does: load the release and execute the reference the probe executed. The
      # expression is the interpreter's own text (`Colorize::ClassMethods#magenta`), so this is the
      # comparison itself rather than a description of one.
      def script_for(finding, expression)
        return "" if expression.empty?

        require_path = finding.module_name.to_s.empty? ? finding.library : finding.module_name
        if finding.ecosystem.to_s == "ruby"
          %(require "#{require_path}"\n#{expression}\n)
        else
          %(import #{require_path}\n#{expression}\n)
        end
      end

      # What the newer release did, in the two facts a reader compares against: the exception's class
      # and the interpreter's own sentence.
      def expected_for(finding)
        klass = Reporting.exception_class(finding)
        return nil if klass.empty?

        { "exception" => klass, "message" => finding.exception.to_s.strip[0, 2_000] }
      end
    end
  end
end
