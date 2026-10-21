# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | yes |
| older | no |

The client is early. A security fix lands on the latest released minor and is not backported
unless the maintainer says otherwise in the advisory.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private vulnerability reporting for this repository
if it is enabled (Security → Advisories → Report a vulnerability). If it is not, contact
**@shoutsid** through the private contact methods on their GitHub profile and say that the report
is a security matter.

Please include:

- the version (`agents-fyi-miner --version` or the image tag);
- the operating system, Ruby version, Python version and whether a compiler is present;
- the command, mode and relevant flags;
- what an attacker can do, and what they need to start with;
- a minimal reproduction, with keys, package names and private source redacted.

You will get an acknowledgement as soon as the maintainer sees the report. There is no bug bounty
and no guaranteed response time; this is a small proprietary project.

## Scope

This client **executes third-party packages by design**. It installs releases into environments
it owns, imports them, runs probes and records the interpreter's output. A report that “a
malicious release can run code in the miner's container” is a description of the product, not a
vulnerability, unless the code escapes the boundary the deployment chose.

The boundaries worth reporting a break of:

- **The operator key.** The key is stored in the state file (mode `0600`) and sent as
  `X-API-Key`. It is a client key, never an admin token. A path that reads, logs or transmits
  the key, or that lets a package reach the service's admin surface through the client, is in
  scope.
- **The state and reports.** The client records command output and may quote it in a public
  report. A path that writes the operator key or another secret into a report, a ledger or a
  log line is in scope. A package printing its own secret is the package's leak; a redaction
  failure in the client is the client's.
- **Path handling.** A package name or version must not make the client read or write outside
  its home through a crafted path or symlink. A bypass is in scope.
- **The container posture.** The image runs as uid `10002`; a deployment should use a read-only
  root, a bounded `/tmp`, dropped capabilities and no database route. A path that writes outside
  the declared volumes or gains privileges is in scope.
- **The queue and the corpus.** A report from an untrusted source must not be able to make the
  verifier execute outside the environment it built for the report. A claim/symptom parser that
  turns report text into an arbitrary shell command is in scope.

Out of scope:

- a release's own build system or import-time code doing what it does;
- an operator who places a key, token or secret in the environment or a volume;
- denial of service from a slow package install, unless it defeats a declared deadline;
- a deployment that runs the container with extra privileges or mounts the host into it.

## Safe harbour

Do not test against a deployment you do not own, and do not use a real operator key in a
report. A proof of concept against a local service and a disposable package is enough.
