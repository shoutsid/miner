# frozen_string_literal: true

require_relative "test_helper"

# A paused index, from the deployment's side.
#
# The miner's own rule for a queue it cannot read is that it costs the miner its *preference* and not
# its work: the local breadth ranking is already on disk, so a briefly unreachable service means a
# slightly worse list rather than a stopped container. A paused index is the exception, and the reason
# is what the ranking is for an index the service has *stopped accepting evidence about* — so "use the
# other list" would build an environment for every pair it planned and have every filing refused at
# the end of it.
#
# These drive the seam that decides it without a server: the queue's refusal is the only input, and
# what is asserted is which indexes the run keeps.
#
# It lives in `cli.rb`, which another worker owns in this round; this file is the test of its
# *contract* rather than of its code, so it is written against the names the brief fixed:
# `Cli.workable(session, args, indexes)` returning the three things the caller must be able to
# say — the indexes being worked, each one's watchlist, and the paused ones with their
# reasons. `args` is any object answering `home`, `top`, `queue_pages` and `package`, and a
# Struct is used here rather than `Cli::Args` so this test does not depend on the flag
# parser's own shape.
class PauseTest < MinerTest
  Cli = AgentsMiner::Cli
  Errors = AgentsMiner::Errors
  Ecosystems = AgentsMiner::Ecosystems

  # The flags `workable` reads, so a test does not have to build the whole parser.
  def args_for(**overrides)
    Struct.new(:home, :top, :queue_pages, :package, keyword_init: true)
          .new(home: @home, top: 5, queue_pages: 1, package: nil, **overrides)
  end

  # A client whose queue is paused for the indexes named, and empty for the rest.
  class PausedSession
    def initialize(*paused) = @paused = paused.map(&:to_s)

    def mining_targets(limit:, pages:, ecosystem:)
      if @paused.include?(ecosystem.to_s)
        raise AgentsMiner::Errors::CollectionPaused.new(
          "the #{ecosystem} queue is paused: Ruby is being brought up first.", ecosystem: ecosystem.to_s
        )
      end

      []
    end
  end

  def test_a_paused_index_is_dropped_rather_than_mined_from_the_ranking
    # The service has stopped taking evidence for this index, so there is nothing a cycle could file
    # for it — and the fallback ranking is exactly the list that would make the miner try. What comes
    # back is the index that is open, the watchlist built for it, and the reason the other one is not
    # being worked.
    workable, watchlists, paused = Cli.workable(
      PausedSession.new("python"), args_for, Ecosystems.named("python,ruby")
    )

    assert_equal ["ruby"], workable.map(&:name)
    assert_equal ["python"], paused.map(&:first)
    assert_includes paused.first[1], "Ruby is being brought up first"
    assert_equal ["ruby"], watchlists.keys
  end

  def test_a_run_whose_every_index_is_paused_has_nothing_to_work
    # Every index closed is a state `serve` exits on and logs, rather than a cycle to run: a service
    # with nothing to work prints the same "0 pair(s)" as one that has finished the whole corpus, and
    # this project has already read that line as healthy for two days.
    workable, watchlists, paused = Cli.workable(
      PausedSession.new("python", "ruby"), args_for, Ecosystems.named("python,ruby")
    )

    assert_empty workable
    assert_empty watchlists
    assert_equal %w[python ruby], paused.map(&:first)
  end

  def test_an_explicit_package_is_worked_whatever_the_index_is_doing
    # An operator naming a package is an instruction about one pair, and it is honoured rather than
    # quietly narrowed to the indexes that happen to be open: the filing is the thing that gets
    # refused, loudly, and a run that silently did nothing would look like a pair that turned out to
    # be fine.
    workable, watchlists, paused = Cli.workable(
      PausedSession.new("python"), args_for(package: ["requests"]), Ecosystems.named("python")
    )

    assert_equal ["python"], workable.map(&:name)
    assert_equal({ "python" => ["requests"] }, watchlists)
    assert_empty paused
  end
end
