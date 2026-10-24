# tech.md: dpistack (nDPI + Suricata + EveBox + ntopng)

[English](tech.md) | Русский

**Версия документа: v32** (2026-10-24)
**Версия программы: v0.23.0**

Источник истины проекта: имена ключей конфига, путей, команд, метрик, полей и эндпоинтов берутся отсюда. Каждое изменение контракта поднимает версию сверху. Полная история слайсов, ревью и прежний журнал изменений (версии до v0.22.0) остались в истории git: из этого файла они убраны 2026-10-24 (последний коммит с ними `02929a8`, файл `tech.md`). Английская версия `tech.md` главная; при расхождении побеждает она.

## 1. Проект

dpistack: установщик, два служебных скрипта и веб-панель для домашней или небольшой лаборатории DPI/IDS: **nDPI + Suricata + EveBox + ntopng** на одном хосте с одним администратором. Цель: работающая связка, которую поднимает одна команда, которой управляют из браузера и которая сама сообщает о поломках. Это готовый полноценный проект, а не MVP. Не SIEM, не платформа для нескольких хостов, не замена промышленного NDR.

- **Ограничение топологии.** Хост видит только трафик своего интерфейса. Пассивный захват (`af-packet`) покажет остальную сеть, только если трафик приходит на этот хост (зеркальный порт, шлюз, включение в разрыв). Хост вне разрыва с NFQUEUE в `INPUT`/`OUTPUT` защищает только себя. Установщик печатает это при выборе интерфейсов.
- **Модель угроз.** Редактор конфигов панели равен root-доступу к хосту; взлом панели равен взлому хоста. Поэтому по умолчанию `ACCESS_MODE=localhost`, вход обязателен и не отключается; `lan` и `nginx` включаются только после явного подтверждения. Панель отдаёт HTTP без TLS (используйте `nginx` с TLS или SSH-туннель). `eve.json` содержит метаданные трафика, права `0640`. Команды `dpistack` запускаются только от root; панель доходит лишь до глаголов управления через `sudo -n dpistack <глагол>`, каждый аргумент сверяется со списками. Секреты только в `secrets.conf` (`0600`), пароль панели это хэш argon2id.
- **Не входит:** мультипользовательская панель, свой SSO, дашборды Grafana, ntopng Enterprise, podman, LXD, слой i18n в программе, перехват трафика всей сети без подходящей топологии.

## 2. Стек и платформы

- Установщик и `dpistack-watch`: Bash 4.4+, без Python и Perl. Внешние утилиты: `curl`, `jq`, `ss`, `ip`, `systemctl`, `sed`, `awk`, `tar`, `flock`; недостающее ставит шаг `preflight`.
- Панель: Go (версия из `panel/go.mod`), стандартная библиотека `net/http` и `golang.org/x/crypto` (argon2id) v0.58.0 с `golang.org/x/sys` v0.49.0. Текст `/metrics` пишется вручную. Фронт: ванильные ES-модули и CSS, без сборщика, фреймворков, иконочных шрифтов и внешних ресурсов.
- Тесты: `bats` для Bash, `go test` для панели, `node --test` для логики интерфейса. Проверки: `shellcheck`, `shfmt`, `gofmt`, `go vet`.
- Платформы (обязательные): Ubuntu LTS от 22.04, Debian от 12, Rocky Linux и AlmaLinux от 8. RHEL и CentOS Stream запускаются с предупреждением. openSUSE, Arch и любой другой Linux с systemd работают с компонентами в Docker. Более старые релизы `preflight` отклоняет кодом 3 (на свой риск: `DPISTACK_ALLOW_UNSUPPORTED=1`). Пакетные менеджеры: `apt`, `dnf` на хосте; `zypper`, `pacman`, `generic` требуют Docker для компонентов.
- По умолчанию только стабильные версии: без `master`, `nightly`, `latest`, `dev`. Suricata из последнего проверенного релиза серии 8.0 (`SURICATA_STABLE_REF`, сейчас `suricata-8.0.7`), nDPI 4.14 (`NDPI_COMPAT_REF`), ntop.org из стабильного канала, EveBox из `stable`. Образы Docker с закреплёнными тегами.
- Архитектуры: `amd64`, `arm64`. Контейнеры: только Docker с плагином `compose`.

## 3. Структура репозитория

| Путь | Назначение |
| --- | --- |
| `install.sh` | точка входа: аргументы, проверка root, диспетчер команд |
| `lib/*.sh` | `schema.sh` (схема ключей), `config.sh`, `os.sh`, `step_*.sh` (шаги установки), `ctl.sh` (глаголы управления), `menu.sh`, `render.sh`, `runtime_docker.sh`, `ips.sh` |
| `bin/dpistack-watch` | watchdog |
| `templates/` | шаблоны конфигов и юнитов (`@@KEY@@` и блоки, подставляет `lib/render.sh`) |
| `panel/` | панель: Go (`cmd/panel`, `internal/{api,auth,ctl,eve,export,health,metrics}`) и `web/` |
| `tests/` | тесты bats, заглушки в `tests/mocks/`, данные в `tests/data/` |
| `scripts/` | `gate.sh`, `bundle.sh`, `security.sh`, `check-conf-example.sh`, `gen-config-doc.sh`, `panel-budget.sh`, `suricata-*.sh` |
| `dpistack-install.sh` | единый файл установщика, **генерируется** `scripts/bundle.sh` |
| `docs/` | руководства; `configuration*.md` **генерируются** из схемы |
| `.github/` | CI, безопасность, релизы, Dependabot |

## 4. Контракты

### 4.1 Компоненты

| id | что | runtime | unit / контейнер |
| --- | --- | --- | --- |
| `suricata` | движок IDS/IPS | native, docker | `suricata.service` |
| `evebox` | просмотр алертов | native, docker | `evebox.service` |
| `ntopng` | монитор трафика | native, docker | `ntopng.service` |
| `redis` | хранилище ntopng, всегда там же, где `ntopng` | как у `ntopng` | `redis.service` (rpm) или `redis-server.service` (deb) |
| `victoriametrics` | бэкенд метрик, только при `METRICS_BACKEND=victoriametrics` | native, docker | `dpistack-vm.service` |
| `prometheus` | бэкенд метрик, только при `METRICS_BACKEND=prometheus` | native, docker | `prometheus.service` |
| `panel` | панель управления | native, docker | `dpistack-panel.service` |
| `watch` | watchdog | только native | `dpistack-watch.timer` |
| `rules` | обновление правил | только native | `dpistack-rules.timer` |

