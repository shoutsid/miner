# frozen_string_literal: true

require "pathname"

require_relative "stub_helper"
require_relative "test_helper"

# The differential itself: what is confirmed by execution, and what is refused.
#
# Nothing installs a release and nothing launches an interpreter, which is what makes these
# tests runnable anywhere.
#
class MineTest < MinerTest
  include StubHelper

  M = AgentsMiner::Mine

  BEFORE = AgentsMiner::Envs::Env.new(package: "numpy", version: "1.26.4",
    root: Pathname.new("/before"))
  AFTER = AgentsMiner::Envs::Env.new(package: "numpy", version: "2.0.0",
    root: Pathname.new("/after"))

  # The two strings `envs.probe`/`probe_symbol` return when the release never got to answer for
  # itself. They are literals here because they are literals there, and a fixture that stopped
  # carrying the marker would fail these tests rather than make them vacuous: `Envs.answers?` would
  # read the stand-in as a clean run.
  CLEAN = ""
  TIMEOUT_OUTPUT = "TIMEOUT"
  KILLED = "KILLED BY SIGNAL SIGKILL"

  def test_the_differential_accepts_the_workers_own_script_name
    # `findings_between` is called by the service with a `suffix` that keeps two workers examining
    # one release from overwriting each other's scratch script.
    #
    # This asserts the *call*, not the callee, and it exists because the suffix was threaded
    # through `observations_between` while `findings_between` kept its old signature: every unit
    # test below passed, and the live service answered
    # `TypeError: findings_between() got an unexpected keyword argument 'suffix'` for every pair in
    # its first parallel cycle. A keyword that exists on the inner function and not on the one the
    # service calls is invisible to tests that call the inner one.
    inventory = ->(_env, **_kwargs) { AgentsMiner::Envs::Inventory.new(module: "numpy", entries: []) }

    with_stub(M, :inventory_for, inventory) do
      assert_equal [], M.findings_between("numpy", "1.26.4", "2.0.0", BEFORE, AFTER, suffix: "-x")
    end
  end

  def test_the_workers_script_name_reaches_every_probe
    # The traceback filed as a report's evidence is the interpreter's own output from the run that
    # raised it, so a probe whose file another worker overwrote files the wrong call — a fabricated
    # finding with a real citation. That only holds if the suffix gets from `findings_between` all
    # the way down to the probes, which is a chain of keywords and therefore easy to break in the
    # middle.
    suffixes = []
    entries = lambda do |env, **_kwargs|
      params = env.version == "1.26.4" ? { "legacy" => { "required" => false } } : {}
      AgentsMiner::Envs::Inventory.new(
        module: "numpy", entries: [{ "name" => "obj", "kind" => "class", "params" => params }]
      )
    end
    recording = lambda do |env, _module_name, _symbol, parameter, **_kwargs|
      suffixes << _kwargs.fetch(:suffix, "")
      # Old release takes it, new one refuses it: enough for one observation.
      env.version == "1.26.4" ? CLEAN : "unexpected keyword argument '#{parameter}'"
    end

    with_stubs(M, inventory_for: entries, probe: recording,
      probe_symbol: ->(_env, _module_name, _name, **_kwargs) { CLEAN }) do
      findings = M.findings_between("numpy", "1.26.4", "2.0.0", BEFORE, AFTER, suffix: "-worker7")

      refute_empty findings, "the fixture should produce one finding"
      refute_empty suffixes, "the probes should have been called"
      assert_equal ["-worker7"], suffixes.uniq
    end
  end

  def test_every_probe_imports_the_resolved_module_not_the_distribution
    # The differential must carry the *import* name the environment resolved, not the distribution
    # name it was given: `import pyyaml` fails before any argument is bound, so a probe built from
    # the distribution name reports a break in a module nobody can import — for every package whose
    # two names differ.
    seen = []
    entries = lambda do |env, **_kwargs|
      params = env.version == "1.26.4" ? { "typ" => { "required" => false } } : {}
      AgentsMiner::Envs::Inventory.new(
        module: "yaml",
        entries: [{ "name" => "safe_load", "kind" => "function", "params" => params }]
      )
    end
    recording = lambda do |env, module_name, _symbol, parameter, **_kwargs|
      seen << module_name
      env.version == "1.26.4" ? CLEAN : "unexpected keyword argument '#{parameter}'"
    end

    with_stubs(M, inventory_for: entries, probe: recording,
      probe_symbol: ->(_env, _module_name, _name, **_kwargs) { CLEAN }) do
      assert M.findings_between("pyyaml", "1.26.4", "2.0.0", BEFORE, AFTER)
    end

    assert_equal ["yaml"], seen.uniq
  end

  # A `probe_symbol` whose answers are declared per (version, name), and a `moved` whose places are
  # declared per name.
  #
  # The message is generated from the name rather than written into the test, because a refusal
  # that names the wrong attribute is the exact bug `Envs.refused_symbol?` exists to catch.
  #
  def with_probes(answers, places: {})
    calls = []
    probe = lambda do |env, _module_name, name, **_kwargs|
      case answers.fetch([env.version, name])
      when "missing" then missing(name)
      when "timeout" then TIMEOUT_OUTPUT
      when "killed" then KILLED
      else CLEAN
      end
    end
    moved = lambda do |env, module_name, names, **kwargs|
      calls << [env.version, module_name, names, kwargs.fetch(:suffix, "")]
      places.select { |name, _| names.include?(name) }
    end

    with_stubs(M, probe_symbol: probe, moved: moved) { yield calls }
  end

  # What the interpreter says when a public name is not there.
  def missing(name) = "AttributeError: module 'numpy' has no attribute '#{name}'\n"

  def entry(kind: "class", params: nil) = { "name" => "float_", "kind" => kind, "params" => params }

  def test_a_name_the_older_release_exported_and_the_newer_does_not_is_a_break
    with_probes({ ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "missing" }) do
      found = M.symbols_between(BEFORE, AFTER, "numpy", { "float_" => entry }, {})

      assert_equal ["float_"], found.map(&:symbol)
      assert_equal "symbol", found[0].kind
      assert_equal "", found[0].parameter
      assert found[0].accepted_before
      refute found[0].accepted_after
    end
  end

  def test_a_name_the_older_release_also_refused_was_never_exported
    # The same standard the argument pass holds: a name that was not there to begin with did not go
    # anywhere.
    with_probes({ ["1.26.4", "float_"] => "missing", ["2.0.0", "float_"] => "missing" }) do
      assert_equal [], M.symbols_between(BEFORE, AFTER, "numpy", { "float_" => entry }, {})
    end
  end

  def test_a_name_the_newer_release_still_exports_did_not_go_anywhere
    with_probes({ ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "clean" }) do
      assert_equal [], M.symbols_between(BEFORE, AFTER, "numpy", { "float_" => entry }, {})
    end
  end

  def test_a_rename_is_confirmed_by_resolving_the_new_name
    with_probes({ ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "missing",
                  ["2.0.0", "float64"] => "clean" }) do
      found = M.symbols_between(BEFORE, AFTER, "numpy", { "float_" => entry },
        { "float64" => entry })

      assert_equal "float64", found[0].repair
      assert_nil found[0].candidate
    end
  end

  def test_a_close_name_that_also_raises_is_recorded_as_a_refusal_not_a_repair
    # `float_` to `float64` is a rename; a name that fails too is not, and saying otherwise would
    # hand a caller an import that does not work either. It is kept as a *refusal* rather than
    # discarded, because "the obvious name was executed and is broken too" is the sentence that
    # stops a reader trying it.
    with_probes({ ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "missing",
                  ["2.0.0", "float64"] => "missing" }) do
      found = M.symbols_between(BEFORE, AFTER, "numpy", { "float_" => entry },
        { "float64" => entry })

      assert_nil found[0].repair
      assert_equal "float64", found[0].candidate
    end
  end

  def test_a_name_with_no_close_export_is_a_removal_not_a_rename
    with_probes({ ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "missing" }) do
      found = M.symbols_between(BEFORE, AFTER, "numpy", { "float_" => entry },
        { "array" => entry })

      assert_nil found[0].repair
    end
  end

  def test_a_name_the_release_still_has_one_level_down_is_a_move
    # `numpy.RankWarning` and `wsproto.Event` are still there, under `numpy.exceptions` and
    # `wsproto.events`. A report that says "pin below this release" about a name one path segment
    # from working sends a caller to pin a version they do not have to pin.
    with_probes({ ["1.26.4", "RankWarning"] => "clean", ["2.0.0", "RankWarning"] => "missing" },
      places: { "RankWarning" => "numpy.exceptions.RankWarning" }) do
      found = M.symbols_between(BEFORE, AFTER, "numpy", { "RankWarning" => entry },
        { "array" => entry })

      assert_equal "numpy.exceptions.RankWarning", found[0].moved
      assert_nil found[0].repair
    end
  end

  def test_the_move_is_looked_up_once_for_the_whole_pass
    names = %w[gone_a gone_b gone_c]
    answers = names.to_h { |name| [["1.26.4", name], "clean"] }
    answers.merge!(names.to_h { |name| [["2.0.0", name], "missing"] })

    with_probes(answers, places: { "gone_b" => "numpy.exceptions.gone_b" }) do |calls|
      older = names.to_h { |name| [name, entry] }
      found = M.symbols_between(BEFORE, AFTER, "numpy", older, {})

      assert_equal [nil, "numpy.exceptions.gone_b", nil], found.map(&:moved)
      assert_equal 1, calls.length
      assert_equal names.sort, calls[0][2].sort
    end
  end

  def test_a_name_the_release_renamed_is_not_also_looked_for_elsewhere
    # One answer to "where did it go", not two: a rename already says, and a second source is how
    # two fields come to disagree about the same fact.
    answers = { ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "missing",
                ["2.0.0", "float64"] => "clean" }

    with_probes(answers, places: { "float_" => "numpy.exceptions.float_" }) do |calls|
      found = M.symbols_between(BEFORE, AFTER, "numpy", { "float_" => entry },
        { "float64" => entry })

      assert_equal "float64", found[0].repair
      assert_nil found[0].moved
      assert_equal [], calls
    end
  end

  # Every pair here was filed by this miner as a rename and is not one. They are taken from the live
  # corpus rather than invented, because the rule being tested was written to fit them: `difflib` at
  # 0.6 scored all of these as close enough.
  NOT_A_RENAME = [
    # paramiko 4.0.0. A DSA key class offered an ECDSA key class, under an AttributeError whose own
    # suggestion was `RSAKey`.
    %w[DSSKey ECDSAKey],
    # numpy 2.0.2. A warning class offered a window function.
    %w[RankWarning hanning],
    # pandas 3.0.6. `read_gbq` moved to pandas-gbq; `read_sql` is a different function entirely.
    %w[read_gbq read_sql],
    # litellm 1.102.1, twice.
    %w[OCRResponse RerankResponse],
    %w[is_azure_document_intelligence_model is_openai_finetune_model],
    # websockets, twice.
    %w[WebSocketURI WebSocketServer],
    %w[ClientConnection ConnectionClosed],
    # jinja2 3.1.6. A decorator offered a class.
    %w[environmentfilter Environment],
    # Two unrelated warning classes.
    %w[PytestUnhandledCoroutineWarning PytestUnhandledThreadExceptionWarning],
    # From the corpus the tightened rule produced, both filed as renames by the version that let a
    # candidate drop a word.
    %w[X12Book Book],
    %w[smart_open open],
    # Plausible and now refused, which is the cost of the rule above.
    %w[CythonMetaType CythonType],
    %w[IdentityOptions Identity]
  ].freeze

  def test_a_name_that_only_looks_alike_is_not_a_rename
    NOT_A_RENAME.each do |removed, offered|
      assert_nil M.best_symbol_replacement(removed, { offered => entry }),
        "#{removed} -> #{offered} is not a rename"
    end
  end

  # The renames the rule must keep, from the same corpus. A rule that refuses everything would be
  # safe and useless.
  A_RENAME = [
    %w[setReconnect set_reconnect],
    %w[random_lobster random_lobster_graph],
    %w[Binary LargeBinary],
    %w[subquery Subquery],
    %w[PytestRemovedIn9Warning PytestRemovedIn10Warning],
    %w[float_ float64],
    # From the corpus: the new name keeps both of the old one's words.
    %w[KafkaClient KafkaAdminClient]
  ].freeze

  def test_a_name_respelled_out_of_the_same_words_is_a_rename
    A_RENAME.each do |removed, offered|
      assert_equal offered, M.best_symbol_replacement(removed, { offered => entry }),
        "#{removed} -> #{offered} is a rename"
    end
  end

  def test_two_equally_good_candidates_are_not_a_rename
    # `numpy` 2.0 exports both `float32` and `float64`, and both are `float_` plus a number.
    # Choosing one is guessing again with better manners.
    newer = { "float32" => entry, "float64" => entry }

    assert_nil M.best_symbol_replacement("float_", newer)
  end

  def test_a_number_that_changed_is_the_same_name
    assert M.best_symbol_replacement("PytestRemovedIn9Warning",
      { "PytestRemovedIn10Warning" => entry })
  end

  def test_a_private_name_is_not_offered_as_a_replacement
    # A release that drops `float_` was not renaming it to `_float`.
    with_probes({ ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "missing" }) do
      found = M.symbols_between(BEFORE, AFTER, "numpy", { "float_" => entry },
        { "_float_" => entry })

      assert_nil found[0].repair
    end
  end

  def test_a_name_is_only_checked_when_the_newer_release_dropped_it
    with_probes({ ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "clean" }) do
      assert_equal [], M.symbols_between(BEFORE, AFTER, "numpy", { "float_" => entry },
        { "float_" => entry })
    end
  end

  def test_an_unreadable_signature_does_not_hide_a_name_that_was_removed
    # A C extension's signature cannot always be read, and that must not make its disappearance
    # invisible — the name is what a caller imports.
    with_probes({ ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "missing" }) do
      older = { "float_" => entry(kind: "class", params: nil) }

      assert_equal 1, M.symbols_between(BEFORE, AFTER, "numpy", older, {}).length
    end
  end

  # One callable whose parameters `older`'s release had and `newer`'s does not.
  #
  # Both releases define the same *name*, so the symbol pass skips it and the test exercises the
  # argument pass alone.
  def signature_inventory(older:, newer:)
    lambda do |env, **_kwargs|
      names = env.version == BEFORE.version ? older : newer
      AgentsMiner::Envs::Inventory.new(
        module: "numpy",
        entries: [{ "name" => "obj", "kind" => "class",
                    "params" => names.sort.to_h { |name| [name, { "required" => false }] } }]
      )
    end
  end

  def test_a_symbol_probe_that_never_ran_is_not_an_acceptance
    # The third answer, at the older release.
    #
    # `probe_symbol` returns the literal `TIMEOUT` when it never reached the release, and
    # `refused_symbol` answers false for it because no refusal is in the string — so without this
    # guard a name nobody ever asked the old release about was filed as one it accepted and then
    # lost, with `accepted_output` = `TIMEOUT` as its evidence. A probe that could not be made is
    # not evidence about anything.
    with_probes({ ["1.26.4", "float_"] => "timeout", ["2.0.0", "float_"] => "missing" }) do
      assert_equal [], M.symbols_between(BEFORE, AFTER, "numpy", { "float_" => entry }, {})
    end
  end

  def test_a_symbol_replay_that_never_ran_does_not_become_the_fix
    # A killed replay is not a confirmed rename.
    #
    # The "was the candidate accepted" test is what the code reads as the interpreter having taken
    # it, so a replay that never ran was promoted to the report's fix — the one lie this module was
    # rewritten to stop telling. The name is withheld instead: the removal is still reported,
    # without a repair, and no refusal is claimed that the interpreter never made.
    with_probes({ ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "missing",
                  ["2.0.0", "float64"] => "killed" }) do
      found = M.symbols_between(BEFORE, AFTER, "numpy", { "float_" => entry },
        { "float64" => entry })

      assert_nil found[0].repair
      assert_nil found[0].candidate
      assert found[0].accepted_before
      refute found[0].accepted_after
    end
  end

  def test_an_argument_probe_that_never_ran_is_not_an_acceptance
    # The same third answer, in the argument pass.
    #
    # The old release timed out and the new one refuses the argument, which is exactly the pair a
    # finding is built from — but the half that says the older release accepted it is a probe that
    # never happened.
    probe = lambda do |env, _module_name, _name, parameter, **_kwargs|
      env.version == BEFORE.version ? TIMEOUT_OUTPUT : "unexpected keyword argument '#{parameter}'"
    end

    with_stubs(M, inventory_for: signature_inventory(older: ["legacy"], newer: ["modern"]),
      probe: probe) do
      assert_equal [], M.observations_between(BEFORE, AFTER, limit: 10)
    end
  end

  def test_an_argument_replay_that_never_ran_does_not_become_the_fix
    # A replay that never ran leaves neither a fix nor a refusal.
    probe = lambda do |env, _module_name, _name, parameter, **_kwargs|
      if parameter == "legacy"
        # Old release takes it, new one refuses it: the finding is real.
        env.version == BEFORE.version ? CLEAN : "unexpected keyword argument 'legacy'"
      else
        # The replay of the offered repair: the interpreter never got to answer.
        KILLED
      end
    end

    with_stubs(M, inventory_for: signature_inventory(older: ["legacy"], newer: ["legacy2"]),
      probe: probe) do
      found = M.observations_between(BEFORE, AFTER, limit: 10)

      assert_equal 1, found.length, "the removal is still a finding"
      assert_nil found[0].repair
      assert_nil found[0].candidate
    end
  end

  def test_a_confirmed_argument_repair_is_still_promoted
    # The guard must not swallow the working path it was added beside.
    probe = lambda do |env, _module_name, _name, parameter, **_kwargs|
      return CLEAN unless parameter == "legacy"

      env.version == BEFORE.version ? CLEAN : "unexpected keyword argument 'legacy'"
    end

    with_stubs(M, inventory_for: signature_inventory(older: ["legacy"], newer: ["legacy2"]),
      probe: probe) do
      found = M.observations_between(BEFORE, AFTER, limit: 10)

      assert_equal "legacy2", found[0].repair
      assert_nil found[0].candidate
    end
  end

  def test_an_unreadable_signature_is_not_compared_as_an_empty_one
    # `nil` from the inventory means "could not read", not "accepts nothing". Comparing it as a
    # mapping would report every unreadable callable as having lost everything it never showed, on
    # a signature nobody could read.
    entries = lambda do |env, **_kwargs|
      params = env.version == BEFORE.version ? nil : { "a" => { "required" => false } }
      AgentsMiner::Envs::Inventory.new(
        module: "numpy", entries: [{ "name" => "obj", "kind" => "class", "params" => params }]
      )
    end

    with_stubs(M, inventory_for: entries,
      probe: ->(*_args, **_kwargs) { "unexpected keyword argument 'a'" }) do
      assert_equal [], M.observations_between(BEFORE, AFTER, limit: 10)
    end
  end

  def test_a_symbol_probe_that_never_ran_is_its_own_answer_not_a_non_refusal
    # `nil` means "the change is not there", and it used to mean this as well.
    #
    # What the miner files is unchanged — a probe that never ran supports no finding either way —
    # but a caller asking about *one* report has to be able to tell the two apart: "the release
    # still exports the name" is a contradiction of a report, and "no release was asked" is no
    # evidence about anything. Handed the same `nil`, the verifiers cast the first on the strength
    # of the second.
    with_probes({ ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "timeout" }) do
      assert_same M::UNREACHED, M.confirm_symbol(BEFORE, AFTER, "numpy", "float_", {})
    end

    # The other two answers are still the two the comparisons are made of.
    with_probes({ ["1.26.4", "float_"] => "clean", ["2.0.0", "float_"] => "clean" }) do
      assert_nil M.confirm_symbol(BEFORE, AFTER, "numpy", "float_", {})
    end
  end

  def test_a_parameter_probe_that_never_ran_is_its_own_answer_not_a_non_refusal
    # The same third answer on the argument pass, where the older release's reply is the half that
    # establishes anything: a `TIMEOUT` there is not an acceptance that was later withdrawn.
    old_entry = { "name" => "obj", "kind" => "class",
                  "params" => { "legacy" => { "required" => false } } }
    new_entry = { "name" => "obj", "kind" => "class", "params" => {} }

    with_stub(M, :probe, ->(*_args, **_kwargs) { TIMEOUT_OUTPUT }) do
      assert_same M::UNREACHED,
        M.confirm(BEFORE, AFTER, "numpy", "obj", old_entry, new_entry, "legacy")
    end

    # Both releases answered and the argument was simply not taken away: `nil`.
    with_stub(M, :probe, ->(*_args, **_kwargs) { CLEAN }) do
      assert_nil M.confirm(BEFORE, AFTER, "numpy", "obj", old_entry, new_entry, "legacy")
    end
  end
end
