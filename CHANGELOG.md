# Changelog

Формат: [Keep a Changelog](https://keepachangelog.com/), версии — semver (`MAJOR.MINOR.PATCH`).

Это changelog самой программы `dpistack` (релизы, что реально можно поставить и запустить).
История версий документа-контракта — в `tech.md`, раздел `Changelog_tech`.

## [Unreleased]

Реализовано по слайсам 0–7 (`tech.md`, раздел 17), в ветке `dev`, ждёт проверки на реальном стенде перед слиянием в `main`.

### Добавлено

- Каркас установщика: `install.sh` (`install`/`reconfigure`/`status`), полная схема `dpistack.conf` (`lib/schema.sh`), послойная загрузка и валидация конфига, `dpistack.conf.example`, блокировка от параллельного запуска, секреты только в `secrets.conf`.
- Suricata (IDS): установка из `distro`/`oisf`/`source` (сборка с `--enable-ndpi`), рендер `suricata.yaml` (интерфейсы, `HOME_NET`, типы EVE, статистика), `logrotate`, systemd-юнит.
- nDPI: установка из пакета или сборка из исходников (`ntop/nDPI`), подключение как плагин Suricata.
- Правила: `suricata-update` (источники, группы, безопасное обновление с сохранением прежнего набора при провале проверки), таймер периодического обновления.
- Redis и ntopng: пакеты, конфиг ntopng из `NTOPNG_IFACES`/`NTOPNG_PORT`.
- EveBox: официальный репозиторий, `evebox.yaml` (типы БД `sqlite`/`elasticsearch`, retention).
- Доступ: режимы `localhost`/`lan`/`nginx`, реверс-прокси nginx с TLS (`selfsigned`/`existing`), правила `ufw` при `FIREWALL_MANAGE=auto`.
- Гейт разработки: `scripts/gate.sh` (`shfmt`, `shellcheck`, `bats`), тесты на все проверяемые в песочнице критерии приёмки слайсов 0–7.

### Известные ограничения (не проверено на реальном стенде)

- Реальная выкачка правил ET Open, репозитории OISF PPA, ntop.org и evebox.org, установка настоящего бинарника EveBox.
- Полная сборка Suricata с nDPI (нужен Rust ≥1.85 на машине сборки).
- Обнаружение реального трафика (BitTorrent, TLS) через EveBox/ntopng.
- Правила `ufw` и ветка SELinux — только на реальном хосте с соответствующим окружением.

Подробности и допущения — в `docs/prototype.md`.
