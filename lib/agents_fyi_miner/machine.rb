# frozen_string_literal: true

require "open3"

module AgentsFyiMiner
  # What this machine is, as the stamp on the facts its environments establish.
  #
  # An `unexaminable` record in the ledger is a fact about a release *and* about the machine
  # that tried it, and the stamp is what expires it: the ledger stops counting a fact whose
  # machine is not this one, so the question goes back to the schedule instead of staying
  # answered by a machine that no longer exists. Two halves, and each was measured on this
  # deployment rather than assumed.
  #
  # **The interpreter.** `cpython 3.12` is what an old ledger spells, and it is half the
  # fact: an sdist with no wheel is refused because no wheel exists for this interpreter, and
  # a `SyntaxError` is a release this interpreter cannot parse. Major and minor only — wheel
  # tags are per minor version (`cp312`), so a patch upgrade changes nothing about what can be
  # installed.
  #
  # The fact the stamp records is unchanged — which interpreter a release was executed against
  # — but it is now a subprocess away, which is also why it is slow enough to read once per
  # process.
  #
  # **The toolchain.** A C extension is *not* a fact about the gem, which is what this module
  # exists to stop the ledger saying. Asked of the index rather than assumed: `prism`,
  # `bigdecimal`, `json`, `psych`, `date`, `nio4r`, `msgpack` and `racc` publish no linux
  # build at all — only `ruby` and `java` — so on a machine with `cc` and `make` they install
  # and without one they never will. `cc` names the half that a compiler decides, so adding
  # one (or moving to an image without one) re-opens every fact it covered.
  #
  # This is deliberately not a property of the process: it is read once, from the filesystem,
  # and the same strings are used to write a fact and to decide whether it still counts.
  module Machine
    # What a machine with a compiler for native extensions is stamped with, and what one
    # without is. Named rather than implied by an absent marker, because the difference is a
    # *fact about the answer*: `no-cc` is why `racc 1.8.1` cannot be installed here, and it
    # has to be visible in the record that says so.
    CC = "cc"
    NO_CC = "no-cc"

    # `PYTHON` names it so a deployment can point at a specific one, and the default is the
    # same `python3` the image's `entrypoint.sh` relies on.
    def self.interpreter = ENV["PYTHON"].to_s.strip.empty? ? "python3" : ENV["PYTHON"].strip

    # `cc` when this machine can build a native extension, `no-cc` when it cannot.
    #
    # Both halves are asked: a C compiler without `make` builds nothing, and gem's own
    # failure for it is `make failedNo such file or directory - make`. Read from `PATH`
    # rather than by compiling a test program, because the answer is a fact about what is
    # installed and a probe that runs a compiler is a probe that can fail for reasons other
    # than this one.
    def self.toolchain
      compiler = which("cc") || which("gcc")
      compiler && which("make") ? CC : NO_CC
    end

    # This machine as the Python environments' builder: `cpython 3.12 cc`.
    #
    # A machine with no interpreter at all answers `unknown` rather than raising: the stamp is
    # written into a ledger, and a miner that could not say what it is would be a miner that
    # cannot record a fact about a release it refused — on a host run that has no intention of
    # building one.
    def self.python
      "cpython #{python_version} #{toolchain}"
    end

    def self.python_version
      out, status = Open3.capture2(interpreter, "-c",
        "import sys; print('%d.%d' % sys.version_info[:2])")
      status.success? ? out.strip : "unknown"
    rescue SystemCallError
      "unknown"
    end

    def self.which(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        candidate = File.join(dir, name)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end
  end
end
