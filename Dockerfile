# The reproduction miner, as a service.
#
# It is a *client* of the API and not part of it, and this image is where that
# stops being a claim in a README: it has no database driver, no network route to
# `db`, and no DB_PASSWORD in its environment. It talks to the API over the
# compose network and nothing else, so the worst thing it can do to the corpus is
# what any other operator could do — file a bad report, from an account that can
# be disabled.
#
# Pinned by digest: the same bytes build the same image forever, regardless of
# what the tag points at later.

#
# The client ships two runtimes and neither is decoration. The probes that execute the call
# sites are Python for one index and Ruby for the other, so both interpreters are live at run
# time.
#
# 3.12 and not Debian's own `python3`, which is 3.11: every "cannot be built here"
# fact this miner has recorded names the interpreter it was established on, and
# those records are **cp312** — `machine.rb` stamps them so an image move is what
# expires them, and a base that quietly downgraded the interpreter would make that
# stamp name the wrong thing. The official image is copied in whole (`/usr/local`
# holds the interpreter, pip, the `venv` module and the standard library) rather
# than installed from apt, which is exactly how this file used to carry Ruby.
#
# Pinned by digest for the reason above.
FROM python:3.12-slim@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9 AS python

# Ruby is the client and the *base*, and the pin is a decision about which
# interpreter its rules were verified against rather than about size. Debian
# bookworm ships Ruby 3.1.2 with RubyGems 3.3.15, and every message this client
# reads was captured in Ruby 3.3.12 / RubyGems 3.5.22: the refusal text
# (`undefined method `x' for`), the native-build failure (`make failedNo such file
# or directory - make`) and `gem install --install-dir` behaviour. A client whose
# rules were written against one interpreter and shipped on another is a client
# whose rules were never verified at all. The client itself is stdlib only — no
# bundler here — so the runtime is the whole of the Ruby half.
FROM ruby:3.3-slim@sha256:379ffc9ca20cae2655cb80cac53ee23e1e7d859c03a4cceb7f567d6ce4873cee

# The two trees are disjoint — this base keeps Ruby's interpreter, gems and libruby under
# `/usr/local`, and the Python one keeps `bin/python3.12`, `lib/python3.12`,
# `lib/libpython3.12.so` and the site-packages beside them — so this copy *merges* them rather
# than replacing the interpreter the image is built on.
COPY --from=python /usr/local /usr/local

