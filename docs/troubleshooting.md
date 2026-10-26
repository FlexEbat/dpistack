# Troubleshooting

English | [Русский](troubleshooting.ru.md)

Start with the report: `sudo dpistack diag`. It collects the platform, versions, repositories, the config without secrets, the state of the services and logs to stdout and to a file (the path is printed).

| Symptom | Cause and action |
| --- | --- |
| `the command runs as root only` | `dpistack` and `install.sh` run as root only: `sudo dpistack ...` |
| `port N (KEY) is already busy (held by: ...)` | another process holds the port: pick the free port from the hint (`--set KEY=port`, the menu or the Settings screen) or stop the process |
| `KEY=native: ... set --set KEY=docker` | this system has no packages of the component: run it in Docker, see [platforms.md](platforms.md) |
| `BIND_ADDR=... is not an address of this host` | the address is not on any interface: pick one from `ip -4 addr` (the menu lists them) or use `auto` |
| Grafana asks for a password | the first login is `admin`/`admin`; Grafana asks for a new password at once |
| `systemd is needed` | a system without systemd is not supported |
| `suricata -T rejected the rendered suricata.yaml` | the config did not suit the installed Suricata; the file on disk is unchanged. Suricata itself prints the reason above in the output. Check `suricata -V` and the keys that affect the config |
| `heavy changes ... need --force` | the change starts an install or a rebuild: apply it with `--force` (or `settings set --apply-heavy`) |
| `applying is already running` | a heavy `dpistack-apply` job is running: `dpistack settings job` shows the progress |
| IPS went back to IDS | the switch was not confirmed in time: `dpistack mode ips`, then `dpistack mode-confirm` |
| the panel does not open | `dpistack status`, then `dpistack logs panel`; check `ACCESS_MODE` and the panel port |
| the page looks plain | you are on the `lite` edition: it is meant to; set `PANEL_EDITION=full` for the rich console |
| no events | `dpistack status` (Suricata, `eve.json`), `dpistack logs suricata`, the interface in `IFACES` and the `BPF_FILTER` filter |
| rules do not update | `dpistack rules-update` prints the reason; the previous set is restored on an error |

Service logs: `dpistack logs <component> -n 200`. One run of the watchdog checks: `dpistack health`. To check that detection works: `dpistack test all`.
