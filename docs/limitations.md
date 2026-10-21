# Limitations

This page is the honest half of the documentation. Each item is a limit of this version, not a
bug waiting to be reported.

## Execution proves a reference, not behaviour

The client executes a call shape against two releases. It does not prove that a release's
behaviour is otherwise unchanged. A release that changes what a call *does* without changing
its signature is invisible here. That is the larger half of breakage and needs a different
mechanism: a contract asserted against both releases.

An argument's value is a placeholder: binding fails before the value is read, so a break whose
*value* a release rejects is not what this finds. A removed export is a break for anyone who
imported it, but the count on such a finding is one reference, not a measure of damage.

## A rename is only found when the names share words

The repair is a name built from every word of the old name, uniquely, and it is executed
before it is claimed. It is never wrong on the evidence it has, but it misses names with no
shared word (`ResponseClosed` → `ResponseNotRead`), names that dropped a word
(`CythonMetaType` → `CythonType`), and moves deeper than the one submodule the search walks
(`litellm.parse_ocr_request_format`). Those reports are true removals; they are just less
helpful than they could be.

The symbol search deliberately refuses a public re-export (`httpx.Client` was defined in
`httpx._client`, which is not a caller's path), so a move that only exists as a re-export is
reported as a removal.

## Only releases that still install

A package whose old release needs an old setuptools, a system library or a compiler the image
does not have is recorded as unexaminable and the miner moves on. The fact is per release and
per machine, so it is worked out once; the image's interpreter and compiler are part of the
stamp, and changing either re-opens it.

Most of what cannot be examined is the environment, not the release. Of 126 unexaminable
releases in one live ledger, **40** genuinely could not be installed and **17** were not on the
index — but **52** installed and failed to import: a missing dependency, a dependency resolved
to something newer than the release can work with, or a setuptools-era import. An environment
of the release's *era* — constraining dependencies to the versions that existed when it was
published — is the next real reach. It is a design change, not a bug fix, and it would make
findings that nobody can reproduce today unless the constraint is recorded in the report.

## Module-level names, not instances

A method removed from a class, or an instance attribute that stopped existing, is not
reachable yet: the inventory describes classes and functions, not what an instance offers once
it is constructed. `Mechanism` declares only what a pass actually establishes.

## Ruby's limits

The Ruby client compares **keyword** parameters. Positional parameters are checked by
position, so “the argument at index 2 changed name” is not a question a placeholder can ask.
C extensions have no Ruby source, so a gem like `json` reports no surface at all; the inventory
says `native: true` rather than reporting an empty gem. A native gem with no precompiled build
needs a compiler, and RubyGems publishes no file size to price an install deadline from, so
the deadline is a flat ceiling that doubles on retry.

A gem's argument claim is never filed and never checked. The keyword pass reads a method's
parameters, not a call-site analysis, so the client files symbol findings only; the verifier
reads a gem report only when its `change_kind` is a symbol one.

A family of Ruby removals can collapse into one report. `Bundler::CurrentRuby#ruby_35_21?`,
`#ruby_35_25?`, `#mri_35_25?` and four more differ by a digit, and the duplicate rule reads a
near-identical title as one problem unless identifying symptoms disagree. The corpus's symptom
extractor reads dotted names, so `Bundler::CurrentRuby#ruby_35_21?` indexes as prose rather
than a symptom. Fixing it means indexing Ruby reference spellings (`Foo::Bar`, `Foo::Bar.baz`,
`Foo::Bar#baz`) as symptoms — an API change with a backfill, not a miner change.

The one-shot `mine` and `publish` modes are PyPI-only in this build. RubyGems is worked by
`serve` and by `verify`; a standalone one-shot Ruby run is not implemented.

## The queue is read once, at startup

`serve` reads `/api/mining/targets` once before the worker loop, and the planner only sees that
snapshot. A newly opened report is still prioritised immediately, because the demand half is
recomputed from the change feed every cycle; the breadth order is not. A running process picks
up a new breadth order only on restart. Re-reading on a slow cadence is the fix if the breadth
order has to move under a running process.

An empty queue and a paused queue are different answers. The client raises on the paused one
rather than treating it as empty. A queue that is merely stale is not distinguishable from one
that is finished from inside the loop; the cycle names its reasons and the ledger names its
settled count.

## Cached histories are parsed twice

`versions.history_is_cached` reads and parses the cached version and date documents to decide
whether a fetch is needed, and `release_history` reads and parses the same two files to return
the history. Caching the parse is left out because it has to be keyed on the file's mtime to
stay correct after a fetch rewrites it — more machinery than the cost currently earns.

## Verification is independent execution, not independent parties

Both verifiers are automated, run by this machine, and registered as separate operators. What
the corpus's two confirmations mean here is “two independent executions, by different methods,
neither by the author” — not “two parties”. Evidence travels with each vote, so a reader can
see exactly what each one ran and decide how much that is worth. A second *party* would need
somebody else to run one of these against the public API, which is a distribution problem
rather than a code one.

A verifier that cannot check a report casts no vote. That is deliberate: a dissent is a claim
about the release, and an environment that would not install is a fact about this machine.

## No service means no publish, solve, serve or verify

`mine` with an explicit pair works from the index alone. `publish`, `solve`, `serve` and
`verify` need the service; there is no offline corpus and no local copy of the queue. The
default is the public deployment, and a self-hosted service is named with `--base-url`.

The miner never reads a changelog, a source diff or a version string as evidence. It never
files into an empty corpus without the precheck, and it never reports a “repair” it did not
execute.

## The image and the host

The client runs in a Linux container. It executes untrusted third-party packages by design,
so the deployment's read-only root, non-root user, caps and memory limits are the boundary. It
does not protect the host from a kernel or interpreter exploit.

The image is large because it carries two interpreters and a compiler; that is the trade for
examining native gems and old Python releases rather than recording them as unbuildable.
`/tmp` is bounded and pip's scratch is on the state volume; a deployment that drops the volume
loses both the cache and the ledgers.

## The corpus is public

A report filed by this client is a public report, including the exception line and the command
it ran. A package that prints a secret in its own output can put that secret in the corpus;
the client does not redact what the package prints. Review a report before treating the output
as safe to share.

## The license is proprietary

This repository is public but not open source. No use, copying, modification, publication,
distribution, sublicensing or sale is permitted without prior written permission. See
[LICENSE](../LICENSE). “Public” here means readable, not licensed for reuse.
