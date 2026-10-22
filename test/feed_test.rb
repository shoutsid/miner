# frozen_string_literal: true

require_relative "test_helper"

# The backlog walk, which both readers share.
#
# Small file, and it exists for one reason: the walk's *order* and the *status* it carries are both
# rules somebody will otherwise change locally, and both were measured the hard way on this
# deployment. The third thing here — what `reconcile` does to a cursor — is the rule that makes a
# process answer questions that were asked before it started.
class FeedTest < MinerTest
  F = AgentsFyiMiner::Feed

  # The corpus client, answering one page of changes and nothing else. `pages` is a list so a test
  # can drive a multi-page walk, and it stops answering once it runs out — which is what makes a
  # paging loop that ignores `has_more` visible rather than infinite.
  class Session
    attr_reader :asked

    def initialize(rows, pages: nil)
      @pages = pages || [{ "items" => rows, "has_more" => false,
                           "next_since" => "2026-01-01T00:00:00Z", "next_since_id" => nil }]
      @asked = 0
    end

    def changes(since: nil, since_id: nil, limit: 100)
      @asked += 1
      @pages[(@asked - 1), 1].first
    end
  end

  def ledger = AgentsFyiMiner::Ledger.new

  def test_the_backlog_walk_alternates_oldest_and_newest
    # A reader that takes only from the front reaches today's reports after every old one, and the
    # corpus holds a deep pool of old ones — measured here, 2,933 backlog entries at twenty-four a
    # cycle, while a gem filed an hour earlier waited for that operator's confirmation.
    assert_equal %w[a f b e c d], F.both_ends(%w[a b c d e f])
    assert_equal %w[a c b], F.both_ends(%w[a b c])
    assert_equal %w[only], F.both_ends(%w[only])
    assert_equal [], F.both_ends([])
  end

  def test_the_walk_files_the_status_the_feed_carries
    # The feed row *is* the status, so a reader that fetches the body to learn it spends a request
    # and a look per settled report in the corpus, every pass.
    session = Session.new(
      [
        { "id" => "a", "status" => "resolved_verified" },
        { "id" => "b", "status" => "resolved_unverified" },
        { "id" => "c", "hidden" => true, "status" => "open" }
      ]
    )
    store = ledger

    seen = F.walk(session, store, since: nil, since_id: nil)

    assert_equal 2, seen, "a hidden report is counted out, as it always was"
    assert_equal "resolved_verified", store.status_of("a")
    assert_equal "resolved_unverified", store.status_of("b")
    assert_equal "", store.status_of("c")
    refute store.seen?("c"), "a retracted report is not work"
  end

  def test_the_walk_files_the_ecosystem_the_feed_carries
    # The second half of the same fact: a verifier scoped to one index can pass over the other's
    # reports without fetching a body, which is what keeps a paused index's backlog from spending
    # the walk's look budget before the open one is reached.
    session = Session.new(
      [
        { "id" => "a", "status" => "resolved_unverified", "ecosystem" => "ruby" },
        { "id" => "b", "status" => "resolved_unverified", "ecosystem" => "python" }
      ]
    )
    store = ledger

    F.walk(session, store, since: nil, since_id: nil)

    assert_equal "ruby", store.ecosystem_of("a")
    assert_equal "python", store.ecosystem_of("b")
    assert_equal "", store.ecosystem_of("never-seen")
  end

  def test_the_walk_keeps_the_position_the_service_sent
    # Taken from every page, including the last one, because it is the service's own position of the
    # last row it sent: a cursor the client computes from its clock can drift ahead of rows it has
    # not seen, and a cursor that drifts is rows nobody ever reads.
    first = { "items" => [{ "id" => "a" }], "has_more" => true,
              "next_since" => "2026-01-01T00:00:00Z", "next_since_id" => "a" }
    last = { "items" => [{ "id" => "b" }], "has_more" => false,
             "next_since" => "2026-01-02T00:00:00Z", "next_since_id" => "b" }
    session = Session.new([], pages: [first, last])
    store = ledger

    assert_equal 2, F.walk(session, store, since: nil, since_id: nil)

    assert_equal 2, session.asked
    assert_equal "2026-01-02T00:00:00Z", store.cursor_since
    assert_equal "b", store.cursor_id
  end

  def test_a_status_the_feed_stops_reporting_does_not_outlive_it
    # The backlog's *time* is first-seen and stays; its status is last-seen, because a report whose
    # fix was withdrawn is a question again.
    store = ledger
    store.note_seen("a", now: 1.0, status: "resolved_verified")
    store.note_seen("a", now: 2.0, status: "open")

    assert_equal 1.0, store.backlog["a"]
    assert_equal "open", store.status_of("a")
  end

  def test_the_reconciliation_walk_starts_at_the_beginning_without_moving_the_cursor
    # Two rules in one test, because they are two halves of one decision. A report filed before this
    # process existed sits behind the cursor forever, so a reader with a *position* has to look back
    # once — but the walk must not write that position back, or the next cycle would re-read the
    # middle of the corpus for no reason.
    store = ledger
    store.cursor_since = "2026-06-01T00:00:00Z"
    store.cursor_id = "later"
    session = Session.new([{ "id" => "ancient" }])

    assert_equal 1, F.reconcile(session, store)

    assert_equal 1, session.asked
    assert store.seen?("ancient")
    assert_equal "2026-06-01T00:00:00Z", store.cursor_since
    assert_equal "later", store.cursor_id
  end

  def test_a_ledger_that_has_never_read_the_feed_does_not_reconcile
    # `only_if_started`, and why it is not merely an optimisation: a ledger with no cursor is about
    # to read the whole feed forward anyway, so a reconciliation walk would read the whole corpus
    # twice on a first start — the one moment it costs the most and knows the least.
    session = Session.new([{ "id" => "a" }])

    assert_equal 0, F.reconcile(session, ledger)
    assert_equal 0, session.asked
  end
end
