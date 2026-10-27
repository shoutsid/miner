# frozen_string_literal: true

# RubyGems releases, and the ordering rule they are read with.
#
# The PyPI side of this miner needs three files per package — the version list, the sizes and
# the dates — because the payload it reads grew a field at a time and a cache written before a
# field existed still has to be usable. RubyGems needs one: `/api/v1/versions/<gem>.json`
# returns **every** indexed, non-yanked version in a single document with `number`, `prerelease`
# and `created_at` on each entry, and the `page` parameter is ignored. That was measured rather
# than assumed — `rails` answers 521 versions with and without `?page=2`, and the count agrees
# with the compact index — so there is one cache file here and nothing to keep in step.
#
# Two decisions are the whole module.
#
# **Pre-releases are not releases.** The endpoint reports `prerelease` as a flag rather than
# leaving it to be inferred from the string, so the ladder is the non-pre-release versions and
# nothing else. A caller's lockfile is not sitting on `2.0.0.rc1`, and a differential against one
# describes a release almost nobody has.
#
# **The ordering is `Gem::Version`'s, not a numeric core's.** `1.0 == 1.0.0`, `1.9.3 < 1.10.0`, a
# `-` is a pre-release separator (`1.0.0-1` is *older* than `1.0.0.1`) and a trailing run of zeros
# is not part of the version. Picking the wrong predecessor picks the wrong comparison, so this
# is written to the same rule as `app.trust.gem_version_key`, and `scripts/gem-version-check.py`
# drives both copies through a real `Gem::Version` in a container — a reimplementation of
# somebody else's ordering rule is worth exactly the evidence behind it.
#
# `ruby_versions_test.rb` holds the two together.
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "pathname"
require "socket"
require "timeout"
require "uri"

require_relative "pair"

