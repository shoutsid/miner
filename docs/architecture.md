# Architecture

## One method, two indexes

The unit of work is a **pair**: two releases of one package, `from` and `to`. The client
installs both, asks each what it exports and what its public callables accept, and executes
the same reference against both. A finding exists only when the older release accepted the
reference and the newer one refused it.

The loop is shared between PyPI and RubyGems. `Ecosystems` is the seam that holds the
differences: how a release history is read, what an install is, what a differential means,
and which cache has a budget. The service-facing loop asks the ecosystem, never the index
modules directly, so a second index is not a second copy of the loop.

## Modes

| Mode | Owner | What it does |
|---|---|---|
| `mine` | `Cli#run_once` | pair selection, differential, print only |
| `publish` | `Cli#run_once` + `Corpus` | differential, precheck, submit |
| `solve` | `CliReports` + `Corpus` | choose open reports, execute a fix, propose a resolution |
| `serve` | `Service` | queue, breadth ranking, ledger, cycles, seed, advisories, unexaminable picture |
| `verify` | `Verifier` + `Verifying` | choose unconfirmed reports, execute the claim, record a vote |

## What one differential does

1. **Select.** A supplied pair is used exactly. Otherwise the newest usable crossings of the
   package are selected, up to the ecosystem's window (twelve line crossings on this build).
   A pair the ledger has settled is not selected again.
2. **Build.** One environment per release. The environment's identity includes the package,
   the version and the machine that built it. The Python side prices its install deadline
   from the release's own payload; the Ruby side has no published size and uses a flat
   ceiling that doubles on retry.
3. **Inventory.** Execute inside each environment to ask what the release exports and what
   its public callables accept. Names whose signature cannot be read are still inventory
   entries; a native Ruby gem reports `native: true` rather than an empty surface.
4. **Differential.** Every parameter the older release had and the newer one does not is a
   candidate, and so is every exported name that disappeared. A removed name was never a
   parameter, so a signature diff alone would miss the break that stops a caller importing.
5. **Confirm.** Execute the candidate against both releases. Keep it only if the older one
   accepted it and the newer one refused it by name.
6. **Repair.** A removed argument is usually renamed. A candidate is taken from the new
   release's own signature, executed, and accepted only if it gets past the failure. A
   removed export is asked whether it was renamed (a name built from every word of the old
   name, uniquely) and then whether it moved (import the release's submodules and look for the
   definition). Spelling alone is never enough for a claim.
7. **Cluster.** Findings are grouped by mechanism, because one decision upstream should not
   become eleven reports with almost the same title.
8. **File.** `publish` asks `POST /api/reports/precheck`; a `duplicate` is not filed, a
   `similar` is filed because the service will accept it, and a `new` is filed with the
   evidence. A mined finding is never an advisory.

The traceback in a report is the refusing interpreter's own output. The report also carries
both releases in structured fields (`from_version`, `subject`, `change_kind`) as well as in
prose, so a caller can ask “what does this upgrade cross?” before the failure happens.

## The ledger

`Ledger` is durable state, not a cache:

- a **settled** pair (`done`, `empty`) is never examined again;
- a **failed** pair is retried up to three attempts;
- an **unexaminable** release is settled on the first attempt, because the first attempt
  established a fact about the release and the machine.

The machine stamp is part of the fact. A release refused because no wheel exists for
`cpython 3.12` becomes examinable when the image moves to 3.13; a gem refused because the
image has no compiler becomes examinable when one is added. The stamp is why the ledger can
expire those answers without a migration.

For reports, `proposed`, `no_mechanism`, `no_pair`, `reproduced`, `did_not_reproduce` and
`partial` are settled; `failed` retries. A verifier that cannot reach a report casts **no
vote** — not a positive one, not a negative one.

## Scheduling and the queue

The service's `GET /api/mining/targets` is the first source of work. It is computed from the
corpus's observations: unanswered reports, searches that found nothing, packages already
proven to break callers. The route pages its answer and reports `limit_max`; the client
reads every page with `offset` instead of asking for a depth the route will refuse.

The breadth ranking continues the queue up to `--top` packages. The client is the one with a
route to the outside, so it fetches the ranking and posts it as a seed; the service decides
what the seed means and when it was read. The queue comes first and the ranking extends it:
returning the ranking *instead of* the queue made the operator's depth meaningless, and
returning the queue *instead of* the ranking ran out of work with thousands of packages on
disk.

The planner orders work by demand first, then by yield, then least-recently touched, taking
one pair per package before a second pair of any. A package that has produced nothing across
three examined releases is deferred behind packages that are still paying.

## Concurrency

Only the examining is parallel. Each worker builds environments and runs probes; the cycle
thread owns the ledger, the filings and the write counter. Those are three things that would
each need locking for no speed.

`Envs.build` takes a lock **per environment path**. Two crossings of one package share a
release (`1.0->2.0` and `2.0->3.0` both need `2.0`), so two workers ask for one directory at
once; two installs into one path would leave an environment half of each, and every probe
against it would fabricate a finding. The lock is also held while the environment is being
built, not merely while the interpreter exists: an environment that exists is not an
environment that is finished.

Every probe writes its own script, suffixed with the examination's identity. A single shared
script would be overwritten between the write and the run, so the traceback filed as evidence
could be another worker's call.

## The two verifying operators

The service promotes a report to `resolved_verified` only when operators other than its
author reproduce it. The miner files its own reports, so it can never be the confirmer. Two
further services run this image under their own accounts:

- `as-reported` runs the call sites the report names, with the refused argument, then the
  fix;
- `searched` takes only the two releases and re-derives the claim.

The methods are different on purpose. If both merely repeated the report, one execution
written twice would be one opinion. A verifier whose environment could not be built returns
*unreached*, not dissent: a probe that could not be made is not evidence about anything.

## Code map

```text
bin/agents-miner             the one entry point
lib/agents_miner.rb          the loader
lib/agents_miner/
  cli.rb                         modes, flags, exit status
  service.rb                     the durable loop
  verifier.rb                    the verification loop
  planner.rb                     what to work on next
  ledger.rb                      settled pairs, reports and machine stamps
  ecosystems.rb                  the PyPI/RubyGems seam
  envs.rb                        Python environments, deadlines, scratch, budgets
  rubyenvs.rb                    gem environments and gem scratch
  mine.rb, rubymine.rb           the differentials
  versions.rb, rubyversions.rb   release histories and ordering
  corpus.rb                      the service client
  reporting.rb                   report payloads and summaries
  solving.rb, verifying.rb       report selection and claim execution
  findings.rb, pair.rb           the data the cycle moves around
  advisories.rb                  reviewed advisory leads
  watchlist.rb                   queue + ranking
  wheelcache.rb, bandwidth.rb    the shared cache and the download ceiling
  machine.rb                     the interpreter/toolchain stamp
  log.rb, errors.rb              one logger and the typed refusals
```

The client has no database driver, no database route and no `DB_PASSWORD`. Its only access to
the corpus is HTTP with an operator key. If a change would give it a database connection, the
design has gone wrong.
