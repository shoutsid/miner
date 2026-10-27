# frozen_string_literal: true

require "pathname"

require_relative "envs"
require_relative "machine"
require_relative "mine"
require_relative "pair"
require_relative "rubyenvs"
require_relative "rubymine"
require_relative "rubyversions"
require_relative "versions"
require_relative "wheelcache"

module AgentsMiner
  # What differs between mining PyPI and mining RubyGems, in one object.
  #
  # The loop is the same for both: choose upgrades, build two releases of one package, execute the
  # same reference against each, file what the older one did and the newer one does not. The loop
  # was written when there was only one index, so the parts that are Python-shaped are spread
  # through it — which index a history comes from, what a "release" is installed into, what a
  # differential is, which caches have a budget. This module gathers them.
  #
  # The service asks the *ecosystem* rather than the modules. That is the whole point: a
  # second copy of the loop for Ruby would be a copy that drifts, and the drift would show up
  # as two miners disagreeing about what a pair is, what "settled" means, or which corpus a
  # finding belongs to. `test_ecosystems.py`'s own docstring said the same thing about the
  # failure being guarded: a Python probe run against a gem produces an *empty* differential,
  # which reads as a release that changed nothing.
  #
  # Nothing here decides anything. Every method is either a delegation to the module that owns the
  # rule or a place where the two indexes genuinely differ, and where they differ the difference
  # is stated:
  #
  # * **A deadline.** PyPI's index publishes each file's size, so the Python side can price an
  #   install from the bytes it has to move. RubyGems publishes no size at all — measured, the key
  #   is absent from the versions endpoint — so the Ruby side has nothing to price from and gets a
  #   flat ceiling that doubles on retry.
  # * **A cache.** The Python side has three things with a budget (environments, the wheel cache,
  #   pip's scratch); the Ruby side has two (gem environments and gem's unpack scratch), because a
  #   `.gem` is cached inside the environment that installed it rather than in a shared
  #   content-addressed store.
  # * **A probe suffix.** Both pass the examination's identity to every probe so one worker's
  #   scratch script is never the file another worker runs. The reason is written out in
  #   `Envs.probe`.
  #
  # The surface every ecosystem answers, which Python stated as a `Protocol` and Ruby states here
  # because there is no interface to implement — a class is an ecosystem when it answers these:
  #
  #   name, machine, install_timeout
  #   history(package, home:, refresh:), history_is_cached(package, home:)
  #   crossings(package, history, limit:), pairs_for(package, history, span:)
  #   advisory_pair(package, history, fixed_in:)
  #   release_date(package, version, home:)
  #   deadline(package, version, home:, rate:, workers:, attempts:)
  #   build(package, version, home:, deadline:, attempt:)
  #   findings(library, from_version, to_version, before, after, suffix:)
  #   prune(home, budget:), sweep(home)
  #
  # `deadline` and `build` both take the whole set of keywords even where one index ignores one,
  # because the caller passes the same four to either and a signature that varied would put the
  # difference in the loop rather than here.
  module Ecosystems
    # Nothing depends on it.
    MEGABYTE = 1024 * 1024

    # PyPI, as this miner has always mined it.
    #
    class Python
      def name = "python"

      def install_timeout = Envs::INSTALL_TIMEOUT

      # This machine as PyPI's builder, asked rather than remembered.
      #
      # A method rather than a value computed when this file loaded, because it is a *read of the
      # machine* — the compiler it has, the interpreter it runs — and a value frozen at load is a
      # value a test cannot set and an operator cannot change without a restart. Cheap: two `PATH`
      # lookups and one subprocess for the interpreter's version, which is why `Machine` reads it
      # once per process.
      def machine = Machine.python

      def history(package, home:, refresh:)
        Versions.release_history(package, cache: Pathname.new(home) + "index", offline: !refresh)
      end

      def history_is_cached(package, home:)
        Versions.history_is_cached(package, cache: Pathname.new(home) + "index")
      end

      def crossings(package, history, limit:)
        Versions.crossings(package, history, limit: limit)
      end

      def pairs_for(package, history, span:)
        Versions.pairs_for(package, history, span: span)
      end

      # No advisory pairs here, and stated rather than omitted because the loop asks every ecosystem
      # the same question: this build ingests the GitHub reviewed advisories for RubyGems only, so
      # there is no PyPI lead for the planner to act on.
      def advisory_pair(_package, _history, fixed_in:) = nil

      def release_date(package, version, home:)
        Versions.release_date(package, version, cache: Pathname.new(home) + "index")
      end

      # The deadline, priced from the payload.
      #
      # `release_size` reads the sizes sidecar PyPI publishes, and a release whose size is unknown
      # (`nil`) leaves `install_deadline` its own floor — see the measurement in `Envs`'s comment
      # about a deadline spent in bytes.
      def deadline(package, version, home:, rate:, workers:, attempts:)
        payload = Versions.release_size(package, version, cache: Pathname.new(home) + "index")
        Envs.install_deadline(payload, rate: rate, workers: workers, attempts: attempts)
      end

      # The loop passes the home it was configured with to both, and each adapter is the one
      # place that knows.
      def build(package, version, home:, deadline:, attempt: 0)
        Envs.build(package, version, home: home + "envs", deadline: deadline)
      end

      def findings(library, from_version, to_version, before, after, suffix:)
        Mine.findings_between(library, from_version, to_version, before, after, suffix: suffix)
      end

      # Every cache this index keeps, each with its own bound and its own label.
      #
      # The *budget* is the environment one; the wheel cache answers to its own
      # (`WheelCache::WHEEL_BUDGET_BYTES`), which is larger on purpose — an environment is a working
      # set that is disposable once its finding is filed, while a wheel cache's entries stay useful
      # for as long as the corpus might install that release again.
      def prune(home, budget:)
        removed, freed = Envs.prune(home + "envs", budget: budget)
        cached, cache_free = WheelCache.prune(WheelCache.cache_dir(home))
        [
          ["environment(s)", removed, freed],
          ["wheel cache entr(ies)", cached, cache_free]
        ]
      end

      def sweep(home)
        removed, freed = Envs.sweep_scratch(Envs.scratch_dir(home))
        [["abandoned scratch dir(s)", removed, freed]]
      end
    end

    # RubyGems, mined the same way against a different everything.
    #
    # The differences that are not delegation are the two above: no published size to price a
    # deadline from, and no separate wheel cache.
    class Ruby
      def name = "ruby"

      def install_timeout = RubyEnvs::INSTALL_TIMEOUT

      # This machine as a gem's builder: `ruby 3.3.12 cc`.
      #
      # The interpreter comes from `RubyEnvs.runtime`, which asks the interpreter once per process
      # and falls back to the bare word when it cannot, so this is not a second opinion about which
      # Ruby is installed.
      def machine = RubyEnvs.machine

      def history(package, home:, refresh:)
        RubyVersions.release_history(package, cache: Pathname.new(home) + "index", offline: !refresh)
      end

      # Whether a complete reading is on disk, by the fetch's own rule.
      #
      # One request returns the version list and the dates together, so there is nothing to keep in
      # step here the way the PyPI side's three sidecars had to be — the predicate is the module's
      # own.
      def history_is_cached(package, home:)
        RubyVersions.history_is_cached(package, cache: Pathname.new(home) + "index")
      end

      # RubyGems' ladder, stamped with the index it was built from.
      #
      # The ladders themselves do not know about ecosystems — `rubyversions.rb` is about RubyGems
      # and `versions.rb` is about PyPI — so the stamp is applied here, once, at the point where a
      # pair enters the service.
      def crossings(package, history, limit:)
        RubyVersions.crossings(package, history, limit: limit).map { |pair| pair.with_ecosystem(name) }
      end

      def pairs_for(package, history, span:)
        RubyVersions.pairs_for(package, history, span: span).map { |pair| pair.with_ecosystem(name) }
      end

      # The crossing a reviewed advisory's fix landed in, stamped with the index it came from.
      #
      # `fixed_in` is GitHub's own statement of where the fix arrived, and it is not re-derived
      # here — this resolves which releases the crossing is *between*, which is a question about the
      # index's history rather than about the advisory.
      def advisory_pair(package, history, fixed_in:)
        RubyVersions.advisory_pair(package, history, fixed_in: fixed_in)&.with_ecosystem(name)
      end

      def release_date(package, version, home:)
        RubyVersions.release_date(package, version, cache: Pathname.new(home) + "index")
      end

      # A flat ceiling, doubled per attempt, because there is nothing to price.
      #
      # RubyGems does not publish a size — not in the versions endpoint and not in the compact
      # index, both measured — so the payload the deadline would be priced from does not exist. The
      # retry factor stays because the evidence it encodes is unchanged: an install that ran out of
      # time had the environment already on its way, so the next attempt gets more room.
      #
      # `home`, `rate` and `workers` are accepted and ignored, and they are named rather than
      # underscored because a caller's keyword has to match the parameter: the loop passes the same
      # four to whichever index it is working, and a signature that varied would put this index's
      # difference into the loop. A floor that fits one index fits the other by accident at best.
      def deadline(_package, _version, home:, rate:, workers:, attempts:)
        RubyEnvs.install_deadline(attempts)
      end

      def build(package, version, home:, deadline:, attempt: 0)
        RubyEnvs.build(package, version, home: home, timeout: deadline, attempt: attempt)
      end

      def findings(library, from_version, to_version, before, after, suffix:)
        RubyMine.findings_between(library, from_version, to_version, before, after, suffix: suffix)
      end

      # The two caches this side keeps: the environments and gem's scratch.
      #
      # The *budget* is the environment one: a `.gem` lives inside the environment that installed
      # it, so there is no shared download cache to bound — which is also why there is nothing here
      # that pruning could break for another environment the way a shared wheel cache can.
      def prune(home, budget:)
        removed, freed = RubyEnvs.prune(home, budget: budget)
        [["gem environment(s)", removed, freed]]
      end

      def sweep(home)
        removed, freed = RubyEnvs.sweep_scratch(home)
        [["abandoned gem scratch dir(s)", removed, freed]]
      end
    end

    PYTHON = Python.new
    RUBY = Ruby.new
    ALL = [PYTHON, RUBY].freeze
    BY_NAME = ALL.to_h { |ecosystem| [ecosystem.name, ecosystem] }.freeze

    # The ecosystems a run was asked for, by name.
    #
    # An unknown name is named in the error rather than skipped: a deployment that asked to
    # mine `pypi` instead of `python` should be told, not quietly given a miner that works one
    # index and reports healthy.
    #
    # A `String` is split on commas *and* spaces, because the variable it comes from is written by
    # hand in a deployment (`MINER_ECOSYSTEMS=ruby`) and both spellings are what an operator means.
    # An empty result is PyPI, which is the default a miner that was never asked for anything gets.
    def self.named(names)
      return [PYTHON].freeze if names.nil?

      list = names.is_a?(String) ? names.tr(",", " ").split : Array(names)
      chosen = []
      list.each do |name|
        ecosystem = BY_NAME[name.to_s.strip.downcase]
        if ecosystem.nil?
          raise ArgumentError,
            "unknown ecosystem '#{name}': expected one of #{BY_NAME.keys.join(', ')}"
        end

        chosen << ecosystem unless chosen.include?(ecosystem)
      end
      (chosen.empty? ? [PYTHON] : chosen).freeze
    end

    # The ecosystem a name refers to, or nil — for a caller that has to ask rather than be handed
    # one. `named` is the surface: it is the one that refuses an unknown name, and this is the same
    # table read without the refusal.
    def self.by_name(name) = BY_NAME[name.to_s.strip.downcase]
  end
end
