# Support

This is a small, proprietary project. There is no support contract, no service-level agreement
and no guaranteed response time. The documentation is the first line of support, and the issue
tracker is the second.

## Before opening an issue

1. Read [Getting started](docs/getting-started.md) and [Configuration](docs/configuration.md).
2. Read [Troubleshooting](docs/troubleshooting.md); it covers refusals, installs, pauses, the
   ledger and the healthcheck.
3. Search the existing issues.
4. Re-run the command with `--log-level DEBUG` (if the command accepts it) and read the cycle
   line. The reason counts are more precise than “nothing happened”.

## What to include

- the version (`agents-fyi-miner --version` or the image tag);
- the operating system, Ruby version, Python version and whether a compiler is present;
- the exact command and flags;
- the service URL, **never the operator key**;
- the exit code and the relevant log lines, with secrets and private package names redacted;
- for a loop, the startup line's settled count and whether the heartbeat is fresh.

## What is not supported

- a deployment's own compose file, proxy, volume layout or secret store;
- a modified image or a fork;
- a package that cannot be installed for reasons outside the client;
- a request for a licence, a redistribution right or a support contract.

Licensing questions go to the copyright holder; see [LICENSE](LICENSE). Security reports go
through [SECURITY.md](SECURITY.md), not the issue tracker.
