# Платформы

[English](platforms.md) | Русский

dpistack управляет службами через systemd, поэтому на любой платформе нужен systemd. Установщик определяет семейство по `/etc/os-release` (`ID`, затем `ID_LIKE`).

| Семейство | Дистрибутивы | Пакетный менеджер | Компоненты на хосте | Компоненты в Docker |
| --- | --- | --- | --- | --- |
| `apt` | Ubuntu LTS от 22.04, Debian от 12 и производные | `apt-get` | да | да |
| `dnf` | Rocky Linux и AlmaLinux от 8, Fedora, RHEL, CentOS Stream, Amazon Linux | `dnf` | да | да |
| `zypper` | openSUSE, SLES | `zypper` | нет | да |
| `pacman` | Arch Linux, Manjaro, EndeavourOS | `pacman` | нет | да |
| `generic` | любой другой Linux с systemd | не используется | нет | да |

Уровни поддержки печатаются при запуске: **supported** (Ubuntu LTS от 22.04, Debian от 12, Rocky и AlmaLinux от 8), **unverified** (остальные известные семейства: запуск идёт с предупреждением), **unsupported** (старее указанных версий).

## Что значит «в Docker» на zypper, pacman и generic

Пакеты Suricata, EveBox, ntopng и nDPI для этих систем установщик не ставит. Все компоненты запускаются контейнерами, панель при желании тоже:

```
sudo ./install.sh install -y \
  --set SURICATA_RUNTIME=docker --set EVEBOX_RUNTIME=docker --set NTOPNG_RUNTIME=docker \
  --set NDPI_ENABLE=no
```

Если оставить `native`, проверка перед установкой остановится и назовёт ключи, которые нужно задать. Плагин nDPI собирается вместе с Suricata на хосте, поэтому в контейнерной схеме `NDPI_ENABLE=no`.

С нужными пакетами и Docker на хосте:

- `zypper` и `pacman`: установщик сам ставит базовые утилиты (`curl`, `jq`, `git`, `openssl`, `sudo`, `iproute2` и другие);
- `generic`: установщик проверяет наличие `ip`, `visudo`, `openssl`, `jq` и просит поставить недостающее пакетами дистрибутива; сам он на таких системах ничего не устанавливает.

Закрепление версий пакетов (`PIN_VERSIONS`) работает на `apt`, `dnf` и `zypper`; на остальных пропускается с сообщением.

## Система без systemd

Alpine, Void с runit, Gentoo с OpenRC и подобные: установщик завершается с кодом 3 и сообщением `systemd is needed`.
