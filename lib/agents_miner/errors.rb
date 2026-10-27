# frozen_string_literal: true

module AgentsMiner
  # What a caller does next, as an exception.
  #
  # Four errors, and the split is the whole point of them. Each carries the one fact the
  # handler has to have and cannot get from the message: whether the failure is
  # *permanent* (asking again reaches the same answer, so the work should be settled) or
  # *transient* (the corpus or the machine had a moment, so the pair must be left
  # unresolved and worked out again), and — for two of them — how long to wait.
  #
  # The messages are close enough to be confused, which is why they are not compared:
  # `AGENTS.md` records what happened when a 429 met a broad `CorpusError` handler in
  # `service._file` — the quota was logged as a filing failure, the pair was marked
  # examined, and the finding was never filed. Every catch here names the class.
  module Errors
    # A precheck verdict the miner should act on, in the corpus's own vocabulary.
    #
    # `duplicate` is what submit refuses, so filing it would be a request whose answer the
    # miner already has. `likely_duplicate` means a candidate carries every symptom in the
    # draft *including* one that identifies it — the same failure — and the honest answer
    # there is to verify that report instead, which the miner does not do because it has
    # not run anybody's fix.
    #
    # `similar` is filed. It is the verdict for a draft that is close to something
    # recorded without being close enough to refuse, and for the case where the titles read
    # alike but the symptoms disagree, the corpus's own advice is that submitting would not
    # be refused. A miner that stopped at `new` would decline exactly the findings the
    # duplicate rule has just finished saying are distinct — which is what a release
    # changing four arguments produces: four mechanisms whose titles read almost alike.
    FILABLE = %w[new similar].freeze

    def self.filable?(verdict) = FILABLE.include?(verdict)

    # The corpus would not take a request.
    #
    # `permanent` says whose problem it is. A 4xx is the corpus reading this request and
    # declining it — the same request will be declined again — while a 5xx, a read timeout
    # and a dropped connection are the corpus being unavailable, where the same request
    # later is exactly what should happen. The distinction matters at exactly one place: a
    # pair whose findings could not be filed is only worth re-examining if the failure was
    # the transient kind, because re-deriving a finding to meet the same refusal is minutes
    # of work for the same answer.
    class CorpusError < StandardError
      attr_reader :permanent

      def initialize(message, permanent: false)
        super(message)
        @permanent = permanent
      end

      def permanent? = @permanent
    end

    # How long to wait when the service says 429 without saying for how long. The caller's
    # own windows are an hour at their widest, so a minute is a floor rather than an
    # estimate: retrying sooner is what turns a limit into an outage.
    RETRY_AFTER_FALLBACK = 60.0

    # The write quota is spent, and the service said when it is not.
    #
    # A `publish` run treating this as a plain error is fine — it is about to exit and the
    # operator can rerun it. A service must not: 60 writes an hour is the service's own
    # protection, and a miner that hammered through it would be the reason it needed one.
    # So the wait is carried rather than guessed at.
    class RateLimited < CorpusError
      attr_reader :retry_after

      def initialize(message, retry_after:)
        super(message)
        @retry_after = retry_after
      end
    end

    # The `error.type` an index's pause carries on a refusal. One string in two places —
    # here and `lib/agents_service/collection.rb` — and the alternative to
    # naming it twice is a client that cannot recognise the refusal at all.
    PAUSE_TYPE = "collection_paused"

    # The service asks for fifteen minutes in `Retry-After`, which is what a refusal
    # carries. A paused *queue* answer has no header to read, so this stands in for it, and
    # it mirrors `Collection::RETRY_AFTER_SECONDS` rather than inventing a second interval.
    PAUSE_FALLBACK = 900.0

    # The service is not taking new evidence for one index.
    #
    # A sibling of `RateLimited` rather than an ordinary `CorpusError`, and for the same
    # reason that one exists: nothing was written, so nothing is settled, and it is not
    # something to retry in a moment — which means every caller that would otherwise treat
    # it as a failed *item* has to hand it to the loop that knows how long to wait. An
    # index is paused for hours, so a pause swallowed in the same place as a quota loses
    # more work than the quota did.
    #
    # `ecosystem` is carried because the caller knows it and the wire usually does not: the
    # queue's flag is read one index at a time, and a refusal names its index in the
    # sentence rather than in a field.
    #
    # `permanent` is inherited as false, which is the truth about it: the work is good and
    # the corpus is not taking it yet.
    class CollectionPaused < CorpusError
      attr_reader :retry_after, :ecosystem

      def initialize(message, retry_after: nil, ecosystem: "")
        super(message)
        @retry_after = retry_after.nil? ? PAUSE_FALLBACK : retry_after
        @ecosystem = ecosystem
      end
    end

    # The miner could not do its job, as distinct from finding nothing.
    #
    # Two facts travel with it, and both exist because the caller's next move differs.
    #
    # `permanent` is the distinction `CorpusError` draws for the corpus, drawn here for the
    # environment, and for the same reason: a release that is not on the index, or that has
    # no wheel for this interpreter and no source that builds, is a fact that asking again
    # will not change — while a timeout, a full disk or a dropped connection is the network
    # having a moment. The messages are similar enough to be confused and the costs are
    # not: retrying a permanent failure costs one attempt, while settling a transient one
    # leaves every pair that needs that release unattempted until the record expires.
    #
    # `release` names the release the failure is about — `"wrapt 1.13.3"` — because a
    # release is shared by several crossings of a package and the caller can record the
    # fact once per release rather than once per pair that needs it. Without it the caller
    # can only settle the pair it happened to be working on, and the eleven other pairs
    # through the same release go and ask pip the same question.
    class MinerError < StandardError
      attr_reader :release

      def initialize(message, permanent: false, release: "")
        super(message)
        @permanent = permanent
        @release = release
      end

      def permanent? = @permanent
    end

    # One release, spelled the way a reader checks it and the ledger keys it.
    #
    # It is here because the ledger, the verifier and both installers have to agree about it:
    # a stamp written as `wrapt 1.13.3` and read as `wrapt-1.13.3` is a fact that never
    # expires.
    def self.release_of(package, version) = "#{package} #{version}"
  end
end
