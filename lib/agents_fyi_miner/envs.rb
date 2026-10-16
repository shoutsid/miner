# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "timeout"

require_relative "bandwidth"
require_relative "errors"
require_relative "machine"

module AgentsFyiMiner
  # Building environments, and running code inside them.
  #
  # Every claim this miner makes is an executed claim: a call was run against one release and
  # against another, and the difference is the finding. That makes this module the foundation
  # rather than a utility — if it reports an environment as ready when it is not, or reports a
  # crash that did not happen, every finding downstream is a fabrication with a citation.
  #
  # So it is deliberately slow and obvious: a virtual environment per (package, version) on
  # disk, reused across runs, and a child process for everything. Nothing in here imports the
  # package under test, because the package under test is hostile by design — it is a version
  # that changed under somebody.
  #
  #
  # Same four call sites catch it, for the same reasons. * `Signal.SIGKILL`-style names are
  # spelled the same way (`kill_reason`), because a reader of a filed record sees them and the
  # Ruby spelling of a signal is `KILL`, not `SIGKILL`.
  module Envs
    # The floor on how long an install may take, and all an interpreter gets when nothing says
    # otherwise. A package that hangs on import is a package this miner cannot say anything
    # about, and waiting for it would stall a run that has hundreds of pairs to get through.
    #
    # It is a floor rather than the whole story now. What an install actually gets is
    # `install_deadline`, which prices the bytes it has to move — because a flat ceiling cannot
    # serve both ends of the watchlist: five minutes is generous for the hundreds of small
    # packages that make up most of the queue and hopeless for the machine-learning tail, where
    # one wheel is 688 MB.
    INSTALL_TIMEOUT = 300
    RUN_TIMEOUT = 60

    # The most any one install may be given, however large its payload.
    #
    # This is the ceiling that turns "we cannot fetch this here" into a fact rather than a retry
    # that never lands: a release whose payload would need longer is recorded as unexaminable by
    # the caller that reaches it, instead of being attempted for ever. The value is a compromise
    # between two real costs — long enough to deliver a gigabyte at the rate this deployment
    # measured, short enough that a stuck install does not hold a worker for most of a cycle.
    MAX_INSTALL_TIMEOUT = 2400

    # What a retry multiplies its deadline by.
    #
    # `install_deadline` prices a release from its *own* files, because those are what the index
    # hands over without another request. A release that is small on its own and drags in a
    # gigabyte of dependencies is therefore under-priced — and a retry is the evidence that it
    # was: it ran out of time with the environment already on its way. Doubling per attempt
    # reaches the ceiling and stops there.
    INSTALL_RETRY_FACTOR = 2

    # How slow a worker is assumed to be when pricing a payload and nothing has measured the
    # link yet — the first cycle, or a container that has only been probing.
    #
    # An unknown rate must not be read as a fast one. Pricing at this floor gives a large release
    # the benefit of the doubt, which is the direction whose cost is an idle worker rather than a
    # discarded download.
    MIN_INSTALL_SHARE_BYTES_PER_SECOND = 64 * 1024

    # Where pip is told to unpack, and how long its leftovers may sit there.
    #
    # `/tmp` in this container is a `tmpfs`, which is RAM, and pip unpacks every wheel and every
    # sdist build into `TMPDIR` — a gigabyte-scale CUDA wheel becomes a gigabyte of the
    # container's memory limit. That was measured, not assumed: with `/tmp` left as the scratch
    # directory the miner's tmpfs held **4.1 GB in thirty-five minutes** — 769 `pip-unpack-*`
    # directories and 28 build directories — and the container sat pinned against its own memory
    # ceiling, 3,174 throttle events deep, with pip installs failing and reporting *nothing*
    # (`could not install sentence-transformers==5.4.1: `, with no output after the colon, which
    # is a subprocess that never printed).
    #
    # Two things are wrong with that and both are fixed here. The scratch belongs on the volume,
    # where this host has 1.6 TB, and `use_scratch_dir` puts it there. And pip only removes its
    # own scratch on the way out, so a pip killed by its timeout — or by the container dying
    # mid-install — leaves it behind for ever; `sweep_scratch` is the other half.
    #
    # The threshold is short on purpose, and deliberately *not* derived from how long an install
    # may now run — which was the first thing written here, on the reasoning that a longer
    # install needs a longer guard. It does not, because of when the sweep is called: at the top
    # of a cycle, before any worker exists, since both loops join their pool before the cycle
    # returns. Nothing can be installing while it runs, so a directory even a minute old belongs
    # to an install that is already dead. Generosity here is not free either: one measured sweep
    # reclaimed 2,767 MB, so a threshold measured in hours would let that pile up rather than
    # reclaim it. What this guards is the narrow case alone — an install killed moments before
    # the process was killed too, whose directory is not worth racing.
    SCRATCH_ORPHAN_SECONDS = INSTALL_TIMEOUT * 2

    # How much disk the environments may take between them.
    #
    # This is the bound that stops a slow disk-full outage. Every pair needs two environments and
    # a thousand packages have twelve crossings each, so the ceiling on what this can consume is
    # not "one venv" — it reached 26 GB within an hour of the wider watchlist, most of it a
    # handful of machine-learning packages. Nothing here is a record: an environment is how a
    # finding is derived, and a finding that has been filed does not need it again. So they are a
    # cache with a budget, and the least recently used go first.
    ENV_BUDGET_BYTES = 8 * (1024**3)

    # How long an environment is left alone regardless of the budget.
    #
    # A cycle examines several pairs at once, and deleting a directory another worker is probing
    # would turn a real finding into a fabricated one — the traceback would name a file that was
    # there when the script was written. Pruning happens between cycles, when no worker is
    # running, and this is the second guard: anything touched recently is treated as in use
    # whatever the budget says.
    ENV_QUIET_SECONDS = 900

    # The most submodules one `moved` pass will import, in the snippet below.
    LIMIT = 200

    # The command that answers "where did this name go" and whether a dotted path resolves.
    #
    # A public name leaving the top level is very often a *move* rather than a removal —
    # `numpy.RankWarning` became `numpy.exceptions.RankWarning`, `wsproto.Event` became
    # `wsproto.events.Event` — and "pin below this release" is the wrong advice for those: the
    # caller's import is one path segment away from working. Reading that off the release notes
    # would be reading somebody's prose; this asks the release, by importing its submodules and
    # looking for the name where it is *defined* rather than re-exported, so what comes back is a
    # location that resolved rather than a sentence that mentioned one.
    MOVED_SOURCE = <<~'PY'
      import importlib, json, pkgutil, sys

      module_name, names_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
      with open(names_path) as handle:
          wanted = json.load(handle)

      module = importlib.import_module(module_name)
      prefix = module.__name__ + "."
      # Bounded because this imports what it looks at: a package with hundreds of
      # submodules would otherwise turn one pair into minutes of importing, and the
      # names this pass exists for live one or two levels down.
      LIMIT = 200

      candidates = set()
      for name in list(sys.modules):
          if name.startswith(prefix):
              candidates.add(name)
      try:
          for found in pkgutil.iter_modules(module.__path__):
              candidates.add(prefix + found.name)
      except (AttributeError, TypeError):
          pass
      # Imported first, looked at second: `iter_modules` reads the directory, and a
      # name that is not imported has not been shown to be there.
      loaded = {}
      for name in sorted(candidates)[:LIMIT]:
          # A private path is not a place a caller can be told to import from, and it is
          # exactly where a package hides the implementation of a name it dropped.
          if any(part.startswith("_") for part in name.split(".")[1:]):
              continue
          try:
              loaded[name] = importlib.import_module(name)
          except (Exception, SystemExit):
              # Deliberately not `BaseException`. A submodule that calls `sys.exit()`
              # while it imports is a quirk of the release and must not abort the walk of
              # the others — that is the direction this catch exists for — but a
              # `KeyboardInterrupt` is this process being asked to stop, and swallowing
              # it inside a loop that imports up to LIMIT modules would make a redeploy
              # wait for the walk to finish.
              continue

      found = {}
      for name in wanted:
          for location, sub in loaded.items():
              obj = getattr(sub, name, None)
              if obj is None:
                  continue
              # Defined here, not re-exported through here: `numpy.core` carries most of
              # the package's names, and answering with it would name a private module
              # and a path nobody is meant to import.
              if getattr(obj, "__module__", None) != location:
                  continue
              # The whole path a caller writes, not the module the name lives in: what
              # the report hands over has to be an import that works, and `wsproto.events`
              # on its own is not one.
              found[name] = f"{location}.{name}"
              break

      with open(out, "w") as handle:
          json.dump(found, handle)
    PY

    # The inventory, generated as a snippet rather than imported, because it has to run *inside*
    # the environment being described: what `httpx.Client` accepts is a fact about the installed
    # release, and reading it from anywhere else would be reading it from the wrong version.
    INVENTORY_SOURCE = <<~'PY'
      import importlib, inspect, json, sys
      from importlib import metadata

      package, out = sys.argv[1], sys.argv[2]


      def candidate_modules(distribution):
          """Which importable modules this distribution provides.

          The distribution name is not the import name, and guessing it by replacing
          `-` with `_` silently excludes a large part of PyPI: `pyyaml` is `yaml`,
          `pyjwt` is `jwt`, `scikit-learn` is `sklearn`, `python-dotenv` is `dotenv`,
          `beautifulsoup4` is `bs4`, `pillow` is `PIL`. Every one of those was reported
          as "could not be imported" — a skip line that reads like a fact about the
          package rather than a fact about this guess.

          So the installed distribution is asked instead of being guessed at. Its
          `top_level.txt` is the direct answer when the wheel ships one; when it does
          not, the first path component of each file it recorded is the same answer
          derived from what pip actually installed.
          """
          found = []
          try:
              installed = metadata.distribution(distribution)
          except metadata.PackageNotFoundError:
              installed = None
          if installed is not None:
              raw = None
              try:
                  raw = installed.read_text("top_level.txt")
              except Exception:
                  raw = None
              if raw:
                  found.extend(line.strip() for line in raw.splitlines() if line.strip())
              if not found:
                  for entry in installed.files or []:
                      head = str(entry).split("/")[0]
                      if not head or head.endswith((".dist-info", ".egg-info", ".data", ".pth")):
                          continue
                      found.append(head[:-3] if head.endswith(".py") else head)
          # Last, because it is the guess that fails: a distribution with no metadata
          # readable at all still usually imports under its own name.
          found.append(distribution.replace("-", "_"))
          # `isidentifier` because the answer is used as a module name: a wheel that
          # records a file under `../` proposed `..` as a candidate, and the note filed
          # with the real failure opened with `TypeError: the 'package' argument is
          # required to perform a relative import for '..'` instead of the release's own
          # error. A name that cannot be imported is not a candidate.
          return list(
              dict.fromkeys(
                  name for name in found if name and name.isidentifier() and not name.startswith("_")
              )
          )


      errors = []
      module = None
      for name in candidate_modules(package):
          try:
              module = importlib.import_module(name)
          except BaseException as exc:
              errors.append(f"{name}: {type(exc).__name__}: {exc}")
              continue
          if dir(module):
              break
      if module is None:
          print(json.dumps({"error": "; ".join(errors) or f"nothing importable for {package}"}))
          raise SystemExit(0)
      # The module's own name, not the distribution's: it is what a caller writes in an
      # import, and what `belongs` below has to match against.
      package = getattr(module, "__name__", package)


      def belongs(obj):
          """Whether this object is the module's own, re-exported or not.

          `obj.__module__ == package` is the obvious test and the wrong one: `httpx`
          re-exports `Client` from `httpx._client`, so the strict form drops the single
          most important class in the package and reports a release that changed
          nothing. A submodule of the package is the package's surface, and a name
          exported from the top level is public whatever module defines it.
          """
          name = getattr(obj, "__module__", "") or ""
          return name == package or name.startswith(package + ".")


      def params_of(obj):
          try:
              signature = inspect.signature(obj)
          except (ValueError, TypeError):
              return None
          found = {}
          for name, parameter in signature.parameters.items():
              if name in ("self", "cls") or name.startswith("_"):
                  continue
              if parameter.kind in (parameter.VAR_POSITIONAL, parameter.VAR_KEYWORD):
                  continue
              found[name] = {"required": parameter.default is parameter.empty}
          return found


      inventory = []
      for attribute in dir(module):
          if attribute.startswith("_"):
              continue
          obj = getattr(module, attribute)
          if not belongs(obj):
              continue
          if inspect.isclass(obj):
              # `params` may be None: a C extension's signature is not always readable.
              # The name is recorded anyway, because the name is what a caller imports
              # and what a later release can take away — dropping it here would make
              # every unreadable signature invisible to the symbol pass, which is
              # exactly the kind of export whose removal is hardest to notice.
              inventory.append({"name": attribute, "kind": "class", "params": params_of(obj)})
          elif inspect.isfunction(obj):
              inventory.append({"name": attribute, "kind": "function", "params": params_of(obj)})

      with open(out, "w") as handle:
          # The resolved import name travels with the entries, because it is what every
          # later call site has to write. `import pyyaml` does not work, and a probe
          # built from the distribution name would report a package that cannot be
          # imported by anybody — which is this bug, one layer down.
          json.dump({"module": package, "entries": inventory}, handle)
    PY

    # A dotted reference read as a *path*: `sqlalchemy.sql.schema.IdentityOptions` is an import
    # and an attribute, and the two halves are not interchangeable — a module that does not exist
    # raises ModuleNotFoundError while a name that does not raises AttributeError, and a reader
    # needs to know which one happened.
    DOTTED_SOURCE = <<~'PY'
      import importlib, sys

      module_name, attribute = sys.argv[1].rsplit(".", 1)
      module = importlib.import_module(module_name)
      getattr(module, attribute)
    PY

    # The value a probe passes for the argument under test. A placeholder because it never
    # reaches the callable: `proxies=` is refused while the arguments are still being bound, so a
    # real URL would change nothing about the failure and a validating release could refuse the
    # value on a side issue. A release that *accepts* the name will often fail later for its own
    # reasons, which is why acceptance is judged by the absence of a refusal naming the parameter
    # rather than by a clean exit.
    PLACEHOLDER = "_marker"

    # pip's own words for "this release cannot be had on this machine". A list of specific
    # messages rather than a rule, and deliberately short, because the two mistakes are not
    # symmetric: everything unrecognised counts as *transient*, so a misread costs one retry,
    # while a wrong "permanent" drops every pair that needs the release until the record expires.
    # A build that failed for want of 200 MB of disk is a build that works a minute later, and one
    # that failed because the release is not on the index never will.
    PERMANENT_BUILD_FAILURES = [
      "no matching distribution",     # the version is not on the index at all
      "could not find a version",     # the same, in an older pip's words
      "failed building wheel",        # an sdist with no wheel and nothing to build it
      "failed to build installable wheels",
      "metadata-generation-failed",   # the build backend could not even be asked
      "requireddependencyexception",
      "invalid syntax",               # a release this interpreter cannot parse
      # What pip actually prints when a build *step* fails, which is where most of these end:
      # `aiofile 3.0.0` declares `python_requires >=3.5.*`, so pip cannot even generate its
      # metadata, and the output is `error: subprocess-exited-with-error` /
      # `× Getting requirements to build wheel did not run successfully` /
      # `note: This error originates from a subprocess`. None of those is the wheel message
      # above, so the first version of this list classified a metadata failure as transient and
      # paid three attempts per crossing for it.
      #
      # The one shape this misreads is a build that failed because the *index* could not serve a
      # build dependency — that is transient, and it is recorded as permanent until the
      # interpreter changes. The alternative is worse: everything unrecognised keeps three
      # attempts, and a metadata failure is not a network blip.
      "subprocess-exited-with-error",
      "did not run successfully",
      "error originates from a subprocess"
    ].freeze

    # The prefixes pip and `gem` use to announce a failure, which is how the reason is found
    # without a list of their messages. Both print one line per dependency that installed
    # cleanly, so the head of a failed install is news that other things worked, and both end
    # with paperwork rather than the reason — for `gem`, `Results logged to …`; for pip,
    # `note: This error originates from a subprocess`. The lines that begin with one of these are
    # the announcements in between, and they are captured from real runs rather than imagined:
    # `ERROR: Failed to build gem native extension.`, `error: subprocess-exited-with-error`,
    # `× pip subprocess to install build dependencies did not run successfully.`
    FAILURE_PREFIXES = ["ERROR:", "error:", "×"].freeze

    # Two spellings, because `module.name` and `from module import name` are two ways to ask
    # and a caller may have used either — and both name the attribute, which is what is
    # checked rather than the general message.
    REFUSED_SYMBOL = ["has no attribute", "cannot import name"].freeze

    REFUSED = "unexpected keyword argument"

    # The marker a signal-killed probe carries. A child the kernel killed is reported as a
    # *negative* status and such a process usually writes nothing, so its output has to name the
    # kill or `resolves?` — which is `output.strip.empty?` — reads the empty string as "the call
    # resolved". It is listed in `UNREACHED` below, which is the third answer: a probe that did
    # not get to run is not evidence about anything.
    KILLED_MARKER = "KILLED BY SIGNAL"

    # What a probe says when the release never got to answer for itself.
    #
    # This is the third answer a probe can give, beside "refused" and "resolved", and leaving it
    # in the same bucket as "resolved" cost a verifier its credibility in its first hour: a
    # package whose install was still running raised `ModuleNotFoundError`, `refused_symbol?`
    # said no, and the vote cast was "did_not_reproduce" against a report that was true. The
    # distinction is the same one `MinerError` draws one layer up — a probe that could not be
    # made is not evidence about anything — and it has to be drawn here too, because by the time
    # the output is a string the two answers look alike.
    #
    # The kill marker is in the same bucket for the same reason: a process the kernel ended exits
    # negative and usually writes nothing, and without the marker that empty output reads as a
    # *resolved* reference — the opposite of what happened. `probe_output` is what puts the kill
    # into the string.
    UNREACHED = ["TIMEOUT", "ModuleNotFoundError", "No module named", KILLED_MARKER].freeze

    # How long an install may take, priced from the bytes it has to move.
    #
    # `INSTALL_TIMEOUT` was a flat five minutes, and the tail of the top-thousand is
    # machine-learning releases whose wheels are hundreds of megabytes. Measured on this
    # deployment: the miner pulls about 2.8 MB/s across six workers, so each has roughly half a
    # megabyte a second, and a 688 MB `nvidia-cudnn` wheel needs some twenty-five minutes — it
    # could never fit in five, and it never did. What made that expensive rather than merely slow
    # is that a killed install keeps *nothing*: measured here, a download aborted after six
    # seconds left the pip cache holding 1,892 bytes of metadata, while the same download allowed
    # to finish put 38.2 MB in it. So every attempt paid the whole deadline and threw away every
    # byte it had moved, once per attempt and once per crossing that shares the release — 62
    # installs in three hours, close to a third of the miner's worker-seconds.
    #
    # So the deadline is derived from the quantity the cost is actually spent in — bytes —
    # divided by the share of the link a worker can expect, because six workers pulling at once
    # is exactly what makes each of them too slow. Every input is an estimate and the asymmetry
    # is deliberate, the same one `MinerError.permanent` draws: too long costs an idle worker,
    # too short costs the whole download.
    #
    # `attempts` is the other half. Only a release's *own* files are priced here, because those
    # arrive with the history the miner already fetches; a release that is small itself and pulls
    # a large tree is under-priced on the first attempt, and having run out of time is the
    # evidence. Retries double, up to the ceiling.
    def self.install_deadline(payload_bytes, rate:, workers:, attempts: 0)
      base = if payload_bytes && payload_bytes.positive?
        share = [(rate || 0.0) / [workers, 1].max, MIN_INSTALL_SHARE_BYTES_PER_SECOND].max
        priced = payload_bytes / share
        [[INSTALL_TIMEOUT, priced].max, MAX_INSTALL_TIMEOUT].min
      else
        # Nothing said how large the payload is. Keep the flat floor rather than inventing
        # a number: this is the behaviour the miner had before any of this.
        INSTALL_TIMEOUT
             end
      base = [base * (INSTALL_RETRY_FACTOR**attempts), MAX_INSTALL_TIMEOUT].min if attempts.positive?
      base.to_i
    end

    # One release, spelled the way a reader checks it and the ledger keys it.
    #
    # Delegated to `Errors.release_of`, which is the one home for the spelling: the ledger, the
    # verifier and both installers have to agree about it, and a stamp written as `wrapt 1.13.3`
    # and read as `wrapt-1.13.3` is a fact that never expires.
    def self.release_of(package, version) = Errors.release_of(package, version)

    # Whether pip's own output says this failure will repeat.
    #
    # Read from the whole output rather than from the three lines that travel into the error
    # message: pip puts its reason above its conclusion often enough to matter.
    def self.cannot_be_built?(output)
      lowered = output.to_s.downcase
      PERMANENT_BUILD_FAILURES.any? { |marker| lowered.include?(marker) }
    end

    # The lines of an installer's output that say why it failed.
    #
    # Taking the end of the output is not enough, which the live ledger showed: a record of
    # `rubyXL 3.3.33` reading `could not install …` said `Successfully installed rexml-3.4.4`,
    # because the caller cut the message to two hundred characters from the front and the head is
    # a list of what worked; and the same cut taken from the back says `Results logged to …`,
    # which is where the installer put its notes rather than why it stopped.
    #
    # So the announcements are what is kept, and `limit` of them: at most three, which fits
    # inside the two hundred characters a record stores, and one for the case where an installer
    # said nothing in the shape this recognises — a reason is worth more than an empty field even
    # when it is a guess at which line is the reason.
    #
    def self.failure_reason(output, limit: 3)
      lines = output.to_s.strip.split("\n").map(&:strip).reject(&:empty?)
      announced = lines.select { |line| FAILURE_PREFIXES.any? { |prefix| line.start_with?(prefix) } }
      (announced.empty? ? lines.last(limit) : announced).first(limit).join(" / ")
    end

    # Delete least-recently-used environments until they fit the budget.
    #
    # Returns (environments removed, bytes freed), so a cycle can say what it did rather than
    # silently making room. Size is measured rather than assumed: the point is a bound on the
    # disk, and an estimate that is close is an estimate that is over sometimes.
    def self.prune(home, budget: ENV_BUDGET_BYTES, quiet: ENV_QUIET_SECONDS)
      return [0, 0] unless home.exist?

      entries = []
      total = 0
      home.children.each do |child|
        # A leading underscore is this module's own scratch naming (`_inventory`, `_moved`), and
        # those live *inside* an environment rather than beside one — the check is kept because
        # the rule is about what a directory here means, not about what happens to be present.
        next if !child.directory? || child.basename.to_s.start_with?("_")

        begin
          size = directory_size(child)
        rescue SystemCallError
          next
        end
        total += size
        entries << [child.mtime.to_f, child, size]
      end
      return [0, 0] if total <= budget

      now = Time.now.to_f
      removed = 0
      freed = 0
      # Oldest first, which is the whole policy: an environment is only worth keeping while
      # something is about to use it.
      entries.sort_by { |modified, _path, _size| modified }.each do |modified, path, size|
        break if total - freed <= budget
        next if now - modified < quiet

        begin
          FileUtils.remove_entry(path)
        rescue SystemCallError
          next
        end
        # The environment is gone, so its lock is dead weight in a registry that would otherwise
        # grow with every environment this process ever built.
        forget_lock(path)
        removed += 1
        freed += size
      end
      [removed, freed]
    end

    # The disk this occupies, which is blocks and not the lengths of its files.
    #
    # `st_size` is what a file's contents measure; `st_blocks` is what the filesystem set aside
    # for them, and inside a virtual environment the two are about ten percent apart — thousands
    # of small modules, each rounding up to a 4 KiB block. The difference is not academic here,
    # because the budget is a bound on a *disk*: measuring the other number lets the cache sit
    # over its budget while `prune` reports it under and deletes nothing. Measured on this
    # deployment, the verifier's 9.1 GB of environments summed to 8.2 GB of file lengths, which
    # is just inside an 8 GiB budget — so the one number that decided whether anything was
    # deleted was the one that was wrong.
    #
    # Symlinks are skipped rather than followed, which is the same rule as before and still
    # load-bearing: `lib64` is one, and it points at a directory already counted.
    def self.directory_size(path)
      total = 0
      path.glob("**/*").each do |entry|
        next if entry.symlink?

        begin
          info = entry.stat
        rescue SystemCallError
          next
        end
        # A filesystem that does not report allocation falls back to length, which under-measures
        # for the reason above — the same reading this had before, rather than a crash over a
        # statistic some platform omits. Ruby has no `st_blocks` on every platform either.
        total += info.respond_to?(:blocks) ? info.blocks * 512 : info.size
      end
      total
    end

    # Where pip unpacks, resolved the way the process was actually told to.
    #
    # `TMPDIR` when it is set, because that is what pip reads; otherwise this client's own `tmp`
    # under its home. The two have to agree, and the way they disagree is a sweep that measures
    # one directory while pip fills another — reporting success and bounding nothing, which is
    # the same failure `WheelCache.cache_dir` documents.
    def self.scratch_dir(home)
      configured = ENV["TMPDIR"].to_s
      configured.empty? ? home + "tmp" : Pathname.new(configured)
    end

    # Put pip's scratch on the volume instead of in RAM, and return where.
    #
    # Set here rather than in the entrypoint because this is where the home is decided: a client
    # started by hand, or by a test, gets the same scratch directory as one started by the
    # image's entrypoint, and neither can drift from what `scratch_dir` will later sweep.
    #
    # Only when `TMPDIR` is absent — an operator who has pointed it somewhere is making a
    # decision this has no business overruling, and the sweep follows whatever they chose.
    def self.use_scratch_dir(home)
      root = scratch_dir(home)
      ENV["TMPDIR"] = root.to_s unless ENV.key?("TMPDIR")
      # A scratch directory that cannot be made is pip's problem to report, and it reports it far
      # better than a startup that refuses to run would.
      begin
        FileUtils.mkdir_p(root)
      rescue SystemCallError
        nil
      end
      root
    end

    class << self
      # Where a release's own code is allowed to write, once `use_probe_home` has said so. `nil`
      # is the library used directly or by a test: those have no volume to point at, and inherit
      # the process environment as they did before this existed.
      #
      attr_accessor :probe_home
    end

    # Give the code under test a `~` it can write to, and return where.
    #
    # `HOME` in this container is `/home/miner`, on a **read-only** root: the only writable mount
    # is the cache volume, and it sits *below* that home rather than over it. So a release that
    # reads and rewrites its settings while it imports — `~/.config`, `~/.mem0`, `~/.local`,
    # which is what `platformdirs` and everything built on it do — dies with
    # `OSError: [Errno 30] Read-only file system`. And `inventory` records a failure to import as
    # a permanent fact about the *release*, so the pair is settled for good. Measured on the live
    # ledger when this was written: fifteen pairs, across `crewai`, `mem0ai`, `mini-swe-agent`,
    # `langgraph` and `apache-airflow`, every one of them on its first attempt — the AI-agent
    # packages this corpus is most about, dropped without being examined.
    #
    # Set at the one place the home is decided, beside `use_scratch_dir`. It is *not* a change to
    # the process's own `HOME`: the miner's paths come from the home the CLI resolves, and a
    # process-wide `HOME` is one refactor away from moving the ledger — which is state, not a
    # cache — out from under the next run. This reaches the subprocess that runs release code,
    # and nothing else.
    def self.use_probe_home(home)
      self.probe_home = home + "probe-home"
      begin
        # A home that cannot be made is the failure this already was; pip and the interpreter
        # report it far better than a startup that refuses to run.
        FileUtils.mkdir_p(probe_home)
      rescue SystemCallError
        nil
      end
      probe_home
    end

    # The environment a subprocess running release code is given, or `nil`.
    #
    # `XDG_*` is deliberately left alone: unset, every `platformdirs` lookup falls back under
    # `HOME`, and setting them by hand here would be a second copy of a rule this container has
    # nowhere else.
    def self.probe_env
      return nil if probe_home.nil?

      ENV.to_h.merge("HOME" => probe_home.to_s)
    end

    # Remove the scratch of installs that are gone, and say how much that was.
    #
    # pip removes its own scratch on the way out and cannot do it when it is killed, so what is
    # left here belongs to a process that will never come back for it. Nothing live is at risk
    # for the reason the threshold is derived from: an install that had been running longer than
    # `INSTALL_TIMEOUT` has already been killed, so age alone separates an orphan from a working
    # directory.
    #
    # Whole entries and not files inside them — pip names each one for the install that owns it,
    # and a half-removed one is not a state anything should have to interpret.
    def self.sweep_scratch(root, older_than: SCRATCH_ORPHAN_SECONDS)
      return [0, 0] unless root.exist?

      now = Time.now.to_f
      removed = 0
      freed = 0
      root.children.each do |child|
        begin
          modified = child.lstat.mtime.to_f
        rescue SystemCallError
          next
        end
        next if now - modified < older_than

        begin
          if child.directory? && !child.symlink?
            size = directory_size(child)
            FileUtils.rm_rf(child)
          else
            size = child.lstat.size
            child.unlink
          end
        rescue SystemCallError
          next
        end
        removed += 1
        freed += size
      end
      [removed, freed]
    end

    # A built environment for one release of one package.
    Env = Data.define(:package, :version, :root) do
      def python = root + "bin" + "python"

      # Run a script in this environment, never raising on its failure.
      #
      # A non-zero exit is the *point* of most of these runs, so it is returned rather than
      # raised. Only a timeout is an error, and the caller reports it as one, because "it did not
      # finish" is not evidence of a break.
      #
      # The working directory is the environment's own root, and the environment is the probe
      # environment: a release that writes a relative path (`langgraph` creates `.langgraph_api`)
      # or touches `~/.config` on import is otherwise refused by this container's read-only root,
      # which reads as a permanent fact about the release. See `use_probe_home`.
      def run_script(argv, timeout: RUN_TIMEOUT)
        Envs.run_captured([python.to_s, *argv], timeout: timeout, cwd: root, env: Envs.probe_env)
      end
    end

    # One lock per environment path, so two workers cannot build the same one twice.
    #
    # The service examines several releases at once, and two crossings of one package share a
    # version — `1.0->2.0` and `2.0->3.0` both need `2.0` — so the same directory is asked for
    # by two threads at the same moment.
    #
    # The registry is guarded by its own lock for the instant it takes to hand one out; the
    # per-path locks are what serialise the work.
    #
    # `Style/MutableConstant` is disabled rather than satisfied: the constant is the registry
    # itself, written by `lock_for` and deleted by `forget_lock`, and freezing the literal would
    # raise on the first `LOCKS[key] ||= …`. What makes that safe is `LOCKS_GUARD` beside it, not
    # immutability.
    LOCKS = {} # rubocop:disable Style/MutableConstant
    LOCKS_GUARD = Mutex.new

    def self.lock_for(root)
      key = root.to_s
      LOCKS_GUARD.synchronize { LOCKS[key] ||= Mutex.new }
    end

    # Drop the lock for an environment that no longer exists.
    #
    # The registry is keyed by environment path and would otherwise grow for the life of the
    # process — one entry for every environment ever built, including every one `prune` has since
    # reclaimed. Called only from `prune`, which runs between cycles where no install is live, so
    # no holder can be waiting on the entry; a path that comes back simply gets a fresh lock,
    # which is the same state a new process starts in. Not called from a failed `build`, where
    # the builder still holds the lock and another worker may be queued on it — forgetting it
    # there would hand out a second lock for a live path.
    def self.forget_lock(root)
      LOCKS_GUARD.synchronize { LOCKS.delete(root.to_s) }
    end

    # A virtual environment with exactly this package at exactly this version.
    #
    # Reused when it already exists: installing a wheel is the slowest thing here by an order of
    # magnitude, and a run that re-derived its environments would spend its time in pip rather
    # than in finding anything.
    #
    # Serializable per environment rather than globally: two workers building *different*
    # environments is the parallelism this exists to allow, so the lock is on the directory
    # rather than around the whole function.
    #
    # The lock is taken on *every* call, including the ones that find the environment already
    # there. Measured in the verifier's first hour: five reports contradicted and a dozen
    # pairs skipped this way, and the pairs that were skipped are the ones the miner is built
    # to examine.
    #
    # A build that *failed* leaves the same fossil, permanently: pip killed by the install
    # timeout, or the worker by the memory limit, leaves a directory holding an interpreter
    # and half a dependency tree. Nothing distinguishes that from a finished environment by
    # looking for `bin/python`, so it is handed out for ever and every probe reports the
    # package as unimportable — `xgboost 2.1.4` and `pyspark 3.3.4` sat in this state, and
    # four reports that could not be checked without them were the only unconfirmed reports in
    # the corpus. So the test is `installed?`: the interpreter, and something in it that is
    # not pip or setuptools. A directory that fails it is removed and built again rather than
    # completed, because a half-done install leaves a dependency tree pip will not revisit.
    #
    # `deadline` is how long the install may take, and it is the caller's to set because only the
    # caller knows what this release costs to download — see `install_deadline`. The wait for room
    # under any configured download ceiling happens here rather than at each call site, because
    # this is the only thing in the image that pulls bytes.
    def self.build(package, version, home:, deadline: INSTALL_TIMEOUT)
      root = home + "#{package}-#{version}".tr("/", "_")
      lock_for(root).synchronize do
        # Inside the lock, so "the environment exists" means the builder has finished rather than
        # that it has started. The second thread to arrive finds the environment the first one
        # just finished, which is the entire point, and the cost of asking is a directory
        # listing.
        return Env.new(package: package, version: version, root: root) if installed?(root)

        FileUtils.rm_rf(root) if root.exist?
        FileUtils.mkdir_p(root.parent)
        begin
          checked([Machine.interpreter, "-m", "venv", root.to_s],
            what: "venv for #{package} #{version}")
          install(
            [
              (root + "bin" + "pip").to_s,
              "install",
              "--quiet",
              "--disable-pip-version-check",
              # Setuptools first, and not because a build needs it: an environment with no
              # `pkg_resources` is not the environment a caller has. `markdown 3.1.1`,
              # `markdown 3.0.1` and `jaraco-classes 1.3` import `pkg_resources` at runtime,
              # and a `python -m venv` has installed no setuptools at all since 3.12 — so
              # three releases were reported as unimportable here and are perfectly importable
              # everywhere a real user would run them.
              #
              # The exception to "exactly this package at exactly this version", deliberately,
              # and it has to be a *deliberate* one: without the comment above, the next reader
              # sees a package installed beside the one under test and removes it as noise. Pip
              # resolves the two together, so a release that pins setuptools still gets the
              # version it asked for.
              "setuptools",
              "#{package}==#{version}"
            ],
            what: "install #{package}==#{version}",
            timeout: deadline
          )
        rescue Errors::MinerError => exc
          # A build that failed leaves nothing behind. Without this, an install killed by its own
          # timeout — which is what a release with a gigabyte of CUDA dependencies does — left a
          # directory holding an interpreter and a few of its dependencies, `installed?` saw a
          # non-pip `.dist-info` in it and called it finished, and every probe against that
          # release reported it as unimportable for ever. Three `xgboost` reports could not be
          # confirmed because of it, and the answer was to try again rather than to hand out the
          # wreckage.
          FileUtils.rm_rf(root)
          # The release is named here rather than at the raise, because this is the frame that
          # knows which release the build was for and every caller above wants it: a release that
          # cannot be built is one fact, and settling it per pair makes eleven other crossings of
          # the same package ask pip the same question again.
          #
          raise Errors::MinerError.new(exc.message, permanent: exc.permanent?,
            release: release_of(package, version))
        end
      end
      Env.new(package: package, version: version, root: root)
    end

    # Remove a probe's own files, and never raise for it.
    #
    # A probe's script and its receipt belong to the *run*, not to the environment: two workers
    # share one environment, so the files are named for the examination and can never be shared,
    # and nothing reads either of them once the interpreter has printed. Leaving them behind grew
    # an environment's directory with every examination that had ever used that release, and
    # `sweep_scratch` looks in `TMPDIR` rather than here, so nothing else was ever going to
    # collect them.
    #
    # Never raising is half the point: this runs on the failure paths too, and a probe that could
    # not tidy up is not a reason to lose the pair.
    def self.drop(*paths)
      paths.each do |path|
        path.unlink if path.exist?
      rescue SystemCallError
        nil
      end
    end

    # Where the newer release still exports these names, if it does.
    #
    # Answers with the whole dotted path a caller would write — `wsproto.events.Event` rather
    # than `wsproto.events` — because that is what the report has to hand over and a module on
    # its own is not an import that works.
    #
    #
    # Failure returns nothing rather than raising. The pass is an improvement on a finding that
    # is already true, so a release whose submodules cannot be walked leaves the report saying
    # "removed", which is what it said before.
    def self.moved(env, module_name, names, suffix: "")
      return {} if names.nil? || names.empty?

      script = env.root + "_moved#{suffix}.py"
      names_path = env.root + "_moved_names#{suffix}.json"
      out = env.root + "_moved#{suffix}.json"
      script.write(MOVED_SOURCE)
      names_path.write(JSON.generate(names.uniq.sort))
      out.unlink if out.exist?
      begin
        env.run_script([script.basename.to_s, module_name, names_path.basename.to_s,
                        out.basename.to_s])
      rescue TimedOut
        drop(script, names_path, out)
        return {}
      end
      unless out.exist?
        drop(script, names_path, out)
        return {}
      end
      begin
        payload = JSON.parse(out.read)
      rescue JSON::ParserError
        drop(script, names_path, out)
        return {}
      end
      drop(script, names_path, out)
      payload.is_a?(Hash) ? payload : {}
    end

    # Whether this directory holds a finished environment, not the remains of one.
    #
    # Two facts, and the second is the one that was missing: there is an interpreter, and
    # something was installed into it that is neither pip nor setuptools. Every virtual
    # environment has pip, so "a `.dist-info` that is not pip's" was the first version of this
    # test; `build` now installs setuptools as well, which makes the pair of them the tooling
    # rather than the subject — and a build killed halfway leaves setuptools in place, so counting
    # it would hand out exactly the wreckage this test exists to catch, with the package missing
    # from it.
    #
    # Not a marker file written on success, which was the obvious design and the wrong one:
    # several hundred environments already exist without it, and a completeness test that failed
    # for all of them would rebuild every one of them once — hours of pip to answer a question
    # the directory itself answers.
    #
    # The limit is a *partially* installed environment: dependencies in place, the package itself
    # not. That is rarer than the fossil this catches, and it degrades into a probe that never
    # reaches the release, which casts no vote rather than a wrong one.
    def self.installed?(root)
      return false unless (root + "bin" + "python").exist?

      tooling = ["pip-", "setuptools-", "wheel-"]
      root.glob("lib/python*/site-packages").any? do |site|
        site.children.any? do |entry|
          entry.basename.to_s.end_with?(".dist-info") &&
            !tooling.any? { |prefix| entry.basename.to_s.start_with?(prefix) }
        end
      end
    end

    # Run pip inside one download slot.
    #
    # The slot is a ceiling on how many installs download at once, which is the only lever a
    # userspace process has: pip reads as fast as its socket allows and offers no rate control,
    # so slowing one down is not available and slowing the *number* of them is. Taken around the
    # install and not around the whole build, because creating the virtual environment fetches
    # nothing. See `Bandwidth::Throttle`, including the measurement that showed delaying starts
    # instead does not work.
    def self.install(argv, what:, timeout: INSTALL_TIMEOUT)
      Bandwidth.download_slot { checked(argv, what: what, timeout: timeout) }
    end

    # Run one command, and turn its exit into an error with the caller's own sentence.
    #
    # The reason each branch reports what it does is in the branches: a negative status is the
    # kernel, which says nothing about the release, while a bare non-zero is the installer's
    # own verdict and may be permanent.
    def self.checked(argv, what:, timeout: INSTALL_TIMEOUT)
      begin
        result = run_captured(argv, timeout: timeout, env: probe_env)
      rescue TimedOut
        # Transient by construction: a timeout is this machine's patience running out, not the
        # release being unavailable — `sglang` and `xgboost` install gigabytes and reach the
        # ceiling on a busy host.
        raise Errors::MinerError.new("timed out trying to #{what}")
      end
      if result.status.negative?
        # Transient, and the asymmetry with `cannot_be_built?` below is the point: a negative
        # code is the kernel killing this process — a memory limit under a large install, or a
        # SIGKILL on redeploy — which says nothing about the release. Read as permanent, it would
        # drop every crossing that shares this release until the interpreter changes.
        raise Errors::MinerError.new("could not #{what}: killed by #{kill_reason(result)}")
      end
      return if result.status.zero?

      output = result.stderr.empty? ? result.stdout.to_s : result.stderr
      raise Errors::MinerError.new("could not #{what}: #{failure_reason(output)}",
        permanent: cannot_be_built?(output))
    end

    # What the module exports, and what each callable's signature accepts.
    #
    # Read from the installed release by executing code inside it, so a signature cannot be
    # stale: an inventory taken from metadata would describe what the package says about itself
    # rather than what it does.
    #
    # The distribution name is passed in and the *import* name comes back out: the environment
    # resolves one to the other, because only it can see the metadata that relates them.
    #
    # `suffix` is the examining worker's identity, for the same reason every probe takes one: two
    # crossings of a package share a release, so two workers can be reading this environment at
    # once, and the scratch files are the only thing they would have collided over. The receipt
    # is unlinked before the run, so the collision was not a wrong answer — it was one worker
    # deleting the file the other was about to look for, which reads as "this release cannot be
    # imported" and loses the pair.
    #
    # The receipt is *also* dropped once it has been read, and the script with it: see `drop`.
    def self.inventory(env, suffix: "")
      script = env.root + "_inventory#{suffix}.py"
      script.write(INVENTORY_SOURCE)
      out = env.root + "_inventory#{suffix}.json"
      # Removed first, because the file is a receipt: the snippet writes it on success and exits
      # without writing it on failure, so a leftover from an earlier run would be read as this
      # run's answer. That matters more than it looks — the failure being reported is "this
      # release cannot be imported", and a stale file would turn it into a confident inventory of
      # a release that is not there.
      out.unlink if out.exist?
      begin
        result = run_captured([env.python.to_s, script.to_s, env.package, out.to_s],
          timeout: RUN_TIMEOUT,
          # Where the release may write, for the reason `use_probe_home`
          # gives: an import that touches `~/.config` is refused by this
          # container's read-only root, and the refusal was being recorded as
          # a permanent fact about the release. The working directory is the
          # same one the probes get, because a release can write a relative
          # path too — `langgraph` creates `.langgraph_api` in it.
          cwd: env.root,
          env: probe_env)
      rescue TimedOut
        # An environment failure rather than a defect, which is what it used to be: a bare
        # timeout reached the cycle as an unexpected exception, was logged as one, and settled
        # the pair as `failed` with a note reading the exception's name — the same outcome as the
        # clear message below at three times the diagnostic cost. Transient, because a release
        # that hangs on import here may well not on the next attempt, and an attempt is a minute.
        drop(script, out)
        raise Errors::MinerError.new(
          "#{env.package} #{env.version} did not finish importing to take an inventory",
          release: release_of(env.package, env.version)
        )
      end
      if result.status.negative?
        # Transient, like the timeout above and for the same reason: the kernel killed this
        # process — memory limit, or a redeploy — so it never reached the snippet's own verdict.
        # Filed as permanent it would record "this release cannot be imported" for every crossing
        # that shares it, which is the fact the `out.exist?` branch below exists to establish and
        # this death never established.
        drop(script, out)
        raise Errors::MinerError.new(
          "#{env.package} #{env.version} was killed taking an inventory: #{kill_reason(result)}",
          release: release_of(env.package, env.version)
        )
      end
      # The receipt is this run's answer and the script is read by nothing once the subprocess has
      # printed, so both go here — before the branches below, so that every exit path has already
      # cleaned up. Doing it at one point rather than at each raise is what keeps them from
      # drifting apart.
      exists = out.exist?
      payload = exists ? JSON.parse(out.read) : nil
      drop(script, out)
      unless exists
        # Permanent, unlike the timeout above: the snippet ran and reported that this release
        # cannot be imported on this interpreter — a `SyntaxError` from a release older than the
        # interpreter, or a dependency that is not installed and is not declared. Both reach the
        # same answer in an hour.
        body = "#{result.stdout}#{result.stderr}".strip
        detail = body.empty? ? "#{env.package} #{env.version} produced no inventory"
                             : "#{env.package} #{env.version} could not be imported to take an inventory: #{body.split("\n").last}"
        raise Errors::MinerError.new(detail, permanent: true,
          release: release_of(env.package, env.version))
      end
      if payload.key?("error")
        # The snippet reached the end of its search for an importable module and found none,
        # which is the same permanent fact by a different route.
        raise Errors::MinerError.new("#{env.package} #{env.version}: #{payload['error']}",
          permanent: true,
          release: release_of(env.package, env.version))
      end

      Inventory.new(module: payload["module"], entries: payload["entries"])
    end

    # What one release exports, and the name it exports it under.
    Inventory = Data.define(:module, :entries)

    # A caller's line, as a caller would have written it.
    #
    # `module_name` is the *import* name, not the distribution name: they differ for a large part
    # of PyPI, and a call site written from the distribution name is one no caller could have
    # written — `import pyyaml` fails before the argument is ever bound, so the probe would report
    # a break in a module that does not exist.
    #
    def self.call_site(module_name, symbol, parameter)
      argument = parameter == "-" ? "" : "#{parameter}='#{PLACEHOLDER}'"
      "import #{module_name}\n\n#{module_name}.#{symbol}(#{argument})\n"
    end

    # A caller's import of one public name, as a caller would have written it.
    #
    # A bare attribute reference rather than `from package import symbol`: the two raise different
    # exceptions for the same absence (`AttributeError` against `ImportError`), and a report
    # carries the traceback a reader will actually see. The reference is the common case —
    # `numpy.float_`, `requests.packages` — and it is the one whose failure names the module and
    # the attribute, which is what makes the report findable.
    def self.symbol_site(module_name, symbol)
      "import #{module_name}\n\n#{module_name}.#{symbol}\n"
    end

    # Why each probe writes its own file name.
    #
    # Two examinations can be running inside one environment at the same time — different
    # crossings of a package share a release — and a single `call_site.py` would be overwritten
    # between the write and the run. The traceback filed as a report's evidence would then be the
    # *other* worker's call, which is a fabricated finding with a real citation. The suffix is
    # the caller's identity, and it is used for nothing else: the file stays `call_site-<n>.py`
    # so a reader still sees a file somebody could have written.
    #
    # The probe writes a *call site* and runs it, rather than calling through `getattr` from a
    # harness script. That is not tidiness: the traceback this produces is filed as the report's
    # evidence, and a harness frame would be handing a caller a stack no caller ever sees. What is
    # filed is the interpreter's own output from the interpreter's own run, so the report can be
    # reproduced by copying it.

    # The signal that ended a process, named when the platform knows it.
    #
    def self.kill_reason(result)
      number = -result.status
      "SIG#{Signal.signame(number)}"
    rescue ArgumentError
      "signal #{-result.status}"
    end

    # What a probe has to say, with a signal-killed process named rather than silent.
    #
    # A process the kernel killed — the container's memory limit under a large install, or a
    # SIGKILL after `stop_grace_period` during a redeploy — is an ordinary event here, and one
    # that writes nothing. Concatenating only stdout and stderr therefore made a killed probe
    # indistinguishable from a *working fix*: `resolves?` is `output.strip.empty?`, so the empty
    # string a kill leaves behind read as "the call resolved", and a verifier adopted a fix on
    # exactly that test. Naming the kill puts it in the third bucket instead, and says which
    # signal as a fact a reader can act on.
    def self.probe_output(result)
      body = "#{result.stdout}#{result.stderr}"
      result.status.negative? ? "#{KILLED_MARKER} #{kill_reason(result)}\n#{body}" : body
    end

    # Run one probe script, keep its output, and remove the script.
    #
    # The evidence is the interpreter's *output*, captured here — not the file that produced it —
    # so the file is finished with the moment the subprocess exits and goes on the timeout path
    # as well as the normal one. See `drop` for why an environment must not accumulate one file
    # per examination that has used it.
    def self.probe_once(env, script, argv)
      begin
        result = env.run_script(argv)
      rescue TimedOut
        return "TIMEOUT"
      ensure
        drop(script)
      end
      probe_output(result)
    end

    # Execute one public-name reference against one release, verbatim.
    def self.probe_symbol(env, module_name, symbol, suffix: "")
      script = env.root + "call_site#{suffix}.py"
      script.write(symbol_site(module_name, symbol))
      probe_once(env, script, [script.basename.to_s])
    end

    # Execute one call against one release and return what the interpreter said.
    #
    # Verbatim, including the traceback: this is the evidence, and a paraphrase of it would be
    # the miner's opinion of the failure rather than the failure.
    def self.probe(env, module_name, symbol, parameter, suffix: "")
      script = env.root + "call_site#{suffix}.py"
      script.write(call_site(module_name, symbol, parameter))
      # Named relatively so the traceback reads `File "call_site.py"` rather than the miner's own
      # scratch path: the environment's location is this machine's business, and a filed
      # traceback carrying an absolute path from somebody's tmp is noise a reader cannot act on.
      probe_once(env, script, [script.basename.to_s])
    end

    # Execute one dotted reference against one release, verbatim.
    #
    # The verifier's instrument for a *fix*: a report that says "import it from
    # `sqlalchemy.sql.schema.IdentityOptions`" has handed a caller a line to type, and whether
    # that line resolves is not a question about spelling. `moved` answers where a name is
    # defined and is bounded to a package's submodules; this answers whether a specific path a
    # report gives actually works, which is the smaller and more exact question.
    def self.probe_dotted(env, dotted, suffix: "")
      script = env.root + "dotted#{suffix}.py"
      script.write(DOTTED_SOURCE)
      probe_once(env, script, [script.basename.to_s, dotted])
    end

    # Whether a reference ran without raising anything.
    #
    # Judged on the interpreter's own output rather than on a status the wrapper could report: an
    # empty run is a reference that resolved, and anything else is a failure this caller quotes
    # instead of describing.
    def self.resolves?(output) = output.to_s.strip.empty?

    # Whether the interpreter refused *this name*, not merely failed.
    def self.refused_symbol?(output, symbol)
      REFUSED_SYMBOL.any? { |phrase| output.to_s.include?("#{phrase} '#{symbol}'") }
    end

    # Whether the interpreter refused *this parameter*, not merely failed.
    #
    # The parameter name is checked rather than the general message, because a release that fails
    # for an unrelated reason must not be recorded as having removed an argument.
    def self.refused_parameter?(output, parameter)
      output.to_s.include?("#{REFUSED} '#{parameter}'")
    end

    # Whether a probe failed before the release could answer for itself.
    #
    # A timeout, or an import that failed — the package, or something it depends on. Neither says
    # anything about the name or the argument under test, so a caller that treats either as an
    # answer is inventing one. An empty output is the opposite of this: the reference resolved,
    # which is an answer.
    def self.unreached?(output)
      UNREACHED.any? { |marker| output.to_s.include?(marker) }
    end

    # Whether a probe ran and the release answered, either way.
    #
    # The inverse of `unreached?`, named for the reading it is meant to be used at: "this probe
    # has something to say" rather than "this probe failed".
    def self.answers?(output) = !unreached?(output)

    # The interpreter's traceback, from the first frame to the exception.
    #
    # Returned rather than rebuilt. A report whose evidence was written by the miner would be a
    # claim about a failure; this is the failure.
    #
    # The one edit is stripping the environment's own directory from any path in it, which is the
    # same normalisation a build system does with a prefix map. Modern CPython absolutises the
    # script path, so without this a filed traceback would carry one contributor's home
    # directory — noise no reader can act on, and the harness's layout rather than the failure.
    # The frame, its line number, the source line and the exception are untouched; only the
    # machine-specific prefix is removed.
    def self.traceback_of(output, root: nil)
      text = output.to_s.strip
      unless root.nil?
        text = text.gsub("#{root.to_s.sub(%r{/+\z}, "")}/", "")
      end
      lines = text.split("\n")
      index = lines.index { |line| line.start_with?("Traceback (most recent call last)") }
      return text if index.nil?

      lines[index..].join("\n").strip
    end

    # The last non-blank line, which is the exception the caller has to act on.
    def self.exception_line(output)
      lines = output.to_s.strip.split("\n").reject { |line| line.strip.empty? }
      lines.empty? ? "" : lines.last
    end

    # A child process that ran out of time, or could not be started at all.
    #
    # A missing interpreter raises this too, because "this machine cannot run the command" is
    # the same fact as "it did not finish" as far as every one of those four is concerned.
    class TimedOut < StandardError
      # The exception is the Ruby index's adapter, which turns a command this machine cannot
      # start into a `MinerError` naming the command while a command that ran out of time
      # becomes that module's third answer (`timed_out`). So `started?` is the distinction,
      # and `stdout`/`stderr` carry what the child printed before its deadline, which a bare
      # `Timeout::Error` throws away — and what a killed install's output *is*.
      attr_reader :stdout, :stderr

      def initialize(message, stdout: "", stderr: "", started: true)
        super(message)
        @stdout = stdout
        @stderr = stderr
        @started = started
      end

      def started? = @started
    end

    # What a child process said and how it ended.
    Result = Data.define(:status, :stdout, :stderr)

    # The one place a child process is started, so it is the one seam a test replaces.
    #
    # `env` is the whole environment to run the child with, or `nil` to inherit this process's —
    # the shape `probe_env` returns, so an operator's `XDG_*` and `TMPDIR` reach the release code
    # untouched.
    def self.run_captured(argv, timeout: RUN_TIMEOUT, cwd: nil, env: nil)
      argv = argv.map(&:to_s)
      out_read, out_write = IO.pipe
      err_read, err_write = IO.pipe
      out_text = +""
      err_text = +""
      status = nil
      # `in: File::NULL` because a *probe* must never read the miner's stdin, where a release's
      # import could otherwise block on a prompt nobody can answer. Both installers are driven
      # non-interactively (`pip` with no tty, `gem install` the same), so this is what a container
      # already looked like; it is stated here rather than left to the terminal's absence.
      options = { in: File::NULL, out: out_write, err: err_write }
      options[:chdir] = cwd.to_s if cwd
      begin
        pid = env ? Process.spawn(env, *argv, **options) : Process.spawn(*argv, **options)
      rescue SystemCallError
        # A command this machine cannot start at all: no interpreter, no such file. It never
        # printed and never will, which `started?` is the difference for.
        [out_read, out_write, err_read, err_write].each { |io| io.close unless io.closed? }
        raise TimedOut.new(argv.join(" "), started: false)
      end
      out_write.close
      err_write.close
      readers = [Thread.new { out_text << out_read.read }, Thread.new { err_text << err_read.read }]
      timed_out = false
      begin
        Timeout.timeout(timeout) { _, status = Process.waitpid2(pid) }
      rescue Timeout::Error
        timed_out = true
        terminate(pid)
      ensure
        # Joined *before* the raise below, so what a killed install printed is carried out of here
        # rather than discarded with the exception. That output is the evidence a report quotes.
        readers.each do |thread|
          thread.join(5)
        rescue StandardError
          nil
        end
        [out_read, err_read].each { |io| io.close unless io.closed? }
      end
      if timed_out
        raise TimedOut.new(argv.join(" "), stdout: out_text, stderr: err_text)
      end

      Result.new(status: exit_status(status), stdout: out_text, stderr: err_text)
    end

    # Kill a child that ran past its deadline, and reap it.
    #
    # Reaping matters: an unreaped child is a zombie for the life of the process, and this
    # container runs for days.
    def self.terminate(pid)
      Process.kill("KILL", pid)
      Process.waitpid(pid)
    rescue SystemCallError
      nil
    end

    def self.exit_status(status)
      return -1 if status.nil?

      status.exitstatus || -status.termsig.to_i
    end
  end
end
