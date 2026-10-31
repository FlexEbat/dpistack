# Docker or native: what can run where

Every part that has an image can run as a container or natively, in any combination. Containers use the host network, so a native part and a container find each other on the same host addresses; nothing needs to be configured by hand when you mix them. Run `sudo dpistack runtime` to see the table below for your installation, with the runtime of every part and a check of every link.

| Part | Docker | Notes |
|---|---|---|
| Suricata | yes | no nDPI plugin and no IPS mode in the container; use a native Suricata for them |
| nDPI plugin | no | built into a native Suricata |
| Rule updates | follows Suricata | run on the host or inside the Suricata container |
| EveBox | yes | |
| ntopng | yes | |
| Redis | follows ntopng | always in the same runtime as ntopng |
| VictoriaMetrics / Prometheus | yes | only the selected backend |
| node_exporter, Grafana | yes | |
| Panel | yes | privileged, with the host process namespace; it reaches `dpistack` through `nsenter` |
| Watchdog | no | a systemd timer of the host |
| nginx | no | a host package, only with `ACCESS_MODE=nginx` |
| Firewall rules | no | rules of the host kernel; they guard host-network containers as well |
| Installer and `dpistack` | no | scripts of the host |

## How the parts find each other

- Suricata writes `eve.json` to `/var/log/suricata`; EveBox and the panel read the same host path, whether Suricata is a container or not.
- ntopng uses Redis on `127.0.0.1:6379`.
- The metrics backend scrapes the panel and node_exporter on the access address (with nginx, the panel is on its port plus 10000); Grafana reads the backend on its port.

`dpistack runtime --json` returns the same data for scripts: the list of parts, the flag `mixed` and the list of links with `ok` set to `true`, `false` or `null` (an end of the link is not running).

## Combinations that are refused

nDPI with a Suricata container and IPS with a Suricata container are refused, with the reason, by the config check, the preflight check and `dpistack mode ips`. Everything else can be mixed.
