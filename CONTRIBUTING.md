# Contributing

English | [Русский](CONTRIBUTING.ru.md)

Thank you for your interest in dpistack. Below: how to prepare the environment, make a change and take it to a merge. There is a separate short note for AI agents: [AGENTS.md](AGENTS.md).

## Environment

You need: `bash` 4.4+, `shfmt`, `shellcheck`, `bats`, `jq`, `argon2`, Go of the version in `panel/go.mod`, Node.js (the panel interface tests).

```
sudo apt-get install -y shfmt shellcheck bats jq argon2 nodejs
```

Installing from a clone to check by hand is done on a separate machine or a snapshot: the installer installs packages and services. The tests change nothing in the system.

## Branches and merging

- `dev` is the working branch, `main` is the tested state.
- Changes go to `dev` (or to a branch from `dev`) and reach `main` as a pull request after a green CI. There are no direct commits to `main`.
- The commit message says what changed and why.

## Before a pull request

```
bash scripts/gate.sh
```

The gate runs `shfmt`, `shellcheck`, the security checks (`scripts/security.sh`), the single file (`scripts/bundle.sh --check`), the config example and the reference of settings, `bats tests`, `gofmt`, `go vet`, `go test`, the interface tests (`node --test`) and the resource budget of the panel. The same checks run in CI on Ubuntu 22.04 and 24.04, plus `actionlint`, `trivy` and `gitleaks`.

If `install.sh`, `lib/`, `templates/` or `bin/` changed, rebuild the single file: `bash scripts/bundle.sh`. If the settings schema changed, update the config example, the hints of the Settings screen, the table in tech.md and the reference (`bash scripts/gen-config-doc.sh`).

## What a change must contain

1. Code and a test: bats for the shell, `go test` for Go, `node --test` for the interface logic. External commands in tests are replaced by stubs (`tests/mocks/`).
2. A note in tech.md: what changed and why, the decision taken, the version. The program version is in `lib/common.sh` and in the header of tech.md.
3. Documentation: if the behavior changes, update the matching file in `docs/` or the README, in English and in Russian (`*.ru.md`).
4. Security: no secrets in logs, command arguments, API answers or commits; values are checked against the schema before use; the panel interface has no external resources.

## Style

- Shell: tabs, `shfmt`, `shellcheck -x -S style` with no remarks. Functions are small, with a comment on the purpose. Messages to the user are in English.
- Go: `gofmt`, `go vet`; only the dependencies that are really needed.
- Interface: plain JavaScript without a build, modules in `panel/web/modules/`, logic that does not touch the DOM goes to a separate file covered by `node --test`. Both panel editions keep the same features.
- Bats: `! command` outside the last line of a test does not work, use `run` and check `$status`.

## Dependencies and releases

The versions of GitHub actions are pinned by SHA; updates come from Dependabot as separate pull requests and are merged after a green CI. A release is made with the tag `vX.Y.Z` on `main`: a workflow builds the panel binaries and the single-file installer and attests where the artifacts came from.

## Reporting problems

File errors and suggestions as an issue: the version (`dpistack version`), the platform, the command, the output of `dpistack diag` (secrets do not get into the report, but look through it before sending). Report vulnerabilities as described in [SECURITY.md](SECURITY.md), not in a public issue.
