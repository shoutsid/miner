# Deployment

## The image

`Dockerfile` builds one image that runs all three client jobs:

- the **miner** (`MINER_MODE=serve`), which grows the corpus;
- the **as-reported verifier** (`MINER_MODE=verify`, `VERIFIER_ROLE=as-reported`);
- the **searched verifier** (`MINER_MODE=verify`, `VERIFIER_ROLE=searched`).

The image is a Ruby 3.3.12 base with a Python 3.12 tree copied in, a compiler for native
gems, and no database driver, no route to the service's database and no `DB_PASSWORD`. The
client is Ruby; Python is material it examines.

`entrypoint.sh` waits up to five minutes for `API_BASE_URL/api/health`, then starts anyway:
an API that is down is something the loop waits out. It then execs the CLI in the selected
mode.

The image deliberately does not carry the deployment's compose file. Which volumes, limits
and networks a container gets is the operator's decision, and a copy in this repository
would be a second source of truth.

## A minimal Compose shape

```yaml
services:
  miner:
    image: ghcr.io/shoutsid/miner:latest
    restart: unless-stopped
    environment:
      API_BASE_URL: http://service:8001
      MINER_MODE: serve
      MINER_HOME: /home/miner/.cache/agents-fyi-miner
      MINER_ECOSYSTEMS: ruby
      MINER_BUDGET: "24"
      MINER_WORKERS: "6"
    volumes:
      - miner_cache:/home/miner/.cache/agents-fyi-miner
      - pip_cache:/home/miner/.cache/pip
    read_only: true
    tmpfs:
      - /tmp:size=1g
    security_opt:
      - no-new-privileges:true

  verifier:
    image: ghcr.io/shoutsid/miner:latest
    restart: unless-stopped
    environment:
      API_BASE_URL: http://service:8001
      MINER_MODE: verify
      MINER_HOME: /home/miner/.cache/agents-fyi-verifier
      VERIFIER_ROLE: as-reported
      VERIFIER_BUDGET: "24"
    volumes:
      - verifier_cache:/home/miner/.cache/agents-fyi-verifier
      - pip_cache:/home/miner/.cache/pip
    read_only: true
    tmpfs:
      - /tmp
    security_opt:
      - no-new-privileges:true

volumes:
  miner_cache:
  verifier_cache:
  pip_cache:
```

The second verifier uses `VERIFIER_ROLE=searched`, its own home and its own cache volume.
The exact limits, memory caps and disk budgets belong to the host; the rules below are the
ones that must survive a change to them.

## Volumes

| Volume | Mount | What it holds |
|---|---|---|
| `miner_cache` | `/home/miner/.cache/agents-fyi-miner` | miner state, environments and ledger |
| `verifier_cache` | `/home/miner/.cache/agents-fyi-verifier` | as-reported verifier state and environments |
| `verifier_independent_cache` | `/home/miner/.cache/agents-fyi-verifier-independent` | searched verifier state and environments |
| `pip_cache` | `/home/miner/.cache/pip` | pip's downloaded wheels, shared by all three |

**The wheel cache is shared; the environments are not.** A wheel is an artifact the index
published a hash for, so a copy is not a claim about anything. An environment is what the
wheel is unpacked into and *executed* in, which makes it evidence. A verifier probing inside
the miner's environment would be checking a claim with the material the claim came from.

The image creates its cache directories and runs as a non-root user, so a named volume
mounted over one inherits a writable owner. An image without those directories would get a
root-owned volume and silently lose the cache.

## Environment and budgets

The full list is in [Configuration](configuration.md). Deployment values worth setting:

- `MINER_ECOSYSTEMS` — the index(es) this deployment is collecting. The public corpus has
  worked `ruby` while PyPI was paused; a deployment must not decide that from a client
  default.
- `MINER_TOP` — how long a watchlist is. It has to outlast the work. Past about 4,000 the
  breadth seed stops fitting in the service's request body.
- `MINER_BUDGET` — pairs per cycle.
- `MINER_REPORT_BUDGET` — open reports answered per cycle.
- `MINER_WORKERS` — how many upgrades are examined at once. The work is subprocess-bound, so
  this is the dial that matters; it also divides the download ceiling.
- `MINER_DOWNLOAD_MBPS` — a ceiling on the whole process's downloads. It bounds how many
  installs download at once, not the rate of an install already running. The floor is one
  download: pip has no rate control of its own.
- `MINER_WRITES_PER_HOUR` — the client's own ceiling; `0` means no limit. The service's quota
  is the authority.

The ledger is state. A deployment that drops the volume looks healthy while re-deriving every
pair it ever examined; the startup line naming the settled count is the only thing that shows
it. The same volume holds the operator key; losing it re-registers a new account, with a new
identity and no memory of what that account already filed.

## Healthchecks

The image's healthcheck is the age of the heartbeat the loop touches once per cycle. It uses
the Ruby already in the image; nothing is installed to probe a file.

```text
ruby -e "p='/home/miner/.cache/agents-fyi-miner/heartbeat'; exit(File.exist?(p) && (Time.now - File.mtime(p)) < 5400 ? 0 : 1)"
```

The two verifiers touch their own files (`heartbeat-as-reported`, `heartbeat-searched`), so a
verifier's compose block must override the path. A service whose healthcheck reads somebody
else's file is reported unhealthy for doing its job.

A process being up is not a health signal. A miner whose corpus went away looks exactly like
one that is thinking, for hours; the heartbeat is what makes that visible.

## Security posture

This client **executes arbitrary third-party packages by design**; that is the method. The
deployment bounds the blast radius rather than pretending the execution does not happen:

- run as a dedicated non-root user (uid `10002`);
- read-only root filesystem, with writes confined to the state volume and a bounded `/tmp`;
- `no-new-privileges`, dropped capabilities, memory and CPU limits;
- no database driver, no database route, no `DB_PASSWORD`, no admin token;
- no Docker socket: this client does not need one;
- the operator key is a client credential, mode `0600`, never printed or written into a
  report.

It does **not** protect the host from a malicious release that exploits the kernel or the
interpreter. Run it on a host you are willing to expose to that, and keep the corpus's
operator key scoped to what this client does.

The corpus is public. A report filed by this client is public, including the exception line
and the command it ran. A release's own output can contain a secret; the client does not
redact what the package prints.

## Release

A `v*` tag runs `.github/workflows/release.yml`, builds the image and publishes it to GHCR.
The image is the same one the CI job builds; there is no separate step image. The release
does not contain a compose file, a key or a state volume.

The CI workflow builds the image and runs `--help` inside it. That is the artifact check. The
service's own contract suite checks the compose wiring and the deployment's volumes.

## What this repository does not deploy

The service itself, its database, the tunnel and the operator accounts are the service's
deployment. This repository ships the client image and its documentation; the deployment
that runs the image lives with the service.
