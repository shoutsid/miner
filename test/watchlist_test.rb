# frozen_string_literal: true

require "json"

require_relative "test_helper"

# The watchlist: which packages to mine, derived rather than curated.
#
# A test that reached a static site from here would pass in a data centre and fail in a
# tunnel, which is not a difference a test of a queue should have, and the autouse fixture
# that used to enforce it is now `setup`.
class WatchlistTest < MinerTest
  W = AgentsFyiMiner::Watchlist

  def setup
    super
    @real_fetch = W.method(:fetch)
    refuse_network
  end

  def teardown
    # The seam is process state, exactly as the monkeypatched `urlopen` was: a test that left a
    # stub in place would decide what a later test's fetch returns.
    W.define_singleton_method(:fetch, @real_fetch)
    super
  end

  # --- the reader's own rules ---------------------------------------------------

  def test_a_project_name_that_could_be_a_library_is_usable
    assert W.usable?("httpx")
    assert W.usable?("scikit-learn")
    assert W.usable?("zope.interface")
  end

  def test_a_name_that_could_not_be_imported_is_not
    # The ranking holds tooling, typing stubs and vendored forks as well as libraries, and the
    # differential needs something a caller can import.
    refute W.usable?("")
    refute W.usable?("2to3")
    refute W.usable?(".hidden")
    refute W.usable?("_private")
  end

  def test_a_ranking_that_is_not_a_list_of_names_is_ignored_rather_than_trusted
    write("watchlist.json", %({"rows": "nonsense"}))

    assert_nil W.send(:read_cache, @home + "watchlist.json")
  end

  # --- the breadth ranking ------------------------------------------------------

  def test_the_ranking_is_read_most_installed_first
    rows = { "rows" => [{ "project" => "boto3", "download_count" => 3 },
                        { "project" => "packaging", "download_count" => 2 },
                        { "project" => "certifi", "download_count" => 1 }] }
    fetch_returns(JSON.generate(rows))

    assert_equal %w[boto3 packaging certifi], W.ranking(cache: @home)
  end

  def test_a_cached_ranking_is_not_refetched_on_every_cycle
    # It is a monthly publication, and a service that re-read it every ten minutes would be
    # fetching the same file for the life of the container.
    asked = []
    fetch_recording(asked) { |_url| JSON.generate({ "rows" => [{ "project" => "boto3" }] }) }

    W.ranking(cache: @home)
    W.ranking(cache: @home)

    assert_equal 1, asked.length
  end

  def test_a_stale_ranking_is_refetched
    # A cache that never expires is a watchlist that never learns about a package that has just
    # become popular, which is the staleness this exists to remove.
    write("watchlist.json", %w[old])
    fetch_returns(JSON.generate({ "rows" => [{ "project" => "new" }] }))

    assert_equal %w[new], W.ranking(cache: @home, max_age: 0)
  end

  def test_an_unreachable_ranking_falls_back_to_the_cached_one
    # A miner that stopped because a static site was briefly down would be trading a certain loss
    # for an uncertain one.
    write("watchlist.json", %w[cached])
    fetch_raises(SocketError.new("no route to host"))

    assert_equal %w[cached], W.ranking(cache: @home, max_age: 0)
  end

  # --- the service's queue, and the order of the two ---------------------------

  def test_the_services_own_queue_comes_first_and_the_ranking_continues_it
    # The queue is the better-informed list, so it is the order. It is not the whole list.
    #
    # A package with an unanswered report is worth the next cycle in a way no download count can
    # express — and the queue is served a page at a time, so a watchlist made of *only* the queue
    # ends where the page ends. The miner asked for a thousand names, was handed one page, worked
    # through it, and had nothing left while the breadth ranking sat on disk.
    cached(%w[popular requests])
    chosen = W.watchlist(cache: @home, remote: -> { %w[httpx] })

    assert_equal %w[httpx popular requests], chosen.packages
    assert_equal [1, 2], [chosen.from_queue, chosen.from_ranking]
  end

  def test_the_operators_depth_is_honoured_across_both_sources
    # `top` is what the operator asked to work on, and it is spent on both lists.
    #
    # The version of this that returned the queue instead of the ranking could not honour it: the
    # depth was whatever the service had served, and the number the operator set was consulted
    # only when the queue was empty.
    cached((0...20).map { |index| "popular#{index}" })
    chosen = W.watchlist(cache: @home, top: 5, remote: -> { %w[a b c] })

    assert_equal %w[a b c popular0 popular1], chosen.packages
    assert_equal [3, 2], [chosen.from_queue, chosen.from_ranking]
  end

  def test_a_name_named_by_both_sources_is_mined_once
    # The queue is a ranking of the corpus and the seed, and the ranking is what the seed was made
    # of, so overlap is the normal case rather than the exception.
    cached(%w[httpx requests])
    chosen = W.watchlist(cache: @home, remote: -> { %w[httpx] })

    assert_equal %w[httpx requests], chosen.packages
    assert_equal [1, 1], [chosen.from_queue, chosen.from_ranking]
  end

  def test_a_service_that_cannot_be_reached_costs_the_preference_not_the_work
    # The queue being unavailable is not the miner being out of work.
    #
    # The service is a network dependency like any other, and a miner that stopped because its own
    # API was restarting would trade a certain loss for an uncertain one — the breadth ranking is
    # already cached and is the reason it is kept.
    fetch_returns(JSON.generate({ "rows" => [{ "project" => "popular" }] }))

    chosen = W.watchlist(cache: @home, remote: -> { raise SocketError, "connection refused" })

    assert_equal %w[popular], chosen.packages
    assert_equal 1, chosen.from_ranking
  end

  def test_a_queue_that_could_not_be_read_is_recorded_rather_than_swallowed
    # The failure is kept, because the version of this that dropped it hid a permanent one.
    #
    # The miner asked the service for 1000 targets and the route answered 422 — every start, for
    # as long as the queue has existed — and the fallback turned it into a normal-looking run on
    # the other list. Which list the miner is working is the first thing an operator needs from
    # the log.
    fetch_returns(JSON.generate({ "rows" => [{ "project" => "popular" }] }))

    refused = -> { raise AgentsFyiMiner::Errors::CorpusError.new("HTTP Error 422", permanent: true) }
    chosen = W.watchlist(cache: @home, remote: refused)

    refute_nil chosen.queue_error
    assert_includes chosen.queue_error, "422"
    assert_includes chosen.describe, "could not be read"
  end

  def test_a_paused_index_is_not_a_reason_to_use_the_breadth_ranking
    # `re_raise` is the one failure the fallback does not apply to: the ranking is a list of names
    # for an index the service has stopped accepting evidence about, so falling back would build
    # an environment for every pair and have every filing refused at the end.
    cached(%w[popular])
    paused = -> { raise AgentsFyiMiner::Errors::CollectionPaused.new("paused", ecosystem: "python") }

    assert_raises(AgentsFyiMiner::Errors::CollectionPaused) do
      W.watchlist(cache: @home, remote: paused,
        re_raise: [AgentsFyiMiner::Errors::CollectionPaused])
    end
  end

  def test_the_log_line_names_the_source_that_actually_contributed
    # It said "from the service's queue and the breadth ranking" while the queue was answering 422
    # and every package had come from the ranking.
    fetch_returns(JSON.generate({ "rows" => [{ "project" => "popular" }] }))

    from_ranking_only = W.watchlist(cache: @home, remote: -> { [] })
    from_both = W.watchlist(cache: @home, remote: -> { %w[httpx] })

    assert_equal "1 package(s) (1 from the breadth ranking)", from_ranking_only.describe
    assert_includes from_both.describe, "from the service's queue"
  end

  def test_an_empty_queue_is_not_a_choice_so_the_ranking_is_used
    # No queue computed yet is a first start, not a decision to mine nothing.
    fetch_returns(JSON.generate({ "rows" => [{ "project" => "popular" }] }))

    assert_equal %w[popular], W.watchlist(cache: @home, remote: -> { [] }).packages
  end

  def test_a_queue_naming_something_unimportable_is_filtered_like_any_other
    # The one rule that applies to both sources: a project has to be a library.
    cached([])
    chosen = W.watchlist(cache: @home, remote: -> { %w[httpx 2to3 _private] })

    assert_equal %w[httpx], chosen.packages
    assert_equal 1, chosen.from_queue
  end

  def test_with_no_ranking_at_all_the_curated_names_are_used
    # Filing into an empty corpus is worse than filing from a shorter list.
    fetch_raises(SocketError.new("no route to host"))

    chosen = W.watchlist(cache: @home, fallback: %w[httpx 2to3 flask])

    assert_equal %w[httpx flask], chosen.packages
    assert_equal 2, chosen.from_fallback
  end

  def test_the_watchlist_is_capped_at_what_was_asked_for
    rows = { "rows" => (0...50).map { |index| { "project" => "pkg#{index}" } } }
    fetch_returns(JSON.generate(rows))

    assert_equal 10, W.watchlist(cache: @home, top: 10).packages.length
  end

  def test_the_default_depth_outlasts_the_work_it_is_a_bound_on
    # 1,000 packages was about two days of mining at the measured rate — 9,042 crossings in 1.9
    # days — and the corpus stopped growing when it ran out.
    assert_operator W::DEFAULT_TOP, :>=, 3000
  end

  # --- the RubyGems side -------------------------------------------------------

  def test_the_shipped_gem_snapshot_is_a_deep_unique_ranking_that_fits_the_seed_cap
    # 3,000 names, each once, and the body they serialise to has to stay under the 64 KiB the
    # service accepts a seed in — past that the seed is refused and the miner is told it has no
    # breadth at all.
    skip "the snapshot is still in the Python package: mv miner/agents_fyi_miner/data/rubygems-downloads.txt miner/lib/agents_fyi_miner/data/" unless W::RUBY_SNAPSHOT.file?

    names = W.ruby_downloads

    assert_equal W::RUBY_DOWNLOADS_TOP, names.length
    assert_equal 3000, W::RUBY_DOWNLOADS_TOP
    assert_equal names.length, names.uniq.length
    assert_operator JSON.generate({ "projects" => names }).bytesize, :<, 64 * 1024
  end

  def test_the_gem_snapshot_skips_its_header_and_keeps_download_order
    snapshot = write("downloads.txt", "# generated\n# source\nbundler\nrake\njson\n")

    assert_equal %w[bundler rake json], W.ruby_downloads(snapshot: snapshot)
    assert_equal %w[bundler rake], W.ruby_downloads(snapshot: snapshot, top: 2)
  end

  def test_a_missing_snapshot_is_named_rather_than_read_as_an_empty_ranking
    # An empty ranking and an index that publishes nothing are the same list, and one of them is a
    # data file that did not ship. The error is its own class so `watchlist` cannot mistake it for
    # an unreachable ranking and quietly hand back the curated names.
    error = assert_raises(AgentsFyiMiner::Watchlist::SnapshotMissing) do
      W.ruby_downloads(snapshot: @home + "absent.txt")
    end

    # The sentence has to name the *file* rather than only the fact, because the fix is a copy
    # command: the snapshot ships in the client's own tree, and an operator reading a miner's log
    # after a bad image build is the person this message is for.
    assert_includes error.message, @home.to_s + "/absent.txt"
    assert_includes error.message, "gem breadth snapshot"
    assert_includes error.message, "rubygems-downloads.sh"
  end

  def test_the_gem_ranking_is_read_from_the_page_and_not_from_its_chrome
    # The RubyGems ranking is HTML, so the reader is scoped twice — to what follows the ranking's
    # own heading, and to the entry markup that heading introduces. The service has the same
    # reader in its own queue and this is the copy a client cannot avoid; both are driven against
    # this same markup.
    page = '<nav><a href="/gems/not-a-ranking-entry">Sign in</a></nav>' \
           '<h3><span class="font-semibold">All Time Most Downloaded</span></h3>' \
           '<h3><a class="text-orange-500" href="/gems/bundler">bundler</a></h3>' \
           '<h3><a class="text-orange-500" href="/gems/rake">rake</a></h3>' \
           '<footer><a href="/gems/not-a-ranking-entry-either">About</a></footer>'

    assert_equal %w[bundler rake], W.parse_gem_ranking(page)
    assert_equal [], W.parse_gem_ranking("<html><body>Nothing here</body></html>")
  end

  def test_the_gem_ranking_walks_the_pages_and_stops_when_one_is_empty
    # Ten gems a page, so the walk is part of reading it — and its bound is the page that lists
    # nothing rather than a count written here, because a count would silently truncate the
    # ranking the day the site publishes more.
    pages = {
      W::RUBY_RANKING => %w[bundler rake],
      "#{W::RUBY_RANKING}?page=2" => %w[nokogiri],
      "#{W::RUBY_RANKING}?page=3" => []
    }
    asked = []
    fetch_recording(asked) do |url|
      body = pages.fetch(url, []).map { |name| %(<h3><a href="/gems/#{name}">#{name}</a></h3>) }.join
      "All Time Most Downloaded#{body}"
    end

    assert_equal %w[bundler rake nokogiri], W.ruby_ranking(cache: @home)
    assert_equal [W::RUBY_RANKING, "#{W::RUBY_RANKING}?page=2", "#{W::RUBY_RANKING}?page=3"],
      asked

    # And the cache answers the next call: reaching the network again would raise.
    asked.clear
    refuse_network("the cached ranking should be used")

    assert_equal %w[bundler rake nokogiri], W.ruby_ranking(cache: @home)
    assert_empty asked
  end

  private

  # A ranking on disk, so a test that is about the queue does not fetch one.
  def cached(names)
    write("watchlist.json", names)
  end

  # The fixture: any fetch is a failure. The message names the URL, so a test that reached the
  # network says which one it wanted instead of failing on a timeout.
  def refuse_network(message = "this test should not touch the network")
    W.define_singleton_method(:fetch) { |url| raise "#{message}: #{url}" }
  end

  def fetch_returns(body)
    W.define_singleton_method(:fetch) { |_url| body }
  end

  def fetch_raises(error)
    W.define_singleton_method(:fetch) { |_url| raise error }
  end

  def fetch_recording(asked, &handler)
    W.define_singleton_method(:fetch) do |url|
      asked << url
      yield(url)
    end
  end
end
