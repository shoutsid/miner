# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "pathname"
require "timeout"
require "uri"

require_relative "advisories"
require_relative "errors"
require_relative "reporting"
module AgentsFyiMiner
  # Talking to the corpus: what this miner files, and what it declines to file.
  #
  # The miner's reports are its own evidence — a failure was executed, and a fix was
  # executed — but whether a report is *new* is not a question the miner can answer,
  # because that question is about the corpus. So it asks the service, through the same
  # precheck a caller would use, and files only what comes back `new`. That is not
  # politeness: a miner that submitted optimistically would spend its rate limit re-filing
  # what other miners had already found, and a corpus padded with the same finding in
  # different words is worth less than the one without it.
  #
  # Filing is deliberately the only thing this module does. It does not decide what is true,
  # and it does not assemble the report — that is `reporting.rb`, so the evidence a report
  # carries can be tested without a server.

  # One HTTP exchange, as this client's own shape rather than a library's.
  #
  # The whole point is the seam.
  #
  # A *refusal* is a response: 429, 422 and a 503 with a `collection_paused` body are all
  # answers from a service that read the request, and they are not exceptions yet. Only a
  # network that failed is an exception, and `Unreachable` is the one this file maps to the
  # retry-later `CorpusError`.
  class Http
    TIMEOUT = 60

    Response = Data.define(:status, :body, :headers) do
      def ok? = status >= 200 && status < 300

      def header(name) = headers[name.to_s.downcase]
    end

    class Unreachable < StandardError; end

    # What a `Net::HTTP` failure looks like from here. Listed rather than rescued as
    # `StandardError`, so a bug in this file is a crash and not a "the corpus was down".
    #
    # `OpenSSL` is conditional because `net/http` loads it only when it can: a build with no
    # OpenSSL serves plain HTTP and never raises that class, and naming it unconditionally
    # would be a `NameError` at load time on exactly such a machine.
    UNREACHABLE = [
      Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, IOError, SystemCallError,
      SocketError, EOFError, (OpenSSL::SSL::SSLError if defined?(OpenSSL))
    ].compact.freeze

    # Perform one exchange. Never raises for a status code; returns it.
    def call(method:, url:, body: nil, headers: {}, timeout: TIMEOUT)
      uri = URI.parse(url)
      # Built per call rather than kept: this client is used by a handful of threads at once
      # (the miner's workers all file through one session), and a shared `Net::HTTP` object
      # is a socket shared between them.
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      request = request_class(method).new(uri)
      headers.each { |name, value| request[name] = value }
      request.body = body if body

      response = http.request(request)
      Response.new(status: response.code.to_i, body: response.body.to_s,
        headers: normalise(response))
    rescue *UNREACHABLE => e
      # A service meets a network that is down, and the difference between "the corpus
      # refused" and "the corpus was unreachable" is only what the caller does next — both
      # are try-again-later, so both are one exception with the reason in the message.
      raise Unreachable, "#{e.class}: #{e.message}"
    end

    private

    def request_class(method)
      case method.to_s.upcase
      when "GET" then Net::HTTP::Get
      when "POST" then Net::HTTP::Post
      when "PUT" then Net::HTTP::Put
      else raise ArgumentError, "unsupported method #{method.inspect}"
      end
    end

    def normalise(response)
      response.each_header.to_h { |name, value| [name.downcase, value] }
    end
  end

  # A signed-in operator on the service, and the corpus it can see.
  class Corpus
    # The service is rate limited per operator, 60 writes an hour by default. Waiting is the
    # correct response to a 429 rather than retrying: the quota is the service's own
    # protection, and a miner that hammered it would be the reason it needed one.
    #

    def initialize(base_url:, api_key:, http: Http.new)
      @base_url = base_url
      @api_key = api_key
      @http = http
    end

    attr_reader :base_url, :api_key, :http

    def precheck(payload)
      # Whether this draft is new, and what it is close to if it is not.
      request("POST", "/api/reports/precheck", body: payload)
    end

    # One index's queue: what the service thinks is worth mining, best first.
    #
    # This replaced a third-party ranking as the miner's source of work. The difference is
    # not the format — it is that the service computes this from its own observations (a
    # library with an unanswered report, one callers keep searching for and missing, one
    # that has already broken its callers), so the queue is reviewable, it names its
    # reasons, and it can be recomputed rather than re-fetched. The external list survives
    # inside the service as a breadth seed for packages nothing here has heard of.
    #
    # Paged, and the paging is the point. The route returns at most `limit_max` targets per
    # request and says so in the body, so asking for more than that is not an error to be
    # answered with a fallback — it is a second request. The miner asked for a thousand in
    # one call for as long as this method has existed and was answered 422 every time, which
    # its caller read as "the service has no queue" and quietly replaced with the local
    # ranking; the queue the service computes has therefore never reached the only miner
    # that reads it.
    #
    # An empty list is a real answer: no queue has been computed, or there is nothing left
    # to mine. The caller falls back to the breadth list, which is the honest move for a
    # first start — a miner with no work from its service is better off with a list of
    # popular packages than with nothing at all.
    def mining_targets(limit: 1000, pages: 32, ecosystem: "python")
      found = []
      offset = 0
      [pages, 1].max.times do
        wanted = limit - found.length
        break if wanted <= 0

        body = request("GET", "/api/mining/targets",
          params: { "limit" => wanted, "offset" => offset,
                    "ecosystem" => ecosystem })
        if body["paused"]
          # The queue states the pause in its body rather than refusing, because an operator
          # still has to be able to see *why* there is nothing here and which route resumes
          # it. Raised rather than returned as an empty list: "nothing left to mine" is
          # progress and this is a decision, and a client that conflates them spends a cycle
          # building environments for pairs whose filings will all be refused.
          reason = body["paused_reason"] || "no reason was recorded"
          advice = body["next_step"] || ""
          raise Errors::CollectionPaused.new(
            "the #{ecosystem} queue is paused: #{reason}. #{advice}".strip, ecosystem: ecosystem
          )
        end

        targets = body["targets"].is_a?(Array) ? body["targets"] : []
        rows = targets.select { |item| item.is_a?(Hash) && item["package"] }
        break if rows.empty?

        found.concat(rows.map { |item| item["package"].to_s })
        served = body["limit_max"]
        unless served.is_a?(Integer) && served.positive?
          # A service that does not say how much a page holds gives no way to tell a full
          # page from a short one, so one page is what this reads. Guessing "there must be
          # more" would walk a queue that is empty.
          break
        end
        # A page shorter than what was asked for *and* shorter than the service said it
        # would serve is the end of the queue. Both halves matter: asking for ten and being
        # served two of a promised five hundred is the end, while being served exactly the
        # two that exist is not.
        break if rows.length < [served, wanted].min

        offset += rows.length
      end
      found.first(limit)
    end

    # Whether an index is collecting, without asking it for a full work list.
    #
    # This is the one cheap way a client can know before it spends an install: the queue states a
    # pause in its body rather than refusing, and `mining_targets` raises on it because a client
    # looking for work wants that. A verifier is not looking for work — it has its own backlog —
    # so it needs the answer and none of the queue, and `limit: 1` is what bounds the queue it
    # walks through to get it.
    #
    # A failure is the caller's to read rather than a `false` here: an unreachable service is not
    # a paused one, and the report read that follows this probe is the honest question.
    def collection_paused?(ecosystem)
      body = request("GET", "/api/mining/targets",
        params: { "limit" => 1, "offset" => 0, "ecosystem" => ecosystem })
      body.is_a?(Hash) && body["paused"] == true
    end

    # Hand the service the breadth ranking this container can reach.
    #
    # The division of labour is deliberate and is the opposite of what it first looks like:
    # the *service* owns what the ranking means — how much it counts for, which tier it can
    # reach, and when it was read — and this client, which is the one with a route to the
    # outside, does the fetching. The service container on this deployment has no egress at
    # all, so a service that insisted on fetching its own seed would have an empty one, and a
    # queue built only from packages somebody has already hit.
    #
    # The service stamps the time it received the list. Nothing here can know when a third
    # party last published it, and a claim the receiver cannot check is worth less than no
    # claim.
    #
    # `ecosystem` says which index these names belong to, and it is not optional in practice
    # the moment more than one is mined: a ranking is a ranking *of* an index, and a list of
    # gem names posted as PyPI's would send a Python installer after every one of them.
    def contribute_seed(projects, source:, ecosystem: "python")
      request("POST", "/api/mining/seed",
        body: { "projects" => projects, "source" => source, "ecosystem" => ecosystem })
    end

    # Hand the service the releases this machine cannot build, as the picture it holds now.
    #
    # A picture rather than a delta, and that is the service's contract rather than a preference:
    # its write replaces the releases recorded for that index, so a release that installs again
    # after an image bump drops out by being absent. An empty list is therefore a real thing to
    # send — "this machine can examine everything it knows about" — and it is how a picture is
    # cleared.
    #
    # `machine` travels with it because an unexaminable release is a fact about the interpreter and
    # the toolchain as well as about the release: a wheel that does not exist for `cp312` exists
    # for `cp313`, and a fact with no stamp is one no later image could retire.
    def report_unexaminable(records, machine:, ecosystem: "python")
      request("POST", "/api/mining/unexaminable",
        body: { "ecosystem" => ecosystem, "machine" => machine,
                "records" => records.map do |record|
                  { "package" => record.fetch(:package), "release" => record.fetch(:release),
                    "reason" => record.fetch(:reason) }
                end })
    end

    # Hand the service the reviewed advisories for an index, as the picture this machine holds now.
    #
    # A picture rather than a delta, the same contract `report_unexaminable` keeps: the write
    # replaces what was recorded, so an advisory GitHub withdraws drops out by being absent.
    #
    # **The rows are documented claims, not evidence, and this method computes nothing.** It
    # forwards what GitHub reviewed — the service decides what the picture means, which tier it
    # fills and when it was read — and it never becomes a report. Nil fields are dropped rather than
    # sent, because an absent value and a null one read the same to the service and the smaller
    # body is the one that fits.
    def contribute_advisories(records, ecosystem: "ruby")
      request("POST", "/api/mining/advisories",
        body: { "ecosystem" => ecosystem, "source" => Advisories::SOURCE,
                "records" => records.map do |record|
                  record.transform_keys(&:to_s).reject { |_key, value| value.nil? }
                end })
    end

    # Hand the service the Ruby requirement each release of one gem declares.
    #
    # The write is idempotent on the service side, so a repeated batch replaces the same
    # rows. RubyGems only: the service refuses any other index.
    #
    # Accepting both costs one line here and saves a call site written against the other
    # convention from being an `ArgumentError` nobody can explain — the port is one language's
    # names, not one language's calling convention.
    def record_release_facts(library = nil, facts = nil, **named)
      library ||= named[:library]
      facts ||= named[:facts]
      # Named rather than quietly sent blank: a body with a null library is a 422 the caller
      # would read as the corpus refusing a fact, which it is not.
      raise ArgumentError, "record_release_facts needs a library and its facts" if library.nil? || facts.nil?

      request("POST", "/api/releases/facts",
        body: { "ecosystem" => "ruby", "library" => library, "facts" => facts })
    end

    def submit(payload) = request("POST", "/api/reports", body: payload)

    # Who this key is, so a service can tell its own reports from others'.
    #
    # The miner verifies by executing, and execution by the author is not the independent
    # reproduction the corpus asks for. Knowing its own operator id is what lets it decline
    # to vote on itself rather than write a row the service will refuse to count.
    def me = request("GET", "/api/operators/me")

    # One page of everything created or changed after a cursor.
    #
    # Hidden reports are included by the service on purpose, and the miner cannot act on one,
    # so it filters rather than asking the service to. The alternative — a miner blind to
    # retractions — would keep answering a failure that was withdrawn.
    def changes(since: nil, since_id: nil, limit: 100)
      request("GET", "/api/reports/changes",
        params: { "since" => since, "since_id" => since_id, "limit" => limit })
    end

    def report(report_id) = request("GET", "/api/reports/#{report_id}")

    # Reserve a report while working on it, so nobody derives it twice.
    def claim(report_id) = request("POST", "/api/reports/#{report_id}/claim")

    def release(report_id) = request("POST", "/api/reports/#{report_id}/release")

    def propose_resolution(report_id, payload)
      request("POST", "/api/reports/#{report_id}/resolution", body: payload)
    end

    def verify(report_id, payload)
      request("POST", "/api/reports/#{report_id}/verify", body: payload)
    end

    # File one finding, or say why it was not filed.
    #
    # Returns the verdict for what happened — `filed`, or the precheck's own
    # `duplicate`/`similar`/`new` when nothing was written — so a run can report what it did
    # with each finding without parsing prose. Every HTTP failure propagates: a run that
    # silently filed nothing would look exactly like a run that found nothing.
    def submit_mined(finding, from_version:, published_at: nil, pace: 0.0, dry_run: false)
      payload = Reporting.payload_for(finding, from_version: from_version,
        published_at: published_at)
      verdict = precheck(Reporting.precheck_payload_for(payload))
      outcome = verdict["verdict"] || "unknown"
      return outcome if !Errors.filable?(outcome) || dry_run

      sleep(pace) if pace.to_f.positive?
      submit(payload)
      "filed"
    end

    # The one place a request is issued, and the one place a status code becomes an error.
    def request(method, path, body: nil, params: nil)
      url = base_url.sub(%r{/+\z}, "") + path
      if params
        query = params.reject { |_key, value| value.nil? }
        url += "?#{URI.encode_www_form(query)}" unless query.empty?
      end

      response = http.call(method: method, url: url,
        body: body.nil? ? nil : JSON.generate(body),
        headers: { "X-API-Key" => api_key,
                   "Content-Type" => "application/json",
                   "Accept" => "application/json" })
      detail = response.body.to_s
      return JSON.parse(detail) if response.ok?

      # Before the status code, because a pause is answered 503 on purpose: it shares that
      # code with an unreachable database, and a client that treats them alike either waits
      # fifteen minutes on an outage or retries a pause every minute for hours.
      paused = self.class.paused_sentence(detail)
      if paused
        raise Errors::CollectionPaused.new("#{method} #{path} -> 503: #{paused}",
          retry_after: self.class.retry_after(response))
      end
      if response.status == 429
        raise Errors::RateLimited.new("#{method} #{path} -> 429: #{detail[0, 200]}",
          retry_after: self.class.retry_after(response))
      end

      raise Errors::CorpusError.new("#{method} #{path} -> #{response.status}: #{detail[0, 400]}",
        permanent: (400...500).cover?(response.status))
    rescue Http::Unreachable => e
      raise Errors::CorpusError, "#{method} #{path} could not be reached: #{e.message}"
    end

    # The service's own sentence from a refusal body, when the refusal is a pause.
    #
    # Read for two reasons. The sentence names the index, the reason the operator recorded
    # and the route that lifts the pause, which is what an operator reading the miner's log
    # needs; and `error.type` is the only thing that separates this 503 from the service
    # being unable to reach its own database, which is a retry-in-a-moment and must not be
    # waited out for fifteen minutes. Nil means "not a pause", and every other failure
    # keeps the handling it had.
    def self.paused_sentence(detail)
      payload = JSON.parse(detail.to_s)
      return nil unless payload.is_a?(Hash)

      error = payload["error"]
      return nil unless error.is_a?(Hash) && error["type"] == Errors::PAUSE_TYPE

      message = error["message"].to_s
      message.empty? ? nil : message
    rescue JSON::ParserError, TypeError
      nil
    end

    # How long the service asked for, or `Errors::RETRY_AFTER_FALLBACK` when it did not say
    # or said something that is not a number.
    def self.retry_after(response)
      raw = response.header("Retry-After").to_s
      [Float(raw), 1.0].max
    rescue ArgumentError, TypeError
      Errors::RETRY_AFTER_FALLBACK
    end

    # Create the operator this miner files under, and return its key.
    #
    # Never reused across runs by accident: the key is written to the state file by the
    # caller, so a run that files a thousand reports keeps one identity and the corpus can
    # see that they came from one source.
    def self.register(base_url, name:, email:, http: Http.new)
      response = http.call(
        method: "POST", url: base_url.sub(%r{/+\z}, "") + "/api/operators/register",
        body: JSON.generate({ "name" => name, "email" => email }),
        headers: { "Content-Type" => "application/json" }
      )
      detail = response.body.to_s
      unless response.ok?
        raise Errors::CorpusError,
          "could not register #{email}: #{response.status} #{detail[0, 200]}"
      end

      JSON.parse(detail)["api_key"]
    end

    # The miner's key, registering once and remembering it afterwards.
    #
    # Registration is rate limited to ten an hour from one address, so a run that
    # registered every time would fail after its tenth finding — and the failure would look
    # like the corpus refusing the work rather than the miner asking for a new identity it
    # did not need.
    def self.load_or_register(base_url, state, name:, email:, http: Http.new)
      state = Pathname.new(state)
      return JSON.parse(state.read)["api_key"] if state.exist?

      key = register(base_url, name: name, email: email, http: http)
      FileUtils.mkdir_p(state.dirname)
      state.write(JSON.pretty_generate({ "api_key" => key, "email" => email }))
      state.chmod(0o600)
      key
    end
  end
end