`ndpi` не компонент: это библиотека, а плагин `ndpi.so` часть `suricata`; `status` показывает его полем `ndpi_plugin`.

### 4.2 Пути

| что | путь |
| --- | --- |
| конфиг установки | `/etc/dpistack/dpistack.conf` (0644 root); черновик меню `dpistack.conf.draft` (0600) |
| секреты | `/etc/dpistack/secrets.conf` (0600 root) |
| хэш пароля панели | `/etc/dpistack/panel.auth` (0640 root:dpistack) |
| состояние | `/var/lib/dpistack/` (`state`, `health.json`, `events.jsonl`, `tests-last.json`, `metrics.json`, `backups/`, `staging/`, `scrape.yaml`) |
| блокировка, журнал установки | `/var/lock/dpistack.lock`, `/var/log/dpistack/install.log` |
| помощники | `/usr/local/sbin/dpistack` (персистентная команда), `/usr/local/sbin/dpistack-ctl` (ссылка на неё), `/usr/local/sbin/dpistack-watch`, библиотеки и шаблоны в `/usr/local/lib/dpistack/` (копия установщика в `installer/`) |
| панель | `/usr/local/bin/dpistack-panel` |
| Suricata | `/etc/suricata/suricata.yaml`, `/etc/suricata/{enable,disable,modify,drop}.conf`, `/etc/suricata/rules/local.rules`, `/var/lib/suricata/rules/suricata.rules`, `/var/log/suricata/eve.json`; сокет native `/run/suricata-command.socket`, docker `/var/run/suricata/suricata-command.socket` |
| EveBox, ntopng | `/etc/evebox/evebox.yaml` (порт 5636), `/etc/ntopng/ntopng.conf` (порт 3000) |
| compose | `/opt/dpistack/compose/compose.yaml` |

Файл `state` хранит отметки шагов, снимок применённого конфига (`applied.<KEY>=<значение>`) и счётчики watchdog (`watch.miss.<id>`, `watch.restarts.<id>`). Системный пользователь `dpistack` (без входа) запускает панель и читает `eve.json`.

### 4.3 Ключи `dpistack.conf`

Формат `KEY=value`, по одному в строке, без кавычек и подстановок. Проверка строгая: неизвестный ключ или значение вне вариантов останавливает установщик. Снятый ключ (`PANEL_MODE`) при загрузке файла отбрасывается. Значение, чья реализация не сделана, отклоняется сообщением `not supported yet`. Секреты только в `secrets.conf`. Таблица зеркалит `lib/schema.sh` (главная таблица в английском `tech.md`; здесь значения и варианты те же).

