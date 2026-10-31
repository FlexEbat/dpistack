# Control panel

English | [Русский](dashboard.ru.md)

The web panel shows the state of the stack and lets you control it without the command line. The default address is `http://127.0.0.1:9800` (see "Access" in [deployment.md](deployment.md)). Signing in with a password is required; the password is stored as an argon2id hash, and you can change it with `dpistack panel-passwd` or in the control menu.

The interface is responsive: on a wide screen the navigation is on the left, on a narrow one it is a floating bar with a menu that opens over the whole screen. The page loads no external fonts, scripts or images (the Geist fonts and the Phosphor icons come from the panel itself) and works on a network without internet access.

## Editions

`PANEL_EDITION` chooses which panel is served. Both editions have exactly the same screens, API and features; only the look and the work done in the browser differ. The installer menu asks which one you want, and you can change it later on the Settings screen.

| Edition | Look | When to choose it |
| --- | --- | --- |
| `full` (default) | a dark console: flat surfaces, one cool-blue accent, the Geist font, a sidebar, blocks that rise into view once and a quiet particle background (it stops when the tab is hidden and respects `prefers-reduced-motion`) | a workstation or any host where the browser has room to spare |
| `lite` | a plain, light page: system fonts, no background canvas, no animations, a small stylesheet | a small host, an old browser or a slow remote link |

The server sends the stylesheet and the background script of the chosen edition, so a lite page never downloads the full one.

## Screens

| Screen | What is on it |
| --- | --- |
| Overview | the overall status of the stack, the state of the components, key figures |
| Components | start, stop and restart of every component, the IDS/IPS mode with a confirmation and a countdown, capture interfaces |
| Settings | every `dpistack.conf` setting and the secrets |
| Configs | an editor for `suricata.yaml`, `evebox.yaml`, `ntopng.conf`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf`; check, save with a backup, and roll back |
| Rules | rule sources, groups, single rules by sid, search, an update with a rollback on error |
| Logs | component logs with live following |
| Events | events from `eve.json` with filters |
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

## Panel security

- The panel does not run as root; it does privileged things by calling `sudo -n dpistack <command>`, where `dpistack` lets the panel user reach the control commands only and checks the arguments against lists.
- The config editor equals root access to the host: edits of `suricata.yaml` allow running foreign code. Do not open the panel to the network without need; the `lan` and `nginx` modes need a confirmation, and in `lan` the HTTP without TLS is visible on the network, so use `nginx` with TLS or an SSH tunnel.
- Every request that changes something is protected by a CSRF token; the session is a cookie.
