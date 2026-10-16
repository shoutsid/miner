# frozen_string_literal: true

# Which packages to mine, taken from what the service knows and what people install.
#
# The watchlist began as a hand-written list of packages the author happened to think were
# important, and that is the wrong kind of list in two ways. It is a guess about usage made by
# somebody who does not have the data, and it goes stale silently — a package that dominates
# installs in a year's time is not on it, and nothing says so.
#
# It then became a third-party ranking of the most-installed packages on PyPI. That is real data
# and it fixed the staleness, but it made this deployment's idea of what to work on depend on
# somebody else's file with no way to see its age, and it could not express the things only this
# corpus knows: which library somebody filed an unanswered report about, which one callers keep
# searching for and getting nothing, which ones have already proven to break their callers.
#
# So the order now comes from the service — `/mining/targets`, computed in
# `lib/agents_fyi_service/mining_queue.rb` — and this module is the *breadth* half: the
# ranking of what is installed elsewhere, used when the service has no queue yet, and the curated
# names used when there is no network at all. The order matters, because the miner's planner
# works a package's releases newest-first and its packages in tier order, so a corpus fed by this
# list fills with the packages an upgrade is most likely to break.
#
# Deliberately not "every package on the index". The differential costs a virtual environment per
# release, most packages are not installed by anybody, and a corpus of findings about packages
# nobody uses is the same as an empty corpus with more rows. The list is the top N by installs,
# and N is a choice the operator makes.
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "pathname"
require "set"
require "socket"
require "timeout"
require "uri"

