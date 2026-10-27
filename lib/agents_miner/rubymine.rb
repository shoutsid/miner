# frozen_string_literal: true

require_relative "errors"
require_relative "findings"
require_relative "mine"
require_relative "rubyenvs"

module AgentsMiner
  # Comparing two gem releases by executing both, and repairing what that finds.
  #
  # What is different is how a Ruby gem describes itself, and there are three differences that
  # change the differential:
  #
  # So the subject of a symbol finding is the *reference* — `Colorize::ClassMethods`,
  # `String#magenta` — which is also what a caller writes. That is the same spelling the API
  # reduces to its last `.`-separated word when a caller asks about a name, so
  # `?symbols=magenta` still finds it.
  #
  # A method is only compared when both releases still define its owner; the constant pass
  # reports the class.
  #
  # **A keyword is the argument that changes.** Ruby's positional arguments are positional, so
  # "the argument at index 2 changed name" is not a question a probe can ask with a
  # placeholder.
  #
  # Everything else is inherited: a probe that could not be made is not evidence, and a name is
  # only reported as gone when the older release ran it and the newer one refused it.
  module RubyMine
    # How many removed names and how many removed keywords one pair's differential will confirm,
    # for the reason the PyPI side states: each candidate costs two Ruby launches, and a major
    # release can drop dozens of names at once. Read from `mine.rb` rather than written again,
    # because the two passes are the same walk over an inventory and one ceiling is what keeps them
    # comparable.
    LIMIT = Mine::SYMBOL_LIMIT

    class << self
      # One release's inventory, or a `MinerError` saying it could not be read.
      #
      # A gem that cannot be required is not a gem that defines nothing, and the error is carried
      # rather than swallowed: the caller records the release as unexaminable, which is a fact about
      # the machine, instead of filing an empty differential as a release that changed nothing.
      def read(env, suffix: "")
        found = inventory(env, suffix: suffix)
        return found if found.loaded?

        raise Errors::MinerError.new(
          "could not load #{env.package} #{env.version}: " \
          "#{found.error.to_s.empty? ? 'no output' : found.error}",
          release: Errors.release_of(env.package, env.version)
        )
      end

      # Every name and every keyword the older release accepted and the newer refuses.
      def observations_between(before, after, limit: LIMIT, suffix: "")
        old_inventory = read(before, suffix: suffix)
        new_inventory = read(after, suffix: suffix)
        older = old_inventory.by_name
        newer = new_inventory.by_name
        symbols(before, after, older, newer, limit: limit, suffix: suffix) +
          keywords(before, after, older, newer, limit: limit, suffix: suffix)
      end

      # Where the new release defines a name of the same leaf, confirmed by running it.
      #
      # The search is the release's own answer — it looks at what is *defined* under the gem's path
      # — and the candidate is then executed, because the report says a reference to it resolved and
      # that has to be true. A location that was merely found by a scan is a guess with a citation,
      # and a candidate whose run did not happen is not even that: it is skipped, because a probe
      # that could not be made is not evidence about anything.
      #
      def where(after, entry, newer, suffix: "")
        moved(after, entry.kind, RubyEnvs.leaf_of(entry.name), suffix: suffix).each do |candidate|
          other = newer[candidate]
          next if other.nil?

          expression = other.expression
          next if expression.nil?

          output = probe(after, expression, suffix: suffix)
          # The probe never reached the gem, so "it did not refuse" is not evidence that this
          # location resolved — and returning it would name a destination no run ever confirmed.
          next unless RubyEnvs.answers?(output)

          return candidate unless RubyEnvs.refused_symbol?(output, candidate)
        end
        nil
      end

      def findings_between(library, from_version, to_version, before, after, suffix: "")
        observations = observations_between(before, after, suffix: suffix)
        found = AgentsMiner.cluster(observations).map do |group|
          AgentsMiner.summarise(library, to_version, from_version, group, ecosystem: "ruby")
        end
        # Stamped with the interpreter the probes actually ran under, because
        # `reporting.payload_for` writes it into the report and this process is not Ruby:
        # without it every gem finding would claim whatever the *client* is written in as its
        # runtime.
        interpreter = RubyEnvs.runtime
        found.map do |finding|
          finding = finding.dup
          finding.runtime = interpreter
          finding
        end
      end

      # The four names the differential reads through, and the reason they are methods here at all.
      #
      # Ruby has no module attribute to overwrite, so these one-line delegations are the seam:
      # the tests replace `RubyMine.inventory` and the walk below reads whichever is
      # installed, while the code under test still names the rule and not the module that
      # implements it.
      #
      # `exception_line` and `traceback_of` have no delegation, deliberately: they read a string the
      # interpreter already produced, nothing about them changes per index, and a seam nothing
      # replaces is one more name to keep in step.
      def inventory(env, suffix: "") = RubyEnvs.inventory(env, suffix: suffix)

      def probe(env, expression, suffix: "")
        RubyEnvs.probe(env, expression, suffix: suffix)
      end

      def probe_keyword(env, expression, keyword, suffix: "")
        RubyEnvs.probe_keyword(env, expression, keyword, suffix: suffix)
      end

      def moved(env, kind, leaf, suffix: "")
        RubyEnvs.moved(env, kind, leaf, suffix: suffix)
      end

      private

      def symbols(before, after, older, newer, limit:, suffix:)
        found = []
        older.each do |name, entry|
          break if found.size >= limit
          next if newer.key?(name)
          # The owner is gone, so the constant pass is already reporting it and every one of its
          # methods with it.
          #
          # `older.key?(entry.owner)` is the half that is easy to miss: a gem that monkeypatches a
          # *core* class — `colorize` adds twenty methods to `String` — has an owner that is not an
          # entry at all, because the gem defines nothing on `String` itself. Read without it, every
          # method on every core class looked like a method whose owner had gone and the whole family
          # was skipped: measured against `colorize` 0.8.1 -> 1.0.0, five removed methods and not one
          # finding.
          if entry.kind != "constant" && older.key?(entry.owner) && !newer.key?(entry.owner)
            next
          end

          expression = entry.expression
          next if expression.nil?

          was = probe(before, expression, suffix: suffix)
          # The older release did not resolve it either, so the inventory diff was misleading and
          # there is nothing to report.
          next if !RubyEnvs.answers?(was) || RubyEnvs.refused_symbol?(was, name)

          now = probe(after, expression, suffix: suffix)
          next if !RubyEnvs.answers?(now) || !RubyEnvs.refused_symbol?(now, name)

          repair = Mine.best_symbol_replacement(name, newer)
          tried = nil
          unless repair.nil?
            # A repair is only a repair when the new release accepted it, which is a weaker
            # statement than "the call works" and exactly the statement the report makes: it got
            # past the failure being reported. A name whose words point at something no reference
            # can reach cannot be executed, so it is dropped rather than filed on its spelling.
            replacement = newer[repair]
            expression_of = replacement&.expression
            if expression_of.nil?
              repair = nil
            else
              replayed = probe(after, expression_of, suffix: suffix)
              if !RubyEnvs.answers?(replayed)
                # The replay never reached the gem, and `refused_symbol?` is false for it — so
                # reading its absent refusal as acceptance filed a name nothing executed as the
                # fix. No evidence is neither a fix nor a refusal, so it is dropped rather than
                # recorded as a candidate the interpreter never refused.
                repair = nil
              elsif RubyEnvs.refused_symbol?(replayed, repair)
                tried = repair
              end
            end
          end
          repair, candidate = Mine.tried_replacement(repair, tried.nil?)

          observation = Observation.new(
            symbol: name,
            parameter: "",
            exception: RubyEnvs.exception_line(now),
            accepted_before: true,
            accepted_after: false,
            repair: repair,
            candidate: candidate,
            traceback: RubyEnvs.traceback_of(now, root: after.root),
            accepted_output: RubyEnvs.traceback_of(was, root: before.root),
            kind: "symbol"
          )
          observation = observation.with(moved: where(after, entry, newer, suffix: suffix)) if repair.nil?
          found << observation
        end
        found
      end

      def keywords(before, after, older, newer, limit:, suffix:)
        found = []
        older.each do |name, entry|
          break if found.size >= limit

          other = newer[name]
          next if other.nil? || other.kind != entry.kind || entry.kind == "constant"

          expression = entry.expression
          next if expression.nil?

          # Sorted and deduplicated, which is what `set(...)` then `sorted(...)` did: the inventory
          # reports a keyword once per parameter it appears in, and a caller reading a report should
          # not see the same argument twice because two signatures lost it.
          (entry.keywords.to_a.uniq - other.keywords.to_a).sort.each do |keyword|
            break if found.size >= limit

            was = probe_keyword(before, expression, keyword, suffix: suffix)
            next if !RubyEnvs.answers?(was) || RubyEnvs.refused_parameter?(was, keyword)

            now = probe_keyword(after, expression, keyword, suffix: suffix)
            next if !RubyEnvs.answers?(now) || !RubyEnvs.refused_parameter?(now, keyword)

            repair = Mine.best_replacement(keyword, { "params" => other.keywords.to_a })
            tried = nil
            unless repair.nil?
              replayed = probe_keyword(after, expression, repair, suffix: suffix)
              if !RubyEnvs.answers?(replayed)
                # See the symbol pass: a replay that never ran is not evidence, so the candidate is
                # dropped rather than promoted to the fix or recorded as a keyword the interpreter
                # never refused.
                repair = nil
              elsif RubyEnvs.refused_parameter?(replayed, repair)
                tried = repair
              end
            end
            repair, candidate = Mine.tried_replacement(repair, tried.nil?)

            found << Observation.new(
              symbol: name,
              parameter: keyword,
              exception: RubyEnvs.exception_line(now),
              accepted_before: true,
              accepted_after: false,
              repair: repair,
              candidate: candidate,
              traceback: RubyEnvs.traceback_of(now, root: after.root),
              accepted_output: RubyEnvs.traceback_of(was, root: before.root)
            )
          end
        end
        found
      end
    end
  end
end
