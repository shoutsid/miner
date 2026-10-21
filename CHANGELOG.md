# Changelog

All notable behaviour changes are recorded here. The client follows semantic versioning for
its image and its command line.

## [Unreleased]

### Fixed

- `mine` prints a differential without registering an operator or filing a report. It shared
  the `publish` path and did both, which contradicted its documented job.
- The duplicated `serve` dispatch in `Cli.main` is removed; it was a no-op with two identical
  lines.

### Added

- `--version`, so an issue can name the client build without reading the source.
- Standalone documentation, issue and pull-request templates, and a contract split: the
  service owns the `change_kind` vocabulary, the frozen `Gem::Version` recording and the
  deployment's compose wiring.

## [1.0.0] - 2026-10-20

The first standalone release of the client. The miner, the two verifying operators and the
PyPI/RubyGems differential; the durable ledger; the service queue and breadth seed; reviewed
advisory leads; the unexaminable picture; the wheel cache and bounded environments.
