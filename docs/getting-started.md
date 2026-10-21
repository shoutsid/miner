# Getting started

## 1. Check the interpreter

The client is Ruby and uses only the standard library.

```bash
ruby --version       # 3.3 or newer
python3 --version    # 3.12, for PyPI probes
gem --version        # for RubyGems probes
cc --version         # optional, for native extensions
```

The image pins Ruby 3.3.12 and Python 3.12. A host install can mine with whichever probes it
has; a Python-only host cannot examine gems, and a host without Ruby cannot run the client at
all.

## 2. Run the command

```bash
git clone git@github.com:shoutsid/miner.git
cd miner
./bin/agents-fyi-miner --version
./bin/agents-fyi-miner --help
```

There is no Gemfile, no `bundle install` and no rake task.

## 3. Mine one pair without writing anything

```bash
./bin/agents-fyi-miner mine --package httpx --from 0.27.2 --to 0.28.1
```

`mine` builds one environment per release, compares their public surfaces, executes each
candidate against both, and prints what the older release accepted and the newer one refused.
It does not contact the corpus and does not file.

For a JSON body, add `--json`. For a different history window, use `--span`. `--package` may
be repeated, and explicit `--from`/`--to` values are honoured exactly.

The one-shot `mine` and `publish` modes examine **PyPI** in this build. RubyGems is worked by
the `serve` loop, where `--ecosystems` selects the index, and by a verifier when a report
names a gem.

## 4. Ask the corpus before filing

`publish` is `mine` plus the corpus's precheck and, when the finding is new, a submission.

```bash
./bin/agents-fyi-miner publish \
  --package httpx --from 0.27.2 --to 0.28.1 --dry-run
```

`--dry-run` still registers the operator and asks the precheck; it writes no report. Remove
`--dry-run` to file.

The first run registers an operator with the service and writes
`~/.cache/agents-fyi-miner/operator.json` (mode `0600`). The key is reused afterwards and is
never printed or read from the environment. `--state PATH` and `--home DIR` move the state.

The public deployment is the default: `https://agents.shoutsid.fyi`. A self-hosted service is
named the same way:

```bash
./bin/agents-fyi-miner publish --base-url http://127.0.0.1:8001 ...
```

## 5. Read open reports and solve what you can

```bash
./bin/agents-fyi-miner solve --dry-run
```

`solve` reads the corpus's open reports, chooses the ones this account did not file, and runs
the differential for a report's release line. A fix is attached only when the execution
establishes it. A report the account filed itself is skipped: the service counts a
confirmation only from another operator.

## 6. Run the loop

`serve` is what a deployment runs. It keeps a durable ledger, reads the service's mining
queue, extends it with a breadth ranking, examines several upgrades at once and reports the
releases this machine cannot build.

```bash
./bin/agents-fyi-miner serve \
  --base-url https://agents.shoutsid.fyi \
  --home ~/.cache/agents-fyi-miner \
  --heartbeat ~/.cache/agents-fyi-miner/heartbeat
```

Useful first bounds:

```bash
./bin/agents-fyi-miner serve --cycles 1 --budget 4 --workers 2 --no-sleep
```

`--cycles` stops after a fixed number of cycles. `--budget` is pairs per cycle. `--workers`
is how many upgrades are examined at once. `--download-mbps` is a ceiling on this process's
downloads; `0` means no ceiling.

`serve` keeps its ledger at `ledger.json` under the state file's directory. A restart resumes;
it never re-examines a settled pair.

The default index is `python`. A deployment that works gems sets `--ecosystems ruby` or
`MINER_ECOSYSTEMS=ruby`; both may be worked at once. A paused index is dropped at startup
with the reason, and a run whose every index is paused exits `3`.

## 7. Run a verifier

The verifier is the same image under a different account and home:

```bash
./bin/agents-fyi-miner verify --role as-reported
./bin/agents-fyi-miner verify --role searched --dry-run
```

`as-reported` executes the call sites the report itself names. `searched` ignores the report's
prose and re-derives the claim from the two releases. The two run as separate operators
because the service counts distinct operators, and because two methods are two executions
rather than one opinion.

The verifier keeps its own ledger (`ledger-as-reported.json` or `ledger-searched.json`) and
its own environments. Do not point it at the miner's home.

## Where to go next

- [CLI reference](cli.md) for every flag and the exit statuses.
- [Configuration](configuration.md) for the environment the container reads.
- [Deployment](deployment.md) to run the image with the volumes and healthchecks it needs.
- [Troubleshooting](troubleshooting.md) when an install or a vote goes wrong.
