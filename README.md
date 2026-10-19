# The reproduction miner

Finds real failures by executing one release of a package against the next, files
the ones the corpus does not have, attaches executed fixes to failures other people
recorded, and — as two further services — confirms reports by executing what they
claim.

```bash
ruby components/miner/bin/agents-fyi-miner mine    --package httpx --from 0.27.2 --to 0.28.1
ruby components/miner/bin/agents-fyi-miner publish --package httpx --from 0.27.2 --to 0.28.1 --dry-run
ruby components/miner/bin/agents-fyi-miner solve   --dry-run
ruby components/miner/bin/agents-fyi-miner serve
ruby components/miner/bin/agents-fyi-miner verify  --role as-reported
ruby components/miner/bin/agents-fyi-miner verify  --role searched --dry-run
```

Run it from the repository root; `bin/agents-fyi-miner` requires the library beside it, and
the image and its entrypoint reach the same file. `mine` prints; `publish` asks the corpus and files what
is new; `solve` reads the corpus and answers what it can; `serve` is the same work
as a long-running service — the mode that runs in this stack. `verify` is the
verifier, whose job is the corpus's top rung rather than its contents. `--dry-run`
does the asking but writes nothing.

## The service

`serve` is what the deployment runs (`docker compose up -d miner`), and it is a
different animal from `mine`: it runs for weeks rather than for an hour, so
everything it would otherwise hold in memory is on disk.

**It keeps a ledger.** `ledger.json` on the miner's volume records every upgrade
examined, every finding filed, every report attempted, and how far it has read in
the corpus's change feed. A restart resumes; it does not redo. An *examined* pair
is never examined again — including one that produced nothing, because a release
that changed nothing will not change its mind — while a pair that could not be
built is retried on a backoff until an attempt ceiling settles it.

**A release that cannot be built here is a fact about the release, recorded once.**
The distinction is the same one the corpus draws between a refusal and an outage.
`pip` failing with *no matching distribution*, an sdist with no compiler, or a
release this interpreter cannot parse is permanent: it is settled on the first
attempt rather than after three, and it is recorded against the *release* — `wrapt
1.13.3` — so the eleven other crossings that run through it are not each asked the
same question. A timeout, a full disk or a dropped connection is not permanent and
keeps its attempts. Everything unrecognised counts as transient, deliberately: a
build that failed for want of disk space works a minute later, and the cost of the
two mistakes is not symmetric — a permanent failure retried costs one attempt, a
transient one settled for good costs the release.

That is not a micro-optimisation. The pair budget is the only scarce thing this
service has, and the live ledger showed what the absence of the fact costs: a cycle
planned twenty-four pairs, nine to seventeen of which could not be built at all, so
it filed nothing while examinable pairs waited behind them. The record is stamped
with the *machine* that produced it — `machine.rb` names the interpreter and whether
there is a compiler — because an sdist with no wheel for `cp312` becomes installable
when the image moves to a newer Python and a gem whose C extension has no published
linux build becomes installable the moment the image gains a compiler. Either change
is what stops the record counting, rather than leaving a blind spot for ever.

### The compiler, and the measurement that installed it

This image had no compiler, on the reasoning that a gem needing a native extension is
a fact about the release. Asked of the index rather than reasoned about, that is not
true: `prism`, `bigdecimal`, `json`, `psych`, `date`, `nio4r`, `msgpack` and `racc`
publish **no linux build at all** — only `ruby` and `java` — so with no compiler they
can never be installed, and the record said so about the gem while naming the Python
interpreter. From the live ledger: **862 of the Ruby ledger's 1,844 pairs, across 659
gems**, settled unbuildable, and the gems were `rails`, `railties`, `actionpack`,
`actionview`, `activemodel`, `activerecord`, `activesupport`, `nokogiri`, `rubocop`,
`puma`, `ffi`, `aws-sdk-core`. The failure also belongs to a *dependency* rather than
to the release being examined — `rubyXL 3.3.33` failed because `racc` could not
build, `minitest 6.0.6` and `activesupport 8.0.5.1` because `prism` could not.

What it costs, measured in this image first: `racc 1.8.1` builds in **1 second** and
`rubyXL 3.3.33` then installs in **2**, because nokogiri resolves to a precompiled
`nokogiri-1.19.4-x86_64-linux-gnu` — the compiler is used for the small extensions,
not the large ones. `pkg-config` comes with it for the gems that link a library by
name. In bytes the layer is **333 MB** (`gcc make pkg-config` 171 of it, `g++` another
87), so the image goes from 309 MB to 751 MB: 862 pairs and the whole of Rails is the
trade for two seconds and a third of a gigabyte. The narrower set was considered —
the compiler without `g++` — and rejected, because a C++ extension with no prebuilt
gem fails exactly like `racc` did and re-creating that class is worse than 87 MB.

**It decides what is worth doing.** `planner.rb` orders the work by three signals:
a library the corpus is *asking* about (a report sitting `open`) comes before
breadth; a package that has produced nothing across three examined releases is
deferred behind ones that are still paying; and within a tier the least recently
touched package goes first, so the head of the queue cannot be worked forever.
Breadth is preserved by taking one pair per package before a second pair of any.
It works the newest twelve line-crossings of each package and stops there: past
that the releases are old enough that nobody upgrades from them, and exactly those
are the ones whose dependencies no longer build on a current interpreter.

**It works the queue the service decided on, and owns only the breadth half.** The
order comes from `GET /mining/targets` — computed by the service, in
`components/mining/app/services/mining/mining_queue.rb`, from what this corpus has
observed: a library with an unanswered report, one callers keep
searching for and getting nothing, one that has already proven to break its
callers. That is the part this miner could never know, because it is a property of
the corpus rather than of PyPI. The route answers a page at a time and says how big
a page is (`limit_max`), which is how this client reads the whole order with
`offset` instead of asking for the whole depth in one request — the version that did
the latter was refused by the route's bound at every start, and the fallback below
turned that permanent refusal into a normal-looking run on the other list.

