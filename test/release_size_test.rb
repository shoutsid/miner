# frozen_string_literal: true

require "json"

require_relative "stub_helper"
require_relative "test_helper"

# Pricing a release, from the index payload the miner already downloads.
#
# The sizes have to come from somewhere, and the whole reason this is cheap is that they come
# from somewhere already paid for: `release_history` fetches the complete index document —
# every release, every file, every size — and used to keep only the version names. So the claim
# worth pinning is not just "the size is right" but "the size cost no request", which is why
# one test counts the calls to the index.
#
# The other claim is the direction of the error. A deadline priced from these bytes is allowed
# to be too long and not too short, because too long costs an idle worker while too short kills
# the download and throws away every byte it moved. That is why the number kept is the largest
# plausible wheel rather than the exact one pip would pick — matched by hand here rather than by
# full platform-tag matching.
class ReleaseSizeTest < MinerTest
  include StubHelper

  V = AgentsFyiMiner::Versions
  MB = 1024 * 1024

  PAYLOAD = {
    "releases" => {
      "1.0.0" => [
        { "filename" => "pkg-1.0.0-py3-none-any.whl", "packagetype" => "bdist_wheel",
          "size" => 3 * MB }
      ],
      "1.1.0" => [
        { "filename" => "pkg-1.1.0-py3-none-manylinux_2_28_aarch64.whl",
          "packagetype" => "bdist_wheel", "size" => 742 * MB },
        { "filename" => "pkg-1.1.0-py3-none-manylinux_2_28_x86_64.whl",
          "packagetype" => "bdist_wheel", "size" => 688 * MB },
        { "filename" => "pkg-1.1.0-py3-none-win_amd64.whl", "packagetype" => "bdist_wheel",
          "size" => 658 * MB }
      ],
      "2.0.0rc1" => [
        { "filename" => "pkg-2.0.0rc1.tar.gz", "packagetype" => "sdist", "size" => 5 * MB }
      ]
    }
  }.freeze

  # A stand-in for the index that counts how often it was asked — the Python suite's `Fetched`,
  # and the reason the fetch seam is a module method with no keyword arguments.
  class FakeIndex
    attr_reader :calls

    def initialize(payload)
      @payload = payload
      @calls = 0
    end

    def body
      @calls += 1
      JSON.generate(@payload)
    end
  end

  # Run a real `release_history` against a fake index, keeping the cache it writes.
  def with_index(payload, cache: @home)
    index = FakeIndex.new(payload)
    with_stub(V, :fetch, ->(_url) { index.body }) do
      V.release_history("pkg", cache: cache)
    end
    index
  end

  def test_the_sizes_are_kept_from_the_payload_already_fetched
    # One request, which is the one the history needed anyway.
    index = with_index(PAYLOAD)

    assert_equal 1, index.calls
    assert_equal 3 * MB, V.release_size("pkg", "1.0.0", cache: @home)
  end

  def test_the_publication_dates_come_from_the_same_payload_and_cost_nothing
    # Same document and same reasoning as the sizes above: the index hands over every file's
    # upload time in the response this call was already making. It is what lets the corpus say
    # which of its facts a reader's training data could not contain, so the claims worth
    # pinning are that the date is right and that it cost no request.
    payload = {
      "releases" => {
        "1.0.0" => [{ "filename" => "pkg-1.0.0-py3-none-any.whl",
                      "upload_time_iso_8601" => "2024-01-15T10:00:00.000000Z" }],
        "1.1.0" => [{ "filename" => "pkg-1.1.0.tar.gz",
                      "upload_time" => "2025-06-01T09:30:00" }]
      }
    }
    index = with_index(payload)

    assert_equal 1, index.calls
    dates = V.release_dates("pkg", cache: @home)
    assert_equal "2024-01-15T10:00:00.000000Z", dates["1.0.0"]
    # The older field, for an index document that predates the ISO one.
    assert_equal "2025-06-01T09:30:00", dates["1.1.0"]
  end

  def test_a_history_cached_before_dates_existed_contributes_none
    # The fallback, and it has to be a quiet one: a sidecar that is simply absent reads as no
    # dates rather than as an error, so a filing served offline — the fetch budget spent, or
    # the index down — goes out with a null date rather than a guess.
    write("pkg.json", ["1.0.0"])

    assert_equal({}, V.release_dates("pkg", cache: @home))
  end

  def test_the_wheel_for_this_machine_is_priced_and_not_the_arm_or_windows_one
    # A 742 MB ARM wheel is not what an x86-64 host would download.
    with_index(PAYLOAD)

    assert_equal 688 * MB, V.release_size("pkg", "1.1.0", cache: @home)
  end

  def test_a_release_with_only_a_source_distribution_is_still_priced
    # An sdist is bytes to move too, and pip will build it if there is no wheel.
    with_index(PAYLOAD)

    assert_equal 5 * MB, V.release_size("pkg", "2.0.0rc1", cache: @home)
  end

  def test_a_release_with_no_files_is_not_priced
    with_index({ "releases" => { "1.0.0" => [] } })

    assert_nil V.release_size("pkg", "1.0.0", cache: @home)
  end

  def test_a_yanked_release_is_not_priced
    # Yanked releases are not mined, so they are not sized either.
    payload = {
      "releases" => {
        "1.0.0" => [
          { "filename" => "p.whl", "packagetype" => "bdist_wheel", "size" => 2 * MB },
          { "filename" => "p.whl", "packagetype" => "bdist_wheel", "size" => 1 * MB }
        ],
        "1.1.0" => [{ "filename" => "yanked.whl", "packagetype" => "bdist_wheel",
                      "size" => 9 * MB, "yanked" => true }]
      }
    }
    with_index(payload)

    assert_nil V.release_size("pkg", "1.1.0", cache: @home)
    assert_equal 2 * MB, V.release_size("pkg", "1.0.0", cache: @home)
  end

  def test_an_unknown_release_reads_as_unknown_rather_than_free
    # Nothing is priced for a release the cache does not mention.
    with_index(PAYLOAD)

    assert_nil V.release_size("pkg", "9.9.9", cache: @home)
    assert_nil V.release_size("other", "1.0.0", cache: @home)
  end

  def test_a_cache_that_predates_the_sizes_reads_as_unknown_rather_than_free
    # The history cache keeps its old shape, and an absent sizes file is not an error.
    #
    # A deployment upgrading into the sizes change has histories on disk with no sizes beside
    # them. Those must keep working — and must read as *unknown*, which keeps the flat timeout,
    # rather than as free, which would price every release at zero. The dates sidecar is
    # written here because a history without one is complete enough for this question and not
    # for the fetch budget's; see the test below.
    write("pkg.json", %w[1.0.0 1.1.0])
    write("pkg.dates.json", { "1.0.0" => "2024-01-15T10:00:00Z" })

    assert_equal %w[1.0.0 1.1.0], V.release_history("pkg", cache: @home)
    assert_nil V.release_size("pkg", "1.0.0", cache: @home)
  end

  def test_a_cached_history_with_no_dates_is_asked_for_again
    # The one reading of the index the miner must not keep: the version names without when each
    # release was published.
    #
    # A report filed from such a cache goes out undated for ever, so the corpus cannot answer
    # what changed after a reader's training data ends for that release — the whole point of
    # the column. Measured on the live miner the day it deployed, 2,885 of 3,000 cached
    # histories were in this state, so the fix is to complete the cache rather than to leave it
    # to expire: one request, once, and the dates are written from the payload that request was
    # going to return anyway.
    write("pkg.json", ["1.0.0"])
    refute V.history_is_cached("pkg", cache: @home)

    published = "2024-01-15T10:00:00.000000Z"
    index = with_index({ "releases" => { "1.0.0" => [{ "filename" => "p.whl",
                                                       "upload_time_iso_8601" => published }] } })

    assert_equal 1, index.calls
    assert V.history_is_cached("pkg", cache: @home)
    assert_equal({ "1.0.0" => published }, V.release_dates("pkg", cache: @home))
  end

  def test_a_broken_sizes_file_is_unknown_rather_than_an_error
    write("pkg.sizes.json", "{not json")

    assert_nil V.release_size("pkg", "1.0.0", cache: @home)
  end

  def test_a_file_that_is_not_a_size_is_not_a_price
    # A negative or non-numeric entry would price a deadline absurdly, so it is refused.
    write("pkg.sizes.json", { "1.0.0" => -5, "1.1.0" => "big", "1.2.0" => 0,
                              "1.3.0" => 2 * MB })

    assert_nil V.release_size("pkg", "1.0.0", cache: @home)
    assert_nil V.release_size("pkg", "1.1.0", cache: @home)
    assert_nil V.release_size("pkg", "1.2.0", cache: @home)
    assert_equal 2 * MB, V.release_size("pkg", "1.3.0", cache: @home)
  end

  def test_the_two_readers_of_the_cache_rule_agree
    # One rule, two callers, and only one of them spends the fetch budget.
    #
    # `release_history`'s early return serves the cache on this rule and `history_is_cached`
    # tells the planner whether a request will happen on it. Two copies would drift into a
    # budget charged for requests that are never made — the bug that left 411 packages
    # unreachable behind a head that consumed a whole cycle's allowance out of a cache — so the
    # state is driven here rather than the agreement being trusted by construction: for every
    # shape a cache can be in, the answer that says "cached" is the one where no request is
    # made.
    aged = Time.now - (7 * 3600)
    shapes = {
      "nothing" => lambda { |_cache| },
      "a history on its own" => ->(cache) { (cache + "pkg.json").write(JSON.generate(["1.0.0"])) },
      "a history with its dates" => lambda { |cache|
        (cache + "pkg.json").write(JSON.generate(["1.0.0"]))
        (cache + "pkg.dates.json").write(JSON.generate({ "1.0.0" => "2024-01-15" }))
      },
      "a sidecar with no dates in it" => lambda { |cache|
        (cache + "pkg.json").write(JSON.generate(["1.0.0"]))
        (cache + "pkg.dates.json").write("{}")
      },
      "a truncated sidecar" => lambda { |cache|
        (cache + "pkg.json").write(JSON.generate(["1.0.0"]))
        (cache + "pkg.dates.json").write("{not json")
      },
      "an expired history with dates" => lambda { |cache|
        (cache + "pkg.json").write(JSON.generate(["1.0.0"]))
        (cache + "pkg.dates.json").write(JSON.generate({ "1.0.0" => "2024-01-15" }))
        File.utime(aged, aged, cache + "pkg.json")
      }
    }

    shapes.each do |name, build|
      cache = dir(name.tr(" ", "-"))
      build.call(cache)

      index = FakeIndex.new(PAYLOAD)
      with_stub(V, :fetch, ->(_url) { index.body }) do
        cached = V.history_is_cached("pkg", cache: cache)
        V.release_history("pkg", cache: cache)

        refute_equal cached, index.calls.positive?,
          "#{name}: history_is_cached said #{cached} and #{index.calls} request(s) followed"
      end
    end
  end

  def test_the_date_is_asked_for_once_when_the_cache_cannot_say
    # Filing is the only moment this fact can be stored, so it is asked for rather than lost —
    # and the request is the one that completes the cache, so the next report about the package
    # costs nothing.
    #
    # `release_dates` deliberately does not reach the network; this is the one caller that must
    # not answer null while the index is reachable. Measured on the live deployment, this is
    # exactly how `about-time 3.3.0` went out undated: the planner's 24-request budget cannot
    # complete 2,885 cached histories at once, so a package it is still holding mines from a
    # cache that cannot date it.
    write("pkg.json", ["1.0.0"])
    published = "2024-01-15T10:00:00.000000Z"
    index = FakeIndex.new({ "releases" => { "1.0.0" => [{ "filename" => "p.whl",
                                                          "upload_time_iso_8601" => published }] } })

    with_stub(V, :fetch, ->(_url) { index.body }) do
      assert_equal published, V.release_date("pkg", "1.0.0", cache: @home)
      assert_equal 1, index.calls

      # Completed, so the second report from this package is dated for free.
      assert_equal published, V.release_date("pkg", "1.0.0", cache: @home)
      assert_equal 1, index.calls
    end
  end

  def test_a_cache_that_can_date_the_release_is_not_asked_about
    # The common case, which must stay free: the sidecar is there and nothing is fetched. A
    # filing path that asked every time would be a request per report.
    write("pkg.json", ["1.0.0"])
    write("pkg.dates.json", { "1.0.0" => "2024-01-15T10:00:00.000000Z" })
    index = FakeIndex.new(PAYLOAD)

    with_stub(V, :fetch, ->(_url) { index.body }) do
      assert_equal "2024-01-15T10:00:00.000000Z", V.release_date("pkg", "1.0.0", cache: @home)
      assert_equal 0, index.calls
    end
  end

  def test_an_unreachable_index_leaves_the_report_undated_rather_than_unfiled
    # A date is worth having and is not worth refusing a finding for. Every way the index can
    # fail is the same answer: null, and the report goes out anyway.
    write("pkg.json", ["1.0.0"])

    with_stub(V, :fetch, ->(_url) { raise SocketError, "no route to host" }) do
      assert_nil V.release_date("pkg", "1.0.0", cache: @home)
    end

    # And a package the index has never heard of is the same answer, not an error.
    with_stub(V, :fetch, ->(url) { raise V::IndexError.new("#{url} -> 404", code: 404) }) do
      assert_nil V.release_date("pkg", "1.0.0", cache: @home)
    end
  end
end
