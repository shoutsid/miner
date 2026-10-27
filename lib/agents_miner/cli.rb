# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "timeout"

require_relative "bandwidth"
require_relative "cli_reports"
require_relative "corpus"
require_relative "ecosystems"
require_relative "envs"
require_relative "errors"
require_relative "ledger"
require_relative "log"
require_relative "mine"
require_relative "pair"
require_relative "planner"
require_relative "reporting"
# Required rather than relied on from the glob: `SEED_FETCH_FAILURES` below names
# `RubyVersions::IndexError`, and a constant is resolved when the assignment is *evaluated* — which is
# while this file loads, before any sibling the loader has not reached yet.
require_relative "rubyversions"
require_relative "service"
require_relative "solving"
require_relative "verifier"
require_relative "verifying"
require_relative "versions"
require_relative "watchlist"

module AgentsMiner
  # The command line: which upgrades to mine, and what to do with what is found.
  #
  # Five modes, and the split is the useful part. `mine` finds findings and prints them, touching no
  # network beyond the index: it is how the differential is checked against a package you suspect,
  # and how a finding is read before anybody files it. `publish` does the same work and files the
  # result, asking the corpus first. `solve` reads the corpus and attempts to attach an executed fix
  # to a failure somebody else recorded.
  #
  # The default is to print. A tool whose first run writes to a shared corpus would make the corpus
  # the place mistakes are discovered, and a mined finding is cheap to re-derive and expensive to
  # un-file.
  #
  # `serve` is the same work as a service rather than a run: it keeps a durable ledger of what it
  # has examined, reads the corpus to decide what is worth doing next, and paces itself under the
  # service's write quota. It is what runs in the container.
  #
  # `verify` is the other half of a corpus's trust, and it is a *separate operator* on purpose: a
  # report reaches `resolved_verified` only when somebody other than its author reproduces it, so the
  # operator that files findings can never confirm them. It runs as a service of its own, under its
  # own account, with `--role` deciding how it checks — see `Verifying` for why there are two ways
  # and why both execute.
  module Cli
    DEFAULT_HOME = Pathname.new(Dir.home) + ".cache" + "agents-miner"
    DEFAULT_VERIFIER_HOME = Pathname.new(Dir.home) + ".cache" + "agents-verifier"
    DEFAULT_BASE = "https://agents.shoutsid.fyi"
    MINER_NAME = "agents reproduction miner"
    MINER_EMAIL = "miner@agents.shoutsid.fyi"

    COMMANDS = %w[mine publish solve serve verify].freeze

    # How many reports a verifier checks per cycle. Lower than the miner's budget for a reason that
    # is about cost rather than patience: every report is a release of its own to install, and a
    # cycle that installs a dozen wheels before it records anything is a cycle whose first vote
    # is minutes away. The installs run in parallel, so the wall clock is set by the pool rather
    # than by the batch.
    VERIFY_BUDGET = 12

    # Who the verifying operators are, one identity per method. Two accounts and not one: the
    # service counts *distinct* operators, so a single account checking twice would record one
    # confirmation twice over — and the two methods are two different executions, so two accounts is
    # also what the evidence says.
    VERIFIER_IDENTITIES = {
      Verifying::AS_REPORTED => ["agents claim verifier", "claim-verifier@agents.shoutsid.fyi"],
      Verifying::SEARCHED => ["agents surface verifier", "surface-verifier@agents.shoutsid.fyi"]
    }.freeze

    # How many pages of the service's mining queue one watchlist reads. The route serves `limit_max`
    # targets a page (500 today), so this is the ceiling on how much of the queue a miner can be
    # handed: 32 pages is 16,000, which is past any stored queue and costs one request per page only
    # while there is another page.
    QUEUE_PAGES = 32

    # The watchlist is derived from what people actually install rather than written here — see
    # `Watchlist` for why. This is the list used when there is no ranking to be had at all, which is
    # only a first start with no network: filing from a shorter list beats filing nothing.
    #
    # A fallback, not a curation. It is the packages this corpus was built on, kept because they are
    # demonstrably minable on this interpreter, and it deliberately stays short: a hand-written list
    # that grows is a hand-written list pretending to be data.
    WATCHLIST = %w[
      httpx requests urllib3 click rich typer starlette pydantic sqlalchemy aiohttp tenacity
      structlog orjson uvicorn attrs marshmallow jinja2 werkzeug flask fastapi numpy pandas
      websockets paramiko pytest
    ].freeze

    # A refusal *this program* produced, which is argparse's exit status 2 rather than a traceback: a
    # deployment that misspells a flag has to be told which flag, and a client that answers a
    # container restart policy with a stack trace is a client nobody can read from `docker logs`.
    class UsageError < StandardError; end

    #
    # A class rather than a Hash because every mode reads it as *attributes* — `args.home`,
    # `args.report_budget` — and the field names are the contract between this file and every mode
    # below it. The defaults are the parser's own, so an `Args` built by hand (a test, or `main`
    # before the per-mode resolution) behaves exactly like a parsed one with no flags.
    class Args
      attr_accessor :command, :package, :top, :queue_pages, :from_version, :to_version, :span,
        :limit, :base_url, :home, :state, :json, :dry_run, :cycles, :ecosystems,
        :budget, :role, :name, :email, :report_budget, :no_sleep, :heartbeat,
        :workers, :writes_per_hour, :download_mbps, :log_level

      def initialize(command: nil, package: [], top: nil, queue_pages: QUEUE_PAGES,
                     from_version: nil, to_version: nil, span: 1, limit: 0,
                     base_url: DEFAULT_BASE, home: nil, state: nil, json: false, dry_run: false,
                     cycles: 0, ecosystems: ENV.fetch("MINER_ECOSYSTEMS", "python"), budget: nil,
                     role: Verifying::AS_REPORTED, name: nil, email: nil, report_budget: 1,
                     no_sleep: false, heartbeat: nil, workers: Service::DEFAULT_WORKERS,
                     writes_per_hour: Service::WRITES_PER_HOUR,
                     download_mbps: Service::DOWNLOAD_MBPS, log_level: "INFO")
        @command = command
        @package = package
        @top = top
        @queue_pages = queue_pages
        @from_version = from_version
        @to_version = to_version
        @span = span
        @limit = limit
        @base_url = base_url
        @home = home
        @state = state
        @json = json
        @dry_run = dry_run
        @cycles = cycles
        @ecosystems = ecosystems
        @budget = budget
        @role = role
        @name = name
        @email = email
        @report_budget = report_budget
        @no_sleep = no_sleep
        @heartbeat = heartbeat
        @workers = workers
        @writes_per_hour = writes_per_hour
        @download_mbps = download_mbps
        @log_level = log_level
      end

      # What a mode reads for its own subcommand's identity: `--ecosystems` as the list a run works,
      # and the two flags that decide whether anything is written.
      def to_h
        instance_variables.to_h { |name| [name.to_s.delete_prefix("@"), instance_variable_get(name)] }
      end

      def json? = @json
      def dry_run? = @dry_run
      def no_sleep? = @no_sleep
    end

    # `optparse` in place of `argparse`, and the shape is what changed rather than the surface.
    #
    # Everything else is kept: the same flag names, the same `--from`/`--to` spellings, the
    # same defaults, the same refusal for a command that is not one of the five, and the same
    # exit status for a usage error. The `command` is a positional argument here rather than a
    # `choices` subcommand, because optparse has no notion of one and inventing a second
    # parser layer to get it back would be more machinery than one positional needs.
    class Parser
      # Deliberately no state of its own: everything a `parse` needs is local to that call, so a
      # `Parser` reused for two runs cannot carry the first one's arguments into the second.

      # The parsed arguments, or `nil` when help was asked for and printed.
      #
      # Raises `UsageError` for what argparse would have exited 2 on: an unknown flag (optparse's
      # own `OptionParser::ParseError` is translated so the caller has one refusal to handle), a
      # missing command, a command that is not one of the five, or a second positional argument.
      def parse(argv)
        args = Args.new
        # A hash rather than an instance variable, because an `on` block's `self` is optparse's to
        # decide: `@help_printed` written from inside one may land on the parser instead of here, and
        # then help would print *and* the run would start. A closure local cannot be captured
        # wrongly.
        help = { requested: false }
        remaining = option_parser(args, help).parse(argv)
        return nil if help[:requested]

        args.command = remaining.shift
        raise UsageError, "the following arguments are required: command" if args.command.nil?
        unless COMMANDS.include?(args.command)
          raise UsageError,
            "argument command: invalid choice: '#{args.command}' (choose from #{COMMANDS.join(', ')})"
        end
        # argparse had `choices=` on this flag, so a misspelling was refused before a run started.
        # Kept as a refusal rather than defaulted: a verifier started with `--role as_reported`
        # would otherwise run the *other* method under the other method's account, and the corpus
        # would record a vote the operator did not mean to cast.
        # Only for the command that has a use for it: argparse's `choices=` refused a bad role on
        # *any* command, including the ones that never read it, so `mine --role nonsense` was a
        # refusal rather than a flag nobody looks at — and the first draft of this check kept that
        # shape while inverting it, which raised for every command except `verify` and left a
        # misspelled role on the one command that casts a vote unrefused.
        if args.command == "verify" && !Verifying::ROLES.include?(args.role)
          raise UsageError, "argument --role: invalid choice: '#{args.role}' (choose from #{Verifying::ROLES.join(', ')})"
        end
        unless remaining.empty?
          raise UsageError, "unrecognized arguments: #{remaining.join(' ')}"
        end

        args
      rescue OptionParser::ParseError => e
        raise UsageError, e.message
      end

      def help = option_parser(Args.new, { requested: false }).to_s

      private

      # A fresh parser per call, bound to *this* call's `Args`. Memoising it was the obvious saving and
      # it is a trap: the option blocks close over one `args` object, so a second `parse` would fill
      # in the first call's arguments and leave its own empty — a bug that looks like flags being
      # ignored.
      def option_parser(args, help)
        OptionParser.new do |parser|
          parser.banner = "Usage: agents-miner <command> [options]"
          parser.separator("")
          parser.separator("Find real failures by executing one release's public API against the next.")
          parser.separator("")
          parser.separator("Commands: #{COMMANDS.join(', ')}")
          parser.separator("")
          parser.on("-h", "--help", "Show this message") do
            $stdout.puts parser.to_s
            help[:requested] = true
          end
          parser.on("--version", "Show the client version") do
            $stdout.puts(AgentsMiner::VERSION)
            help[:requested] = true
          end
          parser.on("--package PACKAGE", "mine this package (repeatable)") { |value| args.package << value }
          parser.on("--top N", Integer,
            "how many packages to work on when none are named (default 3000, or MINER_TOP)") do |value|
            args.top = value
          end
          parser.on("--queue-pages N", Integer, "how many pages of the service's mining queue to read " \
                                               "(default #{QUEUE_PAGES})") { |value| args.queue_pages = value }
          parser.on("--from VERSION", "release to move from") { |value| args.from_version = value }
          parser.on("--to VERSION", "release to move to") { |value| args.to_version = value }
          parser.on("--span N", Integer, "compare this many releases back") { |value| args.span = value }
          parser.on("--limit N", Integer, "cap findings per pair") { |value| args.limit = value }
          parser.on("--base-url URL", "the corpus to file into (default #{DEFAULT_BASE})") do |value|
            args.base_url = value
          end
          # Strings, then wrapped: optparse's type argument means "convert with this", and only the
          # types it knows (`Integer`, `Float`, `Array`, `String`) are unambiguous. A `Pathname`
          # built here rather than there is the same value with no dependency on optparse's own
          # coercion rules.
          parser.on("--home PATH", "where environments are kept") { |value| args.home = Pathname.new(value) }
          parser.on("--state PATH", "where the key is kept") { |value| args.state = Pathname.new(value) }
          parser.on("--json", "print findings as JSON") { args.json = true }
          parser.on("--dry-run", "with publish: check, but write nothing") { args.dry_run = true }
          parser.on("--cycles N", Integer, "with serve or verify: stop after this many cycles") do |value|
            args.cycles = value
          end
          parser.on("--ecosystems NAMES",
            "which package indexes to work, comma-separated: python (PyPI), ruby (RubyGems), " \
            "or both (default python)") { |value| args.ecosystems = value }
          parser.on("--budget N", Integer,
            "with serve: upgrades to mine per cycle (default #{Planner::DEFAULT_BUDGET}); " \
            "with verify: reports to confirm per cycle (default #{VERIFY_BUDGET})") do |value|
            args.budget = value
          end
          parser.on("--role ROLE", "with verify: how to check a claim — as-reported, or searched") do |value|
            args.role = value
          end
          parser.on("--name NAME", "the operator name to register under (default: per mode)") do |value|
            args.name = value
          end
          parser.on("--email EMAIL", "the operator email to register under (default: per mode)") do |value|
            args.email = value
          end
          parser.on("--report-budget N", Integer, "with serve: reports to answer per cycle") do |value|
            args.report_budget = value
          end
          parser.on("--no-sleep", "with serve: no waiting between cycles") { args.no_sleep = true }
          parser.on("--heartbeat PATH", "with serve: touch this file at the end of every cycle") do |value|
            args.heartbeat = Pathname.new(value)
          end
          parser.on("--workers N", Integer, "with serve: how many upgrades to examine at once " \
                                            "(default #{Service::DEFAULT_WORKERS})") { |value| args.workers = value }
          parser.on("--writes-per-hour N", Integer,
            "with serve: how many writes to allow per rolling hour; 0 means no limit") do |value|
            args.writes_per_hour = value
          end
          parser.on("--download-mbps N", Float,
            "with serve or verify: cap this container's downloads at this many MB/s; 0 means no cap") do |value|
            args.download_mbps = value
          end
          parser.on("--log-level LEVEL", "with serve: DEBUG, INFO, WARNING or ERROR") do |value|
            args.log_level = value
          end
        end
      end
    end

    def self.build_parser = Parser.new

    # How many packages to work on, from the environment, or the default.
    #
    # A deployment setting rather than a flag because the service container's command line is
    # written in `entrypoint.sh` and an operator changing it there would be editing the image's
    # plumbing to change a number about their own machine. A value that is not a positive integer
    # is ignored rather than fatal: a miner that refused to start over a typo in a tuning knob
    # would be trading all of its work for nothing.
    def self.env_top
      raw = ENV.fetch("MINER_TOP", "").strip
      return Watchlist::DEFAULT_TOP if raw.empty?

      begin
        value = Integer(raw, 10)
      rescue ArgumentError
        return Watchlist::DEFAULT_TOP
      end
      value.positive? ? value : Watchlist::DEFAULT_TOP
    end

    # The per-mode defaults, resolved in one place because one parser cannot say two defaults for
    # one flag.
    #
    # A verifier keeps its environments apart from the miner's, and its cycle is a different
    # budget for the same reason: an account that installs one release per report has a shorter
    # cycle than one examining pairs.
    def self.resolve_defaults(args)
      if args.home.nil?
        args.home = args.command == "verify" ? DEFAULT_VERIFIER_HOME : DEFAULT_HOME
      end
      if args.budget.nil?
        args.budget = args.command == "verify" ? VERIFY_BUDGET : Planner::DEFAULT_BUDGET
      end
      # The watchlist depth, in the same place and for the same reason as the two above: it
      # describes the deployment rather than any one command, and the default is a guess about
      # somebody else's machine. A miner with a fast link and a big volume can work a much longer
      # list than one sharing a small one, and running out of watchlist is silent — the container
      # keeps cycling and reports `0 pair(s)`.
      args.top ||= env_top
      args
    end

    def self.main(argv = ARGV)
      args = build_parser.parse(argv)
      return 0 if args.nil?

      resolve_defaults(args)
      # `pip` unpacks every wheel and every sdist build into `TMPDIR`, and `/tmp` in this container
      # is a tmpfs — which is RAM. Left there it held 4.1 GB within thirty-five minutes and pinned
      # the container against its own memory limit, killing installs and then the process. So the
      # scratch is set at the one place the home is decided, so every mode and every child process
      # agrees about where it is.
      Envs.use_scratch_dir(args.home)
      # And where the code under test may write, for the same reason: this container's `HOME` is
      # on a read-only root, so a release that touches `~/.config` on import is refused a write and
      # recorded as a release that cannot be imported.
      Envs.use_probe_home(args.home)
      # The download ceiling, in the same place and for the same reason: it describes this
      # deployment rather than any one command, and every mode installs releases. Off unless the
      # operator asked for it, and a limit that is a choice rather than an accident stays visible.
      Bandwidth.set_limit([args.download_mbps.to_f, 0.0].max * 1_000_000, streams: args.workers)
      return serve(args) if args.command == "serve"
      return verify(args) if args.command == "verify"

      run_once(args, solve_only: args.command == "solve")
    rescue UsageError => e
      $stderr.puts("agents-miner: error: #{e.message}")
      # argparse's status for a usage error, and it is 2 rather than 1 on purpose: 1 is "the run
      # happened and found nothing", which a supervisor retries.
      2
    end

    # Fetch each index's breadth ranking and hand it to the service.
    #
    # Never raises. The seed is the *smallest* part of the ranking — a tier below everything the
    # corpus has observed — so a start that cannot reach a third party or cannot reach the service
    # with the list is a start with a slightly narrower queue, not a start that failed. The
    # service's own queue is the part that matters, and it is read separately.
    #
    # One ranking per index, because they are different measurements of different things: PyPI's is
    # a monthly download ranking of projects and RubyGems' is an all-time one of gems. Posting
    # either as the other would seed a queue with names from the wrong index, and nothing
    # downstream would look wrong.
    def self.contribute_seed(session, args, indexes: nil)
      logger = Log.logger("agents_miner.service")
      contributed = 0
      (indexes || Ecosystems.named(args.ecosystems)).each do |ecosystem|
        if ecosystem.name == "ruby"
          fetch = -> { Watchlist.ruby_downloads(top: Watchlist::RUBY_DOWNLOADS_TOP) }
          source = Watchlist::RUBY_SEED_SOURCE
        else
          fetch = -> { Watchlist.ranking(cache: args.home + "index", top: Watchlist::DEFAULT_TOP) }
          source = Watchlist::SEED_SOURCE
        end
        begin
          projects = fetch.call
        rescue *SEED_FETCH_FAILURES => e
          logger.warning("no %s breadth seed this start: %s", ecosystem.name, e.message)
          next
        end
        begin
          session.contribute_seed(projects, source: source, ecosystem: ecosystem.name)
        rescue Errors::CollectionPaused => e
          # A pause is a decision rather than a fault, and this is a seed for an index the service
          # is not taking evidence about. Info, with the reason, rather than the warning below —
          # which is for a service or a third party that could not be reached, and describes this
          # container instead of the corpus's state.
          logger.info("not contributing the %s breadth seed: %s", ecosystem.name, e.message)
          next
        rescue Errors::CorpusError => e
          logger.warning("could not contribute the %s breadth seed: %s", ecosystem.name, e.message)
          next
        end
        logger.info("contributed %d %s breadth seed project(s) to the service",
          projects.length, ecosystem.name)
        contributed += projects.length
      end
      contributed
    end

    # The packages to work on when none were named, and where they came from.
    #
    # One function because there are three callers — a `publish` run, the service, and
    # `resolve_pairs` — and the watchlist has to be the same list for all of them: a corpus filled
    # by one set of packages and topped up by another is a corpus whose coverage nobody can
    # describe.
    #
    # The count per source comes back rather than a bare list because the log line that says which
    # list the miner is working cannot be written from the names: a hundred packages from the queue
    # and a hundred from the ranking produce the same number and describe two different miners.
    #
    # `session` is how the service's own mining queue is reached. Without one the ranking is used,
    # which is what a one-off run with no session to hand gets — the same order, minus the corpus's
    # own demand signals.
    #
    # `ecosystem` chooses which index's queue and which index's ranking. Both halves have to move
    # together: reading PyPI's queue and mining it with the Ruby client would be a watchlist of
    # package names and an installer looking for gems.
    def self.chosen_packages(args, session: nil, ecosystem: nil)
      index = ecosystem || Ecosystems::PYTHON
      remote = if session.nil?
        nil
      else
        lambda do
          session.mining_targets(limit: args.top, pages: args.queue_pages,
            ecosystem: index.name)
        end
               end
      extra = {}
      extra[:ranking_of] = Watchlist.method(:ruby_downloads) if index.name == "ruby"
      Watchlist.watchlist(
        cache: args.home + "index",
        top: args.top,
        fallback: WATCHLIST,
        remote: remote,
        # A pause is the one failure of this read that must not fall back to the ranking: the
        # ranking is a list of names for an index the service has stopped accepting evidence
        # about, so using it costs a cycle of environments built for pairs whose filings are all
        # refused. Raised out of here and handled by `workable`, which is the thing that can decide
        # an index is not this run's to work.
        re_raise: [Errors::CollectionPaused],
        **extra
      )
    end

    # Which upgrades to mine, from the flags given.
    #
    # An explicit package with explicit versions is honoured exactly, so a suspected break can be
    # checked without waiting for a version heuristic to agree. Anything less specific goes through
    # the index.
    def self.resolve_pairs(args, session: nil)
      packages = if args.package.empty?
        chosen_packages(args, session: session).packages
      else
        args.package
                 end
      cache = args.home + "index"
      pairs = []
      packages.each do |package|
        if args.from_version && args.to_version && !args.package.empty?
          pairs << Pair.of(package: package, from_version: args.from_version,
            to_version: args.to_version)
          next
        end
        begin
          history = Versions.release_history(package, cache: cache)
        rescue Versions::NoHistory => e
          $stderr.puts("[skip] #{e.message}")
          next
        end
        found = Versions.pairs_for(package, history, span: args.span)
        if found.empty?
          $stderr.puts("[skip] #{package}: no usable numeric release pair in history")
        end
        pairs.concat(found)
      end
      pairs
    end

    # Every finding one upgrade produces, or none if it cannot be examined.
    #
    # A watchlist is a breadth-first sweep, so anything that makes *one* package unexaminable is
    # reported and skipped rather than raised: a package with no wheel for this interpreter, and a
    # package whose import needs something its own metadata does not install — `httpx-sse` will
    # not import without `httpx`, which it does not declare. Both end the run otherwise, and the
    # run is the only place the other fourteen packages' findings were going to come from.
    #
    # `MinerError` is the boundary rather than `StandardError`: this module's own failures are
    # "could not do this for this package", and anything else is a bug in the miner that should be
    # seen rather than swallowed fifteen times.
    def self.mine_pair(pair, args)
      before = Envs.build(pair.package, pair.from_version, home: args.home + "envs")
      after = Envs.build(pair.package, pair.to_version, home: args.home + "envs")
      Mine.findings_between(pair.package, pair.from_version, pair.to_version, before, after)
    rescue Errors::MinerError => e
      $stderr.puts("[skip] #{pair}: #{e.message}")
      []
    end

    # `mine`, `publish` and `solve`: one pass, and a summary of what it did.
    #
    # `mine` is the local mode and does not create an operator. That distinction was nearly
    # lost: both one-shot modes ran the same function, so `mine` registered an account and
    # submitted every finding it printed. A command whose documented job is to show you what
    # a pair breaks must not write it to a shared corpus.
    def self.run_once(args, solve_only: false)
      publishing = args.command == "publish"
      session = nil
      if publishing || solve_only
        state = args.state || (args.home + "operator.json")
        key = Corpus.load_or_register(args.base_url, state, name: MINER_NAME, email: MINER_EMAIL)
        session = Corpus.new(base_url: args.base_url, api_key: key)
      end

      return CliReports.profile(session, args) if solve_only

      pairs = resolve_pairs(args, session: session)
      if pairs.empty?
        $stderr.puts("nothing to mine")
        return 1
      end

      filed = 0
      found = 0
      pairs.each do |pair|
        findings = mine_pair(pair, args)
        findings = findings.first(args.limit) if args.limit.positive?
        findings.each do |finding|
          found += 1
          $stderr.puts(Reporting.summary_for(finding))
          if args.json
            puts JSON.pretty_generate(Reporting.payload_for(finding, from_version: pair.from_version))
          end
          next unless publishing

          outcome = session.submit_mined(finding, from_version: pair.from_version, pace: 1.0,
            dry_run: args.dry_run)
          $stderr.puts("[#{outcome}] #{finding.title}")
          if outcome == "filed" || (args.dry_run && Errors.filable?(outcome))
            filed += 1
          end
        end
      end
      if publishing
        verb = args.dry_run ? "would file" : "filed"
        $stderr.puts("#{verb} #{filed} finding(s)")
      else
        $stderr.puts("found #{found} finding(s); nothing was filed")
      end
      0
    end

    # The indexes this run can work, their watchlists, and the paused ones.
    #
    # Resolved once, at startup, rather than per cycle: the queue is a decision, and a service that
    # re-read it every cycle would spend a request to learn the same order — as well as its own
    # fetch of the breadth ranking, which is a monthly publication. Resolved *after* the session
    # exists, because the queue is the first source considered and it comes from the service.
    #
    # A paused index is dropped rather than worked from the fallback ranking, and that is the whole
    # reason this is a function instead of a loop in `serve`: the watchlist's own rule is that a
    # failed queue read costs the miner its preference and not its work, which is right for an
    # outage and wrong here. Mining a paused index would build an environment for every pair it
    # planned and have every filing refused at the end of it, and the local ranking is already on
    # disk, so it is exactly what the fallback would do.
    #
    # Returning three things is deliberate: the caller has to be able to say *which* indexes were
    # dropped and why. "This miner is working one index" and "this miner is working one index
    # because the other is paused" are different states of the deployment, and only one of them
    # needs a person.
    #
    # Returns `[workable, watchlists, paused]`, where `watchlists` is a name => names map and
    # `paused` is a list of `[name, reason]` pairs.
    def self.workable(session, args, indexes)
      log = Log.logger("agents_miner.service")
      workable = []
      watchlists = {}
      paused = []
      indexes.each do |ecosystem|
        if !Array(args.package).empty?
          # An explicit package is an instruction about one pair, and it is honoured whatever any
          # index is doing: the filing is what gets refused, loudly, rather than the run being
          # quietly narrowed to the indexes that happen to be open.
          workable << ecosystem
          watchlists[ecosystem.name] = Array(args.package).dup
          next
        end
        begin
          chosen = chosen_packages(args, session: session, ecosystem: ecosystem)
        rescue Errors::CollectionPaused => e
          paused << [ecosystem.name, e.message]
          next
        end
        workable << ecosystem
        watchlists[ecosystem.name] = chosen.packages
        # The line names which source contributed what, and it has to: the version of it that said
        # "from the service's queue and the breadth ranking" was printed while the queue was
        # answering 422 and every package had come from the ranking. Which list the miner is
        # working is the first thing an operator needs to know and the one thing a bare count
        # cannot say.
        log.info("watchlist [%s]: %s", ecosystem.name, chosen.describe)
      end
      [workable, watchlists, paused]
    end

    # The long-running mode: the same work, one cycle at a time, forever.
    def self.serve(args)
      Log.level = args.log_level
      log = Log.logger("agents_miner.service")
      state = args.state || (args.home + "operator.json")
      key = Corpus.load_or_register(args.base_url, state, name: MINER_NAME, email: MINER_EMAIL)
      session = Corpus.new(base_url: args.base_url, api_key: key)
      indexes = Ecosystems.named(args.ecosystems)
      # The breadth seed, contributed once per start, one per index. This container is the one with
      # a route to the third parties — the service container has none — so the rankings are fetched
      # here and *owned* there: the service decides how much each counts for and records when it
      # was read, which is what makes their age visible instead of load-bearing. Failure is not
      # fatal: a miner with no seed still has the corpus's own queue, and that is the part that
      # matters.
      contribute_seed(session, args, indexes: indexes)
      indexes, watchlists, paused = workable(session, args, indexes)
      paused.each do |name, reason|
        log.info("index %s is paused, so this run will not work it: %s", name, reason)
      end
      if indexes.empty?
        # Every index asked for is closed, so there is nothing a cycle could do: the interval, the
        # ledger and the environments all describe work that cannot be filed. Exiting says so once
        # in the container's own status, and the restart the compose policy performs re-reads the
        # flag — which is how this becomes work again the moment an operator resumes an index. The
        # alternative, cycling with an empty watchlist, prints the same "0 pair(s)" as a miner that
        # has worked the whole corpus, and this project already spent two days reading that line as
        # healthy.
        named = paused.map(&:first).join(", ")
        log.warning(
          "every index this miner was asked for is paused (%s), so there is nothing to mine; " \
          "`POST /api/admin/collection/<index>/resume` is what lifts it",
          named.empty? ? "none requested" : named
        )
        return 3
      end
      store = Pathname.new(state).parent + "ledger.json"
      worker = Service.new(
        session: session,
        home: args.home,
        state: store,
        watchlist: watchlists[indexes[0].name],
        ledger: Ledger.load(store),
        budget: args.budget,
        report_budget: args.report_budget,
        dry_run: args.dry_run,
        heartbeat: args.heartbeat || args.home + "heartbeat",
        writes_per_hour: args.writes_per_hour,
        workers: args.workers,
        ecosystems: indexes,
        watchlists: watchlists
      )
      known = Service.known_work(worker.ledger)
      log.info("starting: %s against %s (%s), %d pair(s) examined so far",
        MINER_NAME, args.base_url, indexes.map(&:name).join(", "), known)
      total = worker.run(cycles: args.cycles, pace: !args.no_sleep)
      log.info("stopped: %s", total.summary)
      0
    end

    # The verifier: confirm other operators' reports by executing them.
    #
    # Its own account, its own ledger and its own environments, because that is what makes the
    # confirmation worth counting — the service's rule is "an operator other than the author", and
    # a verifier that shared the miner's identity would be the author checking its own work under
    # a second name.
    def self.verify(args)
      Log.level = args.log_level
      default_name, default_email = VERIFIER_IDENTITIES.fetch(args.role)
      state = args.state || (args.home + "operator-#{args.role}.json")
      key = Corpus.load_or_register(args.base_url, state,
        name: args.name || default_name,
        email: args.email || default_email)
      session = Corpus.new(base_url: args.base_url, api_key: key)
      store = args.home + "ledger-#{args.role}.json"
      worker = Verifier.new(
        session: session,
        home: args.home,
        state: store,
        role: args.role,
        ledger: Ledger.load(store),
        budget: args.budget,
        dry_run: args.dry_run,
        heartbeat: args.heartbeat || args.home + "heartbeat-#{args.role}",
        writes_per_hour: args.writes_per_hour,
        workers: args.workers,
        # The deployment's own scope, not this file's default: an index that has been turned off
        # should not have a verifier installing two releases per report to discover that every
        # vote is refused. `Ecosystems.named` is the one reader of the name, and it refuses a
        # misspelling rather than quietly working nothing.
        ecosystems: Ecosystems.named(args.ecosystems)
      )
      logger = Log.logger("agents_miner.verifier")
      logger.info("starting: %s against %s as %s, %d report(s) already checked",
        args.name || default_name, args.base_url, args.role, worker.ledger.reports.length)
      total = worker.run(cycles: args.cycles, pace: !args.no_sleep)
      logger.info("stopped: %s", total.summary)
      0
    end

    # What a *third party* failing looks like, and the list is named rather than broad for the
    # reason the rest of this client names its rescues: a broad handler here would also swallow the
    # corpus's own refusals, and the seed is the one call in this file that has its own separate
    # handling for exactly two of them (`CollectionPaused` and `CorpusError`). `SnapshotMissing` is
    # included because a client whose data file did not ship should start without a seed rather than
    # fail to start at all.
    SEED_FETCH_FAILURES = [
      SystemCallError, ArgumentError, TypeError, KeyError, JSON::ParserError,
      Watchlist::IndexError, Watchlist::SnapshotMissing,
      Versions::IndexError, RubyVersions::IndexError, SocketError, IOError,
      Timeout::Error
    ].freeze
  end
end
