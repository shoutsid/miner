# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
# Named because it is in `NETWORK_ERRORS`: a constant reference to a class the interpreter has
# not loaded is a `NameError` at the moment this file is read, not at the moment it is needed.
require "openssl"
require "uri"

module AgentsFyiMiner
  # Which upgrades are worth mining, taken from the index rather than from a list.
  #
  # A curated list of "packages that broke something" would be a list written by somebody who
  # already knew the answer, and it would go stale the moment it was published. The index
  # knows the releases, so the pairs come from there: an upgrade a caller would plausibly
  # make, which in practice means a release and its predecessor within the same minor series,
  # because that is what a lockfile bump or a `pip install -U` actually does.
  #
  # Pre-releases are excluded because an agent is rarely on one, and a yanked release is
  # excluded because a caller who did install it has a different problem.
  module Versions
    INDEX = "https://pypi.org/pypi/%s/json"

    # The request's own ceiling. Thirty seconds because this is a third party answering a
    # question about a package's whole history; a shorter one would time out on the large
    # projects this miner most wants, and a longer one holds a worker on a package it could
    # come back to.
    FETCH_TIMEOUT = 30

    # What one release of a package costs to download, cached beside its history.
    #
    # `release_history` already fetches the whole index payload — every release, every file,
    # every size — and used to throw all of it away but the version names. Those sizes are
    # what `envs.install_deadline` needs to decide how long an install may take, so keeping
    # them costs no request at all. A separate file rather than a new shape for the history
    # cache, so a cache written by the version before this one still reads.
    SIZES_SUFFIX = ".sizes.json"

    # When each release was published, from the same payload and the same reasoning as the
    # sizes above: the index hands over every file's upload time in the response this call
    # was already making, and it was being thrown away. Kept because it is the one thing that
    # lets the corpus say which of its facts a reader's training data could not have
    # contained — see `reports.published_at`. A sidecar for the same reason as the sizes: a
    # history cache written before this still reads. It reads as *incomplete* rather than as
    # fresh, though — see `complete_on_disk?` — because the version names it holds are not
    # the whole of what a fetch returns.
    DATES_SUFFIX = ".dates.json"

    # A file built for another machine. The deadline these sizes size is this deployment's,
    # and a Windows or ARM wheel is not the one it would download.
    OTHER_PLATFORMS = /win|macos|darwin|aarch64|arm64|i686|ppc|s390/

    # How long a cached history is trusted before the index is asked again.
    #
    # A service that runs for weeks needs this: a package's next release is exactly what it is
    # waiting for, and a cache with no expiry would leave it mining the same releases forever
    # while believing there was nothing new. Six hours is a compromise — short enough that a
    # release is picked up the same day, long enough that PyPI is not consulted once per cycle
    # for every package.
    DEFAULT_MAX_AGE = 6 * 3600

    # The index answered, and not with a payload: a 404 for a package it has never heard of,
    # or any other non-2xx. Carries the code because the caller's answer differs — a package
    # that is not on the index is a fact, while a 503 is the index having a moment.
    class IndexError < StandardError
      attr_reader :code

      def initialize(message, code:)
        super(message)
        @code = code
      end
    end

    # A named class rather than `Errno::ENOENT` because "not on the index" is not a missing
    # file, and a caller that catches this is catching the *judgement* rather than a syscall.
    class NoHistory < StandardError; end

    # Every way the network fails, as one list instead of one class.
    #
    # Ruby spreads the same situation over `SocketError`, the `Errno::*` family, `IOError` and
    # the two `Net` timeouts — so the list is written once here and rescued as a splat, and a
    # failure it does not cover is a failure the caller should see.
    NETWORK_ERRORS = [SocketError, SystemCallError, IOError, Timeout::Error,
                      Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError].freeze

    # The index, as text. **The one seam that touches the network**, so that a test can
    # place a payload where a test would otherwise have to reach PyPI — the same seam the
    # Python suite patched (`urllib.request.urlopen`) and the reason it is a module method
    # with no keyword arguments.
    def self.fetch(url)
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: FETCH_TIMEOUT, read_timeout: FETCH_TIMEOUT
      ) { |http| http.request(request) }

      unless response.is_a?(Net::HTTPSuccess)
        raise IndexError.new("#{url} -> #{response.code}", code: response.code.to_i)
      end

      response.body
    end

    def self.payload_for(package) = JSON.parse(fetch(INDEX % { package: package }))

    # Every release of a package the index will serve, oldest first.
    #
    # Cached on disk because the index is a third party: a run that re-fetched for every
    # pair would be slow, and a run that failed halfway through because PyPI rate-limited it
    # would be indistinguishable from a run that found nothing.
    #
    # Expiry is what makes the cache safe for a service rather than only for a run: a cached
    # history that never expires is a miner that will not notice the release it exists to
    # find. When the cache is stale and the index cannot be reached, the stale copy is used
    # rather than raising — a miner that stopped mining because PyPI was briefly down would
    # be trading a certain loss for an uncertain one — and `offline` is how a caller forbids
    # the network entirely.
    #
    # The cache this serves is the version list *and* the dates beside it: a reading that
    # cannot say when its releases were published is refreshed rather than trusted, for the
    # reason `complete_on_disk?` records.
    def self.release_history(package, cache:, offline: false, max_age: DEFAULT_MAX_AGE)
      path = cache + "#{package}.json"
      cached = read_cache(path)
      return cached if cached && complete_on_disk?(package, path, cache: cache, max_age: max_age)

      if offline
        return cached if cached

        raise NoHistory, "no cached history for #{package}, and the index is not being asked"
      end

      begin
        payload = payload_for(package)
      rescue IndexError => e
        return cached if cached

        raise NoHistory, "#{package} is not on the index (#{e.code})"
      rescue *NETWORK_ERRORS
        return cached if cached

        raise
      end

      FileUtils.mkdir_p(cache)
      releases = payload["releases"].is_a?(Hash) ? payload["releases"] : {}
      versions = releases.select { |_version, files| files.is_a?(Array) && !files.empty? }
                         .reject { |_version, files| files.any? { |file| file["yanked"] } }
                         .keys
      versions.sort_by! { |version| sort_key(version) }
      path.write(JSON.generate(versions))
      # From the payload already in hand, so pricing a release costs no request beyond the
      # history this call was going to fetch anyway.
      sizes = {}
      versions.each do |version|
        size = own_bytes(releases[version] || [])
        sizes[version] = size if size
      end
      (cache + "#{package}#{SIZES_SUFFIX}").write(JSON.generate(sizes))
      # And when each of them was published, from the same files. Only the first file is read
      # for the date: every file of one release was uploaded within seconds of the others,
      # and the alternative is a second rule for which one is "the" upload time.
      dates = {}
      versions.each do |version|
        files = releases[version] || []
        stamp = files.filter_map { |file| file["upload_time_iso_8601"] || file["upload_time"] }.first
        dates[version] = stamp if stamp
      end
      (cache + "#{package}#{DATES_SUFFIX}").write(JSON.generate(dates))
      versions
    end

    # When each release of a package was published, as the last fetch recorded it.
    #
    # Read from disk only, and an empty mapping rather than an error when there is no
    # sidecar: this is asked on the filing path, where a package whose history came from the
    # cache before dates were kept simply contributes no date, and the report goes out with
    # null. A publication date is worth having, and not worth failing a filing for.
    def self.release_dates(package, cache:) = read_dates(package, cache: cache) || {}

    # The sidecar itself: a mapping, or nothing when there is no readable one.
    #
    # The distinction `release_dates` deliberately does not make, and the one the cache's own
    # freshness needs: a sidecar holding `{}` is a reading of the index that found no upload
    # times, while an absent one is no reading at all. Only the second is a reason to ask the
    # index again.
    def self.read_dates(package, cache:)
      payload = JSON.parse((cache + "#{package}#{DATES_SUFFIX}").read)
      return nil unless payload.is_a?(Hash)

      payload.select { |_version, stamp| stamp.is_a?(String) }
    rescue SystemCallError, IOError, JSON::ParserError, TypeError
      nil
    end

    # One release's publication date, asking the index when the cache cannot say.
    #
    # `release_dates` reads the sidecar and nothing else, which is what a path that must not
    # wait on a third party wants. This is the one caller that must not *lose* the date
    # instead: filing is the only moment the fact can be stored, so a null here is a null for
    # ever — and the corpus's whole use for the column is answering what changed after a
    # reader's training data ends. So when the cache cannot date the release it asks the
    # index once, which is also the request that completes the cache for every later report
    # about that package, and answers nil only when the index cannot be reached: an undated
    # report is worth filing, a lost one is not.
    #
    # The planner's fetch budget deliberately does not reach here. That budget bounds what
    # the *walk* asks for breadth, one request per package it is considering; by the time a
    # pair is being filed the corpus has already decided it wants this one, and measured on
    # the live deployment the budget is the reason a report went out undated: 24 requests a
    # cycle cannot complete 2,885 cached histories, so a package past the budget mines from a
    # cache that cannot date it. Charging this request to the same allowance would put the
    # choice between breadth and the date, and the date is the thing being stored.
    def self.release_date(package, version, cache:, fetch: true)
      date = release_dates(package, cache: cache)[version]
      return date if date || !fetch

      begin
        release_history(package, cache: cache)
      rescue StandardError
        # Not on the index, an index that cannot be reached, or a payload that is not JSON:
        # all three are "no date", and none of them is a reason to refuse the finding this
        # report carries. Python narrowed this to `OSError` and `ValueError`; Ruby's
        # equivalents are spread over a dozen classes, so the broad rescue *is* the faithful
        # translation — the rule is "every way the index can fail is the same answer".
        return nil
      end
      release_dates(package, cache: cache)[version]
    end

    # Whether the files on disk answer for this package without asking the index.
    #
    # One rule with two readers, which is the only reason it is a method: the early return in
    # `release_history` serves the cache on it, and `history_is_cached` tells the planner's
    # *fetch budget* whether a request would happen on it. Two copies would drift, and the
    # drift is expensive in one direction — a budget charged for requests that are never made
    # is what spent a whole cycle's allowance on the head of the watchlist and left 411
    # packages unreachable behind it.
    #
    # A history is only complete if it can also say *when* each of its releases was
    # published. A cache written before the dates sidecar existed holds the version list and
    # no dates, so a report filed from it goes out undated for ever — the corpus cannot
    # answer what changed after a reader's training data ends for that release, which is the
    # whole point of the column. Measured on the live miner the day the column deployed:
    # 2,885 of 3,000 cached histories had no sidecar, 889 of them still inside the six-hour
    # window that would have served them from disk. The cost of asking instead is one request
    # per package, once, and it also refreshes the version list the request was going to want
    # anyway.
    def self.complete_on_disk?(package, path, cache:, max_age:)
      # Never trust the cache: a request happens, so the budget is charged one.
      return false if max_age.nil?
      return false if Time.now.to_f - path.mtime.to_f > max_age

      !read_dates(package, cache: cache).nil?
    end

    # The cached history, or nothing if there is not a readable one there.
    def self.read_cache(path)
      return nil unless path.exist?

      payload = JSON.parse(path.read)
      payload.is_a?(Array) ? payload : nil
    rescue JSON::ParserError, SystemCallError, IOError
      nil
    end

    # Whether asking the index for this package would only repeat what is on disk.
    #
    # The distinction a caller spending a *per-cycle fetch budget* needs, and the one it did
    # not have: a package whose history is already here costs a file read, and one whose
    # history is not costs a request. Counting both as a fetch is how the tail of the
    # watchlist became unreachable — the front of the order is never-touched packages that
    # produce no pair and are therefore never stamped as touched, so they return first every
    # cycle and spent the whole budget on histories the cache already held. Measured on the
    # live miner: 411 of 1000 packages had no cached history, and every one of them was
    # behind that head.
    #
    # "Here" means `complete_on_disk?`, not merely a readable version list: a history with no
    # dates sidecar is one `release_history` will ask the index about, so answering `true`
    # for it would spend the budget on a request that does happen while pretending it did
    # not — the same bug with its sign flipped.
    def self.history_is_cached(package, cache:, max_age: DEFAULT_MAX_AGE)
      # The caller has said the cache is never trustworthy, which is the same answer as "not
      # cached" to the question this asks.
      return false if max_age.nil?

      path = cache + "#{package}.json"
      return false if read_cache(path).nil?

      complete_on_disk?(package, path, cache: cache, max_age: max_age)
    end

    # What downloading one release costs, or nothing when that is not known.
    #
    # Read from the file `release_history` writes. Not knowing is a normal answer rather than
    # a failure — a cache written before the sizes were kept has no such file, and a caller
    # told nothing simply keeps the flat timeout it had before.
    def self.release_size(package, version, cache:)
      payload = JSON.parse((cache + "#{package}#{SIZES_SUFFIX}").read)
      size = payload.is_a?(Hash) ? payload[version] : nil
      size.is_a?(Integer) && size.positive? ? size : nil
    rescue SystemCallError, IOError, JSON::ParserError, TypeError
      nil
    end

    # What one release costs to download, as the largest file shaped like this machine.
    #
    # Deliberately the largest plausible file rather than the one pip will choose. This
    # number sizes a deadline and the two errors are not equal: too long costs an idle
    # worker, while too short kills the download and every byte moved is discarded. Choosing
    # the interpreter's exact wheel would need full tag matching, and one release's wheels
    # for one platform are within a few percent of each other — `nvidia-cudnn-cu12 9.23.2.1`
    # is 742 MB for ARM, 688 MB for x86-64 and 658 MB for Windows — so this is allowed to be
    # a little high and never low.
    def self.own_bytes(files)
      priced = Array(files).select { |file| file.is_a?(Hash) && file["size"].is_a?(Integer) && file["size"].positive? }
      return nil if priced.empty?

      wheels = priced.select { |file| file["packagetype"] == "bdist_wheel" }
      candidates = wheels.reject { |file| OTHER_PLATFORMS.match?(file["filename"].to_s) }
      (candidates.empty? ? (wheels.empty? ? priced : wheels) : candidates).map { |file| file["size"] }.max
    end

    # Order releases by their numbers, with anything non-numeric last.
    #
    # Deliberately not a full PEP 440 implementation. The comparison is only used to pick a
    # predecessor, and a release this cannot order is one the miner declines to guess about
    # rather than one it orders wrongly.
    def self.sort_key(version)
      head = version.split("+").first.to_s
      [head.match?(/[a-zA-Z]/) ? 1 : 0, head.scan(/\d+/).map(&:to_i)]
    end

    # The major and minor a release belongs to, which is what "a version behind" means.
    #
    # A caller who is behind is behind by a *line*, not by a patch: consecutive patch
    # releases of a mature package almost never remove an argument, and comparing them
    # produced nothing across ten watchlisted packages in a row. The upgrade that breaks
    # people is the one that crosses from one minor series to the next — the one
    # `pip install -U` performs.
    def self.line_of(version)
      numbers = version.split("+").first.to_s.scan(/\d+/).map(&:to_i)
      numbers << 0 while numbers.length < 2
      [numbers[0], numbers[1]]
    end

    # The releases this miner will consider, in order.
    #
    # Pre-releases are excluded because an agent is rarely on one, and a release this module
    # cannot order numerically is excluded because a wrong order picks the wrong predecessor
    # — declining to guess is the honest response.
    def self.usable(history)
      history.reject { |version| version.split("+").first.to_s.match?(/[a-zA-Z]/) }
    end

    # Every upgrade that crosses from one minor line to the next, newest first.
    #
    # `pairs_for` answers the question a caller asks *today* — "what does the newest release
    # do to the version I am on" — and that is the right answer for one run. A service that
    # keeps working has the opposite requirement: it has to have something to do tomorrow,
    # and the newest release stops being new. So this walks the whole ladder instead, newest
    # crossing first, which is the order a caller's lockfile walks up it.
    #
    # Newest first rather than oldest first is deliberate for the same reason the corpus
    # exists: a failure people meet is one on a recent release, and a finding from three
    # years ago that nobody upgrades through any more is worth less than one from the last
    # release cycle. The oldest lines still get mined — a package with forty lines is a
    # package with thirty-nine findings — but they are what the miner does with the time it
    # has left.
    def self.crossings(package, history, limit: 0)
      versions = usable(history)
      return [] if versions.empty?

      lines = []
      versions.reverse_each do |version|
        line = line_of(version)
        # Walking backwards, the first release met in a line is that line's newest, which is
        # the one a caller's lockfile is sitting on.
        lines << [line, version] if lines.empty? || lines.last[0] != line
      end
      # `lines` is newest first, so each consecutive pair is (newer line, older line) and the
      # version comes out of the *second* slot of each entry. Written out rather than
      # destructured inline because getting the slot wrong here builds a pair whose versions
      # are line numbers — `[1, 0]` where `1.0.0` belongs — which is a value that reaches the
      # ledger and reads as a package that does not exist.
      pairs = lines.each_cons(2).map do |(_, newer_version), (_, older_version)|
        Pair.of(package: package, from_version: older_version, to_version: newer_version)
      end
      limit.positive? ? pairs.first(limit) : pairs
    end

    # The latest release against the newest release of an earlier series.
    #
    # One pair rather than every consecutive pair, because the question is what a caller
    # moving *now* will meet: the newest release, compared against the one they are
    # plausibly on. A patch-level predecessor is almost never that — the releases are
    # identical down to their signatures — so the predecessor is the last release of an
    # earlier *line*, which is where a package actually changes what it accepts.
    #
    # `span` chooses how many lines back: one is the previous minor series, and a wider span
    # is a caller who has skipped versions.
    def self.pairs_for(package, history, span: 1)
      ordered = usable(history)
      return [] if span < 1 || ordered.empty?

      latest = ordered.last
      seen = [line_of(latest)]
      ordered[0...-1].reverse_each do |version|
        line = line_of(version)
        next if line == seen.last || seen.include?(line)

        seen << line
        if seen.length == span + 1
          # The first release we meet in a line we have not counted is that line's newest,
          # because we are walking backwards from the latest.
          return [Pair.of(package: package, from_version: version, to_version: latest)]
        end
      end
      []
    end
  end
end
