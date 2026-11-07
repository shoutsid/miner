# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "envs"
require_relative "resolver"
require_relative "rubyenvs"

module AgentsMiner
  # **The boot cell: does a release come up in a host, not merely load?**
  #
  # A gem can require cleanly and still refuse to boot: a Rails component that needs a framework
  # initializer, a Rack middleware that raises on the first request, a release that emits a
  # deprecation at boot and a warning that is the whole reason a caller is reading this. `load` is
  # `require`; this is `require` *and* a host that answers one request, which is the difference the
  # plan names between B2 and the load half of B1.
  #
  # **The host is a minimal Rack app, not a generated Rails application.** The plan offers both and
  # says to start with the lighter one; a Rails skeleton is minutes of `rails new` per release and
  # a second framework to keep in step, while a Rack host is a `config.ru` and one `rackup` call.
  # What it establishes is bounded and stated: the release boots under the interpreter in a Rack
  # stack, or it does not. It does not establish that a *Rails application* boots, and the cell's
  # evidence says so.
  #
  # **A deprecation at boot is a documented, observed signal.** The host runs with
  # `RUBYOPT=-w` so warnings are emitted, and the boot's own output is kept as the cell's evidence:
  # a deprecation naming a symbol or argument is what a reader acts on, and it is stored rather
  # than summarised.
  module Boot
    # A boot fetches and installs the release and the framework pin, then starts an interpreter.
    # Slower than a load and still bounded: a run that has not answered in five minutes is a
    # machine with no index, not a slow boot.
    BOOT_TIMEOUT = 300

    # The service's `evidence` is bounded. The boot's output is the evidence, and the *tail* is
    # kept because a boot failure prints its exception last — the opposite end from the resolver's
    # conflict, which is the first thing Bundler says.
    EVIDENCE_LIMIT = 2_000

    # The host. It requires the release, boots a minimal Rack app, and answers one request. A
    # release that raises on require, on boot or on the first request fails here, and the exit
    # status is the fact. `Rack::Lint` is deliberately absent: it would turn a release's own
    # behaviour into a linter's verdict.
    HOST = <<~'RUBY'
      require "rack"
      gem_name = ARGV[0]
      require gem_name.tr("-", "/")
      app = lambda { |_env| [200, { "content-type" => "text/plain" }, ["ok"]] }
      Rack::Builder.new { run app }.to_app
      puts "booted"
    RUBY

    class << self
      # One boot, or a result saying why it could not be asked.
      #
      # Returns `{outcome:, note:}` in the service's four-valued vocabulary: `clean` when the host
      # booted, `findings` when it raised or exited non-zero, and `unexaminable` when the
      # environment could not be built or the interpreter could not start at all.
      def cell(gem, version, home:, suffix: "")
        Dir.mktmpdir("boot-") do |dir|
          gemfile = File.join(dir, "Gemfile")
          File.write(gemfile, gemfile_for(gem, version))
          env = ENV.to_h.merge(
            "BUNDLE_GEMFILE" => gemfile,
            "BUNDLE_APP_CONFIG" => File.join(dir, ".bundle"),
            # Warnings on, so a deprecation at boot is emitted rather than swallowed.
            "RUBYOPT" => "-w"
          )
          install = Envs.run_captured(["bundle", "install", "--quiet"], timeout: BOOT_TIMEOUT,
            cwd: dir, env: env)
          unless install.status.zero?
            return { outcome: "unexaminable",
                     note: "`bundle install` exited #{install.status} for #{gem} #{version}: " \
                           "#{tail(install)}" }
          end

          host = File.join(dir, "boot_host.rb")
          File.write(host, HOST)
          run = Envs.run_captured(["bundle", "exec", "ruby", host, gem], timeout: BOOT_TIMEOUT,
            cwd: dir, env: env)
          output = [run.stdout, run.stderr].map(&:to_s).reject(&:empty?).join("\n").strip
          if run.status.zero?
            return { outcome: "clean",
                     note: "the release booted in a Rack host: exit 0.#{warnings(output)}" }
          end

          { outcome: "findings",
            note: "the release failed to boot: exit #{run.status}. #{tail(run)}" }
        end
      rescue Envs::TimedOut => e
        detail = if e.started?
          "the boot did not finish within #{BOOT_TIMEOUT}s"
        else
          "could not start `bundle`: this machine has no `bundle` on its PATH"
        end
        { outcome: "unexaminable", note: detail }
      rescue SystemCallError => e
        { outcome: "unexaminable", note: "could not boot #{gem} #{version}: #{e.class}: #{e.message}" }
      end

      # The minimal host project: the release, and the framework pin for a Rails component. A
      # source is required by Bundler and nothing else is declared.
      def gemfile_for(gem, version)
        lines = ["source \"https://rubygems.org\"", "", "gem \"#{gem}\", \"#{version}\""]
        if Resolver::RAILS_FAMILY.include?(gem.to_s) && gem.to_s != "rails"
          lines << "gem \"rails\", \"#{version}\""
        end
        lines << "gem \"rack\""
        lines.join("\n") + "\n"
      end

      private

      # The tail of a command's output, which is where a boot failure prints its exception.
      def tail(result, limit = EVIDENCE_LIMIT)
        text = [result.stdout, result.stderr].map(&:to_s).reject(&:empty?).join("\n").strip
        text.length <= limit ? text : "…#{text[-limit, limit]}"
      end

      # The deprecation lines a clean boot emitted, if any. A warning at boot is a documented,
      # observed signal and is worth naming in the note rather than leaving in the output.
      def warnings(output)
        lines = output.to_s.lines.map(&:strip).select { |line| line.match?(/deprecat|warning/i) }
        return "" if lines.empty?

        " Warnings: #{lines.first(3).join(' ')[0, 400]}"
      end
    end
  end
end