| ключ | по умолчанию | варианты / формат |
| --- | --- | --- |
| `SURICATA_RUNTIME` `EVEBOX_RUNTIME` `NTOPNG_RUNTIME` | `native` | `native` `docker` |
| `SURICATA_SOURCE` | `source` | `distro` `oisf` `source`; `oisf` это PPA OISF на Ubuntu и COPR `@oisf/suricata-8.0` на RHEL-семействе; на Debian нет |
| `SURICATA_VERSION` | пусто | для `source`: пусто = последний проверенный релиз серии 8.0, не `master`; значение это тег или ветка |
| `NDPI_ENABLE` | `yes` | `yes` `no`; `yes` требует плагин `ndpi.so` |
| `NDPI_SOURCE` | `source` | `pkg` `source` |
| `NDPI_VERSION` `NTOPNG_VERSION` `EVEBOX_VERSION` | пусто | пусто = версия по умолчанию (nDPI сейчас `4.14`, остальные последняя) |
| `PIN_VERSIONS` | `no` | `yes` `no`; `yes` = `apt-mark hold` / `dnf versionlock` |
| `SURICATA_MODE` | `ids` | `ids` `ips` |
| `IFACES` | `enp2s0` | имена через запятую; если осталось умолчание и такого интерфейса нет, `install` берёт интерфейс маршрута по умолчанию и пишет об этом |
| `BPF_FILTER` | пусто | выражение BPF |
| `HOME_NET` | авто | список CIDR; авто = частные диапазоны RFC 1918 |
| `IPS_METHOD` | `nfq` | `nfq` `afpacket` |
| `IPS_NFQ_CHAINS` | `INPUT,OUTPUT,FORWARD` | подмножество этих цепочек |
| `EVE_FILE` | `yes` | `yes` `no`; `no` отключает просмотр событий, проверку свежести и eve-метрики |
| `EVE_TYPES` | `alert,flow,dns,tls,http,stats` | из `alert,anomaly,dns,http,tls,files,flow,netflow,ssh,smb,stats,drop` |
| `EVE_SYSLOG` | `no` | `yes` `no` |
| `EVE_REDIS` | пусто | `host:port` или пусто |
| `EVE_ROTATE` | `daily` | `daily` `weekly` `size` |
| `EVE_KEEP` | `14` | число ротаций |
| `EVE_MAX_SIZE_MB` | пусто | число, нужен при `EVE_ROTATE=size` |
| `STATS_INTERVAL_SEC` | `30` | 5..300 |
| `RULES_SOURCES` | `et/open` | имена источников `suricata-update` через пробел |
| `RULES_URLS` | пусто | свои URL через пробел |
| `RULES_GROUPS` | `emerging-p2p,emerging-policy` | группы правил в `enable.conf` |
| `RULES_UPDATE` | `on` | `on` `off` |
| `RULES_UPDATE_CALENDAR` | `weekly` | синтаксис `OnCalendar` systemd |
| `NTOPNG_IFACES` | как `IFACES` | имена через запятую |
| `NTOPNG_PORT` `EVEBOX_PORT` `PANEL_PORT` | `3000` `5636` `9800` | 1..65535 |
| `EVEBOX_DB` | `sqlite` | `sqlite` `elasticsearch` |
| `EVEBOX_ES_URL` | пусто | URL, нужен при `elasticsearch` |
| `EVEBOX_RETENTION_DAYS` | `30` | дни, `0` = без ограничения (только SQLite) |
| `ACCESS_MODE` | `localhost` | `localhost` `lan` `nginx` |
| `LAN_CIDR` | авто | CIDR сети интерфейса по умолчанию |
| `PANEL_RUNTIME` | `native` | `native` (юнит `dpistack-panel.service`) или `docker` (сервис `panel` в том же compose-проекте: образ `dpistack-panel:<хэш бинарника>` с хоста из `alpine`, `network_mode: host`, `pid: host`, `privileged`; команды идут через `nsenter -t 1 -m -u -i -n -p -- env DPISTACK_CALLER=panel dpistack ...`); тяжёлое, шаг `panel` |
| `PANEL_EDITION` | `full` | `full` (насыщенная тёмная консоль с фоном из частиц) или `lite` (те же функции на простой лёгкой странице); лёгкое, шаг `panel`; спрашивается в быстрой установке |
| `PANEL_SOURCE` | `auto` | `auto` (готовый бинарник рядом с установщиком, иначе сборка), `build` (нужен Go), `prebuilt` (только готовый) |
| `NGINX_MANAGE` | `snippet` | `yes` (правит и перезагружает системный nginx) или `snippet` (пишет файл и печатает команду) |
| `NGINX_TLS` | `none` | `none` `selfsigned` `existing` |
| `NGINX_CERT` `NGINX_KEY` | пусто | пути, нужны при `existing` |
| `FIREWALL_MANAGE` | `no` | `no` `auto` (ufw или firewalld, только разрешить `LAN_CIDR`) |
| `METRICS_EXPORT` | `yes` | `yes` `no`; включает `GET /metrics` |
| `METRICS_BACKEND` | `none` | `none` `victoriametrics` `prometheus`; `none` = только эндпоинт |
| `METRICS_BACKEND_RUNTIME` | `native` | `native` `docker` |
| `METRICS_BACKEND_PORT` | пусто | пусто = 8428 (VictoriaMetrics) или 9090 (Prometheus) |
| `METRICS_RETENTION` | `30d` | число с суффиксом `h`, `d`, `w` или `y`; другие значения с бэкендом отклоняются |
| `WATCH_ENABLE` | `yes` | `yes` `no` |
| `WATCH_INTERVAL_SEC` | `60` | 10..3600 |
| `WATCH_EVE_STALE_SEC` | `300` | секунды без событий до `crit` |
| `WATCH_DROP_WARN_PCT` `WATCH_DROP_CRIT_PCT` | `1` `5` | проценты |
| `WATCH_DISK_WARN_PCT` `WATCH_DISK_CRIT_PCT` | `15` `5` | свободное место, проценты |
| `WATCH_RULES_WARN_DAYS` `WATCH_RULES_CRIT_DAYS` | `10` `30` | возраст правил |
| `WATCH_REPEAT_MIN` | `60` | повтор оповещения, пока статус не `ok` |
| `WATCH_AUTORESTART` | `no` | `yes` `no`; `yes` = не более 3 рестартов в час на компонент |
| `ALERT_CHANNELS` | `panel,log` | подмножество `panel,log,tg,mail` |
| `ALERT_TG_CHAT_ID` | пусто | нужен при `tg` |
| `ALERT_MAIL_TO` `ALERT_MAIL_FROM` | пусто | адреса, нужны при `mail` |
| `TEST_HTTPS_URL` | `https://example.com` | URL живого HTTPS-теста |
| `TEST_BT_LIVE` | `no` | `yes` подаёт pcap в живой интерфейс через `tcpreplay` |
| `TEST_ON_INSTALL` | `yes` | `yes` `no` |
| секреты | пусто | `ALERT_TG_TOKEN` (токен бота), `ALERT_SMTP_URL` (`smtp://user:pass@host:587`), `METRICS_TOKEN` (32 случайных байта в hex, создаётся при `METRICS_EXPORT=yes`) |

Перекрёстные проверки при загрузке:

- `NDPI_ENABLE=yes` при `SURICATA_SOURCE` `distro`/`oisf` допустим, только если после установки найден `ndpi.so`; иначе установщик предлагает `SURICATA_SOURCE=source` или останавливается с кодом 2.
- `EVE_TYPES` без `stats` при `WATCH_ENABLE=yes` даёт предупреждение: `eve_fresh` и `drop_rate` получат `na`.
- `METRICS_BACKEND` не `none` при `METRICS_EXPORT=no`, `EVEBOX_DB=elasticsearch` без `EVEBOX_ES_URL` и `EVE_FILE=no` при `EVEBOX_DB=sqlite` отклоняются.
- `ACCESS_MODE` не `localhost` требует подтверждения предупреждения раздела 1 (без терминала: `--set ACCESS_CONFIRM=yes`, ключ не сохраняется).
- `SURICATA_MODE=ips` только при `SURICATA_RUNTIME=native`; `IPS_METHOD=afpacket` требует чётного числа интерфейсов (не меньше двух).

Свободные ключи (тип `free`) проверяются шаблонами `SCHEMA_PATTERN` в `lib/schema.sh`: без кавычек, обратной косой, `$`, обратных кавычек, `;`, фигурных скобок и ведущего `-`. Отвергнутое значение секрета в сообщении не печатается.

### 4.4 CLI установщика и команда `dpistack`

```
install.sh <команда> [опции]
dpistack [команда] [опции]

команды: install | reconfigure | upgrade | uninstall | status | diag | test | logs | health | version | ...
опции:   --config FILE   --set KEY=VALUE   --non-interactive, -y   --advanced   --dry-run
         --only STEP[,STEP]   --skip STEP[,STEP]   --force   --purge   --no-color
```

На терминале (или с `DPISTACK_INPUT`) и без `-y` `install`, `reconfigure` и `dpistack` без аргументов открывают текстовое меню. `install.sh` без аргументов и без конфига предлагает установку; `dpistack` без аргументов при установленном конфиге открывает меню управления. **Только root:** любая команда без root завершается кодом 1; панель приходит через `sudo -n` и может запускать только глаголы управления (4.5). Коды возврата: `0` успех, `1` шаг упал, `2` неверные аргументы или конфиг, `3` preflight не пройден или изменение не поддерживается в этом режиме. `diag` пишет отчёт только для чтения (платформа, версии, пакеты, репозитории, конфиг без секретов, службы, `suricata -T`, хвосты журналов) в stdout и в `DIAG_OUT`; токены и пароли в URL заменяются на `<hidden>`.

