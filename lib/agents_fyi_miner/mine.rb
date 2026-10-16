# frozen_string_literal: true

require_relative "envs"
require_relative "findings"

module AgentsFyiMiner
  # Comparing two releases by executing both, and repairing what the comparison finds.
  #
  # The two releases are described by `Envs.inventory`, and every candidate is then *confirmed by
  # running it*: a parameter is only reported as taken away when the older release accepted it and
  # the newer one refused it. Nothing here reads a changelog, a diff of the source, or a version
  # string — a signature that changed without breaking a caller is not a finding, and a caller that
  # broke without the signature changing would be missed by any of those.
  #
  # The repair is mechanical and introspective: a parameter that disappeared from a signature is
  # most likely the same parameter under another name, and the release itself says which names it
  # now has. A repair is only accepted when executing the new name gets past the failure being
  # reported, so what a report hands a caller is an argument that was run, not one that was guessed.
  #
  # That last sentence is the whole product, and it was not true. The candidate came from
  # `difflib`, the confirmation came from an execution, and only the *mechanism* consulted the
  # confirmation — so a candidate that failed its own replay was still filed as "renamed X to Y",
  # with the failure quoted underneath it. Thirty-two of ninety-six live reports were of that
  # shape. The rule now has one home: `tried_replacement` splits a candidate into the fix it is or
  # the refusal it is, and nothing downstream can read the wrong half.
  module Mine
    # A candidate name has to be recognisably the old one. `proxies` -> `proxy` is 0.92 and is the
    # case this exists for; `proxies` -> `mounts` is 0.46 and is a coincidence of English.
    #
    # It is a *floor*, not a test. 0.60 admitted `delim_whitespace` -> `delimiter` (0.64), which is
    # right, and also `RankWarning` -> `hanning` (0.60), which is not, and no threshold separates
    # those two — the score is a property of the spellings and the thing being decided is a
    # property of the package. What actually separates them is the execution two lines below: a
    # real rename accepts the candidate and a coincidence does not.
    #
    REPAIR_SIMILARITY = 0.6

    # A probe that could not be made, said so, and is not a refusal.
    #
    # `confirm` and `confirm_symbol` answer with an `Observation`, and with `nil` for "the
    # change is not there" — checked, and not observed. A probe that never ran answered `nil`
    # too, and the two want opposite verdicts: *not observed* is a contradiction of the
    # report, while *never ran* is no evidence about anything.
    #
    # A sentinel rather than a flag beside the observation, because a caller has to *choose*
    # between three answers at the call site: `if observation` cannot be written by accident once
    # one of the three is a value of its own — and in Ruby `nil` is the only falsy value, so the
    # accidental reading is exactly what a flag would invite.
    class Unreached
      def to_s = "UNREACHED"
      def inspect = "UNREACHED"
    end

    UNREACHED = Unreached.new

    # Split a candidate into the fix it is, or the refusal it is.
    #
    # One place decides this, because the two fields it feeds mean opposite things and the corpus
    # was told the wrong one: `repair` is a name the interpreter accepted in the old one's place,
    # and `candidate` is a name it refused. An earlier version kept the candidate in `repair` and
    # the outcome in a boolean beside it, and the summariser read the candidate while the
    # resolution text read the boolean — so thirty-two reports said "renamed
    # `is_azure_document_intelligence_model` to `is_openai_finetune_model`" on the strength of
    # `difflib`, under an `AttributeError` whose own suggestion was a different name again.
    def self.tried_replacement(repair, confirmed)
      return [nil, nil] if repair.nil?

      confirmed ? [repair, nil] : [nil, repair]
    end

    # How many removed names the symbol pass will confirm per pair.
    #
    # Lower than the argument pass's ceiling because the work is the same per candidate — two
    # interpreter launches, plus one to try a replacement — and a major release can drop dozens of
    # export aliases at once. Sixty is enough to cover a release that removed everything anybody
    # imports, and it keeps a single pair's differential to a few minutes rather than half an hour.
    SYMBOL_LIMIT = 60

    # A name split into words: `setReconnect` -> set, reconnect. An acronym stays with itself
    # (`WebSocketURI` -> web, socket, uri) rather than splitting at every capital, because a rename
    # spells one word the way the module already spells it.
    WORD = /[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\d+/

    # --- the seam ---------------------------------------------------------------
    #
    # These thin delegations are the same namespace rather than a rewrite of one: a test stubs
    # `Mine.probe` and the differential two calls down uses the stub, which is what makes the
    # ported tests evidence about this file.
    #

    def self.inventory_for(env, suffix: "") = Envs.inventory(env, suffix: suffix)

    def self.probe(env, module_name, symbol, parameter, suffix: "")
      Envs.probe(env, module_name, symbol, parameter, suffix: suffix)
    end

    def self.probe_symbol(env, module_name, symbol, suffix: "")
      Envs.probe_symbol(env, module_name, symbol, suffix: suffix)
    end

    def self.moved(env, module_name, names, suffix: "")
      Envs.moved(env, module_name, names, suffix: suffix)
    end

    def self.answers?(output) = Envs.answers?(output)
    def self.refused_symbol?(output, symbol) = Envs.refused_symbol?(output, symbol)
    def self.refused_parameter?(output, parameter) = Envs.refused_parameter?(output, parameter)
    def self.exception_line(output) = Envs.exception_line(output)
    def self.traceback_of(output, root: nil) = Envs.traceback_of(output, root: root)

    # One field of an inventory entry.
    #
    # `envs.rb` owns the shape of an entry and this file only reads four fields of it, so the
    # reader is written to accept a `Hash` keyed by string or by symbol, or an object answering to
    # the name. That is not defensiveness for its own sake: the two files were written side by
    # side, and a differential that silently found no entries because one spelled `:name` and the
    # other `"name"` would report every release as having changed nothing — the one failure here
    # that looks like a quiet success.
    def self.field(entry, name)
      if entry.respond_to?(:[])
        return entry[name] if entry.respond_to?(:key?) && entry.key?(name)
        return entry[name.to_sym] if entry.respond_to?(:key?) && entry.key?(name.to_sym)
      end
      return entry.public_send(name) if entry.respond_to?(name)

      nil
    end

    # Every argument the older release accepted and the newer one refuses.
    #
    # Bounded by `limit` because the work is two subprocess launches per candidate: a release that
    # renamed an argument on a hundred callables would otherwise turn one finding into four hundred
    # interpreter starts.
    #
    # `suffix` is this examination's identity, passed to every probe so its scratch script cannot
    # be overwritten by another worker inspecting the same release — see `envs.probe`, where the
    # reason is written out at length.
    def self.observations_between(before, after, limit: 200, suffix: "")
      old_inventory = inventory_for(before, suffix: suffix)
      new_inventory = inventory_for(after, suffix: suffix)
      older = index_by_name(old_inventory.entries)
      newer = index_by_name(new_inventory.entries)
      # Every probe writes `import <module>`, and the module is the *import* name: the two releases
      # of one distribution agree on it unless the distribution renamed what it exports, in which
      # case the older name is the one a caller migrating is still writing.
      module_name = old_inventory.module
      found = []

      older.each do |name, old_entry|
        new_entry = newer[name]
        next if new_entry.nil? || field(new_entry, "kind") != field(old_entry, "kind")

        old_params = field(old_entry, "params")
        new_params = field(new_entry, "params")
        # Not readable in one of the two releases, so there is nothing to compare. The symbol pass
        # still covers the name itself. `nil` means "could not read" and not "accepts nothing":
        # comparing it as an empty mapping would report every unreadable callable as having lost
        # everything it never showed.
        next if old_params.nil? || new_params.nil?

        removed = old_params.keys - new_params.keys
        removed.sort.each do |parameter|
          break if found.length >= limit
          # A required parameter has no default, so a call omitting it is not a call this miner can
          # make on the old release's behalf.
          next if field(old_params[parameter], "required")

          observation = confirm(before, after, module_name, name, old_entry, new_entry, parameter,
            suffix: suffix)
          # `UNREACHED` is not an observation: a probe that never ran supports no finding either
          # way, which is what the miner always did with it — the difference is that it can no
          # longer be read as a non-refusal.
          found << observation if observation.is_a?(Observation)
        end
      end

      found + symbols_between(before, after, module_name, older, newer,
        limit: SYMBOL_LIMIT, suffix: suffix)
    end

    # Every public name the older release exported and the newer one does not.
    #
    # This is the other half of what a release takes away, and it is invisible to a signature diff:
    # a removed name was never a parameter, and the call site that broke is an `import`. It is the
    # shape of the break that matters most for a library's own aliases — `numpy` dropping `float_`
    # for `float64` — because a caller's code stops importing at all rather than failing at the
    # call.
    #
    # A name is kept only when the reference *resolves* on the older release and *raises* on the
    # newer one, which is the same standard the argument pass holds: a name the older release also
    # refused was never exported, and a name the newer release still resolves did not go anywhere.
    #
    # A name that is gone from the top level is then looked for one level down, in one batch for
    # the whole pass: `numpy.RankWarning` and `wsproto.Event` are still *there*, under
    # `numpy.exceptions` and `wsproto.events`, and a report that says "pin below this release"
    # about a name one path segment away from working is worse than useless. Where it is found is a
    # location that resolved, so it is a fix rather than a guess — which is why the answer to "did
    # it move" is asked of the release instead of guessed from the old name's spelling.
    def self.symbols_between(before, after, module_name, older, newer, limit: SYMBOL_LIMIT,
                             suffix: "")
      found = []
      older.each_key do |name|
        break if found.length >= limit
        next if newer.key?(name)

        observation = confirm_symbol(before, after, module_name, name, newer, suffix: suffix)
        found << observation if observation.is_a?(Observation)
      end

      # Only the names with no replacement of their own: a rename already says where the name went,
      # and a second answer to the same question is how two fields come to disagree.
      gone = found.select { |item| item.repair.nil? }.map(&:symbol)
      return found if gone.empty?

      places = moved(after, module_name, gone, suffix: suffix)
      found.map do |item|
        item.repair.nil? ? item.with(moved: places[item.symbol]) : item
      end
    end

    # Run the reference against both releases, and keep it only if it went away.
    #
    # Three answers, not two: the observation, `nil` for a change that is not there, and
    # `UNREACHED` for a probe that never reached the release. `answers?` is what separates the
    # third from the two the comparisons are made of. A probe that never ran — a timeout, a wheel
    # that would not install — is not evidence about anything, and read as a plain non-refusal it
    # says the opposite of the truth at both ends: the older release looks like it accepted a name
    # it was never asked about, and a replay that never happened looks like a candidate the release
    # accepted. The Ruby twin guards every one of these sites; this is the same guard, for the same
    # reason — and the third answer is now *returned*, so a caller that needs to say "nothing was
    # asked" can no longer be handed `nil`.
    def self.confirm_symbol(before, after, module_name, name, newer, suffix: "")
      was = probe_symbol(before, module_name, name, suffix: suffix)
      return UNREACHED unless answers?(was)
      return nil if refused_symbol?(was, name)

      now = probe_symbol(after, module_name, name, suffix: suffix)
      return UNREACHED unless answers?(now)
      return nil unless refused_symbol?(now, name)

      repair = best_symbol_replacement(name, newer)
      tried = nil
      unless repair.nil?
        replayed = probe_symbol(after, module_name, repair, suffix: suffix)
        if !answers?(replayed)
          # Neither a fix nor a refusal: nothing was executed, so the name is withheld rather than
          # promoted on the strength of a probe that could not be made. The removal itself is still
          # reported.
          repair = nil
        elsif refused_symbol?(replayed, repair)
          tried = repair
        end
      end
      repair, tried = tried_replacement(repair, tried.nil?)

      Observation.new(
        symbol: name,
        parameter: "",
        exception: exception_line(now),
        accepted_before: true,
        accepted_after: false,
        repair: repair,
        candidate: tried,
        traceback: traceback_of(now, root: after.root),
        accepted_output: traceback_of(was, root: before.root),
        kind: "symbol"
      )
    end

    # The exported name the newer release renamed this one to, or nothing.
    #
    # Character similarity is not evidence of a rename, and taking it for one is what put
    # `paramiko`'s removed `DSSKey` in the corpus as `ECDSAKey` — two names that share the word
    # "key", one a DSA key and one an ECDSA key, under a traceback that itself suggested `RSAKey` —
    # and `numpy`'s `RankWarning` as `hanning`, a warning class as a window function.
    #
    # What a rename is, instead, is the *same words* spelled differently: `setReconnect` for
    # `set_reconnect`, `random_lobster_graph` for `random_lobster`, `float64` for `float_`. So a
    # candidate has to be built from the old name's words — all of them, in order, and none of them
    # dropped — and it has to be the only candidate that is. Words rather than characters, because
    # `dss` and `ecdsa` are nothing like each other and the `key` they share is the one word every
    # name in the module has.
    #
    # Ties are refused rather than broken.
    def self.best_symbol_replacement(symbol, newer)
      wanted = words(symbol)
      exact = []
      partial = []
      newer.each_key do |name|
        next if name.start_with?("_")

        candidate_words = words(name)
        if candidate_words == wanted
          exact << name
        elsif same_words(wanted, candidate_words)
          partial << name
        end
      end
      [exact, partial].each do |tier|
        return tier[0] if tier.length == 1
      end
      nil
    end

    # A name as the words it is built from, digits flattened to one token.
    #
    # Flattened because a name that changed only its number is the same name —
    # `PytestRemovedIn9Warning` and `PytestRemovedIn10Warning` are one rename — and a reader is not
    # being asked to recognise the number.
    def self.words(name)
      name.scan(WORD).map { |word| word.match?(/\A\d+\z/) ? "0" : word.downcase }
    end

    # Whether `shorter` is `longer`'s words, in order, with none of its own missing.
    #
    # One direction only, and which direction is the rule: the candidate has to keep *every* word
    # of the old name. A name that **gained** a word was qualified further (`Binary` became
    # `LargeBinary`, `float_` became `float64`), and a name that lost one lost the part that
    # distinguished it — `xlrd.X12Book` is not `xlrd.Book` and `smart_open.smart_open` is not
    # `smart_open.open`, and both were filed as renames by the version of this that allowed either
    # direction. Two real renames go with them (`CythonMetaType` to `CythonType` and
    # `IdentityOptions` to `Identity`, which drop a word and are plausible), which is the same
    # trade as everywhere else in this pass: a fix that cannot be supported is worse than a removal
    # that can.
    #
    # `Enumerator#any?` rather than `next` — the walk consumes each candidate once, and `next` on
    # an Enumerator would run a Fiber, which cannot cross a thread boundary and this differential
    # runs inside worker threads.
    def self.same_words(shorter, longer)
      return false if shorter.empty? || shorter.length > longer.length

      rest = longer.each
      shorter.all? { |word| rest.any? { |candidate| word == candidate } }
    end

    # Run the call against both releases and keep it only if the release took it away.
    #
    # The same three answers as `confirm_symbol`, and the same guard: a probe that never ran is not
    # a non-refusal, so it neither stands for the older release having accepted the argument nor for
    # a candidate having been accepted in the newer one's place. See that method's comment.
    def self.confirm(before, after, module_name, name, old_entry, new_entry, parameter,
                     suffix: "")
      was = probe(before, module_name, name, parameter, suffix: suffix)
      return UNREACHED unless answers?(was)
      # The older release did not accept it either, so the diff of the signatures was misleading
      # and there is nothing to report.
      return nil if refused_parameter?(was, parameter)

      now = probe(after, module_name, name, parameter, suffix: suffix)
      return UNREACHED unless answers?(now)
      return nil unless refused_parameter?(now, parameter)

      repair = best_replacement(parameter, new_entry)
      tried = nil
      unless repair.nil?
        # A repair is only a repair when the interpreter accepted it, which is a weaker statement
        # than "the call works" and exactly the statement the report makes: it got past the failure
        # being reported. A candidate it refused is recorded as a candidate, so the report can say
        # the obvious name was tried rather than claim it as the answer — and a candidate the
        # interpreter never got to refuse is neither.
        replayed = probe(after, module_name, name, repair, suffix: suffix)
        if !answers?(replayed)
          repair = nil
        elsif refused_parameter?(replayed, repair)
          tried = repair
        end
      end
      repair, tried = tried_replacement(repair, tried.nil?)

      Observation.new(
        symbol: name,
        parameter: parameter,
        exception: exception_line(now),
        accepted_before: true,
        accepted_after: false,
        repair: repair,
        candidate: tried,
        # Kept verbatim from the run, so what a reader is shown is the interpreter's output rather
        # than the miner's description of it.
        traceback: traceback_of(now, root: after.root),
        accepted_output: traceback_of(was, root: before.root)
      )
    end

    # The parameter the newer release most likely renamed this one to.
    #
    # The nearest name the release offers, which is the one thing here that is allowed to be a
    # judgement about spelling — because the name it produces is *executed* before it is believed,
    # and a wrong guess costs one probe rather than a filed lie. `SequenceMatcher.ratio` as
    # `difflib.get_close_matches` computes it (see `similarity`).
    def self.best_replacement(parameter, new_entry)
      candidates = close_matches(parameter, parameter_names(new_entry),
        n: 1, cutoff: REPAIR_SIMILARITY)
      candidates.first
    end

    # The parameter names an inventory entry carries, whichever index recorded it.
    #
    # Three shapes, one answer, and the reason they differ is worth writing down: PyPI's
    # inventory records a mapping — `{name: {"required": true}}`, whose *keys* are what
    # Python's `list(entry["params"])` yielded — while the gem inventory records a flat list
    # of keyword names, and `None` still means the signature could not be read at all. Reading
    # them as one shape is how a `String` reached `Array#first` and every Ruby keyword rename
    # failed with `undefined method 'first'`.
    def self.parameter_names(new_entry)
      params = field(new_entry, "params")
      return [] if params.nil?
      return params.keys if params.is_a?(Hash)

      Array(params).map { |name| name.is_a?(Array) ? name.first : name }
    end

    # `difflib.get_close_matches`: the possibilities scoring at or above `cutoff`, best first.
    #
    def self.close_matches(word, possibilities, n: 3, cutoff: 0.6)
      return [] unless n.positive?

      scored = possibilities.filter_map do |candidate|
        score = similarity(candidate, word)
        [score, candidate] if score >= cutoff
      end
      # Descending by score, and stable: `heapq.nlargest` does not reorder equal scores, so a tie
      # answers with the possibility that came first.
      scored.each_with_index.sort_by { |(score, _), index| [-score, index] }
            .first(n)
            .map { |(_, candidate), _| candidate }
    end

    # `difflib.SequenceMatcher.ratio()`: `2M/T`, where `M` is the number of characters in the
    # matching blocks and `T` the length of both sequences.
    #
    # The blocks come from the same recursion `difflib` uses — repeatedly take the longest matching
    # run, then recurse into what is left on either side — and the tie-break is its own: earliest in
    # the left sequence, then earliest in the right. Written out rather than approximated with a
    # character histogram because the score decides a *candidate*, and a histogram would rank
    # `delimiter` and `delim_whitespace` differently from the table this rule was measured against.
    def self.similarity(left, right)
      left = left.to_s
      right = right.to_s
      total = left.length + right.length
      return 1.0 if total.zero?

      2.0 * matching_size(left, right, 0, left.length, 0, right.length) / total
    end

    def self.matching_size(left, right, alo, ahi, blo, bhi)
      best = longest_match(left, right, alo, ahi, blo, bhi)
      size = best[2]
      # The `if k:` guard in `difflib`'s `get_matching_blocks`, and it is load-bearing rather than
      # tidiness: with no character in common the match is `[alo, blo, 0]`, which makes the
      # right-hand window *the window it was asked about* — so without this the recursion has no
      # base case and dies with `SystemStackError: stack level too deep` instead of scoring a
      # candidate. Two identifiers that share nothing is the ordinary case for a wrong guess.
      return 0 if size.zero?

      size += matching_size(left, right, alo, best[0], blo, best[1]) if best[0] > alo && best[1] > blo
      size += matching_size(left, right, best[0] + size, ahi, best[1] + size, bhi) if best[0] + size < ahi && best[1] + size < bhi
      size
    end

    # The longest run common to both windows, as `[left index, right index, length]`.
    #
    # Brute force over the smaller window with a growing-run check, which is what `difflib` does
    # with a junk-aware version of the same search; the arguments this is asked about are
    # identifiers, so the quadratic cost is a handful of comparisons per candidate.
    def self.longest_match(left, right, alo, ahi, blo, bhi)
      best = [alo, blo, 0]
      (alo...ahi).each do |i|
        (blo...bhi).each do |j|
          size = 0
          size += 1 while i + size < ahi && j + size < bhi && left[i + size] == right[j + size]
          next unless size > best[2]
          # Strictly greater, so the earliest pair wins a tie — `difflib`'s own rule, and the one
          # that makes this return the same blocks it does.
          best = [i, j, size]
        end
      end
      best
    end

    # The findings one upgrade produces, clustered so each is a mechanism once.
    #
    # `AgentsFyiMiner.cluster` and `AgentsFyiMiner.summarise` are named with their owner rather
    # than called bare, and that is not a style choice: a bare call inside this module looks for
    # the method on `Mine`, which is the receiver — the lexical scope `AgentsFyiMiner` that holds
    # them is where the *constants* come from and not where a method call goes.
    def self.findings_between(library, from_version, to_version, before, after, suffix: "")
      observations = observations_between(before, after, suffix: suffix)
      AgentsFyiMiner.cluster(observations)
                     .map { |group| AgentsFyiMiner.summarise(library, to_version, from_version, group) }
    end

    # The inventory's entries by name, for the two lookups the passes do.
    def self.index_by_name(entries)
      (entries || []).to_h { |entry| [field(entry, "name"), entry] }
    end
  end
end
