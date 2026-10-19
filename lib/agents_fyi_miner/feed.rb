# frozen_string_literal: true

require_relative "ledger"

module AgentsFyiMiner
  # Reading the corpus's change feed into a ledger, which two services need.
  #
  # The feed is a cursor over `(updated_at, id)`, and what a client does with it is the same
  # whether it is about to answer an open report or confirm a resolved one: walk it forward,
  # remember every report it names, and keep the position so the next walk starts where this one
  # stopped.
  #
  # It lives here rather than on the miner's service because the second reader is the *verifier* —
  # a different process, with a different operator, doing a different job for the same corpus — and
  # two copies of a cursor walk would be two places for the lossless-paging rule to drift.
  # `scripts/` has already had one bug of that shape: a cursor advanced separately from the work it
  # describes points past a row the work never reached.
  module Feed
    # How many pages one walk reads before giving up on the rest of the corpus. The service reads
    # somebody else's corpus, whose size is not its to decide: 50 pages is 5000 reports, a few dozen
    # reads against a quota of 600 a minute, and past that "the most recent few thousand reports" is
    # a stated bound rather than a walk that never returns.
    DEFAULT_PAGES = 50

    # A backlog's order, oldest and newest alternately.
    #
    # `unresolved_seen` is ordered oldest-first, and that is right: a report nobody has got to is
    # worth more to whoever is still hitting it than one filed an hour ago. What is *not* right is
    # that both readers take only from the front, because the corpus keeps a deep pool of old
    # unconfirmed reports and each one costs minutes — so a report filed today sits behind all of
    # them, and "eventually" is days.
    #
    # Measured on this deployment: the as-reported verifier's backlog held 2,933 reports and its
    # cycle takes twenty-four of them, while a gem filed an hour earlier needed that operator's
    # confirmation to reach `resolved_verified`. The other operator, whose backlog was drained, had
    # already confirmed the gems.
    #
    # So the walk alternates: the oldest for the reason above, the newest because a report filed an
    # hour ago is worth something now rather than after two hundred older ones. The order *within*
    # each half is unchanged.
    def self.both_ends(report_ids)
      interleaved = []
      front = 0
      back = report_ids.length - 1
      while front <= back
        interleaved << report_ids[front]
        interleaved << report_ids[back] if front != back
        front += 1
        back -= 1
      end
      interleaved
    end

    # Read the feed forward, filing every report it mentions in the backlog.
    #
    # Returns how many reports the walk saw, so a cycle can say what it read rather than only what
    # it decided.
    #
    # `advance` is false for the reconciliation walk: that one starts at the beginning of a corpus
    # whose end has already been read, and moving the cursor backwards to a page it stopped at would
    # make the next cycle re-read the middle for no reason.
    def self.walk(session, ledger, since:, since_id:, pages: DEFAULT_PAGES, advance: true)
      seen = 0
      pages.times do
        page = session.changes(since: since, since_id: since_id, limit: 100)
        page.fetch("items", []).each do |report|
          # Hidden reports are named because a syncing client has to learn that something was
          # retracted. Neither reader can act on one, so it is counted and skipped rather than
          # filed — and *not* counted as seen, which is what the `next` before the counter means.
          next if report["hidden"]

          # The status travels with the id because the feed already carries it and a reader would
          # otherwise fetch the body to learn it — see `Ledger#note_seen` for what that cost.
          ledger.note_seen(report["id"].to_s, status: (report["status"] || "").to_s)
          seen += 1
        end
        # Taken from every page, including the last one, because it is the service's own position of
        # the last row it sent: a cursor the client computes from its clock can drift ahead of rows
        # it has not seen.
        if advance
          ledger.cursor_since = page["next_since"]
          ledger.cursor_id = page["next_since_id"]
        end
        break unless page["has_more"]

        since = page["next_since"]
        since_id = page["next_since_id"]
      end
      seen
    end

    # Walk from the beginning of the corpus, once, without moving the cursor.
    #
    # A cursor is a *position*, and a report filed before this process existed sits behind it
    # forever — which is the difference between a service that answers questions and one that only
    # reads recent news. Every process that has a backlog wants this on its first cycle, and
    # `only_if_started` is why it is skipped for a ledger with no cursor at all: a ledger that has
    # never read the feed is about to read all of it forward anyway.
    def self.reconcile(session, ledger, only_if_started: true, pages: DEFAULT_PAGES)
      return 0 if only_if_started && ledger.cursor_since.nil?

      walk(session, ledger, since: nil, since_id: nil, pages: pages, advance: false)
    end
  end
end