module AgentsFyiMiner
  module Watchlist
    # The published ranking. Redirected from the `hugovk.github.io` URL it has been cited under
    # for years, which is why the fetch follows redirects — the one place in this client that has
    # to, and `fetch` says so where a reader will look.
    RANKING = "https://hugovk.github.io/top-pypi-packages/top-pypi-packages.min.json"

    # What this ranking is called when it is handed to the service as a breadth seed. One string,
    # and it is the same one the service records — the console displays it, so a deployment whose
    # seed came from somewhere else would say so rather than showing this name over somebody
    # else's list.
    SEED_SOURCE = "top-pypi-packages"

    # RubyGems' ranking, and the same three facts about it: where it is read from, what it is
    # called, and how deep it goes.
    #
    # It is the site's statistics page rather than an API — the endpoint that used to serve a
    # "most downloaded" list answers 410 — and it publishes a hundred gems, ten to a page. That
    # depth is a fact about the index and is stated rather than padded; the service's own
    # observations outrank the seed anyway.
    #
    # The name and the page are the same ones the service reads, and the parser here is a second
    # copy of that rule because the miner is a client and cannot import the service.
    # `watchlist_test.rb` drives this parser against the same real markup the service's own reader
    # is driven against, which is what keeps the copy honest.
    RUBY_RANKING = "https://rubygems.org/stats"
    RUBY_SEED_SOURCE = "rubygems-statistics"
    RUBY_PAGES = 10
    RUBY_TOP = 100

    # The breadth the miner actually seeds from: indexed gems ranked by total downloads, taken
    # from RubyGems' official weekly data dump by `scripts/rubygems-downloads.sh`. The stats page
    # above is the only *live* source, and it stops at 100 — which is how Ruby had a hundred gems
    # of breadth against PyPI's three thousand. The snapshot is built on the host because the dump
    # is ~670 MB and needs a Postgres to read, and the miner is a client with no database driver.
    # It is read here, not fetched, so a miner start never depends on a download.
    #
    # It travels with the client as data — `lib/agents_fyi_miner/data/rubygems-downloads.txt` —
    # and `ruby_downloads` says what a missing copy means.
    RUBY_DOWNLOADS_TOP = 3000
    RUBY_SNAPSHOT = Pathname.new(__dir__) + "data/rubygems-downloads.txt"
    RUBY_HEADING = "Most Downloaded"
    # The ranking *entry*, not every link to a gem: the navigation and the footer link to gems
    # from plain `<a>` tags, and the heading plus this shape is what makes the reader the ranking
    # rather than the chrome around it.
    RUBY_ENTRY = %r{<h3[^>]*>\s*<a[^>]*href="/gems/([A-Za-z0-9_.-]+)"}

    # How many of the ranking to take by default. It used to be 1,000, on the reasoning that this
    # is "a few dozen hours of mining at the rate this service works" — and measured against the
    # ledger that is roughly right, which is the problem: 1,000 packages was about 9,000 crossings
    # and two days of work, after which the miner had worked the whole list, could find nothing,
    # and cycled every ten minutes reporting 0 pair(s) while the container looked healthy. The
    # bound has to outlast the work, and the work is months, not days.
    #
    # 3,000 is also where the *seed* stops fitting: the same list is posted to the service as the
    # breadth seed, and a request body is capped at 64 KiB. Measured over the real ranking (names
    # average 12.9 characters): 3,000 names serialize to 46.7 KiB, 4,000 to 62.5 and 5,000 to
    # 77.5. Raising this past ~4,000 without also raising the body cap gives a seed the API
    # refuses and a miner that is told it has no breadth. `MINER_TOP` is how an operator changes
    # it.
    DEFAULT_TOP = 3000

    # How long a fetched ranking is trusted. The source is rebuilt monthly, so a day is generous —
    # but it is not unbounded, because a cached ranking that never expires is a watchlist that
    # never learns about a package that has just become popular, and that is exactly the staleness
    # this module exists to remove.
    DEFAULT_MAX_AGE = 24 * 3600

    # What a request gets, in seconds. `urllib`'s own `timeout=60` in the client this was ported
    # from, and it is the whole request rather than the read alone: a static site that accepts the
    # connection and then says nothing is the failure this bounds.
    TIMEOUT = 60

    # How many redirects `fetch` will follow before giving up. `urllib` followed them silently and
    # without a bound; a bound is what keeps a ranking that redirects to itself from hanging a
    # cycle, and three is past any real move of a published file.
    REDIRECTS = 3

    # The ranking answered, and not with a document: any non-2xx. Carries the code because the
    # caller's answer to a 404 and to a 503 is the same here (use the cached copy, or fail), but
    # the message is what an operator reads.
    class IndexError < StandardError
      attr_reader :code

      def initialize(message, code:)
        super(message)
        @code = code
      end
    end

    # The gem breadth snapshot is not where the client keeps it.
    #
    # Its own class rather than `Errno::ENOENT`, and that is the whole point of it: a missing data
    # file is *not* one of the ways the network fails, so it must not be caught by `UNREADABLE`
    # and turned into the curated fallback list. A miner quietly working the twelve names in
    # `WATCHLIST` while reporting a healthy watchlist is exactly the failure `AGENTS.md` records
    # for an empty field read as a fresh one.
    class SnapshotMissing < StandardError; end

    # Every way the network fails, as one list instead of one class.
    #
    # Ruby spreads the same situation over `SocketError`, the `Errno::*` family, `IOError` and
    # the two `Net` timeouts — so the list is written once here and rescued as a splat, and a
    # failure it does not cover is a failure the caller should see. `Versions` and
    # `RubyVersions` hold the identical list; `openssl` is required at the top of this file
    # because a constant reference to a class the interpreter has not loaded is a `NameError`
    # while the file is read.
    NETWORK_ERRORS = [SocketError, SystemCallError, IOError, Timeout::Error,
                      Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError].freeze

    # Everything that means "there is no ranking to be had": the network, the status code, and
    # the document. `KeyError` is here because a payload whose rows are not the shape this
    # expects is a payload this module cannot read, and `IndexError` because a 404 from a
    # moved ranking is not a reason to stop mining.
    UNREADABLE = (NETWORK_ERRORS + [IndexError, KeyError, JSON::ParserError]).freeze

    # The watchlist, and which source contributed each part of it.
    #
    # Kept rather than only the names because the log line is how an operator knows which of the
    # three lists the miner is actually working, and the version of this that returned a bare list
    # wrote a sentence naming *both* sources whether or not either had contributed anything —
    # "1000 package(s) from the service's queue and the breadth ranking" was printed while the
    # queue was returning 422 and every one of the thousand had come from the ranking. A count per
    # source cannot say that.
    #
    #
    # At module level rather than beside the reader that builds it, and that is not tidiness: a
    # constant written inside a `class << self` body belongs to the *singleton class*, so
    # `Watchlist::Chosen` would be unnameable from anywhere outside this file — which is exactly
    # how a caller porting `isinstance(chosen, watchlist.Chosen)` writes a NameError.
    Chosen = Data.define(:packages, :from_queue, :from_ranking, :from_fallback, :queue_error) do
      include Enumerable

      def self.of(packages:, from_queue: 0, from_ranking: 0, from_fallback: 0, queue_error: nil)
        new(packages: packages, from_queue: from_queue, from_ranking: from_ranking,
          from_fallback: from_fallback, queue_error: queue_error)
      end

      # One line for the log: how many packages, and where they came from.
      def describe
        parts = []
        parts << "#{from_queue} from the service's queue" if from_queue.positive?
        parts << "#{from_ranking} from the breadth ranking" if from_ranking.positive?
        parts << "#{from_fallback} from the curated names" if from_fallback.positive?
        parts << "the queue could not be read: #{queue_error}" if queue_error
        detail = parts.empty? ? "no source had anything" : parts.join("; ")
        "#{packages.length} package(s) (#{detail})"
      end

      # Iterable over the names, so a caller that only wants those can say so.
      def each(&block) = packages.each(&block)
      def length = packages.length
      alias size length
    end

    class << self
      # Whether a project name is one this miner can act on.
      #
      # The ranking is a list of *project* names, and a project is not always a library: it holds
      # tooling (`twine`), typing stubs (`types-requests`), build backends (`setuptools`), and
      # vendored forks. Those are not excluded here on taste — they are excluded because the
      # differential needs a package that exports something a caller imports, and a project that
      # is run as a command or depended on for its build hooks usually does neither.
      #
      # The test is deliberately cheap and conservative: a name has to look like an importable
      # identifier. Anything it lets through that turns out not to be importable is skipped by
      # the miner itself, with a reason, which is the honest place for that judgement.
      #
      def usable?(project)
        name = project.to_s
        return false if name.empty? || name.start_with?("_", ".")

        candidate = name.tr("-.", "__")
        candidate.match?(/\A[[:alpha:]_][[:alnum:]_]*\z/) && !candidate.match?(/\A\d+\z/)
      end

      # The most-installed projects, most-installed first.
      #
      # Cached and expiry-checked for the same reason the release index is: this is a third party,
      # a service must not depend on it being up at the moment a cycle starts, and a cached copy
      # that never expires would freeze the watchlist at whatever was popular the day the
      # container first ran. When the fetch fails the stale copy is used rather than raising — a
      # miner that stopped because a static site was briefly down would be trading a certain loss
      # for an uncertain one.
      def ranking(cache:, top: DEFAULT_TOP, max_age: DEFAULT_MAX_AGE)
        path = cache + "watchlist.json"
        cached = read_cache(path)
        return cached.first(top) if !cached.nil? && max_age.to_f.positive? && fresh?(path, max_age)

        begin
          payload = JSON.parse(fetch(RANKING))
        rescue *UNREADABLE
          return cached.first(top) unless cached.nil?

          raise
        end
        projects = Array(payload["rows"]).filter_map do |row|
          name = row.is_a?(Hash) ? row["project"] : nil
          name.to_s.empty? ? nil : name
        end
        FileUtils.mkdir_p(cache)
        path.write(JSON.generate(projects), encoding: "utf-8")
        projects.first(top)
      end

      # The gem names a RubyGems statistics page lists, in the order it lists them.
      #
      # Scoped twice — to what follows the ranking's own heading, and to the entry markup that
      # heading introduces — because the page's navigation and footer link to gems too, and a seed
      # that began with whatever the chrome mentions would be a ranking in name only. Order is
      # kept, because order is the only thing a breadth ranking contributes.
      def parse_gem_ranking(page)
        start = page.to_s.index(RUBY_HEADING)
        return [] if start.nil?

        found = []
        page[start..].scan(RUBY_ENTRY).map(&:first).each do |name|
          found << name unless found.include?(name)
        end
        found
      end

      # The most-downloaded indexed gems, from the snapshot the dump produced.
      #
      # Read from the package, not the network, and the header lines the generator writes are
      # skipped. `cache` is accepted because `watchlist` calls every ranking the same way, and this
      # one has nothing to cache. Order is the dump's download order, which is the only thing a
      # breadth ranking contributes.
      #
      # A missing snapshot is named rather than silently empty: an empty ranking here is a miner
      # with no breadth at all, which is indistinguishable from an index that publishes nothing,
      # and the file is data that ships with the client (built by `scripts/rubygems-downloads.sh`,
      # kept at `lib/agents_fyi_miner/data/rubygems-downloads.txt`).
      def ruby_downloads(cache: nil, top: RUBY_DOWNLOADS_TOP, snapshot: RUBY_SNAPSHOT)
        snapshot = Pathname.new(snapshot)
        unless snapshot.file?
          raise SnapshotMissing, "#{snapshot} is missing: the gem breadth snapshot is data that " \
                                 "ships with this client (see scripts/rubygems-downloads.sh)"
        end

        names = snapshot.read(encoding: "utf-8").split("\n").filter_map do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("#")

          stripped
        end
        names.first(top)
      end

      # The most-downloaded gems, most-downloaded first, from the statistics page.
      #
      # Cached and expiry-checked exactly as the PyPI side is, and for the same reasons: this is a
      # third party, a service must not depend on it being up at the moment a cycle starts, and a
      # cached copy that never expired would freeze a whole index's breadth at whatever was
      # popular the day the container first ran. A stale copy beats raising, because a miner that
      # stopped because a web page was briefly down would be trading a certain loss for an
      # uncertain one.
      #
      # Every page is a separate request — the ranking is paginated ten gems at a time — and the
      # walk stops when a page lists nothing, which is also what bounds it: a count written here
      # would silently truncate the ranking the day the site publishes more.
      def ruby_ranking(cache:, top: RUBY_TOP, max_age: DEFAULT_MAX_AGE)
        path = cache + "watchlist-ruby.json"
        cached = read_cache(path)
        return cached.first(top) if !cached.nil? && max_age.to_f.positive? && fresh?(path, max_age)

        begin
          ranked = []
          (1..RUBY_PAGES).each do |page_number|
            url = page_number == 1 ? RUBY_RANKING : "#{RUBY_RANKING}?page=#{page_number}"
            names = parse_gem_ranking(fetch(url))
            break if names.empty?

            names.each { |name| ranked << name unless ranked.include?(name) }
          end
        rescue *UNREADABLE
          return cached.first(top) unless cached.nil?

          raise
        end
        FileUtils.mkdir_p(cache)
        path.write(JSON.generate(ranked.first(top)), encoding: "utf-8")
        ranked.first(top)
      end

      # What to mine: the service's own queue first, then the breadth ranking.
      #
      # `remote` is the service's `/mining/targets` — the queue it computes from what it has
      # observed. It comes *first*, because it is the better-informed list: a package with an
      # unanswered report, or one callers keep searching for and missing, is worth the next cycle
      # in a way no download count can express. What this module still owns is the *breadth* half:
      # a package that became popular last week and appears in no report anywhere, and the depth
      # below the queue.
      #
      # Both are used, and that is the correction this function needed. It returned the queue
      # *instead of* the ranking whenever the queue had anything in it, on the reasoning that the
      # two must not be merged — which is true of *interleaving* them, since two orders combined
      # by a third rule is an order neither produced, and false of putting one after the other.
      # The consequence was that the operator's `top` was silently ignored: the queue is served a
      # page at a time, so a miner asking for a thousand names was handed one page worth of them,
      # worked through it, and had nothing left. When the queue is exhausted the ranking is what
      # there is to mine, and it is already on disk.
      #
      # A `remote` that raises is not a failed run. The service being briefly unreachable should
      # cost the miner its *preference*, not its work; the local ranking is already cached and the
      # miner goes on with it. The exception is recorded rather than swallowed, because the
      # version of this that silently fell through hid a permanent 422 for as long as the queue
      # has existed.
      #
      # The one that exists today is a paused index, where the ranking is a list of names for
      # an index the service has stopped accepting evidence about — falling back to it would
      # build an environment for every pair and have every filing refused at the end, which is
      # the most expensive way for a miner to learn nothing.
      #
      # The fallback is used only when there is no queue and no ranking to be had at all — no
      # cache and no network on a first start. Filing into an empty corpus is worse than filing
      # from a shorter list, so the curated names are kept for exactly that case rather than
      # deleted.
      def watchlist(cache:, top: DEFAULT_TOP, fallback: [], remote: nil, ranking_of: nil, re_raise: [])
        chosen = []
        seen = Set.new

        # Add what is new and importable, up to the operator's bound.
        #
        # A lambda rather than a method because it closes over the two collections above, and the
        # count it returns is per source: the three numbers in `Chosen` come from these three
        # calls and from nowhere else, which is what makes the log line honest.
        take = lambda do |names|
          before = chosen.length
          names.each do |name|
            break if chosen.length >= top
            next if seen.include?(name) || !usable?(name)

            seen << name
            chosen << name
          end
          chosen.length - before
        end

        queue_error = nil
        from_queue = 0
        unless remote.nil?
          begin
            from_queue = take.call(remote.call)
          rescue StandardError => e
            raise if Array(re_raise).any? { |klass| e.is_a?(klass) }

            # Deliberately broad, and the one place in this package that is: the caller passes
            # whichever client it has, and every way a network call can fail is a "use the
            # other list" rather than a reason to stop.
            queue_error = "#{e.class}: #{e.message}"[0, 200]
          end
        end

        from_ranking = 0
        from_fallback = 0
        breadth = ranking_of || method(:ranking)
        if chosen.length < top
          begin
            # Twice what was asked for, because the queue has already spent part of the bound and
            # this list is what fills the rest.
            from_ranking = take.call(breadth.call(cache: cache, top: top * 2))
          rescue *UNREADABLE
            # No cache and no network. The ranking's own fallback is the cached copy, so reaching
            # here means a first start with nothing to read.
            from_fallback = take.call(fallback)
          end
        end

        Chosen.of(packages: chosen.freeze, from_queue: from_queue, from_ranking: from_ranking,
          from_fallback: from_fallback, queue_error: queue_error)
      end

      #
      # Redirects are followed, and this is the only reader here that does: the ranking has been
      # cited under a `hugovk.github.io` URL that now redirects, `urllib` followed it silently, and
      # a `Net::HTTP` port that did not would answer a 301 where the client it replaces answered a
      # document. Bounded at `REDIRECTS` because the one thing a redirect loop must not do is hold
      # a cycle hostage.
      def fetch(url, redirects: REDIRECTS)
        uri = URI.parse(url)
        response = Net::HTTP.start(
          uri.host, uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: TIMEOUT, read_timeout: TIMEOUT
        ) { |http| http.get(uri.request_uri) }

        if response.is_a?(Net::HTTPRedirection)
          location = response["location"].to_s
          code = response.code.to_i
          # A redirect with nowhere to go, and one that will not stop: both are "no document",
          # which is the same answer as a 404 and the same reason to fall back on the cache.
          if location.empty?
            raise IndexError.new("#{url} -> #{response.code} with no Location", code: code)
          end
          raise IndexError.new("#{url} -> redirect loop", code: code) if redirects <= 0

          return fetch(URI.join(url, location).to_s, redirects: redirects - 1)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise IndexError.new("#{url} -> #{response.code}", code: response.code.to_i)
        end

        response.body
      end

      private

      # A cached reading, or nil when there is none to trust.
      #
      # The third is the one worth keeping: `{"rows": "nonsense"}` parses fine, and a reader
      # that handed it on would fail somewhere that cannot say what it was reading.
      def read_cache(path)
        return nil unless path.file?

        begin
          cached = JSON.parse(path.read(encoding: "utf-8"))
        rescue JSON::ParserError
          return nil
        end
        cached.is_a?(Array) ? cached : nil
      end

      # Whether a cached file is young enough to be trusted. `max_age` of zero is "never trust a
      # cache", which is what the tests use to drive a refetch without touching a clock.
      def fresh?(path, max_age)
        (Time.now.to_f - path.mtime.to_f) <= max_age
      end
    end
  end
end
