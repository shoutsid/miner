# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/agents_miner"

# What every test of the Ruby miner needs, in one place.
#
# The Python suite this replaced was pure by design — it installed nothing and reached no
# network, because the parts that do are the parts a test cannot assert anything stable about
# — and the same rule holds here: a test that installs a release is a test that fails when the
# index has a bad afternoon. What is covered is every *judgement* made about a run's output,
# which is where a fabricated finding would come from.
#
# Every test gets its own directory, and that is not tidiness. The miner's state is a home
# directory — environments, the index cache, the ledger — and two tests sharing one would
# pass or fail depending on their order, which is the kind of failure that costs a session to
# find (see `AGENTS.md` on the rarity cache). `@home` is a `Pathname`, because that is what
# the code takes.
class MinerTest < Minitest::Test
  def setup
    super
    @home = Pathname.new(Dir.mktmpdir("miner-test-"))
    @saved_env = ENV.to_h
  end

  def teardown
    FileUtils.remove_entry(@home) if @home&.exist?
    # Environment is process state, and the modules here read it — `PYTHON`, `MINER_*`, and
    # the scratch directory `envs.use_scratch_dir` sets. A test that set one and did not put
    # it back would decide a later test's answer.
    ENV.replace(@saved_env)
    super
  end

  # A directory inside this test's home, created on demand: `dir("envs")`.
  def dir(*parts)
    path = @home.join(*parts.map(&:to_s))
    FileUtils.mkdir_p(path)
    path
  end

  # Write a file, creating its directory. The index cache is a set of JSON files, and a test
  # about a cache hit has to be able to place one.
  def write(relative, content)
    target = @home.join(relative)
    FileUtils.mkdir_p(target.dirname)
    target.write(content.is_a?(String) ? content : JSON.generate(content))
    target
  end

  def read_json(relative) = JSON.parse(@home.join(relative).read)

  # Time as the code under test sees it, so a test can drive a clock rather than sleep.
  # Passed around by explicit `now:` in this client for exactly this reason — see
  # `Ledger#due` and `WriteBudget#allow`.
  def at(seconds) = Time.at(seconds)
end
