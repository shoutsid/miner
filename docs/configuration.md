# Configuration

The client has no configuration file, no `~/.minerrc` and no default state outside `--home`.
A setting is a flag, an environment variable the client reads, or an entrypoint variable that
becomes a flag.

## Precedence

1. a command-line flag;
2. the environment variable that seeds it (`MINER_TOP`, `MINER_ECOSYSTEMS`);
3. the default named here.

The container's `entrypoint.sh` reads its own variables and passes them as flags, so a
deployment is configured without editing the image's command.

## The client

| Variable | Default | Meaning |
|---|---|---|
| `MINER_TOP` | `3000` | how many packages a watchlist holds when `--top` is not given. A value that is not a positive integer is ignored rather than fatal. |
| `MINER_ECOSYSTEMS` | `python` | the indexes `serve` works: `python`, `ruby`, or both comma-separated. `--ecosystems` overrides it. |
| `PYTHON` | `python3` | the interpreter a Python probe and the machine stamp use. |
| `PIP_CACHE_DIR` | pip's own default | where pip keeps downloaded wheels. The image points this at a volume shared by the miner and both verifiers. |
| `TMPDIR` | unset | if set, it is honoured; otherwise the client sends scratch to `<home>/tmp` rather than the container's `/tmp` tmpfs. |

The one-shot `mine`/`publish` modes are PyPI-only in this build. `serve --ecosystems ruby`
works RubyGems; `verify` follows the index named by each report.

## The entrypoint

These are read by `entrypoint.sh`. They select a mode and build the CLI's argument list.

| Variable | Default | Meaning |
|---|---|---|
| `API_BASE_URL` | `http://service:8001` | the service, passed as `--base-url`. On a compose network this is the service's name, not the public hostname. |
| `MINER_HOME` | `/home/miner/.cache/agents-fyi-miner` | the state, environments, caches and heartbeat. A verifier should use its own home. |
| `MINER_MODE` | `serve` | `serve`, or `verify` to run a verifier. |
| `MINER_BUDGET` | `24` | pairs per cycle for `serve`. |
| `MINER_REPORT_BUDGET` | `1` | open reports answered per cycle for `serve`. |
| `MINER_TOP` | `3000` | watchlist depth for `serve`. Past about 4,000 the breadth seed stops fitting in the service's request body. |
| `MINER_WRITES_PER_HOUR` | `0` | the client's own write ceiling; `0` is no limit. |
| `MINER_WORKERS` | `6` | upgrades examined at once. |
| `MINER_DOWNLOAD_MBPS` | `0` | a ceiling on this process's downloads in MB/s; `0` is no ceiling. |
| `MINER_LOG_LEVEL` | `INFO` | `DEBUG`, `INFO`, `WARNING` or `ERROR`. |
| `MINER_ECOSYSTEMS` | read by the client, not passed by the entrypoint | the indexes `serve` works. |
| `VERIFIER_ROLE` | `as-reported` | with `MINER_MODE=verify`: `as-reported` or `searched`. |
| `VERIFIER_BUDGET` | `6` | reports checked per verifier cycle. |

The verifier's home must be distinct from the miner's. Its state file is
`operator-<role>.json` and its ledger is `ledger-<role>.json` under that home.

## State

| Path | Meaning |
|---|---|
| `<home>/operator.json` | the miner's key, mode `0600` |
| `<home>/operator-<role>.json` | a verifier's key |
| `<home>/ledger.json` | the miner's settled pairs and work cursor |
| `<home>/ledger-<index>.json` | a second index's ledger when one process works both |
| `<home>/ledger-<role>.json` | a verifier's report ledger |
| `<home>/envs/` | Python environments, one per release |
| `<home>/rubyenvs/` | Ruby gem environments, one per release |
| `<home>/index/` | release histories and the breadth ranking |
| `<home>/tmp/` | installer scratch, on the volume rather than a tmpfs |
| `<home>/probe-home/` | a writable `HOME` for code under test |
| `<home>/heartbeat` | touched once per miner cycle |

Nothing here is a cache whose loss is harmless: losing the ledger re-derives weeks of work,
and losing the environments re-installs hundreds of releases. The volumes are the deployment.

## The service key

There is no `AGENTS_FYI_KEY` variable in this client. On first use it registers an operator
with the service and writes the key into the state file with mode `0600`. The key is sent as
`X-API-Key`; it is never printed and never written into a report.

The operator is a client identity, never an administrator. The admin surface — hiding,
unhiding, disabling, pausing an index — is deliberately out of reach. A paused index is
something this client reads, reports and waits out; it does not lift it.

## The image

The image's `ENV` sets `PIP_CACHE_DIR`, `PYTHONUNBUFFERED`, `PYTHONDONTWRITEBYTECODE` and
`PIP_DISABLE_PIP_VERSION_CHECK`. The cache path is also the volume mount point; the
deployment must mount a writable volume there or pip warns and installs without a cache.

The image runs as uid `10002`, with a read-only root, a bounded `/tmp`, dropped capabilities
and no database driver, database route or `DB_PASSWORD`. See [Deployment](deployment.md).
