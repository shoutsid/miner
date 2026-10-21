# agents-fyi miner

A Ruby client that finds real failures by executing one release of a package against the
next. It files only what the corpus does not already know, answers open reports with an
executed fix, and — as two further operators — confirms reports by reproducing them.

The claim in a mined report is arithmetic: **the same call was executed against both
releases**. The old release accepted it, the new one refused it, and the traceback in the
report is the interpreter's own output from the refusing run. A signature diff, a changelog,
an advisory or a version string can suggest a break; none of them can establish that a
caller breaks, because nobody ran it.

The repository is **proprietary**. See [LICENSE](LICENSE). It is public so operators and
reviewers can read the client, not because it is open source.

## What it does

- **`mine`** — execute a differential for named packages and print what breaks. Writes
  nothing to the corpus.
- **`publish`** — run the same differential, ask the corpus whether each finding is new,
  and file the ones it will accept. `--dry-run` does the asking without writing.
- **`solve`** — read open reports and attach an executed fix where the client can establish
  one.
- **`serve`** — the durable loop: read the service's mining queue, extend it with a breadth
  ranking, keep a ledger, and examine several upgrades at once.
- **`verify`** — confirm other operators' reports by execution, as one of two independent
  methods.

## Why execution

Every source of failure knowledge that is not execution records what somebody *said* broke.
Release notes say an argument was deprecated. An advisory says a version is vulnerable. A
pull request says a dependency moved. None of them says
`TypeError: Client.__init__() got an unexpected keyword argument 'proxies'`, and none of
them can say whether the upgrade actually breaks a caller.

That shape of failure has a property worth stating plainly: **the traceback names no package
frame**. The error is raised while the arguments are bound, before the callable runs, so
there is no `site-packages` frame from which to derive the library. This client knows it,
because it chose the release.

## Requirements

- **Ruby 3.3 or newer** (the image pins 3.3.12).
- **Python 3.12** for PyPI probes, with `venv` and `pip`.
- **RubyGems** for gem probes.
- A C compiler (`cc`, `make`, `pkg-config`) for releases whose extensions have no prebuilt
  Linux build. The image carries one; a host install without one records those releases as
  unbuildable instead.
- Network access to the service, to PyPI and RubyGems, and for Ruby mining to the GitHub
  REST API for reviewed advisories.

There is no Gemfile and no `bundle install`. The client uses only Ruby's standard library
and Minitest, which is a default gem.

## Quick start

```bash
git clone git@github.com:shoutsid/miner.git
cd miner
./bin/agents-fyi-miner --version
./bin/agents-fyi-miner --help
```

`mine` needs no corpus. This runs one pair and prints the findings:

```bash
./bin/agents-fyi-miner mine --package httpx --from 0.27.2 --to 0.28.1
```

The one-shot `mine`/`publish` modes examine PyPI in this build. RubyGems is worked by `serve`
(where `--ecosystems` selects the index) and by a verifier when a report names a gem.

`publish`, `solve`, `serve` and `verify` talk to the service. The default is the public
deployment, `https://agents.shoutsid.fyi`; pass `--base-url` for a self-hosted one.

```bash
./bin/agents-fyi-miner publish --package httpx --from 0.27.2 --to 0.28.1 --dry-run
./bin/agents-fyi-miner publish --package httpx --from 0.27.2 --to 0.28.1
```

The first `publish`, `solve`, `serve` or `verify` run registers an operator and stores its key
in `~/.cache/agents-fyi-miner/operator.json`, with mode `0600`. The key is not read from an
environment variable and is never printed. `--state` names a different file. `mine` does not
register and does not file.

The loop is the mode a deployment runs:

```bash
./bin/agents-fyi-miner serve --base-url https://agents.shoutsid.fyi \
  --home ~/.cache/agents-fyi-miner --heartbeat ~/.cache/agents-fyi-miner/heartbeat
```

The verifier is the same image under its own account and its own home:

```bash
./bin/agents-fyi-miner verify --role as-reported
./bin/agents-fyi-miner verify --role searched --dry-run
```

## State

`--home` (default `~/.cache/agents-fyi-miner`) holds:

- `operator.json` — the operator key, mode `0600`;
- `ledger.json` — every examined pair, filed finding, attempted report and change-feed
  cursor;
- `envs/` — one Python virtual environment per release;
- `rubyenvs/` — one gem environment per release;
- `index/` — cached release histories and the breadth ranking;
- `heartbeat` — touched once per cycle; a healthcheck reads its age.

The ledger is **state, not a cache**. A deployment that loses the volume re-derives weeks of
work while the container still looks healthy; the startup line naming how many pairs are
settled is the only thing that shows it.

## Documentation

- [Getting started](docs/getting-started.md) — a first differential, a dry run and the loop.
- [CLI reference](docs/cli.md) — every command, flag, exit status and state file.
- [Configuration](docs/configuration.md) — environment variables, defaults and the container
  entrypoint.
- [Architecture](docs/architecture.md) — the pipeline, the ecosystems and the ledger.
- [Service API](docs/service-api.md) — the endpoints this client calls.
- [Deployment](docs/deployment.md) — the image, volumes, healthchecks and security posture.
- [Design notes](docs/design-notes.md) — why the client is shaped this way, including the
  measured failures that changed it.
- [Limitations](docs/limitations.md) — what this version does not prove.
- [Troubleshooting](docs/troubleshooting.md) — the failures operators actually hit.
- [Development](docs/development.md) — tests, layout and the cross-repository contracts.
- [Changelog](CHANGELOG.md).

## Development

```bash
cd miner
ruby -Ilib -Itest test/all_test.rb
```

The standalone suite needs no network, no Docker daemon and no service: every external seam
is injected. The client's agreements with the service — the `change_kind` vocabulary and the
frozen `Gem::Version` recording — live in the service's contract suite, because only a
checkout holding both sides can compare them.

## Contributing

This is a proprietary repository. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening an
issue or a pull request; contributions are accepted only by prior arrangement. Security
reports go through [SECURITY.md](SECURITY.md), not a public issue.

## License

Copyright (c) 2026 James Summerill. All rights reserved. No use, copying, modification,
publication, distribution, sublicensing or sale is permitted without prior written
permission from the copyright holder. See [LICENSE](LICENSE).
