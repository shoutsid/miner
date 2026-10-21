# Design notes

These are the decisions behind the client, including the measurements that changed them. They
are not a changelog; the [changelog](../CHANGELOG.md) records behaviour changes.

## Why execution, and not a changelog

A release note says an argument was deprecated. An advisory says a version is vulnerable. A
pull request says a dependency moved. None of them says
`TypeError: Client.__init__() got an unexpected keyword argument 'proxies'`, and none of them
can say whether a caller actually breaks.

This client runs the caller's shape against both releases. The finding is not “the signature
changed”; it is “this reference resolved here and raised there”. That distinction matters most
for the failure where the traceback names no package frame: argument binding fails before the
callable runs, so there is no `site-packages` frame to read a library from. The miner knows the
library because it chose the release.

The cost of the opposite approach was measured. An audit of a live corpus found **13 of 96
reports** telling callers to import something unrelated to what they lost, and a further **13
denying a successor that exists**. Every one was a claim the execution underneath did not
support:

- `paramiko`'s removed `DSSKey` “renamed to `ECDSAKey`” — a DSA class offered an ECDSA one,
  under an `AttributeError` whose own text said `Did you mean: 'RSAKey'?`;
- `numpy.RankWarning` “became `hanning`”;
- a replacement that had been tried and refused, filed because the mechanism read whether a
  candidate *existed* while the resolution text asserted it had been *executed*;
- a removal whose resolution said “the release exports nothing with a close name” about names
  still exported one submodule down.

Character similarity is not evidence. `is_azure_document_intelligence_model` /
`is_openai_finetune_model` is exactly the 0.6 cutoff, while
`delim_whitespace`/`delimiter` (0.64, wrong) sits 0.004 above
`connect_timeout`/`timeout` (0.636, right). The rule that replaced it asks for a name built
from **every** word of the old name, and refuses a tie. A name that gained a word was
qualified further (`Binary` → `LargeBinary`), not renamed. It costs three real renames and
buys back ten false ones.

A removal that denies a successor is its own lie, so `symbol_moved` asks the *release*:
import the package's submodules and look for the name where it is **defined**, not re-exported.
`wsproto.Event` is still `wsproto.events.Event`; `numpy.RankWarning` is
`numpy.exceptions.RankWarning`; `jsonpath-ng.JsonPathLexer` is
`jsonpath_ng.lexer.JsonPathLexer`. That is a reported fix, rather than “pin below this
release”. A public re-export is not offered (`httpx.Client`'s home in `httpx._client` is not a
caller path), and the search is one batch for the whole pass because the cost is importing the
submodules, not the number of names.

The honest residue: three real renames are refused because their names share no words
(`ResponseClosed` → `ResponseNotRead`), two because a word was dropped (`CythonMetaType` →
`CythonType`), and the pass looks one submodule deep, so a name that moved four levels down
(`litellm.parse_ocr_request_format`) is filed as a removal. Those reports are true; they are
just less helpful than they could be.

## The ledger's two decisions

A **failed** pair is retried; an **examined** pair is not. A release that cannot be built
today may be buildable after an image change, while a pair successfully compared is settled
whatever the comparison found, including finding nothing. Conflating the two either abandons
real packages or re-installs the same wheels forever.

The second decision is that yield is recorded per pair rather than inferred. A package that
has produced nothing across three examined releases is deferred behind packages still paying;
the entries stay, and the package comes back when there is nothing better to do.

A release that cannot be built is a fact about the release **and the machine**. The record is
stamped with the interpreter and whether there is a compiler. An sdist with no wheel for
`cp312` becomes installable when the image moves to 3.13; a gem's C extension becomes
installable when the image gains a compiler. Without the stamp, those facts would never expire.

The measured cost before the permanent/transient split: **817 pairs that could not be built
had cost 1,985 install attempts**; those pairs were 176 releases. With the split, a release is
recorded once rather than once per crossing that needs it. The other direction is deliberate:
everything unrecognised counts as transient. A permanent failure retried costs an attempt; a
transient failure settled for good costs the release.

## The compiler, and the measurement that installed it

The image originally had no compiler, on the reasoning that “a gem that needs a native
extension is a fact about the release”. Asked of the index rather than assumed, that is false:
`prism`, `bigdecimal`, `json`, `psych`, `date`, `nio4r`, `msgpack` and `racc` publish **no
Linux build at all** — only `ruby` and `java`. On this deployment **862 of the Ruby ledger's
1,844 pairs, across 659 gems**, were settled unbuildable, including `rails`, `railties`,
`actionpack`, `actionview`, `activemodel`, `activerecord`, `activesupport`, `nokogiri`,
`rubocop`, `puma`, `ffi` and `aws-sdk-core`. The failure also belongs to a dependency:
`rubyXL 3.3.33` failed because `racc` could not build; `minitest 6.0.6` and
`activesupport 8.0.5.1` because `prism` could not.

