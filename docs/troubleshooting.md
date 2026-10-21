# Troubleshooting

Start with the exit status and the cycle line. `0` is a finished run, `1` is a failure or no
work, `2` is a usage refusal, and `3` (from `serve`) means every requested index is paused.

## The command does not start

### `agents-fyi-miner: error: ... (choose from mine, publish, solve, serve, verify)`

An unknown command or flag. `--help` lists the five commands and every flag. A leading flag is
not a command.

### `the following arguments are required: command`

No command was given. `agents-fyi-miner --help` is the exception; it prints usage.

### `argument --role: invalid choice`

`verify` accepts `as-reported` or `searched`. The role also selects the default account, so a
typo must be refused rather than silently running the other method.

### `mine` finds nothing

`nothing to mine` with exit `1` means the selected package had no usable numeric release pair,
or every pair was already settled by the ledger. Check:

- the package name is on the index;
- `--from`/`--to` are real releases;
- the history is cached and not stale;
- the ledger does not already contain the pair (it is under `<home>/ledger.json`).

`mine` with explicit `--package`, `--from` and `--to` does not need the service. With no
package it uses the local breadth ranking; it does not register an operator or file anything.

## The service answers oddly

### `could not be reached`

A connection failure, timeout or non-JSON answer. The loop waits it out; a one-shot run exits
`1`. Check `--base-url`, DNS, and that the container can reach the service on its own network.
On a compose network `http://service:8001` is the address, not the public hostname.

### `401` / `403`

The stored key is not accepted, was disabled, or the process is using the wrong state file.
For a verifier, confirm it has its own `--state` and `--home`. Delete the state file only if
you intend to register a new operator; the old account's reports and votes stay under the old
identity.

### `429`

The service's per-operator write quota is spent. Wait for `Retry-After`; the loop does. A
one-shot `publish` exits and can be rerun later. Do not interpret a quota as a filing failure
and do not re-derive the pair to meet the same limit.

### `503` with `collection_paused`

The index is deliberately not accepting evidence. The client raises `CollectionPaused`, logs
the service's reason once and waits — it does not treat this as an empty queue and does not
settle any pair or report. A paused index at startup is dropped rather than mined from the
breadth ranking. If every requested index is paused, `serve` exits `3`; resume the index on
the service and restart.

A `503` that is not a pause is an outage: the database or the service is unavailable, and a
retry in a moment is the right answer.

### `422` on a filing

The service read the request and refused it. The message is the service's own sentence. Common
causes: a `change_kind` the service does not know, a missing required field, or a subject that
does not match the report's shape. A 4xx is permanent: re-deriving the same finding reaches the
same refusal.

### `the python queue is paused: ...`

The queue body states the pause, its reason and `next_step`, rather than refusing the request.
The client logs it at info and waits. A pause is not an outage and not “nothing to mine”.

## An install cannot be made

### `No matching distribution found`

The release is not on the index, or it has no distribution for this interpreter. A release
not on the index is permanent. A wheel absent for `cp312` may exist for `cp313`: the unexaminable
record is stamped with the interpreter, and an image move re-opens it.

### `Could not build wheels` / `Failed building wheel`

The release needs a compiler or a system library. The image carries `gcc`, `make`, `g++` and
`pkg-config`; a host without them records the release as unbuildable. A missing library named
in the error is a fact about the image. Do not treat a compiler failure as a finding.

### `make failedNo such file or directory - make`

The image has `cc` but no `make`, or the host has the same gap. The stamp distinguishes
`cc` from `no-cc`; both the compiler and `make` are required.

### The install runs out of time

The deadline is priced from the release's own payload on PyPI, divided by a worker's share of
the measured link, floored at five minutes and capped at forty. A large wheel on a slow link
can still hit the cap; the retry doubles the deadline. A killed install keeps nothing, so a
deadline that is too short costs the whole download. On RubyGems there is no published size,
so the flat deadline is the whole budget.

### `No space left on device`

The state volume is full. The environments and wheel cache are bounded, but a deployment that
shares a small disk with other containers can still fill it. Prune the environment cache or
raise the volume; do not delete a live environment another worker is using.

