# Operations

English | [Русский](operations.ru.md)

All commands run as root (`sudo dpistack ...`). `dpistack` without arguments opens the control menu; `dpistack help` prints the full list of commands.

## State and control

| Command | Action |
| --- | --- |
| `dpistack status [--json]` | the state of the components; without `--json` also a comparison of every install step with the config |
| `dpistack start\|stop\|restart <component>` | control a component |
| `dpistack reload suricata` | reload the rules without stopping |
| `dpistack logs <component> [-n N] [--follow]` | the component log, N up to 1000 |
| `dpistack health [--json]` | one watchdog run |
| `dpistack test bittorrent\|https\|all [--json]` | check tests |
| `dpistack diag` | a report for troubleshooting: platform, versions, config without secrets, services, logs |
| `dpistack version` | the bundle version |

Components: `suricata`, `evebox`, `ntopng`, `redis`, `victoriametrics`, `prometheus`, `panel`, `watch`, `rules`. Components in Docker are controlled with the same commands.

## Settings

| Command | Action |
| --- | --- |
| `dpistack settings list [--json]` | every setting with its current value; secrets are shown as "set" or "not set" |
| `dpistack settings check KEY=VALUE...` | a check without writing: errors, the weight of the change, busy ports (JSON) |
| `dpistack settings set [--apply\|--apply-heavy] [--confirm-access] KEY=VALUE...` | write and apply |
| `dpistack settings secret KEY` | write a secret (the value comes from stdin) |
| `dpistack settings job` | the progress of a heavy apply (JSON) |

`KEY=VALUE` pairs can be passed as arguments or line by line on stdin (the panel does it this way: values such as a BPF filter contain characters that the argument check does not let through; the schema rules check them anyway). Without `--apply` the change is only written. A light change with `--apply` applies at once; a heavy one needs `--apply-heavy` and runs as a separate `dpistack-apply` job that `settings job` follows. Changing `ACCESS_MODE` to a wider access needs `--confirm-access`. A busy port is refused with the process and a free port named.

`dpistack reconfigure --light [--dry-run]` applies the current `dpistack.conf` without questions and for light changes only; heavy ones end with code 3.

## Config files

```
dpistack config-read suricata.yaml
dpistack config-write suricata.yaml --check < new.yaml     # a check only
dpistack config-write suricata.yaml --apply < new.yaml     # check, backup, apply
dpistack config-revert suricata.yaml                        # restore the latest copy
```

Names: `suricata.yaml`, `evebox.yaml`, `ntopng.conf`, `dpistack.conf`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf`. The installer does not overwrite a hand-edited file without `--force`. The rendered `suricata.yaml` is checked with `suricata -T` before it is written, and its `suricata-version` key matches the series of the installed Suricata.

## Rules

```
dpistack rules-update                         # suricata-update with a rollback if suricata -T rejects the set
dpistack rules-sources list [--enabled]       # enable|disable|add-url|remove <name>
dpistack rules-group enable|disable <group>
dpistack rules-sid enable|disable <sid>
dpistack rules-search <query>                 # up to 50 rules by sid or text
```

The rules update timer is turned on with the `RULES_UPDATE` key, the schedule is `RULES_UPDATE_CALENDAR`.

## Capture interfaces

```
dpistack iface list
dpistack iface add eth1
dpistack iface remove eth1       # the last interface cannot be removed
```

## IPS mode

By default Suricata works as IDS: it watches traffic and blocks nothing. `dpistack mode ips` turns it into IPS: through NFQUEUE (`IPS_METHOD=nfq`, rules in a separate `DPISTACK` chain that is restored at boot) or with pairs of interfaces (`afpacket`). The rules use `--queue-bypass`, so stopping Suricata does not cut the network. The switch must be confirmed with `dpistack mode-confirm` within 120 seconds (`--confirm-timeout`, 10 to 3600): otherwise the mode goes back to IDS by itself and the rules are removed. `dpistack mode status [--json]` shows the mode, the method and the countdown. Other people's chains and rules are not touched; traffic is blocked by your rules with the `drop` action (`drop.conf`), none are created for you.

## Watchdog and alerts

The `dpistack-watch` timer checks, every `WATCH_INTERVAL_SEC`, the services, the ports, the freshness of `eve.json`, packet drops, the disk space and the age of the rules (the `WATCH_*` thresholds). A failed component is restarted at most three times an hour (`WATCH_AUTORESTART`). Alerts go to the `ALERT_CHANNELS` channels: `panel`, `log`, `telegram`, `mail`. The Telegram token and the SMTP address are kept as secrets.

## Metrics

See the "Metrics" section of [README.md](../README.md): the `/metrics` endpoint, the token, a ready entry for `scrape_configs`, the built-in VictoriaMetrics or Prometheus storage.

## Backups

Before every config write through `config-write` and `settings set` a backup is made; `config-revert` restores the latest one. Component data (rules, EveBox, ntopng, metrics) lives in its own directories and is removed only by `uninstall --purge`.
