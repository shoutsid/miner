# frozen_string_literal: true

require "yaml"

require_relative "test_helper"

# The deployment the three clients describe, read out of the two files that decide it
# rather than out of prose.
#
# `miner`, `verifier` and `verifier-independent` are one image running three jobs, and
# all three install releases — the same releases, in fact, because the verifiers check
# the reports the miner filed. So all three need the same wheels, and must not have the
# same environments: a wheel is an artifact the index published a hash for and a copy of
# it is not a claim about anything, while an environment is what the wheel is unpacked
# into and *executed* in, which makes it evidence. A verifier that probed inside the
# miner's environment would be checking a claim with the material the claim came from.
#
# Both facts are invisible at runtime. A shared wheel cache is faster and a shared
# environment still works; only the evidence quietly stops being independent, and only
# after the change has shipped. That is why this is a test and not a comment.
#
# Every one of those records names the interpreter it was established on (`machine.rb`), so
# the pins here are what make that stamp mean what it says.
class DeployConfigTest < MinerTest
  # The repository root, which is three directories up: this file lives in
  # `components/miner/test/` and the two artifacts it reads — the compose file and the image — do
  # not.
  ROOT = File.expand_path("../../..", __dir__)
  COMPOSE_PATH = File.join(ROOT, "docker-compose.yml")
  DOCKERFILE_PATH = File.join(ROOT, "components", "miner", "Dockerfile")
  ENTRYPOINT_PATH = File.join(ROOT, "components", "miner", "entrypoint.sh")
  # The image that answers the internet. It was `service/Dockerfile` until the migration finished
  # and there was one application again, and it has since moved to the repository root: this is a
  # Rails application whose root *is* the repository, so its Dockerfile is the one at `ROOT`. The
  # assertion below reads it by path, so this is the line that would have kept passing against a
  # file nobody builds.
  APP_DOCKERFILE_PATH = File.join(ROOT, "Dockerfile")

  # The wheels are pip's, so where they are kept is pip's business and the image says
  # it. Read back from the image rather than repeated here: a test that hard-coded the
  # path would keep passing after the Dockerfile moved it, and the compose mounts would
  # be over a directory nothing ever looked in.
  CACHE_DIR_VAR = "PIP_CACHE_DIR"

  # What this host's volume device was measured draining, in MB/s. A per-container cap
  # is only meaningful as a fraction of it, which is the mistake this pins: the cap was
  # written out three times at 30 MB/s each, and three clients at 30 is 90 against a
  # disk that drains 34 — so the host's dirty pages never cleared, `vm.dirty_bytes` sat
  # at its cap, and every process that writes blocked in `balance_dirty_pages` until the
  # desktop stuttered.
  MEASURED_DISK_DRAIN_MBPS = 34

  def compose_text
    @compose_text ||= File.read(COMPOSE_PATH, encoding: "utf-8")
  end

  def compose
    @compose ||= YAML.safe_load(compose_text, aliases: true)
  end

  # The image's instructions, with the line continuations unfolded. An `ENV` spread
  # over several lines is one instruction, and a test that read the raw text would be
  # testing where the backslashes happened to fall.
  def dockerfile
    @dockerfile ||= File.read(DOCKERFILE_PATH, encoding: "utf-8").gsub(/\\\n\s*/, " ")
  end

  # The instructions with the comments removed, which is what every "must appear"
  # assertion reads. Necessary because this file's comments carry the evidence: the one
  # above the compiler quotes `make failedNo such file or directory - make` and explains
  # why it was left out and then put back, so a substring check reads prose as an
  # instruction.
  def instructions
    @instructions ||= dockerfile.split("\n").reject { |line| line.lstrip.start_with?("#") }.join("\n")
  end

  def entrypoint
    @entrypoint ||= File.read(ENTRYPOINT_PATH, encoding: "utf-8")
  end

  def app_dockerfile
    @app_dockerfile ||= File.read(APP_DOCKERFILE_PATH, encoding: "utf-8")
  end

  # Every service that runs the miner image, which is every installer here.
  def clients
    compose["services"].filter_map do |name, service|
      [name, service] if (service["build"] || {})["context"] == "./components/miner"
    end.to_h
  end

  # (source, container path) for each named-volume mount, ignoring bind mounts.
  def mounts(service)
    Array(service["volumes"]).filter_map do |mount|
      source, _, target = mount.to_s.partition(":")
      next if source.include?("/") # a path on this disk, not a volume the compose file declares

      [source, target.split(":").first]
    end
  end

  # The one mount matching `needle`, by volume name or by container path.
  def mount_matching(service, needle, where: :source)
    field = where == :source ? 0 : 1
    found = mounts(service).select { |mount| mount[field].to_s.include?(needle) }
    assert_equal 1, found.length, "expected exactly one #{needle.inspect} mount, found #{found.inspect}"
    found.first
  end

  # A variable the image declares, wherever it sits in an instruction.
  #
  # Not anchored to the start of a line: `dockerfile` has already unfolded the
  # continuations, so an `ENV` written over four lines is *one* line and only its first
  # variable is at the beginning — `PIP_CACHE_DIR` is the fourth, and a `^`-anchored
  # pattern reported that this image does not declare it while the four assertions that
  # read it failed on a file whose line it is plainly on. The lookbehind keeps `X_NAME=`
  # from answering for `NAME=`, which is the reading a word boundary alone would allow.
  def image_env(name)
    found = dockerfile.match(/(?<![A-Za-z0-9_])#{Regexp.escape(name)}=(\S+)/)
    refute_nil found, "the image does not declare #{name}"
    found[1]
  end

  def cache_dir = image_env(CACHE_DIR_VAR)

  # One client's cap, in bytes or operations per second. Compose writes these as
  # `${VAR:-default}`, because an operator has to be able to raise them; so the number
  # under test is the *default*, read back rather than repeated here. A test that
  # hard-coded it would keep passing after the default changed, which is the direction
  # that matters.
  def per_client_rate(service, key)
    entries = service["blkio_config"][key]
    assert_equal 1, entries.length, "expected one device for #{key}, got #{entries.inspect}"
    raw = entries[0]["rate"].to_s
    found = raw.match(/\A\$\{[A-Z_]+:-(\d+)(mb)?\}\z/)
    refute_nil found, "could not read a default out of #{raw.inspect}"
    found[1].to_i * (found[2] ? 1024**2 : 1)
  end

  # --- the interpreters -------------------------------------------------------------

  def test_the_ruby_client_ships_the_interpreter_its_rules_were_written_against
    # The Ruby half of this image is verified, not assumed. Every message the client
    # reads was captured in Ruby 3.3.12 / RubyGems 3.5.22 — the refusal text
    # (`undefined method `x' for`) and the native-build failure (`make failedNo such file
    # or directory - make`) both differ between versions — and Debian's own `ruby`
    # package is 3.1.2 with RubyGems 3.3.15. So the interpreter comes from the official
    # image, pinned by digest, and it is the *base* rather than a stage copied in: the
    # client is Ruby now, so the runtime it runs on is the image's own.
    base = dockerfile.match(/^FROM\s+(ruby:[^\s@]+@sha256:[0-9a-f]{64})$/)
    refute_nil base, "the image's base is not a pinned official Ruby image"

    # The runtime libraries its extensions need, named rather than left to the base
    # image's dependency tree: `libyaml-0-2` is psych, which reads every gemspec, and
    # `libssl3` is the HTTPS `gem install` fetches over. A missing one of those is a
    # `gem` that cannot run at all, and it fails as a bad gem rather than as a missing
    # library.
    installed = instructions.match(/apt-get install -y --no-install-recommends ([^&|]+)/)
    refute_nil installed, "the image installs no runtime libraries for Ruby"
    %w[libyaml-0-2 libssl3].each do |library|
      assert_includes installed[1], library, "the image does not install #{library}"
    end
  end

  def test_the_probe_interpreter_is_the_one_every_unbuildable_record_was_stamped_with
    # Debian's own `python3` is 3.11; every "cannot be built here" fact this miner has
    # recorded names **cp312**, and those records are what stop a release being attempted a
    # hundred times — so the interpreter comes from the official 3.12 image, copied in whole
    # (`/usr/local` holds the interpreter, pip, the `venv` module and the standard library),
    # exactly as this file used to carry Ruby into a Python base.
    stage = dockerfile.match(/^FROM\s+(python:3\.12-slim@sha256:[0-9a-f]{64})\s+AS\s+python$/)
    refute_nil stage, "the Python stage does not come from a pinned 3.12 image"
    assert_includes dockerfile, "COPY --from=python /usr/local /usr/local"

    # And the tree is not thrown away afterwards: pip installs the releases this client
    # inspects, and the venv module is what the environments are built with.
    refute_match(/rm\s+-rf[^\n]*\/usr\/local\/lib\/python/, instructions,
      "the Python tree the client needs is removed from the image")
  end

  def test_the_image_runs_the_ruby_client_and_never_the_python_module
    # The command the container starts, read from both files that decide it.
    assert_includes instructions, "COPY lib ./lib"
    assert_includes instructions, "COPY bin ./bin"
    assert_includes instructions, "COPY entrypoint.sh ./entrypoint.sh"

    assert_includes entrypoint, "exec ruby /app/bin/agents-fyi-miner serve"
    assert_includes entrypoint, "exec ruby /app/bin/agents-fyi-miner verify"
    refute_includes entrypoint, "python -m agents_fyi_miner",
      "the entrypoint still starts the Python client"
    refute_includes instructions, "COPY agents_fyi_miner ./agents_fyi_miner"
  end

  def test_the_healthcheck_asks_about_the_file_the_loop_writes_with_the_interpreter_in_the_image
    # Liveness is the age of a file the loop touches once a cycle, not a process check:
    # a miner whose corpus went away looks exactly like one that is thinking, for hours.
    # The probe uses the interpreter already in the image — Ruby — so nothing is added
    # to the image just to ask whether a file is old, and the path is the one the client
    # writes rather than a second copy of it.
    healthcheck = instructions.split("\n").find { |line| line.start_with?("HEALTHCHECK") }
    refute_nil healthcheck, "the image has no healthcheck"
    healthcheck = healthcheck.split("CMD ").last
    assert_includes healthcheck, "ruby", "the healthcheck does not use the interpreter in the image"
    refute_includes healthcheck, "python", "the healthcheck probes a file with an interpreter"
    assert_includes healthcheck, "/home/miner/.cache/agents-fyi-miner/heartbeat"

    # The verifiers touch their own heartbeat, so each of them overrides this test —
    # and a service whose healthcheck reads somebody else's file is reported unhealthy
    # for doing its job.
    %w[verifier verifier-independent].each do |name|
      block = compose["services"][name]["healthcheck"]["test"]
      assert(block.any? { |part| part == "ruby" }, "#{name} probes its health with something else")
      assert(block.any? { |part| part.to_s.include?("agents-fyi-#{name}") },
        "#{name}'s healthcheck reads a file another service writes")
    end
  end

  def test_the_image_carries_the_compiler_a_native_gem_needs
    # The image had no compiler, and the reason it now does is a measurement. The rule
    # was that "a gem that needs a native extension is a fact about the release". Asked
    # of the index instead of reasoned about: `prism`, `bigdecimal`, `json`, `psych`,
    # `date`, `nio4r`, `msgpack` and `racc` publish no linux build at all — only `ruby`
    # and `java` — so with no compiler they can never be installed, and the record said
    # so about the *release* while naming the wrong interpreter. Measured on the live
    # ledger before this changed: **862 of the Ruby ledger's 1,844 pairs, across 659
    # gems**, settled unbuildable — `rails`, `actionpack`, `activerecord`,
    # `activesupport`, `nokogiri`, `rubocop`, `puma`, `aws-sdk-core`. And the cost of
    # the fix: `racc 1.8.1` builds in 1 second, `rubyXL 3.3.33` then installs in 2
    # because nokogiri arrives precompiled.
    installed = instructions.match(/apt-get install -y --no-install-recommends ([^&|]+)/)
    refute_nil installed, "the image installs nothing at all"
    assert_includes installed[1], "build-essential",
      "a gem whose C extension has no published linux build can never be installed"
    # `pkg-config` comes with it because a gem that links a library asks for it by name —
    # `pg` and `sqlite3` both fail with a message about it being missing.
    assert_includes installed[1], "pkg-config", "a gem that links a library cannot find it"
  end

  # --- caches and environments ------------------------------------------------------

  def test_the_image_does_not_turn_pips_download_cache_off
    # `PIP_NO_CACHE_DIR` is what the image used to set, and an image `ENV` applies to the
    # runtime as well as the build — so every `pip install` in every environment was a
    # fresh request for a wheel the same service already had. Measured before the change:
    # 74% of the wheel installations in one service's cache were wheels already present
    # in another of its environments, and `typing_extensions 4.16.0` alone had been
    # fetched 43 times. Read from the instructions rather than from the text: the comment
    # above the `ENV` names the variable, and a substring check would pass on prose that
    # is describing the change it is there to explain.
    refute_nil image_env(CACHE_DIR_VAR)

    envs = dockerfile.split("\n").select { |line| line.strip.start_with?("ENV ") }
    refute(envs.any? { |line| line.include?("PIP_NO_CACHE_DIR") }, "the image sets it: #{envs}")

    compose["services"].each do |name, service|
      declared = service["environment"] || {}
      refute_includes declared, "PIP_NO_CACHE_DIR", "#{name} turns pip's cache off"
    end
  end

  def test_the_image_owns_the_directory_the_wheel_cache_is_mounted_over
    # The trap this image already documents for its other volumes: a named volume mounted
    # where the image has no directory is created owned by root, and this account cannot
    # write to it. The cache would then be disabled — pip warns and installs anyway, into
    # a container nobody reads — and every install would go back to the network with
    # nothing to show for it.
    created = instructions.match(/mkdir -p (.*?)&&/m)
    refute_nil created, "the image does not create its cache directories"
    assert_includes created[1], cache_dir
  end

  def test_every_client_mounts_the_same_wheel_cache
    # All three fetch the same wheels, so all three read and write one cache, the point
    # being that between them each distinct wheel is fetched once. A service missing this
    # mount is a service downloading what its neighbour already has.
    refute_empty clients, "no service runs the miner image; this test would pass vacuously"

    seen = clients.to_h { |name, service| [name, mount_matching(service, "pip")[1]] }
    assert_equal 1, seen.values.uniq.length, "the clients disagree about where the cache is: #{seen}"
    assert_equal [cache_dir], seen.values.uniq,
      "compose mounts #{seen} but the image writes to #{cache_dir}"
  end

  def test_no_two_clients_share_an_environment_directory
    # Deliberate, and the reason is not disk. The miner executes arbitrary third-party
    # code inside the environment it installs, so an environment is a thing that has been
    # run in — evidence. A verifier whose probe ran in the miner's environment would be
    # checking a claim with the material the claim was derived from, which is the one
    # thing the second and third operators exist not to do. Disk is not the constraint
    # here: this host reports 1.6 TB free.
    homes = clients.transform_values { |service| mount_matching(service, "agents-fyi-", where: :target) }
    assert_equal homes.keys.length, homes.values.uniq.length,
      "two clients share a home, and so share their environments: #{homes}"
  end

  def test_every_named_volume_a_client_mounts_is_declared
    # Compose refuses an undeclared volume, and it refuses it at the deployment rather
    # than here: the failure is a `docker compose up` that will not start a service which
    # looked configured.
    declared = (compose["volumes"] || {}).keys
    used = compose["services"].values.flat_map { |service| mounts(service).map(&:first) }.uniq
    assert_empty(used - declared, "mounted but not declared: #{(used - declared).sort.inspect}")
  end

  def test_the_miner_runs_with_a_read_only_root_and_a_bounded_tmpfs
    # `/tmp` is a tmpfs — RAM — and pip unpacks every wheel and every sdist build into
    # `TMPDIR`: measured on this deployment, 4.1 GB within thirty-five minutes, 769
    # `pip-unpack-*` directories, the container pinned against its own `mem_limit`. The
    # symptom was not a memory error: pip began failing with an *empty* message and then
    # died mid-cycle without running its SIGTERM handler. The scratch goes to the volume
    # (`Envs.use_scratch_dir`), and this bound is for whatever ignores it.
    block = compose["services"]["miner"]
    assert_equal true, block["read_only"], "the miner's root filesystem is writable"
    tmpfs = Array(block["tmpfs"]).join(" ")
    assert_match(%r{/tmp:size=\d+[mg]}, tmpfs, "the tmpfs is unbounded")
    refute_nil block["mem_limit"], "the container has no memory bound at all"
    assert_includes Array(block["security_opt"]), "no-new-privileges:true"
  end

  # --- the budgets ------------------------------------------------------------------

  def test_the_clients_share_one_cpu_budget_rather_than_a_number_each
    # These are background jobs on somebody's desktop, and each runs one install at a
    # time — one compiler, since the image gained one — so a core each is all they can use
    # and all they may have. Written out separately, the miner's was 2.0 and each
    # verifier's 1.0, which is four cores of an argument about how much of a desktop may
    # be spent. The upgrader is the fourth client and joined this test rather than being
    # written around: it shares the budget and its compose block says so.
    names = %w[miner verifier verifier-independent upgrader]
    budgets = names.to_h { |name| [name, compose["services"][name]["cpus"]] }
    assert_equal 1, budgets.values.uniq.length, budgets.inspect
    refute_nil budgets["miner"], "the miner has no CPU cap at all"

    assert_equal 1, compose_text.scan("&client-cpus").length, "the budget is defined more than once"
    assert_equal names.length, compose_text.scan("*client-cpus").length,
      "a client is missing the shared budget"
  end

  def test_the_deployment_collects_one_index_and_says_so_where_it_is_read
    # Python collection stops, and there are three client-side places that would each quietly
    # keep it going: the miner's own scope, the timer that refreshes one index's queue, and
    # the file an operator copies. The service's own refusal is what makes the pause true — a
    # paused index's writes are rejected with `error.type=collection_paused` — so these are
    # the halves that have to agree with it, and a deployment that disagrees with itself here
    # starts a miner building environments for filings that will all be refused.
    assert_equal "${MINER_ECOSYSTEMS:-ruby}", compose["services"]["miner"]["environment"]["MINER_ECOSYSTEMS"]

    # The verifiers deliberately do not set it, and pinning the omission is the point: a
    # verifier's work list is its own ledger of report ids, so the index comes from each
    # report as it is read and a flag here would be read by nothing. What stops it working
    # a paused index is the service refusing its vote.
    %w[verifier verifier-independent].each do |name|
      declared = compose["services"][name]["environment"] || {}
      refute_includes declared, "MINER_ECOSYSTEMS", "#{name} scopes itself by an index"
    end

    # `Type=oneshot` skips whatever follows a failing command, so asking the route about a
    # paused index would take the gem refresh down with it — every run, with an error line
    # that reads like an outage rather than like a decision somebody made.
    timer = File.read(File.join(ROOT, "deploy", "agents-fyi-mining-refresh.service"), encoding: "utf-8")
    assert_includes timer, "ecosystem=ruby"
    refute_includes timer, "ecosystem=python"

    example = File.read(File.join(ROOT, ".env.example"), encoding: "utf-8")
    assert_includes example, "\nMINER_ECOSYSTEMS=ruby\n"
  end

  def test_the_clients_share_one_disk_budget_rather_than_a_copy_each
    # Defined once and aliased by all three, because only the sum is meaningful. Three
    # copies of a per-client number is precisely how the aggregate reached 90 MB/s
    # without any line in the file looking wrong, so the number of definitions is the
    # thing held here, not just the values.
    assert_equal 1, compose_text.scan("device_write_bps:").length,
      "the disk budget is written per client again; the number that matters is the sum"
    assert_equal 3, clients.length, "expected the three clients, got #{clients.keys.sort.inspect}"
    budgets = clients.values.map { |service| service["blkio_config"] }
    assert_equal 1, budgets.uniq.length, "the clients no longer share one budget: #{budgets.inspect}"
  end

  def test_the_three_clients_together_stay_well_under_what_the_disk_drains
    # The aggregate is the number the disk sees, and it is not three times a safe one.
    # Held against the drain rate for *writes* only, because writes are the ones with a
    # mechanism: dirty pages over `vm.dirty_bytes` are what stalled every writer. A read
    # cannot accumulate in the dirty buffer, and the figure here was measured from the
    # miner's write throughput, so holding reads to it would be inventing a limit rather
    # than applying one.
    write = clients.values.sum { |service| per_client_rate(service, "device_write_bps") }
    ceiling = (MEASURED_DISK_DRAIN_MBPS * 1024**2) / 2
    assert_operator write, :<=, ceiling,
      "the three clients may write #{write / 1024**2} MB/s against a disk measured " \
      "draining #{MEASURED_DISK_DRAIN_MBPS} MB/s; the aggregate has to stay under half"
    clients.each do |name, service|
      assert_operator per_client_rate(service, "device_read_bps"), :>, 0, "#{name} bounds no reads"
    end
  end

  def test_the_clients_bound_operations_and_not_only_bytes
    # `riops`/`wiops` are the ones that default to `max`, and on this workload the
    # operations bind first: ~36 kB a write, because venv and pip create thousands of
    # small files, and a DRAM-less NVMe saturates on IOPS long before it saturates on
    # throughput.
    clients.each do |name, service|
      written = per_client_rate(service, "device_write_iops")
      read = per_client_rate(service, "device_read_iops")
      assert_operator written, :>, 0, "#{name} bounds no operations"
      assert_operator read, :>, 0, "#{name} bounds no operations"
      assert_operator written * 3, :<=, 950 / 2,
        "#{name} may write #{written} IOPS, and three of those saturate a drive " \
        "measured saturating near 950"
    end
  end

  def test_the_application_image_is_the_one_that_can_do_without_pip
    # A Dockerfile copied from one to the other is how the client's job would be "tidied
    # away".
    assert_includes instructions, "PIP_CACHE_DIR="
    refute_match(/PIP_CACHE_DIR|pip install|python:/, app_dockerfile,
      "the application image carries a Python runtime it does not use")
  end
end
