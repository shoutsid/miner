# frozen_string_literal: true

require "pathname"

require_relative "stub_helper"
require_relative "test_helper"

# What a gem upgrade did, decided by executing both releases.
#
# The Ruby differential applies `mine.rb`'s two rules — a rename is the same *words*, a repair is
# only a repair when it was executed — to a surface with owners, so what is tested here is the part
# that is genuinely Ruby-shaped: a reference is the subject, a method whose owner is gone is not its
# own finding, and a keyword is the argument that changes. Everything runs against fake inventories
# and fake probes, because the real ones are `scripts/ruby-client-probe.rb`'s job.
#
# It is the repository's own helper rather than Minitest's `Object#stub` because that one
# lives in `minitest/mock`, which **minitest 6 does not ship at all** — so a suite that used
# it ran in the image (minitest 5.20) and could not even load on a machine whose
# `minitest/autorun` activates 6. A dependency whose presence depends on which minitest a
# machine happens to have is not a seam.
class RubyMineTest < MinerTest
  include StubHelper

  RUBY_MINE = AgentsFyiMiner::RubyMine
  RUBY_ENVS = AgentsFyiMiner::RubyEnvs
  MECHANISM = AgentsFyiMiner::Mechanism

  def entry(name, kind, owner, method_name = "", keywords = [])
    RUBY_ENVS::Entry.new(name: name, kind: kind, owner: owner, method_name: method_name,
      keywords: keywords)
  end

  def inventory(version, entries)
    RUBY_ENVS::Inventory.new(package: "colorize", version: version, entries: entries,
      loaded: true)
  end

  def env(version)
    RUBY_ENVS::Env.new(package: "colorize", version: version,
      root: Pathname.new("/tmp/x"), require_path: "colorize")
  end

  def before_release = @before_release ||= env("0.8.1")
  def after_release = @after_release ||= env("1.0.0")

  # Replace one of the differential's four seams for the length of a block.
  def patched(name, replacement, &block)
    with_stub(RUBY_MINE, name, replacement, &block)
  end

  def test_a_name_the_older_release_resolved_and_the_newer_refuses_is_a_removal
    patched(:inventory, lambda { |environment, suffix: ""|
      inventory(
        environment.version,
        if environment.version == "0.8.1"
          [entry("Colorize::ClassMethods", "constant", "Colorize::ClassMethods")]
        else
          [entry("Colorize", "constant", "Colorize")]
        end
      )
    }) do
      patched(:probe, lambda { |environment, _expression, suffix: ""|
        environment.version == "0.8.1" ? "" : "uninitialized constant Colorize::ClassMethods (NameError)"
      }) do
        patched(:moved, ->(*_args, **_kwargs) { [] }) do
          observations = RUBY_MINE.observations_between(before_release, after_release)

          assert_equal 1, observations.length
          observation = observations[0]
          assert_equal "Colorize::ClassMethods", observation.symbol
          assert_equal "symbol", observation.kind
          assert observation.accepted_before
          refute observation.accepted_after
          assert_nil observation.repair
        end
      end
    end
  end

  def test_a_name_that_is_still_defined_somewhere_else_is_a_move
    # The move is confirmed by running the candidate, because the report says a reference to it
    # resolved and a location found by a scan alone would be a guess with a citation.
    fake_inventory = lambda { |environment, suffix: ""|
      if environment.version == "0.8.1"
        inventory(environment.version, [entry("MyGem::Parser", "constant", "MyGem::Parser"),
                                        entry("MyGem::Parser#parse", "instance", "MyGem::Parser", "parse")])
      else
        inventory(environment.version, [entry("MyGem::Parser", "constant", "MyGem::Parser"),
                                        entry("MyGem::Parsers::Text#parse", "instance", "MyGem::Parsers::Text", "parse")])
      end
    }

    patched(:inventory, fake_inventory) do
      patched(:probe, lambda { |environment, expression, suffix: ""|
        environment.version == "0.8.1" || expression.include?("Parsers") ? "" : "undefined method 'parse' for an instance of MyGem::Parser (NoMethodError)"
      }) do
        patched(:moved, ->(*_args, **_kwargs) { ["MyGem::Parsers::Text#parse"] }) do
          observations = RUBY_MINE.observations_between(before_release, after_release)

          assert_equal ["MyGem::Parser#parse"], observations.map(&:symbol)
          assert_equal "MyGem::Parsers::Text#parse", observations[0].moved
          assert_nil observations[0].repair
        end
      end
    end
  end

  def test_a_method_on_a_class_the_gem_does_not_define_stands_on_its_own
    # A gem that monkeypatches a core class defines nothing on the class itself, so the owner
    # appears in no inventory — and reading that as "the owner is gone" skipped every method on
    # `String`: measured against `colorize` 0.8.1 -> 1.0.0, five removed methods and not one finding.
    patched(:inventory, lambda { |environment, suffix: ""|
      inventory(
        environment.version,
        if environment.version == "0.8.1"
          [entry("String#magenta", "instance", "String", "magenta")]
        else
          [entry("String#purple", "instance", "String", "purple")]
        end
      )
    }) do
      patched(:probe, lambda { |environment, _expression, suffix: ""|
        environment.version == "0.8.1" ? "" : "undefined method `magenta' for an instance of String (NoMethodError)"
      }) do
        patched(:moved, ->(*_args, **_kwargs) { [] }) do
          observations = RUBY_MINE.observations_between(before_release, after_release)

          assert_equal ["String#magenta"], observations.map(&:symbol)
        end
      end
    end
  end

  def test_a_method_whose_owner_is_gone_is_not_its_own_finding
    patched(:inventory, lambda { |environment, suffix: ""|
      inventory(
        environment.version,
        if environment.version == "0.8.1"
          [entry("MyGem::Gone", "constant", "MyGem::Gone"),
           entry("MyGem::Gone#run", "instance", "MyGem::Gone", "run")]
        else
          []
        end
      )
    }) do
      patched(:probe, lambda { |environment, _expression, suffix: ""|
        environment.version == "0.8.1" ? "" : "uninitialized constant MyGem::Gone (NameError)"
      }) do
        patched(:moved, ->(*_args, **_kwargs) { [] }) do
          observations = RUBY_MINE.observations_between(before_release, after_release)

          assert_equal ["MyGem::Gone"], observations.map(&:symbol)
        end
      end
    end
  end

  def test_a_refused_probe_is_not_a_finding
    # The older release refused the name too, so the inventory diff was misleading and there is
    # nothing to report.
    patched(:inventory, lambda { |environment, suffix: ""|
      inventory(
        environment.version,
        environment.version == "0.8.1" ? [entry("Colorize::Gone", "constant", "Colorize::Gone")] : []
      )
    }) do
      patched(:probe, ->(*_args, **_kwargs) { "uninitialized constant Colorize::Gone (NameError)" }) do
        patched(:moved, ->(*_args, **_kwargs) { [] }) do
          assert_empty RUBY_MINE.observations_between(before_release, after_release)
        end
      end
    end
  end

  def test_a_probe_that_could_not_be_made_is_not_evidence
    # `Gem::MissingSpecError` means a dependency was never installed, so the release never answered
    # — reading it as "the name is gone" is a fabricated removal.
    patched(:inventory, lambda { |environment, suffix: ""|
      inventory(
        environment.version,
        environment.version == "0.8.1" ? [entry("Colorize::Gone", "constant", "Colorize::Gone")] : []
      )
    }) do
      patched(:probe, ->(*_args, **_kwargs) {
        "Could not find 'dep' (>= 1) among 3 total gem(s) (Gem::MissingSpecError)"
      }) do
        assert_empty RUBY_MINE.observations_between(before_release, after_release)
      end
    end
  end

  def test_a_renamed_name_is_only_a_rename_when_the_new_name_resolves
    # The rule the corpus paid for: a repair is a name that got past the failure, and a candidate
    # that was refused travels as a candidate.
    #
    # The pair is a name that *gained* a word — `MyGem::Parse` to `MyGem::ParseTask` — which is what
    # the word rule accepts, and not `Colour`/`Color`, which it deliberately does not: two names
    # that share no word are two guesses, however similar they look.
    patched(:inventory, lambda { |environment, suffix: ""|
      inventory(
        environment.version,
        if environment.version == "1.0.0"
          [entry("MyGem::ParseTask", "constant", "MyGem::ParseTask")]
        else
          [entry("MyGem::Parse", "constant", "MyGem::Parse")]
        end
      )
    }) do
      patched(:probe, lambda { |environment, expression, suffix: ""|
        return "" if environment.version == "0.8.1"
        return "" if expression == "MyGem::ParseTask"

        "uninitialized constant MyGem::Parse (NameError)"
      }) do
        patched(:moved, ->(*_args, **_kwargs) { [] }) do
          observations = RUBY_MINE.observations_between(before_release, after_release)

          assert_equal 1, observations.length
          assert_equal "MyGem::ParseTask", observations[0].repair
          assert_nil observations[0].candidate
        end
      end
    end
  end

  def test_a_candidate_the_new_release_refuses_is_recorded_as_a_candidate
    patched(:inventory, lambda { |environment, suffix: ""|
      inventory(
        environment.version,
        if environment.version == "1.0.0"
          [entry("MyGem::ParseTask", "constant", "MyGem::ParseTask")]
        else
          [entry("MyGem::Parse", "constant", "MyGem::Parse")]
        end
      )
    }) do
      # The interpreter names what it could not find, so a refusal that named the wrong constant
      # would be a fake agreeing with itself rather than a release refusing a name.
      patched(:probe, lambda { |environment, expression, suffix: ""|
        environment.version == "1.0.0" ? "uninitialized constant #{expression} (NameError)" : ""
      }) do
        patched(:moved, ->(*_args, **_kwargs) { [] }) do
          observations = RUBY_MINE.observations_between(before_release, after_release)

          assert_nil observations[0].repair
          assert_equal "MyGem::ParseTask", observations[0].candidate
        end
      end
    end
  end

  def test_a_keyword_the_new_signature_refuses_is_a_removed_argument
    patched(:inventory, lambda { |environment, suffix: ""|
      inventory(environment.version, [
                  entry("Colorize::Config#setup", "instance", "Colorize::Config", "setup",
                    environment.version == "0.8.1" ? %w[mode timeout] : %w[mode])
                ])
    }) do
      patched(:probe, ->(*_args, **_kwargs) { "" }) do
        patched(:probe_keyword, lambda { |environment, _expression, keyword, suffix: ""|
          if environment.version == "1.0.0" && keyword == "timeout"
            "unknown keyword: :timeout (ArgumentError)"
          else
            ""
          end
        }) do
          observations = RUBY_MINE.observations_between(before_release, after_release)

          assert_equal 1, observations.length
          assert_equal "timeout", observations[0].parameter
          assert_equal "argument", observations[0].kind
          assert_nil observations[0].repair
        end
      end
    end
  end

  def test_a_keyword_the_new_signature_accepts_under_another_name_is_a_rename
    patched(:inventory, lambda { |environment, suffix: ""|
      inventory(environment.version, [
                  entry("Colorize::Config#setup", "instance", "Colorize::Config", "setup",
                    environment.version == "0.8.1" ? %w[mode timeout] : %w[mode connect_timeout])
                ])
    }) do
      patched(:probe_keyword, lambda { |environment, _expression, keyword, suffix: ""|
        if environment.version == "1.0.0" && keyword == "timeout"
          "unknown keyword: :timeout (ArgumentError)"
        else
          ""
        end
      }) do
        observations = RUBY_MINE.observations_between(before_release, after_release)

        assert_equal "timeout", observations[0].parameter
        assert_equal "connect_timeout", observations[0].repair
      end
    end
  end

  def test_a_gem_that_cannot_be_required_is_recorded_rather_than_read_as_empty
    patched(:inventory, lambda { |environment, suffix: ""|
      RUBY_ENVS::Inventory.new(package: "colorize", version: environment.version, entries: [],
        loaded: false, error: "LoadError: cannot load such file -- colorize")
    }) do
      raised = assert_raises(AgentsFyiMiner::Errors::MinerError) do
        RUBY_MINE.observations_between(before_release, after_release)
      end

      assert_includes raised.message, "could not load colorize 0.8.1"
    end
  end

  def test_a_finding_from_a_gem_is_written_in_ruby_s_words
    patched(:observations_between, ->(*_args, **_kwargs) {
      [AgentsFyiMiner::Observation.new(
        symbol: "String#magenta",
        parameter: "",
        exception: "undefined method 'magenta' for an instance of String (NoMethodError)",
        accepted_before: true,
        accepted_after: false,
        kind: "symbol",
        repair: "String#purple"
      )]
    }) do
      findings = RUBY_MINE.findings_between("colorize", "0.8.1", "1.0.0", before_release, after_release)

      assert_equal 1, findings.length
      finding = findings[0]
      assert_equal "ruby", finding.ecosystem
      assert_equal MECHANISM::SYMBOL_RENAMED, finding.mechanism
      assert_equal "colorize 1.0.0 renamed String#magenta to String#purple", finding.title
      assert_equal "String#magenta", finding.symbol
      assert_includes finding.resolution, "defines"
      refute_includes finding.problem, "colorize.String#magenta"
    end
  end

  def test_a_move_is_not_reported_from_a_probe_that_never_ran
    # `where` returns a destination the report says resolved, so a candidate whose probe never
    # reached the gem must be skipped rather than returned: the refusal phrase is simply absent from
    # "TIMEOUT", and reading that as "it resolved here" names a location nothing ever executed.
    patched(:moved, ->(*_args, **_kwargs) { ["MyGem::Parsers::Text#parse"] }) do
      patched(:probe, ->(*_args, **_kwargs) { "TIMEOUT" }) do
        newer = {
          "MyGem::Parsers::Text#parse" =>
            entry("MyGem::Parsers::Text#parse", "instance", "MyGem::Parsers::Text", "parse")
        }

        assert_nil RUBY_MINE.where(after_release,
          entry("MyGem::Parser#parse", "instance", "MyGem::Parser", "parse"),
          newer, suffix: "")
      end
    end
  end

  def test_a_move_is_reported_only_when_the_candidate_actually_ran
    # The other direction, so the guard above did not turn a real move into a removal: an empty run
    # is the reference resolving, and that is the evidence the report is allowed to name.
    patched(:moved, ->(*_args, **_kwargs) { ["MyGem::Parsers::Text#parse"] }) do
      patched(:probe, ->(*_args, **_kwargs) { "" }) do
        newer = {
          "MyGem::Parsers::Text#parse" =>
            entry("MyGem::Parsers::Text#parse", "instance", "MyGem::Parsers::Text", "parse")
        }

        assert_equal "MyGem::Parsers::Text#parse",
          RUBY_MINE.where(after_release,
            entry("MyGem::Parser#parse", "instance", "MyGem::Parser", "parse"),
            newer, suffix: "")
      end
    end
  end

  def test_a_symbol_replay_that_never_ran_is_not_a_confirmed_repair
    # A repair is only a repair when it was executed. `refused_symbol?` is false for a replay that
    # never ran, and reading that absent refusal as acceptance filed an unexecuted name as the fix —
    # and recording it as a candidate would claim the interpreter refused a name it never saw.
    patched(:inventory, lambda { |environment, suffix: ""|
      inventory(
        environment.version,
        if environment.version == "1.0.0"
          [entry("MyGem::ParseTask", "constant", "MyGem::ParseTask")]
        else
          [entry("MyGem::Parse", "constant", "MyGem::Parse")]
        end
      )
    }) do
      patched(:probe, lambda { |environment, expression, suffix: ""|
        return "" if environment.version == "0.8.1"
        return "TIMEOUT" if expression == "MyGem::ParseTask"

        "uninitialized constant MyGem::Parse (NameError)"
      }) do
        patched(:moved, ->(*_args, **_kwargs) { [] }) do
          observations = RUBY_MINE.observations_between(before_release, after_release)

          assert_equal 1, observations.length
          assert_equal "MyGem::Parse", observations[0].symbol
          assert_nil observations[0].repair
          assert_nil observations[0].candidate
        end
      end
    end
  end

  def test_a_keyword_replay_that_never_ran_is_not_a_confirmed_repair
    # The same guard on the keyword pass, which promotes a candidate the same way: an unrun replay
    # must not become the argument the report offers.
    patched(:inventory, lambda { |environment, suffix: ""|
      inventory(environment.version, [
                  entry("Colorize::Config#setup", "instance", "Colorize::Config", "setup",
                    environment.version == "0.8.1" ? %w[mode timeout] : %w[mode connect_timeout])
                ])
    }) do
      patched(:probe, ->(*_args, **_kwargs) { "" }) do
        patched(:probe_keyword, lambda { |environment, _expression, keyword, suffix: ""|
          if environment.version == "1.0.0" && keyword == "timeout"
            "unknown keyword: :timeout (ArgumentError)"
          elsif keyword == "connect_timeout"
            "TIMEOUT"
          else
            ""
          end
        }) do
          observations = RUBY_MINE.observations_between(before_release, after_release)

          assert_equal 1, observations.length
          assert_equal "timeout", observations[0].parameter
          assert_nil observations[0].repair
          assert_nil observations[0].candidate
        end
      end
    end
  end
end
