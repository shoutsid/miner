# frozen_string_literal: true

require "open3"

require_relative "findings"
require_relative "machine"

module AgentsMiner
  # A finding as the request that files it.
  #
  # The one decision this module makes is about honesty: a report produced by executing two
  # releases is not the same as one written by an agent that hit the failure in their own work, and
  # a reader is entitled to know which they have before trusting it. The provenance is stated where
  # a reader
  # will actually see it: in `environment`, which is what the report says about the conditions it
  # was observed under.
  #
  # That is also why the version is the *breaking* release. A caller searches for what they have
  # installed, and what they have installed is the release that refuses the call.
  #
  # The crossing is sent twice on purpose, in two forms that answer different questions.
  # `attempted` tells a *reader* what was run and against which release — the evidence, in the
  # words of the thing that was run. `from_version`, `subject` and `change_kind` tell a *query* the
  # same facts in a form it can filter on, which is what lets a caller who is about to make this
  # same upgrade be told what it crosses before it fails. Everything here already knew both
  # releases; before the structured fields existed only the prose carried the second one, so the
  # corpus could describe a break and not place it in a move.
  module Reporting
    # What a report says about where it came from. Deliberately explicit and in the report rather
    # than inferred from the account that filed it: an operator can be renamed, and a claim about
    # evidence should not be a lookup.
    #
    # A report claiming a call for a constant that was merely read would be describing an
    # execution that did not happen.
    PROVENANCE = "reproduced by executing the same call against both releases"
    PROVENANCE_REFERENCE = "reproduced by executing both releases and reading the same name from each"

    # The runtime that produced the finding, named in the report.
    #
    #
    # Here it is asked of the interpreter the environments are built with, once per process:
    # it is a subprocess, and a subprocess per filed finding would be paid on the one path
    # that is already rate limited. `platform.python_implementation` and
    # `platform.python_version` are asked in the same call so both halves describe one
    # interpreter — a version read from a different process than the implementation's name is
    # how a report comes to say `CPython 3.11` about a run on 3.12.
    def self.runtime_of(finding)
      return finding.runtime unless finding.runtime.to_s.empty?

      python_runtime
    end

    def self.python_runtime
      @python_runtime ||= begin
        out, status = Open3.capture2(Machine.interpreter, "-c",
          "import platform;print(platform.python_implementation(), " \
          "platform.python_version())")
        answer = out.to_s.strip
        # The machine stamp is the fallback rather than an empty string: a report that said nothing
        # about the runtime would be answering a question the corpus asked.
        status.success? && !answer.empty? ? answer : Machine.python
      rescue SystemCallError
        Machine.python
      end
    end

    # The submit body for one finding, with its evidence attached.
    #
    # `attempted` carries the other half of the evidence — the release that *accepted* the
    # reference — because a report that showed only the failure would leave a reader unable to tell
    # a break from a typo, and that is exactly the distinction the execution establishes. What was
    # attempted is a call with an argument or a reference to a name, and the two read differently,
    # which is why this is a function rather than a format string.
    #
    # `published_at` is when the release that breaks was uploaded, read from the index beside the
    # version list. It is what lets a reader tell a fact their training data could contain from one
    # it could not, so it is sent when known and left out rather than guessed when it is not. The
    # key is always present — `nil` is a statement, and the corpus stores it as sent.
    def self.payload_for(finding, from_version:, published_at: nil)
      {
        "title" => finding.title,
        "library" => finding.library,
        "version" => finding.version,
        # Which index this library is a name in. Declared rather than left to the service's default,
        # because the default is PyPI and a gem filed under it would be compared against the Python
        # corpus — silently, since nothing about the report would look wrong.
        "ecosystem" => finding.ecosystem,
        "subject_kind" => "package",
        "environment" => "#{runtime_of(finding)}; " \
                         "#{finding.ecosystem == 'ruby' ? PROVENANCE_REFERENCE : PROVENANCE}",
        "problem" => finding.problem,
        "attempted" => attempted_for(finding, from_version: from_version),
        # The same crossing, structured. `from_version` is the release the call still resolved
        # against; `version` above is the one that refuses it; the pair is what places this finding
        # inside somebody else's upgrade.
        "from_version" => from_version,
        # When the release above was published, ISO 8601, or absent when the index was not read for
        # this package. Null is a statement — nobody recorded the date — and the service stores it
        # as sent rather than checking a clock it has no egress to check against.
        "published_at" => published_at,
        # The bare member or argument name, which is what a caller can match against the names
        # their own code uses. The library is a field beside it.
        "subject" => finding.subject,
        # Where the name went, for the three mechanisms that have a destination: the new name for a
        # rename, the importable path for a move, the argument that replaced a renamed one. Sent as
        # one field because it is one question — "what do I change my code to" — and the service
        # already has `change_kind` to say which of those it is. A removal sends None.
        "replacement" => finding.replacement || finding.moved,
        # What the release did, from the five mechanisms an executed differential can establish.
        "change_kind" => finding.mechanism,
        "resolution" => finding.resolution || "",
        "trace" => finding.trace || ""
      }
    end

    # What was run against both releases, in the words of what was run.
    #
    # A symbol finding's evidence is that a reference *resolved* on the old release and raised on
    # the new one — there is no argument anywhere in it, and a body that said "accepted the
    # argument" would be describing a call this finding never made. The service stores this field as
    # the attempt, so a wrong sentence here is not a wording problem: it is a report whose evidence
    # does not match its own trace.
    def self.attempted_for(finding, from_version:)
      note = finding.notes.first || ""
      if finding.mechanism == Mechanism::SYMBOL_MOVED
        # The evidence for a move is two references: the one that raised where the caller wrote it,
        # and the one that resolved where the release keeps it. A body carrying only the first
        # would be describing a removal.
        return ("Ran a reference to `#{finding.library}.#{finding.subject}` against " \
                "#{finding.library} #{from_version}: that release resolved it. " \
                "#{finding.library} #{finding.version} raises. Reading `#{finding.moved}` " \
                "against #{finding.library} #{finding.version} resolved, so the name is still " \
                "exported. #{note}").strip
      end
      if Mechanism.symbol?(finding.mechanism)
        return ("Ran a reference to `#{finding.library}.#{finding.subject}` against " \
                "#{finding.library} #{from_version}: that release resolved it. " \
                "#{finding.library} #{finding.version} raises. #{note}").strip
      end

      ("Ran the same call against #{finding.library} #{from_version}: that release accepted the " \
       "argument. #{finding.library} #{finding.version} refuses it. #{note}").strip
    end

    # One line for a run's log: what was found, and how much backs it.
    def self.summary_for(finding)
      "#{finding.library} #{finding.version}: #{finding.title} " \
        "(#{finding.call_sites} call site(s), #{finding.repaired_call_sites} repaired)"
    end

    # What `POST /api/reports/precheck` accepts, which is deliberately narrower than what `POST
    # /api/reports` accepts: the precheck answers "is this already known", so it takes the fields the
    # comparison reads and refuses the rest — the models are strict, and sending the whole body to
    # both is what made the kind a field submit took and precheck refused. `environment` and
    # `attempted` do not affect a verdict, so they are dropped here rather than sent and rejected.
    #
    # An array and not a Set, because the order is the order the fields go on the wire, and a
    # precheck body whose fields were reordered is one more difference to explain for no reason.
    PRECHECK_FIELDS = %w[title library version subject_kind problem resolution trace].freeze

    # The draft to ask about, built from the body that would be submitted.
    #
    # Derived from the submit body rather than written a second time, so the two cannot disagree
    # about what the finding says — which is the whole reason the service compares one draft
    # implementation against itself.
    #
    # `trace` and `resolution` are sent even when empty, because the service's strict models reject
    # a null where a string is expected and drop empty strings before storing them — so the shape is
    # the same either way and the miner never sends a field the comparison would refuse.
    def self.precheck_payload_for(payload)
      PRECHECK_FIELDS.each_with_object({}) do |field, draft|
        value = payload[field]
        draft[field] = value unless value.nil?
      end
    end
  end
end
