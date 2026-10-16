# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "errors"
require_relative "machine"

module AgentsFyiMiner
  # What this miner has already done, so a service restart is not a redo.
  #
  # A single `publish` run gets to forget: it is invoked for a purpose and exits. A service
  # does not. It runs for weeks, it is restarted by a deploy or a power cut, and the thing it
  # must never do is spend its day re-deriving a finding it filed yesterday — or, worse, spend
  # its whole rate limit re-asking the corpus about work it has already done. So the work list
  # is durable state, and this class is it.
  #
  # Two decisions are worth stating, because both are the difference between a ledger that
  # helps and one that silently stops the miner.
  #
  # The first is that a *failed* pair is retried and an *examined* pair is not. A package with
  # no wheel for this interpreter, or one whose import needs something its metadata does not
  # declare, is a package that cannot be examined today and may be examinable tomorrow; a
  # package that was successfully compared to its predecessor is settled whatever the
  # comparison found, including finding nothing. Conflating the two either abandons real
  # packages or re-installs the same wheels forever.
  #
  # The second is that yield is recorded per pair rather than inferred, so the planner can stop
  # spending the miner's time on a package that has produced nothing across three releases.
  # That is a *scheduling* input, not a verdict: the entries stay, and a package that yields
  # nothing today is one the miner comes back to when it has mined everything else.
  #
  class Ledger
    # Bumped when the stored shape changes in a way this class cannot read. A ledger whose
    # schema this version does not understand is set aside rather than guessed at: a wrong
    # parse would either redo months of work or, far worse, mark it done.
    SCHEMA_VERSION = 1

    # What a pair's record means. `done` and `empty` are both *examined* — the difference is
    # only whether the comparison produced anything, which the planner reads as yield. `failed`
    # means the pair could not be examined at all, and will be tried again.
    DONE = "done"
    EMPTY = "empty"
    FAILED = "failed"

    # And the other way a pair cannot be examined: it never will be, on this machine. A release
    # that is not on the index, that has no wheel for this interpreter and no source that
    # builds, or that this interpreter cannot even parse is a fact about the release rather
    # than a bad minute, and asking pip again reaches the same answer.
    #
    # It is its own word because the two are settled differently and read differently: `failed`
    # is retried up to `MAX_PAIR_ATTEMPTS`, and a pair that has been attempted three times is
    # treated as settled whether or not the reason was permanent — which is how a network blip
    # used to retire a pair for good. `unexaminable` is settled on the first attempt, because
    # the first attempt established everything there is to establish.
    UNEXAMINABLE = "unexaminable"

    # Which machine the environment facts in this ledger were established on.
    #
    # An `unexaminable` record is a fact about a release *and* about the machine that tried
    # it: an sdist with no wheel is refused because no wheel exists for this interpreter, and
    # a gem's C extension is refused because this machine has no compiler for it. Both become
    # examinable when the image moves on, which is the one change an operator makes that would
    # otherwise leave a blind spot behind for ever — so the fact is stamped with the machine
    # that produced it and stops counting when it no longer matches.
    #
    # It is a default rather than the last word: a ledger belongs to one index, and
    # `Ledger#machine=` is what the service sets — the Ruby ledger's facts are about this
    # machine's Ruby, and stamping them `cpython 3.12` was how 1,844 gem pairs here came to be
    # settled by a change to the Python interpreter.
    MACHINE = Machine.python

    # And for a report: `proposed` and `no_mechanism` are settled, `failed` retries.
    PROPOSED = "proposed"
    NO_MECHANISM = "no_mechanism"
    NO_PAIR = "no_pair"

    # The other thing that can happen to a report: somebody *checked* it. These are the
    # service's own `verify` outcomes, spelled the way it stores them, because they are the
    # same three words the vote is cast with — a ledger that renamed them would be a second
    # vocabulary for one fact.
    REPRODUCED = "reproduced"
    DISSENTED = "did_not_reproduce"
    PARTIAL = "partial"

    SETTLED_PAIR = [DONE, EMPTY].freeze
    # Pairs that will not be worked on again, whether or not anything was established about
    # them. `unexaminable` is here and deliberately *not* in `SETTLED_PAIR`, which is the yield
    # signal: a package whose releases cannot be examined has been examined zero times, and
    # counting it as work done is how a package that produced nothing looks like a package that
    # was looked at.
    UNAVAILABLE_PAIR = [UNEXAMINABLE].freeze
    # A vote is settled whatever it said: re-running an execution reaches the same answer, and
    # the corpus keeps one verification per operator per report anyway.
    SETTLED_REPORT = [PROPOSED, NO_MECHANISM, NO_PAIR, REPRODUCED, DISSENTED, PARTIAL].freeze

    # How many times a pair may be attempted before the ledger treats it as settled anyway.
    # Without a ceiling, a package that fails for a reason that never changes — a name that is
    # not on the index, an sdist with no wheel and no compiler — would be attempted again on
    # every pass for the life of the service, which is the redo this class exists to prevent.
    # Three is enough to ride out a network blip or an index outage.
    MAX_PAIR_ATTEMPTS = 3

    # And the same ceiling for a report, which is a different kind of thing. A report is retried
    # by the verifier when an install failed for a reason that may pass, and the two ceilings
    # agree today. Named separately because they answer different questions — "how many times
    # may this crossing be attempted" against "how many times may this report be checked" — and
    # a shared constant named for one of its two users is the shape that drifts the moment the
    # two need to diverge.
    MAX_REPORT_ATTEMPTS = 3

    # One pair, as the key it is stored under.
    #
    def self.key(package, from_version, to_version) = "#{package} #{from_version}->#{to_version}"

    # The package a stored key belongs to: `"httpx 0.27.0->0.28.0"` -> `"httpx"`.
    #
    # A pair key is `"{package} {from}->{to}"` and a package name never contains a space, so
    # splitting at the first one is the same test a prefix search would perform — and the test
    # `releases_that_cannot_be_built` and `unexaminable` both need. Written once because three
    # readings of a key that disagree is a count that changes with the reader.
    def self.package_of(key) = key.split(" ", 2).first

    # The `"{from}->{to}"` half, for the one case that needs it: a failure raised before the
    # installer said which release it was about, which is still worth reporting.
    def self.versions_of(key) = key.split(" ", 2)[1].to_s

    # One release, spelled the way the installers spell it.
    #
    # It is `Errors.release_of` now: it is what `record_pair` is handed as `release` and what
    # the verifier looks a fact up by, and three copies of one spelling is how a fact comes to
    # never expire.
    def self.release_of(package, version) = Errors.release_of(package, version)

    # What happened to one upgrade, and when it may be tried again.
    #
    class PairRecord
      FIELDS = %w[attempts findings filed outcome at next_at note release machine].freeze

      attr_accessor :attempts, :findings, :filed, :outcome, :at, :next_at, :note, :release,
        :machine

      # `release` and `machine` are additive with defaults, so no schema bump: bumping would
      # have set every existing ledger aside and redone months of settled work.
      #
      # `release` is the release this pair failed to have built, when the failure was permanent
      # — `"wrapt 1.13.3"` — and it is here rather than only inside `note` because it is the key
      # the *schedule* needs: a release is shared by every crossing that runs through it, so one
      # unbuildable release is one fact about a package rather than one fact per pair.
      #
      # `machine` is the machine the fact was established on (`ruby 3.3.12 cc`). Empty on a
      # record written before the field existed, which is read as "this one" — the alternative
      # would be to distrust facts established a moment ago on the machine asking. Spelled
      # `interpreter` in a ledger written before the toolchain was named, and `from_h` reads
      # that spelling, because the two are one fact.
      def initialize(attempts: 0, findings: 0, filed: 0, outcome: FAILED, at: 0.0, next_at: 0.0,
                     note: "", release: "", machine: "")
        @attempts = attempts
        @findings = findings
        @filed = filed
        @outcome = outcome
        @at = at
        @next_at = next_at
        @note = note
        @release = release
        @machine = machine
      end

      def to_h
        { "attempts" => @attempts, "findings" => @findings, "filed" => @filed,
          "outcome" => @outcome, "at" => @at, "next_at" => @next_at, "note" => @note,
          "release" => @release, "machine" => @machine }
      end

      # One record, reading the field that was renamed on the way in, and refusing a field this
      # version does not know.
      #
      # The stamp was called `interpreter` until the toolchain became half of it. A ledger
      # written then holds facts that are still true — established on this machine, under a
      # spelling that named half of it — so the old name is read into the new field rather than
      # the file being refused, and the *value* is kept as it was: it differs from what this
      # machine now writes, which is the point, so every fact it covers is re-opened rather
      # than trusted.
      #
      def self.from_h(value)
        record = value.to_h.transform_keys(&:to_s)
        record["machine"] = record.delete("interpreter") if record.key?("interpreter")
        unknown = record.keys - FIELDS
        raise ArgumentError, "pair record has unknown field(s): #{unknown.join(', ')}" if unknown.any?

        new(
          attempts: record.fetch("attempts", 0),
          findings: record.fetch("findings", 0),
          filed: record.fetch("filed", 0),
          outcome: record.fetch("outcome", FAILED),
          at: record.fetch("at", 0.0),
          next_at: record.fetch("next_at", 0.0),
          note: record.fetch("note", ""),
          release: record.fetch("release", ""),
          machine: record.fetch("machine", "")
        )
      end
    end

    # What happened to one report this miner tried to solve.
    class ReportRecord
      FIELDS = %w[attempts outcome at next_at note].freeze

      attr_accessor :attempts, :outcome, :at, :next_at, :note

      def initialize(attempts: 0, outcome: FAILED, at: 0.0, next_at: 0.0, note: "")
        @attempts = attempts
        @outcome = outcome
        @at = at
        @next_at = next_at
        @note = note
      end

      def to_h
        { "attempts" => @attempts, "outcome" => @outcome, "at" => @at, "next_at" => @next_at,
          "note" => @note }
      end

      def self.from_h(value)
        record = value.to_h.transform_keys(&:to_s)
        unknown = record.keys - FIELDS
        raise ArgumentError, "report record has unknown field(s): #{unknown.join(', ')}" if unknown.any?

        new(
          attempts: record.fetch("attempts", 0),
          outcome: record.fetch("outcome", FAILED),
          at: record.fetch("at", 0.0),
          next_at: record.fetch("next_at", 0.0),
          note: record.fetch("note", "")
        )
      end
    end

    # One package's scheduling signal, from one pass over the pairs.
    #
    # The three numbers the planner orders by, together because they come from the same scan of
    # the same records. Computing them apart is how the schedule came to walk the whole ledger
    # once per question per candidate: `settled`, `yielded` and the last touch were three
    # separate reads of every pair.
    #
    PackageTotals = Data.define(:settled, :yielded, :last) do
      def self.empty = new(settled: 0, yielded: 0, last: 0.0)
    end

    attr_accessor :pairs, :reports, :backlog, :releases, :release_interpreters, :statuses,
      :cursor_since, :cursor_id, :machine
    # `record_pair` drops both, which is the only way either can become stale.
    attr_accessor :unbuildable_index, :totals_index

    def initialize(pairs: {}, reports: {}, backlog: {}, releases: {},
                   release_interpreters: {}, statuses: {}, cursor_since: nil, cursor_id: nil,
                   machine: MACHINE)
      @pairs = pairs
      @reports = reports
      # Every report this miner has *seen*, whether or not it has attempted it.
      #
      # This is what makes the solver's work list a set of open questions rather than a set of
      # recent changes. The change feed is a cursor — a position — and a report that existed
      # before the miner did is behind that position forever: the corpus's own backlog of
      # unanswered reports would never be visited by the process built to answer them. So the
      # feed fills this, an attempt or a decision-not-to empties it, and what is left is
      # re-examined every cycle.
      @backlog = backlog
      # `release -> reason` for the releases *this* machine has established it cannot produce,
      # recorded by the verifier rather than derived from pairs: a verifier has no pairs — it is
      # handed one report at a time — so the release is the only key it ever learns, and it is
      # the key the fact is about. Empty on a ledger written before the field existed, which
      # reads as "nothing established".
      @releases = releases
      # `release -> machine` for the entries above. A release fact is a fact about a release
      # *and* about the machine that tried it, the same as an `unexaminable` pair. Kept beside
      # the reason rather than folded into it so a ledger written before the field existed still
      # reads — an absent stamp means "this machine", exactly as `PairRecord#machine` reads it.
      @release_interpreters = release_interpreters
      # `report id -> the status the feed last reported`, which is what lets a reader skip a
      # settled report without fetching its body. Kept beside the backlog rather than inside it
      # because the backlog's value is a *time* and its ordering is the whole reason it exists;
      # this is a fact that is overwritten every pass.
      @statuses = statuses
      # Where in the corpus's change feed this miner has read to. Kept here rather than in a
      # second file because it is the same kind of fact as the rest of the ledger — "what this
      # miner has already seen" — and because a cursor advanced separately from the work it
      # describes is a cursor that can point past a report the work never reached.
      @cursor_since = cursor_since
      @cursor_id = cursor_id
      # Which machine this ledger's facts are about, since it holds one index's work. Not part
      # of the payload: it describes the machine *reading and writing* the records rather than
      # anything they say, and a ledger loaded on a machine with a different toolchain would
      # otherwise inherit an identity from the file.
      @machine = machine
      # `package -> {release: reason}` for the releases this machine has established it cannot
      # produce, derived from `pairs` and cached because it is read once per crossing
      # considered rather than once per cycle.
      @unbuildable_index = nil
      # `package -> PackageTotals`, derived from `pairs` and cached for the same reason and with
      # the same lifetime: it is a read of every record, and the schedule asks for one package's
      # numbers once per candidate per cycle — so building it once and looking it up is O(pairs)
      # per invalidation against O(pairs x watchlist) before.
      @totals_index = nil
    end

    # --- pairs ----------------------------------------------------------------------------

    def pair(package, from_version, to_version)
      @pairs[Ledger.key(package, from_version, to_version)]
    end

    # Which of this package's releases this machine cannot produce, and why.
    #
    # The record is per pair, because a pair is what was attempted; the *fact* is per release,
    # because a release is the old side of several crossings — twelve of them for a mature
    # package. Without this the schedule asks pip about `wrapt 1.13.3` once per crossing, which
    # is the same question eleven times and eleven of this cycle's pair slots spent on work that
    # cannot happen.
    def releases_that_cannot_be_built(package)
      if @unbuildable_index.nil?
        index = {}
        @pairs.each do |key, record|
          next unless record.outcome == UNEXAMINABLE && !record.release.empty?
          # Established by a machine this service no longer runs — another interpreter, or this
          # one without a compiler — which is exactly how an sdist with no wheel becomes
          # installable.
          next unless ["", @machine].include?(record.machine)

          lines = record.note.to_s.strip.split(/\r\n|\r|\n/)
          per_package = (index[Ledger.package_of(key)] ||= {})
          next if per_package.key?(record.release)

          per_package[record.release] = lines.empty? ? "" : lines[0][0, 120].to_s
        end
        @unbuildable_index = index
      end
      @unbuildable_index.fetch(package, {})
    end

    # Whether this pair should be left alone, now or forever.
    #
    # `MAX_PAIR_ATTEMPTS` is folded in here rather than at the call site so there is one answer
    # to "will this be tried again" — the planner asks this and does not re-derive it. A pair
    # the environment cannot produce is settled whatever its attempt count, which is the one
    # outcome that does not need the ceiling: the ceiling exists to stop a transient failure
    # being retried for ever, and this one is not transient.
    #
    # A release that cannot be built settles *every* crossing through it, recorded or not,
    # because the second crossing would ask pip the same question the first one already
    # answered.
    def settled_pair?(package, from_version, to_version)
      record = pair(package, from_version, to_version)
      if record && UNAVAILABLE_PAIR.include?(record.outcome)
        # Settled for this machine, and only for it.
        return ["", @machine].include?(record.machine)
      end
      blocked = releases_that_cannot_be_built(package)
      if !blocked.empty? &&
         (blocked.key?(Ledger.release_of(package, from_version)) ||
          blocked.key?(Ledger.release_of(package, to_version)))
        return true
      end
      return false if record.nil?

      SETTLED_PAIR.include?(record.outcome) || record.attempts >= MAX_PAIR_ATTEMPTS
    end

    # Whether this pair should be worked on now, by both tests.
    def due?(package, from_version, to_version, now:)
      return false if settled_pair?(package, from_version, to_version)

      record = pair(package, from_version, to_version)
      record.nil? || record.next_at <= now
    end

    # Write down what this attempt did, and when the next one is allowed.
    def record_pair(package, from_version, to_version, outcome:, findings: 0, filed: 0,
                    next_at: nil, note: "", release: "", now: nil, machine: nil)
      moment = now.nil? ? Time.now.to_f : now
      previous = pair(package, from_version, to_version) || PairRecord.new
      record = PairRecord.new(
        attempts: previous.attempts + 1,
        findings: findings,
        filed: filed,
        outcome: outcome,
        at: moment,
        next_at: next_at.nil? ? moment : next_at,
        note: note,
        release: release.empty? ? previous.release : release,
        machine: machine.nil? ? @machine : machine
      )
      @pairs[Ledger.key(package, from_version, to_version)] = record
      # The derived indexes are reads of these records, and one just changed.
      @unbuildable_index = nil
      @totals_index = nil
      record
    end

    # This package's scheduling signal, out of the derived index.
    #
    # One lookup rather than one walk of the ledger per question. The values are the ones the
    # three separate scans produced — examined pairs, the findings they yielded, and the latest
    # moment any pair was touched — and they are derived together because they come from the
    # same records.
    def package_totals(package)
      @totals_index = derive_totals if @totals_index.nil?
      @totals_index.fetch(package, PackageTotals.empty)
    end

    # One pass over every pair, yielding every package's numbers at once.
    #
    # A pair counts as examined only when its outcome is settled: `unexaminable` is deliberately
    # not in `SETTLED_PAIR`, so a package whose releases cannot be built here reads as examined
    # zero times rather than as work done. The last touch is read from every record whatever its
    # outcome, because "when was this package last worked on" is a fact about the attempt and
    # not about how it turned out.
    def derive_totals
      running = Hash.new { |hash, package| hash[package] = [0, 0, 0.0] }
      @pairs.each do |key, record|
        totals = running[Ledger.package_of(key)]
        if SETTLED_PAIR.include?(record.outcome)
          totals[0] += 1
          totals[1] += record.findings
        end
        totals[2] = record.at if record.at && record.at > totals[2]
      end
      running.transform_values do |examined, found, latest|
        PackageTotals.new(settled: examined, yielded: found, last: latest)
      end
    end

    # How many findings this package has produced across every pair tried.
    def yielded(package) = package_totals(package).yielded

    # How many of this package's pairs have been examined, whatever they found.
    #
    # Paired with `yielded` this is the whole scheduling signal, and it needs no release history:
    # "twelve releases examined, nothing found" is a statement about the ledger, and asking the
    # index to re-derive it would make the planner's ordering depend on a network fetch per
    # package per cycle.
    #
    # Both readings come from `package_totals`, so the ledger is walked once per invalidation
    # rather than once per question.
    def settled(package) = package_totals(package).settled

    # The releases here the environment could not produce, with the reason.
    #
    # One entry per release, not per pair: twelve crossings through one unbuildable release are
    # one fact, and the planner's reader needs to see `wrapt 1.13.3` once rather than twelve
    # versions of the same sentence. A release that was never named — a failure raised before
    # the installer said which release it was about — is still reported, under the pair it
    # happened to, because "this pair cannot be examined" is itself worth knowing.
    #
    def unexaminable(package)
      unexaminable_facts(package).map { |release, note| note.empty? ? release : "#{release} (#{note})" }
    end

    # The same releases as the facts behind that sentence: `[["wrapt 1.13.3", "no wheel..."], ...]`.
    #
    # Two readings of one walk, because a sentence and a record must not be able to disagree — a
    # package the log calls unexaminable and a service never told about is exactly the drift this
    # pair of methods exists to prevent.
    def unexaminable_facts(package)
      facts = releases_that_cannot_be_built(package).dup
      @pairs.each do |key, record|
        next unless record.outcome == UNEXAMINABLE && record.release.empty?
        next unless Ledger.package_of(key) == package
        next unless ["", @machine].include?(record.machine)

        # A failure raised before the installer said which release it was about still says this
        # pair cannot be examined, under the pair it happened to.
        facts[Ledger.versions_of(key)] ||= ""
      end
      facts.to_a
    end

    # Every release this machine cannot build, as the picture a service records: one entry per
    # release, with the stamp of the machine that established it.
    #
    # The service's write *replaces* what it held — absence is how a fact is retracted — so a
    # sender that named one package at a time would erase the others. This is the whole picture,
    # built in one pass over the pairs because the package list comes from the records themselves:
    # a fact about a release this miner no longer has on its watchlist is still a fact about this
    # machine, and the ledger is where facts live.
    def unexaminable_picture
      packages = @pairs.filter_map do |key, record|
        next unless record.outcome == UNEXAMINABLE && ["", @machine].include?(record.machine)

        Ledger.package_of(key)
      end.uniq.sort
      { machine: @machine,
        records: packages.flat_map do |package|
          unexaminable_facts(package).map do |release, note|
            { package: package, release: release, reason: note }
          end
        end }
    end

    # --- reports --------------------------------------------------------------------------

    def report(report_id) = @reports[report_id]

    # Remember a release this machine cannot produce, and why.
    #
    # The verifier's half of the fact the miner records per pair: reports arrive one at a time
    # from the feed, so a release that cannot be installed is discovered *once per report that
    # shares it* — twenty-four of them for `kornia 0.5.11` here, each paying the install in full
    # and each spending one of the cycle's slots on work that cannot happen. The fact belongs to
    # the release: `kornia 0.5.11` is one thing to build, whatever any report says about it.
    #
    # Recorded rather than derived, because the verifier's reports know their library and
    # version but not the interpreter that failed to build them — so the ledger stamps that
    # interpreter here, the way `record_pair` stamps it on a pair. Without the stamp this was the
    # one environment fact with no expiry: an sdist refused for having no `cp312` wheel stayed
    # refused after the image moved to `cp313`, and every report that shared the release was
    # skipped for ever on a fact that had stopped being true.
    #
    def record_release(release, reason, machine: nil)
      @releases[release] = reason[0, 200].to_s
      @release_interpreters[release] = machine.nil? ? @machine : machine
    end

    # Why this machine cannot produce that release, if it has established that.
    #
    # Scoped to this machine, like `releases_that_cannot_be_built`: a stamp from another
    # interpreter, or from this one without a compiler, is a question the schedule has gone back
    # to asking, and an absent stamp — a ledger written before the stamp existed — reads as
    # "this one", the same rule `PairRecord#machine` uses. Returning another machine's failure
    # here would skip a release this one can build.
    def cannot_build(release, machine: nil)
      reason = @releases[release]
      return nil if reason.nil?

      wanted = machine.nil? ? @machine : machine
      return nil unless ["", wanted].include?(@release_interpreters.fetch(release, ""))

      reason
    end

    # Remember a report, without disturbing when it was first seen.
    #
    # First-seen rather than last-seen because the order is a priority: the oldest unanswered
    # report in the corpus is the one nobody has got to, and it is worth more to whoever is
    # still hitting it than one filed an hour ago.
    #
    # `status` is *last*-seen, and it is the exception to that rule for the same reason the order
    # exists: a report's status is what decides whether it is worth reading at all, and the feed
    # carries it. A client that has to fetch the body to learn "already confirmed" spends one
    # request per settled report in the corpus every pass, and — worse — spends its *look* budget
    # on them, so a backlog of 2,933 mostly-settled reports kept this verifier 2,933 reports away
    # from work filed an hour ago.
    def note_seen(report_id, now: nil, status: "")
      @backlog[report_id] = now.nil? ? Time.now.to_f : now unless @backlog.key?(report_id)
      @statuses[report_id] = status unless status.empty?
    end

    # What the feed last said this report's status was, or `""` if it never did.
    def status_of(report_id) = @statuses.fetch(report_id, "")

    def seen?(report_id) = @backlog.key?(report_id)

    # Stop considering a report, because nothing here will ever answer it.
    def drop_seen(report_id) = @backlog.delete(report_id)

    # Reports seen and not yet attempted, oldest first.
    #
    # The index is the tiebreak, because two reports noted in the same moment have to come
    # back in the order they were noted: the Python client's `sorted` is stable and Ruby's
    # `sort_by` is not, so a client that dropped the second key would answer a different queue
    # than the one this ledger replaced — and only when two reports share a timestamp, which
    # is exactly what a feed page does.
    def unresolved_seen
      @backlog.each_with_index
              .reject { |(report_id, _moment), _index| settled_report?(report_id) }
              .sort_by { |(_report_id, moment), index| [moment, index] }
              .map { |(report_id, _moment), _index| report_id }
    end

    def settled_report?(report_id)
      record = report(report_id)
      return false if record.nil?

      SETTLED_REPORT.include?(record.outcome) || record.attempts >= MAX_REPORT_ATTEMPTS
    end

    #
    def due_report?(report_id, now:)
      return false if settled_report?(report_id)

      record = report(report_id)
      record.nil? || record.next_at <= now
    end

    def record_report(report_id, outcome:, next_at: nil, note: "", now: nil)
      moment = now.nil? ? Time.now.to_f : now
      previous = report(report_id) || ReportRecord.new
      record = ReportRecord.new(
        attempts: previous.attempts + 1,
        outcome: outcome,
        at: moment,
        next_at: next_at.nil? ? moment : next_at,
        note: note
      )
      @reports[report_id] = record
      record
    end

    # --- persistence ----------------------------------------------------------------------

    def to_h
      {
        "schema_version" => SCHEMA_VERSION,
        "pairs" => @pairs.transform_values(&:to_h),
        "reports" => @reports.transform_values(&:to_h),
        "backlog" => @backlog,
        "releases" => @releases,
        "release_interpreters" => @release_interpreters,
        "statuses" => @statuses,
        "cursor_since" => @cursor_since,
        "cursor_id" => @cursor_id
      }
    end

    # Read a ledger, or refuse it whole.
    #
    # Refusing is the point: a partially understood ledger is one that will either redo settled
    # work or, worse, report it settled. The caller decides what to do with a refusal, and `load`
    # files the unreadable copy beside the original rather than deleting it.
    #
    # `ArgumentError` is Ruby's `ValueError` — the caller (`load`) catches it, and so does a
    # ledger test that only wants to know a future schema is refused.
    def self.from_json(payload)
      version = payload["schema_version"]
      raise ArgumentError, "ledger schema #{version.inspect} is not readable" if version != SCHEMA_VERSION

      new(
        pairs: (payload["pairs"] || {}).to_h { |key, value| [key, PairRecord.from_h(value)] },
        reports: (payload["reports"] || {}).to_h { |key, value| [key, ReportRecord.from_h(value)] },
        backlog: (payload["backlog"] || {}).to_h { |key, value| [key, Float(value)] },
        releases: (payload["releases"] || {}).to_h { |key, value| [key, value.to_s] },
        release_interpreters: (payload["release_interpreters"] || {}).to_h do |key, value|
          [key, value.to_s]
        end,
        statuses: (payload["statuses"] || {}).to_h { |key, value| [key, value.to_s] },
        cursor_since: payload["cursor_since"],
        cursor_id: payload["cursor_id"]
      )
    end

    # The ledger at `path`, or an empty one, with an unreadable file set aside.
    #
    # A ledger that cannot be read must not stop the miner and must not be discarded: the
    # service's job is to keep working, and the honest record of a bug is a file somebody can
    # look at rather than a stack trace and a lost history. Returning an empty ledger redoes
    # work; deleting the evidence hides why.
    #
    # All three mean "this file was written by something this build does not agree with".
    def self.load(path)
      path = Pathname.new(path)
      return new unless path.exist?

      begin
        # `encoding:` and not a positional argument: `Pathname#read`'s second parameter is a
        # *length*, so `read("UTF-8")` would raise instead of decoding.
        from_json(JSON.parse(path.read(encoding: "UTF-8")))
      rescue ArgumentError, TypeError, KeyError, JSON::ParserError
        aside = path.sub_ext("#{path.extname}.unreadable-#{Time.now.to_i}")
        # If the rename fails there is nothing useful to do about it: the file is still there,
        # and so is the bug it would have recorded.
        begin
          File.rename(path.to_s, aside.to_s)
        rescue SystemCallError
          nil
        end
        new
      end
    end

    # Write the ledger so that a crash cannot leave it half-written.
    #
    # Written to a neighbour and renamed: `File.rename` is atomic on the same filesystem, so a
    # reader sees the old ledger or the new one and never a truncated one. The mode is set
    # before the rename, not after, so the file is never briefly readable by another account.
    #
    def self.save(ledger, path)
      path = Pathname.new(path)
      FileUtils.mkdir_p(path.dirname)
      temporary = path.sub_ext("#{path.extname}.tmp")
      temporary.write(JSON.pretty_generate(ledger.to_h, indent: " ", object_nl: "\n",
        array_nl: "\n"))
      File.chmod(0o600, temporary.to_s)
      File.rename(temporary.to_s, path.to_s)
    end
  end
end