### 4.5 Глаголы управления `dpistack`

Единственная точка привилегированных действий панели и watchdog: `sudo -n dpistack <глагол>`; правило sudoers называет `/usr/local/sbin/dpistack`. Все аргументы сверяются со списками до любого действия; допустимы буквы, цифры, `. _ : = / @ + , -` и пробел, остальное даёт код `5`.

| глагол | что делает |
| --- | --- |
| `status [--json]` | по компоненту: `id`, `runtime`, `state` (`active` `inactive` `failed` `absent`), `enabled`, `version`; плюс `ndpi_plugin` |
| `start\|stop\|restart <id>` | управляет компонентом через его runtime; `<id>` только из 4.1 |
| `reload suricata` | перечитать правила без остановки |
| `logs <id> [-n N] [--follow\|--until-stdin-closed]` | журнал, `N` до 1000; последняя форма заканчивается, когда закрыт stdin (для панели) |
| `config-read <name>`, `config-write <name> [--apply\|--check]`, `config-revert <name>` | файлы конфигов: stdin, `staging/`, проверка, бэкап, атомарная замена; `--apply` ещё перезагружает компонент (для `dpistack.conf` выполняет `reconfigure`) |
| `reconfigure [--light] [--dry-run]` | применить текущий `dpistack.conf` без вопросов; тяжёлые изменения дают код 3 |
| `settings list\|check\|set\|secret\|job` | все параметры с проверкой, весом и занятыми портами; см. `docs/operations.ru.md` |
| `rules-update`, `rules-sources`, `rules-group`, `rules-sid`, `rules-search` | правила: откат, если `suricata -T` отклонил набор; поиск до 50 правил |
| `iface list\|add\|remove <name>` | правит `IFACES`, затем `reconfigure`; последний интерфейс удалить нельзя (3), неизвестный даёт 5 |
| `mode ids\|ips [--confirm-timeout SEC]`, `mode status [--json]`, `mode-confirm` | IDS/IPS; `ips` откатывается сам, если `mode-confirm` не пришёл за `SEC` (10..3600, по умолчанию 120) |
| `mode-rollback`, `fw apply\|remove\|restore` | внутренние: откат по таймеру и цепочка `DPISTACK` (`restore` при загрузке) |
| `test bittorrent\|https\|all [--json]` | раздел 10 |
| `health [--json]` | один прогон watchdog |
| `panel-passwd` | пароль со stdin, хэш argon2id в `panel.auth` (`-id -t 3 -m 14 -p 4 -l 32`, 16 МиБ) |
| `version` | версия набора |