# A compiler, and it is here because of a measurement. This image deliberately had none, on
# the reasoning that "a gem that needs a native extension is a fact about the release" — and
# that reasoning is false in the two ways that matter. Asked of the index rather than assumed:
# `prism`, `bigdecimal`, `json`, `psych`, `date`, `nio4r`, `msgpack` and `racc` publish *no*
# linux build at all, only `ruby` and `java`. So with no compiler they can never be installed,
# and on this deployment that settled **862 of the Ruby ledger's 1,844 pairs — 659 gems, and
# the whole of Rails among them**: `rails`, `railties`, `actionpack`, `actionview`,
# `activemodel`, `activerecord`, `activesupport`, `nokogiri`, `rubocop`, `puma`, `ffi`,
# `aws-sdk-core`. Second, the failure is a *dependency's*: `rubyXL 3.3.33` failed because
# `racc` could not build, and `minitest 6.0.6` and `activesupport 8.0.5.1` because `prism`
# could not.
#
# What it costs, both measured before adding it. In time: `racc 1.8.1` builds in
# **1 second**, and `rubyXL 3.3.33` then installs in **2** — nokogiri resolves to a
# precompiled `nokogiri-1.19.4-x86_64-linux-gnu`, so the compiler is only ever used
# for the small extensions, not for the large ones. In bytes: this layer is
# **333 MB**, of which `gcc make pkg-config` is 171 and `g++` another 87 — the rest
# is `dpkg-dev` and the C++ headers. The narrower set was considered and rejected:
# a C++ extension with no prebuilt gem fails exactly like `racc` did, and an 87 MB
# saving on a 751 MB image is not worth re-creating the class this line exists to
# remove. `pkg-config` comes with it because a gem that links a library (`pg`,
# `sqlite3`) asks for it by name.
#
# The stamp that expires these facts carries `cc`/`no-cc` (`machine.rb`), so this
# line changing is what re-opens the releases the old image could not build.
#
# `libyaml-0-2`, `libssl3` and `libzstd1` are named even though the Ruby base image
# links them: they are psych (which reads every gemspec), the HTTPS `gem install`
# fetches over, and RubyGems' own cache compression, and a base that dropped one
# would fail as a bad gem rather than as a missing library.
#
# Debian's own `python3` is deliberately *not* on this list: the 3.12 tree above brings
# `venv` and `ensurepip` with it, and a second interpreter in `/usr/bin` would be one apt
# upgrade away from being the one `python3` resolves to — which is the interpreter this
# image's pinned stage exists to fix.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libyaml-0-2 libssl3 libzstd1 build-essential pkg-config \
    && rm -rf /var/lib/apt/lists/*

# pip's download cache is *on*, at a path a volume is mounted over.
#
# It was off (`PIP_NO_CACHE_DIR=1`), which was right for the image build and wrong
# for the job: this process installs a release per environment, and the same wheel
# lands in many of them — `typing_extensions 4.16.0` was installed into 43 separate
# environments, `idna` into 38, `urllib3` into 35. Measured, 74% of the wheel
# installations in one service's cache were wheels it already had, and every one
# was a fresh request to the index. With the cache warm the same install went from
# 2,164 KB of traffic to 12 KB.
#
# It is set here rather than in `docker-compose.yml` so the two cannot disagree
# about where it is, and the volume is shared by all three clients (see the
# compose file) because a wheel is one artifact: content-addressed by URL, and
# verified against the hash the index published for it. The *environments* stay
# apart, and for a reason that is not disk — see `envs.rb`.
#
# An unwritable cache directory is not a failure: pip logs a warning and installs
# anyway, which is what a container run without the volume gets.
#
# `PYTHONUNBUFFERED` and `PYTHONDONTWRITEBYTECODE` are still here for the same reason the
# image still carries Python: the probes and pip are that interpreter, and a probe's output
# that arrives after the process that reads it is a verdict built from nothing.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_CACHE_DIR=/home/miner/.cache/pip

#
# The difference is the job. This process builds a virtual environment per
# (package, version) and installs a release into it, which is the whole method:
# the findings are differences between two installed releases. So pip stays, and
# the risk it carries is bounded by the fact that what it installs is what it is
# inspecting — the miner is already executing arbitrary third-party packages, in
# a container with no secrets to reach for and a read-only filesystem outside the
# cache it was given.
WORKDIR /app

# The client, its data and its command. `lib/` is the whole program and carries the
# breadth ranking it reads offline (`lib/agents_fyi_miner/data/`), `bin/` is the
# command the entrypoint and a person at a shell both reach, and `entrypoint.sh` is
# what the container starts through.
COPY lib ./lib
COPY bin ./bin
COPY entrypoint.sh ./entrypoint.sh

# Its own account, and its own cache directory underneath it. The cache holds the
# virtual environments and the ledger — days of work — so it is a volume rather
# than image state, and everything that survives a restart is in one place.
#
# The verifying operators' caches are made here too, empty, for one reason: a named
# volume mounted at a path that does not exist in the image is created owned by
# root, and this account could not write to it. The image owns the directories, so
# the volumes inherit that. `pip` is the third case and the same one: it is a
# directory rather than a file, and a shared volume mounted over a path this image
# did not create would be root-owned and silently uncacheable.
#
# The gem environments live under those homes too and are made by the client as it
# needs them, so there is no directory here for them: a gem tree is evidence (see
# `rubyenvs.rb`), and a directory created at build time would be one place the
# three clients could be pointed at by accident.
RUN useradd --system --uid 10002 --create-home miner \
    && mkdir -p /home/miner/.cache/agents-fyi-miner \
        /home/miner/.cache/agents-fyi-verifier \
        /home/miner/.cache/agents-fyi-verifier-independent \
        /home/miner/.cache/pip \
    && chmod +x /app/entrypoint.sh /app/bin/agents-fyi-miner \
    && chown -R miner:miner /app /home/miner
USER miner

# The container's liveness is the age of a file the loop touches once a cycle.
#
# Not a process check: the process being up says nothing about whether it is
# working, and a miner whose corpus went away looks exactly like one that is
# thinking — for hours. Three cycle intervals is a stall worth acting on rather
# than a slow cycle worth restarting. The interpreter already in the image is the
# client, so nothing is installed just to probe a file.
HEALTHCHECK --interval=5m --timeout=15s --start-period=15m --retries=3 \
    CMD ruby -e "p='/home/miner/.cache/agents-fyi-miner/heartbeat'; exit(File.exist?(p) && (Time.now - File.mtime(p)) < 5400 ? 0 : 1)"

ENTRYPOINT ["/app/entrypoint.sh"]
