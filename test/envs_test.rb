# frozen_string_literal: true

require_relative "test_helper"

# The rules that decide what an execution proved, without executing anything.
#
# The subprocess work is deliberately not tested here: it needs the network and a wheel, and a
# test that installs a package is a test that fails on a plane. What *is* tested is every
# judgement made about a run's output, because those are where a fabricated finding would come
# from — reading a refusal as a break, or a break as a refusal, is the difference between evidence
# and invention.
#
# Here those are two named seams — `Envs.run_captured` (one child process) and `Envs.checked`
# (a command whose exit becomes an error) — and `with_stub` is this suite's spelling of the
# monkeypatch, because a stubbed module method has to be put back whatever the test does.
class EnvsTest < MinerTest
  E = AgentsFyiMiner::Envs

  REFUSAL = (
    "Traceback (most recent call last):\n  " \
    "File \"call_site.py\", line 3, in <module>\n    " \
    "httpx.Client(proxies='_marker')\n" \
    "TypeError: Client.__init__() got an unexpected keyword argument 'proxies'"
  )

  # Same rule here: a test that pointed the probe home somewhere must not decide what a later
  # test's subprocesses see.
  def teardown
    E.probe_home = nil
    super
  end

  # Replace one of a module's own methods for the length of a block.
  def with_stub(mod, name, replacement)
    original = mod.method(name)
    mod.singleton_class.send(:define_method, name) do |*args, **kwargs, &block|
      replacement.call(*args, **kwargs, &block)
    end
    yield
  ensure
    mod.singleton_class.send(:define_method, name, original)
  end

  # A child that answered, in the shape `run_captured` returns.
  def answered(status: 0, stdout: "", stderr: "")
    E::Result.new(status: status, stdout: stdout, stderr: stderr)
  end

  def test_the_call_site_is_a_call_a_person_would_have_written
    # The traceback it produces is filed as evidence, so the frame has to be a real one rather
    # than a harness reaching through getattr.
    assert_equal "import httpx\n\nhttpx.Client(proxies='_marker')\n",
      E.call_site("httpx", "Client", "proxies")
  end

  def test_a_call_site_is_written_against_the_module_that_was_resolved
    # The distribution name is not the import name, and the difference is not cosmetic: `import
    # pyyaml` fails before any argument is bound, so a call site built from the distribution name
    # reports a break in a module nobody can import. The resolved name comes from the
    # environment's own metadata, and this is the one place it is turned into the caller's line.
    assert_includes E.call_site("yaml", "safe_load", "typ"), "import yaml"
    refute_includes E.call_site("yaml", "safe_load", "typ"), "import pyyaml"
    assert_includes E.symbol_site("sklearn", "clone"), "import sklearn"
  end

  def test_a_call_site_uses_the_name_it_is_given_verbatim
    # No hyphen-to-underscore rewrite happens here any more: guessing is what broke `pyyaml`,
    # `pyjwt` and `scikit-learn`, and the environment is the only thing that can answer the
    # question.
    assert_includes E.call_site("ruamel-yaml", "YAML", "typ"), "import ruamel-yaml"
  end

  def test_a_refusal_names_the_parameter_it_refused
    assert E.refused_parameter?(REFUSAL, "proxies")
  end

  def test_failing_for_another_reason_is_not_a_refusal_of_this_parameter
    # The distinction the whole differential rests on: a release that crashes on a missing
    # positional did not remove an argument.
    crashed = (
      "Traceback (most recent call last):\n  " \
      "File \"call_site.py\", line 3, in <module>\n    " \
      "httpx.Client(proxies='_marker')\n" \
      "TypeError: Client.__init__() missing 1 required positional argument: 'transport'"
    )

    refute E.refused_parameter?(crashed, "proxies")
  end

  def test_a_refusal_of_a_different_parameter_is_not_a_refusal_of_this_one
    other = "TypeError: Client.__init__() got an unexpected keyword argument 'cert'"

    refute E.refused_parameter?(other, "proxies")
  end

  def test_the_traceback_keeps_the_interpreter_lines_verbatim
    assert_equal REFUSAL, E.traceback_of(REFUSAL)
  end

  def test_a_traceback_that_is_not_one_is_returned_rather_than_dropped
    # An import error with no frames still says something; discarding it would turn a real result
    # into an empty report.
    assert_equal "ModuleNotFoundError: No module named 'x'",
      E.traceback_of("ModuleNotFoundError: No module named 'x'")
  end

  def test_the_environment_directory_is_stripped_from_the_traceback
    # Modern CPython absolutises the script path, so without this a filed traceback carries one
    # contributor's home directory.
    raw = (
      "Traceback (most recent call last):\n  " \
      "File \"/home/someone/.cache/envs/httpx-0.28.1/call_site.py\", line 3, in <module>\n    " \
      "httpx.Client(proxies='_marker')\n" \
      "TypeError: Client.__init__() got an unexpected keyword argument 'proxies'"
    )
    cleaned = E.traceback_of(raw, root: Pathname.new("/home/someone/.cache/envs/httpx-0.28.1"))

    assert_includes cleaned, 'File "call_site.py"'
    refute_includes cleaned, "someone"
    assert_includes cleaned, "unexpected keyword argument 'proxies'"
  end

  def test_everything_but_the_root_survives_the_stripping
    # Only the machine-specific prefix goes; the frame, its line number, the source line and the
    # exception are the evidence.
    raw = REFUSAL.sub('"call_site.py"', '"/root/envs/httpx-0.28.1/call_site.py"')

    assert_equal REFUSAL, E.traceback_of(raw, root: Pathname.new("/root/envs/httpx-0.28.1"))
  end

  def test_the_exception_line_is_the_last_thing_said
    assert_equal "TypeError: Client.__init__() got an unexpected keyword argument 'proxies'",
      E.exception_line("#{REFUSAL}\n")
  end

  def test_an_empty_run_has_no_exception_line
    assert_equal "", E.exception_line("")
  end

  # The environment a fake install is installing into.
  #
  # `checked` is called with either the venv command or the venv's own pip, so the root is the
  # last argument for the first and two directories up from the interpreter for the second.
  def install_root(argv)
    return Pathname.new(argv.last) if argv.include?("venv")

    Pathname.new(argv.first).parent.parent
  end

  # What a finished install leaves behind, which is what makes an environment complete: an
  # interpreter, and something in it that is not pip or the tooling.
  def install(root, name)
    site = root + "lib" + "python3.12" + "site-packages"
    FileUtils.mkdir_p(site)
    FileUtils.mkdir_p(site + "#{name}-1.0.dist-info")
  end

  # The half of a build `venv` performs on its own: the interpreter exists, and nothing is
  # installed in it yet.
  def venv(argv)
    root = Pathname.new(argv.last)
    FileUtils.mkdir_p(root + "bin")
    (root + "bin" + "python").write("")
    root
  end

  def test_the_same_environment_is_never_built_twice_at_once
    # Two crossings of one package share a release — `1.0->2.0` and `2.0->3.0` both need `2.0` —
    # so the same directory is asked for by two workers at the same moment. Both would see no
    # interpreter, both would run `venv` into it, and the result is an environment that is half of
    # each: a corruption whose findings would be fabricated rather than merely wrong.
    builds = []
    guard = Mutex.new
    slow = lambda do |argv, what:, timeout: E::INSTALL_TIMEOUT|
      guard.synchronize { builds << what }
      sleep 0.05 # long enough that two threads overlap
      if argv.include?("venv")
        venv(argv)
      else
        install(install_root(argv), "pkg")
      end
    end
    E::LOCKS.clear

    results = Queue.new
    with_stub(E, :checked, slow) do
      (1..4).map { Thread.new { results << E.build("pkg", "2.0", home: @home) } }.each(&:join)
    end

    roots = Array.new(4) { results.pop }.map { |built| built.root.to_s }
    assert_equal 4, roots.length
    assert_equal 1, roots.uniq.length
    assert_equal 1, builds.count("venv for pkg 2.0")
    assert_equal 1, builds.count("install pkg==2.0")
  end

  def test_two_different_environments_are_still_built_beside_each_other
    # The lock is on the directory, not around the function: building *different* environments
    # concurrently is the parallelism the service needs.
    overlapping = Queue.new
    in_flight = []
    guard = Mutex.new
    slow = lambda do |argv, what:, timeout: E::INSTALL_TIMEOUT|
      guard.synchronize do
        in_flight << what
        overlapping << true if in_flight.length >= 2
      end
      sleep 0.05
      venv(argv) if argv.include?("venv")
    end
    E::LOCKS.clear

    with_stub(E, :checked, slow) do
      %w[1.0 2.0].map { |version| Thread.new { E.build("pkg", version, home: @home) } }.each(&:join)
    end

    assert overlapping.pop(timeout: 5), "two different environments were never built at once"
  end

  def test_a_half_built_environment_is_never_handed_out
    #
    # The old fast path did exactly that, and the cost was not theoretical: in the verifier's first
    # hour it produced `ModuleNotFoundError: No module named 'httpx'` about a release that was
    # installed, which the caller read as "this name still resolves" and filed as a contradiction
    # of a report that was true. The same race had been losing the miner's pairs to `could not be
    # imported` for as long as the parallel examining has existed.
    venv_done = Queue.new
    installed = Queue.new
    results = Queue.new
    slow = lambda do |argv, what:, timeout: E::INSTALL_TIMEOUT|
      if what.start_with?("venv")
        venv(argv)
        venv_done << true
        next
      end
      # The install: the half of the build the old fast path could not see.
      sleep 0.2
      installed << true
    end
    E::LOCKS.clear

    with_stub(E, :checked, slow) do
      first = Thread.new { results << E.build("pkg", "1.0", home: @home) }
      assert venv_done.pop(timeout: 5), "the venv was never created"

      second = Thread.new { results << E.build("pkg", "1.0", home: @home) }
      second.join(5)

      refute second.alive?
      assert installed.pop(timeout: 5), "an environment was handed out before the install finished"
      assert_equal 2, results.size
      first.join(5)
    end
  end

  def test_a_build_that_stopped_halfway_is_not_an_environment
    # pip killed by its timeout, or the worker by the memory limit, leaves a directory holding an
    # interpreter and half a dependency tree — and nothing about it says "unfinished". It was
    # handed out for ever, so every probe against it reported the package as unimportable:
    # `xgboost 2.1.4` and `pyspark 3.3.4` sat in that state, and the four reports that needed them
    # were the only unconfirmed reports in the corpus.
    calls = []
    stopped = lambda do |argv, what:, timeout: E::INSTALL_TIMEOUT|
      calls << what
      if argv.include?("venv")
        venv(argv)
        next
      end
      # The install starts and stops: dependencies, no package, no trace of the build having
      # failed.
      site = install_root(argv) + "lib" + "python3.12" + "site-packages"
      FileUtils.mkdir_p(site)
      FileUtils.mkdir_p(site + "pip-25.0.dist-info")
    end
    E::LOCKS.clear

    with_stub(E, :checked, stopped) do
      first = E.build("pkg", "1.0", home: @home)
      refute E.installed?(first.root)

      # Built again rather than completed, which is the second half of the rule: a half-done
      # install leaves a tree pip will not revisit.
      E.build("pkg", "1.0", home: @home)
    end

    assert_equal 2, calls.count("venv for pkg 1.0")
    assert_equal 2, calls.count("install pkg==1.0")
  end

  def test_an_environment_that_finished_is_reused_without_reinstalling
    # The fossil is replaced; a real environment is not. Rebuilding every environment on every
    # call is the cost this cache exists to avoid — several hundred wheels per run.
    calls = []
    finished = lambda do |argv, what:, timeout: E::INSTALL_TIMEOUT|
      calls << what
      if argv.include?("venv")
        venv(argv)
      else
        install(install_root(argv), "pkg")
      end
    end
    E::LOCKS.clear

    with_stub(E, :checked, finished) { 2.times { E.build("pkg", "1.0", home: @home) } }

    assert_equal ["venv for pkg 1.0", "install pkg==1.0"], calls
  end

  def test_a_build_that_failed_leaves_nothing_behind
    # An install killed by its own timeout left a directory holding an interpreter and a few of
    # its dependencies, and the next build found a non-pip `.dist-info` in it and called it
    # finished — so the wreckage was handed out for ever and every probe against that release
    # reported it as unimportable. Three `xgboost` reports could not be confirmed because of it. A
    # failed build is a retry, not a state.
    attempts = []
    fails = lambda do |argv, what:, timeout: E::INSTALL_TIMEOUT|
      attempts << what
      if argv.include?("venv")
        venv(argv)
        next
      end
      # Some of the dependency tree landed before the timeout.
      site = install_root(argv) + "lib" + "python3.12" + "site-packages"
      FileUtils.mkdir_p(site)
      FileUtils.mkdir_p(site + "numpy-2.5.3.dist-info")
      raise AgentsFyiMiner::Errors::MinerError.new("timed out trying to install pkg==1.0")
    end
    E::LOCKS.clear

    with_stub(E, :checked, fails) do
      assert_raises(AgentsFyiMiner::Errors::MinerError) { E.build("pkg", "1.0", home: @home) }
    end
    refute (@home + "pkg-1.0").exist?
    refute E.installed?(@home + "pkg-1.0")

    # And the retry starts from a clean directory rather than the wreckage.
    with_stub(E, :checked, fails) do
      assert_raises(AgentsFyiMiner::Errors::MinerError) { E.build("pkg", "1.0", home: @home) }
    end
    assert_equal 2, attempts.count("venv for pkg 1.0")
  end

  def test_a_release_pip_cannot_produce_says_which_release_and_that_asking_again_will_not_help
    # One fact, two halves, and the caller needs both. Which release, because a release is the old
    # side of several crossings and settling only the pair in hand makes eleven more ask pip the
    # same question; that it is permanent, because the alternative is three attempts per pair and a
    # cycle that spends its whole budget on work that cannot happen.
    failing = lambda do |_argv, timeout: E::RUN_TIMEOUT, cwd: nil, env: nil|
      answered(status: 1, stderr: "ERROR: No matching distribution found for wrapt==1.13.3")
    end

    caught = with_stub(E, :run_captured, failing) do
      assert_raises(AgentsFyiMiner::Errors::MinerError) { E.build("wrapt", "1.13.3", home: @home) }
    end

    assert caught.permanent?
    assert_equal "wrapt 1.13.3", caught.release
  end

  def test_a_failure_that_might_not_repeat_is_not_called_permanent
    # The two mistakes are not symmetric. A permanent failure settled wrongly drops every pair that
    # needs the release until the record expires; a transient one treated as permanent costs three
    # retries. So the classification only fires on pip's own words for "this release cannot be had
    # here" — a timeout, a full disk and a dropped connection all keep their attempts.
    assert E.cannot_be_built?("ERROR: No matching distribution found for x==1.0")
    # The other half of what pip prints for a version that is not there.
    assert E.cannot_be_built?("ERROR: Could not find a version that satisfies the requirement x==1.0")
    assert E.cannot_be_built?("error: failed building wheel for uvloop")
    assert E.cannot_be_built?("SyntaxError: invalid syntax")
    # What a build *step* failing looks like, which is where most of these end: `aiofile 3.0.0`
    # declares an invalid `python_requires`, so pip cannot generate its metadata and never reaches
    # the wheel message above. The first version of this list called that transient and paid three
    # attempts per crossing for it.
    assert E.cannot_be_built?(
      "error: subprocess-exited-with-error\n" \
      "× Getting requirements to build wheel did not run successfully.\n" \
      "note: This error originates from a subprocess, and is likely not a problem with pip."
    )
    refute E.cannot_be_built?(
      "ERROR: Could not install packages due to an OSError: [Errno 28] No space left on device"
    )
    refute E.cannot_be_built?("ConnectionResetError: [Errno 104] Connection reset by peer")
    refute E.cannot_be_built?("pip._vendor.urllib3.exceptions.ReadTimeoutError: HTTPSConnectionPool")
  end

  def test_a_timeout_keeps_its_attempts_because_it_is_this_machine_running_out_of_patience
    # `sqlalchemy 0.8` and `sglang` both hit the ceiling legitimately, and one of them installs in
    # twelve minutes on an idle host.
    timing_out = lambda do |_argv, timeout: E::RUN_TIMEOUT, cwd: nil, env: nil|
      raise E::TimedOut, "pip install"
    end

    caught = with_stub(E, :run_captured, timing_out) do
      assert_raises(AgentsFyiMiner::Errors::MinerError) { E.build("pkg", "1.0", home: @home) }
    end

    refute caught.permanent?
  end

  def test_a_build_installs_the_tooling_an_environment_really_has
    # `python -m venv` has installed no setuptools since 3.12, and a release that imports
    # `pkg_resources` at runtime then cannot be imported — `markdown 3.1.1`, `markdown 3.0.1`
    # and `jaraco-classes 1.3` were all reported as unimportable here and import fine in any
    # environment a caller would run them in. It is the one deliberate exception to "exactly
    # this package at exactly this version".
    asked = []
    recording = lambda do |argv, what:, timeout: E::INSTALL_TIMEOUT|
      asked << argv.dup
      if argv.include?("venv")
        venv(argv)
      else
        install(install_root(argv), "markdown")
      end
    end
    E::LOCKS.clear

    with_stub(E, :checked, recording) { E.build("markdown", "3.1.1", home: @home) }

    pip = asked.reject { |line| line.include?("venv") }.first
    assert_includes pip, "setuptools"
    assert_includes pip, "markdown==3.1.1"
  end

  def test_tooling_installed_without_the_release_is_not_a_finished_environment
    # The completeness test caught a build that stopped halfway by wanting something in the
    # environment that is neither `pip` nor... now setuptools, which `build` installs first. A
    # build killed after setuptools landed would otherwise be handed out as finished with the
    # package missing from it — which is the fossil this test exists for, reintroduced by the fix.
    root = dir("markdown-3.1.1")
    site = root + "lib" + "python3.12" + "site-packages"
    FileUtils.mkdir_p(site)
    FileUtils.mkdir_p(root + "bin")
    (root + "bin" + "python").write("")
    FileUtils.mkdir_p(site + "setuptools-80.9.0.dist-info")
    FileUtils.mkdir_p(site + "pip-25.0.dist-info")

    refute E.installed?(root)

    FileUtils.mkdir_p(site + "markdown-3.1.1.dist-info")
    assert E.installed?(root)
  end

  def test_a_release_this_interpreter_cannot_import_is_a_permanent_fact_about_the_release
    # The install succeeded and the package will not import — a `SyntaxError` from a release older
    # than the interpreter, or a dependency that is not declared. Both reach the same answer in an
    # hour, and the release travels with the failure so the ledger can say which one.
    installed_env = lambda do |argv, what:, timeout: E::INSTALL_TIMEOUT|
      if argv.include?("venv")
        venv(argv)
      else
        install(install_root(argv), "kombu")
      end
    end
    failing = lambda do |_argv, timeout: E::RUN_TIMEOUT, cwd: nil, env: nil|
      answered(status: 1, stderr: "SyntaxError: invalid syntax")
    end
    E::LOCKS.clear

    caught = with_stub(E, :checked, installed_env) do
      with_stub(E, :run_captured, failing) do
        env = E.build("kombu", "4.1.0", home: @home)
        assert_raises(AgentsFyiMiner::Errors::MinerError) { E.inventory(env) }
      end
    end

    assert caught.permanent?
    assert_equal "kombu 4.1.0", caught.release
  end

  def test_a_probe_that_never_reached_the_release_is_not_an_answer
    # The third answer a probe can give, beside refused and resolved. Reading it as "resolved" is
    # how a name that is gone becomes a report that is wrong.
    assert E.unreached?("TIMEOUT")
    assert E.unreached?("ModuleNotFoundError: No module named 'httpx'")
    refute E.unreached?("")
    refute E.unreached?(REFUSAL)
    assert E.answers?("")
    refute E.answers?("TIMEOUT")
  end

  def test_a_process_the_kernel_killed_is_not_an_answer
    # The third answer, drawn for the case that has no output at all: the container kills a probe
    # against its memory limit, and the empty string it leaves is what `resolves?` reads as "the
    # reference resolved". The kill has to be named in the output, or a verifier adopts a fix that
    # was never run.
    output = E.probe_output(answered(status: -9))

    assert E.unreached?(output)
    refute E.answers?(output)
    refute E.resolves?(output)
    assert_includes output, "SIGKILL"
  end

  def test_a_probe_that_exited_on_its_own_keeps_its_verdict
    # The marker is for a signal only. An ordinary exit must still read the way it did — an empty
    # output is a reference that resolved, and a traceback is the failure — or the fix above would
    # have turned every clean probe into "never ran".
    quiet = E.probe_output(answered)
    failed = E.probe_output(answered(status: 1, stdout: "boom\n"))

    assert_equal "", quiet
    assert E.resolves?(quiet)
    assert_equal "boom\n", failed
    refute E.unreached?(failed)
  end

  def test_a_failed_install_records_what_pip_announced_not_its_trailing_note
    # The output below is the tail of a real `pip install scikit-learn==0.23.2`.
    #
    # Both ends are useless as a reason: the head is a line per dependency that installed, and the
    # very last line is pip's standing note about subprocesses. The announcement in the middle is
    # what a reader can act on, and it is what the record has to carry — `See above for output` is
    # where pip put its notes, and the note about subprocesses is on both of these failures and on
    # none of the successful ones.
    output = (
      "      ╰─> See above for output.\n" \
      "\n      " \
      "note: This is an issue with the package mentioned above, not pip.\n      " \
      "hint: See above for details.\n      " \
      "[end of output]\n" \
      "\n  " \
      "note: This error originates from a subprocess, and is likely not a problem with pip.\n" \
      "error: subprocess-exited-with-error\n" \
      "\n" \
      "× pip subprocess to install build dependencies did not run successfully.\n" \
      "│ exit code: 1\n" \
      "╰─> See above for output.\n" \
      "\n" \
      "note: This error originates from a subprocess, and is likely not a problem with pip.\n"
    )

    reason = E.failure_reason(output)

    assert_includes reason, "subprocess-exited-with-error"
    assert_includes reason, "did not run successfully"
    refute_includes reason, "note:"
    refute_includes reason, "See above"
  end

  def test_an_install_that_named_nothing_in_that_shape_still_says_something
    # An installer can fail without printing a line this recognises, and an empty reason is worse
    # than an approximate one: the field is what a reader looks at to decide whether the fact is
    # worth re-deriving.
    assert_equal "some other kind of noise / the last line it said",
      E.failure_reason("some other kind of noise\nthe last line it said")
  end

  def test_a_killed_install_is_transient_not_a_fact_about_the_release
    # A negative status is the kernel killing the process — a memory limit, or a SIGKILL on
    # redeploy — which says nothing about the release. Read as permanent, it drops every crossing
    # that shares the release until the interpreter changes.
    killed = lambda do |_argv, timeout: E::RUN_TIMEOUT, cwd: nil, env: nil|
      answered(status: -9)
    end

    caught = with_stub(E, :run_captured, killed) do
      assert_raises(AgentsFyiMiner::Errors::MinerError) do
        E.checked(["pip", "install", "kombu==4.1.0"], what: "install kombu 4.1.0")
      end
    end

    refute caught.permanent?
    assert_includes caught.message, "SIGKILL"
  end

  def test_a_killed_inventory_is_transient_not_a_fact_about_the_release
    # The import was killed, so the receipt is missing for a reason that has nothing to do with the
    # release — and the two want opposite verdicts: the kernel is this machine's problem and reaches
    # a different answer in a minute, while a `SyntaxError` is the release's and will not.
    killed = lambda do |_argv, timeout: E::RUN_TIMEOUT, cwd: nil, env: nil|
      answered(status: -9)
    end
    env = E::Env.new(package: "kombu", version: "4.1.0", root: @home + "envs" + "kombu-4.1.0")
    FileUtils.mkdir_p(env.root)

    caught = with_stub(E, :run_captured, killed) do
      assert_raises(AgentsFyiMiner::Errors::MinerError) { E.inventory(env) }
    end

    refute caught.permanent?
    assert_equal "kombu 4.1.0", caught.release
    assert_includes caught.message, "SIGKILL"
  end

  def test_a_probe_runs_where_the_release_can_write
    # `HOME` in this container is on the image's read-only root, so a release that reads its
    # settings while it imports — `platformdirs` and everything built on it — is denied a write, and
    # the inventory files that as a permanent fact about the *release*. Fifteen pairs were retired
    # that way before this existed: crewai, mem0ai, mini-swe-agent, langgraph and apache-airflow,
    # each on its first attempt, never examined again.
    E.probe_home = nil
    home = E.use_probe_home(@home)
    seen = {}
    run = lambda do |argv, timeout: E::RUN_TIMEOUT, cwd: nil, env: nil|
      seen[:env] = env
      seen[:cwd] = cwd
      answered
    end
    env = E::Env.new(package: "httpx", version: "0.28.1", root: @home + "envs" + "httpx-0.28.1")
    FileUtils.mkdir_p(env.root)

    with_stub(E, :run_captured, run) { env.run_script(["call_site.py"]) }

    assert_equal home.to_s, seen[:env]["HOME"]
    assert_equal env.root, seen[:cwd]
  end

  def test_the_probe_home_is_not_a_change_to_the_miners_own_home
    # The CLI's default home and the ledger under it are decided once at startup, so a
    # process-wide `HOME` would move state the next run looks for, which is the one thing the
    # ledger must never do. Only the subprocess is moved.
    E.probe_home = nil
    before = ENV["HOME"]

    E.use_probe_home(@home)

    assert_equal before, ENV["HOME"]
  end

  def test_an_inventory_is_taken_where_the_release_can_write
    # The working directory matters as much as the home: `langgraph-runtime-inmem` creates
    # `.langgraph_api` there while it imports, and the snippet's receipt is only written when the
    # import finishes — so a relative write refused by a read-only working directory read as "this
    # release cannot be imported".
    E.probe_home = nil
    home = E.use_probe_home(@home)
    seen = {}
    env = E::Env.new(package: "httpx", version: "0.28.1", root: @home + "envs" + "httpx-0.28.1")
    FileUtils.mkdir_p(env.root)
    run = lambda do |argv, timeout: E::RUN_TIMEOUT, cwd: nil, env: nil|
      seen[:env] = env
      seen[:cwd] = cwd
      # The receipt is the contract of the snippet this stands in for.
      Pathname.new(argv.last).write('{"module": "httpx", "entries": []}')
      answered
    end

    inventory = with_stub(E, :run_captured, run) { E.inventory(env) }

    assert_equal "httpx", inventory.module
    assert_equal env.root, seen[:cwd]
    assert_equal home.to_s, seen[:env]["HOME"]
  end

  def test_a_probe_script_does_not_outlive_the_run
    # The evidence is what the interpreter printed, not the file that produced it. An environment is
    # shared by two workers and reused for weeks, so a script left behind per examination
    # accumulates without bound — and `sweep_scratch` looks in `TMPDIR`, so nothing else was ever
    # going to collect them.
    run = ->(_argv, timeout: E::RUN_TIMEOUT, cwd: nil, env: nil) { answered }
    env = E::Env.new(package: "httpx", version: "0.28.1", root: @home + "envs" + "httpx-0.28.1")
    FileUtils.mkdir_p(env.root)

    with_stub(E, :run_captured, run) { E.probe_symbol(env, "httpx", "Client", suffix: "-a") }

    refute (env.root + "call_site-a.py").exist?
  end

  def test_a_probe_script_does_not_outlive_a_timeout_either
    # The failure paths are half the point: a probe that timed out used to leave its file behind as
    # surely as one that succeeded.
    timing_out = lambda do |_argv, timeout: E::RUN_TIMEOUT, cwd: nil, env: nil|
      raise E::TimedOut, "call_site.py"
    end
    env = E::Env.new(package: "httpx", version: "0.28.1", root: @home + "envs" + "httpx-0.28.1")
    FileUtils.mkdir_p(env.root)

    output = with_stub(E, :run_captured, timing_out) do
      E.probe(env, "httpx", "Client", "proxies", suffix: "-b")
    end

    assert_equal "TIMEOUT", output
    refute (env.root + "call_site-b.py").exist?
  end

  def test_an_inventory_receipt_does_not_outlive_the_run
    # The receipt is this run's answer and is read by the call, and by nothing else — so it goes with
    # the script, instead of one per examination that has ever used the release.
    env = E::Env.new(package: "httpx", version: "0.28.1", root: @home + "envs" + "httpx-0.28.1")
    FileUtils.mkdir_p(env.root)
    run = lambda do |argv, timeout: E::RUN_TIMEOUT, cwd: nil, env: nil|
      Pathname.new(argv.last).write('{"module": "httpx", "entries": []}')
      answered
    end

    inventory = with_stub(E, :run_captured, run) { E.inventory(env, suffix: "-i") }

    assert_equal "httpx", inventory.module
    assert_equal [], env.root.glob("_inventory*")
  end

  def test_pruning_an_environment_forgets_its_lock
    # The registry is keyed by environment path and would otherwise hold one entry for every
    # environment this process ever built, including every one `prune` has since reclaimed. `prune`
    # runs between cycles where nothing is live, so the entry belongs to nobody by then.
    root = dir("envs", "httpx-0.28.1")
    FileUtils.mkdir_p(root + "bin")
    (root + "bin" + "python").write("")
    FileUtils.mkdir_p(root + "lib")
    (root + "lib" + "payload.bin").write("x" * (1024 * 1024))
    stamp = Time.now.to_f - 10_000
    File.utime(stamp, stamp, root)
    # The invariant the registry exists for, and the growth this bounds: the same path gets the
    # same lock, and a reclaimed path keeps none.
    assert_same E.lock_for(root), E.lock_for(root)
    assert_includes E::LOCKS.keys, root.to_s

    removed, = E.prune(@home + "envs", budget: 0, quiet: 0)

    assert_equal 1, removed
    refute_includes E::LOCKS.keys, root.to_s
  end
end
