# Platforms

English | [Русский](platforms.ru.md)

dpistack manages services through systemd, so any platform needs systemd. The installer detects the family from `/etc/os-release` (`ID`, then `ID_LIKE`).

| Family | Distributions | Package manager | Components on the host | Components in Docker |
| --- | --- | --- | --- | --- |
| `apt` | Ubuntu LTS from 22.04, Debian from 12 and derivatives | `apt-get` | yes | yes |
| `dnf` | Rocky Linux and AlmaLinux from 8, Fedora, RHEL, CentOS Stream, Amazon Linux | `dnf` | yes | yes |
| `zypper` | openSUSE, SLES | `zypper` | no | yes |
| `pacman` | Arch Linux, Manjaro, EndeavourOS | `pacman` | no | yes |
| `generic` | any other Linux with systemd | not used | no | yes |

Support levels are printed at start: **supported** (Ubuntu LTS from 22.04, Debian from 12, Rocky and AlmaLinux from 8), **unverified** (the other known families: the run goes on with a warning), **unsupported** (older than the versions above).

## What "in Docker" means on zypper, pacman and generic

The installer does not install the Suricata, EveBox, ntopng and nDPI packages for these systems. All components run as containers, and the panel can too:

```
sudo ./install.sh install -y \
  --set SURICATA_RUNTIME=docker --set EVEBOX_RUNTIME=docker --set NTOPNG_RUNTIME=docker \
  --set NDPI_ENABLE=no
```

If you leave `native`, the check before the install stops and names the keys you must set. The nDPI plugin is built together with Suricata on the host, so in the container scheme `NDPI_ENABLE=no`.

With the needed packages and Docker on the host:

- `zypper` and `pacman`: the installer itself installs the base tools (`curl`, `jq`, `git`, `openssl`, `sudo`, `iproute2` and others);
- `generic`: the installer checks for `ip`, `visudo`, `openssl` and `jq` and asks you to install what is missing with the distribution packages; it installs nothing itself on such systems.

Pinning package versions (`PIN_VERSIONS`) works on `apt`, `dnf` and `zypper`; on the others it is skipped with a message.

## A system without systemd

Alpine, Void with runit, Gentoo with OpenRC and the like: the installer exits with code 3 and the message `systemd is needed`.