The measured trade: `racc 1.8.1` builds in **1 second**, and `rubyXL 3.3.33` then installs in
**2** because nokogiri resolves to a precompiled `nokogiri-1.19.4-x86_64-linux-gnu`. The
compiler is used for small extensions, not the large ones. The layer is **333 MB** (`gcc make
pkg-config` 171, `g++` 87), taking the image from 309 MB to 751 MB. The narrower set — the
compiler without `g++` — was rejected: a C++ extension with no prebuilt gem fails exactly like
`racc` did, and 87 MB is not worth re-creating that class. `pkg-config` comes with it because
a gem linking a library asks for it by name.

The stamp that expires these facts carries `cc`/`no-cc`, so changing this line is what
re-opens the releases the old image could not build.

## The queue, the ranking and the seed

The service's queue is the first source of work because it is computed from observations the
miner cannot make: a library with an unanswered report, one callers keep searching for and
missing, one that has already broken callers. The ranking continues the queue up to
`MINER_TOP` packages. Both are used.

The first version returned the queue *instead of* the ranking. That made the operator's depth
meaningless, and the miner ran out of work with thousands of packages on disk. The second
version had the opposite failure in its history: a queue read that failed was read as “the
service has no queue”, and the fallback ranking became the only list — so the queue the service
computed had never once driven the only miner that reads it.

The route pages. It returns at most `limit_max` targets and says so; asking for a thousand in
one request was a `422` at every start. The client reads the whole order with `offset`
instead of guessing a constant.