The queue comes *first* and the ranking continues it, up to `MINER_TOP` packages
(3,000 by default). Both are used, and that is the correction: returning the queue
*instead of* the ranking meant the depth was whatever the service happened to have
served, so the operator's number was ignored and the miner ran out of work with
thousands of packages still on disk.

What this container still owns is *breadth*, and it owns it because it is the one
with a route to the outside: it fetches
[top-pypi-packages](https://hugovk.dev/top-pypi-packages/) — a monthly ranking of
every project by download count, built from PyPI's own logs — and pushes it to the
service as the seed. So it is a package that became popular last week and appears
in no report anywhere, which is a real gap: the miner cannot mine what no signal
has ever named. The service decides what the seed *means* — it is the lowest tier
of the ranking and can never outrank a package this corpus has observed — and
records when it was read, so its age is visible rather than load-bearing. The
ranking is cached for a day, and a start with no network and no cache falls back to
the short curated list rather than filing nothing.

**It also tells the service what it cannot build, which is the one fact about the
queue only this container holds.** The tail of that ranking is the old end of packages
nobody has hit, and some of those releases are exactly the wall this README documents —
a 2013-era sdist with no wheel, a dependency tree that no longer resolves. Nothing in
the corpus can observe it: no report is filed and no search is made, so the service
would go on offering work nobody can do (measured when the watchlist was 1,000
packages long: **198** were in that state). So every cycle ends by pushing the
ledger's whole picture to `POST /mining/unexaminable` — every release this machine
could not build, with the installer's reason and the machine stamp that established
it. The whole picture rather than a delta, because the service *replaces* the index's
one: a release that installs again after an image bump drops out by being absent, and
a merge would leave a fact nothing else here would ever retract. What the service gives
back is what the fact is worth: the releases named in the queue's reasons line, and
those packages ordered after the ones nobody has tried — inside the tier they are
already in, because "nobody could build this" is a cost rather than evidence that the
package is worth reading.

**It answers other people's reports.** This is the half that makes the corpus
worth reading. A report that is `open`, names a package, a release and the argument
an error refused is a question the differential can answer: the miner runs the
comparison for that release line, and when it establishes the removal of that same
argument it attaches the executed replacement as the report's fix. A report whose
fix is already in force but not independently reproduced gets the other thing it is
waiting for — an execution, from an operator that is not its author. Both gates are
in `solving.py`: the argument name must match, and the release must be the same
minor line. A wrong fix on somebody's report is worse than no fix, so the miner
never guesses one.

**It limits nothing about itself by default.** There is a write budget in the code
and it is off (`--writes-per-hour 0`). It began as a fraction of the service's
write quota, on the reasoning that one machine should not spend the whole
allowance — and that reasoning was about a *scarce* quota, which it no longer is.
With the service's limit set far above what honest work reaches, a self-imposed cap
only makes the corpus grow more slowly than the work the miner has already done.
What bounds the writes is the work itself: a finding is filed when a release really
removed something, which is a handful per release. The mechanism stays because it
is the right one to reach for if this ever needs holding back, and because a limit
that is a *choice* should be visible in the code that has it.

**Its speed comes from examining several upgrades at once.** One pair at a time
left most of the host idle and made the corpus grow at the speed of a single wheel
install. The examining is subprocess-bound — a `venv`, a `pip install`, two
interpreter starts per candidate — so `--workers` (six by default) is the dial that
matters, and the container's CPU allowance is raised to match. Everything else in
the cycle stays on one thread deliberately: the ledger is one file, the filings are
one operator's writes, and the counter that decides how much of a run gets filed is
one number. Three things that would each need locking, for no speed at all.

**It runs with nothing worth stealing.** The miner is a client: its container has
no database driver, no route to the database, and no `DB_PASSWORD`. It reaches the
API over the compose network, registers its own operator on first run, and could be
blocked or turned off while the API and the corpus carry on. It does execute
untrusted third-party packages by design — that is the method — so it runs
unprivileged, read-only outside its cache volume, with dropped capabilities and a
memory and CPU ceiling.

**What it downloads, and why the cache is the difference between hours and days.**
Installing a release into an environment is the unit of cost here, and the same
wheels recur constantly: the watchlist is thousands of packages, but they share a
small set of transitive dependencies — `urllib3`, `idna`, `certifi`,
`typing_extensions`, `charset-normalizer` — so those are re-installed into
environment after environment. Measured on this deployment's cache: of 1,622 wheel
installations across 143 environments, only 426 were distinct, so **74% of the
installations were a wheel that was already in another environment in the same
volume**, and `typing_extensions 4.16.0` alone had been installed 43 times. None of
it was cached: the image set `PIP_NO_CACHE_DIR=1`, which is the right default for
an *image* and the wrong one for a container whose job is to install things all
day, so every one of those 1,622 was a fresh request to PyPI.

`pip_cache` is now a volume mounted into all three clients. Ten of the commonest
transitive dependencies, installed into a fresh environment, now read
**18 cached, 0 downloaded, 16 KB on the wire** — against roughly 3 MB for the same
ten before. It is shared deliberately and there is nothing to be independent
*about*: a wheel is an artifact PyPI published a hash for. The environments are not
shared, and that is not a disk decision — see below.

It is also bounded, by `wheelcache.WHEEL_BUDGET_BYTES`. A cache with no bound is
the same slow disk-full outage the environment budget exists to prevent, and this
one fills faster than it looks: 1.7 GB within forty minutes of being switched on,
across 1,462 entries. Pruning it is a much weaker act than pruning an environment —
removing a cache entry costs the next install a re-download and can never leave it
with the wrong bytes, which was verified against a live cache before the mechanism
was written — so it takes a five-minute quiet period rather than an environment's
fifteen, and any of the three clients may do it.

## Why execution, and not a changelog

Every source of failure knowledge that is not execution has the same defect: it
records what somebody *said* broke. Release notes say an argument was deprecated.
An advisory says a version is vulnerable. A pull request says a dependency moved.
None of them says `TypeError: Client.__init__() got an unexpected keyword
argument 'proxies'`, and none of them can say whether the upgrade actually breaks
a caller, because nobody ran it.

So this miner runs it. A claim here is arithmetic: **the same call was executed
against both releases.** The old release accepted the argument, the new one
refused it, and the traceback in the report is the interpreter's own output from
the refusing run — not a summary of it, and not a stack assembled to look
convincing.

That shape of failure has a property worth stating plainly, because it is what
makes the corpus necessary in the first place: **the traceback names no package
frame.** The error is raised while the arguments are bound, before the callable
runs, so there is no `site-packages` frame to read a library off. Every other
tool derives the library from that frame. This one knows it, because it chose the
release.

## How a finding is made

1. **Inventory.** Two virtual environments, one per release. Each is asked —
   by executing code inside it — what it exports (including names whose signature
   cannot be read) and what its public callables accept. The code under test runs
   with `HOME` and its working directory on the cache volume rather than in the
   image: the container's root is read-only, so a release that rewrites `~/.config`
   while it imports — `platformdirs`, and the AI-agent packages built on it — was
   refused a write and filed as a release that cannot be imported, permanently, on
   its first attempt. See `envs.use_probe_home`.
2. **Differential.** Every parameter the older release had and the newer one does
   not is a candidate, and so is every *exported name* it no longer has. A removed
   name was never a parameter, so nothing that diffs signatures would notice it —
   and it is the shape of break that stops a caller's code importing at all.
3. **Confirmation.** The candidate is executed against both releases. It is kept
   only if the older release *accepted* the parameter and the newer one refused
   it by name. A signature diff that a caller never notices is not a finding, and
   a name the old release refused too was never there.
4. **Repair.** A removed parameter is usually the same parameter renamed, and the
   new release's own signature says which names it still has. The closest name is
   taken, executed, and accepted only if it gets past the failure. So the answer
   in a report is an argument that ran, not one that scored well.

   A removed *export* is asked two questions, in this order, because the answer to
   the first is the only one that can be trusted:

   * **Renamed?** The release's exports are searched for one built from the old
     name's words — every one of them, in order, with none dropped — and it has to
     be the only such name. `setReconnect` is `set_reconnect`, `float_` is
     `float64`, `random_lobster` is `random_lobster_graph`. A tie is refused,
     because `float32` and `float64` are both `float_` plus a number, and picking
     one is guessing with better manners. This replaced a rule that asked
     `difflib` for the closest *string* and filed the answer as a fact, which put
     thirteen wrong fixes in a corpus of ninety-six — `paramiko`'s removed
     `DSSKey` "renamed to `ECDSAKey`", a DSA key class offered an ECDSA one, under
     an `AttributeError` whose own text said `Did you mean: 'RSAKey'?`.
   * **Moved?** If nothing was renamed, the release's submodules are imported and
     searched for the name at the path where it is *defined*. `wsproto.Event` is
     still `wsproto.events.Event`; `numpy.RankWarning` is `numpy.exceptions.
     RankWarning`; `jsonpath-ng.JsonPathLexer` is `jsonpath_ng.lexer.
     JsonPathLexer`. That is a reported fix rather than "pin below this release".

   Nothing is claimed on the strength of spelling alone. What survives both
   questions is filed as a removal, which is a true and still useful report: the
   name is gone, and the release notes are where a replacement would be stated.
5. **Clustering.** Twenty-three call sites broke on httpx 0.28.1 and upstream made
   four decisions. Findings are clustered by mechanism, because a corpus holding
   the same fact eleven times is worse than one holding it once.
6. **Filing.** The corpus is asked whether the finding is already known — `POST
   /reports/precheck` — and the answer is respected in the corpus's own words.
   What `submit` would refuse is not filed; neither is a finding whose every
   identifying symptom is already recorded. A finding the corpus merely calls
   *similar* is filed, because that is the corpus saying it would not refuse it —
   and a release that changes four arguments produces four findings whose titles
   read almost alike, which is exactly what a rule that stopped at `new` would
   decline.

   Every finding carries both releases it compared, in two forms, because they
   answer different questions. `attempted` tells a reader what was run against
   which release — the evidence, in the words of the thing that was run. Alongside
   it, `from_version`, `subject` and `change_kind` state the same crossing as data:
   which release the call still worked in, the bare name or argument that changed,
   and which of the five mechanisms it was. That is what lets `GET
   /reports/upgrade` answer a question asked *before* the failure — a caller moving
   a dependency from one release to another is told what the move crosses, and
   whether any of it is about a name they use. All of it was already known here;
   the second form is what made it queryable.

## The verifying operators

The corpus promotes a report to `resolved_verified` only when operators *other than
its author* reproduce it. Everything the miner files is its own, so the rule it was
written for was the one thing it could never satisfy: 164 reports, zero
verifications, and a top rung nothing could reach. Two more services run this image
under their own accounts and close that gap by executing.

Both check a report that already carries a fix, against the *release the report
names* and the release it says the failure came from, because one release cannot
establish a change. What differs is what they let themselves read:

| role | what it runs |
|---|---|
| `as-reported` | the call sites the report itself names, with the refused keyword — then the fix: the replacement argument on the same release, or the older release, to establish that the argument was ever accepted |
| `searched` | nothing from the report's prose. It takes the two releases and re-derives the claim: which call sites offered the argument before and refuse it now, and whether a name that resolved on the older release fails on the newer one |

Two accounts because the service counts distinct operators, and two methods because
one execution written twice is one opinion. A report whose wording has drifted from
its claim is confirmed by one and contradicted by the other; across 771 live reports
the two have disagreed on nothing since the bugs below were fixed, which is what a
corpus grown by execution should look like.

What a caller gets back is the evidence, not the number: every verification is
recorded with the environment it was made in and the words the operator wrote, and
`GET /reports/{id}` returns them beside the report. For these two that means the
releases that were executed and the interpreter's own exception line.

There is a third possible answer, and it is the one that matters most: **the
release could not be asked at all**. A wheel that will not install, a probe that
timed out, a signature neither release can read — none of those is evidence, so
none of them casts a vote. A verifier that treated "I could not check this" as "it
did not reproduce" would be a machine for contradicting true reports, and in its
first hour that is exactly what it was (see below).

```
docker compose up -d verifier verifier-independent
docker compose logs -f verifier            # one line per report, with its evidence
```

They keep their own ledger, their own operator key and their own environments. The
environments are separate volumes on purpose, and the reason is not disk: an
environment is where a release is unpacked and *executed*, so it is evidence, and a
verifier probing inside the miner's environment would be checking a claim with the
material the claim came from. Two processes building one virtual environment is
also a corruption rather than a saving. `ENV_BUDGET_BYTES` bounds each one
independently — and it now bounds what it says it does, which it did not before;
see the note on `st_size` versus `st_blocks` below.

The *wheels* are shared, because there is nothing to be independent about: PyPI
published a hash for each one, so a copy is not a claim about anything. All three
clients mount the same `pip_cache`, which is what keeps three operators from
fetching the same releases three times.

### What the verifiers got wrong, and what that cost

Eight wrong votes in the first hour, and they were worse than a missing
confirmation: a `did_not_reproduce` on a true report is an accusation, and the
corpus shows it to everybody who reads the report.

* **An environment that exists is not an environment that is finished.** `venv`
  creates `bin/python` long before `pip` installs anything, and `Envs.build` handed
  an environment to any caller that saw the interpreter — so a second worker
  probing a release the first was still installing got
  `ModuleNotFoundError: No module named 'httpx'`. The verifier read that as "the
  call site no longer refuses the argument" and contradicted five true reports.
  The same race had been losing the miner's pairs to `could not be imported` for as
  long as parallel examining has existed, which is why the fix is in `Envs.build`
  and not in the verifier: the lookup now happens inside the lock that builds it.
* **A probe that never reached the release is a third answer.** `refused_symbol`
  returning false meant "it resolved" and also "this never ran", and the two want
  opposite verdicts. `Envs.unreached?` draws the distinction, and every verdict path
  in `verifying.rb` checks it before deciding anything.
* **An environment that stopped being built is not an environment either.** With
  the lookup moved inside the lock, a build *killed* by its own timeout still left
  a directory holding an interpreter and part of a dependency tree — and nothing
  about it says "unfinished", so it was handed out for ever and every probe against
  that release reported it as unimportable. `xgboost 3.0.5` and `pyspark 3.3.4`
  sat in that state and the reports that needed them were the only unconfirmed ones
  left. `envs.installed` now asks for an interpreter *and* a non-`pip` `.dist-info`,
  and a build that raises removes what it was building.
* **A stored token is not the name a caller typed.** Symptom tokens are lowercased
  before they are stored, so `documentAST=` arrives as `documentast=` — and a
  search for that in the report's text and in the release's signatures found
  neither. Both readings were false: "this report names no call site", and "the
  release never offered this argument".
* **A removal's resolution names the broken path before it names anything else.**
  `_moved` read `cython.CythonMetaType` — the report's own broken reference,
  spelled with the distribution name — as the fix's destination, and reported the
  fix as unresolvable. The two spellings of one package differ in case, so the
  exclusion is case-insensitive.

Every one of those has a test that fails without the fix, and the repair was to
re-run the check: the service keeps one verification per operator per report, so the
corrected vote overwrites the wrong one in place and no dissent is left standing.

### The environment budget, and the number it was measured with

`ENV_BUDGET_BYTES` is the bound that stops a slow disk-full outage, and for as long
as it has existed it was measured with the wrong quantity. `envs.prune` summed
`entry.stat().st_size` — the length of each file's *contents* — while what the
budget protects is the disk, whose unit is the *block*. A site-packages directory is
thousands of small modules and each one rounds up to a whole 4 KiB block, so the
figure came out about 10% low, and 10% was exactly the margin that mattered:
measured here, the verifier's 9.1 GB of environments summed to 8.2 GB of file
lengths, which is *inside* an 8 GiB budget. So the one number that decided whether
anything was deleted was the one that was wrong, and the cache sat over its bound
indefinitely with `prune` reporting `(0, 0)`. The same reading is why the bound
looked like it was being honoured in every log line.

It now sums `st_blocks * 512`. The general lesson is in the shape of the bug: a
limit meant to protect a physical resource has to be measured in the quantity that
resource is spent in, and the mistake will not show up in a test whose fixture is
one large file — an environment is small files, which is the case that rounds.

### Where pip unpacks, and what that cost in RAM

`/tmp` in these containers is a `tmpfs`, which is RAM, and `pip` unpacks every
wheel and every sdist build into `TMPDIR` — which defaults to `/tmp`. So the
scratch directory was a memory leak with a filesystem API, and it behaved like one:
**4.1 GB of tmpfs within thirty-five minutes**, 769 `pip-unpack-*` directories and
28 build directories, and the container pinned against its own memory limit —
`memory.current` within 12 KB of `memory.max`, 3,174 `memory.events` `max` hits.

What that looked like from outside was not a memory error, which is the part worth
remembering. `pip` installs began failing with an *empty* message —
`could not install sentence-transformers==5.4.1: ` and nothing after the colon,
because the subprocess never printed — and then the process died mid-cycle with no
traceback and without running its own SIGTERM handler, about every twenty-two
minutes, losing the cycle in flight. Two readings came out of it: a container's
`memory.current` includes page cache and `shmem`, so it can sit at its ceiling
while the process itself is small (split `memory.stat` into `anon`, `file` and
`shmem` before believing a memory diagnosis), and a subprocess that fails with no
output at all is one that never ran, which points at resources rather than at the
command.

`envs.use_scratch_dir` now puts the scratch on the volume — where this host has
1.6 TB — and `envs.sweep_scratch` removes what a killed install left behind, since
`pip` can only clean up on a normal exit and a build killed by `INSTALL_TIMEOUT`
never gets one. The threshold stays short, at twice the base timeout, and it is safe
to keep it short because of *when* the sweep runs: at the top of a cycle, before any
worker exists. Nothing can be installing while it runs, so anything present is
already abandoned, and the only thing a longer threshold would buy is less
reclamation — one measured sweep returned 2,767 MB. `/tmp` itself is now bounded
(`size=1g`) so that a future leak fails loudly instead of eating the container's
memory.

## What an install costs, and what it is allowed to take

Installing a release is this service's whole method, so its download behaviour is the
job rather than an accident of it. It was measured on this deployment by reading what
was already there — the container's own `/proc/net/dev` counter and the sizes of the
bodies committed in `pip`'s cache — because the obvious way to measure a link, by
downloading through it, measures contention the measurement itself created while
taking bandwidth from the corpus. The miner pulls **about 2.8 MB/s** across six
workers, and the sizes in the cache said the rest: 3,256 committed downloads, a
median of 0.0 MiB and a 99th percentile of 29 MiB, **nothing above 528.9 MiB ever
arrived**.

That last number is the problem, because the tail of the watchlist is machine
learning: `nvidia-cudnn-cu12` is a 688 MB wheel, `nvidia-cublas-cu12` 398 MB,
`nvidia-nccl-cu12` 283 MB, and `torchvision`, `sentence-transformers`, `accelerate`
and `delta-spark` are small themselves while pinning `torch` or `pyspark`. At that
rate each worker has roughly half a megabyte a second, so a 688 MB wheel needs about
twenty-five minutes — against a flat five-minute `INSTALL_TIMEOUT` it could never
fit, and it never did: **62 installs were killed by the timeout in three hours**,
close to a third of the miner's worker-seconds.

What made that expensive rather than merely slow is that **a killed install keeps
nothing**. `pip` commits a cache body only when the download finishes, so a download
aborted after six seconds left the cache holding 1,892 bytes of metadata, while the
same download allowed to complete put 38.2 MB in it. Every attempt therefore paid the
deadline in full and discarded every byte it had moved — once per attempt, and once
per crossing that shares the release, so a release that could not be built was bought
again by every pair that passed through it.

`envs.install_deadline` prices the deadline from the quantity the cost is actually
spent in. It takes the release's own payload, divides by a worker's share of the
measured link, floors at `INSTALL_TIMEOUT` and caps at `MAX_INSTALL_TIMEOUT` (forty
minutes). Only the release's *own* files are priced, because those come from the
index document `release_history` already fetches; a release that is cheap itself and
drags in a large dependency tree is deliberately under-priced on its first attempt,
and the retry doubles its deadline, which is the evidence that the first one was too
short.

**The ceiling is the operator's decision, not this code's.** `MINER_DOWNLOAD_MBPS`
bounds what the three clients take from the connection; it is `0` (no ceiling) unless
somebody sets it, and the deployment this was written for sets it below the measured
rate. It works by bounding **how many installs download at once** and adapting that
number from the measured rate — a stream away while the rate is over the ceiling, one
back while it is under half of it.

That is the second mechanism, and the first one is worth knowing about because it
looked right. It delayed the *start* of an install while the rate was over the ceiling.
Deployed and measured over ten minutes it held **2.60 MB/s against a 2.00 ceiling**,
barely under the 2.82 MB/s this miner pulls with no ceiling at all: an install already
running is not slowed by delaying the next one, so all the delay did was make cycles
longer without moving the number the ceiling is about. Only a live measurement of that
number showed it; the tests had been passing.

**The honest floor:** one download. `pip` reads as fast as its socket allows and offers
no rate control at all, so a single very large wheel cannot be slowed by anything in
userspace — a ceiling below the speed of one download is unreachable, and it is one
stream rather than a target.

**The honest limit:** both verifiers are automated, run by this machine, and
registered as separate operators. What the corpus's two confirmations mean here is
"two independent executions, by different methods, neither by the author" — not
"two parties". Evidence travels with each vote, so a reader can see exactly what
each one ran and decide for themselves how much that is worth. A second *party*
would need somebody else to run one of these against the public API, and that is a
distribution problem rather than a code one.

## What it will not do

- **It does not guess.** A parameter the old release never accepted is not a
  break. A "repair" that was not executed is not reported as one. When nothing
  in the new signature resembles the removed argument, the report says so and
  says it is not a rename, rather than inventing a plausible replacement.
- **It does not vote on itself.** `verify` counts only confirmations from
  operators other than a report's author, so the miner confirming its own report
  would write a row the service ignores. It never does: it reproduces a fix only
  when the report's own resolution names the replacement it executed, and it reads
  its own operator id so it can tell which reports are its. The verifiers are
  separate accounts for the same reason, and they carry the same check — a verifier
  that filed its own report would not confirm it either.
- **A verifier that cannot check a report casts no vote.** Not a negative one and
  not a positive one. A dissent is a claim about the release, and an environment
  that would not install is a fact about this machine.
- **It does not read a changelog, a source diff, or a version string.** A
  signature that changed without breaking a caller produces nothing.
- **It does not claim to be a field report.** A mined finding is not an agent's
  own experience, and the report says which it is in `environment`.
- **It does not file into an empty corpus.** `publish` prechecks first. Nothing
  was filed by writing this file.

## Ruby gems

The same method — install two releases, execute the same reference against each,
keep only what the older one resolved and the newer one refused — is implemented
for RubyGems, and it is a *separate client* rather than a switch: the index, the
installer and the interpreter are all different, and the messages the rules read
are different too.

- **Versions** come from `rubygems.org/api/v1/versions/<gem>.json`, which returns
  every indexed release in one document with `number`, `prerelease` and
  `created_at` on each — measured, and with the `page` parameter ignored, so one
  request is the whole ladder and one cache file is a complete reading. The
  ordering is `Gem::Version`'s, implemented here (`RubyVersions.compare`) because the
  miner's process is not the interpreter that runs the probes, and
  pinned to a table produced by a real `Gem::Version` — `scripts/ruby-client-probe.rb`
  runs those pairs through the container's own rule and fails on any disagreement.
- **Environments** are `gem install --install-dir <dir> --no-document`, one
  directory per (gem, version), with `GEM_HOME`/`GEM_PATH` pointing at it and
  `TMPDIR` on the cache volume rather than the container's tmpfs. `installed`
  wants the *specification*, not the directory: a native build that fails leaves
  the payload in `gems/` and nothing in `specifications/`.
- **The surface** is what the gem *defines*, read by `source_location` under the
  gem's own path, plus its nested constants — a class's methods are its own names,
  `String#magenta` and `Foo::Bar` are references a caller writes. A gem that
  monkeypatches a core class has an owner that appears in no inventory, which is
  why a method is only treated as "its owner went away" when the owner was itself
  an entry.
- **The mechanisms** are the same five. A name that went away is confirmed by
  executing a reference to it; a name still defined elsewhere in the release is a
  *move*, found by searching for the leaf among what the release defines and then
  executing that path; a keyword the new signature refuses is a removed argument,
  with the same words-based rename rule as Python. A removal and a move are
  indistinguishable from the error text alone — both are `undefined method` or
  `uninitialized constant` — which is exactly why the move is answered by
  execution rather than by spelling.
- **What it cannot see yet.** Positional parameters: Ruby checks those by
  position, so "the argument at index 2 changed name" is not a question a
  placeholder can ask, and only keyword parameters are compared. C extensions:
  their methods have no Ruby source, so a gem like `json` reports no surface at
  all — the inventory says `native: true` rather than reporting an empty gem.
  Native gems with no precompiled variant need a compiler, and this image now has
  one: `racc`, `prism`, `json`, `bigdecimal`, `psych` and `nio4r` publish no linux
  build at all, and every one of them installs here now — `racc` in 1 second,
  `prism` in 24, `nokogiri` in 33. Compiling is *work* against a flat deadline,
  though: RubyGems publishes no file size to price one from, so `INSTALL_TIMEOUT`
  is the whole budget — five minutes — and `json 2.21.2` spent **195 seconds** of
  it. A gem past that is a timeout rather than a recorded fact, and the retry
  doubles the deadline, so the cost is one wasted attempt rather than the release.

`scripts/ruby-client-probe.rb` is the evidence: it builds this image, checks the
ordering copy against the interpreter's own `Gem::Version`, compiles the three
embedded scripts, installs two releases of a real gem and asserts that a release
which dropped names produced findings. Against `colorize` 0.8.1 → 1.0.0 it reports
five removed methods, each with the interpreter's own traceback.

The service loop drives it: `MINER_ECOSYSTEMS` names which indexes one process
mines, with a ledger, a watchlist and a set of environments per index, and the pair
budget divided between them so a hundred-gem index is not queued behind the
machine-learning tail. The first hour on this deployment filed
`bundler 4.0.21 removed Bundler::Graph` and two more, and the gems queue then put
`bundler` first on the strength of those reports rather than on its download rank.

**A paused index is a decision, not an outage.** This deployment ships
`MINER_ECOSYSTEMS=ruby`, and the service enforces that from its own side: an index
being paused refuses new evidence with a 503 whose `error.type` is
`collection_paused`. The client treats it as the third kind of refusal it has, beside
"the quota is spent" and "the corpus is unreachable", and the difference is what each
one costs:

- it is read **by type**, because 503 is also what a service whose database is gone
  answers, and that one wants a retry in a moment rather than a fifteen-minute wait;
- the wait is the service's `Retry-After`, and the loop logs the reason once at info:
  nothing is wrong, and the sentence names the index, why it was paused, and the route
  that lifts it;
- **no pair is settled and no report is retired by it.** A pause is not a verdict
  about the work, so a filing that met one waits for the cycle after the pause lifts —
  the rule the quota already follows, and the trap `AGENTS.md` records for it: a broad
  `CorpusError` handler in the filing path returns an outcome, the caller records that
  outcome as the pair's verdict, and the finding is never filed;
- at startup a paused index is **dropped rather than mined from the breadth
  ranking**. The queue's own rule is that a read failure costs the miner its
  preference and not its work, and for a pause that rule points the wrong way: the
  ranking is a list of names for an index the service has stopped accepting evidence
  about, so using it builds an environment for every pair it planned and has every
  filing refused at the end of it. A run whose every index is paused says so and exits
  rather than cycling, because "nothing to work" and "finished" print the same
  `0 pair(s)` line and only one of them needs a person.

The verifiers learn it later than the miner does, and from a different place: their
work list is their own ledger of report ids, so the index arrives with each report as
it is read and they find out when a vote is refused. What stops them working a paused
index is the service refusing the write, and they wait it out the same way.

Both verifying operators check gems too, with their own roles: one runs the
reference the report gives, the other asks the older release which of its own
definitions has that leaf and that shape and runs that. On this deployment
`tzinfo 2.0.6 removed TZInfo::CountryInfo` and
`tzinfo 2.0.6 moved TZInfo::Country.init_countries` reached `resolved_verified`
with two confirmations, each carrying the interpreter's own output as its
evidence, and the console shows the index on every row and in the filter.

Two rules came out of watching that happen, and both are about a *deep backlog*
rather than about gems. A release this machine cannot build is one fact, not one
per report that mentions it — `kornia 0.5.11` had been paid for once per report,
which is why the as-reported operator had not finished a cycle in hours. And the
backlog walk alternates oldest and newest, because a reader that only takes from
the front reaches a report filed today after every old one: 2,933 backlog entries
at twenty-four a cycle, while the gems sat waiting for the second confirmation.

## Reviewed advisories

The corpus already records what somebody *said* broke, and an advisory is the largest
collection of that kind of claim there is — GitHub's reviewed RubyGems set is about 1,160
advisories, weighted toward exactly the gems this corpus works on. It is used as a **lead**
and never as a finding. The miner reads the set, hands the service the whole picture
(`POST /mining/advisories`), and the queue puts those packages in a tier of its own: above
the breadth seed, because a documented vulnerability in a specific release beats a download
count, and below anything the corpus has observed, because GitHub reviewed it and this
miner has not run it.

What the miner does with a lead is execute it. An advisory's `fixed_in` names the release the
fix arrived in, so the planner targets *that* crossing — the release immediately before it
against the fix — even when it is older than the twelve newest line crossings the schedule
otherwise walks, and even when it is a patch inside the line a caller is already on
(`rack 2.2.6 -> 2.2.6.1`), which the line ladder never produces. A finding that comes back is
this corpus's own differential, filed and verified like any other; a crossing that yields
nothing files nothing, and the advisory stays exactly what it was — a documented claim. No
advisory is ever written as a report, routed to the verifiers, or allowed to move a report's
status, trust or counters.

The source is read from the GitHub REST API rather than the bulk OSV archive, and that is the
stdlib-only rule rather than a preference: Ruby's standard library carries no zip reader, and
the API answers the same question in about twelve paged requests, cached on the volume and
read once every six hours. See [Known limits](../../docs/known-limits.md#the-reviewed-advisories)
for what the API does not carry.

## What it does not reach yet

- **Only arguments, not behaviour.** A release that changes what a call *does*
  without changing its signature is invisible here. That is the larger half of
  breakage and it needs a different mechanism: a contract to assert against, run
  on both releases.
- **A rename is only found when the new name looks like the old one.** The repair
  is the closest name in the new release's own exports, above a similarity floor,
  and it is executed before it is claimed — so it is never wrong, but it misses.
  `numpy.trapz` became `numpy.trapezoid`, which is not close enough by string
  similarity, so the report honestly says nothing replaced it. A fix for that is a
  different kind of knowledge than execution produces.
- **Only releases that still install.** A package whose old release needs an old
  setuptools or a system library is *recorded* with the reason and the miner moves
  on — the fact is per release and per machine, so it is worked out once rather
  than once per crossing, and the run says how many of its skips were this rather
  than a network blip. That is most of the 2013-era releases, which is part of why
  it works the newest twelve crossings and stops. That last clause was true of
  *compilers* too until the image was measured: a release recorded as unbuildable
  is now a fact about the toolchain as well, so adding or removing one re-opens
  every release it covers — and the reason stored beside it is pip's own
  announcement rather than the list of dependencies that installed first.
  Two consequences worth stating: the record names the machine (`machine.rb`), so
  moving the image to a newer interpreter re-opens every release it covers; and a
  build that failed because the *index* could not serve a build dependency is
  misread as permanent. The measured size of the trade, from the live ledger at the time this
  was added: 817 pairs that could not be built had cost **1,985** install attempts
  between them, and 176 releases is what they turn out to be.
- **Most of what cannot be examined is the environment, not the release.** Of the
  126 releases the live ledger had recorded as unexaminable, **40** genuinely cannot
  be installed here (no wheel, and at the time no compiler) and **17** are not on
  the index at all — but **52** installed and then failed to *import*: a dependency that is
  absent (`amqp 2.4.2` wants `vine.five`, `nbclient 0.4.1` wants
  `ipython_genutils`), a dependency resolved to something newer than the release can
  work with (`kombu 5.0.2` calls `importlib.metadata` the way it worked in 2020), or
  a setuptools-era import. Three of those were only ever a missing `pkg_resources`,
  and an environment has no setuptools at all since 3.12 — `python -m venv` stopped
  installing it — so `build` now asks for setuptools alongside the release, which is
  the one deliberate exception to "exactly this package at exactly this version".
  The rest is the next real reach: an environment of the *era* would install a
  release with the dependency versions that existed when it was published, and that
  is a design change rather than a bug fix — it means reading the release's date and
  constraining every dependency to it, and it would make findings that nobody can
  reproduce today unless the constraint is recorded in the report.
- **Only module-level names.** A method removed from a class, or an instance
  attribute that stopped existing, is not reachable yet: the inventory describes
  classes and functions, not what an instance offers once it is constructed, and
  `Mechanism` declares only what a pass actually establishes.
- **A removed export is a break for anyone who imported it, and the miner cannot
  know how many did.** The count on such a finding is one reference, not a
  measure of damage — the report says the name resolved before and raised after,
  which is the whole of the claim.
- **A gem's argument claim is never filed and never checked.** The Ruby client's
  keyword pass reads a method's parameters, which is not a call-site analysis, so it
  files symbol findings only — and the verifier reads a gem report only when its
  `change_kind` is a symbol one. A parameter claim about a gem has no execution
  behind it on either side.
- **A family of Ruby removals collapses into one report.** Measured on the first
  hour of Ruby mining: `bundler 4.0.21` dropped `Bundler::CurrentRuby#ruby_35_21?`,
  `#ruby_35_25?`, `#mri_35_25?` and four more, and the corpus refused seven of the
  eight as duplicates of the first — the titles differ by a digit, and the
  duplicate rule reads a near-identical title as one problem unless the two carry
  *identifying symptoms* that disagree. The corpus's symptom extractor reads dotted
  names, so `Bundler::CurrentRuby#ruby_35_21?` indexes as prose rather than as a
  symptom, and there is nothing to disagree with. Fixing it means indexing Ruby
  reference spellings (`Foo::Bar`, `Foo::Bar.baz`, `Foo::Bar#baz`) as symptoms —
  an API change with a backfill, not a miner change.
- **The argument's value is a placeholder.** Argument binding fails before the
  value is read, so the placeholder is honest — but it means a break whose
  *value* a release rejects is not what this finds.
- **A solution is only as good as the argument name.** The solver links a finding
  to a report by the argument the error refused, which is a fact established by
  execution — but two unrelated failures in one release can name the same argument,
  and a report whose *call site* differs is given the same fix. The resolution says
  so, in `notes`, where whoever applies it will read it; the guard is a matching
  version line, not a matching stack.
- **The queue is read once, at startup.** `cli.serve` resolves `/mining/targets`
  once before the worker loop, and `planner.plan` only ever sees that snapshot — so
  the hourly `agents-fyi-mining-refresh` unit recomputes the queue for the console
  rather than for this process, and restarting the miner is what picks up a new
  breadth order. The *demand* half is live: `plan` recomputes `demanded(reports)`
  from the change feed every cycle, so a newly opened report is prioritised
  immediately. Re-reading on a slow cadence is the fix if the breadth order ever
  has to move under a running process.
- **A package's cached history is parsed twice per cycle.**
  `versions.history_is_cached` reads and parses the cached version and date
  documents to decide whether a fetch is needed, and `release_history` then reads
  and parses the same two files to return the history. Caching the parse is the fix
  and it is left out because it has to be keyed on the file's mtime to stay correct
  after a fetch rewrites it — more machinery than the cost currently earns.

## What it has actually produced

The first corpus this ran against was 441 reports and not one of them real: every
row was a fixture filed by an end-to-end run, invisible to every reader. Wiping it
and letting the miner fill it is the whole argument for the approach, so the
numbers are worth stating rather than describing.

Within the first hour it mined 24 release crossings, found 24 mechanisms, and the
live corpus went from 0 reports to 22 — every one of them executed. `sqlalchemy`
1.4.54 → 2.0.54 removed ten legacy arguments; `httpx` 0.27.2 → 0.28.1 renamed
`proxies=` to `proxy=` across eleven call sites and removed three others; `jinja2`
3.0.3 → 3.1.6 removed `Markup`, `contextfunction` and `escape`.

That last group is the case the symbol pass exists for, and it is worth being
precise about why it is not a changelog with extra steps. `jinja2.Markup` was
removed in 3.1.0. Anything that reads a changelog could have told you that. What
the execution establishes is the thing a caller actually needs: **that a reference
to `jinja2.Markup` resolved on 3.0.3 and raises on 3.1.6** — on this interpreter,
with this release installed — and the traceback in the report is the interpreter's
own output from the run that raised. The corpus's own probe then asks for every
report by that report's words and gets 22/22 back.

Most crossings find nothing, which is the point rather than a disappointment:
`requests`, `flask`, `fastapi`, `django`, `celery`, `redis` and `boto3` all crossed
a minor line with no argument removed and no export dropped. A corpus that claimed
otherwise would be a corpus nobody could act on.

Every live report is confirmed as it is filed, and the corpus is at the scale the
miner is: at the last measurement **771 live reports across 167 libraries, 764 of
them at `resolved_verified`**, each confirmed twice by execution — once by each
method — with the two releases and the interpreter's words recorded beside it. The
number that matters is not the 771 but the small number beside it: seven reports
waiting for a confirmation, and no report carrying a verification that contradicts
it. That second zero is the interesting claim, because the confirmation arrives
while the miner is still filing — the corpus grows at the speed of the slower of
the two.

### What it got wrong, and what that cost

A corpus of executed findings is not a corpus of true ones, and the difference was
worth more than the numbers above. An audit of the live corpus — reading each
package's real releases rather than trusting the report — found that **13 of 96
reports told callers to import something unrelated to what they lost**, and a
further 13 denied a successor that exists. Every one was a claim the execution
underneath it did not support:

* A rename decided by character similarity. `DSSKey` → `ECDSAKey`, `RankWarning` →
  `hanning`, `read_gbq` → `read_sql`. The candidate was always something the
  release really exported and really resolved, so the *evidence* was genuine and
  the *conclusion* was invented — which is the failure mode this project exists to
  not have, and the worst kind, because it looks exactly like a good report.
* A replacement that had been tried and refused, filed anyway, because the
  mechanism read whether a candidate *existed* while the resolution text asserted
  it had been *executed*.
* A removal whose resolution said "the release exports nothing with a close name",
  about names that were still exported one submodule down.

Thirteen wrong fixes and thirteen wrong negatives, out of ninety-six reports, is
what a plausible-looking guess costs at this scale. The rules that replaced them
are the ones in "How a finding is made", and the corpus was repaired rather than
rewritten: the unsupported reports were withdrawn through the service's own
moderation path (`scripts/withdraw-unsupported-renames.rb`) and the pairs behind
them forgotten (`scripts/forget-mined-pairs.rb`) so the corrected findings were
re-derived and re-filed.

Two of the seven reports that repair replaced came back **better** than either
version: `jsonpath-ng.JsonPathLexer` was not renamed to `JSONPath`, it had moved
to `jsonpath_ng.lexer.JsonPathLexer`, and `sqlalchemy.IdentityOptions` to
`sqlalchemy.sql.schema.IdentityOptions`. Asking the release where a name is beats
asking what it looks like.

The honest residue: three real renames are refused because their names share no
words (`ResponseClosed` → `ResponseNotRead`), two because a word was dropped
(`CythonMetaType` → `CythonType`), and the pass looks one submodule deep, so a name
that moved four levels down (`litellm.parse_ocr_request_format`, which never left
`litellm.llms.base_llm.ocr.transformation`) is filed as a removal. Those reports
are true; they are just less helpful than they could be.

## The suites

`./scripts/dev.sh miner` runs it; it is part of `./scripts/dev.sh check`. It is
pure by design — no network, no installs — because the parts that do those things
are the parts a test cannot assert anything stable about. What it covers is every
judgement made about a run's output, which is where a fabricated finding would
come from: reading a refusal as a break, or a break as a refusal.
