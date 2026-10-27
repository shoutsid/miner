# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "openssl"
require "pathname"
require "timeout"
require "uri"

module AgentsMiner
  # The reviewed security advisories for RubyGems, read from the GitHub Advisory Database.
  #
  # **A lead, not a finding, and this module is built so a caller cannot mistake it for one.** It
  # reads what GitHub's curation team reviewed — `type:reviewed`, ecosystem `rubygems` — and hands
  # the service a *picture* of documented claims. Whether a release breaks a caller is a question
  # only this corpus's own execution answers, so a lead is never filed as a report: it orders the
  # queue's middle tier and names the release crossing to examine, and the miner turns it into
  # evidence by running that crossing like any other. GitHub did the validation; this service does
  # not repeat it and does not claim it.
  #
  # ## Why the REST route rather than the OSV archive
  #
  # The bulk OSV feed (`osv-vulnerabilities.storage.googleapis.com/RubyGems/all.zip`) is one 5 MB
  # request and carries structured ranges, and it is the *better* source for a client that can read
  # a zip. This one cannot: the miner is stdlib-only by design (`components/miner/README.md`), and
  # Ruby's standard library carries no zip reader — so the choice is between a hand-written deflate
  # reader and an API that answers the same question in twelve paged requests. The API is chosen,
  # and it answers with `first_patched_version`, which is exactly the one field the planner needs
  # (`introduced` and `last_affected` are recorded as absent rather than inferred). The page count
  # is bounded and the result is cached, so a daily refresh is a dozen requests against a limit of
  # sixty an hour.
  #
  # The cache is a file on the miner's volume, like the release index and the watchlist: a restart
  # does not re-read the source, and a cycle does not depend on GitHub being up.
  module Advisories
    INDEX = "https://api.github.com/advisories"
    QUERY = "ecosystem=rubygems&type=reviewed"
    # What the service records as the rows' source, and prints back to a reader.
    SOURCE = "github-reviewed"
    PER_PAGE = 100
    # The reviewed RubyGems set is about 1,160 advisories — twelve pages of a hundred. Forty is
    # slack for growth and a hard stop against a source that never stops paging.
    MAX_PAGES = 40

    # How long a fetched picture is trusted. The source changes as advisories are published and
    # withdrawn, so a day is generous and not unbounded: a picture that never expires is one that
    # keeps naming a fix for a release the database has since retracted.
    DEFAULT_MAX_AGE = 24 * 3600

    TIMEOUT = 60
    USER_AGENT = "agents-miner"

    # GitHub's own severity words, which the service validates against. A word outside this set is
    # dropped from the lead rather than sent: the source recorded something this build does not
    # understand, and a severity the service would refuse the whole body over is worse than none.
    SEVERITIES = %w[low medium high critical].freeze

    # The source answered, and not with a document. Carries the code because the caller's answer to
    # a 404 and a 503 is the same (use the cache, or fail) but the message is what an operator reads.
    class IndexError < StandardError
      attr_reader :code

      def initialize(message, code:)
        super(message)
        @code = code
      end
    end

    NETWORK_ERRORS = [SocketError, SystemCallError, IOError, Timeout::Error,
                      Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError].freeze

    # Everything that means "there is no picture to be had": the network, the status code and the
    # document. A payload that does not parse is a payload this module cannot read.
    UNREADABLE = (NETWORK_ERRORS + [IndexError, JSON::ParserError, KeyError, TypeError]).freeze

    class << self
      def cache_path(cache) = Pathname.new(cache) + "advisories-ruby.json"

      # The reviewed picture, cache-first.
      #
      # A fresh cache is returned without touching the network, and an unreadable source falls back
      # to a stale cache rather than raising when there is one — a miner that stopped because
      # GitHub had an afternoon would be trading a certain loss for an uncertain one, the rule the
      # breadth ranking already keeps. With no cache and no source the failure propagates, and the
      # service loop logs it and carries on: a lead is the smallest thing this miner works on.
      def picture(cache:, max_age: DEFAULT_MAX_AGE, fetch: true)
        path = cache_path(cache)
        cached = read_cache(path)
        return cached if !cached.nil? && max_age.to_f.positive? && fresh?(path, max_age)
        return cached unless fetch

        begin
          leads = fetch_picture
        rescue *UNREADABLE
          return cached unless cached.nil?

          raise
        end
        write_cache(path, leads)
        leads
      end

      # The leads grouped by gem, which is how the planner asks for them.
      def leads_by_library(leads)
        leads.group_by { |lead| lead.fetch("library") }
      end

      # Every reviewed RubyGems advisory GitHub publishes, as one flat list of leads.
      #
      # Flat rather than grouped because the *picture* is what travels to the service, and the
      # service keys it by `(library, advisory_id)`: two packages affected by one advisory are two
      # rows there, and one package affected by two advisories is two rows too.
      def fetch_picture(pages: MAX_PAGES)
        leads = []
        url = "#{INDEX}?#{QUERY}&per_page=#{PER_PAGE}"
        pages.times do
          body, link = fetch_page(url)
          Array(body).each { |advisory| leads.concat(leads_from(advisory)) }
          url = next_link(link)
          break if url.nil?
        end
        leads
      end

      # One advisory document, as one lead per affected RubyGems package.
      #
      # A withdrawn advisory produces nothing — it is a retraction, and the service's picture write
      # drops it anyway, but a client that never sends one is a client whose absence is honest.
      # An advisory that names no RubyGems package produces nothing either: the API answers this
      # filter with a RubyGems-first set, and a record that also touches another ecosystem must not
      # become a gem named the same way.
      #
      # **One advisory can carry several ranges for the same gem** — GitHub lists a separate
      # `vulnerabilities` entry per affected version line, and the service's key is
      # `(library, advisory_id)`, so they collapse to one row. A lead with a fix is preferred over
      # one without, and the first GitHub listed wins among several: the schema holds one `fixed_in`
      # and picking the range is a choice this client cannot make for the source. See
      # `docs/known-limits.md`.
      def leads_from(advisory)
        return [] unless advisory.is_a?(Hash)

        id = advisory["ghsa_id"].to_s
        return [] if id.empty? || !advisory["withdrawn_at"].nil?

        shared = shared_fields(advisory, id)
        found = {}
        Array(advisory["vulnerabilities"]).each do |vulnerability|
          next unless vulnerability.is_a?(Hash)

          package = vulnerability.dig("package", "name").to_s
          ecosystem = vulnerability.dig("package", "ecosystem").to_s
          next if package.empty? || !ecosystem.casecmp?("rubygems")

          fixed = vulnerability["first_patched_version"].to_s
          lead = shared.merge("library" => package, "fixed_in" => fixed.empty? ? nil : fixed)
          existing = found[package]
          found[package] = lead if existing.nil? || (existing["fixed_in"].nil? && !lead["fixed_in"].nil?)
        end
        found.values
      end

      private

      # The fields every lead from one advisory shares.
      def shared_fields(advisory, id)
        fields = {
          "advisory_id" => id,
          "aliases" => Array(advisory["identifiers"]).filter_map do |identifier|
            identifier["value"].to_s if identifier.is_a?(Hash) && identifier["type"].to_s == "CVE"
          end,
          "cvss_score" => advisory.dig("cvss", "score"),
          "cvss_vector" => advisory.dig("cvss", "vector_string"),
          "cwe_ids" => Array(advisory["cwes"]).filter_map do |cwe|
            cwe["cwe_id"].to_s if cwe.is_a?(Hash) && !cwe["cwe_id"].to_s.empty?
          end,
          "summary" => advisory["summary"].to_s,
          "source_url" => source_url(advisory, id),
          "reviewed_at" => advisory["github_reviewed_at"],
          "published_at" => advisory["published_at"],
          "modified_at" => advisory["updated_at"]
        }
        severity = advisory["severity"].to_s.downcase
        fields["severity"] = severity if SEVERITIES.include?(severity)
        fields
      end

      # The advisory's own page. The API always answers one; a missing `html_url` falls back to the
      # id's canonical address rather than leaving the row with no attribution at all, which the
      # service refuses.
      def source_url(advisory, id)
        url = advisory["html_url"].to_s
        url.empty? ? "https://github.com/advisories/#{id}" : url
      end

      # The next page's URL, out of the `Link` header. Nil is the end of the set, which is also
      # what a missing header means.
      def next_link(header)
        header.to_s.split(",").each do |part|
          next unless part.include?('rel="next"')

          match = part.match(/<([^>]+)>/)
          return match[1] if match
        end
        nil
      end

      # One page: the parsed body and the `Link` header.
      #
      # The one seam that touches the network, so a test places a document where it would otherwise
      # reach GitHub — the same shape `Watchlist.fetch` and `RubyVersions.fetch` keep.
      def fetch_page(url)
        uri = URI.parse(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
          open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = USER_AGENT
          request["Accept"] = "application/vnd.github+json"
          request["X-GitHub-Api-Version"] = "2022-11-28"
          http.request(request)
        end
        unless response.is_a?(Net::HTTPSuccess)
          raise IndexError.new("#{url} -> #{response.code}", code: response.code.to_i)
        end

        [JSON.parse(response.body), response["link"]]
      end

      def read_cache(path)
        return nil unless path.file?

        begin
          cached = JSON.parse(path.read(encoding: "utf-8"))
        rescue JSON::ParserError
          return nil
        end
        cached.is_a?(Array) ? cached : nil
      end

      def write_cache(path, leads)
        FileUtils.mkdir_p(path.dirname)
        path.write(JSON.generate(leads), encoding: "utf-8")
      end

      # Whether a cached file is young enough to be trusted. `max_age` of zero is "never trust a
      # cache", which is what the tests use to drive a refetch without touching a clock.
      def fresh?(path, max_age)
        (Time.now.to_f - path.mtime.to_f) <= max_age
      end
    end
  end
end