Имена конфигов: `suricata.yaml`, `evebox.yaml`, `ntopng.conf`, `dpistack.conf`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf`. `suricata.yaml` и файлы правил проходят `suricata -T` на временной копии; `dpistack.conf` проходит схему; `evebox.yaml` и `ntopng.conf` проверяются только на непустоту. Провал проверки ничего не меняет (код 3, вывод проверки в stdout). `config-write dpistack.conf` отвергает секретные ключи. Запись берёт блокировку установщика (до 30 с). Файл, записанный через `config-write`, установщик считает изменённым вручную. Коды глаголов: `0` успех, `1` ошибка, `2` неверное использование, `3` проверка не пройдена или недоступно в этом режиме, `4` компонент отсутствует, `5` имя вне списка.

### 4.6 `health.json` и события

`/var/lib/dpistack/health.json` перезаписывается атомарно каждым прогоном watchdog: `{"ts", "overall", "checks":[{"id","status","value","detail","since"}]}`. `status`: `ok`, `warn`, `crit`, `na`; `overall` худший (`na` не считается); `since` меняется только при смене статуса. Идентификаторы: `<id>.process` и `<id>.port` для `evebox`, `ntopng`, `redis`, `panel` и бэкенда метрик (у `suricata` только `.process`), затем `suricata.eve_fresh`, `suricata.drop_rate`, `disk.free`, `rules.age`. Значение ровно на пороге даёт худший статус; сравнение точной арифметикой.

`events.jsonl`: по строке на смену статуса (`ts`, `check`, `from`, `to`, `detail`); первое появление проверки со статусом `ok` или `na` событием не считается. `tests-last.json`: последний результат каждого теста (`{"results":[{"name","status","detail","duration_ms","timestamp"}]}`), один объект на строку, права `0644`; прогон одного теста не стирает результат другого.

### 4.7 Поля EVE, на которые опираются панель и тесты

`timestamp`, `event_type`, `in_iface`, `src_ip`, `dest_ip`, `proto` (все события); `alert.signature`, `alert.signature_id`, `alert.severity`, `alert.category`, `alert.metadata` (`alert`); `tls.sni` (`tls`); `stats.capture.kernel_packets`, `stats.capture.kernel_drops`, `stats.uptime` (`stats`). Плагин nDPI даёт только ключевые слова правил `ndpi-protocol` и `ndpi-risk`; полей `ndpi.*` в EVE нет. Drop rate интервала: `Δkernel_drops / Δkernel_packets × 100`; сброс счётчика пропускает интервал.

### 4.8 HTTP API панели

Ответы JSON; ошибка `{"error":"текст"}` с кодом 4xx/5xx. Все методы кроме `POST /api/login` и `GET /metrics` требуют сессию; изменяющие методы требуют заголовок `X-CSRF-Token`. **Обе редакции отдают один и тот же API.**

| метод и путь | что делает |
| --- | --- |
| `POST /api/login`, `POST /api/logout` | сессия в cookie `HttpOnly; SameSite=Strict` |
| `GET /api/status` | компоненты (`ctl status`) и `health.json` |
| `POST /api/components/{id}/{start\|stop\|restart}`, `POST /api/suricata/reload` | через `ctl`; остановка и перезапуск `panel` требуют `?confirm=yes` |
| `GET /api/config`, `GET /api/config/{name}`, `PUT /api/config/{name}?apply=0\|1`, `POST /api/config/{name}/check`, `POST /api/config/{name}/revert` | редактор конфигов |
| `GET /api/rules/sources`, `POST /api/rules/sources`, `POST /api/rules/update`, `GET /api/rules/search?q=`, `POST /api/rules/groups/{group}/{enable\|disable}`, `POST /api/rules/sid/{sid}/{enable\|disable}` | правила |
| `GET /api/logs/{id}?lines=N`, `GET /api/logs/{id}/stream` | последние строки; живой хвост по SSE (до 4 потоков сразу) |
| `GET /api/eve?type=&q=&since=&limit=`, `GET /api/eve/stream?type=` | события, новые сверху (`limit` 1..500); поток новых событий по SSE |
| `GET /api/metrics?range=1h\|6h\|24h` | ряды графиков `pps`, `drops`, `cpu`, `rss`, `eve_size`, `disk` на одной сетке |
| `POST /api/tests/{bittorrent\|https\|all}`, `GET /api/tests/last` | запуск теста (упавший тест это результат, 200; второй запуск, пока идёт первый, 409); последние результаты |
| `GET /api/alerts?limit=&check=` | строки `events.jsonl`, новые сверху |
| `GET /api/iface`, `POST /api/iface/{add\|remove}` | интерфейсы захвата |
| `GET /api/mode`, `POST /api/mode` (тело `{mode, acknowledged, confirm_timeout}`), `POST /api/mode/confirm` | режим IDS/IPS |
| `GET /api/settings`, `POST /api/settings/check`, `POST /api/settings/apply`, `GET /api/settings/job`, `PUT /api/settings/secret/{key}` | все параметры и секреты (схема приходит из `dpistack settings list --json`) |
| `GET /metrics` | экспорт Prometheus (4.9) |

Панель отвечает 403, если IP клиента вне `LAN_CIDR` (`ACCESS_MODE=lan`) или вне loopback (`localhost`); при `nginx` доверяет `X-Forwarded-For` только с loopback.

### 4.9 Экспорт метрик `GET /metrics`

Формат Prometheus text 0.0.4. Доступ: заголовок `Authorization: Bearer <METRICS_TOKEN>`, сессия не нужна. При `METRICS_EXPORT=no` ответ 404, без токена или с неверным 401. Метрика без данных не выдаётся вовсе.

`dpistack_component_up{component}`, `dpistack_check_status{check}` (`ok`=0, `warn`=1, `crit`=2), `dpistack_suricata_kernel_packets_total`, `dpistack_suricata_kernel_drops_total`, `dpistack_suricata_drop_ratio`, `dpistack_suricata_uptime_seconds`, `dpistack_eve_events_total{event_type}`, `dpistack_eve_size_bytes`, `dpistack_eve_last_event_age_seconds`, `dpistack_disk_free_ratio{path}`, `dpistack_rules_age_seconds`, `dpistack_test_status{test}`, `dpistack_test_timestamp_seconds{test}`, `dpistack_panel_rss_bytes`. Метрики `eve` и `suricata_*` не выдаются при `EVE_FILE=no` или без `stats` в `EVE_TYPES`.

## 5. Установщик

**Шаг** это пара `step_<имя>_check` (0, если состояние уже соответствует конфигу) и `step_<имя>_apply`, плюс `step_<имя>_plan` (строка для dry-run). Порядок: `preflight`, `selfinstall`, `ndpi`, `suricata`, `rules`, `redis`, `ntopng`, `evebox`, `metrics`, `access`, `panel`, `watch`, `verify`. `selfinstall` копирует установщик в `/usr/local/lib/dpistack/installer/` и кладёт его в `/usr/local/sbin/dpistack`.

- **Меню** (`lib/menu.sh`, чистый Bash, без dialog и ncurses): ввод из stdin или `/dev/tty`, `DPISTACK_INPUT=<файл>` подменяет его (тесты). Выбор номером или буквой, `0` или пустой ввод наверх, `?` справка, `q` выход. Быстрая установка спрашивает интерфейсы, источник Suricata, режим доступа, **какую панель ставить (`full` или `lite`)** и пароль панели. Разделы: захват, компоненты, EVE, правила, доступ, метрики, наблюдение, тесты, пароль панели. Основные ключи видны сразу, остальные по `a` (или `--advanced`). Правки пишутся в черновик после каждого изменения; `dpistack.conf` меняется только при применении. Секреты вводятся без эха и показываются как «set»/«not set».
- **Ход установки:** слои значений (умолчания, `dpistack.conf`, секреты и окружение, `--config`, `--set`, правки меню), проверка конфига, сводка и подтверждение, `preflight` (все проблемы списком, код 3), подготовка пакетов, план (`--dry-run` заканчивается здесь, ничего не пишется, пароль не генерируется), шаги по порядку (`apply`, затем `check` как постусловие), шаг `verify` (`dpistack test all` при `TEST_ON_INSTALL=yes`; провал теста установку не отменяет) и итоговый отчёт (адреса, результаты тестов, токен `/metrics` с готовым `scrape_config`, сгенерированный пароль панели один раз, предупреждения). Упавший шаг останавливает установку и печатает, как продолжить: `install.sh install --only <шаг>`.
- **Пароль панели:** вводится в меню; с `-y` берётся из `DPISTACK_PANEL_PASSWORD` или генерируется случайный в 24 символа и печатается один раз. Хранится только хэш argon2id.
- **Reconfigure:** diff применённого и нового конфига, затронутые шаги, деление на лёгкие изменения (перерисовка и перезапуск) и тяжёлые (пакеты, сборка, runtime, версия, пиннинг; нужны `--force` или `settings set --apply-heavy`), рендер с бэкапами, проверка `suricata -T`, затем перезапуск; провал проверки оставляет прежние файлы.

| группа ключей | шаги | вес |
| --- | --- | --- |
| `IFACES`, `BPF_FILTER`, `HOME_NET`, `SURICATA_MODE`, `IPS_*`, `EVE_*`, `STATS_INTERVAL_SEC` | `suricata`; `ntopng` для `IFACES`; `watch` для `EVE_*` | лёгкий |
| `RULES_*` | `rules` | лёгкий |
| `NTOPNG_*`, `EVEBOX_PORT`, `EVEBOX_RETENTION_DAYS`, `EVEBOX_ES_URL` | `ntopng` или `evebox`, `access` | лёгкий |
| `ACCESS_MODE`, `LAN_CIDR`, `PANEL_PORT`, `PANEL_EDITION`, `NGINX_*`, `FIREWALL_MANAGE` | `access`, `panel` | лёгкий |
| `WATCH_*`, `ALERT_*`, `TEST_*` | `watch`, `verify` | лёгкий |
| `METRICS_EXPORT`, `METRICS_RETENTION`, `METRICS_BACKEND_PORT` | `metrics`, `panel` | лёгкий |
| `METRICS_BACKEND`, `METRICS_BACKEND_RUNTIME`, `*_RUNTIME`, `*_SOURCE`, `*_VERSION`, `NDPI_*`, `PIN_VERSIONS`, `EVEBOX_DB`, `PANEL_SOURCE` | шаг компонента | тяжёлый |

- **Идемпотентность:** повторный запуск с тем же конфигом ничего не меняет (каждый шаг пишет `no changes`). Отрендеренный файл хранит хэш последнего рендера в `state`; файл, изменённый руками, остаётся, установщик сообщает об этом; `--force` делает бэкап и перезаписывает. Пакеты ставятся, только если их нет или версия расходится с закреплённой. Установщик никогда не сбрасывает и не пересоздаёт чужие цепочки iptables/nft: свои правила в цепочке `DPISTACK` (или таблице nft `inet dpistack`), которую при загрузке восстанавливает `dpistack-fw.service`.
- **Preflight:** root, Bash 4.4+, поддерживаемые дистрибутив и архитектура, systemd (native), Docker с `compose` (если нужен), интерфейсы из `IFACES` существуют, свободное место (4 ГБ для сборки из исходников, иначе 1 ГБ), нужные хосты доступны, порты свободны (с nginx и порт за ним), режим SELinux. Занятый порт в меню это предупреждение с именем процесса и свободным портом; без терминала установка останавливается с кодом 3. Печатаются все проблемы, а не первая.
- **dnf-семейство:** `dnf makecache`, базовые пакеты только для недостающих команд, `epel-release` и `crb` (на 8 `powertools`) для Rocky, AlmaLinux и CentOS, `dnf versionlock`, COPR OISF, когда Rust слишком старый. Контексты и порты SELinux задаются `semanage` и `restorecon`.
- **Сборка из исходников:** сначала ставятся зависимости; Suricata из git нужен Rust 1.85 (при более старом системном берётся пакет `rustc-1.N`); при наличии только Rust 1.75 берётся пакет дистрибутива или OISF, nDPI выключается с сообщением.
- **Режимы и секреты:** в неинтерактивном режиме значения идут из `--config`, `--set`, затем умолчаний; запрос ввода там ошибка. `--dry-run` печатает `+ команда` и ничего не пишет. Секреты не попадают в `dpistack.conf`, журнал установки и вывод dry-run; `set -x` запрещён.
- **Обновление и удаление:** `upgrade` учитывает `PIN_VERSIONS`. `uninstall` останавливает и удаляет юниты, бинарники и копию установщика, цепочку `DPISTACK` и правила ufw/firewalld, добавленные dpistack, и перезапускает Suricata, работавшую в NFQ; данные и конфиги остаются. `--purge` удаляет и их (флаг служит подтверждением; в меню вводится слово `remove`).

## 6. Suricata и nDPI

- **Захват:** `af-packet`, блок на интерфейс из `IFACES`, `cluster-type: cluster_flow`, `defrag: yes`, `threads: auto`, уникальный `cluster-id`; `BPF_FILTER` подставляется, если задан.
- **nDPI:** при `NDPI_ENABLE=yes` в `plugins:` добавляется `ndpi.so` установленной Suricata. Правила с `ndpi-protocol` или `ndpi-risk` обязаны начинаться с `requires: keyword ...`, чтобы Suricata без плагина их пропускала. Сборка из исходников: `./configure --enable-ndpi --with-ndpi=<префикс>`; несовместимость выводится как есть.
- **Конфиг:** `suricata.yaml` рендерится целиком из шаблона, соответствует серии собранной Suricata (`suricata-version`) и проверяется `suricata -T` до записи; один шаблон для IDS и IPS.
- **IDS → IPS:** `mode` включает `afpacket` copy-mode или NFQUEUE-правила в цепочке `DPISTACK` (с `--queue-bypass`, чтобы упавшая Suricata не отрезала сеть), перезапускает Suricata и запускает таймер отката; без `mode-confirm` вовремя режим возвращается в `ids`. Правила `drop` берутся из `drop.conf`, сами не создаются.
- **EVE:** типы из `EVE_TYPES`, `stats` раз в `STATS_INTERVAL_SEC`, права `0640`, `logrotate` без `copytruncate` и затем `suricatasc -c reopen-log-files`.

## 7. Правила

Источники `RULES_SOURCES` и `RULES_URLS`; свои правила в `local.rules` подключаются всегда; `RULES_GROUPS` превращаются в строки `group:<имя>.rules` в `enable.conf`; отдельные правила отключаются в `disable.conf`. `dpistack-rules.timer` (`OnCalendar=$RULES_UPDATE_CALENDAR`, `Persistent=true`): снимок, `suricata-update`, `suricata -T`, перезагрузка; любая ошибка возвращает снимок и оставляет `rules.age` растущим (это увидит watchdog). `RULES_UPDATE=off` не создаёт таймер.

## 8. Watchdog

`dpistack-watch` запускается таймером каждые `WATCH_INTERVAL_SEC` как oneshot от root и ничего не чинит, пока `WATCH_AUTORESTART=no`.

| проверка | как | ok / warn / crit |
| --- | --- | --- |
| `<id>.process` | состояние через runtime | active / `na` если нет / failed или inactive |
| `<id>.port` | `ss -ltn` на порту из конфига (с nginx порт сервиса плюс 10000; redis 6379) | слушает / нет 1-2 прогона / нет 3 и больше |
| `suricata.eve_fresh` | возраст `eve.json` по mtime | моложе `WATCH_EVE_STALE_SEC` / файла нет / старше |
| `suricata.drop_rate` | два последних `stats` (последние 4 МБ файла) | ниже `WARN` / от `WARN` / от `CRIT` |
| `disk.free` | наименьшая доля свободного места по разделам логов Suricata, данных EveBox (sqlite) и бэкенда метрик | выше `WARN` / ниже `WARN` / ниже `CRIT` |
| `rules.age` | возраст `suricata.rules` | младше `WARN_DAYS` / от `WARN_DAYS` или файла нет / от `CRIT_DAYS` |

`na`: проверка неприменима (`EVE_FILE=no`, нет `stats`, `RULES_UPDATE=off`, компонента нет). При `WATCH_AUTORESTART=yes` упавший компонент перезапускается через `restart <id>` не более 3 раз за скользящий час. **Оповещения** уходят при смене статуса и повторяются каждые `WATCH_REPEAT_MIN`, пока статус не `ok`; при возврате в `ok` уходит сообщение о восстановлении. Каналы `ALERT_CHANNELS` работают независимо: `panel` (строка в `events.jsonl`), `log` (`logger`), `tg` (Bot API через `curl`) и `mail` (`curl --url "$ALERT_SMTP_URL"`, без локального MTA). Сбой канала пишется в журнал и не мешает остальным. Тексты английские, одна строка на проверку.

## 9. Панель

**Бюджет:** RSS в простое не больше 25 МБ, бинарник не больше 15 МБ, статика не больше 150 КБ, ноль CPU без открытых вкладок и без запросов `/metrics`. У юнита `ProtectHome=yes`, `PrivateTmp=yes`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`; **нет `MemoryMax` и `CPUQuota`** (решение 2026-10-24: путь к более лёгкой панели это редакция lite). `NoNewPrivileges` и `ProtectSystem` не ставятся: `sudo` наследует ограничения юнита и `dpistack` не смог бы писать в `/etc`.

