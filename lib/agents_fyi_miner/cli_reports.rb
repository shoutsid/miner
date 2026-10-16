# frozen_string_literal: true

require "pathname"

require_relative "corpus"
require_relative "envs"
require_relative "errors"
require_relative "mine"
require_relative "solving"
require_relative "versions"

module AgentsFyiMiner
  # `solve` as a one-off run: read the corpus, and answer what can be answered.
  #
  # `serve` does this every cycle with a ledger behind it; this is the same work without the loop,
  # which is what makes it usable against a specific report while the service is being debugged —
  # and what makes the whole path testable without a long-running process. Both go through
  # `Solving`, so neither can decide a fix is justified by a rule the other does not have.
  module CliReports
    # A page big enough that a small corpus is read in one request, and the change feed's own
    # ceiling is what bounds it beyond that.
    PAGE = 100

    # How many open reports one `solve` run takes on when the operator did not say. Not zero and
    # not unbounded: every report is a release of its own to install, so this is a budget in
    # *minutes*, which is why it is smaller than the mining budget.
    DEFAULT_LIMIT = 200

    # Every report in the corpus that is a question the differential could answer.
    #
    # Walked through the change feed rather than through search: the question is "what is
    # unanswered", which is a property of the corpus rather than of a query somebody already
    # knows how to write. The feed returns oldest first, so the first page is the oldest
    # unanswered reports — which is the right end to start from, since those are the ones nobody
    # has got to.
    #
    # This account's own reports are left out for the same reason the service leaves them out —
    # see `Solving.ours?` — and the omission was once missing here alone: the command selected
    # sixteen of its own reports and set about running a full differential against each, which is
    # not a slow query but minutes of work per report to reach a conclusion the corpus already
    # holds.
    def self.open_questions(session, limit: DEFAULT_LIMIT)
      operator_id = session.me["id"].to_s
      operator_id = nil if operator_id.empty?
      found = []
      since = nil
      since_id = nil
      while found.length < limit
        page = session.changes(since: since, since_id: since_id, limit: PAGE)
        Array(page["items"]).each do |report|
          next if report["hidden"] || Solving.ours?(report, operator_id)
          next unless Solving.needs_a_fix?(report) || Solving.needs_reproduction?(report)

          found << report
          break if found.length >= limit
        end
        break unless page["has_more"]

        # The cursor, not an offset: the feed is a position in a stream of changes, and a
        # report filed while this walk is running has to be reachable by a later cycle.
        since = page["next_since"]
        since_id = page["next_since_id"]
      end
      found
    end

    # Attempt one report and return the outcome as one word.
    #
    # The claim is taken and released around the work for the same reason the service does it:
    # environment building is minutes of a shared machine, and two miners deriving the same fix
    # is the waste the corpus's claims exist to stop.
    #
    # `args` is duck-typed rather than a `Cli::Args`: this module is called by `solve` and by the
    # service's own `answer`, and requiring the command line from here would make the one-off run
    # the only shape this could take. It reads two fields — `home` and `dry_run`.
    def self.answer_one(session, report, args)
      report_id = report["id"].to_s
      # Claimed only when there is a gap to fill: the corpus refuses a claim on a report that
      # already carries a fix, deliberately, so claiming first would stop this ever reaching the
      # reproduction it was selected to give.
      claimed = Solving.needs_a_fix?(report)
      if claimed
        begin
          session.claim(report_id)
        rescue Errors::CollectionPaused
          # A one-off run has no loop to wait in, and the report is not what is closed — the
          # index is. Raised so `profile` stops the run with the service's own sentence, rather
          # than printing "unavailable" once per report in a queue it cannot answer any of.
          raise
        rescue Errors::CorpusError => e
          return "unavailable: #{e.message}"
        end
      end

      begin
        begin
          history = Versions.release_history(report["library"], cache: args.home + "index")
        rescue Versions::NoHistory => e
          return "no history: #{e.message}"
        end
        pairs = Solving.pairs_for_report(report, history)
        return "no release line to compare" if pairs.empty?

        pair = pairs[0]
        $stderr.puts("[solve] #{report_id}: #{pair.package} #{pair.from_version}->#{pair.to_version}")
        begin
          before = Envs.build(pair.package, pair.from_version, home: args.home + "envs")
          after = Envs.build(pair.package, pair.to_version, home: args.home + "envs")
          findings = Mine.findings_between(pair.package, pair.from_version, pair.to_version,
            before, after)
        rescue Errors::MinerError => e
          return "could not examine: #{e.message}"
        end

        findings.each do |finding|
          answer = Solving.answer_for(report, finding, pair)
          next if answer.nil?

          return "would #{answer.kind}: #{answer.summary}" if args.dry_run

          if answer.kind == "resolution"
            session.propose_resolution(report_id, answer.payload)
          else
            session.verify(report_id, answer.payload)
          end
          return "#{answer.kind}: #{answer.summary}"
        end
        "no mechanism: #{findings.length} finding(s), none naming this argument"
      ensure
        if claimed
          begin
            session.release(report_id)
          rescue Errors::CorpusError => e
            $stderr.puts("[solve] could not release #{report_id}: #{e.message}")
          end
        end
      end
    end

    # The `solve` command: answer as many open reports as the budget allows.
    #
    # Returns 0 in every case it completes, including "nothing open": the run did what it was
    # asked and the corpus had no question for it, which is not a failure — the exit status a
    # cron reads is for a run that could not be made at all.
    def self.profile(session, args)
      questions = open_questions(session, limit: args.limit.positive? ? args.limit : DEFAULT_LIMIT)
      if questions.empty?
        $stderr.puts("nothing open that this miner could answer")
        return 0
      end
      $stderr.puts("#{questions.length} report(s) this miner could answer")
      answered = 0
      questions.each do |report|
        begin
          outcome = answer_one(session, report, args)
        rescue Errors::CollectionPaused => e
          # Stops the run rather than walking the rest of the queue: every remaining report is in
          # an index that is closed, so the loop would print the same refusal once per report and
          # answer none of them.
          $stderr.puts("collection is paused, so this run stopped: #{e.message}")
          break
        end
        $stderr.puts("[#{outcome}] #{report['library']} #{report['version']}: " \
                     "#{report['title'].to_s[0, 70]}")
        answered += 1 if outcome.start_with?("resolution", "verification", "would")
      end
      $stderr.puts("answered #{answered} report(s)")
      0
    end
  end
end
