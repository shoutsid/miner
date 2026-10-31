# frozen_string_literal: true

require_relative "findings"

module AgentsMiner
  # What changed when the signatures did not.
  #
  # The differentials in `Mine` and `RubyMine` compare *surfaces*: which names a release exports
  # and what its callables accept. A release that keeps every name and every parameter and changes
  # what one of them *is* — a constant that held a string and now holds a table, a default that was
  # a tuple and is now a list, a version string that no longer matches the package — is invisible to
  # both, and a caller finds out at run time.
  #
  # This is the metamorphic relation the corpus can afford: the same attribute of the same release,
  # read twice, and compared. It costs nothing beyond what the inventory already did — the module is
  # imported, `dir(module)` is walked and each name is read to decide what it is — so there is no
  # second execution and no call into the release.
  #
  # **Two relations, and only the two an attribute can answer.** `returns_type` is the class the
  # value belongs to; `returns_equal` is the value's own rendering. Both are `repr`/`inspect` of a
  # value rather than a judgement about it, which is what keeps this a comparison of two executions
  # rather than a guess about intent. The relations that need a *call* — idempotence, round-trip,
  # side effects — are not here, because calling an arbitrary zero-argument function in a release
  # nobody has run is how a miner acquires network traffic and file writes it never asked for.
  module Behaviour
    # How many changed values one release pair may report.
    #
    # A bound rather than a threshold, for the same reason `Mine` caps its candidates: a release
    # whose constants are generated — a large table, a matrix, a registry — has hundreds of values,
    # and a finding per value would bury the one a caller can act on. Forty is well above the
    # handful a real release changes deliberately.
    MAX_ENTRIES = 40

    # The observation kind a behaviour finding carries, beside `argument` and `symbol`.
    KIND = "behaviour"

    # The relations this pass establishes, named as the comparison rather than as the symptom.
    RELATIONS = %w[returns_type returns_equal].freeze

    # One observation per attribute whose type or rendering differs between the two releases.
    #
    # The reading is one-directional like every other pass here: an attribute that exists in only
    # one of the two releases is the symbol pass's business, and reporting it here as well would
    # file one removal twice under two names for the same fact.
    def self.observations(before, after, limit: MAX_ENTRIES)
      older = (before.respond_to?(:values) ? before.values : nil) || {}
      newer = (after.respond_to?(:values) ? after.values : nil) || {}
      found = []
      older.each do |name, was|
        break if found.length >= limit

        still = newer[name]
        next if still.nil?

        relation = relation_of(was, still)
        next if relation.nil?

        found << Observation.new(
          symbol: name.to_s, parameter: "",
          exception: "", accepted_before: true, accepted_after: false,
          kind: KIND, relation: relation,
          # The witness, in the two releases' own words: what the value was rendered as on each
          # side. A report can only quote what was read, and these strings are the reading.
          accepted_output: rendering(was), observed_after: rendering(still)
        )
      end
      found
    end

    # Which relation the two readings differ under, or nil when they agree.
    #
    # The type is asked first because it is the stronger statement: `1` and `1.0` render
    # differently *and* are different kinds, and a report that called that a value change would
    # send a caller looking for a formatting difference.
    def self.relation_of(was, still)
      return "returns_type" if was["type"].to_s != still["type"].to_s
      return "returns_equal" if was["repr"].to_s != still["repr"].to_s

      nil
    end

    # `type repr`, which is what a reader needs and what a title can hold.
    def self.rendering(shape)
      "#{shape['type']} `#{shape['repr']}`"
    end
  end
end
