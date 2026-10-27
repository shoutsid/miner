# frozen_string_literal: true

module AgentsMiner
  # One failure, not twenty-three: clustering what a release did to its callers.
  #
  # A signature differential reports *call sites* — `Client(proxies=)`, `options(proxies=)`,
  # `post(proxies=)`, `request(proxies=)` — and one upstream decision produced all of them.
  # Filing those separately would pad a corpus with the same knowledge repeated, which is the
  # failure mode the duplicate rule exists to prevent, and it would make the one useful fact (the
  # argument was renamed) harder to find than the twenty-three echoes of it.
  #
  # So a finding is a *mechanism*, not a call site, and this module is where that decision is
  # made. The evidence kept is the arithmetic of the cluster: how many call sites broke, how many
  # were executing cleanly before, and which of them a candidate repair was actually run against.
  #
  # Nothing here knows about HTTP, the corpus, or a package's internals. It takes observations and
  # returns one finding, so the rule can be tested against hand-written observations rather than
  # against a live package.
  #
  module Mechanism
    # What the release did, which is what a reader needs to know.
    #
    # Named as the *change* rather than as the exception, because the exception is the symptom and
    # this is the cause: `TypeError` is what a caller sees, and "the argument was renamed" is what
    # they have to act on.
    #
    # Only the mechanisms the differential can actually establish are declared. A vocabulary that
    # advertised "the symbol was removed" without a pass that finds it would describe a corpus the
    # miner does not produce.
    #
    # The call site is the same and one argument has another name.
    PARAMETER_RENAMED = "parameter_renamed"
    # The argument is gone and nothing replaced it: the behaviour moved, or the caller was always
    # relying on something undocumented.
    PARAMETER_REMOVED = "parameter_removed"
    # A public name the module exported is gone, and something with a close name took its place.
    # `numpy` dropping `float_` for `float64` is this.
    SYMBOL_RENAMED = "symbol_renamed"
    # The name is gone with nothing to replace it. This is the migration that breaks an `import`,
    # and it is invisible to a signature diff because the thing that disappeared was never a
    # parameter.
    SYMBOL_REMOVED = "symbol_removed"
    # The name left the top level and the release still has it somewhere a caller can import from.
    # Different from a removal for the same reason a rename is: the fix exists, and "pin below this
    # release" would be the wrong advice.
    SYMBOL_MOVED = "symbol_moved"

    ALL = [PARAMETER_RENAMED, PARAMETER_REMOVED, SYMBOL_RENAMED, SYMBOL_REMOVED, SYMBOL_MOVED].freeze

    def self.valid?(value) = ALL.include?(value)

    def self.symbol?(value) = value.to_s.start_with?("symbol_")
  end

  # One call site, and what executing it against each version showed.
  #
  # `accepted_before` is what makes this evidence rather than a guess: the same call was run
  # against the release the caller is on and against the one they are moving to, and only a
  # parameter the older release *took* can have been taken away. A removed name that the older
  # release also refused is not a break — it was never there.
  #
  # `repair` is the same standard applied to the answer, and it is *only* set when the answer met
  # it: a name the interpreter refused in the old one's place is not a repair, so it does not live
  # in this field at all. It used to, beside a boolean that said whether it had worked, and the two
  # were read by different things — which is how the corpus came to tell callers to rename an
  # argument to a name that had never got past the failure. A candidate that was tried and failed
  # is still worth saying out loud, so it travels in `candidate`, which nothing mistakes for a fix.
  #
  # `traceback` is the interpreter's own output, kept verbatim. It is what the report hands a
  # reader, so it is evidence rather than a rendering of one.
  #
  class Observation
    FIELDS = %i[
      symbol parameter exception accepted_before accepted_after
      repair candidate moved traceback accepted_output kind
    ].freeze

    attr_reader(*FIELDS)

    def initialize(symbol:, parameter:, exception:, accepted_before:, accepted_after:,
                   repair: nil, candidate: nil, moved: nil, traceback: "",
                   accepted_output: "", kind: "argument")
      @symbol = symbol
      @parameter = parameter
      @exception = exception
      @accepted_before = accepted_before
      @accepted_after = accepted_after
      @repair = repair
      # The name that was tried in the old one's place and did not work there, when the release
      # offered one. Not a fix and never read as one: it exists so a report can say "the obvious
      # replacement was executed and refused", which is the difference between a reader trusting
      # the removal and going to look.
      @candidate = candidate
      # Where the newer release still exports this name, when it is not at the top level any more:
      # `numpy.exceptions.RankWarning` for a `numpy.RankWarning` that went away. A location, not a
      # spelling — the release was asked, and this is what it answered — which is why it is a fix
      # where a similar-looking name is not.
      @moved = moved
      @traceback = traceback
      @accepted_output = accepted_output
      # "argument" or "symbol": what kind of thing this release took away. The two passes produce
      # observations of one shape and the difference matters everywhere downstream — an argument is
      # something a call site passes, a symbol is something an import names — so it is a field
      # rather than something inferred from whether `parameter` happens to be empty.
      @kind = kind
      freeze
    end

    # The same observation with some fields changed.
    def with(**changes) = self.class.new(**to_h.merge(changes))

    def to_h = FIELDS.to_h { |field| [field, public_send(field)] }

    def ==(other) = other.is_a?(Observation) && to_h == other.to_h
    alias eql? ==
    def hash = to_h.hash
  end

  # A cluster, in the shape a report is filed from.
  #
  # Field names follow the corpus rather than this module's vocabulary, because the whole point of
  # the miner is that what it produces is a report: a caller reading one should not be able to tell
  # whether an agent or a harness found it, which is why `provenance`-style facts are stated
  # explicitly instead of left to be guessed.
  #
  # A `Data.define` would have made `self.library = …` a redesign of three call sites instead
  # of a port of one.
  class Finding
    REQUIRED = %i[library version mechanism title problem].freeze

    attr_accessor :library, :version, :mechanism, :title, :problem, :resolution,
      :ecosystem, :runtime, :parameter, :symbol, :replacement,
      :refused_candidate, :moved, :signatures, :call_sites,
      :repaired_call_sites, :trace, :notes

    def initialize(library: nil, version: nil, mechanism: nil, title: nil, problem: nil,
                   resolution: nil, ecosystem: "python", runtime: "", parameter: "",
                   symbol: "", replacement: nil, refused_candidate: nil, moved: nil,
                   signatures: [], call_sites: 1, repaired_call_sites: 0, trace: "",
                   notes: [])
      # What pydantic did with a missing field, kept as a refusal rather than a nil: a finding
      # without a title is a request the corpus would answer 422 to, and the miner would learn that
      # after the work of deriving it.
      REQUIRED.each do |field|
        value = binding.local_variable_get(field)
        raise ArgumentError, "Finding is missing #{field}" if value.nil?
      end
      unless Mechanism.valid?(mechanism)
        raise ArgumentError, "Finding mechanism #{mechanism.inspect} is not one of #{Mechanism::ALL.join(', ')}"
      end

      @library = library
      @version = version
      @mechanism = mechanism
      @title = title
      @problem = problem
      @resolution = resolution
      # Which package index this finding is about: `python` for PyPI, `ruby` for RubyGems. It is on
      # the finding rather than added when the report is filed, because it is a fact about what was
      # executed — a gem was installed with `gem install` and probed with `ruby` — and a report
      # whose index was decided at the last moment is one that can be sent to the wrong corpus.
      @ecosystem = ecosystem
      # The runtime the execution happened under, when it is not the process filling the report in:
      # a gem is probed by `ruby`, whose version a reader can act on and which this process cannot
      # report from its own environment.
      @runtime = runtime
      # The argument the release took away, and the one it renamed it to when the release itself
      # offered a close name. Fields rather than a phrase left in the prose: the solver links a
      # finding to somebody else's report on exactly this string, and reading it back out of a
      # sentence would turn a fact established by execution into a text-matching accident.
      @parameter = parameter
      # The exported name that was taken away, for a symbol finding. Empty for an argument finding,
      # because there the symbol is the *callable* the call site names — the thing that stayed — and
      # putting it here would make `subject` report the wrong half of the change.
      @symbol = symbol
      @replacement = replacement
      # For a removal: the closest name the new release does export, which was executed in the old
      # name's place and refused. Recorded so the report can say the search for a replacement
      # already happened and came up short, which is a stronger statement than "nothing close
      # exists" — and it is a *fact of an execution* rather than a judgement about spelling.
      @refused_candidate = refused_candidate
      # For a move: the importable path the name is at now.
      @moved = moved
      @signatures = signatures
      # How many call sites this one mechanism broke, and how many of them the repair was executed
      # against. A finding carried by one call site and a finding carried by eleven are the same
      # knowledge with different amounts of evidence behind it, and a reader deserves to see which
      # they have.
      @call_sites = call_sites
      @repaired_call_sites = repaired_call_sites
      @trace = trace
      @notes = notes
    end

    # What this release took away, whichever pass established it.
    #
    # An argument for an argument finding, the exported name for a symbol one. Every consumer
    # that wants "the thing that went missing" — the title, the fix, the report's attempt —
    # reads this rather than choosing between two fields, which is what stops a symbol finding
    # being described as a call with an argument.
    def subject = parameter.to_s.empty? ? symbol.to_s : parameter.to_s

    # The fields as a hash, which is what the corpus's request body is built from and what a
    # test compares two findings with.
    def to_h
      {
        "library" => library, "version" => version, "mechanism" => mechanism,
        "title" => title, "problem" => problem, "resolution" => resolution,
        "ecosystem" => ecosystem, "runtime" => runtime, "parameter" => parameter,
        "symbol" => symbol, "replacement" => replacement,
        "refused_candidate" => refused_candidate, "moved" => moved,
        "signatures" => signatures, "call_sites" => call_sites,
        "repaired_call_sites" => repaired_call_sites, "trace" => trace, "notes" => notes
      }
    end
  end

  # Group observations by the mechanism that produced them.
  #
  # Keyed on (mechanism, named parameter, repair-or-not) rather than on the call site, which is
  # what collapses twenty-three signatures into one finding. The symbol is deliberately *not* in
  # the key: `proxies` disappearing from `Client`, `get`, `post` and `request` in the same release
  # is one decision upstream, and reporting it four times would say otherwise.
  def self.cluster(observations)
    groups = {}
    observations.each do |observation|
      next if observation.accepted_after
      next unless observation.accepted_before

      key = [
        mechanism_of(observation),
        observation.parameter.to_s.empty? ? observation.symbol : observation.parameter,
        # The replacements this observation *offers*, not the one it settled on: two call sites of
        # one release that each had a different candidate executed are two different answers and
        # must not be merged into one report that can only quote one of them.
        observation.repair || observation.candidate
      ]
      (groups[key] ||= []) << observation
    end
    groups.values
  end

  # Which of the five things this release did, from what was executed.
  #
  # A repair that *ran* is what separates a rename from a plain removal, and whether the thing
  # taken away was an argument or an exported name is what separates the two families: they are
  # different failures for a caller (a keyword at a call site, a name at an import) and different
  # fixes.
  #
  # The test is `repair`, which by construction is only ever set for a candidate the interpreter
  # accepted in the old one's place. Reading a candidate that was tried and refused would call a
  # removal a rename and put the refusal in the title as the answer.
  def self.mechanism_of(observation)
    if observation.kind == "symbol"
      return Mechanism::SYMBOL_MOVED unless observation.moved.to_s.empty?

      return observation.repair ? Mechanism::SYMBOL_RENAMED : Mechanism::SYMBOL_REMOVED
    end
    observation.repair ? Mechanism::PARAMETER_RENAMED : Mechanism::PARAMETER_REMOVED
  end

  # One cluster as a report: the mechanism, the evidence, and the fix.
  #
  # The title states the mechanism and names the version, because that is the string the next
  # caller will search for — they are looking at an upgrade, not at a cluster number.
  #
  # `ecosystem` chooses the four or five words that are not the same in both languages, and
  # nothing else: a Python module *exports* a name and a gem *defines* one, a caller
  # re-imports it from Python and re-calls it in Ruby, and a Ruby subject is a reference
  # (`Colorize::ClassMethods`, `String#magenta`) rather than a bare member name. One template
  # with those words chosen, rather than a second summariser, so the two cannot drift into
  # describing one mechanism two ways.
  def self.summarise(library, version, from_version, group, ecosystem: "python")
    ruby = ecosystem == "ruby"
    mechanism = mechanism_of(group[0])
    subject = group[0].parameter.to_s.empty? ? group[0].symbol : group[0].parameter
    # How the thing that went away is named in a title.
    written = ruby ? subject : "#{library}.#{subject}"
    holds = ruby ? "defines" : "exports"
    rehome = ruby ? "Call" : "Import"
    # Read from `repair`, never from `candidate`: the first is a name that got past this failure and
    # the second is one that did not, and the whole difference between a fix and a coincidence
    # lives in that distinction.
    repaired = group.select { |item| item.repair }
    symbols = group.map(&:symbol).uniq.sort
    observed = group.find { |item| !item.traceback.to_s.empty? } || group[0]
    refused = group.select { |item| item.candidate && !item.repair }.map(&:candidate).uniq.sort
    replacement = repaired.empty? ? nil : repaired[0].repair

    title, resolution =
      case mechanism
      when Mechanism::PARAMETER_RENAMED
        [
          "#{library} #{version} renamed #{subject}= to #{replacement}=",
          # Deliberately weaker than the symbol branch, because the differential is: a keyword is a
          # name at a call site, and what this pass establishes about it is that the new signature
          # refuses the old name and accepts this one. Whether the two parameters *take* the same
          # thing is not something a probe passing a placeholder can establish, so the report does
          # not imply it — `pandas`'s `delim_whitespace=` (a flag) and `delimiter=` (a separator
          # string) are 0.64 apart and are not the same argument.
          "Rename the argument: `#{subject}=` is `#{replacement}=` in #{library} #{version}. " \
          "The new signature refuses `#{subject}=` and accepts `#{replacement}=`, which is the " \
          "nearest name to it; a call passing that name was executed against the new release and " \
          "got past this failure. That establishes the name and not the meaning, so check that " \
          "what you pass still does what it did."
        ]
      when Mechanism::PARAMETER_REMOVED
        [
          "#{library} #{version} removed the #{subject}= argument",
          "`#{subject}=` is gone in #{library} #{version}. " +
            refusal_clause(refused, spelling: "=",
              nothing: "No parameter in the new signature is spelled like it.") +
            " So this is not a rename: the argument's behaviour moved elsewhere or was dropped, " \
            "and a replacement, if there is one, is stated in the release notes. Pin below this " \
            "release until then."
        ]
      when Mechanism::SYMBOL_MOVED
        where = group[0].moved
        [
          "#{library} #{version} moved #{written} to #{where}",
          "#{rehome} it from where it lives now: `#{written}` is `#{where}` in #{library} " \
          "#{version}. The release no longer has the name where it was, and #{holds} the same " \
          "name from `#{where}`; reading it there was executed against the new release and " \
          "resolved. Nothing about the name itself changed."
        ]
      when Mechanism::SYMBOL_RENAMED
        [
          "#{library} #{version} renamed #{written} to #{replacement}",
          "#{rehome} the new name: `#{subject}` is `#{replacement}` in #{library} #{version}. " \
          "The release no longer has `#{written}` and #{holds} `#{replacement}`, which is built " \
          "from the same words — the only name it #{holds} that is — and a reference to it was " \
          "executed against the new release and resolved."
        ]
      else
        [
          "#{library} #{version} removed #{written}",
          "`#{written}` is gone in #{library} #{version}. " +
            refusal_clause(refused, spelling: "", nothing: "The release #{holds} no name") +
            " built from the same words, so this is not a rename: whatever the name stood for " \
            "moved, or was dropped, and a replacement, if there is one, is stated in the release " \
            "notes. Pin below this release, or call the replacement wherever it moved to."
        ]
      end

    problem = problem_for(library, version, from_version, observed, subject, symbols, group,
      ecosystem: ecosystem)
    Finding.new(
      library: library,
      version: version,
      mechanism: mechanism,
      ecosystem: ecosystem,
      # A report's title is bounded at 300 characters by the corpus's own model, and a finding that
      # exceeded it would be refused after the work of mining it.
      title: title[0, 300],
      problem: problem,
      resolution: resolution,
      parameter: group[0].parameter,
      symbol: Mechanism.symbol?(mechanism) ? group[0].symbol : "",
      replacement: replacement,
      refused_candidate: refused.empty? ? nil : refused[0],
      moved: mechanism == Mechanism::SYMBOL_MOVED ? group[0].moved : nil,
      call_sites: group.size,
      # Counts the call sites that *have* a repair, which for a removal is none of them: the field
      # is read as "how much of this fix is evidenced", and a cluster with no fix has nothing to
      # evidence.
      repaired_call_sites: repaired.size,
      notes: [note_for(group.size, repaired.size)],
      trace: observed.traceback.to_s.strip
    )
  end

  # How much evidence sits behind the finding, in one clause.
  #
  # A removal counts zero repairs and does not say so: "0 call sites had the replacement executed
  # successfully" reads like a search that failed, and the search is described in the resolution
  # instead, where a reader can see that it happened at all.
  def self.note_for(broken, repaired)
    sites = plural(broken, "call site")
    return "#{sites} broke" if repaired.to_i.zero?

    "#{sites} broke; #{plural(repaired, 'call site')} had the replacement executed " \
      "successfully against the new release"
  end

  # The clause that says what happened to the names that were tried.
  #
  # Two honest sentences, because the pass knows two different things. With no candidate it can
  # only say that nothing matched, and `nothing` is which kind of thing nothing matched. With one,
  # "nothing close exists" would be false and the refusal is the part worth printing — it is what
  # stops a reader spending an afternoon on the name that looks right, and it is an execution
  # rather than a judgement about spelling.
  def self.refusal_clause(refused, spelling:, nothing:)
    return nothing if refused.empty?

    names = refused.map { |name| "`#{name}#{spelling}`" }.join(", ")
    verb = refused.size == 1 ? "was" : "were"
    "#{names}, the closest there is to it, #{verb} executed in its place and refused"
  end

  # `1 call site` / `3 call sites`: a count a reader does not have to re-read.
  def self.plural(count, noun) = count == 1 ? "#{count} #{noun}" : "#{count} #{noun}s"

  # The mechanism and the evidence for it, in one statement.
  #
  # The count is stated because it is the difference between "somebody noticed this once" and "this
  # is what the release did to its callers", and the symbols are named because a caller whose site
  # is not the one shown needs to find theirs in the list. `subject` is what was taken away — an
  # argument or an exported name — and the two read differently because they break differently.
  def self.problem_for(library, version, from_version, observed, subject, symbols, group,
                       ecosystem: "python")
    ruby = ecosystem == "ruby"
    written = ruby ? subject : "#{library}.#{subject}"
    if observed.kind == "symbol"
      source = ruby ? "the gem's own definitions" : "the package's own exports"
      return "Upgrading #{library} from #{from_version} to #{version} breaks code that names " \
             "`#{written}`. Found by executing the same reference against both releases: it " \
             "resolved on #{from_version} and raised on #{version}. The name is read from " \
             "#{source}, so this is not a guess about what the release intended.\n\n" \
             "#{observed.exception}"
    end

    if ruby
      named = symbols.map { |symbol| "#{symbol}(#{subject}: …)" }.join(", ")
      binding = "The failure is raised while the keyword is bound, before the method runs, so " \
                "the traceback names no gem frame"
      spelling = "#{subject}:"
    else
      named = symbols.map { |symbol| "#{symbol}(#{subject}=…)" }.join(", ")
      binding = "The failure is raised while the arguments are bound, before the callable runs, " \
                "so the traceback names no package frame"
      spelling = "#{subject}="
    end
    "Upgrading #{library} from #{from_version} to #{version} breaks calls that pass " \
      "`#{spelling}`. Found by executing the same call against both releases: " \
      "#{plural(group.size, 'call site')} accepted it on #{from_version} and were refused on " \
      "#{version} (#{named}). #{binding} — the version here is the release that was executed." \
      "\n\n#{observed.exception}"
  end
end
