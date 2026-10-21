# Development

## Run the suite

```bash
cd miner
ruby -Ilib -Itest test/all_test.rb
```

There is no Gemfile, no `bundle install` and no rake task. The client uses only the standard
library, and the tests use Minitest, which is a default gem.

One file:

```bash
ruby -Ilib -Itest test/cli_test.rb
```

One test:

```bash
ruby -Ilib -Itest test/cli_test.rb -n test_mine_prints_without_registering_or_filing
```

The suite is pure by design: no network, no installs, no Docker and no service. Every external
seam is injected — a fake corpus, a fake environment builder, a fake runner — because the parts
that do real work are the parts a test cannot assert anything stable about. The judgement under
test is what the client *concludes* from a run, which is where a fabricated finding would come
from.

CI runs the suite on Ruby 3.3.12 and checks `ruby -c` over every Ruby file and `bash -n` over
every shell script. The image job builds the Dockerfile and runs `--help` inside it.

## Layout

```text
bin/agents-fyi-miner             the one entry point
lib/agents_fyi_miner.rb          the loader
lib/agents_fyi_miner/            the client
  cli.rb                         commands, flags and exit status
  service.rb                     the durable loop
  verifier.rb                    the verifier loop
  planner.rb                     what to work on next
  ledger.rb                      settled pairs, reports and machine stamps
  ecosystems.rb                  the PyPI/RubyGems seam
  envs.rb, rubyenvs.rb           environments, deadlines and scratch
  mine.rb, rubymine.rb           the differentials
  versions.rb, rubyversions.rb   release histories and ordering
  corpus.rb                      the service client
  reporting.rb                   report payloads
  solving.rb, verifying.rb       report selection and claim execution
  advisories.rb                  reviewed advisory leads
  watchlist.rb                   the queue and the breadth ranking
  wheelcache.rb, bandwidth.rb    shared cache and download ceiling
  machine.rb                     interpreter/toolchain stamp
  data/                          the shipped RubyGems ranking
test/                            the standalone suite
Dockerfile                       the image (Ruby + Python + compiler)
entrypoint.sh                    mode selection, waiter and flag assembly
```

The client has no database driver and no database route. If a change would add one, the design
has gone wrong: it talks to the service over HTTP with an operator key.

## Cross-repository contracts

A few tests are about the **service** as much as the client. They live in the service's
repository, under `test/contracts/miner/`, because only a checkout that holds both sides can
run them:

| Contract | Why it cannot live here |
|---|---|
| the service's `change_kind` enum | the enum is `db/structure.sql` in the service; copying it here would create a second source of truth |
| the frozen `Gem::Version` recording | the recording is the service's fixture; this suite's table is the client's copy of the rule |
| the compose file's mounts, budgets and healthchecks | the compose file is the service's deployment, not this repository's |

Run them from the service's checkout:

```bash
RAILS_ENV=test bin/rails test test/contracts/miner
```

The standalone suite must not read a parent directory. A test here that reaches into the
service's `data/`, schema or compose file is a test that cannot run in this repository's CI.
If an agreement needs both sides, move it to the service's contract suite; if it can be stated
about this repository alone, state it here.

`test/artifact_test.rb` is the local half of the deployment agreement: it reads the
Dockerfile's interpreters, compiler, cache path and healthcheck, compiles the healthcheck's
Ruby, and checks every flag the entrypoint passes against the CLI. The service's deployment
contract is the other half.

## Adding a feature

- **A new mechanism** belongs in `Mechanism` and in the service's `change_kind` enum. Add the
  value to both; the service's contract suite fails if the client can produce a kind the
  service does not declare.
- **A new index** belongs in `Ecosystems`: an adapter that answers the same surface —
  `name`, `machine`, `history`, `crossings`, `pairs_for`, `release_date`, `deadline`, `build`,
  `findings`, `prune`, `sweep`. Nothing else in the loop should learn the index's name.
- **A new flag** belongs in the parser, the docs, and the entrypoint if the deployment needs
  it. A flag the entrypoint passes but the parser does not accept makes the container fail at
  start, and `test/artifact_test.rb` checks that.
- **A new state file** belongs in the docs and in the ledger/state tests. The ledger is state,
  not a cache; a shape change needs a schema version or an additive default, never a silent
  reinterpretation.

## Style

- Two-space indentation, frozen string literals, no trailing whitespace.
- Comments explain **why**, not what the code already says.
- Errors say what the caller should do next, with the count or the limit named.
- Tests are named as sentences; a test for a deliberate refusal says so in its docstring.
- Names are descriptive rather than short; a one-letter local is acceptable only in a
  mathematical loop.

The service's RuboCop run scans this tree when it is checked out as a submodule. The standalone
CI checks are syntax and the suite; the service's guide is the style to follow.

Do not add a runtime dependency. A default gem is acceptable when it is the right tool; a new
gem is a design change, not a convenience.

## Release process

1. Update `lib/agents_fyi_miner.rb`'s `VERSION` and `CHANGELOG.md`.
2. Run `ruby -Ilib -Itest test/all_test.rb`.
3. Run the service's contract suite if this checkout is the submodule.
4. Commit, tag `vX.Y.Z`, push the tag. The release workflow builds the image and publishes it
   to GHCR.

The release image is the same image CI builds. It carries both interpreters and the compiler;
there is no separate plan image.

## Pull requests

- Keep a change to one concern.
- Add or update a test that would fail without it.
- Update docs when a flag, a default, a refusal, an exit status or a state file changes.
- Do not add a secret, a token, a real operator key or a package's private source to a fixture.
- Do not skip a test to make the suite green. If an agreement needs the service, move it to the
  service's contract suite; if it can be stated here, state it here.
