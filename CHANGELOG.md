# Changelog

All notable behaviour changes are recorded here. The client follows semantic versioning for
its image and its command line.

## [Unreleased]

### Changed

- **Bisection follows demand, and its budget is per crossing.** A pair a caller asked for gets
  `BISECT_PROBES` (now `8`) installs; one that an advisory lead or an open report put in the plan
  gets two; a ladder crossing nobody has asked about gets none and keeps the window the
  differential proved. The planner stamps the demand on the pair, so the budget is decided where
  the work is chosen rather than inside the search.

### Added

- **A runnable reproduction of the comparison.** A finding now carries the reference its probe
  executed (`Finding#expression`), and `AgentsMiner::Reproduction` writes that comparison out — the
  release, the script, the command and the exception the newer release raised. Before it is recorded
  the miner **re-runs it in the release's own environment** and compares the exception, so a record
  that names a command is one the miner actually ran (`verified: true`, with what it `observed`); a
  record that did not reproduce is downgraded to the description form rather than filed as runnable.
  A behaviour comparison reads a value and calls nothing, so it has no expression and is a
  description from the start. The record rides the pair's `differential` cell and round-trips through
  the ledger (`PairRecord#reproduction`).
- **A caller's examination request is read as work.** `GET /api/mining/requests` is read every cycle
  (`Corpus#examination_requests`, `Service#refresh_examination_requests`), and the planner adds the
  exact `(from, to)` window the request names — ahead of the ladder's own crossings, because the
  request names the move — and weights the package above a reviewed advisory's lead and below an
  open report (`REQUEST_BONUS = 0.75`). A request the ledger has already settled is not work. The
  client never reports the satisfaction: the service marks a matching request satisfied when the
  examination for the same window is recorded.
- A verifier executes the claims somebody proposed. `GET /api/scenarios?state=unrun` is a queue of
  scenarios nobody has reached, and the verifier runs each one's own steps against both releases and
  records the run, which the service turns into the ordinary `reproduced` verification. A claim this
  client cannot read is recorded as `unreached` with the step named, never skipped silently, and a
  claim it could not build is not offered back to it.

### Changed

- The project is **Agents**. The client is `agents-miner`, the namespace is `AgentsMiner`, the
  environment variables use the `AGENTS_` prefix, the state directory is
  `~/.cache/agents-miner`, and the image tags use `agents-miner`. The old names are not read or
  accepted; this is a breaking rename, so the client is `2.0.0`.

### Fixed

- A Ruby report quotes the refusal rather than the frame it was raised in. Ruby prints the exception
  first and the `from` frames after it, so reading the last non-blank line gave every gem finding a
  `problem` that read `from probe.rb:6:in '<main>'`, and gave every scenario proposed from one an
  expected class of that frame — a claim no run could satisfy, and one a verifier could only answer
  `unknown`. The location prefix is stripped too, so what a reader sees is what the interpreter said.
- `mine` prints a differential without registering an operator or filing a report. It shared
  the `publish` path and did both, which contradicted its documented job.
- The duplicated `serve` dispatch in `Cli.main` is removed; it was a no-op with two identical
  lines.

### Added

- **A value that changed under an unchanged name.** The differentials compare surfaces — names and
  signatures — so a release that keeps both and changes what a name *is* was invisible. `Behaviour`
  compares the `type` and `repr` of the attributes both inventories already read, and files a
  `behaviour_changed` finding carrying both readings. No call is made and no probe is spent: the
  values come with the inventory the differential takes anyway. The four relations that need a call
  (idempotence, round-trip, side effects, a call's own error) are deliberately not here.
- The verifier checks a Rails move that failed while Bundler was resolving versions:
  `as-reported` executes a minimal `bundle lock` naming the two releases, and `searched`
  reads the refused gem's own gemspec rather than the report's quoted constraint. Both use
  the two existing verifier accounts, so such a report can reach `resolved_verified` without
  the application that filed it.
- **The release that actually broke the call, for a finding whose crossing has releases between
  its endpoints.** The differential proves the two ends and says nothing about the middle, so a
  report could only say "this move breaks you". `Bisect` searches the releases between the two,
  in `ceil(log2(k))` installs, and files the boundary as `introduced_in`; the middle releases are
  run only when the window has any, and a release that cannot be built stops the search rather
  than reading as one that still worked. `--bisect-probes` (or `MINER_BISECT_PROBES`, default 4)
  bounds the installs per crossing; 0 turns the search off and sends no field.
- Standalone documentation, issue and pull-request templates, and a contract split: the
  service owns the `change_kind` vocabulary, the frozen `Gem::Version` recording and the
  deployment's compose wiring.

## [1.0.0] - 2026-10-20

The first standalone release of the client. The miner, the two verifying operators and the
PyPI/RubyGems differential; the durable ledger; the service queue and breadth seed; reviewed
advisory leads; the unexaminable picture; the wheel cache and bounded environments.