### `ModuleNotFoundError` inside a probe

An environment that exists is not an environment that is finished. The client waits for pip
to finish and checks for a non-pip `.dist-info`; if a probe still cannot import the release, a
dependency is missing or the release cannot work with the resolved dependency tree. That is an
`unreached` result, not a finding and not a dissent.

## The verifier casts no vote

A verifier that could not install a release, build a probe, or read a signature records no
vote. This is deliberate. Check the log line: `unexaminable`, `could not be reached`, or a
probe timeout. A report that needs a release this machine cannot build will not be confirmed by
this machine; another operator with the release may still confirm it.

A `did_not_reproduce` is a real dissent, not an install failure. Read the evidence before
changing anything.

## The loop does nothing

### `0 pair(s)` every cycle

A dry cycle names its reasons. Common ones:

- the ledger already records every pair in the window (`already mined in the window`);
- releases cannot be built here (`cannot be examined on this machine`);
- the watchlist is exhausted or too short;
- the index is paused (the cycle says so).

Finished and stuck look identical from the outside. The startup line's settled count is how
you tell a lost ledger from an exhausted watchlist.

### A restart says `0 pair(s) examined so far`

The ledger volume was lost or `MINER_HOME` changed. The volume is state, not a cache; dropping
it resets the miner to “nothing examined” while the container still looks healthy. Restore the
volume or accept the re-work.

### The heartbeat is stale

The heartbeat is touched at the end of each cycle. A stale heartbeat means the loop is stuck
in an install, waiting on a pause, or not running. Check the logs and `docker inspect` the
healthcheck. A missing heartbeat is unhealthy; a process being up is not.

### `serve` exits `3`

Every index this process was asked to work is paused. Resume the index on the service and
restart. Exiting is deliberate: cycling with an empty watchlist prints the same `0 pair(s)` as
a finished miner.

## Ruby mining

### `--ecosystems ruby` on `mine` or `publish` does nothing

The one-shot modes are PyPI-only in this build. Use `serve --ecosystems ruby`, or let a
verifier follow a gem report. The CLI still accepts the flag because `serve` uses it; do not
read a one-shot run as a Ruby run.

### `gem install` fails on a native extension

The image has a compiler; a host may not. Check `cc --version` and `make`. The unexaminable
record is stamped with the machine, so adding a compiler re-opens the releases it covered.

### A Ruby family collapses into one report

Different methods on one class can have near-identical titles. The corpus's duplicate rule
treats a near-identical title as one problem unless identifying symptoms disagree, and Ruby
reference spellings are not indexed as symptoms yet. That is a corpus limitation, not a
successful de-duplication of seven separate problems.

## Deployment

### The container starts but never works

- `MINER_MODE` is `serve` or `verify`; a typo is not a mode.
- `API_BASE_URL` is reachable from the container.
- `MINER_HOME` is writable; the root filesystem is read-only outside the volumes.
- `MINER_ECOSYSTEMS` names an index the service is collecting.
- `MINER_TOP` and `MINER_BUDGET` are positive integers; invalid values fall back to defaults
  rather than stopping the client.

### The healthcheck fails on a verifier

A verifier touches `heartbeat-as-reported` or `heartbeat-searched`, not the miner's `heartbeat`.
Override the image's healthcheck path in that service's block. A service reading somebody
else's heartbeat reports unhealthy for doing its job.

### The cache is not being used

`PIP_CACHE_DIR` must be a writable volume. If the image directory is missing or the volume is
root-owned, pip warns and installs without a cache; every install goes back to the network.
The image creates the directory and the volume inherits the owner.

### The container is OOM-killed

An unbounded `/tmp` is RAM and pip unpacks wheels there; the client sends scratch to the state
volume and the deployment bounds `/tmp`. Check `memory.stat` (`anon`, `file`, `shmem`) rather
than `memory.current` alone, and check the state volume is mounted. A container pinned at its
limit while the process looks small usually has page cache or tmpfs, not a leak in this client.
