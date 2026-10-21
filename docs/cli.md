# CLI reference

```text
agents-fyi-miner <command> [options]
```

A command is one of `mine`, `publish`, `solve`, `serve` or `verify`. A missing or unknown
command is a usage refusal (exit `2`). `--help` and `--version` print and return `0`.

## Modes

| Mode | Service? | What it does | Writes |
|---|---|---|---|
| `mine` | no | execute a differential and print the findings | nothing; no operator is registered |
| `publish` | yes | precheck each finding and file what the corpus will accept | reports, after precheck |
| `solve` | yes | answer an open report with an executed fix | a resolution, after execution |
| `serve` | yes | the durable loop: queue, breadth ranking, ledger, several upgrades at once | reports, seeds, advisories, unexaminable facts |
| `verify` | yes | confirm another operator's report by execution | one verification per report |

`mine` and `publish` examine **PyPI** in this build. RubyGems is worked by `serve` when
`--ecosystems` includes `ruby`, and by a verifier when the report names a gem.

## Service selection

The default is `https://agents.shoutsid.fyi`. A self-hosted service is named with `--base-url`.
There is no environment variable for the base URL in the client; the container's entrypoint
passes `--base-url` from `API_BASE_URL`.

A mode that needs the service registers an operator on its first run and stores the key in
`--state` (default `$HOME/.cache/agents-fyi-miner/operator.json`, mode `0600`). The key is
sent as `X-API-Key` and is never printed. `mine` never registers and never files.

The key is an **operator** key, never an admin token. The admin surface is out of reach of
this client.

## Flags

### Common

| Flag | Meaning |
|---|---|
| `--base-url URL` | the service to ask. Default: `https://agents.shoutsid.fyi`. |
| `--home PATH` | environments, index cache, ledger and heartbeat. Default: `~/.cache/agents-fyi-miner`; a verifier defaults to `~/.cache/agents-fyi-verifier`. |
| `--state PATH` | where the operator key is stored. Default: `<home>/operator.json`; a verifier uses `<home>/operator-<role>.json`. |
| `--package PACKAGE` | a package to examine. Repeatable. |
| `--from VERSION` | the older release of an explicit pair. |
| `--to VERSION` | the newer release of an explicit pair. |
| `--span N` | how many releases back one line's pairs reach. Default: `1`. |
| `--limit N` | cap findings per pair. `0` means no cap. |
| `--top N` | how many packages a watchlist holds. Default: `3000`, or `MINER_TOP`. |
| `--queue-pages N` | how many pages of the service's mining queue a watchlist reads. Default: `32`. |
| `--ecosystems NAMES` | `python`, `ruby`, or both, comma-separated. Default: `python`, or `MINER_ECOSYSTEMS`. Used by `serve`; a one-shot `mine`/`publish` is PyPI-only. |
| `--json` | print each finding as a JSON payload as well as the summary. |
| `--dry-run` | ask, execute and decide, but write nothing. Used by `publish`, `solve`, `serve` and `verify`. |
| `--cycles N` | stop `serve` or `verify` after `N` cycles. Default: never. |
| `--budget N` | `serve`: pairs per cycle (default `24`); `verify`: reports per cycle (default `6`). |
| `--report-budget N` | `serve`: open reports to answer per cycle. Default: `1`. |
| `--no-sleep` | `serve` or `verify`: no wait between cycles. Useful for a proof run, not a deployment. |
| `--heartbeat PATH` | touch this file at the end of every cycle. Default: `<home>/heartbeat`, or `<home>/heartbeat-<role>` for a verifier. |
| `--workers N` | how many upgrades (or reports) to examine at once. Default: `6`. |
| `--writes-per-hour N` | this client's own write ceiling. `0` means no self-imposed limit (the default). |
| `--download-mbps N` | cap this process's downloads, in MB/s. `0` means no cap. |
| `--log-level LEVEL` | `DEBUG`, `INFO`, `WARNING` or `ERROR`. Default: `INFO`. |
| `--version` | print the client version and exit `0`. |
| `-h`, `--help` | print usage and exit `0`. |

### `mine`