What the client owns is breadth: it is the process with a route to the outside, so it fetches
the monthly top-packages ranking (and RubyGems' all-time ranking) and pushes it as a seed. The
service decides what the seed means — it is the lowest tier and can never outrank a package
the corpus has observed — and records when it was read. A seed fetched by the service itself
would be empty on this deployment, because the service container has no egress.

The watchlist has to outlast the work. A list of 1,000 packages was documented as “a few dozen
hours of mining” — measured, about right, which is the problem: **9,042 crossings in 1.9 days**,
after which the miner cycled every ten minutes logging `0 pair(s)` and reported healthy.
Finished and stuck look identical from outside, so the dry cycle now names its reasons with
counts.

The seed is an order, not a set. Scoring presence at a flat point tied every seed-only package
and left the alphabet to order them — `botocore`, seed #15, at rank 242 behind `bs4` at #991.
When data arrives carrying an order, keep it.

## What the machine cannot build

The tail of the ranking is the old end of packages nobody has hit: 2013-era sdists with no
wheel, dependency trees that no longer resolve. Nothing in the corpus can observe it — no
report is filed and no search is made — so the service would go on offering work nobody can do.
Measured when the watchlist was 1,000 packages long: **198** were in that state.

Every cycle ends by pushing the ledger's whole unexaminable picture to
`POST /api/mining/unexaminable`. It is a **replacement**, not a delta: a release that installs
again after an image bump drops out by being absent, and a merge would leave a fact nothing
else would retract. The service uses the picture to order packages inside their tier, not to
move one across tiers, because “nobody could build this” is a cost rather than evidence that
the package is worth reading.

## The wheel cache

Installing a release is the unit of cost. The same wheels recur across packages and
environments: `urllib3`, `idna`, `certifi`, `typing_extensions`,
`charset-normalizer`. Measured on one deployment: of **1,622 wheel installations across 143
environments**, only **426 were distinct** — **74%** were a wheel already present in another
environment in the same volume; `typing_extensions 4.16.0` alone was installed 43 times.
The image had `PIP_NO_CACHE_DIR=1`, right for an image build but wrong for a container whose
job is to install releases all day, so every one was a fresh request.

`pip_cache` is now a volume shared by all three clients. Ten common transitive dependencies,
installed into a fresh environment, read **18 cached, 0 downloaded, 16 KB on the wire** against
roughly 3 MB before. The cache is bounded by `WheelCache::WHEEL_BUDGET_BYTES`: unbounded it
reached 1.7 GB in forty minutes across 1,462 entries. Pruning a cache entry costs a re-download
and can never leave the wrong bytes, so it takes a shorter quiet period than an environment.

The environments are deliberately **not** shared. That is not a disk decision: an environment
is what the wheel is unpacked into and executed in, so it is evidence. A verifier probing in
the miner's environment would verify a claim with the material the claim came from.

## Scratch, memory and the wrong measurement

`/tmp` in these containers is a tmpfs — RAM — and pip unpacks every wheel and sdist build into
`TMPDIR`, which defaults to `/tmp`. Measured: **4.1 GB within thirty-five minutes**, 769
`pip-unpack-*` directories, the container pinned against its own `mem_limit` (3,174
`memory.events` `max` hits). The symptom was not a memory error: pip began failing with an
**empty** message (`could not install sentence-transformers==5.4.1: ` and nothing after the
colon), then died mid-cycle with no traceback and without running its SIGTERM handler.

`Envs.use_scratch_dir` sends scratch to the volume; `Envs.sweep_scratch` removes what a killed
install left behind, because pip cleans up only on a normal exit. `/tmp` is now bounded so a
future leak fails loudly. The threshold is short and safe because the sweep runs at the top of
a cycle, before any worker exists; a longer threshold would only reclaim less. One measured
sweep returned **2,767 MB**.

The environment budget had the same shape of mistake in the other direction: `Envs.prune`
summed `st_size`, the length of each file's contents, while the disk is spent in **blocks**. A
site-packages directory is thousands of small modules and each rounds up to a whole block, so
the figure was about 10% low. The verifier's 9.1 GB of environments summed to 8.2 GB of file
lengths — *inside* an 8 GiB budget — so `prune` returned `(0, 0)` while the cache sat over its
bound. It now sums `st_blocks * 512`. A fixture of one large file cannot see this; the case
that rounds is many small files.

## A deadline spent in bytes, not seconds

`INSTALL_TIMEOUT` was a flat five minutes for every install. The tail of the watchlist is
machine learning: `nvidia-cudnn-cu12` is a 688 MB wheel, `nvidia-cublas-cu12` 398 MB,
`nvidia-nccl-cu12` 283 MB. The miner pulls about **2.8 MB/s** across six workers, so a 688 MB
wheel needs about twenty-five minutes and never fit. In three hours, **62 installs were killed
by the deadline**, close to a third of the miner's worker-seconds. A killed install keeps
nothing: pip commits a cache body only when the download finishes, so every attempt paid the
deadline in full and discarded every byte.

`envs.install_deadline` prices the deadline from the release's own payload, divided by a
worker's share of the measured link, floored at `INSTALL_TIMEOUT` and capped at
`MAX_INSTALL_TIMEOUT`. Only the release's own files are priced; a cheap release dragging a
large dependency tree is under-priced on its first attempt, and the retry doubles the
deadline, which is the evidence that the first was too short.

The first download ceiling was also wrong. It delayed the **start** of an install while the
recent rate was over the ceiling, reasoning that fewer starts is less traffic. Measured over
ten minutes it held **2.60 MB/s against a 2.00 ceiling**, barely under the 2.82 MB/s the miner
pulls with no ceiling: an install already running is not slowed by delaying the next one.
`Bandwidth::Throttle` now bounds **how many installs download at once**, adapts that count from
the measured rate, and has a floor of one download — pip has no rate control, so a ceiling
below the speed of one download is unreachable. A tested mechanism can still be the wrong one;
only measuring the number it existed to control showed that.

## Parallelism and its shared resources

The examining is subprocess-bound, so `--workers` (six by default) is the dial that matters.
Everything else in a cycle stays on one thread on purpose: the ledger is one file, the filings
are one operator's writes, and the write counter is one number. Three things that would each
need locking for no speed.

`Envs.build` takes a lock per environment path, not around the function. Two crossings of one
package share a release, so two workers ask for one directory at once; two `python -m venv`
runs into one path leave an environment half of each, and every finding from it is fabricated.
The lookup is inside the lock: an environment that *exists* is not an environment that is
finished. `venv` creates `bin/python` long before pip has installed anything, and the earlier
code handed that environment to any caller that saw the interpreter. The verifier then read
`ModuleNotFoundError: No module named 'httpx'` as “the call site no longer refuses” and
contradicted five true reports. A build that is killed by its timeout also leaves a directory
with an interpreter and part of a dependency tree; `Envs.installed?` now wants an interpreter
*and* a non-pip `.dist-info`, and a build that raises removes the directory.

Every probe writes its own script, suffixed with the examination's identity. A single
`call_site.py` is overwritten between the write and the run, so the traceback filed as evidence
could be another worker's call. The same collision in `Envs.inventory` had one worker deleting
the receipt another was about to read, which reads as “this release cannot be imported” and
loses the pair.

## The verifiers' three answers

A probe has three answers: refused, resolved, and **never ran**. `refused_symbol` returning
false covered both “the name is still there” and “the package was not in the environment”, and
the two want opposite verdicts. `Envs.unreached?` makes the third case distinct all the way to
the vote. A verifier that treated “I could not check this” as “it did not reproduce” would be a
machine for contradicting true reports; in its first hour it was exactly that.

The five bugs behind those eight wrong votes, all with a test that fails without the fix:

- an environment that existed but was not finished;
- a probe that never reached the release;
- an environment left half-built by a timeout;
- a stored symptom token lowercased (`documentAST=` arrives as `documentast=`) and compared as
  the spelling the caller used;
- a removal resolution that named the broken path before the destination, and a rule that read
  the broken path as the fix (`cython.CythonMetaType`), or two spellings of one package
  (`pymupdf` vs `pymupdf.JM_Warning`) with case differences.

The repair is to re-run the check: the service keeps one verification per operator per report,
so the corrected vote overwrites the wrong one in place.

The second operator exists because one execution written twice is one opinion. `as-reported`
runs the call sites the report names; `searched` re-derives the claim from the two releases and
ignores the report's prose. Across the live corpus they have disagreed on nothing since the
bugs above were fixed.

## Reviewed advisories are leads, not findings

GitHub's reviewed RubyGems set is about 1,160 advisories, weighted toward the gems this corpus
works on. It is used as a **lead** and never as a finding. The miner reads the set, posts the
whole picture to `POST /api/mining/advisories`, and the queue puts those packages in a tier
above the breadth seed and below anything the corpus has observed.

An advisory's `fixed_in` names the release the fix arrived in, so the planner targets that
crossing — including a patch inside the current line (`rack 2.2.6 -> 2.2.6.1`), which the line
ladder never produces. A finding that comes back is this corpus's own differential, filed and
verified like any other. A crossing that yields nothing files nothing, and the advisory stays
what it was: a documented claim. No advisory is written as a report or allowed to move a
report's status, trust or counters.

The source is the GitHub REST API rather than the bulk OSV archive because Ruby's standard
library has no zip reader; the API answers the same question in about twelve paged requests,
cached on the volume and read every six hours.

## What the corpus produced, and what it got wrong

The first corpus was 441 fixture reports and not one of them real. The first hour of real
mining examined 24 crossings, found 24 mechanisms, and took the live corpus from 0 to 22
executed reports. `sqlalchemy` 1.4.54 → 2.0.54 removed ten legacy arguments; `httpx` 0.27.2 →
0.28.1 renamed `proxies=` to `proxy=` across eleven call sites; `jinja2` 3.0.3 → 3.1.6 removed
`Markup`, `contextfunction` and `escape`.

Most crossings find nothing, which is the point: `requests`, `flask`, `fastapi`, `django`,
`celery`, `redis` and `boto3` crossed a minor line with no argument removed and no export
dropped. A corpus that claimed otherwise would be one nobody could act on.

At the last measurement, **771 live reports across 167 libraries, 764 at
`resolved_verified`**, each confirmed twice by execution. Seven were waiting for a
confirmation, and none carried a contradicting verification.

The wrong-fix audit above is the reason the word rule, the executed repair and the moved-name
search exist. The corpus was repaired rather than rewritten: unsupported reports were withdrawn
through the service's moderation path, and the pairs behind them forgotten so the corrected
findings were re-derived and re-filed. Two replacements came back better than either version:
`jsonpath-ng.JsonPathLexer` had moved to `jsonpath_ng.lexer.JsonPathLexer`, and
`sqlalchemy.IdentityOptions` to `sqlalchemy.sql.schema.IdentityOptions`. Asking the release
where a name is beats asking what it looks like.

## The eight wrong votes, and the other hard lessons

- **A rate limit swallowed by a helper never reaches the loop.** `RateLimited` is a
  `CorpusError`, and every helper that catches `CorpusError` to mean “this one item failed”
  also caught the quota; the pair looked done and the finding was never filed. Anywhere the
  client handles `CorpusError`, `RateLimited` is re-raised first.
- **A retry delay written and never read is not a delay.** The verifier recorded
  `next_at = now + REPORT_RETRY_SECONDS` and its work list asked `unresolved_seen()`, which
  knew nothing about it, so three attempts happened in consecutive cycles and a briefly
  unavailable release settled the report for good.
- **A permanent refusal and a transient one cannot be told apart by their message.** The status
  code decides; a 4xx is the service declining the request, a 5xx/timeout is the service being
  unavailable. A pair whose findings were deferred is left unsettled; one the corpus refused is
  settled.
- **A self-imposed write cap is still a cap.** The miner began with a fraction of the service's
  quota, on the reasoning that one machine should not spend the whole allowance. The quota was
  not the constraint, and the cap only made the corpus grow more slowly. It is off by default;
  the mechanism stays because a limit that is a choice should be visible.
- **A list sized by a guess about the work runs out.** The watchlist held 1,000 packages,
  documented as “a few dozen hours of mining” — measured, about right, which was the problem.
  Size a bound against the measured rate, and when the dry cycle has nothing to do, name the
  reasons with counts.
- **A bound on a response written as a bound on the request turns the client away.** The queue
  route validated `limit` with `le=`, the miner asked for 1,000 against a cap of 500, and every
  start was a 422. Its fallback read a failed queue as “no queue”, so the service's queue had
  never driven the miner. Clamp the value and serve the clamp, so a client pages instead of
  guessing.
