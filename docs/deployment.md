# Deployment options

English | [Русский](deployment.ru.md)

Each component runs independently either on the host (`native`) or in a Docker container (`docker`):

| Key | Component |
| --- | --- |
| `SURICATA_RUNTIME` | Suricata |
| `EVEBOX_RUNTIME` | EveBox |
| `NTOPNG_RUNTIME` | ntopng (redis follows it) |
| `METRICS_BACKEND_RUNTIME` | the metrics storage (VictoriaMetrics or Prometheus) |
| `PANEL_RUNTIME` | the control panel |

All 32 combinations are allowed; the only limit: with `SURICATA_RUNTIME=docker` the nDPI plugin is not installed into the image, so set `NDPI_ENABLE=no`. You need Docker with the `compose` plugin.

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

## Panel edition

`PANEL_EDITION` is `full` (the default) or `lite`. It does not change what the panel can do, only the page it serves: `full` is the rich dark console with the particle background, `lite` is a plain, light page for small hosts (see [dashboard.md](dashboard.md)). The panel unit has no `MemoryMax` or `CPUQuota`, in a container or on the host, and the number of open log streams is fixed at 4. Switch the edition on the Settings screen or with `dpistack settings set --apply PANEL_EDITION=lite`.

An old `dpistack.conf` that still has `PANEL_MODE` (the limited/unlimited switch of earlier versions) keeps loading: the key is ignored.

## Access and ports

`ACCESS_MODE`: `localhost` (the default, from this machine only), `lan` (the network `LAN_CIDR`, detected from the interface by default) and `nginx` (nginx proxies the panel, EveBox and ntopng, optionally with TLS: `NGINX_TLS=selfsigned|existing`). The `lan` and `nginx` modes are enabled only after an explicit confirmation. Ports: panel 9800, EveBox 5636, ntopng 3000; a busy port gives a warning and a choice of another one (see [installation.md](installation.md)).
