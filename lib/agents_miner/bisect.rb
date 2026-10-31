# frozen_string_literal: true

module AgentsMiner
  # The first release that refuses what the older one accepted.
  #
  # A differential runs two releases, so the report it files says "worked at 1.2, broke at 1.5" —
  # a *window*, and a caller reading it cannot tell whether 1.3 or 1.4 is the release that did it.
  # Those are different facts with different advice: "this move breaks you" argues for pinning
  # below the new release, and "1.3 broke you" says which release to read the changelog of.
  #
  # This searches the releases between the two endpoints, and it is deliberately a binary search
  # rather than a sweep: probing is an install, the window can hold a dozen releases, and the
  # corpus needs the answer for every crossing it files. `ceil(log2(k))` probes for `k` releases
  # between the endpoints is the difference between a feature that runs on every finding and one
  # that runs on none.
  #
  # Two things it does *not* do, and both are statements a reader can rely on:
  #
  # * It never answers from an unprobed release. A release that could not be built, or a window the
  #   caller had no budget left for, yields no answer at all — `nil`, not "not broken". A guess here
  #   would be a report naming a release nobody executed.
  # * It cannot prove the break is monotone. A release that refuses, then a later one that accepts
  #   again, is a shape a binary search meets as "the first refusal in this window"; the answer is
  #   the boundary it found, and the *window* it searched travels beside it so a reader knows how
  #   much of the range was ruled out rather than assumed.
  module Bisect
    # What one search found, and what it cost.
    #
    # `version` is the first release observed to refuse, or nil when nothing was established.
    # `window` is the pair the answer sits in — the release below it, which was observed to accept,
    # and the one above, which refused — and is the honest statement when `version` is nil.
    Result = Data.define(:version, :window, :probes) do
      def established? = !version.nil?

      # Whether a probe was spent at all. Distinguished from `established?` because a window with no
      # releases between its endpoints has nothing to search, and saying so is not a failure.
      def searched? = !probes.empty?
    end

    # The releases strictly between two, in the index's own order.
    #
    # Position in the ordering rather than a version comparison done here: the two indexes order
    # `1.0.0.pre` and `1.0.0-rc1` by rules this module does not implement, and a bisection over a
    # list sorted by a different rule than the index's would probe the wrong half. A version the
    # list does not hold yields no window rather than a guessed one — the endpoints came from the
    # same list, so this means the list moved under the search.
    def self.between(releases, from_version, to_version)
      from = releases.index(from_version.to_s)
      to = releases.index(to_version.to_s)
      return [] if from.nil? || to.nil? || to <= from + 1

      releases[(from + 1)...to]
    end

    # The first refusing release, given a probe that says whether a release refuses.
    #
    # `probe` is called with one version and answers `true` (it refuses what the from-release
    # accepted), `false` (it still accepts), or `nil` (the question could not be asked — an
    # unbuildable release, an exhausted budget). `nil` stops the search rather than being read as
    # either answer, which is the whole of the "an unreached release never reads as not broken"
    # rule.
    #
    # The invariant is `lo` accepts and `hi` refuses, with the answer strictly between them. The
    # loop ends when nothing is strictly between, so `hi` is adjacent to a release known to accept —
    # which is what makes it a boundary rather than merely an upper bound.
    def self.introduced(releases:, from_version:, to_version:)
      candidates = between(releases, from_version, to_version)
      lo = from_version.to_s
      hi = to_version.to_s
      return Result.new(version: nil, window: [lo, hi], probes: []) if candidates.empty?

      probes = []
      while candidates.any?
        middle = candidates[candidates.length / 2]
        refused = yield(middle)
        probes << [middle, refused]
        if refused.nil?
          # Unknown: the boundary is as far as this search got, and the caller keeps it as a pair
          # rather than accepting the upper end as the answer.
          return Result.new(version: nil, window: [lo, hi], probes: probes)
        end

        position = candidates.index(middle)
        if refused
          hi = middle
          candidates = candidates[0...position]
        else
          lo = middle
          candidates = candidates[(position + 1)..]
        end
      end

      Result.new(version: hi, window: [lo, hi], probes: probes)
    end
  end
end
