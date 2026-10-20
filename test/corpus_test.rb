# frozen_string_literal: true

require_relative "test_helper"

# The client's behaviour at the edges: a quota, an outage, a pause, and a query string.
#
# What each test asserts is unchanged — including that a pause is read from the *body* before
# the status code, which is the one branch that cannot be tested by a status alone.
class CorpusTest < MinerTest
  # A response, or a network failure, chosen by the test. Every request the client makes goes
  # through here, so the driver is the whole client and no server exists.
  class FakeHttp
    def initialize(&handler) = @handler = handler

    attr_reader :calls

    def call(method:, url:, body: nil, headers: {}, timeout: AgentsFyiMiner::Http::TIMEOUT)
      (@calls ||= []) << { method: method, url: url, body: body, headers: headers,
                           timeout: timeout }
      @handler.call(method: method, url: url, body: body)
    end
  end

  # What a server would have sent. Separate from `answer` because a *handler* has to be able to
  # build a response per request — the paging test below answers three requests with three
  # different bodies — where `answer` is one whole client that always says the same thing.
  def response(status: 200, body: "", headers: {})
    AgentsFyiMiner::Http::Response.new(status: status, body: body, headers: headers)
  end

  def answer(status: 200, body: "", headers: {})
    FakeHttp.new { |**_kwargs| response(status: status, body: body, headers: headers) }
  end

  def answer_json(payload, status: 200, headers: {})
    answer(status: status, headers: headers, body: JSON.generate(payload))
  end

  def offline(message = "no route to host")
    FakeHttp.new { |**_kwargs| raise AgentsFyiMiner::Http::Unreachable, message }
  end

  def client(http, base_url: "http://x") = AgentsFyiMiner::Corpus.new(base_url:, api_key: "k", http:)

  # The quota is the service's own protection. A client that retried through it would be the
  # reason it needed one, so the wait is read and honoured.
  def test_a_429_carries_the_wait_rather_than_being_a_generic_error
    http = answer(status: 429, body: "slow down", headers: { "retry-after" => "300" })

    error = assert_raises(AgentsFyiMiner::Errors::RateLimited) { client(http).submit({}) }

    assert_equal 300.0, error.retry_after
    assert_equal "POST", http.calls.first[:method]
    assert_equal "http://x/api/reports", http.calls.first[:url]
  end

  # The whole set, with the stamp that established it. Not a delta: the service's write replaces
  # the index's picture, so a client that sent one release at a time would erase the others, and a
  # release that builds again after an image bump is retracted by being absent.
  def test_a_picture_is_posted_whole_with_the_machine_that_established_it
    http = answer_json({ "recorded" => 1 })

    client(http).report_unexaminable(
      [{ package: "wrapt", release: "wrapt 1.13.3", reason: "no wheel for this interpreter" }],
      machine: "cpython 3.12 cc", ecosystem: "python"
    )

    call = http.calls.first
    assert_equal "POST", call[:method]
    assert_equal "http://x/api/mining/unexaminable", call[:url]
    assert_equal({ "ecosystem" => "python", "machine" => "cpython 3.12 cc",
                   "records" => [{ "package" => "wrapt", "release" => "wrapt 1.13.3",
                                   "reason" => "no wheel for this interpreter" }] },
      JSON.parse(call[:body]))
  end

  def test_a_429_with_no_wait_is_still_waited_for
    http = answer(status: 429, body: "")

    error = assert_raises(AgentsFyiMiner::Errors::RateLimited) { client(http).submit({}) }

    assert_equal AgentsFyiMiner::Errors::RETRY_AFTER_FALLBACK, error.retry_after
  end

  # A service meets a network that is down, and the difference between a refusal and an
  # outage is only what the caller does next.
  def test_an_unreachable_corpus_is_a_failure_the_caller_can_retry
    error = assert_raises(AgentsFyiMiner::Errors::CorpusError) { client(offline).changes }

    assert_includes error.message, "could not be reached"
    refute error.permanent?, "an outage is the corpus being unavailable, not refusing"
  end

  def test_a_refusal_that_is_not_a_quota_is_not_a_rate_limit
    http = answer(status: 422, body: "missing library")

    error = assert_raises(AgentsFyiMiner::Errors::CorpusError) { client(http).submit({}) }

    refute_kind_of AgentsFyiMiner::Errors::RateLimited, error
    assert error.permanent?, "a 4xx is the same request being declined again"
  end

  # The cursor is a pair, and dropping half of it is how a paging client loses the rows that
  # share a timestamp.
  def test_the_change_feed_cursor_and_limit_become_a_query_string
    http = answer_json({ "items" => [], "has_more" => false })

    client(http).changes(since: "2001-09-09T01:46:40Z", since_id: "abc", limit: 100)

    url = http.calls.first[:url]
    assert_includes url, "since=2001-09-09T01%3A46%3A40Z"
    assert_includes url, "since_id=abc"
    assert_includes url, "limit=100"
  end

  def test_an_absent_cursor_is_left_out_rather_than_sent_empty
    http = answer_json({})

    client(http).changes

    refute_includes http.calls.first[:url], "since"
  end

  # The route returns a page and says how big it is, so a client asking for more asks again
  # instead of being refused.
  #
  # This client asked for the whole depth in one request for as long as the method has
  # existed, against a route whose bound was 500 — so every start was a 422, and its caller
  # read a failed read of the queue as "use the local list" and did. The queue this service
  # computes has never driven the miner.
  def test_the_mining_queue_is_paged_rather_than_asked_for_in_one_request
    pages = [
      { "count" => 2, "limit_max" => 2, "targets" => [{ "package" => "a" }, { "package" => "b" }] },
      { "count" => 2, "limit_max" => 2, "targets" => [{ "package" => "c" }, { "package" => "d" }] },
      { "count" => 1, "limit_max" => 2, "targets" => [{ "package" => "e" }] }
    ]
    http = FakeHttp.new { |**_kwargs| response(body: JSON.generate(pages.shift)) }

    targets = client(http).mining_targets(limit: 10)

    assert_equal %w[a b c d e], targets
    assert_includes http.calls[1][:url], "offset=2"
    assert_includes http.calls[2][:url], "offset=4"
  end

  # A page shorter than the service said it would serve is the end of the queue, not a reason
  # to ask for the next one.
  def test_a_short_page_ends_the_paging
    http = answer_json({ "limit_max" => 500, "targets" => [{ "package" => "only" }] })

    assert_equal ["only"], client(http).mining_targets(limit: 1000)
    assert_equal 1, http.calls.length
  end

  # An older deployment answers without `limit_max`, and one request is the right number of
  # requests to spend finding that out — not an unbounded walk.
  def test_a_service_that_does_not_state_its_page_size_is_read_once
    http = answer_json({ "targets" => [{ "package" => "a" }] })

    assert_equal ["a"], client(http).mining_targets(limit: 1000)
    assert_equal 1, http.calls.length
  end

  # The service refuses a paused index with 503 on purpose, sharing that code with an
  # unreachable database, which wants the opposite response: one is retry in a moment, the
  # other is stop asking for fifteen minutes. `error.type` is the only thing that tells them
  # apart, and the sentence is what an operator reading the log needs — it names the index,
  # the reason and the route that lifts the pause.
  def test_a_paused_index_is_neither_an_outage_nor_a_quota
    body = JSON.generate(
      "error" => {
        "type" => "collection_paused",
        "status" => 503,
        "message" => "Collection for `python` is paused (Ruby is being brought up first), " \
                     "so your report was not recorded."
      }
    )
    http = answer(status: 503, body: body, headers: { "retry-after" => "900" })

    error = assert_raises(AgentsFyiMiner::Errors::CollectionPaused) { client(http).submit({}) }

    assert_equal 900.0, error.retry_after
    refute_kind_of AgentsFyiMiner::Errors::RateLimited, error
    # A pause is not the corpus declining this request: nothing is settled, and the same
    # request is what should happen later.
    refute error.permanent?
    assert_includes error.message, "POST /api/reports -> 503"
    assert_includes error.message, "Ruby is being brought up first"
  end

  # The status code alone is not the signal, which is why the type is read: a service whose
  # database is gone also answers 503, and waiting fifteen minutes on that would call an
  # outage a decision.
  def test_a_503_that_is_not_a_pause_stays_an_outage
    body = JSON.generate("error" => { "type" => "unavailable", "message" => "Retry shortly." })
    http = answer(status: 503, body: body)

    error = assert_raises(AgentsFyiMiner::Errors::CorpusError) { client(http).submit({}) }

    refute_kind_of AgentsFyiMiner::Errors::CollectionPaused, error
    refute error.permanent?, "a 5xx is the corpus being unavailable"
  end

  # `targets: []` and a pause look identical to a client that reads only the list, and they
  # mean opposite things: nothing left to mine is progress, and this is a decision somebody
  # made and can undo.
  #
  # Raised rather than returned, because the fallback for an empty or unreadable queue is the
  # local breadth ranking — which, for a paused index, is a list of names the service has
  # stopped accepting evidence about. The miner would then build an environment for every pair
  # on it and have every filing refused at the end.
  def test_a_paused_queue_is_raised_rather_than_read_as_an_empty_one
    # Braced, and that is load-bearing: a trailing hash literal without braces is read as
    # *keywords* when the method takes any, so `answer_json("targets" => …)` passes no payload at
    # all and Ruby raises before the test runs anything.
    http = answer_json({
      "targets" => [], "count" => 0, "ecosystem" => "python", "paused" => true,
      "paused_reason" => "Ruby is being brought up first",
      "next_step" => "Resume it with `POST /api/admin/collection/python/resume`."
    })

    error = assert_raises(AgentsFyiMiner::Errors::CollectionPaused) do
      client(http, base_url: "http://service:8001").mining_targets(limit: 10, ecosystem: "python")
    end

    assert_equal "python", error.ecosystem
    assert_equal AgentsFyiMiner::Errors::PAUSE_FALLBACK, error.retry_after
    assert_includes error.message, "Ruby is being brought up first"
    assert_includes error.message, "POST /api/admin/collection/python/resume"
  end

  # Registration is rate limited to ten an hour from one address, so the key is written once
  # and read back — and it is written as a credential (`0600`), because that is what it is.
  def test_a_key_is_registered_once_and_remembered
    http = answer_json({ "api_key" => "secret" }, status: 201)
    state = @home + "operator.json"

    first = AgentsFyiMiner::Corpus.load_or_register("http://x", state,
      name: "miner", email: "miner@example.test",
      http: http)
    second = AgentsFyiMiner::Corpus.load_or_register("http://x", state,
      name: "miner", email: "miner@example.test",
      http: http)

    assert_equal "secret", first
    assert_equal "secret", second
    assert_equal 1, http.calls.length, "a second run asked for a second identity"
    assert_equal 0o600, state.stat.mode & 0o777
    assert_equal "miner@example.test", read_json("operator.json")["email"]
  end
end