**Редакции (v0.23.0).** `PANEL_EDITION=full|lite` заменил `PANEL_MODE=limited|unlimited`. У обеих редакций одни экраны, один API и одни функции. Файлы выбирает сервер: страница всегда просит `app.css` и `fx.js`; редакция `full` отвечает `full.css` и `fx.js`, `lite` отвечает `lite.css` и пустым `nofx.js`, поэтому страница lite никогда не загружает полный дизайн.
- **full:** тёмная консоль в духе дорогих инструментов разработчика: почти чёрный фон, матовые карточки с тонкими полупрозрачными границами и мягкими внутренними бликами, один холодный синий акцент в малых дозах, боковая панель с маркой и тонкими линейными иконками (активный пункт светлой «таблеткой» с лёгким свечением), капсульные элементы, поочерёдное появление блоков 150-550 мс с мягкой кривой, подъём карточек при наведении и тихий фон из дрейфующих точек с тонкими линиями на canvas (`fx.js`: тусклый, не более 70 точек и 2x плотности пикселей, пауза на скрытой вкладке, один неподвижный кадр при `prefers-reduced-motion`). Только системные шрифты (`Inter`, `Geist`, `Manrope`, если установлены), потому что политика запрещает внешние. На узких экранах боковая панель становится полосой сверху.
- **lite:** простая светлая страница с системными шрифтами и маленьким файлом стилей, без canvas и анимаций; следует `prefers-color-scheme`.
- Установщик спрашивает редакцию в быстрой установке; экран «Настройки» и `dpistack settings set --apply PANEL_EDITION=...` переключают её (лёгкое изменение: юнит рендерится заново и перезапускается). Старый `dpistack.conf` с `PANEL_MODE` загружается: ключ отбрасывается.
- Экраны в обеих редакциях: Overview, Components, Settings, Configs, Rules, Logs, Events, Metrics, Tests, Alerts. Правила интерфейса: без внешних шрифтов, скриптов и картинок, без инлайн-скриптов и стилей (CSP), `textContent` вместо `innerHTML`, графики на inline SVG, хэш-роутер, редактор на обычном `<textarea>`, опасные действия за подтверждением.

