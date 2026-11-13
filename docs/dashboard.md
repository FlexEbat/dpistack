# Control panel

English | [Русский](dashboard.ru.md)

The web panel shows the state of the stack and lets you control it without the command line. The default address is `http://127.0.0.1:9800` (see "Access" in [deployment.md](deployment.md)). Signing in with a password is required; the password is stored as an argon2id hash, and you can change it with `dpistack panel-passwd` or in the control menu.

The interface is responsive: on a wide screen the navigation is on the left, on a narrow one it is a floating bar with a menu that opens over the whole screen. The page loads no external fonts, scripts or images (the Geist fonts and the Phosphor icons come from the panel itself) and works on a network without internet access.

## Look

The panel is one dark console. A sidebar in groups (it collapses to icons), a top bar with the live state, and cards on a navy canvas. The Overview shows the health banner, four state cards, ring gauges for CPU, memory and disks, the interfaces, traffic charts, alerts by severity and the components. Charts show the values under the pointer, you can drag over a stretch to zoom and double click to reset. A quiet background of drifting points stops when the tab is hidden, and everything that moves stops under `prefers-reduced-motion`.
## Screens

| Screen | What is on it |
| --- | --- |
| Overview | the overall status of the stack, the state of the components, key figures |
| Network | the capture chain (host, capture interfaces, Suricata, `eve.json`, EveBox) and the table of interfaces; read only |
| Traffic | devices, applications, domains and connections from the newest `flow`, `dns` and `tls` events, with a filter, a detail view of one device and a link to ntopng; read only |
| Components | start, stop and restart of every component, the IDS/IPS mode with a confirmation and a countdown, capture interfaces |
| Settings | every `dpistack.conf` setting and the secrets |
| Configs | an editor for `suricata.yaml`, `evebox.yaml`, `ntopng.conf`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf`; check, save with a backup, and roll back |
| Rules | rule sources, groups, single rules by sid, search, an update with a rollback on error; the counts per rule source (total, enabled, disabled), the history of updates, a search by category, source, state and text (disabled rules included), an editor for `local.rules` with a check (no rule, no sid, a sid used twice or by the rule set, `suricata -T`) and the earlier versions of the file with a comparison |
| Exceptions | what Suricata stays silent about or reports less often: one rule for one address or for every address, or a rate limit per address; each with an optional expiry (a number of days, the default, or never) and a note; started from an alert with Create exception on the Events screen; the same `dpistack exceptions` command as in the CLI |
| Logs | component logs with live following |
| Events | events from `eve.json`: filters by address, rule number, category, protocol, severity, domain and time; grouping by rule, address or category; the events of one flow; the history of one rule; export of what is shown as JSON or CSV; Create exception for an alert. The filters other than type, text and time work on the newest events that were loaded (at most 500) |
| Metrics | charts of the Suricata statistics and the state of the host |
| Tests | check tests (BitTorrent, HTTPS) |
| Alerts | watchdog messages and delivery channels |

## The Settings screen

The screen is built from the settings schema that the program itself serves, so it shows exactly the keys the installed version knows: what used to be split between the installer and the control command is now in one place.

- Settings are grouped: traffic capture, components and installation, events and storage, rules, access and ports, metrics, watch and alerts, test checks. Each setting has a short description. The main settings are visible at once, the rest appear with the "Advanced settings" switch.
- The field fits the type of the setting: a list for enumerations, a number with bounds for integers, text for the rest. Obvious errors show at once, the final check is done by the server.
- **Check** writes nothing: it shows the errors by key, the weight of the change and the busy ports. **Apply** checks, writes and applies; **Reset** brings back the entered values.
- The "reinstall" mark on a setting means the change starts an install or a rebuild of a component. The panel asks for a confirmation first, and the progress of applying is shown in a log on the same screen.
- A busy port is shown with the name of the process and a "Use N" button for the nearest free one.
- Widening access (`ACCESS_MODE` other than `localhost`) needs its own confirmation.
- Secrets (`ALERT_TG_TOKEN`, `ALERT_SMTP_URL`, `METRICS_TOKEN`) are never shown: you see only "set" or "not set". A new value goes into a separate field, an empty one removes the secret.

The same actions are available from the command line: `dpistack settings list|check|set|secret|job` (see [operations.md](operations.md)).

## Users and roles

The panel has more than one user. The first one is `admin`, with the password you set at install (`sudo dpistack panel-passwd`). Sign in with a user name and a password; an empty name means `admin`.

| Role | May do |
|---|---|
| viewer | look at every screen except Configs |
| analyst | viewer, run the self-tests, read the audit |
| operator | analyst, control components, edit rules |
| admin | everything, including settings, configs, IPS mode, updates and users |
| custom | exactly the permissions you tick |

The Account screen changes your own password and, for users who may manage users, adds users, changes roles, disables and removes them. The same from the command line (the password is read from stdin):

```
printf '%s\n' 'a long password' | sudo dpistack users add anna operator
sudo dpistack users list
sudo dpistack users role anna custom --perms view,rules.edit
sudo dpistack users disable anna
```

The last user who may manage users cannot be removed, disabled or demoted. A change of the role or the password ends that user's sessions; a disabled user is cut off at once.

## The audit log

Every action that can change something is written to `/var/lib/dpistack/audit/audit.jsonl`: who (the user name, or `-` for a call with no sign-in), from which address, what, the result (`ok`, `denied` or `error`) and a short note. That covers signing in (a wrong password is a line with the name that was tried), every change made in the panel, and every `dpistack` command that changes something when it is run by hand with `sudo` (the line says `cli <command>` and names the user who ran `sudo`). Reading screens and commands such as `list` and `status` leave no line.

No password, token or password hash is ever written: a changed password is logged as `password=changed`, and a setting given as `KEY=VALUE` on the command line is logged as `KEY=...`.

The Audit screen shows the log, newest first, with filters (user, part of the action, result, date) and exports the selection as CSV or JSON. It needs the permission `audit.view`; the roles analyst, operator and admin have it. The file is rotated at 10 MB and five files are kept.

## Panel security

- The panel does not run as root; it does privileged things by calling `sudo -n dpistack <command>`, where `dpistack` lets the panel user reach the control commands only and checks the arguments against lists.
- The config editor equals root access to the host: edits of `suricata.yaml` allow running foreign code. Do not open the panel to the network without need; the `lan` and `nginx` modes need a confirmation, and in `lan` the HTTP without TLS is visible on the network, so use `nginx` with TLS or an SSH tunnel.
- Every request that changes something is protected by a CSRF token; the session is a cookie.
