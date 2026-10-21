# Contributing

This repository is **proprietary**. It is public so operators and reviewers can read the
client, not because it is open source. See [LICENSE](LICENSE).

## Before you write code

Open an issue first and describe the change. Contributions are accepted only by prior
arrangement with the copyright holder. Do not send a pull request that adds a feature, a
dependency or a large refactor without that conversation; it may be declined for reasons that
have nothing to do with the quality of the code.

Opening an issue or a pull request does not grant a licence to use the repository, and does not
transfer ownership of your contribution. Any contribution that is accepted is subject to a
separate written agreement with the copyright holder.

## What is welcome

- A reproducible bug report with the command, the version, the operating system and a redacted
  log or state description.
- A correction to documentation that is wrong about the current behaviour.
- A test that demonstrates a real failure, with the smallest reproduction you can find.
- A focused fix, discussed first.

## Development

You need Ruby 3.3 or newer. Python 3.12 is needed for PyPI probes; a C compiler is needed for
native gems. There is no Gemfile and no `bundle install`.

```bash
git clone git@github.com:shoutsid/miner.git
cd miner
ruby -Ilib -Itest test/all_test.rb
```

A single file:

```bash
ruby -Ilib -Itest test/cli_test.rb
```

The suite needs no network, no Docker daemon and no service. If a change needs one of those to
test, it likely belongs in the service's cross-repository contract suite, not here. See
[Development](docs/development.md) for the split.

## Design rules

- **No new runtime dependencies.** A default gem is acceptable when it is the right tool; a new
  gem is a design change, not a convenience.
- **The corpus is the service's.** Do not add a local copy of the mining queue, the
  `change_kind` vocabulary or the deployment's compose file.
- **A refusal is not a crash.** Keep `1` (failure), `2` (usage) and `3` (every index paused)
  distinct, and never settle work on a pause or a quota.
- **The ledger is state.** A change that reinterprets an existing record without a version or an
  additive default is not finished.
- **Do not skip a test to make the suite green.** If an agreement needs both repositories, move
  it to the service's contract suite; if it can be stated here, state it here.

## Style

- Two-space indentation, frozen string literals, no trailing whitespace.
- Comments explain **why**, not what the code already says.
- Errors say what the caller should do next, with the count or the limit named.
- Tests are named as sentences and a test that documents a deliberate refusal says so.

The service's RuboCop run scans this tree when it is checked out as a submodule. In standalone
CI the checks are `ruby -c` over every Ruby file, `bash -n` over the shell scripts, the suite,
and an image build that runs `--help`.

## Pull requests

- One concern per change.
- Add or update a test that would fail without the change.
- Update the docs when a flag, default, refusal, exit status or state file changes.
- Do not add a secret, a token or a package's private source to a fixture.
- Describe how you tested it, including the Ruby version and whether Python, Docker or a real
  service was involved.

## Security

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## Conduct

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
