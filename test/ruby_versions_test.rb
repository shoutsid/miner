# frozen_string_literal: true

require_relative "test_helper"

# RubyGems release histories, and the ordering they are read with.
#
# The ordering below is a copy of `Gem::Version`'s rule, and the table it is written from was
# produced by running each pair through a real `Gem::Version` in a container — the only thing that
# makes a reimplementation of somebody else's rule worth anything.
#
# The table is checked against the frozen recording of a real `Gem::Version` in the service's
# contract suite (`test/contracts/miner/version_order_test.rb`), not here: the recording belongs to
# the service, and a standalone checkout has no copy of it.
class RubyVersionsTest < MinerTest
  RUBYGEMS_ORDER = [
    ["1.0", "1.0.0", 0],
    ["1.0.0.pre", "1.0.0", -1],
    ["2.0.0.rc1", "2.0.0", -1],
    ["1.9.3", "1.10.0", -1],
    ["0.9", "0.10", -1],
    ["1.0.0-x.7.z.92", "1.0.0", -1],
    ["1.0.0.beta.2", "1.0.0.beta.10", -1],
    ["1.0.0.beta.2", "1.0.0.beta", 1],
    ["1.0.0", "1.0.0.0", 0],
    ["1.0.0.pre", "1.0.0.pre.1", -1],
    ["1.0.a", "1.0.0", -1],
    ["0.pre", "0", -1],
    ["1.0.0.1", "1.0.0", 1],
    ["1.2.3.4.5", "1.2.3.4.5.0", 0],
    ["1.0.0-1", "1.0.0.1", -1],
    ["2.0", "2.0.0.rc1", 1],
    ["1.10", "1.9", 1]
  ].freeze

  def setup
    super
    @fetch_stubbed = false
  end

  def teardown
    # The stub is process state, exactly as the monkeypatched `urlopen` was: a test that left one
    # in place would decide what a later test's fetch returns.
    if @fetch_stubbed
      AgentsFyiMiner::RubyVersions.singleton_class.alias_method(:fetch, :fetch_unstubbed)
      AgentsFyiMiner::RubyVersions.singleton_class.remove_method(:fetch_unstubbed)
      @fetch_stubbed = false
    end
    super
  end

  def test_a_gem_version_orders_the_way_rubygems_orders_it
    # One test over the table rather than seventeen: minitest has no parametrisation, and the
    # failure output names the pair either way.
    RUBYGEMS_ORDER.each do |left, right, expected|
      assert_equal expected, versions.compare(left, right), "#{left} <=> #{right}"
      assert_equal(-expected, versions.compare(right, left), "#{right} <=> #{left}")
    end
  end

  def test_a_dash_is_a_prerelease_separator_rather_than_a_zero_width_dot
    # `1.0.0-1` is older than `1.0.0.1`: RubyGems rewrites the dash to `.pre.`. A scanner that
    # ignored the punctuation gets this pair backwards.
    assert_equal(-1, versions.compare("1.0.0-1", "1.0.0"))
    assert_equal [1, "pre", 1], versions.gem_key("1.0.0-1")
  end

  def test_a_version_rubygems_would_refuse_is_not_ordered_by_a_guess
    # `+build` is malformed to RubyGems, so the ladder declines it rather than placing it: naming
    # the wrong predecessor picks the wrong comparison.
    assert_nil versions.gem_key("1.0.0+build")
    assert_nil versions.compare("1.0.0+build", "1.0.0")
    assert_equal ["1.0.0", "1.1.0"], versions.usable(["1.0.0", "1.0.0+build", "1.1.0"])
  end

  def test_two_spellings_of_one_release_keep_the_order_they_arrived_in
    # The one place this port's ordering differs from Ruby's own `sort`, deliberately: `1.0`
    # and `1.0.0` compare equal but are two entries, and `crossings` names whichever it meets
    # first as a line's release. Python's `sorted` was stable and Ruby's `sort` is not, so the
    # tie-break is written out — otherwise the release a pair is filed against would depend on
    # the sort algorithm rather than on the index.
    assert_equal ["1.0", "1.0.0"], versions.usable(["1.0", "1.0.0"])
    assert_equal ["1.0.0", "1.0"], versions.usable(["1.0.0", "1.0"])
  end

  def test_the_ladder_crosses_minor_lines_newest_first
    # A caller is behind by a *line*, so the pairs are line to line, newest crossing first — the
    # order a lockfile walks up the ladder.
    history = ["1.0.0", "1.0.5", "1.1.0", "1.2.0", "1.2.9", "2.0.0", "2.0.1"]

    pairs = versions.crossings("colorize", history)

    assert_equal [["1.2.9", "2.0.1"], ["1.1.0", "1.2.9"], ["1.0.5", "1.1.0"]],
      pairs.map { |pair| [pair.from_version, pair.to_version] }
    assert(pairs.all? { |pair| pair.package == "colorize" })
  end

  def test_the_span_picks_the_release_a_caller_is_plausibly_on
    # One line back is the newest release of the previous minor series — which is `2.0.0` against
    # `2.4.0`, not `1.9.0`: a line is a major *and* minor here, the same rule the PyPI side uses.
    history = ["1.0.0", "1.9.0", "2.0.0", "2.4.0"]

    assert_equal [AgentsFyiMiner::Pair.of(package: "rake", from_version: "2.0.0",
      to_version: "2.4.0")],
      versions.pairs_for("rake", history)
  end

  def test_a_history_is_one_fetch_with_the_dates_in_it
    # The RubyGems endpoint hands over number, prerelease and created_at in one document —
    # measured, and unlike PyPI it has no size field at all — so the cache is a whole reading by
    # construction and there is nothing to keep in step.
    asked = []
    stub_fetch do |url|
      asked << url
      JSON.generate([
        { "number" => "2.0.0", "prerelease" => false, "created_at" => "2024-05-01T00:00:00Z" },
        { "number" => "1.5.0", "prerelease" => false, "created_at" => "2023-01-01T00:00:00Z" },
        { "number" => "3.0.0.rc1", "prerelease" => true, "created_at" => "2025-01-01T00:00:00Z" },
        { "number" => "1.4.0", "prerelease" => false, "created_at" => "2022-01-01T00:00:00Z" }
      ])
    end

    history = versions.release_history("colorize", cache: @home)

    assert_equal ["1.4.0", "1.5.0", "2.0.0"], history, "oldest first, pre-releases out"
    assert_equal ["https://rubygems.org/api/v1/versions/colorize.json"], asked
    assert_equal "2024-05-01T00:00:00Z", versions.release_date("colorize", "2.0.0", cache: @home)

    # The cache answers the next call, with no second request.
    again = versions.release_history("colorize", cache: @home)
    assert_equal history, again
    assert_equal 1, asked.length
  end

  def test_a_stale_cache_is_still_used_when_the_index_cannot_be_reached
    # A miner that stopped mining because RubyGems was briefly down would be trading a certain
    # loss for an uncertain one.
    write("rake#{AgentsFyiMiner::RubyVersions::CACHE_SUFFIX}",
      "fetched_at" => Time.now.to_f - (10 * 24 * 3600),
      "releases" => [{ "number" => "13.1.0", "prerelease" => false,
                       "created_at" => "2024-01-01T00:00:00Z" }])
    stub_fetch { |_url| raise Errno::EHOSTUNREACH, "no route to host" }

    assert_equal ["13.1.0"], versions.release_history("rake", cache: @home)
  end

  def test_offline_with_nothing_cached_is_a_refusal_and_not_an_empty_ladder
    # `NoHistory`, and not `Errno::ENOENT`: the refusal is a judgement about the ladder rather
    # than a syscall, and it is the name the PyPI ladder beside this one raises for the same
    # case. The CLI rescues both.
    assert_raises(AgentsFyiMiner::RubyVersions::NoHistory) do
      versions.release_history("rake", cache: @home, offline: true)
    end
  end

  def test_a_gem_the_index_has_never_heard_of_is_the_same_refusal
    stub_fetch do |url|
      raise AgentsFyiMiner::RubyVersions::IndexError.new("#{url} -> 404", code: 404)
    end

    error = assert_raises(AgentsFyiMiner::RubyVersions::NoHistory) do
      versions.release_history("never-heard-of-it", cache: @home)
    end
    assert_match(/is not on the index \(404\)/, error.message)
  end

  def test_a_cache_without_dates_is_not_a_whole_reading
    # The lesson the PyPI side paid for: a document that cannot say when its releases were
    # published is refreshed rather than trusted, or every release it holds is filed undated for as
    # long as the window lasts.
    write("rake#{AgentsFyiMiner::RubyVersions::CACHE_SUFFIX}",
      "fetched_at" => Time.now.to_f,
      "releases" => [{ "number" => "13.1.0", "prerelease" => false }])
    stub_fetch do |_url|
      JSON.generate([{ "number" => "13.1.0", "prerelease" => false,
                       "created_at" => "2024-01-01T00:00:00Z" }])
    end

    assert_equal({}, versions.release_dates("rake", cache: @home))
    assert_equal ["13.1.0"], versions.release_history("rake", cache: @home)
    assert_equal({ "13.1.0" => "2024-01-01T00:00:00Z" },
      versions.release_dates("rake", cache: @home))
  end

  # The crossing a reviewed fix landed in: *adjacent*, not a line crossing, because a security fix
  # is usually a patch release inside the line a caller is already on (`2.2.6 -> 2.2.6.1`) and the
  # line ladder never produces that pair.
  def test_an_advisory_pair_is_the_crossing_the_fix_landed_in
    pair = versions.advisory_pair("rack", %w[2.2.5 2.2.6 2.2.6.1 2.2.7], fixed_in: "2.2.6.1")

    assert_equal ["2.2.6", "2.2.6.1"], [pair.from_version, pair.to_version]
  end

  # No predecessor is no crossing: the fix at the oldest release has nothing before it to move from.
  def test_an_advisory_pair_is_nil_when_the_fix_has_no_predecessor
    assert_nil versions.advisory_pair("rack", %w[2.2.6.1 2.2.7], fixed_in: "2.2.6.1")
    assert_nil versions.advisory_pair("rack", %w[2.2.6], fixed_in: "")
  end

  # A fix spelled as a version the index does not list is placed at the first release at or after it,
  # because that is the release the fix arrived by; nil only when there is none.
  def test_an_advisory_pair_uses_the_first_release_at_or_after_a_fix_it_cannot_place
    pair = versions.advisory_pair("rack", %w[2.2.5 2.2.6 2.2.7], fixed_in: "2.2.6.1")

    assert_equal ["2.2.6", "2.2.7"], [pair.from_version, pair.to_version]
    assert_nil versions.advisory_pair("rack", %w[2.2.5 2.2.6], fixed_in: "3.0.0")
  end

  private

  def versions = AgentsFyiMiner::RubyVersions

  def stub_fetch(&block)
    versions.singleton_class.alias_method(:fetch_unstubbed, :fetch)
    versions.define_singleton_method(:fetch, &block)
    @fetch_stubbed = true
  end
end
