# frozen_string_literal: true

require "open3"

require_relative "test_helper"

# The artifacts this repository ships, read as artifacts rather than as prose.
#
# The Dockerfile and the entrypoint are the deployment's contract with the image: the
# interpreter every recorded fact was established on, the compiler that makes a native gem
# installable, the health probe that distinguishes a working loop from a running process, and
# the flags the container hands the CLI. The service's own deployment contract
# (`test/contracts/miner/deploy_config_test.rb`) checks the compose file around these; this
# file is the half a standalone checkout can prove on its own.
class ArtifactTest < MinerTest
  ROOT = File.expand_path("..", __dir__)
  DOCKERFILE_PATH = File.join(ROOT, "Dockerfile")
  ENTRYPOINT_PATH = File.join(ROOT, "entrypoint.sh")
  BIN_PATH = File.join(ROOT, "bin", "agents-fyi-miner")

  def dockerfile
    @dockerfile ||= File.read(DOCKERFILE_PATH, encoding: "utf-8").gsub(/\\\n\s*/, " ")
  end

  # Every "must appear" assertion reads the instructions, not this file's comments: the
  # comments carry the measurements, and a substring check over them would pass on prose.
  def instructions
    @instructions ||= dockerfile.split("\n").reject { |line| line.lstrip.start_with?("#") }.join("\n")
  end

  def entrypoint
    @entrypoint ||= File.read(ENTRYPOINT_PATH, encoding: "utf-8")
  end

  def image_env(name)
    found = dockerfile.match(/(?<![A-Za-z0-9_])#{Regexp.escape(name)}=(\S+)/)
    refute_nil found, "the image does not declare #{name}"
    found[1]
  end

  def test_the_ruby_client_ships_the_interpreter_its_rules_were_written_against
    base = dockerfile.match(/^FROM\s+(ruby:[^\s@]+@sha256:[0-9a-f]{64})$/)
    refute_nil base, "the image's base is not a pinned official Ruby image"

    installed = instructions.match(/apt-get install -y --no-install-recommends ([^&|]+)/)
    refute_nil installed, "the image installs no runtime libraries for Ruby"
    %w[libyaml-0-2 libssl3].each do |library|
      assert_includes installed[1], library, "the image does not install #{library}"
    end
  end

  def test_the_probe_interpreter_is_the_one_every_unbuildable_record_was_stamped_with
    stage = dockerfile.match(/^FROM\s+(python:3\.12-slim@sha256:[0-9a-f]{64})\s+AS\s+python$/)
    refute_nil stage, "the Python stage does not come from a pinned 3.12 image"
    assert_includes dockerfile, "COPY --from=python /usr/local /usr/local"
    refute_match(/rm\s+-rf[^\n]*\/usr\/local\/lib\/python/, instructions,
      "the Python tree the probes need is removed from the image")
  end

  def test_the_image_runs_the_ruby_client_and_never_the_python_module
    assert_includes instructions, "COPY lib ./lib"
    assert_includes instructions, "COPY bin ./bin"
    assert_includes instructions, "COPY entrypoint.sh ./entrypoint.sh"
    assert_includes entrypoint, "exec ruby /app/bin/agents-fyi-miner serve"
    assert_includes entrypoint, "exec ruby /app/bin/agents-fyi-miner verify"
    refute_includes entrypoint, "python -m agents_fyi_miner"
  end

  def test_the_image_carries_the_compiler_a_native_gem_needs
    installed = instructions.match(/apt-get install -y --no-install-recommends ([^&|]+)/)
    refute_nil installed, "the image installs nothing at all"
    assert_includes installed[1], "build-essential",
      "a gem whose C extension has no published linux build can never be installed"
    assert_includes installed[1], "pkg-config", "a gem that links a library cannot find it"
  end

  def test_the_image_does_not_turn_the_pip_cache_off
    refute_nil image_env("PIP_CACHE_DIR")
    envs = dockerfile.split("\n").select { |line| line.strip.start_with?("ENV ") }
    refute(envs.any? { |line| line.include?("PIP_NO_CACHE_DIR") }, "the image sets it: #{envs}")
  end

  def test_the_healthcheck_is_valid_ruby_and_reads_the_loop_s_own_heartbeat
    healthcheck = instructions.split("\n").find { |line| line.start_with?("HEALTHCHECK") }
    refute_nil healthcheck, "the image has no healthcheck"
    script = healthcheck[/CMD ruby -e "(.*)"\s*\z/, 1]
    refute_nil script, "the healthcheck does not run a Ruby one-liner"

    assert_includes script, "/home/miner/.cache/agents-fyi-miner/heartbeat"
    _out, err, status = Open3.capture3("ruby", "-e", script)
    refute_includes err, "syntax error", "the healthcheck does not compile: #{err}"
    assert_equal 1, status.exitstatus, "a missing heartbeat must be an unhealthy result, not a pass"
  end

  def test_every_flag_the_entrypoint_passes_is_one_the_cli_accepts
    invocations = entrypoint.scan(/exec ruby \/app\/bin\/agents-fyi-miner (?:serve|verify).*?(?=\n|$)/m)
    refute_empty invocations, "the entrypoint does not start the CLI"
    flags = invocations.flat_map { |line| line.scan(/--[a-z][a-z-]*/) }.uniq

    out, err, status = Open3.capture3("ruby", "-Ilib", BIN_PATH, "--help", chdir: ROOT)
    assert_equal 0, status.exitstatus, err
    flags.each do |flag|
      assert_includes out, flag, "the entrypoint passes #{flag}, which the CLI does not accept"
    end
  end

  def test_the_command_and_the_entrypoint_are_executable
    assert File.executable?(BIN_PATH), "bin/agents-fyi-miner is not executable"
    assert File.executable?(ENTRYPOINT_PATH), "entrypoint.sh is not executable"
  end
end