module AgentsMiner
  module RubyVersions
    # Where a gem's releases come from. One request per gem, complete: see the module comment
    # for the measurement that makes the `page` parameter meaningless.
    #
    # `%s` rather than the Python client's `{package}` placeholder: `versions.rb`, the PyPI
    # ladder beside this one, is written the same way, and the two are read together.
    INDEX = "https://rubygems.org/api/v1/versions/%s.json"

    # The cache, named so it cannot collide with the PyPI history of a gem and a package that
    # share a name — which is exactly the case this whole feature exists for. `rake` is both, and
    # the two ladders are different ladders.
    CACHE_SUFFIX = ".ruby.json"

    # How long a cached ladder is trusted before the index is asked again. The same compromise
    # the PyPI side makes and for the same reason: a gem's next release is what the miner is
    # waiting for, so a cache that never expires is a miner that will not notice it, and six
    # hours keeps RubyGems from being asked once per cycle for every gem.
    DEFAULT_MAX_AGE = 6 * 3600

    # What `Net::HTTP` gets for an index request, in seconds. `urllib`'s own `timeout=30` in
    # the client this was ported from, and it is the whole request rather than the read alone:
    # an index that accepts the connection and then says nothing is the failure this bounds.
    TIMEOUT = 30

    # The index answered, and not with a document: a 404 for a gem it has never heard of, or any
    # other non-2xx. Carries the code because the caller's answer differs — a gem that is not on
    # the index is a fact, while a 503 is the index having a moment.
    #
    # The twin of `Versions::IndexError`, spelled the same way, because the two ladders are the
    # two indexes and a reader comparing them should be comparing their rules rather than their
    # vocabulary.
    class IndexError < StandardError
      attr_reader :code

      def initialize(message, code:)
        super(message)
        @code = code
      end
    end

    #
    # A named class rather than `Errno::ENOENT` because "not on the index" is not a missing file,
    # and a caller that rescues this is rescuing the *judgement* rather than a syscall — the same
    # reasoning, and the same twin, as `Versions::NoHistory`. The CLI rescues both, because a
    # package with no ladder and a gem with no ladder are the same `[skip]` line.
    class NoHistory < StandardError; end

    # Every way the network fails, as one list instead of one class.
    #
    # Ruby spreads the same situation over `SocketError`, the `Errno::*` family, `IOError` and
    # the two `Net` timeouts — so the list is written once here and rescued as a splat, and a
    # failure it does not cover is a failure the caller should see. `versions.rb` holds the
    # identical list; `openssl` is required at the top of this file because a constant
    # reference to a class the interpreter has not loaded is a `NameError` while the file is
    # read.
    NETWORK_ERRORS = [SocketError, SystemCallError, IOError, Timeout::Error,
                      Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError].freeze

    # `Gem::Version::VERSION_PATTERN`, and the three rules below are the ones documented at
    # `app.trust.gem_version_key`. `+` is deliberately absent: a SemVer build tag is malformed to
    # RubyGems rather than orderable.
    #
    GEM_VERSION = /\A\s*(?:[0-9]+(?:\.[0-9a-zA-Z]+)*(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)?\s*\z/
    GEM_SEGMENT = /[0-9]+|[a-zA-Z]+/
    GEM_TRAILING = /(?<=[a-zA-Z.])[.0]+\z/
    GEM_LETTER = /[a-zA-Z]/
    NUMBERS = /\d+/

    # A single character that is a letter.
    LETTER_CHARACTER = /\A[a-zA-Z]\z/

    class << self
      # `Gem::Version#canonical_segments`'s second rule — see the service's twin.
      #
      private def strip_zeros_before_the_first_letter(text)
        text.each_char.with_index do |character, index|
          next unless "0.".include?(character)
          next if index.positive? && text[index - 1] != "."

          ending = index
          ending += 1 while ending < text.length && "0.".include?(text[ending])
          if ending < text.length && text[ending].match?(LETTER_CHARACTER)
            return text[0...index] + text[ending..]
          end
        end
        text
      end







      # The cached document, or nil when there is nothing readable there.
      #
      private def read_cache(path)
        payload = JSON.parse(path.read(encoding: "utf-8"))
      rescue SystemCallError, IOError, JSON::ParserError
        nil
      else
        payload.is_a?(Hash) ? payload : nil
      end

      # Whether a cached document is both fresh and a whole reading.
      #
      # "Fresh" alone is not enough, which is the lesson the PyPI side paid for: the endpoint
      # hands over the publication date with the version list, so a document without dates is one
      # written by something that did not read the whole response, and trusting it would file
      # every release undated for as long as the window lasts.
      private def complete?(payload, max_age:)
        return false if payload.nil?

        releases = payload["releases"]
        return false unless releases.is_a?(Array) && !releases.empty?
        return false if releases.any? { |release| !release.is_a?(Hash) || !release.key?("created_at") }
        return true if max_age.nil?

        fetched_at = Float(payload.fetch("fetched_at", 0))
        (Time.now.to_f - fetched_at) <= max_age
      rescue ArgumentError, TypeError
        false
      end

      # The release numbers in a fetched document, oldest first, without pre-releases.
      private def numbers_in(payload)
        releases = payload.is_a?(Hash) ? payload["releases"] : nil
        return [] unless releases.is_a?(Array)

        usable(
          releases.filter_map do |release|
            next unless release.is_a?(Hash)
            next unless release["number"].is_a?(String)
            next if release["prerelease"]

            release["number"]
          end
        )
      end
    end

    # The segments `Gem::Version` compares, or nil if this is not a version.
    def self.gem_key(raw)
      text = (raw || "").strip
      return nil unless text.match?(GEM_VERSION)

      text = "0" if text.empty?
      text = text.gsub("-", ".pre.")
      canonical = text.sub(GEM_TRAILING, "")
      canonical = strip_zeros_before_the_first_letter(canonical) if canonical.match?(GEM_LETTER)
      canonical.scan(GEM_SEGMENT).map { |part| part.match?(/\A[0-9]+\z/) ? part.to_i : part }
    end

    # `Gem::Version` order: -1, 0, 1, or nil for a version it would refuse.
    #
    # An Integer and a String are not comparable in Ruby either — `1 <=> "pre"` is nil — so the
    # two branches below are the rule rather than a convenience: a number sorts *before* a
    # word segment, which is what makes `1.0.0.pre` older than `1.0.0`.
    def self.compare(left, right)
      left_key = gem_key(left)
      right_key = gem_key(right)
      return nil if left_key.nil? || right_key.nil?

      width = [left_key.length, right_key.length].max
      width.times do |index|
        lhs = index < left_key.length ? left_key[index] : 0
        rhs = index < right_key.length ? right_key[index] : 0
        next if lhs == rhs

        return -1 if lhs.is_a?(String) && rhs.is_a?(Integer)
        return 1 if lhs.is_a?(Integer) && rhs.is_a?(String)

        return lhs < rhs ? -1 : 1
      end
      0
    end

    # The releases this miner will consider, oldest first.
    #
    # A version RubyGems itself would refuse is dropped rather than ordered by a guess: the
    # ladder's whole job is to name a predecessor, and a wrong order names the wrong one.
    # Pre-releases are already gone — the index reported them as a flag, and `release_history`
    # keeps only what it did not flag.
    #
    # It matters for exactly one input: two spellings of one release, `1.0` and `1.0.0`,
    # compare equal and are two entries in `usable` — and `crossings` names whichever it
    # meets first as that line's release. The tie-break is therefore the input order, so the
    # answer does not depend on the sort algorithm's mood. (The alternative — de-duplicating
    # equal versions — was rejected: `1.0.0.1` and `1.0.0-1` are *not* equal, and a rule
    # that keeps one spelling of the release the index published is a rule that would rename
    # a report's own version.)
    def self.usable(history)
      history.select { |version| !gem_key(version).nil? }
             .each_with_index
             .sort { |(left, left_index), (right, right_index)|
               ordered = compare(left, right) || 0
               ordered.zero? ? left_index <=> right_index : ordered
             }
             .map(&:first)
    end

    # The major and minor a release belongs to, which is what "a version behind" means.
    #
    # The same rule the PyPI side uses, and for the same measured reason: a caller who is
    # behind is behind by a *line*, and consecutive patch releases of a mature gem rarely change
    # what a call site has to say.
    def self.line_of(version)
      numbers = version.split("+").first.to_s.scan(NUMBERS).map(&:to_i)
      numbers << 0 while numbers.length < 2
      [numbers[0], numbers[1]]
    end

    # Every upgrade that crosses from one minor line to the next, newest first.
    #
    # Newest first because a failure people meet is one on a recent release, and a
    # three-year-old breakage nobody upgrades through is worth less than the last release
    # cycle's. The oldest lines still get mined; they are what the miner does with the time it
    # has left.
    def self.crossings(package, history, limit: 0)
      versions = usable(history)
      return [] if versions.empty?

      lines = []
      versions.reverse_each do |version|
        line = line_of(version)
        # Walking backwards, the first release met in a line is that line's newest — the one a
        # caller's lockfile is sitting on.
        lines << [line, version] if lines.empty? || lines.last[0] != line
      end

      pairs = lines[1..].zip(lines[..-2]).map do |(_, older), (_, newer)|
        Pair.of(package: package, from_version: older, to_version: newer)
      end
      limit.positive? ? pairs.first(limit) : pairs
    end

    # The latest release against the newest release of an earlier series.
    def self.pairs_for(package, history, span: 1)
      versions = usable(history)
      return [] if span < 1 || versions.empty?

      latest = versions[-1]
      target = line_of(latest)
      seen = [target]
      versions[..-2].reverse_each do |version|
        line = line_of(version)
        next if line == seen[-1] || seen.include?(line)

        seen << line
        # The first release met in a line not yet counted is that line's newest, because we are
        # walking backwards from the latest.
        return [Pair.of(package: package, from_version: version, to_version: latest)] if
          seen.length == span + 1
      end
      []
    end

    # The crossing a reviewed fix landed in: the release immediately before `fixed_in`, against
    # `fixed_in` itself.
    #
    # **Adjacent, not a line crossing, and that is the whole reason this exists beside `crossings`.**
    # A security fix is usually a patch release inside the line a caller is already on —
    # `rack 2.2.6 -> 2.2.6.1` — and `crossings` reduces a history to one release per minor line, so
    # it would never produce that pair at all: the advisory's own fix would be invisible to the
    # ladder. This names it directly.
    #
    # nil when the fix is not a release the index lists, or is the oldest release — there is then no
    # crossing to run, and a pair invented from a spelling the index does not have would examine the
    # wrong releases. When the fix is absent but the set is not, the first release at or after it is
    # used, because the fix landed between the release before that and that one.
    def self.advisory_pair(package, history, fixed_in:)
      return nil if fixed_in.to_s.strip.empty?

      versions = usable(history)
      return nil if versions.empty?

      index = versions.index { |version| compare(version, fixed_in).zero? }
      if index.nil?
        index = versions.index { |version| (compare(version, fixed_in) || 0) >= 0 }
      end
      return nil if index.nil? || index.zero?

      Pair.of(package: package, from_version: versions[index - 1], to_version: versions[index])
    end

    # The index, as text. **The one seam that touches the network**, so that a test can place a
    # document where it would otherwise have to reach RubyGems — the same seam the Python suite
    # patched (`urllib.request.urlopen`), the same shape as `Versions.fetch`, and the reason it
    # is a module method of one argument.
    def self.fetch(url)
      uri = URI.parse(url)
      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: TIMEOUT, read_timeout: TIMEOUT
      ) { |http| http.get(uri.request_uri) }

      unless response.is_a?(Net::HTTPSuccess)
        raise IndexError.new("#{url} -> #{response.code}", code: response.code.to_i)
      end

      response.body
    end

    # The index's own document for one gem, parsed. The endpoint returns every indexed,
    # non-yanked version in one array, which is what makes this ladder one file rather than
    # three.
    def self.payload_for(package) = JSON.parse(fetch(INDEX % package))

    # Every release of a gem the index will serve, oldest first.
    #
    # One request, cached, and the cache is what a run works from: the index is a third party,
    # and a run that re-fetched for every pair would be slow while a run that failed halfway
    # through because RubyGems rate-limited it would be indistinguishable from a run that found
    # nothing.
    #
    # When the cache is stale and the index cannot be reached the stale copy is used rather than
    # raising — the same trade the PyPI side makes, because a miner that stopped mining because
    # RubyGems was briefly down would be trading a certain loss for an uncertain one. `offline`
    # forbids the network outright.
    #
    # A gem the index does not have *and* a cache with nothing in it raises `NoHistory`: the
    # caller's move for both is the same — print `[skip] <why>` and work on the next package
    # — and the one the Python client made for the same case.
    def self.release_history(package, cache:, offline: false, max_age: DEFAULT_MAX_AGE)
      url = INDEX % package
      path = cache + "#{package}#{CACHE_SUFFIX}"
      payload = read_cache(path)
      return numbers_in(payload) if complete?(payload, max_age: max_age)

      if offline
        return numbers_in(payload) if payload

        raise NoHistory, "no cached history for #{package}, and the index is not being asked"
      end

      begin
        releases = payload_for(package)
      rescue IndexError => e
        return numbers_in(payload) if payload

        raise NoHistory, "#{package} is not on the index (#{e.code})"
      rescue *NETWORK_ERRORS
        # The stale copy is used rather than raising: a miner that stopped mining because
        # RubyGems was briefly down would be trading a certain loss for an uncertain one. A
        # resolver failure arrives as a `SocketError` rather than as a connection error, which
        # is why the list names it, and `IndexError` is handled above — it is not in the list,
        # and naming it twice would be a clause that never runs.
        return numbers_in(payload) if payload

        raise
      end
      fetched = { "releases" => releases, "fetched_at" => Time.now.to_f, "source" => url }
      FileUtils.mkdir_p(cache)
      # Written after the read that decides whether to fetch, so the file a reader finds is a
      # whole response rather than a half-written one.
      path.write(JSON.generate(fetched), encoding: "utf-8")
      numbers_in(fetched)
    end

    # Whether a complete reading is already on disk for this gem.
    #
    # The planner's fetch budget spends a request only on a package the cache does not cover, so
    # this has to answer the same question the fetch does — and it is the *same predicate*,
    # `complete?`, rather than a second rule that could disagree about a document holding
    # versions but no dates.
    def self.history_is_cached(package, cache:, max_age: DEFAULT_MAX_AGE)
      complete?(read_cache(cache + "#{package}#{CACHE_SUFFIX}"), max_age: max_age)
    end

    # When each release was published, as the index stated it.
    #
    # No sidecar and no completeness question: the date arrives in the same document as the
    # version it belongs to. An empty mapping means no reading, never "nobody published these on
    # a date".
    def self.release_dates(package, cache:)
      payload = read_cache(cache + "#{package}#{CACHE_SUFFIX}")
      return {} if payload.nil?

      releases = payload["releases"]
      return {} unless releases.is_a?(Array)

      releases.each_with_object({}) do |release, found|
        next unless release.is_a?(Hash)
        next unless release["number"].is_a?(String) && release["created_at"].is_a?(String)

        found[release["number"]] = release["created_at"]
      end
    end

    # When one release was published, or nil when this deployment did not read it.
    def self.release_date(package, version, cache:)
      release_dates(package, cache: cache)[version]
    end
  end
end