**Поведение:** `eve.json` читается инкрементально с сохранённого смещения (целиком не разбирается; первое чтение берёт не больше 4 МиБ с конца); кольцо не больше 5000 событий в памяти. Кольцо графиков: 24 часа по 30 секунд, снимок в `metrics.json` раз в час и при остановке; `/metrics` строится из тех же данных и читает диск не чаще раза в секунду. Опрос `status` раз в 10 с и только на видимой вкладке; SSE открывается только на экранах логов и событий. Один администратор, argon2id, 5 попыток входа за 5 минут на IP, сессия 12 часов. Каждый изменяющий запрос требует токен CSRF. Адрес клиента: адрес соединения, `X-Forwarded-For` только с loopback (последняя запись). Флаги передаёт юнит (в `dpistack.conf` панель не заглядывает): `-addr`, `-access`, `-lan-cidr`, `-auth-file`, `-health-file`, `-ctl`, `-tests-file`, `-events-file`, `-eve-file`, `-metrics-file`, `-metrics-token-file`, и `-lite` для редакции lite. В контейнере панель вызывает `dpistack` через `nsenter` с `DPISTACK_CALLER=panel`.

## 10. Проверочные тесты (`dpistack test`)

Результат: `{"name","status","detail","duration_ms"}`, `status` из `pass`, `fail`, `skip`; итог пишется в `tests-last.json`. Код `0`: все `pass` или `skip`, `1`: есть `fail`.

- **`bittorrent`** (офлайн): `suricata -r tests/data/bittorrent.pcap` с конфигом из `suricata-test.yaml.tpl` во временный каталог; `pass`, если появился `alert` с сигнатурой, содержащей `BitTorrent`. При загруженном плагине nDPI тест добавляет своё правило `ndpi-protocol:BitTorrent` (sid 9000001). `skip` с причиной, если нет ни правил `emerging-p2p`, ни плагина. `TEST_BT_LIVE=yes` дополнительно подаёт pcap в первый интерфейс через `tcpreplay`.
- **`https`** (живой): `curl --max-time 15 "$TEST_HTTPS_URL"`, затем до 20 секунд ждёт событие `tls` с `tls.sni`, равным хосту; нет `eve.json`: `fail` сразу; `detail` называет причину (curl не прошёл, событий нет, интерфейс захвата не тот, что у curl).
- **`all`** запускает оба; `verify` запускает его при `TEST_ON_INSTALL=yes`.

