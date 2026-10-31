# AGENTS.md


Instructions for AI agents and automation that make changes in this repository. For people: [CONTRIBUTING.md](CONTRIBUTING.md). The full specification and the decisions: [tech.md](tech.md); where they disagree, tech.md wins.

## What this is

dpistack: an installer and a panel for the nDPI, Suricata, EveBox and ntopng stack on a single host. One command, `dpistack` (the root `install.sh`), installs, configures and looks after the stack; the web panel, written in Go (`panel/`), calls its control commands through `sudo -n dpistack <command>` (or `nsenter` from a container).

## Repository map

| Path | Purpose |
| --- | --- |
| `install.sh` | entry point: argument parsing, the root check, the command dispatcher |
| `lib/*.sh` | libraries: `schema.sh` (the key schema), `config.sh`, `os.sh` (distribution families), `step_*.sh` (install steps), `ctl.sh` (control commands), `menu.sh`, `runtime_docker.sh`, `ips.sh` |
| `bin/dpistack-watch` | the watchdog (started by a timer) |
| `templates/` | config and unit templates (`@@KEY@@` is filled in by `lib/render.sh`) |
| `panel/` | the panel: Go (`cmd/`, `internal/`) and the static interface (`web/`, no external resources; `full.css` and `fx.js` are the full edition, `lite.css` the lite one) |
| `tests/` | bats tests, stubs of external commands in `tests/mocks/`, helpers in `tests/helpers/` |
| `scripts/` | the gate, the single-file build, the security checks, the reference generator |
| `dpistack-install.sh` | the single-file installer; **generated** by `scripts/bundle.sh`, never edited by hand |
| `docs/` | guides; `docs/configuration.md` and `docs/configuration.ru.md` are **generated** by `scripts/gen-config-doc.sh` |
| `tech.md` | the specification, contracts and decisions |

## Rules of work

1. Work on the `dev` branch. Changes reach `main` only as a pull request after a green gate; there are no direct commits to `main`.
2. Before a commit run `bash scripts/gate.sh`. It runs `shfmt`, `shellcheck`, the security checks, the checks of the single file, the config example and the reference, `bats`, and, if Go is there, `gofmt`, `go vet`, `go test` and the interface tests on node. A green gate is required.
3. If you changed any file of `install.sh`, `lib/`, `templates/`, `bin/`, run `bash scripts/bundle.sh`, otherwise the single-file check fails.
4. If you changed the key schema, update `lib/schema.sh`, `dpistack.conf.example`, the table in tech.md, the hint in `panel/web/modules/settings-model.js` (a test compares it with the schema) and run `bash scripts/gen-config-doc.sh`.
5. Every decision and contract is recorded in tech.md. The program version in `lib/common.sh` and in tech.md changes together.
6. New behavior comes with a test: bats for the shell, `go test` for the panel, `node --test` for the pure logic of the interface.
7. Prefer ready-made solutions (packages, images, tools) to writing your own code when they exist.
8. The program is English only: messages, the menu, errors and the panel text. The README and `docs/*.md` come in English and Russian (`*.ru.md`): change both. `tech.md`, `AGENTS.md`, `CONTRIBUTING.md` and `SECURITY.md` are English only.

## Style and traps

- Shell: tabs, `shfmt`, `shellcheck -x -S style` with no remarks, `set -u`. Messages to the user are in English.
- The installer commands and all verbs work as root only. The panel user gets only the control verbs through `sudo` (or `DPISTACK_CALLER=panel`), without `install`, `upgrade`, `uninstall`.
- Secrets live only in `/etc/dpistack/secrets.conf`; they must not appear in command-line arguments, logs or API answers. Secret values travel through stdin.
- Values from the config and from a request are not put into a command line without a check against the schema; the panel sends `KEY=VALUE` pairs on stdin.
- In bats a `! command` that is not the last line of a test is ignored: write `run command; [ "$status" -ne 0 ]` (checked in `tests/ci_config.bats`).
- Tests do not touch the system: external commands are replaced by stubs from `tests/mocks/` through `PATH`, and `DPISTACK_ROOT` sets the root of the file system.
- The panel interface: no external fonts, scripts or images, no inline scripts or styles (the CSP policy). The lite edition must keep every feature of the full one; only the look differs.
- Go modules may be unavailable without a network: the panel tests run in CI.

## What not to do

- Do not edit `dpistack-install.sh` or `docs/configuration*.md` by hand.
- Do not weaken the security checks and do not add a way to turn off the panel sign-in.
- Do not commit tokens, passwords or keys; do not print them in reports.
- Do not write into the documentation or the messages that the project was never run for real: document the behavior, and file what really does not work as an issue.
