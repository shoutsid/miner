# frozen_string_literal: true

require "json"
require "net/http"
require "rubygems"
require "tmpdir"
require "uri"

require_relative "envs"
require_relative "ledger"

module AgentsMiner
  # **A version that cannot resolve is a claim about an index, not about somebody's application.**
  #
  # The corpus has a class of report no probe in `Verifying` could ever confirm: a Rails move that
  # failed while *resolving*, before anything was installed or booted. The report names a release and
  # quotes Bundler refusing to put it beside the framework, and the claim is checkable without the
  # application that filed it — which is what makes it the missing Rails verifier rather than a
  # second walker.
  #
  # The two methods are the two the corpus already counts:
  #
  # * `as-reported` believes the report's account of *which* releases conflicted and executes it: a
  #   minimal Gemfile naming both, then `bundle lock`, and the resolver's own refusal is the vote.
  # * `searched` ignores the report's account of the *constraint* and reads it from the release's own
  #   gemspec at rubygems.org. That is the independent derivation — if the report's quoted `< 8.0`
  #   had drifted, the gemspec would still say what the release requires.
  #
  # Neither runs the application, installs a gem or needs the repository: a resolver conflict is a
  # fact about two versions, and a verifier that asked for the private application would have no
  # way to check the report at all. What it will not do is guess: a report whose conflict cannot be
  # read as two versions gets no vote.
  module Resolver
    # A resolver run fetches the whole framework's metadata. It is slower than a gem install of one
    # release and still bounded: a run that has not answered in three minutes is a machine with no
    # index, not a slow resolution.
    LOCK_TIMEOUT = 180

    # The service's `notes` field is bounded at 2,000 characters. The evidence travels in it, so the
    # head of the output is kept rather than the tail — the conflict is the first thing Bundler says.
    NOTES_LIMIT = 1800

    # The two releases a resolver claim is about. `requirement` is what the report quotes; the
    # searched role deliberately does not trust it and reads the release's own declaration instead.
    Target = Struct.new(:gem, :gem_version, :rails_version, :requirement, keyword_init: true)

    # `Because js_image_paths >= 0.2.0 depends on rails >= 4.0, < 8.0`
    #
    # The `>=` is Bundler's own wording, and the version after it is the release the report says is
    # installed. A report that names a range (`>= 0.2.0`) is about the newest release in it, which is
    # the version the resolver actually chose — `Gemfile depends on js_image_paths = 0.2.0` is read
    # by `GEM_PIN` when the report has one.
    BECAUSE = /Because\s+([A-Za-z0-9_.-]+)\s+(?:>=|=)\s*([A-Za-z0-9_.-]+)\s+depends on\s+rails\s+([^\r\n]+)/

    # `and Gemfile depends on rails = 8.0.5.1,`
    RAILS_PIN = /Gemfile depends on rails\s*=\s*([A-Za-z0-9_.-]+)/

    # `So, because Gemfile depends on js_image_paths = 0.2.0,`
    GEM_PIN = /because Gemfile depends on\s+([A-Za-z0-9_.-]+)\s*=\s*([A-Za-z0-9_.-]+)/i

    # The text that separates a resolution failure from every other way `bundle lock` can fail.
    CONFLICT = /Could not find compatible versions|cannot be used|depends on rails/

    class << self
      # The two releases a report's resolver output names, or nil when it is not that kind of report.
      #
      # Narrow on purpose. It requires the exact `Because … depends on rails …` sentence *and* a
      # Rails pin (in the output, or the report's own `version` when its library is Rails). A report
      # that merely mentions Bundler, or one whose conflict is between two gems that are not the
      # framework, is not this claim and gets no vote rather than a guessed one.
      def claim_for(report)
        return nil unless report.is_a?(Hash)
        return nil unless report["ecosystem"].to_s == "ruby"

        text = [report["problem"], report["trace"]].join("\n")
        because = BECAUSE.match(text)
        return nil if because.nil?

        gem, gem_version, requirement = because.captures
        gem = gem.to_s.strip
        return nil if gem.empty? || gem == "rails"

        gem_version = gem_version.to_s.delete_suffix(",")
        # The `because Gemfile depends on …` line names the exact installed release, which is more
        # precise than Bundler's `>=` and is what the minimal Gemfile must ask for. It is optional:
        # the `Because` line already names a version, and a report that omits the second line is
        # still a claim.
        pinned = GEM_PIN.match(text)
        if pinned && pinned[1].to_s == gem
          gem_version = pinned[2].to_s
        end

        rails_version = RAILS_PIN.match(text)&.captures&.first
        rails_version = report["version"].to_s.strip if rails_version.to_s.empty? &&
          report["library"].to_s.strip == "rails"
        return nil if rails_version.to_s.empty?

        return nil unless Gem::Version.correct?(gem_version)
        return nil unless Gem::Version.correct?(rails_version)

        Target.new(gem: gem, gem_version: gem_version,
          rails_version: rails_version, requirement: requirement.to_s.strip.delete_suffix(","))
      rescue ArgumentError
        nil
      end

      # One operator's check, in the shape `Verifying.check` dispatches to.
      #
      # `suffix` is accepted because every other check takes one; this one's only scratch is a
      # `Dir.mktmpdir`, which is unique per call already.
      def check(claim, role, suffix: "")
        target = Target.new(gem: claim.resolver_gem, gem_version: claim.resolver_version,
          rails_version: claim.version, requirement: claim.resolver_requirement)
        return resolve(target, suffix: suffix) if role == Verifying::AS_REPORTED
        return inspect_release(target, suffix: suffix) if role == Verifying::SEARCHED

        raise ArgumentError, "unknown verification role #{role.inspect}"
      end

      # Run the conflict the report quotes, against a Gemfile that contains nothing else.
      #
      # `bundle lock` rather than `bundle update`: the lock is the resolver alone, so the result says
      # whether these two releases can sit together rather than what the application's own Gemfile
      # would have done with them. The temp directory is thrown away, so no lockfile outlives the
      # check and no second run inherits the first one's resolution.
      def resolve(target, suffix: "")
        Dir.mktmpdir("resolver-") do |dir|
          gemfile = File.join(dir, "Gemfile")
          File.write(gemfile, gemfile_for(target))
          # The child gets this process's environment with the bundle scoped to the scratch
          # directory: a global `~/.bundle/config` naming a mirror or a path would make the
          # verifier's result a fact about this machine rather than about the releases.
          env = ENV.to_h.merge(
            "BUNDLE_GEMFILE" => gemfile,
            "BUNDLE_APP_CONFIG" => File.join(dir, ".bundle")
          )
          result = Envs.run_captured(["bundle", "lock"], timeout: LOCK_TIMEOUT, cwd: dir, env: env)
          output = [result.stdout, result.stderr].map(&:to_s).reject(&:empty?).join("\n").strip
          status = result.status
          if status.zero?
            return Verifying::Verdict.of(
              outcome: Ledger::DISSENTED,
              executed: "Wrote a Gemfile naming rails #{target.rails_version} and " \
                        "#{target.gem} #{target.gem_version}, then ran `bundle lock`: exit 0. " \
                        "The resolver found a solution, so the conflict the report describes is " \
                        "not there."
            )
          end
          if conflict?(output, target)
            return Verifying::Verdict.of(
              outcome: Ledger::REPRODUCED,
              executed: "Wrote a Gemfile naming rails #{target.rails_version} and " \
                        "#{target.gem} #{target.gem_version}, then ran `bundle lock`: exit #{status}. " \
                        "#{clip(output)}"
            )
          end

          Verifying::Verdict.of(
            outcome: Verifying::NO_CLAIM,
            detail: "`bundle lock` exited #{status} without the resolver conflict this report " \
                    "describes: #{clip(output, 400)}",
            unreachable: true
          )
        end
      rescue Envs::TimedOut => e
        detail = if e.started?
          "`bundle lock` did not finish within #{LOCK_TIMEOUT}s: " \
            "#{clip(e.stdout.to_s + e.stderr.to_s, 400)}"
        else
          # `started: false` is the other half: there was no `bundle` to run at all. Reporting that
          # as a timeout would send the operator looking at the index rather than at the image.
          "could not start `bundle lock`: this machine has no `bundle` on its PATH"
        end
        Verifying::Verdict.of(outcome: Verifying::NO_CLAIM, detail: detail, unreachable: true)
      rescue SystemCallError => e
        # `bundle` itself was not on this machine, which is a fact about the verifier and wants a
        # retry on an image that has it rather than a vote about the release.
        Verifying::Verdict.of(
          outcome: Verifying::NO_CLAIM,
          detail: "could not run `bundle lock`: #{e.class}: #{e.message}",
          unreachable: true
        )
      end

      # Read the release's own declaration and evaluate it, ignoring the report's quoted constraint.
      #
      # This is the independent half. The report says the gem's dependency is `< 8.0`; the release's
      # gemspec is where that claim actually lives, and a report whose prose has drifted still gets
      # the answer the index would give. It does not execute the resolver, so it confirms the
      # *incompatibility* rather than the exact sentence the application saw — which is what makes it
      # a second method rather than the first one run twice.
      def inspect_release(target, suffix: "")
        data, error = fetch(target, suffix: suffix)
        if error
          return Verifying::Verdict.of(
            outcome: Verifying::NO_CLAIM,
            detail: "could not read #{target.gem} #{target.gem_version} from rubygems.org: #{error}",
            unreachable: true
          )
        end

        dependencies = Array(data.dig("dependencies", "runtime"))
        rails = dependencies.find { |dependency| dependency["name"].to_s == "rails" }
        if rails.nil?
          return Verifying::Verdict.of(
            outcome: Ledger::DISSENTED,
            executed: "Read #{target.gem} #{target.gem_version} from rubygems.org: its gemspec " \
                      "declares no runtime dependency on rails, so it cannot be the gem that " \
                      "refused this Rails release."
          )
        end

        requirement = rails["requirements"].to_s
        parsed = Gem::Requirement.new(*requirement.split(",").map(&:strip))
        rails_version = Gem::Version.new(target.rails_version)
        if parsed.satisfied_by?(rails_version)
          Verifying::Verdict.of(
            outcome: Ledger::DISSENTED,
            executed: "Read #{target.gem} #{target.gem_version} from rubygems.org: its gemspec " \
                      "requires `rails #{requirement}`, which admits #{target.rails_version}. " \
                      "The release's own declaration does not refuse this Rails release."
          )
        else
          Verifying::Verdict.of(
            outcome: Ledger::REPRODUCED,
            executed: "Read #{target.gem} #{target.gem_version} from rubygems.org: its gemspec " \
                      "requires `rails #{requirement}`, which does not admit " \
                      "#{target.rails_version}. The release's own declaration is the conflict " \
                      "the report describes, independently of the report's quoted output."
          )
        end
      rescue ArgumentError => e
        Verifying::Verdict.of(
          outcome: Verifying::NO_CLAIM,
          detail: "#{target.gem} #{target.gem_version} declares a rails requirement this " \
                  "verifier cannot read (#{e.message})"
        )
      end

      # The minimal project: the framework at the release the report was moving to, and the one gem
      # the report says could not sit beside it. A source is required by Bundler, and nothing else
      # is declared — an application's other gems are not part of this claim.
      def gemfile_for(target)
        <<~GEMFILE
          source "https://rubygems.org"

          gem "rails", "#{target.rails_version}"
          gem "#{target.gem}", "#{target.gem_version}"
        GEMFILE
      end

      private

      # Whether the output is the conflict this claim is about, rather than any other failure. The
      # gem's name keeps a generic "resolution failed" from confirming a report about a different
      # package; the rails wording is Bundler's own and is what makes it this shape. Measured
      # against the report this module was written for: `bundle lock` exits 6 with `Could not find
      # compatible versions`, these two `Because … depends on rails …` lines, and `version solving
      # has failed` — but the status is not required, because the wording is the distinction and a
      # Bundler release that changes the code should not turn a real conflict into no vote.
      def conflict?(output, target)
        text = output.to_s
        text.include?(target.gem) && text.match?(CONFLICT)
      end

      # The release's metadata, one call. `injectable` through `with_stub` in the suite, so the
      # judgement below is tested without a network and the fetch itself is one small method.
      def fetch(target, suffix: "")
        _ = suffix
        uri = URI("https://rubygems.org/api/v2/rubygems/" \
                  "#{URI.encode_www_form_component(target.gem)}/versions/" \
                  "#{URI.encode_www_form_component(target.gem_version)}.json")
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
          open_timeout: 15, read_timeout: 15) do |http|
          http.get(uri.request_uri)
        end
        unless response.is_a?(Net::HTTPSuccess)
          return [nil, "rubygems.org answered #{response.code} for #{target.gem} #{target.gem_version}"]
        end

        [JSON.parse(response.body), nil]
      rescue StandardError => e
        [nil, "#{e.class}: #{e.message}"]
      end

      def clip(text, limit = NOTES_LIMIT)
        text.to_s.gsub(/\s+\z/, "")[0, limit].to_s
      end
    end
  end
end
