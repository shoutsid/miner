#!/bin/sh
# Start the miner — or a verifier — and wait for the API before asking it anything.
#
# Both modes are this image because both are the same kind of thing: a client of
# the corpus that installs releases and executes them. What differs is the job.
# The miner files findings; a verifier confirms somebody else's, and has to do it
# under its own account, because the service counts a confirmation only from an
# operator other than the author. So the mode selects the command, and the two
# services that run it differ in env alone.
#
# The wait is shared: a process that started against a socket nobody was listening
# on would spend its first cycle retrying and log an outage it did not have.
#
# It does not wait forever. An API that is down for an hour is an API the work
# should be running alongside rather than a reason for the container to refuse to
# start: both loops already treat an unreachable corpus as something to wait out,
# which is strictly more forgiving than this.
#
# The client is Ruby and so is the probe (`lib/`) — `ruby /app/bin/agents-miner`
# is the one command, and the wait below asks `/api/health` with the interpreter that is
# already in the image rather than with one installed for the purpose.
set -eu

: "${API_BASE_URL:=http://service:8001}"
: "${MINER_HOME:=/home/miner/.cache/agents-miner}"
: "${MINER_MODE:=serve}"
: "${MINER_BUDGET:=48}"
: "${MINER_REPORT_BUDGET:=1}"
# How many packages the watchlist holds. The list has to outlast the work: at the
# rate this deployment mines (~4,600 pairs a day, twelve crossings a package) a
# thousand packages is about two days, after which the miner has nothing left,
# keeps cycling, and reports 0 pair(s) while the container looks healthy. It is an
# operator setting because it describes the link and the disk rather than any one
# command. Past ~4,000 the breadth seed stops fitting in a request body — see
# `Watchlist::DEFAULT_TOP` — so raising this needs the body cap raised too.
: "${MINER_TOP:=3000}"
# 0 is no limit: the service's quota is not the constraint, the work is.
: "${MINER_WRITES_PER_HOUR:=0}"
: "${MINER_WORKERS:=2}"
# Which index the interval works. The deployment collects one — PyPI is paused — and an
# image that silently fell back to Python would build environments for votes the service
# refuses. An operator overriding this is a deliberate act rather than an omission.
: "${MINER_ECOSYSTEMS:=ruby}"
# 0 is no ceiling. How much of the link a background service may take is the
# operator's decision about their own connection, so this is off unless asked for;
# set it below what the miner would otherwise pull (about 2.8 MB/s while mining).
: "${MINER_DOWNLOAD_MBPS:=0}"
: "${MINER_LOG_LEVEL:=INFO}"
# Which way a verifier checks a claim: as the report writes it, or by re-deriving
# it from the two releases. Both services run this image and differ in this and in
# their home directory.
: "${VERIFIER_ROLE:=as-reported}"
: "${VERIFIER_BUDGET:=12}"

echo "miner: waiting for ${API_BASE_URL}/api/health"
attempt=0
# The URL goes in through the environment rather than into the one-liner, so a base
# with a quote or a space in it is a URL rather than a broken program.
#
# The 4-second ceiling is on *both* halves — opening the connection and reading the
# answer — which is a difference from `Net::HTTP.get_response`'s defaults rather than a
# detail: those are sixty seconds each, so an address that accepts a connection and then
# says nothing would hold one attempt for two minutes and turn this loop's "5 minutes"
# into a quarter of an hour. The bound is the point of the bound.
until HEALTH_URL="${API_BASE_URL}/api/health" ruby -rnet/http -ruri -e '
begin
  uri = URI(ENV["HEALTH_URL"])
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 4, read_timeout: 4) do |http|
    http.get(uri.request_uri)
  end
  exit(response.code == "200" ? 0 : 1)
rescue StandardError
  exit 1
end
' 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        echo "miner: ${API_BASE_URL} did not come up in 5 minutes; starting anyway" >&2
        break
    fi
    sleep 5
done

# Unquoted on purpose: these are several arguments, not one.
# shellcheck disable=SC2086
common="--base-url ${API_BASE_URL} --home ${MINER_HOME} --log-level ${MINER_LOG_LEVEL}"

if [ "${MINER_MODE}" = "verify" ]; then
    exec ruby /app/bin/agents-miner verify \
        --state "${MINER_HOME}/operator-${VERIFIER_ROLE}.json" \
        --heartbeat "${MINER_HOME}/heartbeat-${VERIFIER_ROLE}" \
        --role "${VERIFIER_ROLE}" \
        --budget "${VERIFIER_BUDGET}" \
        --workers "${MINER_WORKERS}" \
        --writes-per-hour "${MINER_WRITES_PER_HOUR}" \
        --download-mbps "${MINER_DOWNLOAD_MBPS}" \
        --ecosystems "${MINER_ECOSYSTEMS}" \
        ${common} "$@"
fi

exec ruby /app/bin/agents-miner serve \
    --state "${MINER_HOME}/operator.json" \
    --heartbeat "${MINER_HOME}/heartbeat" \
    --top "${MINER_TOP}" \
    --budget "${MINER_BUDGET}" \
    --report-budget "${MINER_REPORT_BUDGET}" \
    --writes-per-hour "${MINER_WRITES_PER_HOUR}" \
    --workers "${MINER_WORKERS}" \
    --download-mbps "${MINER_DOWNLOAD_MBPS}" \
    --ecosystems "${MINER_ECOSYSTEMS}" \
    ${common} "$@"
