# frozen_string_literal: true

require "fileutils"
require "json"

module AgentsFyiMiner
  # What each release of a gem **declares**: its Ruby floor and its runtime dependencies.
  #
  # `rubyversions.rb` reads `/api/v1/versions/<gem>.json`, which carries a release's number,
  # its prerelease flag, its date and its Ruby requirement — everything except the one fact a
  # Rails move turns on. `devise 2.2.4` declares `railties ~> 3.1`; that is why a Rails 4 rung
  # cannot keep it, and no reading of Rails' own guide says so. The **compact index**
  # (`/info/<gem>`) carries both the requirement and the dependencies, one line per release,
  # so this module reads it and the facts it produces are what `POST /releases/facts` stores.
  #
  # The document's format, as one parser:
  #
  #     <version> <name>:<requirement>,<name>:<requirement>|<key>:<value>,<key>:<value>
  #
  # where a version may carry a platform suffix (`1.16.0-x86_64-linux`), a release with no
  # dependencies has an empty section before the pipe, and a requirement with several clauses
  # joins them with `&` (`railties:< 5&>= 3.2.6`) — which is why the dependency list can be
  # split on commas at all. A `---` header line opens the document.
  #
  # **This parser exists in two clients on purpose, and the reason is worth stating.** The
  # upgrader's `Research` reads the same document, for the same reason: the *service* cannot
  # reach the index (its container has no route out), so whoever can fetch it parses it and
  # the service decides what the reading means. Putting the parser in the service would mean
  # a service that accepts a third party's document over its own body cap — `rails`' document
  # is hundreds of kilobytes — for a route no client would send when it can already parse what
  # it just fetched. The two are held to the same lines: both suites quote the real index.
  module RubyIndex
    # Where a gem's declared facts come from. The compact index rather than the versions API:
    # the latter has `ruby_version` per release and no dependencies at all.
    INDEX = "https://index.rubygems.org/info/%s"

    # A cache file per gem, distinct from `rubyversions.rb`'s: one holds a JSON payload from
    # one endpoint and this one holds the other endpoint's text, and a reader that guessed
    # which it had would parse one as the other.
    CACHE_SUFFIX = ".ruby.info"

    # The same window the rest of this client uses. A gem's next release is what a run is
    # waiting for, and a cache that never expired would not see it.
    DEFAULT_MAX_AGE = 6 * 3600

    # The document could not be read and there is nothing cached to fall back on.
    class NoDocument < StandardError; end

    class << self
      # `{ version => { "ruby_requirement" => String|nil, "dependencies" => [{"name" =>,
      # "requirement" =>}] } }`.
      #
      # **An empty mapping means nothing was read**, never that the releases declare nothing —
      # the same rule `rubyversions.rb` states for its own reader, and the one the caller
      # depends on to decide whether to settle a gem. A release the index states no
      # requirement for maps to nil, which is a statement; a release with no dependencies maps
      # to `[]`, which is another.
      #
      # A stale copy is used when the index cannot be reached, rather than raising: a miner
      # that stopped recording facts because RubyGems was briefly down would be trading a
      # certain loss for an uncertain one. `offline` forbids the network outright.
      def release_facts(package, cache:, offline: false, max_age: DEFAULT_MAX_AGE)
        path = cache + "#{package}#{CACHE_SUFFIX}"
        cached = path.file? ? path.read(encoding: "utf-8") : nil
        return parse(cached) if fresh?(path, cached, max_age)

        if offline
          return parse(cached) if cached

          raise NoDocument, "no cached document for #{package}, and the index is not being asked"
        end

        begin
          document = fetch_to(package)
        rescue RubyVersions::IndexError => e
          return parse(cached) if cached

          raise NoDocument, "#{package} is not on the index (#{e.code})"
        rescue *RubyVersions::NETWORK_ERRORS
          return parse(cached) if cached

          raise NoDocument, "the index could not be reached for #{package}"
        end
        FileUtils.mkdir_p(cache)
        path.write(document, encoding: "utf-8")
        parse(document)
      end

      # Whether a fresh document is already on disk for this gem — the question a fetch budget
      # asks before spending a request, answered by the same predicate the read uses.
      def document_is_cached?(package, cache:, max_age: DEFAULT_MAX_AGE)
        path = cache + "#{package}#{CACHE_SUFFIX}"
        fresh?(path, path.file? ? path.read(encoding: "utf-8") : nil, max_age)
      end

      # The whole document, parsed. Pure, so the format is testable against lines copied from
      # the real index rather than against a fixture invented beside the reader.
      def parse(document)
        document.to_s.each_line.with_object({}) do |line, facts|
          line = line.strip
          next if line.empty? || line.start_with?("---")

          left, right = line.split("|", 2)
          release, dependencies = left.to_s.split(" ", 2)
          next if release.to_s.empty?

          requirements = (right || "").split(",").filter_map do |pair|
            key, value = pair.split(":", 2)
            [key, value] if key && value
          end.to_h
          facts[release] = {
            "ruby_requirement" => requirements["ruby"],
            "dependencies" => (dependencies || "").split(",").filter_map do |pair|
              name, requirement = pair.split(":", 2)
              next if name.nil? || name.empty?

              { "name" => name, "requirement" => requirement.to_s.empty? ? nil : requirement }
            end
          }
        end
      end

      private

      def fresh?(path, cached, max_age)
        return false if cached.nil? || cached.strip.empty?
        return false unless path.file?

        (Time.now - path.mtime) < max_age
      end

      # The one HTTP call this module makes, through the fetcher `rubyversions.rb` already
      # has: one timeout, one error vocabulary, one place this client speaks to RubyGems.
      def fetch_to(package)
        RubyVersions.fetch(INDEX % package)
      end
    end
  end
end