## 11. Тесты проекта

Тесты выводятся из критериев приёмки, а не из готового кода. Bash: `bats` с заглушками внешних команд в `tests/mocks/` через `PATH`, пути перенаправляются `DPISTACK_ROOT`, переменные только для тестов `DPISTACK_INPUT`, `DPISTACK_TEST_WAIT`, `DPISTACK_NOW`. Go: `go test` с `httptest` и интерфейсом `ctl.Runner`. Интерфейс: `node --test` для чистой логики. Запрещённый вид теста: «выполнили шаг, проверили 0»; тест проверяет результат (содержимое файла, вызванные команды, отказ). Каждое изменение приносит тест на каждый критерий, тест пути ошибки и, для шагов установщика, тест идемпотентности. Матрица платформ перед выпуском: Ubuntu 22.04 и 24.04, Debian 12 и 13, Rocky Linux или AlmaLinux 8, 9 и 10, на каждой `install -y`, источники `distro` и `oisf` там, где они есть, повторная установка, `reconfigure`, `upgrade`, `uninstall --purge` и `dpistack test all`.

## 12. Проверки и гейт

`scripts/gate.sh` запускает `shfmt -d`, `shellcheck -x -S style`, `scripts/security.sh`, `scripts/bundle.sh --check`, `scripts/check-conf-example.sh` (ключи и умолчания примера против 4.3 и схемы), `scripts/gen-config-doc.sh --check` (оба справочника), `bats tests` и, если есть `panel/`, `gofmt -l`, `go vet`, `go test`, `node --test` и `scripts/panel-budget.sh`. Красный гейт значит, что работа не закончена.

- **CI/CD (`.github/`):** workflow `ci` запускает гейт на Ubuntu 22.04 и 24.04 (с таймаутом), плюс `actionlint`, `gitleaks` и `trivy`; workflow `security` запускает `scripts/security.sh`; выпуск это тег `vX.Y.Z` на `main` (тег не на `main` не публикуется): бинарники панели, единый файл установщика и подтверждение происхождения. Действия GitHub закреплены по SHA, обновления идут от Dependabot.
- **Проверка релизов Suricata:** `suricata-watch.yml` раз в неделю собирает закреплённый релиз установщиком, сравнивает закреплённый тег с финальными тегами `OISF/suricata`, собирает более новый релиз той же серии и открывает issue («verified: raise SURICATA_STABLE_REF» или «failed the build check»), а новую серию объявляет один раз. В репозитории ничего не меняет.
- **Ветки и слияние:** `main` защищена (проверки `gate (ubuntu-22.04)`, `gate (ubuntu-24.04)`, `lint workflows`, `gitleaks`, `shell security checks`, `trivy (config and secrets)`; только pull request; force-push запрещён). Работа идёт в `dev`; коммит должен пройти локальный гейт и проверки GitHub; только когда всё зелёное, открывается PR `dev` → `main` и сливается коммитом слияния (не squash, не rebase) с сообщением `merge dev into main: <что вошло>`. Выпуск это тег на `main`.
- **Проверки безопасности (`scripts/security.sh`):** секреты в отслеживаемых файлах, `eval` и `bash -c` над собранной строкой, `curl | sh`, `chmod` с записью для группы и остальных, фиксированные пути в `/tmp` и `mktemp -u`, `set -u` в каждой точке входа, CRLF, секреты в аргументах `curl` (они идут через `-K -` на stdin).

## 13. Конвенции

- **Язык.** Программа только на английском: сообщения, меню, ошибки, текст панели, комментарии. Документы пишутся сначала на английском и хранятся на русском рядом (`X.md` и `X.ru.md`, каждый ссылается на двойника); меняются вместе, а `tests/docs.bats` проверяет, что у каждого документа есть двойник. Сгенерированные справочники (`docs/configuration.md`, `docs/configuration.ru.md`) делает `scripts/gen-config-doc.sh` (английские подсказки лежат в `settings-model.js`, русские в `scripts/config-hints.ru`).
- **Решения «выбирай сам»** принимает разработчик и записывает в этот файл. Нет нужного контракта: остановиться и спросить владельца, а не выдумывать ключ или поле.
- **Предпочитать готовые решения** (пакеты, образы, утилиты) написанию кода с нуля.
- **Тесты, CI/CD и проверки безопасности** часть проекта и описаны здесь (разделы 11 и 12).
- **Git-процесс этого репозитория:** коммит в `dev`, дождаться тестов, и только если всё зелёное слить `dev` в `main` (12, «Ветки и слияние»). Версия программы в `lib/common.sh` и в этом файле меняется вместе.
- **Токены** доступа к GitHub используются только в сеансе и никогда не записываются в репозиторий, URL удалённого репозитория и файлы памяти.

## 14. Решения

- **2026-10-24, v0.23.0.** `PANEL_MODE` (limited/unlimited) убран вместе с лимитами юнита `MemoryMax=64M` и `CPUQuota=20%` и флагом `-max-streams` (потоков 4); добавлен `PANEL_EDITION=full|lite`, он спрашивается в быстрой установке. Панель `full` переработана (тёмные матовые поверхности, один синий акцент, боковая панель, анимации появления, фон из частиц); `lite` сохраняет все функции на простой светлой странице. Программа переведена на английский; документы стали английскими в первую очередь с русскими двойниками. Файл очищен: журнал изменений, итоги слайсов и журналы ревью удалены (они остаются в истории git).
- **Прежние решения, которые действуют:** `dpistack` и `dpistack-ctl` это одна программа; панель содержит все параметры программы; компоненты работают на хосте или в Docker в любых сочетаниях; занятый порт даёт предупреждение и выбор; `suricata.yaml.tpl` соответствует серии собранной Suricata и проверяется `suricata -T`; команда `dpistack` всегда от root и иначе отказывает; `main` защищена и получает только проверенные слияния из `dev`.
