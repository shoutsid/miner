# frozen_string_literal: true

require_relative "test_helper"

# Gem environments, and reading Ruby's own answers.
#
# The subprocess work is deliberately not tested end to end here — it needs the network and a Ruby
# image, and `scripts/ruby-client-probe.py` (being rewritten in Ruby with the rest of the client's
# scripts) is what drives it against the real thing. What is tested is every judgement made about
# a run's output, which is where a fabricated finding would come from: the strings below are copied
# from real runs of Ruby 3.3.12 / RubyGems 3.5.22 in a `ruby:3.3-slim` container, not imagined.
#
# `with_stub` restores what it replaced, which is what `monkeypatch` did.
class RubyEnvsTest < MinerTest
  R = AgentsFyiMiner::RubyEnvs

  def env(package: "rake", version: "13.1.0", require_path: "rake", root: nil)
    R::Env.of(package: package, version: version, root: root || @home, require_path: require_path)
  end

  # Replace a module method for the length of a block, the way `monkeypatch.setattr` did — with
  # the original put back afterwards, because these are process-global and a test that left one
  # behind would decide the next test's answer.
  def with_stub(mod, name, body)
    original = mod.singleton_class.instance_method(name)
    # `instance_exec` rather than `define_singleton_method(name, &body)`: a block handed to
    # `define_method` runs with `self` bound to the *receiver*, so a stub that calls `assert` or
    # `result` — both helpers on this test — would be calling them on the module and fail with
    # `undefined method 'assert' for module AgentsFyiMiner::RubyEnvs`. Running the block against
    # the test keeps those helpers reachable while the arguments still arrive as the call's.
    test = self
    mod.define_singleton_method(name) { |*args, **kwargs, &blk| test.instance_exec(*args, **kwargs, &body) }
    yield
  ensure
    mod.singleton_class.send(:define_method, name, original)
  end

  # What a child process said, in the shape `RubyEnvs.capture` returns.
  def result(status: 0, output: "", timed_out: false)
    R::Result.new(status: status, output: output, timed_out: timed_out)
  end

  def test_an_entry_builds_the_reference_its_kind_calls_for
    constant = R::Entry.of(name: "Colorize::ClassMethods", kind: "constant",
      owner: "Colorize::ClassMethods")
    singleton = R::Entry.of(name: "Rake::Task.define", kind: "singleton",
      owner: "Rake::Task", method_name: "define")
    instance = R::Entry.of(name: "String#magenta", kind: "instance",
      owner: "String", method_name: "magenta")

    assert_equal "Colorize::ClassMethods", constant.expression
    assert_equal "Rake::Task.define", singleton.expression
    # An instance method is reached through `allocate`, so the probe does not need to know how to
    # construct the object under test.
    assert_equal "String.allocate.magenta", instance.expression
  end

  def test_a_name_that_cannot_be_a_reference_is_not_interpolated_into_one
    # These expressions are `eval`ed inside the probe, and the names come from a gem. Anything
    # that is not an identifier shape is refused on this side as well as in the script that
    # produced it.
    assert_nil R::Entry.of(name: "x", kind: "singleton", owner: "Foo; system('rm -rf /')",
      method_name: "bar").expression
    assert_nil R::Entry.of(name: "x", kind: "singleton", owner: "Foo", method_name: "Bar").expression
    assert_equal "Foo.bar?", R::Entry.of(name: "x", kind: "singleton", owner: "Foo",
      method_name: "bar?").expression
    assert_nil R::Entry.of(name: "x", kind: "constant", owner: "foo").expression
  end

  def test_installed_wants_the_specification_and_not_the_directory
    # A native build that failed leaves the payload in `gems/` and nothing in `specifications/` —
    # an environment that looks installed, cannot be required, and would make every probe report
    # the gem as gone. Measured: `make failed No such file or directory - make`, exit 1, with the
    # gem directory left behind.
    root = dir("bcrypt-3.1.20")
    (root + "gems" + "bcrypt-3.1.20").mkpath
    (root + "specifications").mkpath

    refute R.installed?(root, "bcrypt", "3.1.20")

    (root + "specifications" + "bcrypt-3.1.20.gemspec").write("")
    assert R.installed?(root, "bcrypt", "3.1.20")

    # A platform build is the release as this machine installs it.
    (root + "specifications" + "nokogiri-1.16.0-x86_64-linux.gemspec").write("")
    assert R.installed?(root, "nokogiri", "1.16.0")
    refute R.installed?(root, "nokogiri", "1.16.0.1")
  end

  def test_the_messages_a_build_that_cannot_succeed_prints
    # Copied from a real `gem install` run: the native-extension failure has no space in
    # `make failedNo such file or directory - make`, which is why the marker is `make failed`
    # rather than the sentence.
    native = "Building native extensions. This could take a while...\n" \
             "ERROR:  Error installing bcrypt:\n" \
             "\tERROR: Failed to build gem native extension.\n" \
             "make failedNo such file or directory - make\n"
    missing = "ERROR:  Could not find a valid gem 'no-such-gem' (>= 0) in any repository\n"
    network = "ERROR:  While executing gem ... (Gem::RemoteFetcher::FetchError)\n"

    assert R.cannot_be_built?(native)
    assert R.cannot_be_built?(missing)
    # A fetch error is the network having a moment, not a fact about the release.
    refute R.cannot_be_built?(network)
  end

  def test_a_name_that_went_away_is_read_from_ruby_s_own_message
    gone_33 = "-e:1:in `<main>': undefined method `no_such_method' for module JSON (NoMethodError)\n"
    gone_34 = "-e:1:in '<main>': undefined method 'no_such_method' for module JSON (NoMethodError)\n"
    constant = "-e:1:in `<main>': uninitialized constant Colorize::NoSuchThing (NameError)\n"
    other = "-e:1:in `<main>': wrong number of arguments (given 1, expected 0) (ArgumentError)\n"

    # Ruby 3.3 prints backticks and 3.4 prints quotes: both name the method.
    assert R.refused_symbol?(gone_33, "JSON.no_such_method")
    assert R.refused_symbol?(gone_34, "JSON.no_such_method")
    assert R.refused_symbol?(constant, "Colorize::NoSuchThing")
    # A failure for another reason is not a removal.
    refute R.refused_symbol?(other, "String#green")
    # And a different name in the same message is not this name.
    refute R.refused_symbol?(gone_33, "JSON.other_method")
  end

  def test_a_keyword_that_went_away_is_read_from_the_keyword_not_the_phrase
    # Ruby says `unknown keyword: :x` for a method and `unknown keywords: :x, :y` for a `Struct`
    # or `Data`, so the phrase alone would call every multi-keyword refusal a refusal of any
    # single one of them.
    plain = "-e:1:in `<main>': unknown keyword: :timeout (ArgumentError)\n"
    plural = "-e:1:in `<main>': unknown keywords: :alpha, :beta (ArgumentError)\n"
    arity = "-e:1:in `<main>': wrong number of arguments (given 1, expected 0) (ArgumentError)\n"

    assert R.refused_parameter?(plain, "timeout")
    assert R.refused_parameter?(plural, "beta")
    refute R.refused_parameter?(plural, "gamma")
    refute R.refused_parameter?(arity, "timeout")
  end

  def test_a_probe_that_could_not_be_made_is_not_an_answer
    # Two texts, and they are a documented distinction rather than one bucket: a dependency that
    # is missing means the environment is unusable, while a `LoadError` for a path means the gem
    # loaded and the file is not in it. Both are "the release never answered", which is the third
    # answer a probe can give.
    missing_dep = "Could not find 'multipart-post' (>= 1.2, < 3) among 71 total gem(s) " \
                  "(Gem::MissingSpecError)\n"
    load_error = "-e:1:in `require': cannot load such file -- mygem (LoadError)\n"
    answered = "-e:1:in `<main>': undefined method `x' for nil (NoMethodError)\n"

    assert R.unreached?(missing_dep)
    assert R.unreached?(load_error)
    assert R.unreached?("TIMEOUT")
    refute R.unreached?(answered)
    assert R.answers?(answered)
    assert R.resolves?("")
    refute R.resolves?(answered)
  end

  def test_each_script_is_given_the_arguments_it_reads
    # The scripts take the gem name as well as the require path, and getting that wrong is
    # silent: the real run answered `cannot load such file -- 4000`, because the require path had
    # picked up the limit. Every argument list is pinned here so the mistake cannot come back as a
    # runtime surprise.
    seen = []
    with_stub(R, :run_probe, lambda { |environment, source, argv, suffix: "", timeout: 60|
      seen << [source, argv]
      source == R::INVENTORY_SOURCE ? '{"t":"header","loaded":true,"native":false,"entries":0}' : ""
    }) do
      environment = env(package: "colorize", version: "0.8.1", require_path: "colorize/extra")

      R.inventory(environment, limit: 250)
      R.probe(environment, "String.allocate.magenta")
      R.probe_keyword(environment, "String.allocate.magenta", "mode")
      R.moved(environment, "instance", "magenta")
    end

    assert_equal [
      # gem name, require path, limit
      [R::INVENTORY_SOURCE, %w[colorize colorize/extra 250]],
      # require path, expression
      [R::PROBE_SOURCE, ["colorize/extra", "String.allocate.magenta"]],
      # require path, expression, keyword
      [R::PROBE_SOURCE, ["colorize/extra", "String.allocate.magenta", "mode"]],
      # gem name, require path, kind, leaf
      [R::MOVED_SOURCE, %w[colorize colorize/extra instance magenta]]
    ], seen
  end

  def test_a_build_that_succeeded_registers_the_release_and_one_that_failed_leaves_nothing
    calls = []
    installer = lambda { |argv, timeout:, env: nil, cwd: nil|
      calls << argv
      root = Pathname.new(argv[argv.index("--install-dir") + 1])
      # Where a real `gem install --install-dir` puts the specification, which is what makes the
      # release installed at all.
      (root + "specifications").mkpath
      (root + "specifications" + "rake-13.1.0.gemspec").write("")
      assert root.to_s.end_with?("rake-13.1.0")
      result(status: 0, output: "1 gem installed\n")
    }

    with_stub(R, :capture, installer) do
      environment = R.build("rake", "13.1.0", home: @home)
      assert_equal "rake", environment.require_path
      assert R.installed?(environment.root, "rake", "13.1.0")

      # Building it again reuses what is there rather than installing twice.
      R.build("rake", "13.1.0", home: @home)
    end
    assert_equal 1, calls.length
  end

  def test_a_build_that_failed_removes_the_directory_it_was_building_into
    # `gem install` leaves a half-installed tree behind on a native failure, and handing that out
    # later reports the gem as missing for ever.
    failing = lambda { |argv, timeout:, env: nil, cwd: nil|
      # The half-installed tree a native failure leaves: the payload is in `gems/` and
      # `specifications/` stays empty.
      root = Pathname.new(argv[argv.index("--install-dir") + 1])
      (root + "gems" + "bcrypt-3.1.20").mkpath
      result(status: 1, output: "ERROR:  Failed to build gem native extension.\nmake failed\n")
    }

    with_stub(R, :capture, failing) do
      error = assert_raises(AgentsFyiMiner::Errors::MinerError) do
        R.build("bcrypt", "3.1.20", home: @home)
      end
      assert error.permanent?, "a native build this machine cannot do is a fact about the release"
    end

    refute (@home + "rubyenvs" + "bcrypt-3.1.20").exist?,
      "a build that failed must not leave a directory to be handed out"
  end

  def test_the_inventory_reads_the_lines_the_script_prints
    # The script's own output, copied from a real run against `colorize` 0.8.1.
    output = [
      '{"t":"header","loaded":true,"native":false,"dir":"/opt/g1/api/gems/colorize-0.8.1","entries":3}',
      '{"t":"instance","name":"String#magenta","owner":"String","method":"magenta","params":[]}',
      '{"t":"constant","name":"Colorize::ClassMethods","owner":"Colorize::ClassMethods"}',
      '{"t":"singleton","name":"Colorize.new","owner":"Colorize","method":"new","params":["mode"]}'
    ].join("\n")

    with_stub(R, :run_probe, ->(*_args, **_kwargs) { output }) do
      read = R.inventory(env(package: "colorize", version: "0.8.1", require_path: "colorize"))

      assert read.loaded?
      refute read.native?
      assert_equal ["String#magenta", "Colorize::ClassMethods", "Colorize.new"],
        read.entries.map(&:name)
      assert_equal ["mode"], read.by_name["Colorize.new"].keywords
    end
  end

  def test_a_gem_that_cannot_be_required_is_not_a_gem_that_defines_nothing
    header = '{"t":"header","loaded":false,"error":"LoadError: cannot load such file -- mygem"}'

    with_stub(R, :run_probe, ->(*_args, **_kwargs) { header }) do
      read = R.inventory(env(package: "mygem", version: "1.0.0", require_path: "mygem"))

      refute read.loaded?
      assert_includes read.error, "LoadError"
    end
  end

  def test_an_inventory_with_no_header_at_all_says_so
    # No header means the script never reached its first print: a missing interpreter, or a
    # timeout. The output is kept rather than reported as an empty surface.
    with_stub(R, :run_probe, ->(*_args, **_kwargs) { "ruby: command not found\n" }) do
      read = R.inventory(env)

      refute read.loaded?
      assert_includes read.error, "command not found"
    end
  end

  def test_a_move_search_returns_only_references
    # What comes back is going to be filed as a location a caller can use, so a frame or a warning
    # in the output must not be read as one.
    output = "Foo::Parsers::Text\nwarning: already initialized constant X\nFoo::Parsers#parse\n"

    with_stub(R, :run_probe, ->(*_args, **_kwargs) { output }) do
      environment = env(package: "foo", version: "2.0.0", require_path: "foo")

      assert_equal ["Foo::Parsers::Text", "Foo::Parsers#parse"],
        R.moved(environment, "instance", "parse")
    end
  end

  def test_a_move_search_that_could_not_run_answers_nothing
    with_stub(R, :run_probe, ->(*_args, **_kwargs) { "TIMEOUT" }) do
      environment = env(package: "foo", version: "2.0.0", require_path: "foo")

      assert_equal [], R.moved(environment, "instance", "parse")
    end
  end

  def test_the_scratch_sweep_leaves_what_a_running_install_might_be_using
    # The sweep runs at the top of a cycle where nothing is live, which is what makes the short
    # threshold safe — the same reasoning, and the same reverted "fix", as the PyPI side.
    root = R.scratch_dir(@home)
    fresh = root + "gem-unpack-fresh"
    stale = root + "gem-unpack-stale"
    fresh.mkpath
    stale.mkpath
    (fresh + "payload").write("x" * 10)
    (stale + "payload").write("x" * 10)
    old = Time.now.to_f - (R::INSTALL_TIMEOUT * 4)
    File.utime(old, old, stale)

    removed, freed = R.sweep_scratch(@home)

    assert_equal 1, removed
    assert_operator freed, :>=, 10
    assert fresh.exist?
    refute stale.exist?
  end

  def test_the_sweep_measures_the_disk_and_not_the_length_of_the_files
    # The swept figure was summed from `st_size`, while `prune` below it and `Envs.directory_size`
    # both sum blocks — and an unpack directory is thousands of small files the filesystem rounds
    # up to a whole block, so the figure that told an operator how much the sweep reclaimed
    # under-counted what it freed.
    #
    # Compared against the same arithmetic rather than against `st_blksize`: the block size is a
    # property of the filesystem, and the claim being pinned is that the module reports what the
    # *disk* set aside for these files, which is what `stat.blocks * 512` is.
    root = R.scratch_dir(@home)
    stale = root + "gem-unpack-many"
    (stale + "lib").mkpath
    32.times { |index| (stale + "lib" + "file#{index}.rb").write("x") }
    old = Time.now.to_f - (R::INSTALL_TIMEOUT * 4)
    File.utime(old, old, stale)

    lengths = (stale + "lib").glob("*.rb").sum { |file| file.stat.size }
    footprint = (stale + "lib").glob("*.rb").sum { |file| file.stat.blocks * 512 }

    removed, freed = R.sweep_scratch(@home)

    assert_equal 1, removed
    assert_equal 32, lengths, "thirty-two files of one byte each"
    assert_operator freed, :>=, footprint
    assert_operator freed, :>, lengths, "the figure has to be the disk's, not the files' lengths"
  end

  def test_a_process_the_kernel_killed_is_not_a_resolved_reference
    # Ruby's third answer, drawn for a kill: an OOM leaves no output, and `resolves?` reads an
    # empty string as "the reference resolved". `run_probe` has to name the kill instead, or a
    # verifier adopts a fix that was never run.
    with_stub(R, :capture, ->(*_args, **_kwargs) { result(status: -9) }) do
      output = R.run_probe(env, "puts 1", [], suffix: "killed")

      assert R.unreached?(output)
      refute R.resolves?(output)
      assert_includes output, "KILLED BY SIGNAL"
    end
  end

  def test_a_killed_install_is_transient_not_a_fact_about_the_release
    # A negative return code is the kernel killing `gem install` — a memory limit, or a redeploy —
    # not the gem being unbuildable. Settled as permanent it drops every crossing that shares the
    # release until the interpreter moves.
    with_stub(R, :capture, ->(*_args, **_kwargs) { result(status: -9) }) do
      error = assert_raises(AgentsFyiMiner::Errors::MinerError) do
        R.checked(["gem", "install", "rake"], what: "install rake", timeout: 60, env: {},
          release: "rake 13.1.0")
      end

      refute error.permanent?
      assert_includes error.message, "signal 9"
    end
  end

  def test_a_failed_install_records_the_reason_rather_than_what_installed_fine
    # The output below is a real `gem install rubyXL -v 3.3.33` from this image.
    #
    # The head of it is `Successfully installed rubyzip-3.7.0` and the tail is where `gem` left
    # its notes — `Results logged to …` — so neither end says why the install stopped, and the
    # record was built out of the head (the caller cut it to two hundred characters from the
    # front). What says so is the pair of lines announcing the failure in between, and both halves
    # are asserted: the reason is present and the news that another dependency was fine is not.
    output = "Successfully installed rubyzip-3.7.0\n" \
             "Building native extensions. This could take a while...\n" \
             "ERROR:  Error installing rubyXL:\n" \
             "\tERROR: Failed to build gem native extension.\n" \
             "\n    " \
             "current directory: /tmp/api/gems/racc-1.8.1/ext/racc/cparse\n" \
             "make failedNo such file or directory - make\n" \
             "\n" \
             "Gem files will remain installed in /tmp/api/gems/racc-1.8.1 for inspection.\n" \
             "Results logged to /tmp/extensions/x86_64-linux/3.3.0/racc-1.8.1/gem_make.out\n"

    with_stub(R, :capture, ->(*_args, **_kwargs) { result(status: 1, output: output) }) do
      error = assert_raises(AgentsFyiMiner::Errors::MinerError) do
        R.checked(["gem", "install", "rubyXL"], what: "installing rubyXL 3.3.33", timeout: 60,
          env: {}, release: "rubyXL 3.3.33")
      end

      reason = error.message
      assert_includes reason, "Failed to build gem native extension"
      refute_includes reason, "Successfully installed"
      refute_includes reason, "Results logged to"
      # And the kind of failure is unchanged by the message: a native build that cannot run here is
      # settled against the release rather than retried for ever.
      assert error.permanent?
      assert_equal "rubyXL 3.3.33", error.release
    end
  end

  def test_a_probe_script_does_not_outlive_the_run
    # The evidence is what Ruby printed, not the file it ran. An environment is shared by two
    # workers and reused for weeks, so a script left behind per examination accumulates without
    # bound.
    with_stub(R, :capture, ->(*_args, **_kwargs) { result }) do
      R.run_probe(env, "puts 1", [], suffix: "cleanup")
    end

    refute (@home + "probe-cleanup.rb").exist?
  end

  def test_a_probe_script_does_not_outlive_a_killed_run
    # The failure paths too: a killed probe used to leave its file behind as surely as one that
    # answered.
    with_stub(R, :capture, ->(*_args, **_kwargs) { result(status: -9) }) do
      output = R.run_probe(env, "puts 1", [], suffix: "killed-cleanup")

      assert_includes output, "KILLED BY SIGNAL"
    end

    refute (@home + "probe-killed-cleanup.rb").exist?
  end

  def test_pruning_a_gem_environment_forgets_its_lock
    # The registry is keyed by path and would otherwise hold one entry per gem environment this
    # process ever built, including every one `prune` has since reclaimed.
    root = R.env_root(@home)
    environment = root + "rake-13.1.0"
    (environment + "specifications").mkpath
    (environment + "specifications" + "rake-13.1.0.gemspec").write("")
    (environment + "payload.bin").write("x" * (1024 * 1024))
    stamp = Time.now.to_f - 10_000
    File.utime(stamp, stamp, environment)
    # The invariant the registry exists for, and the growth this bounds.
    assert_same R.lock_for(environment), R.lock_for(environment)
    assert_includes R::LOCKS, environment.to_s

    removed, _freed = R.prune(@home, budget: 0, quiet: 0)

    assert_equal 1, removed
    refute_includes R::LOCKS, environment.to_s
  end
end