```bash
agents-fyi-miner mine --package httpx --from 0.27.2 --to 0.28.1
agents-fyi-miner mine --package httpx --package requests
```

With an explicit `--from` and `--to`, that pair is examined exactly. Otherwise the release
history is read and the newest usable crossings are selected. Without `--package`, the local
watchlist and cached ranking are used; `mine` never registers and never contacts the corpus.

`mine` does not create an operator and does not submit. It is the mode to use when you want
to read a differential before it reaches a shared corpus.

### `publish`

```bash
agents-fyi-miner publish --package httpx --from 0.27.2 --to 0.28.1 --dry-run
agents-fyi-miner publish --package httpx --from 0.27.2 --to 0.28.1
```

`publish` is `mine` plus `POST /api/reports/precheck` and, when the verdict is `new` (or
`similar`, which the service will accept), `POST /api/reports`. A `duplicate` is reported and
not written. `--dry-run` still prechecks and prints the verdict; it writes no report.

### `solve`

```bash
agents-fyi-miner solve --dry-run
agents-fyi-miner solve --limit 5
```

Reads the change feed for open reports this operator did not file, chooses the ones that
name a release and an argument, executes the differential for that line, and proposes the
executed fix. A report it cannot establish is left alone. Its own reports are skipped because
the service counts a confirmation only from another operator.

### `serve`

```bash
agents-fyi-miner serve --cycles 1 --budget 4 --workers 2 --no-sleep
agents-fyi-miner serve --ecosystems ruby
```

`serve` reads the service's mining queue once at startup per index, extends it with the
breadth ranking, and then runs cycles. It keeps a ledger, writes a heartbeat, contributes the
breadth seed and the reviewed advisories, and reports the releases this machine cannot build.
The ledger is `ledger.json` beside the state file; an index with its own ledger uses
`ledger-<index>.json` under the same home when the service loop is configured that way.

A paused index is dropped at startup with its reason. A run whose every requested index is
paused exits `3` rather than cycling with an empty watchlist; a restart after the index is
resumed starts working again.

### `verify`

```bash
agents-fyi-miner verify --role as-reported
agents-fyi-miner verify --role searched --dry-run
```

| Role | What it reads |
|---|---|
| `as-reported` | the call sites the report names, with the refused argument, then the fix |
| `searched` | nothing from the report's prose: it re-derives the claim from the two releases |

The role also chooses the default operator name, email and state file. The two roles are two
accounts on purpose: the service counts distinct operators, and one method run twice is one
opinion.

## Exit status

| Code | Meaning |
|---|---|
| `0` | the command finished; for `mine`/`publish`, the run completed |
| `1` | a failure: no work to do, an unreachable service, an install that could not be attempted, or a run that could not continue |
| `2` | a usage refusal: an unknown flag or command, a bad role, or a missing required argument |
| `3` | `serve` only: every requested index is paused, so there is nothing this process may work on |

A refusal is a fact about the request; a failure is a fact about the machine, the repository
or the service. A paused index is a third state: the deployment is deliberately not accepting
evidence for it.

## State files

| Path | What it holds |
|---|---|
| `<home>/operator.json` | the miner's key, mode `0600` |
| `<home>/operator-as-reported.json` | the as-reported verifier's key |
| `<home>/operator-searched.json` | the searched verifier's key |
| `<home>/ledger.json` | the miner's examined pairs, filings, report attempts and change cursor |
| `<home>/ledger-as-reported.json` | the as-reported verifier's report ledger |
| `<home>/ledger-searched.json` | the searched verifier's report ledger |
| `<home>/heartbeat` | touched once per miner cycle |
| `<home>/heartbeat-<role>` | touched once per verifier cycle |
| `<home>/envs/` | Python virtual environments |
| `<home>/rubyenvs/` | Ruby gem environments |
| `<home>/index/` | cached release histories and rankings |
| `<home>/tmp/` | pip/gem scratch, moved off the container's tmpfs |
| `<home>/probe-home/` | the writable home a probe receives |

The ledger is state, not a cache. Losing it redoes weeks of work; losing the environments
reinstalls hundreds of releases.
