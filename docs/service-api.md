# Service API

The client talks to the corpus over HTTP and never through a database driver. Every request
carries `X-API-Key` with the operator key stored in the state file. The one exception is
registration, which has no key yet.

The client has a 60-second open and read timeout. It treats a 2xx body as JSON, a 4xx as a
permanent refusal, a 5xx/timeout/dropped connection as a transient outage, and a pause as its
own answer.

## Registration and identity

| Method | Route | Used by | What it does |
|---|---|---|---|
| `POST` | `/api/operators/register` | first run of `publish`, `solve`, `serve`, `verify` | creates an operator from `{name, email}` and returns `{api_key}`; the client writes it to the state file with mode `0600` |
| `GET` | `/api/operators/me` | `solve`, verifier selection | returns the operator's own id, used to skip its own reports |
| `GET` | `/api/health` | `entrypoint.sh` | waits for the service before starting either loop |

Registration is rate limited, which is why the key is reused rather than requested on every
run. `mine` never registers and never calls the service.

## Reports

| Method | Route | What it does |
|---|---|---|
| `POST` | `/api/reports/precheck` | asks whether a draft is new; returns `new`, `similar`, `duplicate` or `likely_duplicate` |
| `POST` | `/api/reports` | submits a finding that the precheck says is filable |
| `GET` | `/api/reports/changes` | one page of created/changed reports after `since` or `since_id`; hidden rows are included and the client filters them |
| `GET` | `/api/reports/{id}` | reads one report, including its resolution and verifications |
| `POST` | `/api/reports/{id}/claim` | reserves a report while a client works on it |
| `POST` | `/api/reports/{id}/release` | releases the claim |
| `POST` | `/api/reports/{id}/resolution` | proposes an executed fix |
| `POST` | `/api/reports/{id}/verify` | records one verifier's vote and its evidence |

`new` and `similar` are filable. `duplicate` is not written; the client reports it and moves
on. `likely_duplicate` means the candidate carries every symptom, including an identifying
one, and is not filed. A filing that meets a `429` waits for `Retry-After` rather than
settling the pair.

The verifier's vote is `reproduced`, `did_not_reproduce` or `partial`. A report it cannot
reach is not voted on at all.

## The mining queue

| Method | Route | What it does |
|---|---|---|
| `GET` | `/api/mining/targets` | a page of `{package, ...}` targets for one `ecosystem`, best first; also returns `limit_max` and, for a paused index, `paused`, `paused_reason` and `next_step` |
| `POST` | `/api/mining/seed` | the breadth ranking, as `{projects, source, ecosystem}`; the service replaces the index's stored seed |
| `POST` | `/api/mining/unexaminable` | the whole picture of releases this machine cannot build, as `{ecosystem, machine, records:[{package, release, reason}]}`; the service replaces the index's picture |
| `POST` | `/api/mining/advisories` | the reviewed advisory lead set for an index, as `{ecosystem, source, records}`; leads, never reports |

`targets` is paged by the client with `offset`; `limit_max` is what makes a short page
distinguishable from the end of the queue. A paused queue is a **503-style refusal expressed
in the body**, and the client raises a `CollectionPaused` rather than reading it as an empty
queue. A paused index is dropped at startup; every requested index paused exits `3`.

The seed and the advisory set are **replacement pictures**, not deltas: a package or advisory
that is absent has been retracted. The client sends the current picture, including an empty
one.

## Release facts

| Method | Route | What it does |
|---|---|---|
| `POST` | `/api/releases/facts` | the Ruby requirement each release of one gem declares, as `{ecosystem:"ruby", library, facts}`; idempotent per release |

RubyGems only. The service refuses any other index. The client records these facts so a
later plan can answer “what Ruby does this release require?” without re-reading the index.

## Error answers

| Status/body | Client's reading |
|---|---|
| `429` | `RateLimited`; wait for `Retry-After`, do not settle the work |
| `422` | `CorpusError(permanent: true)`; the request itself was refused |
| `503` with `error.type=collection_paused` | `CollectionPaused`; wait, do not settle, do not retry in a moment |
| other `5xx`, timeout, dropped connection | `CorpusError(permanent: false)`; retry later |
| `401`/`403` | permanent refusal; the key is wrong or lacks the operator role |

The distinction is load-bearing. A permanent failure settles a pair because asking again
reaches the same answer; a transient one leaves it unresolved so it is worked out again. A
pause is neither: it is a decision about the index, and no report or pair is retired by it.

## What the client never calls

The admin surface — hiding, unhiding, disabling, pausing or resuming an index — is not in
this client. It has an operator key, not an admin token. A deployment that needs one of
those actions uses the service's site admin or its operator tooling, not this container.
