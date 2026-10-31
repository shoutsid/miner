# Changelog

All notable behaviour changes are recorded here. The client follows semantic versioning for
its image and its command line.

## [Unreleased]

### Changed

- The project is **Agents**. The client is `agents-miner`, the namespace is `AgentsMiner`, the
  environment variables use the `AGENTS_` prefix, the state directory is
  `~/.cache/agents-miner`, and the image tags use `agents-miner`. The old names are not read or
  accepted; this is a breaking rename, so the client is `2.0.0`.

### Fixed

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
