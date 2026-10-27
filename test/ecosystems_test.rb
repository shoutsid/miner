# frozen_string_literal: true

require "json"

require_relative "test_helper"

# One process, two package indexes.
#
# The loop is the same for both, so what is tested here is the seam rather than the loop: that
# a pair carries the index it came from, that each adapter reaches its own index and its own
# installer, and that a deadline and a cache budget are *not* shared between them.
#
# What is *not* here: `test_ecosystems.py` also drove `service.Service` to check that one cycle
# mines both indexes, keeps two ledgers with two machine stamps, splits its budget between them and
# interleaves the pairs. Those are tests of the service loop and belong with it —
# `service.rb` is another slice of this port — and what they exercise is the loop's own arithmetic
# rather than the adapter's. The adapter's half of each of those facts is here: the stamp each index
# answers with, and the pairs each index stamps.
class EcosystemsTest < MinerTest
  P = AgentsMiner::Ecosystems::PYTHON
  R = AgentsMiner::Ecosystems::RUBY

  # Replace a module method for the length of a block, restoring it afterwards: these are
  # process-global, and a test that left one behind would decide the next test's answer.
  #
  # `instance_exec` rather than `define_singleton_method(name, &body)`: a block handed to
  # `define_method` runs with `self` bound to the receiver, so a stub that touched a test helper
  # would be calling it on the module instead of on the test.
  def with_stub(mod, name, body)
    original = mod.singleton_class.instance_method(name)
    test = self
    mod.define_singleton_method(name) { |*args, **kwargs| test.instance_exec(*args, **kwargs, &body) }
    yield
  ensure
    mod.singleton_class.send(:define_method, name, original)
  end

  def test_an_ecosystem_name_that_is_not_one_is_refused_rather_than_skipped
    # A deployment that asked for `pypi` should hear it rather than be given a miner that works
    # something else and reports healthy.
    assert_equal ["python"], AgentsMiner::Ecosystems.named("python").map(&:name)
    assert_equal %w[python ruby], AgentsMiner::Ecosystems.named("python,ruby").map(&:name)
    assert_equal ["python"], AgentsMiner::Ecosystems.named(nil).map(&:name)

    error = assert_raises(ArgumentError) { AgentsMiner::Ecosystems.named("pypi") }

    assert_includes error.message, "pypi"
    assert_includes error.message, "python, ruby", "the refusal names what it could have been"
  end

  def test_an_empty_name_list_is_pypi_rather_than_nothing
    # The variable the names come from is written by hand in a deployment, so a blank one has to
    # mean "the default a miner that was never asked for anything gets" rather than a miner with no
    # index at all — which would be a container that starts, prints nothing and looks healthy.
    assert_equal ["python"], AgentsMiner::Ecosystems.named("").map(&:name)
    assert_equal ["python"], AgentsMiner::Ecosystems.named([]).map(&:name)
    # The operator's order, kept rather than canonicalised, and a repeat that is not a second
    # index. Written as the code reads them — `python, ruby` would be this test asserting an
    # order nothing in either client promises, and the miner's pair budget is *divided* by
    # this list, so a fixed order is not cosmetic: it decides which index gets the remainder.
    assert_equal %w[ruby python], AgentsMiner::Ecosystems.named(["ruby", "python", "ruby"]).map(&:name),
      "order is the operator's and a repeat is not a second index"
  end

  def test_a_pair_carries_the_index_it_came_from
    # Downstream keys on the pair — the ledger, the installer, the differential — so a pair that had
    # to be told its index by the caller is one that can be examined with the wrong client.
    python_pair = AgentsMiner::Pair.of(package: "rake", from_version: "1.0.0", to_version: "1.1.0")
    ruby_pair = AgentsMiner::Pair.of(package: "rake", from_version: "1.0.0", to_version: "1.1.0",
      ecosystem: "ruby")

    assert_equal "python", python_pair.ecosystem, "the default is what every pair was"
    assert_equal "ruby", ruby_pair.ecosystem
  end

  def test_the_ruby_ladder_stamps_its_pairs
    plain = AgentsMiner::Pair.of(package: "rake", from_version: "1.0.0", to_version: "1.1.0")

    with_stub(AgentsMiner::RubyVersions, :crossings, ->(_package, _history, limit:) { [plain] }) do
      with_stub(AgentsMiner::RubyVersions, :pairs_for, ->(_package, _history, span:) { [plain] }) do
        assert_equal "ruby", R.crossings("rake", %w[1.0.0 1.1.0], limit: 8).first.ecosystem
        assert_equal "ruby", R.pairs_for("rake", %w[1.0.0 1.1.0], span: 1).first.ecosystem
      end
    end
  end

  def test_each_adapter_reaches_its_own_index
    # The delegation, checked at the module that owns the rule: a history read through the wrong
    # client is a ladder of the wrong index's versions, and PyPI has never heard of most gems.
    seen = []

    with_stub(AgentsMiner::Versions, :release_history,
      ->(_package, cache:, offline:) {
        seen << "py"
        ["1.0.0"] }) do
      with_stub(AgentsMiner::RubyVersions, :release_history,
        ->(_package, cache:, offline:) {
          seen << "rb"
          ["1.0.0"] }) do
        with_stub(AgentsMiner::Versions, :history_is_cached,
          ->(_package, cache:) {
            seen << "py-cache"
            false }) do
          with_stub(AgentsMiner::RubyVersions, :history_is_cached,
            ->(_package, cache:) {
              seen << "rb-cache"
              true }) do
            assert_equal ["1.0.0"], P.history("x", home: @home, refresh: true)
            assert_equal ["1.0.0"], R.history("x", home: @home, refresh: true)
            refute P.history_is_cached("x", home: @home)
            assert R.history_is_cached("x", home: @home)
          end
        end
      end
    end

    assert_equal %w[py rb py-cache rb-cache], seen
  end

  def test_the_two_indexes_price_a_deadline_differently_and_say_so
    # PyPI publishes each file's size, so the Python side can price an install from the bytes;
    # RubyGems publishes none — measured — so that side is a flat ceiling that doubles per attempt.
    # The difference has to be visible rather than shared, because a floor that fits one index fits
    # the other by accident at best.
    write("index/sqlalchemy.sizes.json", { "2.0.54" => 700 * 1024 * 1024 })

    priced = P.deadline("sqlalchemy", "2.0.54", home: @home, rate: 1_000_000.0, workers: 1, attempts: 0)
    flat = R.deadline("colorize", "0.8.1", home: @home, rate: 2_800_000.0, workers: 1, attempts: 0)
    retried = R.deadline("colorize", "0.8.1", home: @home, rate: nil, workers: 1, attempts: 1)

    assert priced > AgentsMiner::Envs::INSTALL_TIMEOUT,
      "a 700 MB payload is not a five-minute install"
    assert_equal AgentsMiner::RubyEnvs::INSTALL_TIMEOUT, flat
    assert_equal AgentsMiner::RubyEnvs::INSTALL_TIMEOUT * AgentsMiner::RubyEnvs::INSTALL_RETRY_FACTOR,
      retried
  end

  def test_each_index_prunes_its_own_caches_under_one_budget
    # The labels come back from the ecosystem so the cycle's report reads the same way for both, and
    # so the count can never describe a cache the other index owns. Two caches on the Python side
    # and one on the Ruby side is a fact about the indexes rather than an oversight: a `.gem` is
    # cached inside the environment that installed it, so there is no shared download cache here.
    (dir("envs", "a-1.0.0") + "payload").write("x" * 1024)
    (dir("rubyenvs", "b-1.0.0") + "payload").write("x" * 1024)

    python = P.prune(@home, budget: 0)
    ruby = R.prune(@home, budget: 0)

    assert(python.any? { |label, _removed, _freed| label.include?("environment") })
    assert(python.any? { |label, _removed, _freed| label.include?("wheel cache") })
    assert(ruby.any? { |label, _removed, _freed| label.include?("gem environment") })
    assert_equal 1, ruby.length, "the Ruby side has one cache with a budget"
    assert_equal 2, python.length, "the Python side has two"
  end

  def test_the_machine_each_index_is_stamped_with_is_the_index_s_own
    # A machine's Python is not its Ruby, and the stamp is what expires a fact when the
    # machine changes: 1,844 gem pairs here were stamped `cpython 3.12`, so a Ruby fact would
    # have survived a Python upgrade that changed nothing about gems.
    assert_equal AgentsMiner::Machine.python, P.machine
    assert_equal AgentsMiner::RubyEnvs.machine, R.machine
    refute_empty P.machine
    refute_empty R.machine
  end

  def test_each_index_builds_into_its_own_directory_under_the_home
    python_home = nil
    ruby_home = nil

    with_stub(AgentsMiner::Envs, :build,
      ->(package, version, home:, deadline:) {
        python_home = home
        "py-env" }) do
      with_stub(AgentsMiner::RubyEnvs, :build,
        ->(package, version, home:, timeout:, attempt:) {
          ruby_home = home
          "rb-env" }) do
        assert_equal "py-env", P.build("httpx", "0.28.0", home: @home, deadline: 300)
        assert_equal "rb-env", R.build("rake", "13.1.0", home: @home, deadline: 300)
      end
    end

    assert_equal @home + "envs", python_home
    assert_equal @home, ruby_home
  end

  def test_each_index_sweeps_the_scratch_it_owns
    with_stub(AgentsMiner::Envs, :sweep_scratch, ->(_root, **_extra) { [2, 4096] }) do
      with_stub(AgentsMiner::RubyEnvs, :sweep_scratch, ->(_home, *_) { [1, 2048] }) do
        assert_equal [["abandoned scratch dir(s)", 2, 4096]], P.sweep(@home)
        assert_equal [["abandoned gem scratch dir(s)", 1, 2048]], R.sweep(@home)
      end
    end
  end
end
