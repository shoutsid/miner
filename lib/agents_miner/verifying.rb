# frozen_string_literal: true

require_relative "envs"
require_relative "errors"
require_relative "ledger"
require_relative "mine"
require_relative "reporting"
require_relative "resolver"
require_relative "rubyenvs"
require_relative "solving"

module AgentsMiner
  # Confirming somebody else's report by executing what it claims.
  #
  # A corpus's trust ladder ends at "other operators reproduced this", and until the verifier
  # existed nothing on this machine could stand in that position: the miner files findings, and the
  # service counts a confirmation only from an operator that is *not* the author, so every report in
  # the corpus sat at `resolved_unverified` with the top of the ladder unreachable. This module is
  # the other operator. It reads a report that already carries a fix, reconstructs the claim from
  # the report's own fields, runs it against the releases the claim is about, and records what
  # happened — including when what happened is nothing.
  #
  # Two methods, shipped as two operators because the service counts distinct ones:
  #
  # * `as-reported` runs the claim as the report writes it — the call sites it names, or the
  #   reference it quotes — against the release it was reported against, and then runs the *fix*:
  #   the replacement argument, or the path the fix says the name went to. Where the fix names no
  #   replacement, the older release the report came from is read instead, because "this release
  #   took it away" is a claim about a change and one release cannot establish it.
  # * `searched` ignores the report's prose and re-derives the claim from the two releases: which
  #   call sites accepted the argument before and refuse it now, and whether a name that resolved on
  #   the older release fails on the newer one. That is the check that catches a report whose own
  #   account has drifted while its claim is still true, and the one that contradicts a claim that
  #   was never true.
  #
  # Both are more than "the release does not accept this name". That sentence is true of every
  # argument in existence — nothing accepts a keyword it has never had — so a verifier built on it
  # would confirm every removal in the corpus while looking like independent work. Everything here
  # is a *change* between two releases, or a fix executed against the release it is for.
  #
  # Neither can fabricate a confirmation: every verdict is the interpreter's own output, and both
  # methods return `did_not_reproduce` when the execution disagrees. What they will not do is guess
  # — a report whose claim cannot be turned into something executable gets no vote at all, which is
  # the only honest answer to "I could not check this".
  #
  # Nothing here talks to the corpus. It takes a report and a way to build releases, and returns a
  # verdict, so what a confirmation *means* can be tested against records rather than against a
  # live server.
  module Verifying
    # The two ways of checking a claim, named for what they do rather than for who runs them: a
    # name that describes the *method* is what makes the operator's own evidence readable years
    # later.
    AS_REPORTED = "as-reported"
    SEARCHED = "searched"
    ROLES = [AS_REPORTED, SEARCHED].freeze

    # What a check decided, in the corpus's own vocabulary where it has one.
    NO_CLAIM = "no_claim" # ours: nothing executable could be built, so no vote

    # The status a report has to be in for a confirmation to mean anything: a fix is in force and
    # it has not been confirmed yet. `open` reports are dropped rather than settled — the change
    # feed re-announces a report the moment it gains a fix — and a report already at
    # `resolved_verified` has the confirmations it needs.
    UNVERIFIED_STATUS = "resolved_unverified"

    # A report's version when nobody could name one. The service writes this literal, and a claim
    # about it cannot be positioned against a release.
    UNKNOWN_VERSION = "unknown"

    # The call sites the report itself names, in its own vocabulary:
    # "(`AsyncClient(app=…), Client(app=…))`". The parameter is matched as written, so a report
    # whose list mentions a different argument than the one its symptoms carry yields no sites
    # rather than the wrong ones. A template rather than a pattern because the parameter is
    # escaped into it per call — a name is a name, not a regex.
    SITE = "([A-Za-z_][A-Za-z0-9_.]*)\\(%<parameter>s=…\\)"

    # How the interpreter reports a public name that is no longer there. Read from the *report*,
    # because a mined report quotes the interpreter verbatim — this is the failure a reader sees,
    # not a paraphrase of it. The two spellings are the two ways a caller can ask: an attribute
    # reference and a `from` import.
    #
    # The word "module" is matched case-insensitively, and that is not cosmetic: a package that
    # defines its own module-level `__getattr__` writes this message itself, in its own style.
    # `modal` raises `AttributeError: Module 'modal' has no attribute 'Stub'. Use \`modal.App\`
    # instead.` — a capital M — and a case-sensitive pattern read that as "this report names no
    # reference", which cast no vote at all on a report that was true and left it the only
    # unconfirmed report in the corpus.
    NO_ATTRIBUTE = /(?i:module) +'([A-Za-z_][A-Za-z0-9_.]*)' +has no attribute +'([A-Za-z_][A-Za-z0-9_]*)'/

    # The other place a mined report names the reference: the sentence it opens with, "breaks code
    # that names `modal.Stub`". Read second rather than first, because the interpreter's line says
    # which *module* the failure was raised against while this one is written with the
    # distribution's name (`graphql-core.find_deprecated_usages` is imported as
    # `graphql.find_deprecated_usages`), and a probe built from the wrong one fails to import — no
    # vote, rather than a wrong one.
    NAMED_REFERENCE = /names `([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)`/
    CANNOT_IMPORT = /cannot import name '([A-Za-z_][A-Za-z0-9_]*)' from '([A-Za-z_][A-Za-z0-9_.]*)'/

    # Where a fix says the name went: "it is `sqlalchemy.sql.schema.IdentityOptions` in sqlalchemy
    # 1.4.54". A dotted term ending in the name being asked about, so a sentence that mentions a
    # module without naming the thing is not read as a location.
    DOTTED_TERM = /`([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)`/

    # The replacement an argument rename's fix names: "Rename the argument: `on_stop=` is
    # `on_reset=` in prompt-toolkit 2.0.10." Both sides are backticked *with* their `=`, which is
    # what keeps a sentence about a symbol from being read as one about an argument, and the other
    # way round.
    REPLACEMENT = /`([A-Za-z_][A-Za-z0-9_]*)=` is `([A-Za-z_][A-Za-z0-9_]*)=`/

    # How many call sites a verdict quotes before it stops listing them. The count is the evidence;
    # the names are what a reader checks.
    NAMED_SITES = 3

    # How many candidate call sites the re-derived check runs. Bounded because each is two
    # interpreter starts, and a major release can remove one argument from dozens of callables:
    # past this many, the count in the evidence is the answer.
    SITE_LIMIT = 40

    # The mechanisms a gem's report can carry, and the only ones this module will read out of one.
    # The Ruby client files symbol findings: its keyword pass tells a caller which keywords a
    # *method* takes, which is not a call-site analysis, so a parameter claim about a gem has no
    # execution behind it to check.
    RUBY_SYMBOL_KINDS = %w[symbol_removed symbol_renamed symbol_moved].freeze

    # A Ruby reference written in a report's prose, backticked the way both the problem and the fix
    # write it: `` `Bundler::Graph` ``, `` `Colorize::ClassMethods#parse` ``,
    # `` `Rake::Win32.normalize` ``. The separator is what tells a constant from a method, so it is
    # kept rather than normalised.
    RUBY_TERM = /`([A-Za-z_][A-Za-z0-9_:]*(?:[#.][a-z_][A-Za-z0-9_]*[?!]?)?)`/

    # An argument name as a report writes it, with the `=` a call would have.
    WRITTEN_ARGUMENT = /([A-Za-z_][A-Za-z0-9_]*)\s*=/

    # The sentence every mined report writes: "Upgrading {library} from {from} to {to}".
    FROM_PROSE = /from (\S+) to (\S+)/

    # What a report says, in the form an execution can test.
    #
    # `parameter` and `symbol` are the two *probe* shapes a mined report has — an argument a call
    # site passed, or a name an import referred to — and exactly one of them is set. Everything
    # else is evidence about that one thing: where the report says the failure is (`sites`,
    # `module_name`), where the fix says the name went (`moved`), what the fix says to call instead
    # (`replacement`), and the release the report says it came from (`from_version`). A resolver
    # claim sets neither: it is about two releases, not a call in one.
    #
    # `ecosystem` says which index the two releases belong to, because everything below it
    # differs: a gem is installed with `gem` and reached with `require`, its name is a
    # *reference* (`Bundler::Graph`, `Bundler::CurrentRuby#ruby_35_18?`) rather than a dotted
    # path, and the check that runs is `RubyEnvs.probe` rather than a Python subprocess.
    # `reference` is that reference as the release spells it, and `reference_kind` is which of
    # Ruby's three shapes it is — a constant, an instance method or a singleton method —
    # because a search for where a name went has to look in the right half of the release's
    # surface.
    #
    # `Data` gives the value equality the frozen dataclass had, and `of` is where the defaults
    # live.
    # **A resolver claim is the third shape, and it is not a reference at all.** A Rails move can
    # fail while Bundler is choosing versions, before an application is installed or booted; the
    # thing the report is about is two releases that cannot sit together. `resolver_gem` and its
    # version are the one the report says was refused, and `version` is the Rails release it was
    # refused beside. All three are empty on every other claim, which is why `resolver?` is the
    # branch every reader asks first.
    Claim = Data.define(:library, :version, :parameter, :symbol, :module_name, :sites,
      :replacement, :moved, :from_version, :ecosystem, :reference,
      :reference_kind, :resolver_gem, :resolver_version, :resolver_requirement) do
      def self.of(library:, version:, parameter: "", symbol: "", module_name: "", sites: [],
                  replacement: "", moved: "", from_version: "", ecosystem: "python",
                  reference: "", reference_kind: "", resolver_gem: "", resolver_version: "",
                  resolver_requirement: "")
        new(library: library, version: version, parameter: parameter.to_s, symbol: symbol.to_s,
          module_name: module_name.to_s, sites: Array(sites).freeze, replacement: replacement.to_s,
          moved: moved.to_s, from_version: from_version.to_s, ecosystem: ecosystem,
          reference: reference.to_s, reference_kind: reference_kind.to_s,
          resolver_gem: resolver_gem.to_s, resolver_version: resolver_version.to_s,
          resolver_requirement: resolver_requirement.to_s)
      end

      # Whether this is the resolver shape rather than a call site or a reference.
      def resolver? = !resolver_gem.to_s.empty?

      def kind
        return "resolver" if resolver?

        parameter.to_s.empty? ? "symbol" : "argument"
      end

      # Whether this claim is about a gem rather than a package.
      def is_ruby? = ecosystem == "ruby"

      # The last segment of a Ruby reference, which is what a message names.
      def leaf = RubyEnvs.leaf_of(reference)

      # The thing the release supposedly took away, as the title spells it.
      def subject
        return "#{resolver_gem} #{resolver_version}" if resolver?

        parameter.to_s.empty? ? symbol : parameter
      end

      # The reference the report quoted the interpreter raising about.
      def dotted
        if module_name.to_s.empty? || symbol.to_s.empty?
          ""
        else
          "#{module_name}.#{symbol}"
                   end
      end
    end

    # What running the claim showed, ready to be a vote or to be withheld.
    #
    # `executed` is the evidence: what was run and what the interpreter said about it. It travels
    # into the verification's notes verbatim, because a confirmation whose evidence is a description
    # of an execution is worth less than one that carries the execution.
    #
    # `unreachable` separates the two reasons a verdict can carry no vote. One is that the report has
    # nothing executable in it — a fact about the report, which the loop settles by dropping it and
    # picking up a revision when the feed announces one. The other is that a probe did not run or a
    # release could not be read — a fact about this machine, which has to be *retried*: dropping it
    # takes the report out of that operator's backlog for good, because nothing re-adds a report
    # except a change to it and no attempt record is written for the bound to work from. One word,
    # `NO_CLAIM`, covers both, so the difference has to be a field.
    Verdict = Data.define(:outcome, :executed, :detail, :unreachable) do
      def self.of(outcome:, executed: "", detail: "", unreachable: false)
        new(outcome: outcome, executed: executed.to_s, detail: detail.to_s,
          unreachable: unreachable)
      end

      # Whether this is something the corpus can be told.
      def vote? = [Ledger::REPRODUCED, Ledger::PARTIAL, Ledger::DISSENTED].include?(outcome)
    end

    # The executable claim inside a report, or nothing if it has none.
    #
    # Deliberately narrow. Every branch is a fact the report states about itself — its kind, its
    # version, the argument its symptoms say an error refused, the reference its quoted
    # interpreter line names, where its fix says the name went — and anything that has to be
    # inferred is refused rather than guessed: a report carrying two refused arguments could be
    # about either, and a confirmation of the wrong one is a true sentence about a different
    # question.
    def self.claim_for(report)
      # **The resolver shape is read before the subject-kind guard, because it is not a package
      # claim.** A Rails move's failure is filed as `platform` — the thing that broke is the move,
      # not the gem — and the old guard refused every one of them before reading the output that
      # names the two releases. The claim is still narrow: `Resolver.claim_for` needs Bundler's own
      # `Because … depends on rails …` sentence and a Rails pin, or it returns nothing.
      if field(report, "ecosystem").to_s == "ruby"
        target = Resolver.claim_for(report)
        unless target.nil?
          return Claim.of(library: "rails", version: target.rails_version, ecosystem: "ruby",
            resolver_gem: target.gem, resolver_version: target.gem_version,
            resolver_requirement: target.requirement)
        end
      end

      return nil unless field(report, "subject_kind", "package").to_s == "package"

      library = field(report, "library").to_s.strip
      version = field(report, "version").to_s.strip
      return nil if library.empty? || version.empty? || version == UNKNOWN_VERSION

      problem = field(report, "problem").to_s
      resolution = field(report, "resolution").to_s
      came_from = from_version_of(report, version)

      if field(report, "ecosystem").to_s == "ruby"
        return ruby_claim(report, library: library, version: version, from_version: came_from)
      end

      parameters = Solving.named_arguments(field(report, "signatures"))
      return nil if parameters.length > 1

      unless parameters.empty?
        # The *spelling* the report writes, not the token the corpus stores: an argument name
        # reaches the signatures lowercased (`documentAST` is stored as `documentast`), and a call
        # written with the stored spelling is not the call the report is about — it would not even
        # match the call sites the report names, so the check would abstain on a report it can
        # verify.
        parameter = spelling(problem, parameters.first)
        return Claim.of(library: library, version: version, parameter: parameter,
          sites: sites(problem, parameter),
          replacement: replacement(resolution), from_version: came_from)
      end

      quoted = quoted_reference(problem)
      return nil if quoted.nil?

      module_name, symbol = quoted
      # Every way the report's own body writes the name it says is gone, because a fix cannot be
      # the thing that is broken and the report spells that thing more than once. The title is
      # deliberately left out: a move's title names the destination ("toml 0.10.2 moved
      # toml.InlineTableDict to toml.decoder.InlineTableDict"), so reading it here would refuse
      # the very fix the report offers.
      spelled = written_paths(problem, symbol) +
                written_paths(field(report, "attempted").to_s, symbol)
      Claim.of(library: library, version: version, symbol: symbol, module_name: module_name,
        moved: moved(resolution, symbol, "#{module_name}.#{symbol}", spelled: spelled),
        from_version: came_from)
    end

    # Whether this report is one this operator can and should confirm.
    #
    # Its own reports are not: the service counts a confirmation only from an operator other than
    # the author, so a vote here would write a row no number reads while looking, in the corpus,
    # like independent reproduction.
    def self.needs_confirmation?(report, operator_id)
      return false if field(report, "hidden")

      return false if Solving.ours?(report, operator_id)

      return false unless field(report, "status").to_s == UNVERIFIED_STATUS

      !claim_for(report).nil?
    end

    # Run one operator's check of one claim, building the releases it needs.
    #
    # `build` turns a version into an environment and is passed in rather than imported, so this
    # module can be driven against fakes and so the environments a check needs are built by the
    # caller that knows where they live. It raises `Errors::MinerError` when a release cannot be
    # installed, which is the caller's answer to give: a release that will not build is not
    # evidence about a report.
    def self.check(claim, role, build:, suffix: "")
      # **A resolver claim is checked by the resolver, not by a release environment.** It is about
      # two versions rather than about code inside one, so a `build` of either release would be the
      # wrong tool — and the gem the report says was refused is not the report's library, so the
      # ledger's unbuildable-release rule must not see it as one.
      return Resolver.check(claim, role, suffix: suffix) if claim.resolver?

      if claim.is_ruby?
        # A gem's claim is a reference to run, in both roles — there is no call-site analysis to
        # do, because the Ruby client never files an argument claim.
        return role == AS_REPORTED ? ruby_reference(claim, build: build, suffix: suffix)
                                   : ruby_searched(claim, build: build, suffix: suffix)
      end
      return as_reported(claim, build: build, suffix: suffix) if role == AS_REPORTED
      return searched(claim, build: build, suffix: suffix) if role == SEARCHED

      raise ArgumentError, "unknown verification role #{role.inspect}"
    end

    # The verification to send, with its evidence attached.
    #
    # `environment` says what the operator did and which releases it did it against, because a
    # confirmation is read by somebody deciding whether to trust a number: "2 operators confirmed"
    # with no way to see what they ran is a fact about arithmetic rather than about the release.
    # `notes` carries the execution itself.
    def self.payload(verdict, claim, role)
      if claim.resolver?
        releases = "rails #{claim.version} with #{claim.resolver_gem} #{claim.resolver_version}"
        how = if role == AS_REPORTED
          "ran `bundle lock` against a minimal Gemfile naming #{releases}"
        else
          "read #{claim.resolver_gem} #{claim.resolver_version}'s gemspec from rubygems.org and " \
            "evaluated its rails requirement against #{claim.version}"
        end
        return {
          "outcome" => verdict.outcome,
          "environment" => ("#{RubyEnvs.runtime}; #{how}, by an operator that did not file the " \
                            "report (method: #{role})"),
          # The service's field is bounded at 2,000 characters, and the conflict is at the head of
          # the output rather than its tail. A refusal from validation would turn a real vote into
          # a skipped report, so the evidence is clipped here rather than left to the service.
          "notes" => verdict.executed.to_s[0, Resolver::NOTES_LIMIT].to_s
        }
      end

      releases = "#{claim.library} #{claim.version}"
      if !claim.from_version.empty? && claim.from_version != claim.version
        releases = "#{claim.library} #{claim.from_version} and #{claim.library} #{claim.version}"
      end
      runtime = claim.is_ruby? ? RubyEnvs.runtime : Reporting.python_runtime
      {
        "outcome" => verdict.outcome,
        "environment" => (
          "#{runtime}; verified by executing against #{releases}, " \
          "by an operator that did not file the report (method: #{role})"
        ),
        "notes" => verdict.executed
      }
    end

    # --- the Ruby index, whose claim is a reference rather than a call site ------------------

    # The executable claim inside a gem's report, when it has one.
    #
    # Narrow like the PyPI path, and narrower still in one respect: only a *symbol* mechanism is
    # read. The Ruby client files symbol findings and nothing else — its keyword pass is not a
    # call-site analysis, so a parameter claim about a gem has no execution behind it — and a
    # report about a gem that names no reference is refused rather than guessed at.
    #
    # The subject is the report's own field rather than a substring of its prose, because the
    # miner stored the reference it executed (`Bundler::Graph`,
    # `Bundler::CurrentRuby#ruby_35_18?`) and reading it back out of a sentence would turn a fact
    # established by execution into a text-matching accident.
    def self.ruby_claim(report, library:, version:, from_version:)
      return nil unless RUBY_SYMBOL_KINDS.include?(field(report, "change_kind").to_s)

      subject = field(report, "subject").to_s.strip
      entry = RubyEnvs.entry_of(subject)
      return nil if entry.nil?

      reference = entry.expression
      return nil if reference.nil?

      # Every way the report's own body writes the name it says is gone, so a fix cannot be
      # the thing that is broken.
      spelled = ruby_written(field(report, "problem").to_s, subject) +
                ruby_written(field(report, "attempted").to_s, subject)
      Claim.of(library: library, version: version, symbol: subject, ecosystem: "ruby",
        reference: reference, reference_kind: entry.kind,
        moved: ruby_moved(field(report, "resolution").to_s, subject, spelled),
        from_version: from_version)
    end

    # A gem's claim, checked as the report writes it: run the reference in both.
    #
    # The same three outcomes the PyPI path reaches, with the same rule about the third: a probe
    # that never got as far as the release answering is not evidence about anything, so it
    # abstains rather than dissenting. What differs is only how a name is reached — `require` and a
    # reference rather than an import and a dotted path — and a gem that will not load is
    # `unreached`, which is the case the whole `answers?` distinction exists for.
    def self.ruby_reference(claim, build:, suffix: "")
      if claim.reference.empty?
        return Verdict.of(outcome: NO_CLAIM, detail: "the report names no reference to run")
      end

      reported = build.call(claim.library, claim.version)
      output = RubyEnvs.probe(reported, claim.reference, suffix: "#{suffix}-reported")
      if !RubyEnvs.answers?(output)
        return Verdict.of(
          outcome: NO_CLAIM,
          detail: "#{claim.library} #{claim.version} could not be asked about " \
                  "`#{claim.reference}`: " \
                  "#{RubyEnvs.exception_line(output).empty? ? 'the probe did not run' : RubyEnvs.exception_line(output)}",
          unreachable: true
        )
      end
      if !RubyEnvs.refused_symbol?(output, claim.reference)
        return Verdict.of(
          outcome: Ledger::DISSENTED,
          executed: "Ran a reference to `#{claim.reference}` against #{claim.library} " \
                    "#{claim.version}: it resolved, so the release the report names still " \
                    "defines the name it says it lost.",
          detail: "the name the report says is gone is still there"
        )
      end
      raised = RubyEnvs.exception_line(output)

      unless claim.moved.empty?
        # The fix names a reference. A destination that does not resolve is a fix that cannot be
        # applied, which is worse than no fix — so it is executed on the same release, and a
        # failure to resolve is what makes this a partial.
        entry = RubyEnvs.entry_of(claim.moved)
        expression = entry&.expression
        found = expression ? RubyEnvs.probe(reported, expression, suffix: "#{suffix}-moved") : ""
        if expression.nil? || RubyEnvs.unreached?(found)
          return Verdict.of(
            outcome: Ledger::REPRODUCED,
            executed: "Ran a reference to `#{claim.reference}` against #{claim.library} " \
                      "#{claim.version}: #{raised} — the failure this report describes. The " \
                      "fix could not be run in this environment: " \
                      "#{RubyEnvs.exception_line(found).empty? ? 'the probe did not run' : RubyEnvs.exception_line(found)}."
          )
        end
        if !RubyEnvs.resolves?(found)
          return Verdict.of(
            outcome: Ledger::PARTIAL,
            executed: "Ran a reference to `#{claim.reference}` against #{claim.library} " \
                      "#{claim.version}: #{raised} — the failure is real. The fix was run and " \
                      "did not resolve: reading `#{claim.moved}` on the same release raised " \
                      "#{RubyEnvs.exception_line(found).empty? ? 'nothing' : RubyEnvs.exception_line(found)}.",
            detail: "the problem reproduces but the reference the fix names does not resolve"
          )
        end
        return Verdict.of(
          outcome: Ledger::REPRODUCED,
          executed: "Ran a reference to `#{claim.reference}` against #{claim.library} " \
                    "#{claim.version}: #{raised} — the failure this report describes. Ran the " \
                    "fix from the same release: `#{claim.moved}` resolved, so the name is " \
                    "still reachable where the report says it is."
        )
      end

      if claim.from_version.empty?
        return Verdict.of(
          outcome: NO_CLAIM,
          detail: "the reference raises, but the report names no release it came from and no " \
                  "fix, so nothing establishes that the name was there before"
        )
      end
      older = build.call(claim.library, claim.from_version)
      was = RubyEnvs.probe(older, claim.reference, suffix: "#{suffix}-older")
      if !RubyEnvs.answers?(was)
        return Verdict.of(
          outcome: Ledger::REPRODUCED,
          executed: "Ran a reference to `#{claim.reference}` against #{claim.library} " \
                    "#{claim.version}: #{raised} — the failure this report describes. " \
                    "#{claim.library} #{claim.from_version} could not be asked whether the " \
                    "name resolved there: " \
                    "#{RubyEnvs.exception_line(was).empty? ? 'the probe did not run' : RubyEnvs.exception_line(was)}."
        )
      end
      if RubyEnvs.refused_symbol?(was, claim.reference)
        return Verdict.of(
          outcome: Ledger::DISSENTED,
          executed: "Ran a reference to `#{claim.reference}` against #{claim.library} " \
                    "#{claim.from_version}, the release this report says it came from: it " \
                    "raises there too, so the name was already gone and nothing changed " \
                    "between the two. #{RubyEnvs.exception_line(was)}",
          detail: "the name was already gone on the release the report came from"
        )
      end
      Verdict.of(
        outcome: Ledger::REPRODUCED,
        executed: "Ran a reference to `#{claim.reference}` against #{claim.library} " \
                  "#{claim.from_version}: that release resolved it. Against #{claim.library} " \
                  "#{claim.version}: #{raised} — the same reference, resolved before and " \
                  "raising now, which is the break this report describes."
      )
    end

    # Re-derive the gem's claim from the two releases, ignoring the report's account.
    #
    # Where the PyPI side asks the older release's call sites, this asks the older release's
    # *surface*: which of its own definitions has this leaf and this shape. That is the question
    # the miner asked when it filed, and it is the one that can tell a removal from a misspelling —
    # a reference the report invented has no definition behind it in either release.
    #
    # The execution is still what the verdict rests on: the name is found in the release's
    # definitions, then run against both, so the evidence is a reference that resolved and now
    # raises rather than a comparison of two inventories.
    def self.ruby_searched(claim, build:, suffix: "")
      if claim.reference.empty?
        return Verdict.of(outcome: NO_CLAIM, detail: "the report names no reference to run")
      end

      if claim.from_version.empty?
        return Verdict.of(outcome: NO_CLAIM,
          detail: "the report names no release to compare against")
      end

      older = build.call(claim.library, claim.from_version)
      newer = build.call(claim.library, claim.version)
      before = RubyEnvs.inventory(older, suffix: "#{suffix}-older")
      after = RubyEnvs.inventory(newer, suffix: "#{suffix}-searched")
      unless before.loaded? && after.loaded?
        unreadable = before.loaded? ? after : before
        return Verdict.of(
          outcome: NO_CLAIM,
          detail: "#{unreadable.package} #{unreadable.version} could not be read: " \
                  "#{unreadable.error.to_s.empty? ? 'the release defines nothing readable' : unreadable.error}",
          unreachable: true
        )
      end
      # Definitions of this leaf and this shape, in the release the report came from. Both halves
      # matter: `Parser#parse` and `Parser.parse` are different names, and searching by leaf alone
      # would let a singleton method confirm an instance one.
      was = before.entries.select do |entry|
        entry.kind == claim.reference_kind && RubyEnvs.leaf_of(entry.name) == claim.leaf
      end
      if was.empty?
        return Verdict.of(
          outcome: NO_CLAIM,
          detail: "#{claim.library} #{claim.from_version} defines no #{claim.reference_kind} " \
                  "named `#{claim.leaf}`, so there is nothing that could have been taken away"
        )
      end
      now = after.entries.map(&:name)
      # The one the report names when the older release has it verbatim, and otherwise the
      # definition the search found: the claim is about *that name*, and which of the older
      # release's names it lands on is what the report was describing.
      entry = was.find { |one| one.name == claim.symbol } || was.first
      expression = entry.expression || claim.reference
      ran = RubyEnvs.probe(older, expression, suffix: "#{suffix}-older")
      still = RubyEnvs.probe(newer, expression, suffix: "#{suffix}-searched")
      unless RubyEnvs.answers?(ran) && RubyEnvs.answers?(still)
        return Verdict.of(
          outcome: NO_CLAIM,
          detail: "one of the two releases could not be asked: " \
                  "#{[RubyEnvs.exception_line(ran), RubyEnvs.exception_line(still)].find { |line| !line.empty? } || 'no answer'}",
          unreachable: true
        )
      end
      if now.include?(entry.name) || !RubyEnvs.refused_symbol?(still, entry.name)
        return Verdict.of(
          outcome: Ledger::DISSENTED,
          executed: "Asked the two releases directly: `#{entry.name}` on #{claim.library} " \
                    "#{claim.from_version} resolved, and on #{claim.library} #{claim.version} " \
                    "it says #{RubyEnvs.exception_line(still).empty? ? 'nothing' : RubyEnvs.exception_line(still)} — the release " \
                    "still defines the name, so it did not take it away.",
          detail: "the release did not lose the name between these releases"
        )
      end
      destination = ""
      unless claim.moved.empty?
        fix_entry = RubyEnvs.entry_of(claim.moved)
        fix_probe =
          if fix_entry && fix_entry.expression
            RubyEnvs.probe(newer, fix_entry.expression, suffix: "#{suffix}-searched")
          else
            ""
          end
        if fix_entry.nil? || RubyEnvs.unreached?(fix_probe)
          destination = "unrun"
        elsif !RubyEnvs.resolves?(fix_probe)
          return Verdict.of(
            outcome: Ledger::PARTIAL,
            executed: "Asked the two releases directly: `#{entry.name}` resolved on " \
                      "#{claim.library} #{claim.from_version} and raises on #{claim.library} " \
                      "#{claim.version}, which is the break reported. The fix was run and did " \
                      "not resolve: reading `#{claim.moved}` on #{claim.library} " \
                      "#{claim.version} failed.",
            detail: "the problem reproduces but the reference the fix names does not resolve"
          )
        else
          destination = "resolved"
        end
      end
      moved_to = RubyEnvs.moved(newer, claim.reference_kind, claim.leaf,
        suffix: "#{suffix}-searched")
      where =
        if !moved_to.empty?
          " The release does define #{list_of(moved_to.first(3))}" \
            "#{moved_to.length <= 3 ? '' : ', and more'} — so the name moved rather than " \
            "disappearing."
        elsif destination == "resolved"
          # The fix the report hands over resolves, and the move search did not find it: the name
          # is reachable where the report says it is, even if the search's own filter (this leaf,
          # this kind) does not describe it.
          " The reference the report offers as the fix, `#{claim.moved}`, resolves on the " \
            "same release."
        else
          " The release defines nothing with that leaf, so it is not a rename: the name " \
            "was dropped."
        end
      Verdict.of(
        outcome: Ledger::REPRODUCED,
        executed: "Asked the two releases directly: `#{entry.name}` resolved on #{claim.library} " \
                  "#{claim.from_version} and raises on #{claim.library} #{claim.version} with " \
                  "#{RubyEnvs.exception_line(still)}. The name went away between these two " \
                  "releases, which is what the report claims.#{where}"
      )
    end

    # --- the PyPI index, whose claim is a call site or a dotted reference -------------------

    # Run the claim as the report writes it, then run the fix it hands over.
    #
    # An argument report names its call sites, and each is run against the reported release with
    # the refused keyword: the failure is confirmed when the interpreter refuses *that name*. What
    # follows depends on what the fix says:
    #
    # * a replacement argument (`on_stop=` is `on_reset=`) is executed against the same release,
    #   and the claim holds when it is accepted there — a replacement the release refuses as well
    #   is a `partial`, which the corpus does not count;
    # * no replacement (a removal) is only a claim about a change, so the *older* release the
    #   report came from is asked whether it accepted the argument. If it refused it too, nothing
    #   was taken away and the report is contradicted.
    #
    # A report that names no call site has nothing here to run. Probing the release's whole surface
    # instead would be inventing a claim the report did not make.
    def self.as_reported(claim, build:, suffix: "")
      return reference(claim, build: build, suffix: suffix) if claim.kind != "argument"

      if claim.sites.empty?
        return Verdict.of(outcome: NO_CLAIM,
          detail: "the report names no call site to run the failure against")
      end

      reported = build.call(claim.library, claim.version)
      module_name = module_for(reported, claim, suffix: "#{suffix}-reported")
      refusing = []
      first_output = ""
      last_output = ""
      answered = false
      claim.sites.each do |site|
        output = Envs.probe(reported, module_name, site, claim.parameter,
          suffix: "#{suffix}-reported")
        last_output = output
        # A probe that never got as far as the callable is not a refusal *or* a resolution: the
        # release has said nothing about the argument yet, and the only honest verdict is none at
        # all.
        answered ||= Envs.answers?(output)
        if Envs.refused_parameter?(output, claim.parameter)
          refusing << site
          first_output = first_output.empty? ? output : first_output
        end
      end
      if refusing.empty? && !answered
        return Verdict.of(
          outcome: NO_CLAIM,
          detail: "#{claim.library} #{claim.version} could not be asked: " \
                  "#{Envs.exception_line(last_output).empty? ? 'the probe did not run' : Envs.exception_line(last_output)}",
          unreachable: true
        )
      end
      if refusing.empty?
        return Verdict.of(
          outcome: Ledger::DISSENTED,
          executed: "Ran #{list_of(claim.sites)} against #{claim.library} #{claim.version} with " \
                    "`#{claim.parameter}=`: none of them refused that name. " \
                    "#{Envs.exception_line(last_output)}",
          detail: "the call sites the report names do not refuse the argument"
        )
      end

      ran = list_of(refusing.map { |site| "#{site}(#{claim.parameter}=…)" })
      refusal = Envs.exception_line(first_output)
      unless claim.replacement.empty?
        fixed = Envs.probe(reported, module_name, refusing.first, claim.replacement,
          suffix: "#{suffix}-replacement")
        if Envs.refused_parameter?(fixed, claim.replacement)
          return Verdict.of(
            outcome: Ledger::PARTIAL,
            executed: "Ran #{ran} against #{claim.library} #{claim.version}: the interpreter " \
                      "refused the argument, so the problem is real. The fix the report " \
                      "gives was run too, from the same call site, and refused as well — " \
                      "`#{claim.replacement}=` is not accepted there either. " \
                      "#{Envs.exception_line(fixed)}",
            detail: "the problem reproduces but the fix it names does not run"
          )
        end
        if !Envs.answers?(fixed)
          # The fix could not be run — the interpreter never reached the call — and that is not a
          # reason to withhold a confirmation of the *problem*, which is what the corpus counts. It
          # is a reason to say the fix was not run.
          return Verdict.of(
            outcome: Ledger::REPRODUCED,
            executed: "Ran #{ran} against #{claim.library} #{claim.version}: the interpreter " \
                      "refused `#{claim.parameter}=` by name, which is the failure this " \
                      "report describes. The fix could not be run in this environment: " \
                      "#{Envs.exception_line(fixed).empty? ? 'the probe did not run' : Envs.exception_line(fixed)}. #{refusal}"
          )
        end
        return Verdict.of(
          outcome: Ledger::REPRODUCED,
          executed: "Ran #{ran} against #{claim.library} #{claim.version}: the interpreter " \
                    "refused `#{claim.parameter}=` by name. Running the same call site with " \
                    "the report's `#{claim.replacement}=` was not refused, so the fix runs " \
                    "against the release it is for. #{refusal}"
        )
      end

      if claim.from_version.empty?
        return Verdict.of(
          outcome: NO_CLAIM,
          detail: "the failure reproduces, but the report names no release it came from, " \
                  "so there is nothing to establish that the argument was ever accepted"
        )
      end
      older = build.call(claim.library, claim.from_version)
      older_module = module_for(older, claim, suffix: "#{suffix}-older")
      was = Envs.probe(older, older_module, refusing.first, claim.parameter,
        suffix: "#{suffix}-older")
      if !Envs.answers?(was)
        return Verdict.of(
          outcome: Ledger::REPRODUCED,
          executed: "Ran #{ran} against #{claim.library} #{claim.version}: the interpreter " \
                    "refused `#{claim.parameter}=` by name, which is the failure this report " \
                    "describes. #{claim.library} #{claim.from_version} could not be asked " \
                    "whether it accepted the argument: " \
                    "#{Envs.exception_line(was).empty? ? 'the probe did not run' : Envs.exception_line(was)}. #{refusal}"
        )
      end
      if Envs.refused_parameter?(was, claim.parameter)
        return Verdict.of(
          outcome: Ledger::DISSENTED,
          executed: "Ran #{ran} against #{claim.library} #{claim.version}: the argument is " \
                    "refused, which is the failure reported. The release this report says it " \
                    "came from was asked the same question — #{claim.library} " \
                    "#{claim.from_version}, #{refusing.first}(#{claim.parameter}=…) — and refused " \
                    "it too, so nothing was taken away. #{Envs.exception_line(was)}",
          detail: "the older release never accepted the argument either"
        )
      end
      Verdict.of(
        outcome: Ledger::REPRODUCED,
        executed: "Ran #{refusing.first}(#{claim.parameter}=…) against #{claim.library} " \
                  "#{claim.from_version}: that release accepted the argument. Against " \
                  "#{claim.library} #{claim.version}: it is refused by name. Same call, accepted " \
                  "before and refused now, which is the removal this report describes. #{refusal}"
      )
    end

    # A symbol's claim: run the reference, then run the fix or the older release.
    def self.reference(claim, build:, suffix: "")
      if claim.dotted.empty?
        return Verdict.of(outcome: NO_CLAIM,
          detail: "the report names no reference to run")
      end

      reported = build.call(claim.library, claim.version)
      output = Envs.probe_symbol(reported, claim.module_name, claim.symbol,
        suffix: "#{suffix}-reported")
      if !Envs.answers?(output)
        return Verdict.of(
          outcome: NO_CLAIM,
          detail: "#{claim.library} #{claim.version} could not be asked about " \
                  "`#{claim.dotted}`: " \
                  "#{Envs.exception_line(output).empty? ? 'the probe did not run' : Envs.exception_line(output)}",
          unreachable: true
        )
      end
      if !Envs.refused_symbol?(output, claim.symbol)
        return Verdict.of(
          outcome: Ledger::DISSENTED,
          executed: "Ran a reference to `#{claim.dotted}` against #{claim.library} " \
                    "#{claim.version}: it resolved, so the release the report names still " \
                    "exports the name it says it lost.",
          detail: "the name the report says is gone is still there"
        )
      end
      raised = Envs.exception_line(output)

      unless claim.moved.empty?
        # The fix names a path. A path that does not resolve is a fix that cannot be applied, which
        # is worse than no fix — so it is executed, and a failure to resolve is what makes this a
        # partial rather than a confirmation.
        found = Envs.probe_dotted(reported, claim.moved, suffix: "#{suffix}-moved")
        if Envs.unreached?(found)
          return Verdict.of(
            outcome: Ledger::REPRODUCED,
            executed: "Ran a reference to `#{claim.dotted}` against #{claim.library} " \
                      "#{claim.version}: #{raised} — the failure this report describes. The " \
                      "fix could not be run in this environment: " \
                      "#{Envs.exception_line(found).empty? ? 'the probe did not run' : Envs.exception_line(found)}."
          )
        end
        if !Envs.resolves?(found)
          return Verdict.of(
            outcome: Ledger::PARTIAL,
            executed: "Ran a reference to `#{claim.dotted}` against #{claim.library} " \
                      "#{claim.version}: #{raised} — the failure is real. The fix was run and " \
                      "did not resolve: reading `#{claim.moved}` on the same release raised " \
                      "#{Envs.exception_line(found).empty? ? 'nothing' : Envs.exception_line(found)}.",
            detail: "the problem reproduces but the path the fix names does not resolve"
          )
        end
        return Verdict.of(
          outcome: Ledger::REPRODUCED,
          executed: "Ran a reference to `#{claim.dotted}` against #{claim.library} " \
                    "#{claim.version}: #{raised} — the failure this report describes. Ran the " \
                    "fix from the same release: `#{claim.moved}` resolved, so the name is " \
                    "still reachable where the report says it is."
        )
      end

      if claim.from_version.empty?
        return Verdict.of(
          outcome: NO_CLAIM,
          detail: "the reference raises, but the report names no release it came from and no " \
                  "fix, so nothing establishes that the name was there before"
        )
      end
      older = build.call(claim.library, claim.from_version)
      older_module = module_for(older, claim, suffix: "#{suffix}-older")
      was = Envs.probe_symbol(older, older_module, claim.symbol, suffix: "#{suffix}-older")
      if !Envs.answers?(was)
        return Verdict.of(
          outcome: Ledger::REPRODUCED,
          executed: "Ran a reference to `#{claim.dotted}` against #{claim.library} " \
                    "#{claim.version}: #{raised} — the failure this report describes. " \
                    "#{claim.library} #{claim.from_version} could not be asked whether the " \
                    "name resolved there: " \
                    "#{Envs.exception_line(was).empty? ? 'the probe did not run' : Envs.exception_line(was)}."
        )
      end
      if Envs.refused_symbol?(was, claim.symbol)
        return Verdict.of(
          outcome: Ledger::DISSENTED,
          executed: "Ran a reference to `#{older_module}.#{claim.symbol}` against " \
                    "#{claim.library} #{claim.from_version}, the release this report says it " \
                    "came from: it raises there too, so the name was already gone and nothing " \
                    "changed between the two. #{Envs.exception_line(was)}",
          detail: "the name was already gone on the release the report came from"
        )
      end
      Verdict.of(
        outcome: Ledger::REPRODUCED,
        executed: "Ran a reference to `#{older_module}.#{claim.symbol}` against #{claim.library} " \
                  "#{claim.from_version}: that release resolved it. Against #{claim.library} " \
                  "#{claim.version}: #{raised} — the same reference, resolved before and raising " \
                  "now, which is the break this report describes."
      )
    end

    # Re-derive the claim from the two releases, ignoring the report's account of it.
    #
    # The report's own call sites are deliberately not read here. What is asked instead is the
    # question the miner asked when it filed: which call sites accepted this argument on the older
    # release and refuse it on the newer one — and, for a name, did it resolve before and does it
    # fail now. A claim that holds only where the report happened to look was never a claim about
    # the release.
    def self.searched(claim, build:, suffix: "")
      if claim.from_version.empty?
        return Verdict.of(outcome: NO_CLAIM,
          detail: "the report names no release to compare against")
      end

      older = build.call(claim.library, claim.from_version)
      newer = build.call(claim.library, claim.version)

      return search_parameter(claim, older, newer, suffix: suffix) if claim.kind == "argument"

      search_symbol(claim, older, newer, suffix: suffix)
    end

    # Which call sites took the argument away, found from the releases themselves.
    def self.search_parameter(claim, older, newer, suffix: "")
      old_inventory = Envs.inventory(older, suffix: "#{suffix}-older")
      new_inventory = Envs.inventory(newer, suffix: "#{suffix}-searched")
      old_entries = index_by_name(old_inventory.entries)
      new_entries = index_by_name(new_inventory.entries)
      # The older release's import name, for the same reason the miner uses it: the call site a
      # migrating caller is still writing was written against that release.
      module_name = old_inventory.module

      # (call site, the release's spelling of the argument). The spelling matters and is not the
      # token: signatures carry the name as the package wrote it, while the token read back from
      # the report is lowercased, and comparing the two as text found no call site at all for
      # `documentAST=` — which the check then reported as "this argument was not taken away", a
      # contradiction of a report that was true.
      candidates = []
      blind = 0
      old_entries.each do |name, entry|
        other = new_entries[name]
        next if other.nil? || Mine.field(entry, "kind") != Mine.field(other, "kind")

        old_params = Mine.field(entry, "params")
        new_params = Mine.field(other, "params")
        if old_params.nil? || new_params.nil?
          # Unreadable in one of the two releases, which is what the miner skips as well. An
          # *empty* hash is not the same thing: a callable that takes no parameters at all is a
          # callable that lost this one, and reading it as "nothing to compare" would drop exactly
          # that case.
          blind += 1
          next
        end
        # Optional on the older release, because a parameter that was required cannot be probed on
        # its own: the call would fail for the missing positional and the refusal would never be
        # reached. Same rule, same limitation as the miner's own pass.
        taken = named(old_params, claim.parameter)
        next if taken.nil? || Mine.field(old_params[taken], "required")

        next unless named(new_params, claim.parameter).nil?

        candidates << [name, taken]
        break if candidates.length >= SITE_LIMIT
      end

      confirmed = []
      named_sites = []
      said = ""
      asked = 0
      candidates.each do |name, spelling_of|
        observation = Mine.confirm(older, newer, module_name, name, old_entries[name],
          new_entries[name], spelling_of,
          suffix: "#{suffix}-searched")
        # The call site was never asked, so it neither refuses the argument nor says it was taken
        # away. Counted, so the verdict below can tell "no call site lost it" apart from "no call
        # site answered".
        next if observation.equal?(Mine::UNREACHED)

        asked += 1
        next if observation.nil?

        confirmed << [name, spelling_of]
        named_sites << [name, spelling_of] if named_sites.length < NAMED_SITES
        said = said.empty? ? observation.exception : said
      end
      if confirmed.empty?
        if candidates.empty? && blind.positive?
          # Every call site that could have answered was unreadable in one of the two releases.
          # That is not a contradiction, it is a blind spot.
          return Verdict.of(
            outcome: NO_CLAIM,
            detail: "#{count_of(blind, 'call site')} in these releases have a signature " \
                    "neither release can read, so the argument cannot be checked",
            unreachable: true
          )
        end
        if asked.zero?
          # Not one candidate was asked anything, and *which* of two things that means is what
          # `candidates` decides. With call sites in hand it is the machine's failure — no probe
          # reached its release — and marked so the verifier comes back to it instead of retiring
          # a report no release was ever asked about. With none, there was nothing here to ask and
          # no probe failed, which is a fact about the report and wants the drop. One word,
          # NO_CLAIM, covers both, so the difference has to be carried by `unreachable` rather than
          # inferred from the outcome.
          return Verdict.of(
            outcome: NO_CLAIM,
            detail: if candidates.empty?
                      "none of these releases offers a call site for this argument"
                    else
                      "#{count_of(candidates.length, 'call site')} in these releases could " \
                        "not be asked: not one probe reached its release"
                    end,
            unreachable: !candidates.empty?
          )
        end
        unasked = candidates.length - asked
        note = unasked.zero? ? "" : " #{count_of(unasked, 'call site')} could not be asked at all."
        return Verdict.of(
          outcome: Ledger::DISSENTED,
          executed: "Asked the two releases directly: " \
                    "#{count_of(candidates.length, 'call site')} in #{claim.library} " \
                    "#{claim.from_version} offered `#{claim.parameter}=` and no longer do in " \
                    "#{claim.library} #{claim.version}, and not one of them refuses it — so " \
                    "this argument was not taken away between these releases.#{note}",
          detail: "no call site lost the argument between these releases"
        )
      end
      Verdict.of(
        outcome: Ledger::REPRODUCED,
        executed: "Asked the two releases directly: #{count_of(confirmed.length, 'call site')} " \
                  "accepted `#{confirmed.first[1]}=` on #{claim.library} #{claim.from_version} " \
                  "and refuse it on #{claim.library} #{claim.version} — " \
                  "#{list_of(named_sites.map { |name, sp| "#{name}(#{sp}=…)" })}" \
                  "#{confirmed.length <= NAMED_SITES ? '' : ', and more'}. #{said}"
      )
    end

    # Whether the release the report names really stopped exporting this name.
    def self.search_symbol(claim, older, newer, suffix: "")
      new_inventory = Envs.inventory(newer, suffix: "#{suffix}-searched")
      new_entries = index_by_name(new_inventory.entries)
      newer_module = claim.module_name.empty? ? new_inventory.module : claim.module_name
      older_module =
        if claim.module_name.empty?
          Envs.inventory(older, suffix: "#{suffix}-older").module
        else
          claim.module_name
        end
      observed = Mine.confirm_symbol(older, newer, newer_module, claim.symbol, new_entries,
        suffix: "#{suffix}-searched")
      if observed.equal?(Mine::UNREACHED)
        # A probe that never ran is not a contradiction either: neither reference was asked, so
        # nothing here is evidence about the report. Marked as the machine's failure rather than the
        # report's, so the loop comes back to it instead of retiring a report no release was ever
        # asked about.
        return Verdict.of(
          outcome: NO_CLAIM,
          detail: "one of the two releases could not be asked: the probes did not run",
          unreachable: true
        )
      end
      if observed.nil?
        # Only now are the two references run again, because the reason for the refusal is what the
        # evidence has to carry and the two failures read alike: a name that was already gone and a
        # name that is still here.
        was = Envs.probe_symbol(older, older_module, claim.symbol, suffix: "#{suffix}-older")
        now = Envs.probe_symbol(newer, newer_module, claim.symbol, suffix: "#{suffix}-searched")
        unless Envs.answers?(was) && Envs.answers?(now)
          return Verdict.of(
            outcome: NO_CLAIM,
            detail: "one of the two releases could not be asked: " \
                    "#{[Envs.exception_line(was), Envs.exception_line(now)].find { |line| !line.empty? } || 'no answer'}",
            unreachable: true
          )
        end
        return Verdict.of(
          outcome: Ledger::DISSENTED,
          executed: "Asked the two releases directly: `#{older_module}.#{claim.symbol}` on " \
                    "#{claim.library} #{claim.from_version} says " \
                    "#{Envs.exception_line(was).empty? ? 'nothing' : Envs.exception_line(was)}, and on #{claim.library} " \
                    "#{claim.version} says #{Envs.exception_line(now).empty? ? 'nothing' : Envs.exception_line(now)} — so this is " \
                    "not a name that resolved before and fails now.",
          detail: "the release did not lose the name between these releases"
        )
      end
      fix_probe = claim.moved.empty? ? "" : Envs.probe_dotted(newer, claim.moved,
        suffix: "#{suffix}-searched")
      if !claim.moved.empty? && !Envs.unreached?(fix_probe) && !Envs.resolves?(fix_probe)
        return Verdict.of(
          outcome: Ledger::PARTIAL,
          executed: "Asked the two releases directly: `#{older_module}.#{claim.symbol}` resolved " \
                    "on #{claim.library} #{claim.from_version} and raises on #{claim.library} " \
                    "#{claim.version}, which is the break reported. The fix was run and did not " \
                    "resolve: reading `#{claim.moved}` on #{claim.library} #{claim.version} failed.",
          detail: "the problem reproduces but the path the fix names does not resolve"
        )
      end
      Verdict.of(
        outcome: Ledger::REPRODUCED,
        executed: "Asked the two releases directly: `#{older_module}.#{claim.symbol}` resolved on " \
                  "#{claim.library} #{claim.from_version} and raises on #{claim.library} " \
                  "#{claim.version} with #{observed.exception}. The name went away between these " \
                  "two releases, which is what the report claims."
      )
    end

    # --- reading a report's own prose --------------------------------------------------------

    # An argument's name as the report writes it, given the corpus's stored form.
    #
    # Symptom tokens are lowercased before they are stored — a rule the whole service
    # depends on — so the token read back out of `signatures` is not the name a caller
    # typed. `documentAST=` is the only such argument in the corpus today and it is enough:
    # the call sites the report names are spelled with the capitals, and a search for the
    # lowercase form found none of them, which read as "this report names no call site" and
    # cast no vote on a report that was true. Getting that wrong is not a crash in the
    # parser's own terms — it is `undefined method 'downcase' for an instance of Array`,
    # which is what the first run of this suite said 21 times.
    def self.spelling(problem, parameter)
      problem.to_s.scan(WRITTEN_ARGUMENT).map(&:first).each do |name|
        return name if name.downcase == parameter.downcase
      end
      parameter
    end

    # Every call site the report names for this argument, in the order written.
    def self.sites(problem, parameter)
      pattern = Regexp.new(format(SITE, parameter: Regexp.escape(parameter.to_s)))
      problem.to_s.scan(pattern).map(&:first).uniq
    end

    # The argument a rename's fix says to use instead, when it says so.
    def self.replacement(resolution)
      match = REPLACEMENT.match(resolution.to_s)
      match ? match[2] : ""
    end

    # The path a fix says the name went to, when it names one.
    #
    # A dotted term is required, and it has to end in the name being asked about:
    # `sqlalchemy.sql.schema.IdentityOptions` is a location for `IdentityOptions`, while a bare
    # module name is a place to look rather than the thing itself.
    #
    # The path the report says is *broken* is excluded, which is not a detail: a removal's
    # resolution opens by naming that path ("`sqlalchemy.IdentityOptions` is gone"), and reading it
    # as the destination would turn every removal into a move back to the place the caller already
    # is.
    #
    # `spelled` is every other way the report's own body writes that same name, and it is the
    # exclusion `broken` cannot make. One name has two spellings — the distribution's and the
    # import's — and a report can use one in its sentence while the interpreter line it quotes uses
    # the other. `pymupdf 1.24.14 removed pymupdf.JM_Warning` says the distribution spelling in its
    # problem and quotes `module 'fitz' has no attribute 'JM_Warning'`, so `broken` was
    # `fitz.JM_Warning`, the resolution's own `` `pymupdf.JM_Warning` is gone `` was not excluded,
    # and the name the report says was removed was read back as the fix for it — two true reports
    # filed as `partial` and left unable to reach `resolved_verified`.
    #
    # Compared without case, because the two spellings of a package's name differ in case as well
    # as shape: the resolution writes the *distribution* name (`cython.CythonMetaType`), while the
    # failure it quotes is raised against the module (`Cython.CythonMetaType`).
    def self.moved(resolution, symbol, broken, spelled: [])
      gone = ([symbol, broken] + Array(spelled)).map(&:downcase)
      # `String#scan`, not `Regexp#scan`: it is the receiver that scans, and `findall`'s shape —
      # one group, so a flat list of the capture — is what `String#scan` returns too.
      resolution.to_s.scan(DOTTED_TERM).map(&:first).each do |term|
        next unless term.end_with?(".#{symbol}")
        next if gone.include?(term.downcase)

        return term
      end
      ""
    end

    # Every way a report's own body writes the reference it says is gone.
    #
    # The same question the PyPI side's `written_paths` answers, over Ruby's separators: a report
    # writes its subject more than once, and a fix cannot be one of the spellings the report itself
    # calls broken.
    def self.ruby_written(text, subject)
      text.to_s.scan(RUBY_TERM).map(&:first).reject { |term| term == subject }
    end

    # The reference a fix says the name went to, when it names one.
    #
    # Two rules, and they are the two ways a Ruby name survives a release. A name that **moved**
    # keeps its leaf and changes owner (`Foo::Bar` to `Foo::Parsers::Bar`), so the leaf is the test.
    # A name that was **renamed** keeps its words (`MyGem::Parse` to `MyGem::ParseTask`) and
    # changes the leaf, so the test is the miner's own rename rule: every word of the old name has
    # to survive in the new one. Reusing that rule rather than writing a second one is deliberate —
    # the fix a verifier accepts should be the kind of fix the miner would have filed.
    #
    # The reference the report says is *broken* is excluded in every spelling its own body uses,
    # and so is a module of it: `Bundler` in "the name moved out of `Bundler`" is a place to look
    # rather than a destination.
    def self.ruby_moved(resolution, subject, spelled)
      leaf = RubyEnvs.leaf_of(subject)
      candidates = resolution.to_s.scan(RUBY_TERM).map(&:first).reject do |term|
        term == subject || Array(spelled).include?(term) || subject.start_with?("#{term}::")
      end
      candidates.each { |term| return term if RubyEnvs.leaf_of(term) == leaf }
      candidates.each do |term|
        return term if Mine.same_words(Mine.words(leaf), Mine.words(RubyEnvs.leaf_of(term)))
      end
      ""
    end

    # Every dotted spelling of one name that a piece of report text writes itself.
    #
    # The name a report is *about*, as that report spells it — used to refuse the symbol as its own
    # successor. `DOTTED_TERM` needs a dot and a name on each side of it, so a bare module or a bare
    # name is not one of these, and a sentence that mentions a module without naming the thing is
    # not read as a location.
    def self.written_paths(text, symbol)
      ending = ".#{symbol}".downcase
      text.to_s.scan(DOTTED_TERM).map(&:first).select { |term| term.downcase.end_with?(ending) }
    end

    # The module and name a report names, preferring what the interpreter said.
    #
    # Two sources, in the order of how much they establish: the interpreter's own line (two
    # spellings, and any package's own wording of them), then the sentence that names the reference
    # in prose. The title is deliberately not one of them, for the reason `claim_for` leaves it out
    # of the spellings a fix may not be: a move's title names the destination, so a title read as
    # the reference would turn the break into its own fix. A report that names none of these is one
    # this verifier cannot check, and it says so rather than guessing which name was meant.
    def self.quoted_reference(problem)
      text = problem.to_s
      match = NO_ATTRIBUTE.match(text)
      return [match[1], match[2]] if match

      match = CANNOT_IMPORT.match(text)
      return [match[2], match[1]] if match

      match = NAMED_REFERENCE.match(text)
      if match
        dotted = match[1]
        module_name, _, symbol = dotted.rpartition(".")
        return [module_name, symbol]
      end
      nil
    end

    # The release a report came from: the field it states, else its own sentence.
    #
    # Every mined report writes it in prose — "Upgrading {library} from {from} to {to}" — and since
    # `0018` it is a column the API returns, filed from that same template. The field is read first
    # because it is what the author *declared*: a report that supplies `from_version` and
    # paraphrases its own problem text had the column ignored and was refused as uncheckable, which
    # is a report that stated exactly what the check needed and was told it had not.
    #
    # Either way the answer is sanity-checked before it is handed to the installer. A release equal
    # to the one being compared against, or a sentence that mentions two other things, is no
    # before-release at all — and a claim about a change cannot be checked against one release.
    #
    def self.from_version_of(report, version)
      stated = Mine.field(report, "from_version").to_s.strip
      return stated if usable_from_version?(stated, version)

      from_prose(Mine.field(report, "problem").to_s, version)
    end

    # The release a report's own sentence says it came from, when one is readable.
    def self.from_prose(problem, version)
      match = FROM_PROSE.match(problem.to_s)
      return "" if match.nil?

      # Trailing punctuation is not part of a version: "from 0.27.0, to 0.28.0" reads as `0.27.0,`,
      # and that is handed to the installer as a release to fetch — a check that fails for a reason
      # with nothing to do with the report.
      came_from = match[1].strip.gsub(/\A[.,;:]+/, "").gsub(/[.,;:]+\z/, "")
      usable_from_version?(came_from, version) ? came_from : ""
    end

    # Whether this could be the release the report came from.
    #
    # A version is what is wanted: the same release twice establishes nothing about a change, and
    # anything that does not start with a digit would be handed to the installer as a release to
    # fetch.
    def self.usable_from_version?(candidate, version)
      text = candidate.to_s
      !text.empty? && text != version && text[0].to_s.match?(/\d/)
    end

    # The import name a call site has to be written against.
    #
    # The distribution name is not the import name — `pyyaml` is `yaml`, `pillow` is `PIL` — and a
    # call site built from the distribution name fails before the argument is ever bound. Only the
    # environment can resolve one to the other, so it is asked.
    def self.module_for(env, claim, suffix:)
      claim.module_name.empty? ? Envs.inventory(env, suffix: suffix).module : claim.module_name
    end

    # One field of a report body, read the way a body may arrive.
    #
    # `Hash`-keyed by string is what the service returns and what the change feed carries, and every
    # test here builds one; symbol keys are accepted beside it because a caller that built its own
    # report instead of reading one is not a different question. Anything else is `default`.
    def self.field(report, name, default = nil)
      if report.respond_to?(:key?) && report.key?(name)
        report[name]
      elsif report.respond_to?(:key?) && report.key?(name.to_sym)
        report[name.to_sym]
      else
        default
      end
    end

    # Inventory entries by name, whichever spelling the entry's fields arrived in.
    def self.index_by_name(entries)
      (entries || []).each_with_object({}) do |entry, found|
        name = Mine.field(entry, "name")
        found[name] = entry unless name.nil?
      end
    end

    # The release's spelling of an argument, given the corpus's lowercased token.
    def self.named(params, parameter)
      (params || {}).each_key do |name|
        return name if name.to_s.downcase == parameter.to_s.downcase
      end
      nil
    end

    def self.list_of(names) = names.map { |name| "`#{name}`" }.join(", ")

    def self.count_of(count, noun) = count == 1 ? "#{count} #{noun}" : "#{count} #{noun}s"
  end
end
