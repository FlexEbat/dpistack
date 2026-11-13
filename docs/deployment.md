# Deployment options

English | [Русский](deployment.ru.md)

Each component runs independently either on the host (`native`) or in a Docker container (`docker`):

| Key | Component |
| --- | --- |
| `SURICATA_RUNTIME` | Suricata |
| `EVEBOX_RUNTIME` | EveBox |
| `NTOPNG_RUNTIME` | ntopng (redis follows it) |
| `METRICS_BACKEND_RUNTIME` | the metrics storage (VictoriaMetrics or Prometheus) |
| `GRAFANA_RUNTIME` | Grafana (only with `GRAFANA_ENABLE=yes`) |
| `NODE_EXPORTER_RUNTIME` | node_exporter (only with `NODE_EXPORTER_ENABLE=yes`) |
| `PANEL_RUNTIME` | the control panel |

Every combination is allowed; the only limit: with `SURICATA_RUNTIME=docker` the nDPI plugin is not installed into the image, so set `NDPI_ENABLE=no`. You need Docker with the `compose` plugin.

## Examples

The panel in a container, Suricata on the host:

```
sudo dpistack install -y --set PANEL_RUNTIME=docker
```

Suricata in a container, the panel on the host:

```
sudo dpistack install -y --set SURICATA_RUNTIME=docker --set NDPI_ENABLE=no
```

Everything in containers:

```
sudo dpistack install -y --set SURICATA_RUNTIME=docker --set EVEBOX_RUNTIME=docker \
  --set NTOPNG_RUNTIME=docker --set PANEL_RUNTIME=docker --set NDPI_ENABLE=no
```

Switching the runtime of an installed component: change the key (the Settings screen or `dpistack settings set --apply-heavy`), the old variant is stopped and the new one is created.

## How the containers work

The installer creates the file `/opt/dpistack/compose/compose.yaml`; you do not need to manage the containers by hand: `dpistack status|start|stop|restart|logs` work with them the way they do with services. The containers run with `network_mode: host`, so the ports and the access rules (`ACCESS_MODE`) are the same as for services on the host.

### The panel in a container

- The image `dpistack-panel:<hash of the binary>` is built on the host with `docker build` from a directory that holds only the panel binary and a Dockerfile based on `alpine`. A new binary gives a new image, the old one is not rebuilt.
- The container starts with `pid: host` and `privileged: true`: the panel runs control commands on the host through `nsenter -t 1 -m -u -i -n -p`, like `dpistack` as root. The container names itself in the variable `DPISTACK_CALLER=panel`, and `dpistack` lets it reach the control commands only (not `install`, `upgrade`, `uninstall`).
- Files are mounted at the same paths as on the host: `/etc/dpistack` (read only), `/var/lib/dpistack`, `/var/log/suricata`, `/var/lib/suricata`, `/var/lib/evebox` (read only).
- The `dpistack-panel.service` unit is not used then and is removed; when you go back to `native` the container is removed and the unit is created again.

The panel has root rights on the host: just as with `sudo`, a hacked panel is a hacked host. The `DPISTACK_CALLER` limit protects against mistakes, not against an attacker who has access to the container.

## Panel resources

The panel unit has no `MemoryMax` or `CPUQuota`: the panel takes the memory and the CPU it needs.

An old `dpistack.conf` that still has `PANEL_MODE` (the limited/unlimited switch of earlier versions) or `PANEL_EDITION` (the full/lite switch, removed in v0.47.0) keeps loading: the keys are ignored.

## Listen address

`BIND_ADDR` decides on which address the web services (ntopng, EveBox, the panel, the metrics storage, Grafana, node_exporter) listen:

| `ACCESS_MODE` | `BIND_ADDR=auto` | `BIND_ADDR=<address of this host>` |
| --- | --- | --- |
| `localhost` | `127.0.0.1`, clients from this machine only | that address; the panel lets in clients from `LAN_CIDR` |
| `lan` | `0.0.0.0`, clients from `LAN_CIDR` | that address only, clients from `LAN_CIDR` |
| `nginx` | services on `127.0.0.1` behind nginx | ignored |

In the menu the installer lists the IPv4 addresses of the host (from `ip addr`) and you pick one, for example `192.168.1.156` on `enp2s0`. `preflight` stops with code 3 if the address is not one of this host's. A non-loopback address opens the panels to your network, so it needs the same confirmation as `lan` (without a terminal: `--set ACCESS_CONFIRM=yes`).

## Access and ports

`ACCESS_MODE`: `localhost` (the default, from this machine only), `lan` (the network `LAN_CIDR`, detected from the interface by default) and `nginx` (nginx proxies the panel, EveBox and ntopng, optionally with TLS: `NGINX_TLS=selfsigned|existing`). The `lan` and `nginx` modes are enabled only after an explicit confirmation. Ports: panel 9800, EveBox 5636, ntopng 3000; a busy port gives a warning and a choice of another one (see [installation.md](installation.md)).

`LAN_CIDR` may be a list of networks separated by commas, for example `auto,172.18.0.0/16`: `auto` is the network of the default route, the rest are added to it. Use it when clients reach the panel through something that changes their address, such as a WireGuard server in a Docker container on the same host: the panel then sees the address of the container (the bridge network of Docker, or the tunnel subnet), not the address of the phone, and answers `access from this address is forbidden` until that network is in the list. Add the network the panel actually sees (see `docker network inspect` of the container's network), not a wide range such as `0.0.0.0/0`.
