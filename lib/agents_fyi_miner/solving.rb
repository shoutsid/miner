# frozen_string_literal: true

require_relative "findings"
require_relative "pair"
require_relative "reporting"
require_relative "versions"

module AgentsFyiMiner
  # Attaching an executed fix to a failure somebody else recorded.
  #
  # This is the other half of what the miner is for. Finding a break adds a *failure* to the
  # corpus; the corpus's value is that it also carries what fixed it, and a report nobody can
  # solve stays a dead end however findable it is. Such a report names a library, a version
  # and, usually, the argument the failure was about — and that is exactly what the
  # differential can execute. So when the miner already knows that `convert_unicode=`
  # disappeared between two releases, a report saying "sqlalchemy 2.0 rejects
  # convert_unicode" is not a question it has to guess at: it is one it can answer by running
  # the same comparison.
  #
  # The gate is deliberately narrow, because a wrong fix attached to somebody's report is
  # worse than no fix:
  #
  # * the symptom must be a *named argument* the interpreter refused, which is the one failure
  #   shape this miner establishes by execution;
  # * the argument name in the report must be the name the finding established, and the
  #   release must be the same minor line, so the link is a specific fact about a specific
  #   release rather than a similarity between two English sentences;
  # * a report that already carries a fix is only ever *reproduced*, never re-fixed — the
  #   corpus adopts a report's first proposal, so a second one would be competing with an
  #   answer rather than filling a gap.
  #
  # Nothing here talks to the corpus; it takes a record and a finding and decides whether they
  # describe the same mechanism, so the rule can be tested against records rather than against
  # a live server.
  #
  # **Two halves, landed in that order, and the whole file is here now.** The predicate layer
  # came first because the planner needs it and nothing else — `demanded` and `wanted?` ask
  # whether a report is answerable at all — and the matching half was appended by the slice
  # that ported the rest of `solving.py`.
  module Solving
    # How a stored signature names the argument an error refused. The service lowercases every
    # token it stores, so the name read back out of a signature is lowercased whatever the
    # caller wrote — which is why the comparison below is case-insensitive in one direction
    # only.
    NAMED_ARGUMENT = "unexpected keyword argument '"

    # A report's version when nobody could name one. The service writes this literal rather
    # than refusing the report, so it is a thing the solver has to recognise rather than a
    # thing it can assume away.
    UNKNOWN_VERSION = "unknown"

    # The two statuses that are still a question for this operator: a report with no fix yet,
    # and one whose fix nobody has independently reproduced. Named once because three functions
    # decide on the same two strings — `needs_a_fix?`, `needs_reproduction?` and `wants_status?`
    # — and a walk that disagreed with the predicate about which status matters would skip
    # exactly the reports it exists to answer, without anything failing.
    OPEN = "open"
    RESOLVED_UNVERIFIED = "resolved_unverified"

    # What the solver decided about one report, ready to be sent.
    #
    # A value named on the module rather than inside the predicates' `class << self`: a constant
    # defined in there is `Solving.singleton_class::Answer`, which nothing outside can name —
    # and `service.rb` and `cli_reports.rb` both carry one of these out of here.
    Answer = Data.define(:report_id, :parameter, :kind, :payload, :summary)

    # Whether this miner filed the report it is looking at.
    #
    # The service counts a confirmation only from an operator other than a report's author, so
    # a miner voting on its own report writes a row no number reads — and it *looks*, in the
    # corpus, like independent reproduction. It is also pointless work: re-deriving a finding
    # this account already filed is the differential run that produced it, run again to reach
    # it.
    #
    # One function because there are two callers — the service's cycle and the one-off `solve`
    # command — and the command was written without the check at all, which cost it a full
    # differential per report it had filed itself.
    def self.ours?(report, operator_id)
      !operator_id.to_s.empty? && report["submitted_by"].to_s == operator_id
    end

    # Every argument name the stored symptoms say an error refused.
    def self.named_arguments(signatures)
      found = {}
      Array(signatures).each do |signature|
        next unless signature.to_s.include?(NAMED_ARGUMENT)

        name = signature.split(NAMED_ARGUMENT, 2)[1].to_s.split("'", 2).first.to_s
        # Lowercased here rather than at the comparison, so there is one spelling of the name
        # and every caller compares the same thing: the service stores tokens lowercased, and
        # a caller's text is not.
        found[name.downcase] = true unless name.empty?
      end
      found.keys
    end

    # Whether a report the feed reports at this status could be a question here.
    #
    # The solver acts on two statuses — an open report with no fix, and one whose fix nobody
    # has independently reproduced — so everything else is settled as far as this operator is
    # concerned. Read from the *feed row* rather than from a fetched body, which is the
    # difference between a walk that reaches today's reports and one whose look budget is
    # spent reading the same settled reports again every cycle. The empty status is read
    # rather than assumed: a report the feed has not described yet is one nothing is known
    # about.
    def self.wants_status?(status)
      ["", OPEN, RESOLVED_UNVERIFIED].include?(status.to_s)
    end

    # Whether the differential could have anything to say about this report.
    #
    # Every clause is a fact the solver needs and cannot guess. A package rather than any
    # other kind, because the differential executes a package's releases and nothing else. A
    # concrete version, because "unknown" cannot be positioned against a release line. A
    # named argument, because a breaker that removed an argument is the one failure this
    # miner establishes by running code — offering to solve a timeout with it would be
    # inventing a fix.
    def self.answerable?(report)
      return false unless report.fetch("subject_kind", "package").to_s == "package"
      return false if report["library"].to_s.empty?
      return false if [nil, "", UNKNOWN_VERSION].include?(report["version"])

      !named_arguments(report["signatures"]).empty?
    end

    # An open report with no answer, which is the gap the solver fills.
    def self.needs_a_fix?(report)
      answerable?(report) && report["status"] == OPEN && !report["resolution"]
    end

    # A fix in force that nobody has independently reproduced yet.
    #
    # Only `resolved_unverified`: a report already at `resolved_verified` has the
    # confirmations it needs, and re-confirming one every cycle would spend the miner's write
    # quota on a number that is already right.
    def self.needs_reproduction?(report)
      answerable?(report) && !report["resolution"].nil? && !report["resolution"].to_s.empty? &&
        report["status"] == RESOLVED_UNVERIFIED
    end

    # The upgrade that introduced this report's failure, if the history shows one.
    #
    # The report is *about* one release, but the comparison is between the release that
    # refuses the call and the one before it: a caller on `2.0.5` is on a line whose first
    # release is what removed the argument, and `1.4.x -> 2.0.y` is the upgrade that broke
    # them. So the pair is chosen by *line*: the newest release of the report's own line
    # against the newest release of the line below it.
    #
    # Lines are the unit rather than exact versions because consecutive patches of a mature
    # package have identical signatures — `miner/README.md` says so, and comparing patch to patch
    # found nothing across ten packages.
    def self.pairs_for_report(report, history)
      version = report["version"].to_s
      line = Versions.line_of(version)
      Versions.crossings(report["library"].to_s, history).each do |pair|
        return [pair] if Versions.line_of(pair.to_version) == line
      end
      []
    end

    # The argument name that links a finding to a report, or nothing.
    #
    # One fact, stated in both directions: the argument this finding saw refused by execution
    # is an argument the report's own symptoms name. The symbol is deliberately not required
    # to match, because the mechanism is what clusters twenty-three call sites into one
    # finding — a report from somebody whose call site is `Session(...)` and a finding
    # established on `create_engine(...)` are the same break, which is precisely the knowledge
    # a corpus is for.
    def self.match(finding, report)
      # A symbol finding is not a link here. This module answers *argument* reports: the
      # report names the argument an error refused, and a released export has no such name to
      # match against. Offering the two as one would attach a fix for `convert_unicode=` to a
      # report about `jinja2.Markup`.
      parameter = finding.parameter.to_s
      return nil if parameter.empty?

      named_arguments(report["signatures"]).include?(parameter.downcase) ? parameter : nil
    end

    # The write that attaches this finding to this report, or nothing.
    #
    # A report with no fix gets the fix the miner executed; a report whose fix is in force and
    # unreproduced gets the one thing it is waiting for — an independent run, by an operator
    # that is not its author, of the replacement it names.
    def self.answer_for(report, finding, pair)
      parameter = match(finding, report)
      return nil if parameter.nil?

      if needs_a_fix?(report)
        return Answer.new(
          report_id: report["id"].to_s,
          parameter: parameter,
          kind: "resolution",
          payload: resolution_payload(finding, report, pair),
          summary: "solved #{report['id']}: #{finding.title}"
        )
      end

      if needs_reproduction?(report)
        payload = verification_payload(finding, report)
        if payload
          return Answer.new(
            report_id: report["id"].to_s,
            parameter: parameter,
            kind: "verification",
            payload: payload,
            summary: "reproduced the recorded fix on #{report['id']}"
          )
        end
      end

      nil
    end

    # The fix, plus the reason this report can be given it.
    #
    # The evidence is the execution: the same call ran against both releases, the older
    # accepted the argument and the newer refused it by name. `notes` says what the claim does
    # *not* cover — the caller's own call site — because it is read by somebody who will apply
    # the fix to code the miner has never seen.
    #
    def self.resolution_payload(finding, report, pair)
      {
        "resolution" => finding.resolution.to_s,
        "environment" => (
          "#{Reporting::PROVENANCE} (#{finding.library} #{pair.from_version} accepted " \
          "`#{finding.parameter}=`; #{finding.library} #{pair.to_version} refused it by name)"
        ),
        "notes" => (
          "This report names the argument `#{finding.parameter}` that #{finding.library} " \
          "#{pair.to_version} refuses. Executing the same call against #{pair.from_version} and " \
          "#{pair.to_version} establishes the refusal by name: " \
          "#{plural(finding.call_sites, 'call site')} " \
          "broke that way and #{plural(finding.repaired_call_sites, 'call site')} had the " \
          "replacement executed successfully. The call site in this report is not necessarily " \
          "the one that was run, so apply the change to yours."
        )
      }
    end

    # A reproduction vote, only when the recorded fix is the one that was run.
    #
    # The vote is cast by *executing*, which is more than the corpus asks for, and it is still
    # withheld unless the report's own resolution names the replacement the miner ran.
    # Anything looser would let the miner confirm any fix that shares an argument name —
    # including one that says "pin the version", which execution has not tested and which must
    # not be reported as reproduced.
    def self.verification_payload(finding, report)
      replacement = finding.replacement
      resolution = report["resolution"].to_s
      return nil if replacement.to_s.empty? || !names?(replacement, resolution)

      {
        "outcome" => "reproduced",
        "environment" => (
          "#{Reporting::PROVENANCE} (#{finding.library} #{finding.version} refused " \
          "`#{finding.parameter}=`; `#{replacement}=` was executed against the same call and got " \
          "past it)"
        ),
        "notes" => (
          "Ran the call with `#{replacement}=` against #{finding.library} #{finding.version} " \
          "after this report's fix suggested the replacement; the failure that named " \
          "`#{finding.parameter}` no longer occurs."
        )
      }
    end

    # Whether `text` names `name`, rather than merely containing its letters.
    #
    # Containment was the first version of this rule and it is looser than the rule it was
    # written for: `id` is contained in "invalid", `on` in "only", `to` in "into", so a
    # resolution that never mentions the replacement satisfied a gate whose whole job is to
    # establish that it does. What passes the gate is a `reproduced` vote — a claim that this
    # fix was executed — so a false positive is the miner telling the corpus somebody's fix is
    # confirmed by a run that tested something else, which is the outcome this module exists
    # to refuse.
    #
    # Anchored on word characters rather than `\b` because a replacement is not always a bare
    # name: a call shape is `client.get(x, timeout=5)` and ends in `)`, where `\b` needs a word
    # character on one side and cannot be satisfied without inventing one. Only the *edges* of
    # the name are anchored, so a replacement that appears as the tail of a qualified name —
    # the corpus writes `httpx.Client` where the finding's replacement is `Client` — still
    # counts: that spelling adds a qualifier, which does not change what was executed.
    def self.names?(name, text)
      Regexp.new("(?<!\\w)#{Regexp.escape(name)}(?!\\w)", Regexp::IGNORECASE).match?(text.to_s)
    end

    def self.plural(count, noun)
      count == 1 ? "#{count} #{noun}" : "#{count} #{noun}s"
    end
  end
end
