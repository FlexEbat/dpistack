# tech.md: dpistack (nDPI + Suricata + EveBox + ntopng)

**Версия документа: v8** (2026-10-10)
**Версия программы: v0.3.2** (слайсы 0–15 реализованы в ветке `dev`, ждут реальной проверки на стенде; см. раздел «Changelog программы» ниже)

Changelog программы (что реально сделано по слайсам из раздела 17, в `dev`, до реальной проверки на стенде):
- v0.1.0 (слайсы 0–7): каркас установщика (`install.sh`, схема `dpistack.conf`, послойный конфиг, блокировка); Suricata (`distro`/`oisf`/`source`, рендер `suricata.yaml`, logrotate, systemd); nDPI (пакет или сборка из исходников); правила (`suricata-update`, безопасное обновление с сохранением прежнего набора, таймер); Redis и ntopng; EveBox (официальный репозиторий, `evebox.yaml`, retention); доступ (`localhost`/`lan`/`nginx`, TLS, `ufw`). Гейт (`shfmt`+`shellcheck`+`bats`) зелёный. Не проверено на реальном стенде: PPA OISF, репозитории ntop.org и evebox.org, реальная выкачка ET Open, сборка Suricata+nDPI (нужен Rust ≥1.85), `ufw`/SELinux вживую — см. `docs/prototype.md` и `docs/real-test-guide.md`.
- v0.2.0 (слайсы 8–9): `reconfigure` — настоящий транзакционный поток (diff, лёгкое/тяжёлое, проверка `suricata -T` на временном файле до записи на диск, применяются только затронутые шаги); `upgrade` (`apt-get install --only-upgrade`, закреплённые версии пропускает сам apt); `uninstall`/`--purge` (удаляет только созданное самим dpistack, пакеты и сервисы компонентов не трогает — решение, не буквальное прочтение спеки, см. `docs/prototype.md`); текстовое меню `install`/`reconfigure` (без диалоговых библиотек) — быстрая установка, разделы по группам ключей, черновик, пароль панели, подтверждения. `lib/render.sh` — общий рендер `@@KEY@@` вместо рассинхронизированных `awk` по шагам. Гейт: 95 bats, зелёный.
- v0.3.0 (слайсы 10–13): `dpistack-ctl` (статус, управление, логи, конфиги с бэкапом и откатом, `reconfigure`, правила, `iface`, `panel-passwd`, `test`, `health`); шаг `panel` (пользователь `dpistack`, `sudoers` с проверкой `visudo`); проверочные тесты BitTorrent и HTTPS и шаг `verify`; `dpistack-watch` с шагом `watch` и юнитами. Пароль панели хранится как argon2id (пакет `argon2`), `reconfigure` сравнивает конфиг со снимком применённого состояния. Гейт: 164 bats, зелёный. Не проверено на реальном стенде: `suricata -r` с `suricata-test.yaml`, правило `requires: keyword ndpi-protocol` на настоящей сборке с nDPI, `sudo -n` от пользователя `dpistack`, `argon2` на dnf-семействе. Модули `selfinstall` (слайс 15) ещё нет, поэтому юнит watchdog пропускает запуск до появления копии установщика.
- v0.3.2 (повторное ревью, раздел 18.2): рендер конфигов сохраняет права (раньше `evebox.yaml`, юниты и `logrotate` получали 0600), сбой `run` в шагах останавливает шаг, `universe` только на Ubuntu, снимок `applied` под блокировкой `state`.
- v0.3.1 (слайсы 14–15 и полное ревью): каналы оповещений (`log`, `tg`, `mail`, `panel`), `selfinstall` с командой `dpistack` и меню управления; исправления из раздела 18.1: `run` возвращает настоящий код ошибки, запись файлов не оставляет обрезанный результат, `state` защищён блокировкой, свободные ключи `dpistack.conf` проверяются шаблонами, `*_VERSION` для ntopng и EveBox действуют, CI закреплён по SHA.

Changelog_tech:
- v8: защита ветки `main` и слияние через pull request (12.3), результат повторного ревью (18.2).
- v7: порядок веток и слияния dev в main (12.3); полное ревью кода и CI (18.1); шаблоны свободных ключей (4.3), правила `ctl` для секретов, блокировки и `logs -n` (4.5), закрепление действий по SHA и проверка тега на `main` (12.1).
- v6: слайсы 14 и 15 (каналы оповещений, `selfinstall` и меню управления), CI/CD и проверки безопасности (12.1, 12.2), структура репозитория дополнена `.github/`, `scripts/security.sh`, `SECURITY.md`. Ревью и поиск ошибок: результат записан в разделе 18.
- v5: решения по слайсам 10–13, внесённые владельцем разрешением «выбирай сам». (1) Допущение A2 закрыто: в смерженном плагине nDPI нет отдельных полей `ndpi.*` в EVE, nDPI виден через `alert.signature` и `alert.metadata`; тест BitTorrent при плагине подкладывает своё правило `ndpi-protocol:BitTorrent` (раздел 10, 4.7). (2) Допущение A8 закрыто: режима проверки конфига у EveBox и ntopng нет, проверяется непустота (4.5). (3) Описан формат `tests-last.json` (4.6). (4) Состояние применённого конфига хранится в `state` как `applied.<KEY>`, по нему `reconfigure` определяет разницу (4.2, 4.5). (5) Хэш пароля панели argon2id считает CLI `argon2` (4.5). (6) Раздел 8 дополнен: порог даёт худший статус, смысл состояний `process` и `port`, `jq` как зависимость. (7) Переменные окружения для тестов описаны в разделе 11.
- v4: `install.sh` устанавливает себя как персистентную команду `dpistack` (`/usr/local/sbin/dpistack`, новый шаг `selfinstall`). Без аргументов `dpistack` открывает CLI-меню: установка при отсутствии конфига, иначе меню управления (Настроить, Статус, Логи, Тесты, Обновить, Удалить, Пароль панели) — раздел 5.2. Раздел 5 перенумерован (5.0–5.7). Новый слайс 15 «персистентная команда `dpistack` и меню управления»; слайсы 15–29 сдвинуты на +1 (стало 31 слайс, 0–30), стадия 4 переименована в «управление и панель» (15–25), стадия 5 — 26–30.
- v3: `install` и `reconfigure` — это текстовое меню (раздел 5.0), а не только линейный прогон по конфигу. Новый слайс 9 «меню install и reconfigure»; все слайсы с прежним номером 9 и далее сдвинуты на +1 (было 28 слайсов, стало 29), границы стадий 2–5 пересчитаны.
- v2: удалён LXD (runtime только `native` и `docker`). Добавлены экспорт метрик `/metrics` и бэкенды VictoriaMetrics/Prometheus (ключи `METRICS_*`, раздел 4.9), команда `reconfigure` и пошаговое описание `install`/`reconfigure` (раздел 5), retention EveBox, модель угроз (раздел 1), слайс 0 (ручной прототип), слайс README и LICENSE. Крупные слайсы разбиты, стадия 5 отнесена к «после MVP». Умолчания изменены: `NDPI_ENABLE=yes`, `SURICATA_SOURCE=source`.
- v1: первая версия. Структура и дисциплина взяты из tech.md сайта заметок (слайсы, гейт, DoD, `CONTRACT GAP`). Предметная область, стек и контракты написаны заново.

---

## Предметная область (кратко)

- **DPI (deep packet inspection):** определение прикладного протокола потока по содержимому пакетов, а не по номеру порта. Библиотека **nDPI** (ntop) делает это и ставит потокам «риски» (самоподписанный сертификат, протокол на нестандартном порту и т.д.).
- **Suricata:** движок сигнатур. В режиме **IDS** смотрит копию трафика и только сообщает, в режиме **IPS** стоит в разрыве и может отбрасывать пакеты. Плагин nDPI добавляет ключевые слова правил `ndpi-protocol` и `ndpi-risk`. Плагин появляется только в сборке Suricata с `--enable-ndpi`.
- **EVE JSON:** построчный JSON-журнал Suricata (`alert`, `flow`, `dns`, `tls`, `http`, `stats` и др.). Единый источник данных для EveBox, панели, watchdog и тестов.
- **EveBox:** веб-просмотр алертов Suricata («Inbox»), хранит события во встроенном SQLite или в Elasticsearch.
- **ntopng:** веб-монитор трафика в реальном времени (хосты, потоки, протоколы), использует Redis и собственную копию nDPI.
- **Правила:** наборы сигнатур. Источник по умолчанию: Emerging Threats Open через `suricata-update`. Группы `emerging-p2p` и `emerging-policy` ловят BitTorrent и нарушения политики.
- **Метрики:** числовые ряды во времени. Формат Prometheus (`/metrics`) читают Prometheus, VictoriaMetrics и `vmagent`.
- **Точка съёма трафика:** пассивный захват (`af-packet`) видит только пакеты, проходящие через интерфейс самого хоста. Чтобы видеть всю сеть, нужны зеркальный порт, шлюз или inline-включение. Хост вне разрыва сети с NFQUEUE в цепочках `INPUT`/`OUTPUT` защищает только себя.

## ТЗ (кратко)

1. **Установщик** `install.sh` на Bash: интерактивный (CLI-меню) и неинтерактивный режимы, идемпотентный, есть `--dry-run`, `reconfigure`, `upgrade`, `uninstall`. После установки доступен как персистентная команда `dpistack` с тем же меню для настройки, статуса, логов, тестов, обновления и удаления.
2. **Ставит** nDPI, Suricata, Redis, ntopng, EveBox, systemd-юниты, конфиг EVE, logrotate. Источник Suricata (пакеты дистрибутива, OISF, исходники), пиннинг версий и способ развёртывания каждого компонента (`native` или `docker`) выбирает пользователь.
3. **ОС:** Ubuntu, Debian, Fedora, RHEL и совместимые (Rocky, Alma, CentOS Stream).
4. **Захват:** режим IDS по умолчанию, IPS опционально. Интерфейсы: список, по умолчанию `enp2s0`, добавление и удаление без переустановки. Есть офлайн-реплей pcap.
5. **Правила:** ET Open плюс дополнительные и свои источники, автообновление раз в неделю (настраивается), группы p2p и policy включены.
6. **Доступ к веб-интерфейсам:** `localhost`, `lan` или через `nginx`. Внешний SSO не нужен.
7. **Проверки:** BitTorrent (реплей pcap) и обычный HTTPS (живой запрос) с автоматическим вердиктом.
8. **Watchdog:** проверяет процессы, порты, свежесть `eve.json`, drop rate, место на диске, возраст правил. Оповещения: панель, лог, Telegram, почта, каналы комбинируются.
9. **Метрики:** панель отдаёт `/metrics` в формате Prometheus. Опционально установщик ставит VictoriaMetrics или Prometheus и настраивает сбор.
10. **Личная панель:** лёгкая по ресурсам, современный вид. MVP: статус компонентов, start/stop/restart, редактор конфигов с валидацией (`suricata -T`), управление правилами, запуск тестов, просмотр логов и EVE-событий, графики метрик.
11. **MVP** = стадии 0–4: Ubuntu/Debian, компоненты `native`, режим IDS. Docker, dnf-семейство, бэкенд метрик, IPS и единый файл идут после.
12. **Не входит:** мультипользовательская панель, свой SSO, дашборды Grafana, ntopng Enterprise, podman, LXD, i18n, перехват трафика всей сети без подходящей топологии.

---

## 0. Как читать этот файл

Это источник истины проекта. Читай его перед каждой задачей и подчиняйся дословно.

- Имена ключей конфига, путей, команд, метрик, полей и эндпоинтов берутся отсюда. Свои варианты не придумывай.
- Нужного контракта здесь нет → СТОП, выдай блок `CONTRACT GAP` (раздел 15). Код с выдуманным ключом или полем не пиши.
- Файл меняет только владелец проекта. Каждое изменение контракта поднимает версию сверху файла.
- Работаешь один слайс за заход. Стадии и слайсы в разделе 17, иди сверху вниз.

---

## 1. Проект

Набор из установщика, двух служебных скриптов и панели для домашней или небольшой лаборатории DPI/IDS. Один хост, один администратор.

Цель: работающая связка, которую поднимает одна команда, которой управляют из браузера и которая сама сообщает о поломках. Не SIEM, не платформа для нескольких хостов, не замена промышленного NDR.

Ограничение топологии: хост видит только трафик своего интерфейса. Установщик печатает это предупреждение при выборе интерфейсов и не обещает видимость всей сети.

**Модель угроз (коротко):**

- Редактор конфигов панели даёт доступ уровня root к хосту: правки `suricata.yaml` и запуск компонентов позволяют выполнить чужой код. Белый список в `dpistack-ctl` защищает от произвольных команд, но не от вредных правок конфигов. Взлом панели равен взлому хоста.
- Поэтому `ACCESS_MODE=localhost` по умолчанию, вход по паролю обязателен и не отключается. `lan` и `nginx` установщик включает только после явного подтверждения предупреждения.
- Сама панель отдаёт HTTP без TLS. Пароль и токен `/metrics` в `lan` видны в сети, поэтому установщик рекомендует `nginx` с TLS или SSH-туннель.
- `eve.json` содержит метаданные трафика (SNI, DNS-имена, адреса). Права: `0640`, группа доступа только у Suricata и пользователя `dpistack`.
- Персистентная команда `dpistack` (раздел 5.2) рассчитана на прямой запуск администратором от root: у неё нет белого списка, она ставит пакеты, меняет `dpistack.conf` и удаляет набор. Это не проблема безопасности сама по себе (эквивалент root-доступа к хосту уже есть у того, кто её запускает), но `dpistack` не должна вызываться сервисным пользователем `dpistack` или другим непривилегированным процессом — этим занимается только `dpistack-ctl`.

---

## 2. Стек и платформы

- Установщик, `dpistack-ctl`, `dpistack-watch`: Bash 4.4+, без Python и Perl. Внешние утилиты: `curl`, `jq`, `ss`, `ip`, `systemctl`, `sed`, `awk`, `tar`, `flock`. Установщик доставит недостающие пакеты на шаге `preflight`.
- Панель: Go 1.22+, только `net/http` из стандартной библиотеки. Единственная внешняя зависимость: `golang.org/x/crypto` (argon2id). Формат `/metrics` пишется вручную, без `client_golang`. Фронт: ванильные ES-модули и CSS, без сборщика, без фреймворков, без иконочных шрифтов.
- Тесты: `bats` для Bash, `go test` для панели.
- Проверки: `shellcheck`, `shfmt`, `gofmt`, `go vet`.
- Менеджеры пакетов: `apt` (Ubuntu, Debian), `dnf` (Fedora, RHEL и совместимые). Версии ОС: Ubuntu LTS 22.04+, Debian 11+, два последних релиза Fedora, RHEL-семейство 8+. Реальную поддержку версии определяет доступность выбранных источников; установщик проверяет её на `preflight` и выходит с понятной ошибкой.
- Архитектуры: `amd64`, `arm64`.
- Контейнеры: только Docker с плагином `compose`.

Без ORM, без БД у панели, без Node/npm в рантайме, без CSS-фреймворков.

---

## 3. Структура репозитория

```
install.sh                    точка входа: разбор аргументов, загрузка lib/, запуск шагов
dpistack.conf.example         пример конфига со всеми ключами
README.md  LICENSE  SECURITY.md
.github/
  workflows/ci.yml            гейт на каждый push и pull request (12.1)
  workflows/security.yml      gitleaks, security.sh, trivy (12.1)
  workflows/release.yml       сборка и публикация по тегу vX.Y.Z (12.1)
  dependabot.yml
docs/
  prototype.md                отчёт слайса 0
lib/
  paths.sh                    все пути системы из префикса DPISTACK_ROOT
  common.sh                   log, run (учитывает dry-run), die, lock, atomic_write, backup
  schema.sh                   таблица ключей: имя|тип|умолчание|варианты|уровень|затрагиваемые шаги|подсказка
  config.sh                   загрузка, проверка по schema, вопросы, сохранение, diff старого и нового
  menu.sh                     текстовое меню install и reconfigure (раздел 5.0)
  os.sh                       определение ОС, обёртки pkg_install/pkg_repo_add/pkg_pin
  state.sh                    состояние шагов и хэши отрендеренных файлов
  render.sh                   подстановка @@KEY@@ и блоков в templates/
  step_preflight.sh
  step_selfinstall.sh          копия install.sh, lib/, templates/ в систему и бинарник /usr/local/sbin/dpistack
  step_ndpi.sh
  step_suricata.sh
  step_rules.sh
  step_redis.sh
  step_ntopng.sh
  step_evebox.sh
  step_metrics.sh             VictoriaMetrics или Prometheus и настройка сбора
  step_access.sh              bind-режимы, nginx, firewall, SELinux
  step_panel.sh
  step_watch.sh
  step_verify.sh              итоговые тесты после установки
  runtime_native.sh           systemd
  runtime_docker.sh           compose
templates/
  suricata.yaml.tpl
  suricata-test.yaml.tpl      минимальный конфиг для офлайн-тестов
  evebox.yaml.tpl
  ntopng.conf.tpl
  nginx.conf.tpl
  compose.yaml.tpl
  scrape.yaml.tpl             конфиг сбора метрик для VictoriaMetrics и Prometheus
  logrotate.tpl
  sudoers.tpl
  *.service.tpl  *.timer.tpl
bin/
  dpistack-ctl                привилегированный помощник (раздел 4.5)
  dpistack-watch              watchdog (раздел 8)
panel/
  go.mod
  cmd/panel/main.go
  internal/{api,auth,ctl,eve,metrics,health}/
  web/                        index.html, app.css, app.js, modules/*.js
tests/
  data/bittorrent.pcap        handshake, документационные IP
  data/README.md              как записан pcap
  mocks/                      заглушки внешних команд для bats
  *.bats
scripts/
  gate.sh
  security.sh
  bundle.sh                   склейка в один файл dpistack-install.sh
```

Правила размещения:

- Пути к системным файлам строятся только в `lib/paths.sh` из префикса `DPISTACK_ROOT` (по умолчанию пустой). Тесты подставляют временный каталог. Прямых `/etc/...` в шагах нет.
- Шаг не вызывает системные команды напрямую, только через `run` из `common.sh` (dry-run и лог).
- Логика, зависящая от ОС, живёт в `os.sh`. Шаги вызывают `pkg_install`, а не `apt-get` или `dnf`.
- Логика, зависящая от способа развёртывания, живёт в `runtime_*.sh`. Шаги вызывают `rt_start`, `rt_stop`, `rt_exec`, а не `systemctl` или `docker` напрямую.
- Панель не запускает команды кроме `sudo -n dpistack-ctl <verb>`. Сама панель читает только `eve.json`, `health.json`, `events.jsonl`, `tests-last.json`, `metrics.json`, делает `stat` на `suricata.rules` и `statfs` на каталоги данных.

---

## 4. Контракты (заморожены)

### 4.1 Компоненты

| id | что это | runtime | unit / контейнер |
| --- | --- | --- | --- |
| `suricata` | движок IDS/IPS | native, docker | `suricata.service` |
| `evebox` | просмотр алертов | native, docker | `evebox.service` |
| `ntopng` | монитор трафика | native, docker | `ntopng.service` |
| `redis` | хранилище ntopng, всегда там же, где `ntopng` | как у `ntopng` | `redis.service` (rpm) или `redis-server.service` (deb), разрешает `os.sh` |
| `victoriametrics` | бэкенд метрик, только при `METRICS_BACKEND=victoriametrics` | native, docker | `dpistack-vm.service` |
| `prometheus` | бэкенд метрик, только при `METRICS_BACKEND=prometheus` | native, docker | `prometheus.service` |
| `panel` | личная панель | только native | `dpistack-panel.service` |
| `watch` | watchdog | только native | `dpistack-watch.timer` |
| `rules` | обновление правил | только native | `dpistack-rules.timer` |

`ndpi` компонентом не является: это библиотека, а плагин `ndpi.so` часть `suricata`. Его состояние показывает `dpistack-ctl status` отдельным полем `ndpi_plugin`.

### 4.2 Пути

| что | путь |
| --- | --- |
| конфиг установки | `/etc/dpistack/dpistack.conf` (0644 root) |
| черновик меню | `/etc/dpistack/dpistack.conf.draft` (0600 root) |
| секреты | `/etc/dpistack/secrets.conf` (0600 root) |
| хэш пароля панели | `/etc/dpistack/panel.auth` (0640 root:dpistack) |
| состояние | `/var/lib/dpistack/` (`state`, `health.json`, `events.jsonl`, `tests-last.json`, `metrics.json`, `backups/`, `staging/`, `scrape.yaml`) |
| блокировка | `/var/lock/dpistack.lock` |
| журнал установки | `/var/log/dpistack/install.log` |
| помощники | `/usr/local/sbin/dpistack` (персистентная команда, раздел 5.2), `/usr/local/sbin/dpistack-ctl`, `/usr/local/sbin/dpistack-watch`, библиотеки и шаблоны в `/usr/local/lib/dpistack/` (в т.ч. копия установщика в `/usr/local/lib/dpistack/installer/`) |
| панель | `/usr/local/bin/dpistack-panel` |
| Suricata | `/etc/suricata/suricata.yaml`, `/etc/suricata/{enable,disable,modify,drop}.conf`, `/etc/suricata/rules/local.rules`, `/var/lib/suricata/rules/suricata.rules`, `/var/log/suricata/eve.json` |
| сокет Suricata | `/run/suricata/suricata-command.socket` |
| EveBox | `/etc/evebox/evebox.yaml`, порт 5636 |
| ntopng | `/etc/ntopng/ntopng.conf`, порт 3000 |
| compose | `/opt/dpistack/compose/compose.yaml` |

Файл `state` кроме отметок шагов хранит снимок применённого конфига (`applied.<KEY>=<значение>`, пишется установщиком после каждого успешного применения) и счётчики watchdog (`watch.miss.<id>`, `watch.restarts.<id>`).

Системный пользователь `dpistack` (без входа) запускает панель и состоит в группе, которой доступен `eve.json` на чтение.

### 4.3 Ключи `dpistack.conf`

Формат `KEY=value`, по одному в строке, без кавычек и подстановок. Проверка строгая: неизвестный ключ или значение вне вариантов останавливает установщик. Значение, чья реализация ещё не сделана (`docker`, `ips`, `dnf`-дистрибутив, `METRICS_BACKEND` кроме `none`), отклоняется сообщением `пока не поддерживается`. Секреты живут только в `secrets.conf`. Таблица зеркалит `lib/schema.sh`.

| ключ | по умолчанию | варианты / формат |
| --- | --- | --- |
| `SURICATA_RUNTIME` | `native` | `native` `docker` |
| `EVEBOX_RUNTIME` | `native` | `native` `docker` |
| `NTOPNG_RUNTIME` | `native` | `native` `docker` |
| `SURICATA_SOURCE` | `source` | `distro` `oisf` `source` |
| `SURICATA_VERSION` | пусто | пусто = последняя доступная в источнике |
| `NDPI_ENABLE` | `yes` | `yes` `no`; `yes` требует плагин `ndpi.so` |
| `NDPI_SOURCE` | `source` | `pkg` `source` |
| `NDPI_VERSION` | пусто | пусто = версия, совместимая с выбранной Suricata |
| `NTOPNG_VERSION` | пусто | пусто = последняя |
| `EVEBOX_VERSION` | пусто | пусто = последняя |
| `PIN_VERSIONS` | `no` | `yes` `no`; `yes` = `apt-mark hold` / `dnf versionlock` |
| `SURICATA_MODE` | `ids` | `ids` `ips` |
| `IFACES` | `enp2s0` | имена через запятую |
| `BPF_FILTER` | пусто | выражение BPF |
| `HOME_NET` | авто | список CIDR; авто = частные диапазоны RFC 1918 |
| `IPS_METHOD` | `nfq` | `nfq` `afpacket` |
| `IPS_NFQ_CHAINS` | `INPUT,OUTPUT,FORWARD` | подмножество этих цепочек |
| `EVE_FILE` | `yes` | `yes` `no`; `no` отключает EVE-просмотр, проверку свежести и eve-метрики |
| `EVE_TYPES` | `alert,flow,dns,tls,http,stats` | из `alert,anomaly,dns,http,tls,files,flow,netflow,ssh,smb,stats,drop` |
| `EVE_SYSLOG` | `no` | `yes` `no` |
| `EVE_REDIS` | пусто | `host:port` или пусто |
| `EVE_ROTATE` | `daily` | `daily` `weekly` `size` |
| `EVE_KEEP` | `14` | число ротаций |
| `EVE_MAX_SIZE_MB` | пусто | число, нужен при `EVE_ROTATE=size` |
| `STATS_INTERVAL_SEC` | `30` | 5..300 |
| `RULES_SOURCES` | `et/open` | имена источников `suricata-update` через запятую |
| `RULES_URLS` | пусто | свои URL через запятую |
| `RULES_GROUPS` | `emerging-p2p,emerging-policy` | группы правил, включаемые в `enable.conf` |
| `RULES_UPDATE` | `on` | `on` `off` |
| `RULES_UPDATE_CALENDAR` | `weekly` | синтаксис `OnCalendar` systemd |
| `NTOPNG_IFACES` | как `IFACES` | имена через запятую |
| `NTOPNG_PORT` | `3000` | 1..65535 |
| `EVEBOX_DB` | `sqlite` | `sqlite` `elasticsearch` |
| `EVEBOX_ES_URL` | пусто | URL, нужен при `elasticsearch` |
| `EVEBOX_PORT` | `5636` | 1..65535 |
| `EVEBOX_RETENTION_DAYS` | `30` | число дней, `0` = без ограничения; механизм по допущению A9 |
| `ACCESS_MODE` | `localhost` | `localhost` `lan` `nginx` |
| `LAN_CIDR` | авто | CIDR сети интерфейса по умолчанию |
| `PANEL_PORT` | `9800` | 1..65535 |
| `PANEL_SOURCE` | `build` | `build` (нужен Go) или `prebuilt` (готовый бинарник рядом с установщиком) |
| `NGINX_MANAGE` | `snippet` | `yes` (правит и перезагружает системный nginx) или `snippet` (только пишет файл и печатает команду) |
| `NGINX_TLS` | `none` | `none` `selfsigned` `existing` |
| `NGINX_CERT` `NGINX_KEY` | пусто | пути, нужны при `existing` |
| `FIREWALL_MANAGE` | `no` | `no` `auto` (ufw или firewalld, только разрешить `LAN_CIDR`) |
| `METRICS_EXPORT` | `yes` | `yes` `no`; включает `GET /metrics` панели |
| `METRICS_BACKEND` | `none` | `none` `victoriametrics` `prometheus`; `none` = только эндпоинт, сбор настраивает пользователь |
| `METRICS_BACKEND_RUNTIME` | `native` | `native` `docker` |
| `METRICS_BACKEND_PORT` | пусто | пусто = 8428 (VictoriaMetrics) или 9090 (Prometheus) |
| `METRICS_RETENTION` | `30d` | число и суффикс `d` |
| `WATCH_ENABLE` | `yes` | `yes` `no` |
| `WATCH_INTERVAL_SEC` | `60` | 10..3600 |
| `WATCH_EVE_STALE_SEC` | `300` | секунды без новых событий до `crit` |
| `WATCH_DROP_WARN_PCT` `WATCH_DROP_CRIT_PCT` | `1` `5` | проценты |
| `WATCH_DISK_WARN_PCT` `WATCH_DISK_CRIT_PCT` | `15` `5` | свободного места, проценты |
| `WATCH_RULES_WARN_DAYS` `WATCH_RULES_CRIT_DAYS` | `10` `30` | возраст правил |
| `WATCH_REPEAT_MIN` | `60` | повтор оповещения, пока статус не `ok` |
| `WATCH_AUTORESTART` | `no` | `yes` `no`; `yes` = не более 3 рестартов в час на компонент |
| `ALERT_CHANNELS` | `panel,log` | подмножество `panel,log,tg,mail` |
| `ALERT_TG_CHAT_ID` | пусто | нужен при `tg` |
| `ALERT_MAIL_TO` `ALERT_MAIL_FROM` | пусто | адреса, нужны при `mail` |
| `TEST_HTTPS_URL` | `https://example.com` | URL для живого HTTPS-теста |
| `TEST_BT_LIVE` | `no` | `yes` подаёт pcap в живой интерфейс через `tcpreplay` |
| `TEST_ON_INSTALL` | `yes` | `yes` `no` |
| секрет `ALERT_TG_TOKEN` | пусто | токен бота |
| секрет `ALERT_SMTP_URL` | пусто | `smtp://user:pass@host:587` |
| секрет `METRICS_TOKEN` | генерируется | 32 случайных байта в hex, создаётся при `METRICS_EXPORT=yes` |

Проверки при загрузке (перекрёстные):

- `NDPI_ENABLE=yes` при `SURICATA_SOURCE` из `distro`/`oisf` допустим, только если после установки найден файл `ndpi.so`; иначе установщик предлагает `SURICATA_SOURCE=source` (интерактивно) или останавливается с кодом 2 (неинтерактивно).
- `EVE_TYPES` без `stats` при `WATCH_ENABLE=yes` даёт предупреждение: проверки `eve_fresh` и `drop_rate` получат статус `na`.
- `METRICS_BACKEND` не `none` при `METRICS_EXPORT=no` отклоняется: бэкенду нечего собирать.
- `EVEBOX_DB=elasticsearch` без `EVEBOX_ES_URL` отклоняется.
- `ACCESS_MODE` не `localhost` требует подтверждения предупреждения из раздела 1 (в неинтерактивном режиме подтверждением служит `--set ACCESS_CONFIRM=yes`, ключ не сохраняется).

Свободные ключи (тип `free`) проверяются шаблонами из `SCHEMA_PATTERN` в `lib/schema.sh`. Их значения попадают в YAML, nginx и systemd, в аргументы `curl` и `suricata-update`, и всё это выполняет или читает root, а `dpistack-ctl config-write` позволяет менять их из панели. Значение вне формата отвергается до записи куда-либо: без кавычек, обратной косой, `$`, обратных кавычек, `;`, фигурных скобок и без ведущего `-`, который команда прочла бы как опцию. Формат ключей: `IFACES` и `NTOPNG_IFACES` имена интерфейсов через запятую; `LAN_CIDR` `auto` или `адрес/длина`; `HOME_NET` `auto` или список CIDR; `TEST_HTTPS_URL` и `EVEBOX_ES_URL` URL `http://` или `https://`; `ALERT_SMTP_URL` URL `smtp://` или `smtps://`; `NGINX_CERT` и `NGINX_KEY` абсолютный путь; `*_VERSION` буквы, цифры и `. ~ + : _ -`; остальные описаны в коде рядом с шаблоном. Отвергнутое значение секретного ключа в сообщении об ошибке не печатается.

`NTOPNG_VERSION` и `EVEBOX_VERSION` фиксируют версию пакета при установке (`пакет=версия` для apt, `пакет-версия` для dnf). Смена версии у уже установленного пакета его не переустанавливает.

### 4.4 CLI установщика и персистентной команды `dpistack`

`install.sh` (запуск из клона или архива, до установки) и `dpistack` (персистентная команда, доступна после установки — раздел 5.2) принимают один и тот же синтаксис:

```
install.sh <команда> [опции]
dpistack [команда] [опции]

команды:  install | reconfigure | upgrade | uninstall | status | test | logs
опции:    --config FILE          путь к dpistack.conf (по умолчанию /etc/dpistack/dpistack.conf)
          --set KEY=VALUE        переопределить ключ, можно повторять
          --non-interactive, -y  без вопросов; недостающее берётся из умолчаний
          --advanced             спрашивать все ключи, а не только уровень basic
          --dry-run              показать план, ничего не менять
          --only STEP[,STEP]     выполнить только указанные шаги
          --skip STEP[,STEP]     пропустить шаги
          --force                перезаписать вручную изменённые файлы (с бэкапом)
          --purge                для uninstall: удалить также данные и конфиги
          --no-color             без ANSI-цветов в меню и выводе
```

Без `--non-interactive` и на терминале (или с переменной `DPISTACK_INPUT`) команда `install`, `reconfigure` или сам `dpistack` без аргументов открывают текстовое меню вместо вопросов подряд — раздел 5.0. `--set` и `--config` при этом действуют как предзаполненные значения, которые меню показывает и позволяет поменять. Разница между `install.sh` и `dpistack` только в состоянии по умолчанию: `install.sh` без аргументов и без установленного конфига всегда предлагает установку; `dpistack` без аргументов при уже установленном конфиге открывает меню управления, а не меню установки (раздел 5.2).

`test` и `logs <id>` — тонкие обёртки над `dpistack-ctl test` и `dpistack-ctl logs`, доступны только у `dpistack` (не у `install.sh`, пока набор не установлен — обращаться нечему).

`status` печатает по каждому шагу результат `check`: `в порядке` или `расхождение` с причиной. Ничего не меняет.

Код возврата: `0` успех, `1` ошибка шага, `2` неверные аргументы или конфиг, `3` preflight не пройден или изменение не поддерживается в этом режиме.

### 4.5 `dpistack-ctl`

Единственная точка привилегированных действий панели и watchdog. Работает от root через `sudo -n`, правило в `/etc/sudoers.d/dpistack` разрешает пользователю `dpistack` только этот файл. Все аргументы сверяются со списками ниже до любого действия. Метасимволы shell в аргументах отклоняются.

| команда | что делает |
| --- | --- |
| `status [--json]` | по каждому компоненту: `id`, `runtime`, `state` (`active` `inactive` `failed` `absent`), `enabled`, `version`; плюс `ndpi_plugin` (`loaded` `absent`) |
| `start\|stop\|restart <id>` | управляет компонентом через его runtime; `<id>` только из 4.1 |
| `reload suricata` | перечитывает правила без остановки (`ruleset-reload-nonblocking`) |
| `logs <id> [-n N] [--follow]` | журнал компонента, `N` до 1000 |
| `config-read <name>` | печатает текущий файл |
| `config-write <name> [--apply]` | читает stdin, кладёт в `staging/`, проверяет, делает бэкап, атомарно заменяет; `--apply` затем перезагружает компонент, а для `dpistack.conf` выполняет `reconfigure` |
| `config-revert <name>` | возвращает последний бэкап |
| `reconfigure [--dry-run]` | применяет текущий `dpistack.conf` без вопросов: определяет затронутые шаги (раздел 5.3), перерисовывает конфиги и перезапускает компоненты. Не ставит пакеты и не собирает: при изменении «тяжёлых» ключей отказывает с кодом 3 и просит `install.sh reconfigure` |
| `rules-update` | `suricata-update`, проверка `suricata -T`, перезагрузка; при ошибке откат набора |
| `rules-sources list\|enable\|disable\|add-url\|remove <arg>` | источники правил |
| `rules-group enable\|disable <group>` | правит `enable.conf` |
| `rules-sid enable\|disable <sid>` | правит `disable.conf`, `sid` только число |
| `rules-search <q>` | до 50 правил по `sid` или тексту `msg` |
| `iface list\|add\|remove <name>` | правит `IFACES`, вызывает `reconfigure` |
| `mode ids\|ips [--confirm-timeout SEC]` | переключает режим; для `ips` откатывается сам, если за `SEC` (по умолчанию 120) не пришёл `mode-confirm` |
| `mode-confirm` | подтверждает переключение в IPS |
| `test bittorrent\|https\|all [--json]` | раздел 10 |
| `health [--json]` | один прогон watchdog |
| `panel-passwd` | читает пароль со stdin, пишет argon2id-хэш в `panel.auth` |
| `version` | версия набора |

Аргументы: допустимы буквы, цифры и `. _ : = / @ + , -` и пробел (`rules-search` принимает фразу); всё остальное, включая `; | & $ ( ) < > \` кавычки и перевод строки, даёт код `5` до любого действия. URL с `?`, `&`, `%` поэтому в `rules-sources add-url` не проходит.

`logs -n N`: `N` от 1 до 1000, ведущие нули это десятичная запись (`08` равно 8, `01750` отвергается как 1750). `config-write dpistack.conf` отвергает секретные ключи (`ALERT_TG_TOKEN`, `ALERT_SMTP_URL`, `METRICS_TOKEN`): секреты живут только в `secrets.conf`. Запись и откат конфигов берут блокировку установщика (ждут до 30 секунд), чтобы файл не менялся, пока `install.sh` рендерит по нему.

`config-write --apply`: `dpistack.conf` выполняет `reconfigure`; `suricata.yaml` перезапускает `suricata`; `evebox.yaml` и `ntopng.conf` перезапускают свой компонент; `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf` выполняют `rules-update`. Файл, записанный через `ctl`, установщик считает изменённым вручную (5.4): `config-write` не обновляет хэш последнего рендера.

`reconfigure` сравнивает `dpistack.conf` со снимком `applied.<KEY>` в `state`, а не с самим файлом, потому что `config-write` уже заменил файл. `ACCESS_CONFIRM=yes` подставляется только пока `ACCESS_MODE` равен применённому; смена режима доступа идёт через `install.sh reconfigure`. Тяжёлое изменение даёт код `3` и сообщение со словами `install.sh reconfigure`.

`iface add|remove` пишет `IFACES` в `dpistack.conf` (с бэкапом) и вызывает `reconfigure`; при неудаче файл возвращается из бэкапа. Имя для `add` должно существовать в системе, иначе `5`; последний интерфейс удалить нельзя (`3`).

`rules-sources list` печатает `suricata-update list-sources`; `add-url` называет источник `dpistack-custom-<8 символов sha256 от URL>`. `rules-group enable|disable` добавляет и убирает строку `group:<имя>.rules` в `enable.conf`, `rules-sid` строку `<sid>` в `disable.conf`; `RULES_GROUPS` в `dpistack.conf` они не меняют.

`panel-passwd` вызывает CLI `argon2` (пакет `argon2`, ставит установщик): `-id -t 3 -m 16 -p 4 -l 32 -e`, соль 16 случайных байт. Пароль идёт на stdin, не в аргументы. В `panel.auth` пишется строка `$argon2id$...`, права `0640`, группа `dpistack`; пока пользователя нет (первая установка), группа выставляется шагом `panel`. Тот же код пишет пароль при установке из меню.

Допустимые `<name>` для конфигов: `suricata.yaml`, `evebox.yaml`, `ntopng.conf`, `dpistack.conf`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf`.

Проверки при `config-write`: `suricata.yaml`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf` проходят `suricata -T` на временной копии набора; `dpistack.conf` проходит проверку схемы из 4.3; `evebox.yaml` и `ntopng.conf` проверяются только на непустоту: режима проверки конфига у EveBox и ntopng нет (допущение A8 закрыто). Для `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf` `suricata -T` проверяет, что набор остаётся рабочим, но сами эти файлы читает только `suricata-update`. Провал проверки: ничего не меняется, код `3`, вывод проверки идёт в stdout.

Коды возврата: `0` успех, `1` ошибка, `2` неверное использование, `3` проверка не пройдена или действие недоступно в этом режиме, `4` компонент отсутствует, `5` имя вне списка.

### 4.6 `health.json` и события

`/var/lib/dpistack/health.json`, перезаписывается атомарно каждый прогон watchdog:

```json
{
  "ts": "2026-09-24T12:00:00Z",
  "overall": "ok",
  "checks": [
    { "id": "suricata.process", "status": "ok", "value": "active", "detail": "", "since": "2026-09-24T09:00:00Z" }
  ]
}
```

`status` только `ok`, `warn`, `crit`, `na`. `overall` берёт худший статус, `na` не считается. `since` меняется только при смене статуса.

Идентификаторы проверок: `<id>.process` и `<id>.port` для `suricata` (порта нет, только процесс), `evebox`, `ntopng`, `redis`, `panel`, а при установленном бэкенде метрик ещё `victoriametrics` или `prometheus`; `suricata.eve_fresh`, `suricata.drop_rate`, `disk.free`, `rules.age`.

`/var/lib/dpistack/events.jsonl`: по строке на смену статуса проверки, канал `panel`:

```json
{"ts":"...","check":"suricata.drop_rate","from":"ok","to":"warn","detail":"drops 2.4%"}
```

`/var/lib/dpistack/tests-last.json`, последний результат каждого теста раздела 10. Прогон одного теста не стирает результат другого:

```json
{"results":[
{"name":"bittorrent","status":"pass","detail":"сигнатура: ET P2P BitTorrent DHT ping request","duration_ms":812,"timestamp":"2026-10-08T12:00:00Z"}
]}
```

Один объект на строку, чтобы файл можно было объединять без `jq`. `status` из `pass`, `fail`, `skip`. Права `0644`.

Правило порогов для `health.json` и `ctl health`: значение ровно на пороге даёт худший из двух статусов (`drop_rate` 1 % при `WARN=1` это `warn`, свободного места ровно `WARN` это `warn`, возраст `WATCH_EVE_STALE_SEC` это `crit`). Сравнение идёт точной арифметикой без округления. Событие в `events.jsonl` пишется при смене статуса; первое появление проверки со статусом `ok` или `na` событием не считается.

### 4.7 EVE: поля, на которые опираются панель и тесты

| поле | где | зачем |
| --- | --- | --- |
| `timestamp`, `event_type`, `in_iface`, `src_ip`, `dest_ip`, `proto` | все события | лента событий, фильтры |
| `alert.signature`, `alert.signature_id`, `alert.severity`, `alert.category` | `alert` | лента, тест BitTorrent |
| `tls.sni` | `tls` | тест HTTPS |
| `alert.metadata` | `alert` | nDPI-детект, если правило `ndpi-protocol` или `ndpi-risk` задаёт `metadata` |
| `stats.capture.kernel_packets`, `stats.capture.kernel_drops` | `stats` | drop rate, график пакетов, метрики |
| `stats.uptime` | `stats` | метрики |

Отдельных полей `ndpi.*` в EVE нет: смерженный плагин nDPI даёт только ключевые слова правил `ndpi-protocol` и `ndpi-risk`, результат виден через `alert.signature` и `alert.metadata` (допущение A2 закрыто).

Drop rate за интервал: `Δkernel_drops / Δkernel_packets × 100`. Счётчики накопительные, сброс (значение меньше прежнего) пропускает интервал.

### 4.8 HTTP API панели

Все ответы JSON, ошибка: `{"error":"текст"}` с кодом 4xx/5xx. Все методы кроме `POST /api/login` и `GET /metrics` требуют сессию. Изменяющие методы требуют заголовок `X-CSRF-Token`.

| метод и путь | что делает |
| --- | --- |
| `POST /api/login`, `POST /api/logout` | сессия в cookie `HttpOnly; SameSite=Strict` |
| `GET /api/status` | компоненты (`ctl status`) + `health.json` |
| `POST /api/components/{id}/{start\|stop\|restart}` | через `ctl` |
| `POST /api/suricata/reload` | `ctl reload suricata` |
| `GET /api/config/{name}` | текст файла |
| `PUT /api/config/{name}?apply=0\|1` | `ctl config-write`; ответ `{ok, output}` |
| `POST /api/config/{name}/revert` | `ctl config-revert` |
| `GET /api/rules/sources`, `POST /api/rules/sources` | список и изменение источников |
| `POST /api/rules/update` | `ctl rules-update` |
| `GET /api/rules/search?q=` | поиск |
| `POST /api/rules/groups/{group}/{enable\|disable}` | группы |
| `POST /api/rules/sid/{sid}/{enable\|disable}` | отдельное правило |
| `GET /api/logs/{id}?lines=N` | последние строки |
| `GET /api/logs/{id}/stream` | SSE, живой хвост |
| `GET /api/eve?type=&q=&since=&limit=` | события из `eve.json`, `limit` до 500 |
| `GET /api/eve/stream?type=` | SSE, новые события |
| `GET /api/metrics?range=1h\|6h\|24h` | ряды для графиков: pps, drops, cpu, rss, размер `eve.json`, диск |
| `POST /api/tests/{bittorrent\|https\|all}` | запуск, ответ как у `ctl test --json` |
| `GET /api/tests/last` | последний результат |
| `GET /api/alerts?limit=` | строки `events.jsonl`, новые сверху |
| `POST /api/iface/{add\|remove}` | `ctl iface` |
| `POST /api/mode/{ids\|ips}`, `POST /api/mode/confirm` | режим |
| `GET /metrics` | экспорт Prometheus (раздел 4.9) |

Панель отвечает 403, если IP клиента вне `LAN_CIDR` (при `ACCESS_MODE=lan`) или вне `127.0.0.1` (при `localhost`). При `nginx` доверяет `X-Forwarded-For` только от `127.0.0.1`.

### 4.9 Экспорт метрик `GET /metrics`

Формат Prometheus text exposition 0.0.4, `Content-Type: text/plain; version=0.0.4`. Доступ: заголовок `Authorization: Bearer <METRICS_TOKEN>`, сессия не нужна. Ограничение по IP из 4.8 действует. При `METRICS_EXPORT=no` ответ 404, без токена или с неверным токеном 401.

| метрика | тип | метки | источник |
| --- | --- | --- | --- |
| `dpistack_component_up` | gauge | `component` | `health.json`, `<id>.process`: 1 при `active`, иначе 0 |
| `dpistack_check_status` | gauge | `check` | `health.json`: `ok`=0, `warn`=1, `crit`=2; `na` не выдаётся |
| `dpistack_suricata_kernel_packets_total` | counter |  | `stats.capture.kernel_packets` |
| `dpistack_suricata_kernel_drops_total` | counter |  | `stats.capture.kernel_drops` |
| `dpistack_suricata_drop_ratio` | gauge |  | доля 0..1 за последний интервал `stats`, см. 4.7 |
| `dpistack_suricata_uptime_seconds` | gauge |  | `stats.uptime` |
| `dpistack_eve_events_total` | counter | `event_type` | события, прочитанные панелью с её старта |
| `dpistack_eve_size_bytes` | gauge |  | размер `eve.json` |
| `dpistack_eve_last_event_age_seconds` | gauge |  | возраст последнего события |
| `dpistack_disk_free_ratio` | gauge | `path` | `statfs` на каталогах данных (лог Suricata, данные EveBox, данные бэкенда метрик) |
| `dpistack_rules_age_seconds` | gauge |  | возраст `suricata.rules` |
| `dpistack_test_status` | gauge | `test` | последний результат: 1 `pass`, 0 `fail`; `skip` не выдаётся |
| `dpistack_test_timestamp_seconds` | gauge | `test` | время последнего прогона |
| `dpistack_panel_rss_bytes` | gauge |  | RSS панели |

Метрики `eve` и `suricata_*` не выдаются при `EVE_FILE=no` или без `stats` в `EVE_TYPES`.

---

## 5. Установщик: правила и сценарии

**Шаг** это пара функций `step_<имя>_check` (код 0, если состояние уже соответствует конфигу) и `step_<имя>_apply`, плюс `step_<имя>_plan` (одна строка для dry-run). Порядок шагов: `preflight`, `selfinstall`, `ndpi`, `suricata`, `rules`, `redis`, `ntopng`, `evebox`, `metrics`, `access`, `panel`, `watch`, `verify`.

Шаг `selfinstall` копирует `install.sh`, `lib/*.sh` и `templates/*` в `/usr/local/lib/dpistack/installer/` и кладёт исполняемый `install.sh` из этой копии в `/usr/local/sbin/dpistack`. После этого шага команда `dpistack` работает без исходного клона или архива репозитория — раздел 5.2. Идемпотентен по хэшу скопированных файлов, как остальные шаги (5.4).

### 5.0 Меню установщика: общие правила

- Меню открывают команды `install` и `reconfigure`, а также бинарник `dpistack` без аргументов, когда есть терминал и не указан `-y`. Реализация на чистом Bash в `lib/menu.sh`: без `dialog`, `whiptail`, ncurses и курсорных последовательностей. Экран печатается заново после каждого действия, поэтому меню работает через SSH и `tmux` и остаётся в истории терминала.
- Ввод читается из stdin, при запуске через `curl | bash` из `/dev/tty`. Переменная `DPISTACK_INPUT=<файл>` подменяет источник (так работают тесты). Нет терминала, `DPISTACK_INPUT` и `-y`: код 2 и подсказка про `-y`.
- Цвета включаются только на терминале и без `NO_COLOR` и `--no-color`.
- Навигация: пункт выбирается номером или буквой; `0` или пустой ввод возвращает на уровень выше; `?` показывает справку экрана; `q` выходит.
- Экран раздела конфига: ключи списком `N) KEY = значение`. Маркеры: `*` значение отличается от умолчания, `~` (только в «Настроить» существующей установки) отличается от применённого, `!` ключ с ошибкой. Пункт `a` включает и выключает показ ключей уровня advanced (с `--advanced` они видны сразу).
- Правка ключа: номер ключа, затем вопрос с подсказкой, вариантами и умолчанием. Ключ с фиксированными вариантами выбирается номером из списка, остальные вводятся текстом. Enter оставляет значение, `-` сбрасывает к умолчанию, `?` показывает подсказку. Значение проверяется по схеме сразу: неверное отклоняется с перечнем допустимых, прежнее остаётся.
- Экран разделов конфига всегда показывает сводку проблем (схема и перекрёстные проверки из 4.3) и не даёт выбрать «Установить» или «Применить», пока они есть.
- Секреты вводятся без эха. В экранах, сводке и diff показывается `задан` или `не задан`.
- Правки сохраняются в `/etc/dpistack/dpistack.conf.draft` (0600 root) после каждого изменения. Секреты в черновик не пишутся. Обрыв сессии не теряет ввод: при следующем запуске меню предлагает продолжить черновик. `dpistack.conf` меняется только при применении.
- `q` при неприменённых правках просит подтверждение. `Ctrl+C` завершает работу, ничего не меняя в системе и не оставляя частично записанных файлов (`trap`, временные файлы удаляются).
- Ключи уровня basic: `SURICATA_RUNTIME`, `EVEBOX_RUNTIME`, `NTOPNG_RUNTIME`, `SURICATA_SOURCE`, `NDPI_ENABLE`, `IFACES`, `EVE_TYPES`, `ACCESS_MODE`, `ALERT_CHANNELS`, `METRICS_BACKEND`, `PIN_VERSIONS`. Остальные ключи уровня advanced.

Разделы экрана конфига (колонка «группа» это колонка `lib/schema.sh`; каждый ключ входит ровно в одну группу):

| группа | пункт меню | ключи |
| --- | --- | --- |
| `capture` | Захват и режим | `IFACES`, `BPF_FILTER`, `HOME_NET`, `SURICATA_MODE`, `IPS_METHOD`, `IPS_NFQ_CHAINS`, `NTOPNG_IFACES` |
| `components` | Компоненты и источники | `SURICATA_RUNTIME`, `EVEBOX_RUNTIME`, `NTOPNG_RUNTIME`, `SURICATA_SOURCE`, `SURICATA_VERSION`, `NDPI_ENABLE`, `NDPI_SOURCE`, `NDPI_VERSION`, `NTOPNG_VERSION`, `EVEBOX_VERSION`, `PIN_VERSIONS`, `PANEL_SOURCE` |
| `eve` | EVE и хранение | `EVE_FILE`, `EVE_TYPES`, `EVE_SYSLOG`, `EVE_REDIS`, `EVE_ROTATE`, `EVE_KEEP`, `EVE_MAX_SIZE_MB`, `STATS_INTERVAL_SEC`, `EVEBOX_DB`, `EVEBOX_ES_URL`, `EVEBOX_RETENTION_DAYS` |
| `rules` | Правила | `RULES_SOURCES`, `RULES_URLS`, `RULES_GROUPS`, `RULES_UPDATE`, `RULES_UPDATE_CALENDAR` |
| `access` | Доступ | `ACCESS_MODE`, `LAN_CIDR`, `PANEL_PORT`, `NTOPNG_PORT`, `EVEBOX_PORT`, `NGINX_MANAGE`, `NGINX_TLS`, `NGINX_CERT`, `NGINX_KEY`, `FIREWALL_MANAGE` |
| `metrics` | Метрики | `METRICS_EXPORT`, `METRICS_BACKEND`, `METRICS_BACKEND_RUNTIME`, `METRICS_BACKEND_PORT`, `METRICS_RETENTION` |
| `watch` | Наблюдение и оповещения | `WATCH_ENABLE`, все `WATCH_*`, `ALERT_CHANNELS`, `ALERT_TG_CHAT_ID`, `ALERT_TG_TOKEN`, `ALERT_MAIL_TO`, `ALERT_MAIL_FROM`, `ALERT_SMTP_URL` |
| `tests` | Тесты | `TEST_HTTPS_URL`, `TEST_BT_LIVE`, `TEST_ON_INSTALL` |
| действие | Пароль панели | не ключ конфига, хранится только как хэш |

`METRICS_TOKEN` генерируется установщиком и в меню не редактируется.

### 5.1 `install.sh install` / `dpistack install`, что происходит

Явная команда `install` (в отличие от бинарника `dpistack`, вызванного без аргументов, — раздел 5.2) всегда ведёт по описанному здесь пути установки, даже если `dpistack.conf` уже есть.

**Запуск.** Берётся блокировка `flock` на `/var/lock/dpistack.lock` (второй экземпляр выходит с кодом 1), открывается `install.log`. Установщик определяет систему: дистрибутив, архитектуру, наличие `systemd` и Docker. Затем:

- если `dpistack.conf` уже есть, открывается экран «Найдена установка»: `1) настроить (перейти в «Настроить», раздел 5.3)`, `2) применить текущий конфиг заново` (идемпотентно, без вопросов), `3) открыть меню управления (раздел 5.2)`, `4) выйти`. Молча перезаписывать существующую установку нельзя;
- если есть черновик, предлагается `Продолжить черновик? [Y/n]`;
- иначе (свежая установка) открывается главное меню установки.

**Главное меню установки** (пример, справа краткая сводка значений):

```
dpistack 2.0  |  Ubuntu 24.04, amd64  |  systemd: да  |  docker: нет
Установка. Конфиг: /etc/dpistack/dpistack.conf (не создан)

  1) Быстрая установка
  2) Захват и режим                IDS, enp2s0
  3) Компоненты и источники        Suricata: source, nDPI: да
  4) EVE и хранение                6 типов, ротация daily
  5) Правила                       ET Open, раз в неделю
  6) Доступ                        localhost
  7) Метрики                       экспорт: да, бэкенд: нет
  8) Наблюдение и оповещения       panel, log
  9) Тесты                         после установки: да
 10) Пароль панели                 не задан

  c) Проверить систему    p) План    s) Сохранить конфиг в файл    l) Загрузить из файла
  i) Установить           q) Выйти

Проблемы (1): не задан пароль панели
>
```

Пункты:

- **1, Быстрая установка.** Короткий опрос: интерфейсы (список найденных `ip -o link` без `lo`, интерфейс с маршрутом по умолчанию помечен, выбор номерами через запятую), способ Suricata (`source` даёт nDPI, `oisf` и `distro` ставятся быстрее, но без плагина nDPI), режим доступа, пароль панели. Остальное по умолчанию. Установка сама не стартует: меню возвращается в главное, чтобы можно было проверить сводку.
- **2–9, разделы.** Экран раздела по правилам 5.0.
- **10, Пароль панели.** Ввод дважды без эха, пустой пароль отклоняется. Хэш пишется на этапе применения.
- **c, Проверить систему.** Preflight (5.5) без изменений системы, результат списком.
- **p, План.** `check` каждого шага и таблица `нужно применить / без изменений`. Ничего не меняет.
- **s, l.** Сохранить текущие значения в файл и загрузить из файла. Загрузка проверяется схемой, ошибки показываются списком, загруженные значения становятся правками.
- **i, Установить.** Запускает последовательность ниже.

**Что происходит после `i`** (и сразу при `-y`, без меню):

1. **Слои значений.** Поздний перекрывает ранний: умолчания из `schema.sh` → существующий `dpistack.conf` → `secrets.conf` и переменные окружения для секретов → `--config` → `--set` → правки из меню.
2. **Проверка конфига.** Схема (тип, варианты) и перекрёстные правила из 4.3. Все ошибки печатаются списком, код 2 (в меню возврат в главное меню). Для `ACCESS_MODE` не `localhost` показывается предупреждение из раздела 1 и требуется подтверждение.
3. **Сводка и подтверждение.** Печатается итоговый конфиг (секреты скрыты) и `Установить? [y/N]` (при `-y` вопроса нет). Затем записываются `dpistack.conf` (0644) и `secrets.conf` (0600), черновик удаляется.
4. **Preflight.** Все проверки из 5.5 выполняются целиком, ошибки печатаются списком, код 3. До этого момента система не менялась.
5. **План.** Для каждого шага вызывается `check`, печатается таблица и строки `plan`. При `--dry-run` работа заканчивается здесь, код 0, `dpistack.conf` не пишется.
6. **Применение** по порядку шагов (включая `selfinstall`, см. врезку в начале раздела 5). На экране одна строка на шаг: `[3/13] suricata ... готово`, `без изменений` или `ошибка`; подробности в `install.log`. На каждом шаге: `apply`, затем повторный `check` (постусловие) и запись результата в `state`. Отрендеренные файлы хранят хэш; изменённые руками не перезаписываются без `--force`. Ошибка шага останавливает установку: печатается имя шага, причина и команда продолжения `install.sh install --only <шаг>`. Уже применённые шаги остаются, установленные пакеты не удаляются, файлы, изменённые упавшим шагом в этом запуске, восстанавливаются из `backups/`.
7. **Проверка.** Шаг `verify` запускает `ctl test all` при `TEST_ON_INSTALL=yes`. Провал теста не отменяет установку и попадает в отчёт.
8. **Итоговый отчёт.** Адреса интерфейсов по `ACCESS_MODE` (панель, EveBox, ntopng, бэкенд метрик), результат тестов, где лежат конфиги и логи, команда `dpistack` для дальнейшего управления (раздел 5.2), токен `/metrics` и готовая строка `scrape_config`, сгенерированный пароль панели (только если он создавался, показывается один раз), предупреждения (топология, SELinux, пароль по HTTP в `lan`).

Пароль панели: в меню вводится вручную и без него «Установить» недоступно. При `-y` берётся из `DPISTACK_PANEL_PASSWORD`, а если переменной нет, генерируется случайный (24 символа) и печатается один раз в отчёте. В открытом виде нигде не хранится. Меняется пунктом меню управления «Пароль панели» (5.2) или командой `ctl panel-passwd`.

### 5.2 Персистентная команда `dpistack` и меню управления

После установки на системе есть исполняемый `/usr/local/sbin/dpistack` (шаг `selfinstall`) — тот же код, что и `install.sh`, скопированный вместе с `lib/` и `templates/` в `/usr/local/lib/dpistack/installer/`, поэтому команда работает без исходного клона или архива. `dpistack` рассчитан на прямой запуск администратором от root, в отличие от `dpistack-ctl` (4.5), который вызывается только через `sudo -n` из панели и watchdog по узкому списку команд.

**Что показывает `dpistack` без аргументов** зависит от состояния:

- `dpistack.conf` нет → главное меню установки, раздел 5.1 (тот же путь, что у `install.sh install` на свежей системе).
- `dpistack.conf` есть → **меню управления**:

```
dpistack 2.0  |  Управление установленным стендом
Конфиг: /etc/dpistack/dpistack.conf  |  компоненты: 6 из 6 активны  |  health: ok

  1) Настроить                     разделы конфига, diff, применение
  2) Статус компонентов
  3) Логи
  4) Запустить тесты
  5) Обновить пакеты (upgrade)
  6) Удалить (uninstall)
  7) Пароль панели

  q) Выйти
>
```

Пункты:

- **1, Настроить.** Открывает экран разделов конфига с diff и применением — раздел 5.3. Тот же экран открывает команда `dpistack reconfigure`, минуя меню управления.
- **2, Статус компонентов.** Вывод `dpistack-ctl status` построчно: компонент, состояние, включён ли в автозапуск.
- **3, Логи.** Список компонентов из 4.1, выбор номером, затем `dpistack-ctl logs <id> -n 200`; `f` внутри просмотра переключает на `--follow` до `Ctrl+C`.
- **4, Запустить тесты.** `dpistack-ctl test all --json`, результат построчно как в 10.
- **5, Обновить пакеты.** Запускает `upgrade` (5.7) с подтверждением, если есть незакреплённые пакеты для обновления.
- **6, Удалить.** Требует ввести слово `удалить` для подтверждения, затем `1) обычное удаление` или `2) удаление с данными (--purge)`; отменяется пустым вводом.
- **7, Пароль панели.** Ввод дважды без эха, затем `ctl panel-passwd`.

Пункты 2–4 только читают систему и не требуют подтверждения. `dpistack-ctl` недоступен или вернул ошибку — пункт показывает причину и возвращает в меню управления, не завершая `dpistack` целиком.

**Неинтерактивно** те же действия доступны как подкоманды: `dpistack status`, `dpistack test [bittorrent|https|all]`, `dpistack logs <id> [-n N] [--follow]` — тонкие обёртки, отдают код возврата `dpistack-ctl`. `dpistack upgrade` и `dpistack uninstall [--purge]` — как в 5.7. `dpistack reconfigure` — как в 5.3.

### 5.3 «Настроить» (`dpistack reconfigure`), что происходит

**Запуск** как в 5.1 (блокировка, лог, черновик). Если `dpistack.conf` нет, ошибка с подсказкой про `install`, код 2. Иначе открывается экран разделов конфига существующей установки. Его пункты те же, что при установке, но значения текущие, а не умолчания:

```
dpistack 2.0  |  Настройка существующей установки
Конфиг: /etc/dpistack/dpistack.conf  |  компоненты: 6 из 6 активны  |  health: ok

  1) Захват и режим                IDS, enp2s0, enp3s0       ~
  2) Компоненты и источники        Suricata: source, nDPI: да
  3) EVE и хранение                6 типов, ротация daily
  4) Правила                       ET Open, раз в неделю
  5) Доступ                        localhost
  6) Метрики                       экспорт: да, бэкенд: нет
  7) Наблюдение и оповещения       panel, log
  8) Тесты                         после установки: да
  9) Пароль панели                 сменить

  d) Изменения (diff)     a) Применить            r) Отменить правки
  0) Назад в меню управления       q) Выйти

Правки: 1 ключ (IFACES). Проблемы: нет
>
```

Отличия от установки:

- Маркер `~` у раздела и ключа означает «отличается от применённого».
- **d, Изменения.** Построчно `KEY: старое → новое` (секреты: `изменён`), список затронутых шагов по таблице ниже и пометка «лёгкое» или «тяжёлое» у каждого изменения.
- **r, Отменить правки.** С подтверждением сбрасывает все неприменённые правки и удаляет черновик.
- **0, Назад.** Доступно, только когда экран открыт из меню управления (не при прямом `dpistack reconfigure`); без правок выходит сразу, с правками — как `q`.
- **Быстрой установки нет.** Пароль панели меняется отдельным пунктом (без эха, дважды); на этапе применения вызывается `ctl panel-passwd`.

Статус компонентов и запуск тестов на этом экране не дублируются — они в меню управления (5.2).

**Что происходит после `a`** (и сразу при `-y --set ...` через `dpistack reconfigure`, без меню):

1. **Diff.** `config.sh` сравнивает применённый конфиг (`old`) и новый набор и выдаёт список изменённых ключей. Изменений нет: `изменений нет`, код 0.
2. **Определение шагов.** Каждый ключ схемы знает свои шаги (таблица ниже). Изменённые ключи дают набор шагов к применению, остальные пропускаются по `check`.
3. **Классификация.** Изменения делятся на лёгкие (перерисовка файлов и перезапуск) и тяжёлые (пакеты, сборка, смена runtime, версия, пиннинг). Для тяжёлых показывается, что будет переустановлено или пересобрано, и запрашивается `Продолжить? [y/N]` (в `-y` нужен `--force`).
4. **Сводка и подтверждение** с diff ключей и списком шагов. `--dry-run` печатает план и выходит.
5. **Применение.** Новый конфиг пишется в `dpistack.conf.new`, шаги работают с ним. Каждый затронутый файл рендерится с бэкапом, затем проверяется (`suricata -T` для Suricata и правил), затем компонент перезапускается или перечитывает конфиг. Провал проверки оставляет прежний файл и прежний `dpistack.conf`, печатает вывод проверки, код 1; экран остаётся открытым с правками, чтобы их можно было исправить. Успех атомарно переименовывает `dpistack.conf.new` в `dpistack.conf`, обновляет `state`, удаляет черновик.
6. **Отчёт** с тем, что изменилось, и предупреждениями. Тесты автоматически не запускаются (пункт «Запустить тесты» в меню управления или `--only verify`).

Из панели и `ctl` изменение конфига идёт по тому же пути, но без меню, без вопросов и без тяжёлых изменений (`ctl reconfigure`, раздел 4.5).

Ключи и затрагиваемые шаги:

| группа ключей | шаги | тип |
| --- | --- | --- |
| `IFACES`, `BPF_FILTER`, `HOME_NET`, `SURICATA_MODE`, `IPS_*`, `EVE_*`, `STATS_INTERVAL_SEC` | `suricata` (перерисовка, перезапуск), `ntopng` при `IFACES`, `watch` при `EVE_*` и `STATS_*` | лёгкий |
| `RULES_*` | `rules` | лёгкий |
| `NTOPNG_IFACES`, `NTOPNG_PORT`, `EVEBOX_PORT`, `EVEBOX_RETENTION_DAYS`, `EVEBOX_ES_URL` | `ntopng` или `evebox`, `access` | лёгкий |
| `ACCESS_MODE`, `LAN_CIDR`, `PANEL_PORT`, `NGINX_*`, `FIREWALL_MANAGE` | `access`, `panel` | лёгкий |
| `WATCH_*`, `ALERT_*` | `watch` | лёгкий |
| `METRICS_EXPORT`, `METRICS_RETENTION`, `METRICS_BACKEND_PORT` | `metrics`, `panel` | лёгкий |
| `METRICS_BACKEND`, `METRICS_BACKEND_RUNTIME` | `metrics` | тяжёлый |
| `TEST_*` | `verify` | лёгкий |
| `*_RUNTIME`, `*_SOURCE`, `*_VERSION`, `NDPI_*`, `PIN_VERSIONS`, `EVEBOX_DB`, `PANEL_SOURCE` | шаг компонента | тяжёлый |

### 5.4 Идемпотентность

- Повторный запуск с тем же конфигом ничего не меняет: каждый шаг печатает `без изменений`, код 0. Проверяется bats-тестом на заглушках.
- Отрендеренный файл хранит хэш последнего рендера в `state`. Файла нет → рендер. Хэш совпадает, вход изменился → рендер. Файл изменён руками (в том числе через панель) → остаётся, установщик печатает уведомление. `--force` делает бэкап в `backups/` и перезаписывает. Это правило действует и для перерисовки при `iface add|remove` и `reconfigure`.
- Пакеты ставятся только если их нет или версия расходится с закреплённой.
- Шаг `selfinstall` копирует файлы, только если их хэш в `/usr/local/lib/dpistack/installer/` отличается от хэша в источнике (обновление версии набора).
- Установщик никогда не сбрасывает и не пересоздаёт чужие цепочки iptables/nft. Свои правила живут в отдельной цепочке `DPISTACK`, которую восстанавливает юнит `dpistack-fw.service` при каждой загрузке.

### 5.5 Preflight

Root, Bash 4.4+, дистрибутив и архитектура из поддерживаемых, `systemd` (для native), Docker с `compose` (если есть компонент с `docker`), интерфейсы из `IFACES` существуют (`ip link`), свободное место (не меньше 4 ГБ при `SURICATA_SOURCE=source`, иначе 1 ГБ), доступность нужных хостов через `curl`, порты из 4.3 свободны (`ss -ltn`), режим SELinux (только сообщить). Провал даёт код 3 и перечень причин целиком, а не первую.

### 5.6 Режимы и секреты

- Неинтерактивный режим: значения из `--config`, затем `--set`, затем умолчания. Секреты только из `secrets.conf` или переменных окружения. Запрос ввода в этом режиме ошибка.
- `--dry-run`: `run` печатает `+ команда` и не выполняет. Запись в `state`, `dpistack.conf` и лог установки не делается. Чтение системы разрешено.
- Секреты не попадают в `dpistack.conf`, лог установки и вывод `--dry-run`. `set -x` в скриптах запрещён.

### 5.7 Обновление и удаление

`upgrade` учитывает `PIN_VERSIONS` и не трогает закреплённое без `--set`. `uninstall` останавливает и отключает юниты, удаляет юниты и бинарники набора (включая `/usr/local/sbin/dpistack` и `/usr/local/lib/dpistack/installer/`), оставляет данные и конфиги Suricata, EveBox, ntopng и бэкенда метрик. `uninstall --purge` удаляет и их, после подтверждения (в неинтерактивном режиме подтверждением служит сам флаг; в меню управления — слово `удалить`, раздел 5.2).

---

---

## 6. Suricata и nDPI: правила интеграции

- **Захват:** `af-packet`, по блоку на интерфейс из `IFACES`, `cluster-type: cluster_flow`, `defrag: yes`, `threads: auto`, `cluster-id` уникален для интерфейса. `BPF_FILTER` подставляется, если задан.
- **nDPI:** при `NDPI_ENABLE=yes` в `plugins:` добавляется `ndpi.so` из каталога плагинов установленной Suricata. Правила, использующие `ndpi-protocol` и `ndpi-risk`, обязаны начинаться с `requires: keyword ndpi-protocol` (и/или `ndpi-risk`), чтобы Suricata без плагина пропускала их, а не падала.
- **Сборка из исходников:** `./configure --enable-ndpi --with-ndpi=<префикс>`. Версия nDPI определяется требованием выбранной версии Suricata. Несовместимость ловится на `configure` и выводится как есть, обходов нет. Установщик после сборки проверяет наличие `ndpi.so` и `suricata --build-info`.
- **Юнит** при `source` рендерится из `templates/`, при пакетах используется дистрибутивный, дополняется drop-in файлом.
- **Конфиг:** `suricata.yaml` рендерится полностью из шаблона и проверяется `suricata -T`. Один и тот же шаблон обслуживает IDS и IPS (допущение A5).
- **IDS → IPS:** переключение командой `mode` включает `afpacket` copy-mode или NFQUEUE-правила в цепочке `DPISTACK`, перезапускает Suricata и запускает таймер отката. Без `mode-confirm` за отведённое время режим возвращается в `ids`. Правила с действием `drop` берутся из `drop.conf`. NFQUEUE-правила ставятся с флагом `--queue-bypass`, чтобы падение Suricata не отрезало сеть. Хост вне разрыва сети защищает только себя (раздел «Предметная область»).
- **EVE:** типы из `EVE_TYPES`. `stats` включается с интервалом `STATS_INTERVAL_SEC`. Права файла `0640`. Ротация через `logrotate` без `copytruncate`: после ротации выполняется `suricatasc -c reopen-log-files`, чтобы Suricata открыла новый файл.

---

## 7. Правила Suricata

- Источники: `RULES_SOURCES` (имена из `suricata-update list-sources`), `RULES_URLS` (свои). Свои локальные правила лежат в `local.rules` и подключаются всегда.
- Группы из `RULES_GROUPS` включаются строками `group:<имя>.rules` в `enable.conf`. Отдельные правила отключаются в `disable.conf`.
- Обновление: `dpistack-rules.timer` с `OnCalendar=$RULES_UPDATE_CALENDAR` и `Persistent=true`. Порядок: снимок текущего набора → `suricata-update` → `suricata -T` → `reload suricata`. Ошибка на любом шаге возвращает снимок и оставляет `rules.age` растущим (это увидит watchdog).
- `RULES_UPDATE=off` не создаёт таймер, обновление только вручную.

---

## 8. Watchdog

`dpistack-watch` запускается `dpistack-watch.timer` каждые `WATCH_INTERVAL_SEC` как oneshot от root. Он ничего не чинит, пока `WATCH_AUTORESTART=no`.

| проверка | как | `ok` / `warn` / `crit` |
| --- | --- | --- |
| `<id>.process` | состояние через runtime | `active` / нет / `failed` или `inactive` |
| `<id>.port` | `ss -ltn` на порту из конфига | слушает / нет / нет дольше двух прогонов подряд |
| `suricata.eve_fresh` | возраст последнего события в `eve.json` | моложе `WATCH_EVE_STALE_SEC` / нет / старше |
| `suricata.drop_rate` | по двум последним `stats` | ниже `WARN` / от `WARN` / от `CRIT` |
| `disk.free` | минимум свободного места по разделам логов Suricata, данных EveBox (при `sqlite`) и бэкенда метрик; `detail` называет худший путь | выше `WARN` / ниже `WARN` / ниже `CRIT` |
| `rules.age` | возраст `suricata.rules` | младше `WARN_DAYS` / от `WARN_DAYS` / от `CRIT_DAYS` |

Детали проверок:

- `<id>.process` берёт состояние из `dpistack-ctl status --json` (то есть через runtime): `active` даёт `ok`, `failed` и `inactive` дают `crit`, `absent` даёт `na`.
- `<id>.port`: порты `EVEBOX_PORT`, `NTOPNG_PORT`, `PANEL_PORT`, `METRICS_BACKEND_PORT`, у `redis` 6379. Нет порта один или два прогона подряд даёт `warn`, три и больше подряд дают `crit`; счётчик лежит в `state` (`watch.miss.<id>`).
- `suricata.eve_fresh`: возраст `eve.json` по mtime. Файла нет даёт `warn`.
- `suricata.drop_rate`: по двум последним `stats` из хвоста файла (последние 4 МБ, файл целиком не читается). Меньше двух событий даёт `na`. Сброс счётчика (значение меньше прежнего) даёт `ok` с пометкой, интервал пропускается.
- `disk.free`: разделы каталога `eve.json` и `/var/lib/evebox` (при `sqlite`); каталог бэкенда метрик добавляет слайс 28. Побеждает наименьшая доля свободного места.
- `rules.age`: файла `suricata.rules` нет даёт `warn`.
- При `WATCH_AUTORESTART=yes` упавший (`crit`) компонент перезапускается через `dpistack-ctl restart <id>`, не больше 3 раз за скользящий час, метки времени лежат в `state` (`watch.restarts.<id>`). Перезапуск пишется в журнал юнита.
- Зависимости: `jq` (шаг `watch` ставит), `flock` (util-linux): второй одновременный прогон выходит молча. Юнит пропускает запуск, пока нет копии установщика и `dpistack-ctl` (`ConditionPathExists`).
- `dpistack-watch` не требует аргументов; `dpistack-ctl health` запускает его один раз и печатает `health.json`.

`na` ставится, если проверка неприменима: `EVE_FILE=no`, нет `stats` в `EVE_TYPES`, `RULES_UPDATE=off` для `rules.age`, компонент не установлен.

**Оповещения:** отправляются при смене статуса и повторяются каждые `WATCH_REPEAT_MIN`, пока статус не `ok`. При возврате в `ok` уходит сообщение о восстановлении. Каналы из `ALERT_CHANNELS` работают независимо и в любых сочетаниях:

- `panel`: строка в `events.jsonl`;
- `log`: `logger -t dpistack-watch -p daemon.warning` (уровень `err` для `crit`);
- `tg`: `curl` к Bot API, токен и `ALERT_TG_CHAT_ID`;
- `mail`: `curl --url "$ALERT_SMTP_URL"` с `ALERT_MAIL_FROM` и `ALERT_MAIL_TO`, без локального MTA.

Сбой одного канала пишется в журнал и не мешает остальным. Тексты сообщений на русском, одна строка на проверку.

---

## 9. Панель

**Ресурсы (бюджет):** RSS в простое не больше 25 МБ, бинарник не больше 15 МБ, ноль CPU без открытых вкладок и без запросов `/metrics`. Юнит: `MemoryMax=64M`, `CPUQuota=20%`, `ProtectHome=yes`, `PrivateTmp=yes`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`. `NoNewPrivileges` и `ProtectSystem` не ставятся: `sudo` наследует ограничения юнита и `dpistack-ctl` не смог бы писать в `/etc`. Защита строится на списках в `dpistack-ctl`.

**Поведение:**

- Чтение `eve.json` инкрементальное с сохранённого смещения. Кольцо не больше 5000 событий в памяти. Файл целиком никогда не разбирается.
- Метрики для графиков: кольцо 24 часа с шагом 30 секунд, снимок в `metrics.json` раз в час и при остановке. `GET /metrics` строится из тех же данных и не читает диск чаще, чем раз в секунду.
- Опрос `status` не чаще раза в 10 секунд и только пока вкладка видима. SSE открывается только на экранах логов и событий и закрывается при уходе с экрана.
- Аутентификация: один администратор, argon2id, ограничение попыток входа (5 за 5 минут на IP), сессия 12 часов. Отключить вход нельзя.

**Интерфейс:** одностраничный, хэш-роутер. Экраны: Обзор, Компоненты, Конфиги, Правила, Логи, События, Метрики, Тесты, Оповещения. Светлая и тёмная темы по `prefers-color-scheme`, системный шрифт, адаптивная вёрстка. Графики рисуются собственной функцией на inline SVG. Суммарный вес статики не больше 150 КБ до сжатия, отдаётся с gzip. Редактор конфига обычный `<textarea>` с моноширинным шрифтом, кнопки «Проверить», «Сохранить», «Сохранить и применить», «Откатить». Опасные действия (остановка компонента, переключение в IPS) просят подтверждение.

---

## 10. Проверочные тесты (`dpistack-ctl test`)

Результат: `{"name","status","detail","duration_ms"}`, `status` из `pass`, `fail`, `skip`. Итог пишется в `tests-last.json`. Код возврата: `0` все `pass` или `skip`, `1` есть `fail`.

**`bittorrent`** (офлайн, по умолчанию не касается живого трафика):

1. Запускает `suricata -r tests/data/bittorrent.pcap -l <tmp>` с конфигом из `suricata-test.yaml.tpl`. Конфиг подключает те же правила и плагины, пишет `alert` и `netflow` во временный каталог, главный `eve.json` не трогает.
2. `pass`, если во временном `eve.json` есть `alert` с сигнатурой, содержащей `BitTorrent`. При загруженном плагине nDPI тест добавляет в набор своё правило `alert tcp any any -> any any (msg:"dpistack test nDPI BitTorrent"; requires: keyword ndpi-protocol; ndpi-protocol:BitTorrent; sid:9000001;)`, поэтому плагин проверяется и без группы `emerging-p2p` (A2: отдельных полей nDPI в EVE нет).
3. `skip` с причиной, если нет ни правил группы `emerging-p2p`, ни плагина nDPI. Сообщение говорит, что именно включить.
4. `TEST_BT_LIVE=yes` дополнительно подаёт тот же pcap через `tcpreplay` в первый интерфейс из `IFACES` и ищет событие в главном `eve.json`. По умолчанию выключено: подмена трафика на боевом интерфейсе шумит.

Происхождение pcap: записывается один раз в слайсе 0. Клиент BitTorrent с легальным торрентом в изолированной сети, `tcpdump` первых пакетов handshake, адреса заменяются на документационные (`192.0.2.0/24`) через `tcprewrite`. Способ записи и проверка срабатывания на реальной сигнатуре ET описываются в `tests/data/README.md`.

**`https`** (живой):

1. Выполняет `curl -sS -o /dev/null "$TEST_HTTPS_URL"`. Метка события: SNI, то есть хост из URL.
2. Ждёт до 20 секунд события `tls` в главном `eve.json` с `tls.sni` равным хосту из URL.
3. Строки про nDPI `TLS` в `detail` нет: полей nDPI в EVE нет (A2).
4. Нет `eve.json`: `fail` сразу, без ожидания. `curl` запускается с `--max-time 15`, чтобы сеть без ответа не зависила запрос панели. `fail`, если событие не появилось: `detail` называет причину (`curl` не прошёл, событий нет, интерфейс тот же, что у `curl`, иначе пакеты не видны).

Результат каждого теста пишется в `tests-last.json` (4.6). `--json` печатает массив объектов `{"name","status","detail","duration_ms"}`.

**`all`** запускает оба по очереди. `verify` в установщике запускает `all` при `TEST_ON_INSTALL=yes`, провал теста не отменяет установку, а попадает в итоговый отчёт.

---

## 11. Тесты проекта

Тесты выводятся из критериев приёмки слайса, а не из готового кода. Критерии пишутся в разделе 17 до кода.

- Bash: `bats`. Внешние команды (`apt-get`, `dnf`, `systemctl`, `suricata`, `curl`, `ss`, `docker`) подменяются заглушками из `tests/mocks/` через `PATH`. Пути перенаправляются в `mktemp -d` через `DPISTACK_ROOT`. Остальные переменные окружения, нужные только тестам: `DPISTACK_INPUT` (ввод меню из файла), `DPISTACK_TEST_WAIT` (секунды ожидания события вместо 20), `DPISTACK_NOW` (время watchdog в секундах эпохи).
- Go: `go test`, HTTP-обработчики через `httptest`, вызов `dpistack-ctl` подменяется интерфейсом `ctl.Runner`.
- Запрещённый вид теста: «выполнили шаг, проверили, что вернулся 0». Тест проверяет результат: содержимое файла, вызванные команды, отказ.
- На каждый слайс минимум: тест на каждый критерий с проверяемым условием, тест пути ошибки (неверный ключ, отсутствующий компонент, провал валидации), тест идемпотентности для слайсов установщика.
- Интеграция на реальной ОС проверяется руками по критериям слайса и в bats не автоматизируется.

---

## 12. Проверки и гейт

`scripts/gate.sh`:

```
shfmt -d install.sh lib bin scripts tests
shellcheck -x install.sh lib/*.sh bin/dpistack-ctl bin/dpistack-watch scripts/*.sh
bats tests
# при наличии panel/:
gofmt -l panel        (пустой вывод)
go vet ./...          (в panel/)
go test ./...         (в panel/)
```

`gate.sh` красный → слайс не закрыт. Правки по гейту делаются в том же заходе.

Между `shellcheck` и `bats` гейт запускает `scripts/security.sh` (12.2).

### 12.1 CI/CD (`.github/`)

- `ci.yml` на каждый push в `main` и `dev` и на каждый pull request: `scripts/gate.sh` на `ubuntu-22.04` и `ubuntu-24.04`, плюс `actionlint` для самих workflow. Права `contents: read`, отмена устаревших прогонов той же ветки.
- `security.yml` на push, pull request и раз в неделю: `gitleaks` по всей истории (токен, попавший в старый коммит, остаётся в нём), `scripts/security.sh`, `shellcheck -S style`, `trivy fs` (секреты и ошибки конфигурации, HIGH и CRITICAL) с отправкой SARIF в code scanning.
- `release.yml` по тегу `vX.Y.Z`: тот же `gate.sh`, затем проверка, что тег равен `DPISTACK_VERSION` в `lib/common.sh`, сборка `dpistack-X.Y.Z.tar.gz` (`install.sh`, `lib`, `templates`, `bin`, `tests/data`), файл `.sha256`, аттестация происхождения (`actions/attest-build-provenance`) и публикация релиза. Права на запись есть только у job `publish`.
- `dependabot.yml` обновляет версии GitHub Actions раз в неделю.
- Правила для workflow, проверяемые `tests/ci_config.bats`: у каждого явный блок `permissions`, нет `pull_request_target`, нет текста события (`head_ref`, заголовки issue и комментарии) в `run:`, каждая сторонняя action закреплена версией, версия программы в `tech.md` равна версии в коде.
- Закрепление action по SHA коммита не сделано: версии берутся из `dependabot`, SHA нужно подставить при первом запуске с доступом к GitHub.
- Сборка Go-панели и бинарных артефактов добавится в `release.yml` вместе с панель-слайсами.

Дополнено ревью (v7): все действия закреплены по полному SHA коммита с комментарием версии (`dependabot` обновляет их), `actionlint` запускается готовым образом, а не скриптом, пущенным в `bash`; `trivy-action` v0.36.0 (v0.28.0 тянул удалённый `setup-trivy@v0.2.1`, и job падал на подготовке); релиз публикуется, только если тег стоит на `main`; загрузка SARIF пропускается для pull request из форка (у него токен только на чтение). `tests/ci_config.bats` проверяет закрепление по SHA, отсутствие `curl | sh`, проверку тега и наличие файлов, которые копирует `release.yml`. Первые запуски на GitHub были красными с первого коммита по двум причинам, обе найдены только там: (1) `preflight` установщика требует root, а шаги раннера идут от обычного пользователя, поэтому каждый тест с установкой падал; гейт на раннере теперь запускается как `sudo -E env "PATH=$PATH" bash scripts/gate.sh`; (2) `trivy-action` v0.28.0 подтягивал вложенное действие `setup-trivy@v0.2.1`, которого больше нет, и job падал на подготовке; теперь v0.36.0, у которого вложенные действия закреплены по SHA. Проверено локально на версиях инструментов Ubuntu 22.04 (`shfmt` 3.4.3, `shellcheck` 0.8.0, `bats` 1.2.1). Журналы запусков из среды разработки недоступны, поэтому причины подтверждены воспроизведением, а не чтением журнала. Чтобы красный гейт не приходилось разбирать вслепую, шаг `Report failing checks` в `ci.yml` публикует имена первых шести упавших проверок как commit status с контекстом `gate <ОС> #N` (права `statuses: write` только у этого job). Ещё два дефекта, найденные там: тест искал `uses: ` подстрокой и принял `statuses: write` за действие (теперь разбор привязан к началу строки), а подмена `journalctl` в тесте не останавливалась при игнорируемом `SIGPIPE`, как на раннерах GitHub.

### 12.3 Ветки и слияние

Ветка `main` защищена на GitHub (решение «выбирай сам», v8): обязательны проверки `gate (ubuntu-22.04)`, `gate (ubuntu-24.04)`, `lint workflows`, `gitleaks`, `shell security checks`, `trivy (config and secrets)`; изменения идут только через pull request (одобрений 0, у проекта один владелец); защита действует и для администратора; force-push и удаление `main` запрещены; обсуждения в PR должны быть закрыты. Актуальность ветки относительно `main` не требуется (`strict` выключен), иначе после каждого слияния `dev` пришлось бы подтягивать `main`. Прямой push в `main` невозможен, поэтому слияние идёт кнопкой «Create a merge commit» в PR `dev` → `main`. Ветку `dev` не удалять: «Automatically delete head branches» в настройках репозитория выключено.

Работа идёт в ветке `dev`, ветка `main` содержит только проверенное состояние:

1. Каждый слайс или исправление коммитится в `dev` и пушится.
2. Коммит должен пройти проверки: локально `scripts/gate.sh` (`shfmt`, `shellcheck`, `scripts/security.sh`, `bats`), на GitHub workflow `ci` и `security` для этого коммита.
3. Пока хотя бы одна проверка красная или не закончилась, в `main` не сливают.
4. Когда всё зелёное, открывается PR `dev` → `main` и сливается коммитом слияния (не squash, не rebase) с сообщением вида `merge dev into main: <что вошло>`; прямых коммитов в `main` нет.
5. Релиз выпускается тегом `vX.Y.Z` на `main` (12.1: тег не на `main` не публикуется).

Если слияние даёт конфликт, он решается в `dev`, после чего проверки проходят заново.

### 12.2 Проверки безопасности (`scripts/security.sh`)

Дешёвая локальная проверка без сети, одна и та же в гейте и в CI. Красный результат закрывает слайс так же, как красный `shellcheck`. Проверяет:

1. секреты в отслеживаемых файлах (токены GitHub, ключи AWS, приватные ключи, токены Slack и Telegram); при наличии `gitleaks` запускает и его;
2. `eval` и `bash -c` / `sh -c` над собранной строкой в коде (строки, которые только печатают `ExecStart=` юнита, исключены);
3. `curl | sh` и `wget | sh`;
4. `chmod` с правом записи для группы и остальных;
5. фиксированные пути в `/tmp`, `mktemp -u` и временные имена через `$$`: временное создаётся только через `mktemp` в приватном каталоге;
6. `set -u` в каждой точке входа;
7. окончания строк CRLF;
8. секреты в аргументах `curl`: токены и пароли передаются через `-K -` на stdin, чтобы их не было в `ps`.

Что уже учтено в коде и проверяется тестами: токен Telegram и пароль SMTP не попадают ни в журнал, ни в `events.jsonl`, ни в `--dry-run` (`tests/alerts.bats`); `sudo` разрешает пользователю `dpistack` только `dpistack-ctl`, а его аргументы сверяются со списками (`tests/ctl_basic.bats`, `tests/ctl_config.bats`); `sudoers` проверяется `visudo` до записи; `panel.auth` хранит argon2id с правами 0640; `config-write` не обновляет хэш рендера, поэтому правка из панели не затирается установщиком. Проверки `suricata -T` идут в приватном временном каталоге, а не в `/tmp`. Блокировка установщика берёт свободный дескриптор через `exec {fd}>`, без `eval`.

Тесты самих проверок: `tests/security.bats` подсовывает каждое нарушение во временный репозиторий и требует красный результат, а чистое дерево и репозиторий проходят.

Не покрыто и остаётся ручным: настоящий `sudo -n` от пользователя `dpistack` на стенде, лимиты `systemd` панели (слайсы панели), поведение `fs.protected_symlinks` на целевых ОС, сканирование зависимостей Go (появится вместе с `panel/`: `govulncheck ./...` добавляется в `gate.sh` и `security.yml`).

- `shfmt` ловит форматирование;
- `shellcheck` ловит ошибки кавычек, неиспользуемые переменные, небезопасные конструкции;
- `bats` и `go test` ловят критерии приёмки.

Слайс 0 (прототип) и слайс 25 (README) гейт не затрагивают, кроме проверки ссылок в 25.

---

## 13. Конвенция текста

Код, комментарии, коммиты, записи в лог-файлы и журнал, имена в API и метриках: по-английски. Всё, что видит человек (вопросы установщика, вывод `--help`, сообщения об ошибках установщика, интерфейс панели, тексты оповещений): по-русски. Слоя i18n нет.

Коммиты, Conventional Commits, фиксированный формат:

```
type(scope): summary
```

- `type` из набора `feat|fix|test|refactor|chore|docs`;
- `scope` из набора `installer|ctl|watch|panel|rules|suricata|ndpi|ntopng|evebox|metrics|access|tests|docs`;
- `summary` в императиве, со строчной буквы, без точки, до 50 символов;
- тело только чтобы объяснить *почему*, не *что*;
- коммитить по ходу работы маленькими шагами. Каждый коммит по возможности проходит `gate.sh`.

Примеры: `feat(installer): add idempotent suricata step`, `test(watch): cover drop rate counter reset`.

Правила письма для всей прозы проекта (коммиты, комментарии, README): активный залог, конкретика вместо общих фраз, без вводных оборотов, без длинного тире, без наречий-усилителей. Комментарий объясняет причину решения, а не пересказывает соседнюю строку. Закомментированный код не оставлять.
Перед написанием README посмотри [https://docs.github.com/en](https://docs.github.com/en), [https://github.com/matiassingers/awesome-readme](https://github.com/matiassingers/awesome-readme), [https://www.makeareadme.com/](https://www.makeareadme.com/)

---

## 14. Definition of Done одного слайса

1. Критерии приёмки слайса из раздела 17 выполнены и проверены руками на чистой ОС (стадии 1–4: Ubuntu LTS; слайсы 26–28: указанная там среда).
2. Тесты написаны из критериев, `scripts/gate.sh` зелёный.
3. Для слайсов установщика: второй запуск даёт `без изменений`, `--dry-run` ничего не меняет (проверено сравнением состояния системы до и после).
4. Новых файлов и абстракций сверх раздела 3 нет.
5. Мёртвого кода нет: неиспользуемых функций, шаблонов, ключей схемы, JS-модулей.
6. Коммиты по конвенции раздела 13.
7. `tech.md` не изменён (изменение контракта идёт отдельно, через раздел 15).

---

## 15. CONTRACT GAP

Не хватает ключа конфига, команды `ctl`, метрики, поля EVE или эндпоинта: работа останавливается. Выдай блок и жди ответа:

```
CONTRACT GAP
Что нужно: <ключ/команда/метрика/поле/эндпоинт>
Зачем: <какой критерий приёмки без него не выполняется>
Предлагаемая форма: <точное имя, тип, значения по умолчанию>
Что делаю пока: <заглушка локально в своём слайсе / жду>
```

Код с выдуманным контрактом не пиши. Схему ключей, список команд `dpistack-ctl`, формат `health.json`, список метрик, HTTP API сам не расширяй.

---

## 16. Правила поведения в сессии

- Думай до кода: назови допущения, спроси при неоднозначности, покажи варианты вместо молчаливого выбора.
- Простота: никаких фич сверх запрошенного, никаких абстракций под одноразовый код, никакой обработки ошибок, которых не бывает.
- Хирургические правки: соседний рабочий код не улучшать и не рефакторить. Каждая изменённая строка следует из текущей задачи.
- Один слайс за заход. Не выкатывай всё сразу.
- Команды, меняющие систему (`apt`, `dnf`, `iptables`, `systemctl`), запускай только на тестовой машине или в `--dry-run`. Никогда не меняй правила сети и не переключай IPS на хосте, где идёт работа по SSH, без таймера отката.
- Ревью идёт вторым заходом, после того как слайс готов, а не в том же сообщении, где написан код.

---

## 17. Стадии и слайсы, допущения

Порядок жёсткий, сверху вниз. Один слайс за один заход. Слайс закрыт, когда выполнен Definition of Done из раздела 14 (для слайсов 0 и 25 критерии приёмки, без гейта). Слайс вертикальный: от ключа конфига до видимого результата.

- **Стадия 0, прототип.** Слайс 0.
- **Стадия 1, каркас.** Слайс 1.
- **Стадия 2, ядро на хосте (native, apt-семейство).** Слайсы 2–9.
- **Стадия 3, проверки и наблюдение.** Слайсы 10–14.
- **Стадия 4, управление и панель.** Слайсы 15–25. **Конец стадии 4 = MVP.**
- **Стадия 5, после MVP.** Слайсы 26–30.

### Допущения, требующие проверки (не заморожены)

| # | допущение | подтверждается в слайсе |
| --- | --- | --- |
| A1 | Имя набора `dpistack` и все производные пути из 4.2 | согласуется владельцем до слайса 1 |
| A2 | Закрыто (v5): отдельных полей `ndpi.*` в EVE нет, nDPI виден через `alert.signature` и `alert.metadata` (4.7) | закрыто |
| A3 | Пакеты `distro` и `oisf` могут не содержать `ndpi.so` | 0, 4 |
| A4 | Способ задать пароль администратора ntopng при установке; пока он не найден, ntopng слушает только `127.0.0.1`, а установщик печатает предупреждение | 0, 5 |
| A5 | Полный рендер `suricata.yaml` вместо `include`-дополнений (списки в `include` могут заменяться, а не сливаться) | 0, 2 |
| A6 | Docker-образы `jasonish/suricata`, `jasonish/evebox`, `ntop/ntopng`, `victoriametrics/victoria-metrics`, `prom/prometheus` и их пути и тома | 27, 28 |
| A7 | Наличие репозиториев ntop и EveBox для каждой поддерживаемой ОС | 5, 6, 26 |
| A8 | Закрыто (v5): режима проверки у EveBox и ntopng нет, проверяется непустота (4.5) | закрыто |
| A9 | Механизм retention EveBox (`EVEBOX_RETENTION_DAYS`): встроенная настройка или периодическая очистка | 0, 6 |
| A10 | Источник бинарника VictoriaMetrics и Prometheus для `native` и проверка контрольной суммы | 28 |
| A11 | Тип лицензии выбирает владелец | до слайса 25 |

---

### Слайс 0: ручной прототип

Кода нет. На чистой тестовой машине (Ubuntu LTS) вручную поднимается вся связка по документации компонентов. Результат: `docs/prototype.md` и `tests/data/bittorrent.pcap` с `tests/data/README.md`.

**Критерии приёмки:**

1. Для допущений A2, A3, A4, A5, A9 записан ответ с командами и выводом. Владелец обновляет `tech.md` до v3 и убирает их из таблицы.
2. Записаны реальные имена полей nDPI в EVE для `alert` и `netflow` на примере BitTorrent и TLS.
3. `bittorrent.pcap` при реплее (`suricata -r`) даёт сигнатуру ET P2P и/или nDPI-протокол `BitTorrent`. Способ записи описан.
4. Записан список пакетов, репозиториев и версий, которые понадобились, и время сборки Suricata из исходников на тестовой машине.

**Не делать:** скрипты, шаблоны, автоматизацию.

---

### Слайс 1: каркас

**Что собрать:**

- Дерево из раздела 3 с пустыми шагами (каждый печатает `план` и `без изменений`).
- `lib/paths.sh`, `lib/common.sh` (`run`, `log`, `die`, `lock`, `atomic_write`, `backup`), `lib/os.sh` (определение ОС, `pkg_*` для apt и dnf), `lib/state.sh`.
- `lib/schema.sh` с полной таблицей 4.3 (включая колонку затрагиваемых шагов из 5.3) и `lib/config.sh`: слои, проверка, вопросы basic и advanced, сохранение, diff.
- `install.sh` со всеми командами и опциями из 4.4.
- `dpistack.conf.example`, `scripts/gate.sh`, `tests/mocks/`.

**Критерии приёмки:**

1. `scripts/gate.sh` зелёный на каркасе.
2. `install.sh install --dry-run -y` проходит все шаги, ничего не меняет, код 0.
3. Неизвестный ключ, значение вне вариантов, `EVEBOX_DB=elasticsearch` без `EVEBOX_ES_URL`, `METRICS_BACKEND=victoriametrics` при `METRICS_EXPORT=no` дают код 2 и понятное сообщение.
4. Ключ с ещё не реализованным значением (`docker`, `ips`) отклоняется сообщением `пока не поддерживается`.
5. Интерактивный режим сохраняет ответы в `dpistack.conf`, повторный `-y` даёт тот же конфиг.
6. `os.sh` правильно определяет `apt` для Ubuntu/Debian и `dnf` для Fedora/RHEL/Rocky/Alma по заглушкам `os-release`, включая `ID_LIKE`.
7. Секреты из `--set ALERT_TG_TOKEN=...` попадают в `secrets.conf` (0600), а не в `dpistack.conf` и не в вывод.
8. Два одновременных запуска: второй выходит с кодом 1 из-за блокировки.
9. `reconfigure --dry-run` на заглушках выводит diff ключей и список затронутых шагов по таблице 5.3.

**Тесты:** `tests/config.bats`, `tests/os.bats`, `tests/dryrun.bats`, `tests/lock.bats` по критериям 2–9.

**Не делать:** реальную установку чего-либо, шаблоны, панель.

---

### Слайс 2: Suricata (IDS) из пакетов, EVE, systemd, logrotate

**Файлы:** `lib/step_suricata.sh`, `lib/step_preflight.sh`, `lib/runtime_native.sh`, `templates/suricata.yaml.tpl`, `templates/logrotate.tpl`.

**Что делает:** реальный `preflight`; установка Suricata при `SURICATA_SOURCE` из `distro`/`oisf` (подключение репозитория через `pkg_repo_add`); рендер `suricata.yaml` (af-packet по `IFACES`, EVE по `EVE_TYPES`, `stats`, `HOME_NET`); logrotate; `systemctl enable --now`. До слайса 4 значения `SURICATA_SOURCE=source` и `NDPI_ENABLE=yes` отклоняются как `пока не поддерживается`, тесты идут с `--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no`.

**Критерии приёмки:**

1. `suricata -T` на отрендеренном конфиге проходит.
2. Два интерфейса в `IFACES` дают два блока `af-packet` с разными `cluster-id`.
3. `EVE_TYPES=alert,dns` даёт в конфиге только эти типы; `stats` есть, если он в списке.
4. `eve.json` растёт при трафике на интерфейсе, `stats` приходит каждые `STATS_INTERVAL_SEC`, права файла `0640`.
5. Несуществующий интерфейс останавливает `preflight` до установки пакетов, код 3.
6. Повторный запуск: без изменений. Файл, изменённый руками, не перезаписывается без `--force`; с `--force` есть бэкап.
7. `PIN_VERSIONS=yes` закрепляет пакет (`apt-mark hold` или `versionlock`).

**Тесты:** `tests/suricata_step.bats` по критериям 2, 3, 5, 6, 7 (на заглушках).

**Не делать:** правила, nDPI, IPS, доступ по сети.

---

### Слайс 3: правила

**Файлы:** `lib/step_rules.sh`, юниты `dpistack-rules.{service,timer}`.

**Что делает:** установка `suricata-update`, источники из `RULES_SOURCES` и `RULES_URLS`, `enable.conf` из `RULES_GROUPS`, таймер, безопасное обновление с откатом.

**Критерии приёмки:**

1. После установки `suricata.rules` существует, `suricata -T` проходит, группы p2p и policy включены.
2. `RULES_UPDATE_CALENDAR=daily` меняет `OnCalendar` в юните.
3. Провал `suricata -T` после обновления возвращает прежний набор, код возврата не 0.
4. `RULES_UPDATE=off` не создаёт таймер.
5. Свой URL в `RULES_URLS` регистрируется как источник и попадает в набор.

**Тесты:** `tests/rules_step.bats` по критериям 2–5.

**Не делать:** интерфейс управления правилами (слайс 20).

---

### Слайс 4: nDPI и Suricata из исходников

**Файлы:** `lib/step_ndpi.sh`, дополнение `step_suricata.sh`, `templates/suricata.service.tpl`.

**Что делает:** при `NDPI_ENABLE=yes` собирает или ставит nDPI, при `SURICATA_SOURCE=source` собирает Suricata с `--enable-ndpi`, подключает `ndpi.so`. Значения по умолчанию становятся рабочими.

**Критерии приёмки:**

1. `suricata --build-info` показывает поддержку nDPI, `ndpi.so` найден, Suricata стартует с плагином.
2. Правило с `requires: keyword ndpi-protocol; ndpi-protocol:TLS;` загружается и срабатывает на тестовом TLS-трафике.
3. `NDPI_ENABLE=yes` при `SURICATA_SOURCE=oisf` и отсутствии `ndpi.so` в неинтерактивном режиме останавливается с кодом 2 и текстом про `SURICATA_SOURCE=source`.
4. Несовместимая версия nDPI видна как ошибка `configure` в выводе, установка не продолжается.
5. Реальные имена полей nDPI в EVE из отчёта слайса 0 внесены в 4.7 через `CONTRACT GAP` (допущение A2).
6. Повторный запуск не пересобирает то, что уже собрано той же версии.

**Тесты:** `tests/ndpi_step.bats` по критериям 3, 6.

**Не делать:** ntopng, собственные сборки других компонентов.

---

### Слайс 5: Redis и ntopng

**Файлы:** `lib/step_redis.sh`, `lib/step_ntopng.sh`, `templates/ntopng.conf.tpl`.

**Что делает:** репозиторий ntop, пакет `ntopng`, Redis, конфиг с `NTOPNG_IFACES` и `NTOPNG_PORT`, привязка к `127.0.0.1` до слайса 7.

**Критерии приёмки:**

1. `ntopng` и `redis` активны, порт `NTOPNG_PORT` слушает на `127.0.0.1`.
2. `NTOPNG_IFACES` по умолчанию равен `IFACES`, явное значение перекрывает.
3. Пароль администратора по умолчанию не остаётся в рабочем состоянии (допущение A4): либо задан установщиком, либо ntopng ограничен `127.0.0.1` с предупреждением.
4. Повторный запуск: без изменений.

**Тесты:** `tests/ntopng_step.bats` по критериям 2, 4.

**Не делать:** ntopng Enterprise, лицензии.

---

### Слайс 6: EveBox

**Файлы:** `lib/step_evebox.sh`, `templates/evebox.yaml.tpl`.

**Что делает:** пакет из репозитория EveBox, `evebox.yaml`, читает `eve.json` (SQLite) или пишет в Elasticsearch, юнит, retention по `EVEBOX_RETENTION_DAYS`.

**Критерии приёмки:**

1. `evebox` активен, порт `EVEBOX_PORT` слушает на `127.0.0.1`, алерт из `eve.json` виден в интерфейсе.
2. `EVEBOX_DB=elasticsearch` без доступного `EVEBOX_ES_URL` останавливает установку до старта юнита.
3. При `EVE_FILE=no` и `EVEBOX_DB=sqlite` шаг сообщает, что EveBox не сможет читать события, и требует подтверждения.
4. События старше `EVEBOX_RETENTION_DAYS` удаляются выбранным по допущению A9 механизмом; `0` отключает удаление. Способ проверен на тестовых данных со старыми метками времени.
5. Повторный запуск: без изменений.

**Тесты:** `tests/evebox_step.bats` по критериям 2, 3, 5.

**Не делать:** агент EveBox, аутентификация EveBox.

---

### Слайс 7: доступ (localhost, lan, nginx), firewall

**Файлы:** `lib/step_access.sh`, `templates/nginx.conf.tpl`.

**Что делает:** привязка всех веб-интерфейсов по `ACCESS_MODE`. `lan`: bind на `0.0.0.0`, при `FIREWALL_MANAGE=auto` разрешение только `LAN_CIDR`. `nginx`: сервисы на `127.0.0.1`, по одному `server` на интерфейс со своим портом (подпути не используются), `allow LAN_CIDR; deny all`, TLS по `NGINX_TLS`. `NGINX_MANAGE=snippet` пишет файл в `/var/lib/dpistack/nginx/` и печатает команду подключения.

**Критерии приёмки:**

1. `localhost`: ни один интерфейс не слушает не на `127.0.0.1` (`ss -ltn`).
2. `lan`: интерфейсы слушают на `0.0.0.0`, установщик печатает предупреждение о видимости и о пароле по HTTP.
3. `nginx` при `snippet` не трогает системный `nginx.conf` и не перезагружает nginx.
4. `nginx -t` на отрендеренном конфиге проходит (проверка в изолированном каталоге).
5. `NGINX_TLS=existing` без `NGINX_CERT` и `NGINX_KEY` даёт код 2.
6. Режим не `localhost` без подтверждения предупреждения не применяется (код 2).
7. На SELinux-системах шаг сообщает о нужных `setsebool`/`semanage`, применение только на слайсе 26.

**Тесты:** `tests/access_step.bats` по критериям 1, 3, 5, 6.

**Не делать:** SSO, basic auth, автоматическое получение сертификатов.

---

### Слайс 8: reconfigure, upgrade, uninstall

**Что делает:** реальные команды `reconfigure`, `upgrade`, `uninstall`, `uninstall --purge` по разделам 5.3 и 5.7.

**Критерии приёмки:**

1. `reconfigure` без `dpistack.conf` выходит с кодом 2; без изменений в ключах печатает `изменений нет`, код 0.
2. Смена `IFACES` перерисовывает `suricata.yaml` и `ntopng.conf`, перезапускает оба компонента и не трогает остальные шаги.
3. Смена «тяжёлого» ключа (`SURICATA_SOURCE`, `*_VERSION`) без подтверждения не применяется; с `-y` без `--force` тоже.
4. Провал `suricata -T` при `reconfigure` оставляет прежние `suricata.yaml` и `dpistack.conf`, код 1, вывод проверки показан.
5. Файл, изменённый руками, при `reconfigure` не перезаписывается без `--force`.
6. `uninstall` останавливает и отключает юниты набора, удаляет юниты и бинарники набора, оставляет конфиги и данные компонентов; `--purge` удаляет и их, но не пакеты, поставленные не установщиком.
7. `upgrade` с `PIN_VERSIONS=yes` не меняет закреплённые пакеты; без пиннинга обновляет.
8. `uninstall` на чистой системе завершается с кодом 0 и сообщением `нечего удалять`.
9. `install`, `uninstall --purge`, `install` даёт тот же результат, что первая установка.

**Тесты:** `tests/reconfigure.bats`, `tests/uninstall.bats` по критериям 1–8.

**Не делать:** откат `upgrade`.

---

### Слайс 9: меню install и reconfigure

**Файлы:** `lib/menu.sh`, доработка `install.sh`.

**Что делает:** меню из разделов 5.0–5.1 и 5.3 поверх схемы, конфига, шагов и `reconfigure` из слайсов 1 и 8. Применение идёт теми же функциями, что и при `-y`. Меню управления (5.2) и персистентная команда `dpistack` — отдельный слайс 15.

**Критерии приёмки:**

1. `install.sh install` на терминале (или с `DPISTACK_INPUT`) показывает главное меню с разделами из 5.0; `-y` меню не показывает.
2. Без терминала, без `DPISTACK_INPUT` и без `-y` установщик выходит с кодом 2 и подсказкой про `-y`.
3. Правка ключа проверяется по схеме сразу: неверное значение отклоняется с перечнем допустимых, прежнее значение остаётся; Enter оставляет значение, `-` сбрасывает к умолчанию, `?` показывает подсказку.
4. Маркеры: `*` у ключей, отличающихся от умолчаний; в `reconfigure` `~` у отличающихся от применённого; `!` у ключей с ошибкой.
5. Пункт «Установить» (`i`) и «Применить» (`a`) недоступны, пока в главном меню есть проблемы; сводка проблем показывает перекрёстные ошибки (например, `METRICS_BACKEND` при `METRICS_EXPORT=no`).
6. «Быстрая установка» показывает найденные интерфейсы без `lo`, помечает интерфейс с маршрутом по умолчанию, принимает номера через запятую и записывает имена в `IFACES`.
7. При существующем `dpistack.conf` `install` показывает экран «Найдена установка» и не перезаписывает конфиг молча.
8. Черновик `dpistack.conf.draft` создаётся после каждого изменения, не содержит секретов, при следующем запуске предлагается продолжить; `dpistack.conf` до применения не меняется.
9. `q` с неприменёнными правками просит подтверждение; `Ctrl+C` завершает работу без изменений системы и без временных файлов.
10. Секреты вводятся без эха и в экранах, сводке и diff показываются как `задан` или `не задан`.
11. `reconfigure`: пункты `d` (diff с пометкой лёгкое или тяжёлое), `a`, `r`, `s`, `t` работают; провал проверки при `a` оставляет меню открытым с правками.
12. `NO_COLOR` и `--no-color` убирают ANSI-последовательности из вывода.

**Тесты:** `tests/menu.bats` по критериям 1–5, 7–12 (ввод из файла `DPISTACK_INPUT`, результат проверяется по сохранённым файлам и выводу, а не по количеству вызовов).

**Не делать:** `dialog`, `whiptail`, ncurses, курсорные последовательности, мышь, темы оформления.

---

### Слайс 10: `dpistack-ctl`, статус, управление, логи

**Файлы:** `bin/dpistack-ctl` (команды `status`, `start|stop|restart`, `reload`, `logs`, `version`), `templates/sudoers.tpl`, часть шага `panel` (пользователь `dpistack`, sudoers).

**Критерии приёмки:**

1. `status --json` отдаёт валидный JSON со всеми установленными компонентами из 4.1 и полем `ndpi_plugin`.
2. `start|stop|restart` работает через runtime компонента; `<id>` вне списка даёт код 5, отсутствующий компонент код 4.
3. `logs <id> -n 5000` даёт код 2 (предел 1000); `logs --follow` завершается при закрытии потока вывода.
4. Аргументы с метасимволами shell дают код 5 без выполнения.
5. Пользователь `dpistack` вызывает `sudo -n dpistack-ctl status` без пароля и не может вызвать другие команды через `sudo`.

**Тесты:** `tests/ctl_basic.bats` по критериям 1–4.

**Не делать:** конфиги, правила, `iface`, `test`, `health`, `mode`, `reconfigure`.

---

### Слайс 11: `dpistack-ctl`, конфиги, правила, iface, reconfigure

**Что делает:** `config-read`, `config-write`, `config-revert`, `reconfigure`, `rules-*`, `iface`, `panel-passwd`.

**Критерии приёмки:**

1. `config-write` при провале проверки не меняет файл, отдаёт код 3 и вывод проверки; при успехе делает бэкап и атомарную замену.
2. `config-revert` возвращает последний бэкап.
3. `config-write dpistack.conf --apply` вызывает `reconfigure`; `reconfigure` при тяжёлом изменении отказывает с кодом 3 и текстом про `install.sh reconfigure`.
4. `rules-sid` с нечисловым аргументом, `config-read` с именем вне списка дают код 5 без выполнения.
5. `iface add` и `iface remove` меняют `IFACES` и вызывают `reconfigure`; удаление последнего интерфейса отклоняется; изменённый вручную `suricata.yaml` не затирается (правило 5.4).
6. `rules-group`, `rules-sources`, `rules-search` правят и читают те же файлы, что шаг `rules`.
7. `panel-passwd` пишет argon2id-хэш, права `panel.auth` `0640 root:dpistack`, пароль не попадает в вывод и лог.
8. Проверка синтаксиса `evebox.yaml` и `ntopng.conf` реализована по допущению A8 и записана в отчёт.

**Тесты:** `tests/ctl_config.bats` по критериям 1–7.

**Не делать:** `test`, `health`, `mode`.

---

### Слайс 12: тесты BitTorrent и HTTPS

**Файлы:** `dpistack-ctl test`, `templates/suricata-test.yaml.tpl`, `lib/step_verify.sh`.

**Критерии приёмки:**

1. `test bittorrent` даёт `pass` на включённой группе `emerging-p2p` и на загруженном плагине nDPI по отдельности.
2. Без правил p2p и без плагина: `skip` с причиной, код 0.
3. Главный `eve.json` не изменился после `test bittorrent` (сравнение размера).
4. `test https` даёт `pass`, когда `curl` вызывает событие `tls` с нужным `tls.sni`, и `fail` с понятной причиной, когда события нет (интерфейс не тот, curl не прошёл).
5. `tests-last.json` содержит результат последнего прогона.
6. `verify` запускает `all` при `TEST_ON_INSTALL=yes`; `fail` не отменяет установку, а попадает в итоговый отчёт.

**Тесты:** `tests/test_cmd.bats` по критериям 2, 3, 4, 5 (на заглушках `suricata` и `curl`, готовых `eve.json`).

**Не делать:** реальные торренты, скачивание файлов.

---

### Слайс 13: watchdog

**Файлы:** `bin/dpistack-watch`, шаг `watch`, юниты `dpistack-watch.{service,timer}`, `ctl health`.

**Критерии приёмки:**

1. Каждая проверка из раздела 8 пишет `status` по порогам из конфига (тесты на границах: значение ровно на пороге).
2. Остановка `suricata` даёт `suricata.process=crit` за один прогон.
3. `eve.json` старше `WATCH_EVE_STALE_SEC` даёт `crit`; при `EVE_FILE=no` или без `stats` в `EVE_TYPES` проверки получают `na`, `overall` их игнорирует.
4. Сброс накопительных счётчиков `stats` (новое значение меньше прежнего) не даёт ложный drop rate.
5. `disk.free` берёт минимум по нескольким разделам и называет худший путь в `detail`.
6. `health.json` валиден, пишется атомарно, `since` меняется только при смене статуса.
7. `WATCH_AUTORESTART=yes` перезапускает упавший компонент не чаще 3 раз в час.
8. `dpistack-ctl health` выполняет один прогон и печатает тот же JSON.

**Тесты:** `tests/watch.bats` по критериям 1, 3, 4, 5, 6, 7.

**Не делать:** оповещения (слайс 14), сбор рядов для графиков.

---

### Слайс 14: каналы оповещений

**Что делает:** каналы `panel`, `log`, `tg`, `mail` в `dpistack-watch`.

**Критерии приёмки:**

1. Смена `ok → warn` отправляет по одному сообщению в каждый канал из `ALERT_CHANNELS`, смена обратно отправляет сообщение о восстановлении.
2. Пока статус не `ok`, повтор идёт не чаще `WATCH_REPEAT_MIN`.
3. `ALERT_CHANNELS=panel,tg` не пишет в журнал и не шлёт почту; сбой `tg` не мешает записи в `events.jsonl`.
4. Пустой `ALERT_TG_TOKEN` при `tg` в списке: установщик останавливает конфигурацию с кодом 2, watchdog на лету пишет ошибку канала в журнал и продолжает.
5. Токен и SMTP-пароль не появляются в журнале, `--dry-run` и `events.jsonl`.

**Тесты:** `tests/alerts.bats` по критериям 1–5 (заглушки `curl` и `logger`).

**Не делать:** маршрутизацию по severity, тихие часы, эскалацию.

---

### Слайс 15: персистентная команда `dpistack` и меню управления

**Файлы:** `lib/step_selfinstall.sh`, доработка `install.sh` и `lib/menu.sh` (главное меню установки уже есть из слайса 9, меню управления и экран «Настроить» без быстрой установки — новые).

**Что делает:** шаг `selfinstall` (раздел 5, врезка перед 5.0) копирует `install.sh`, `lib/*.sh`, `templates/*` в `/usr/local/lib/dpistack/installer/` и кладёт исполняемый файл в `/usr/local/sbin/dpistack`. Бинарник `dpistack` без аргументов показывает меню установки (если конфига нет) или меню управления (5.2), опираясь на `dpistack-ctl` (слайсы 10–11) для статуса, логов и тестов. Подкоманды `dpistack status|test|logs|upgrade|uninstall|reconfigure`.

**Критерии приёмки:**

1. После `install.sh install` на чистой системе `/usr/local/sbin/dpistack` существует, исполняем, и `dpistack --dry-run status` (или эквивалент) даёт тот же результат, что и исходный `install.sh` из того же коммита.
2. Второй запуск `install.sh install` (или `dpistack install`): шаг `selfinstall` не копирует файлы заново, если их хэш не изменился («без изменений»); изменившийся `install.sh` в источнике (новая версия набора) копируется поверх.
3. Бинарник `dpistack` без аргументов при существующем `dpistack.conf` показывает меню управления (пункты «Настроить», «Статус компонентов», «Логи», «Запустить тесты», «Обновить пакеты», «Удалить», «Пароль панели»), а не меню установки.
4. Бинарник `dpistack` без аргументов при отсутствующем `dpistack.conf` показывает меню установки, как `install.sh install` на свежей системе.
5. В меню управления: «Статус компонентов» вызывает `dpistack-ctl status` и построчно показывает результат; «Логи» даёт выбрать компонент номером и вызывает `dpistack-ctl logs <id> -n 200`; «Запустить тесты» вызывает `dpistack-ctl test all`. Недоступный или упавший `dpistack-ctl` показывает причину и возвращает в меню управления, не завершая `dpistack`.
6. «Настроить» из меню управления и команда `dpistack reconfigure` открывают один и тот же экран разделов конфига (5.3); из меню управления на этом экране есть пункт «Назад», при прямом вызове его нет.
7. «Удалить» в меню управления требует ввод слова `удалить`; неверный ввод или пустая строка возвращают в меню без изменений; подтверждённый ввод предлагает выбор обычного удаления или `--purge` и вызывает соответствующий поток из 5.7.
8. Явная команда `dpistack install` (или `install.sh install`) при существующем `dpistack.conf` показывает экран «Найдена установка» с пунктами «настроить», «применить текущий конфиг заново», «открыть меню управления», «выйти» — а не сразу меню управления.
9. Неинтерактивные подкоманды `dpistack status`, `dpistack test bittorrent`, `dpistack logs suricata -n 50` возвращают тот же код завершения и вывод, что прямой вызов `dpistack-ctl` с теми же аргументами.
10. `uninstall` удаляет `/usr/local/sbin/dpistack` и `/usr/local/lib/dpistack/installer/`; после этого `dpistack` в `PATH` не находится.

**Тесты:** `tests/dpistack_cmd.bats` по критериям 2, 3, 4, 6, 7, 9, 10 (заглушки `dpistack-ctl`, ввод из `DPISTACK_INPUT`).

**Не делать:** автодополнение в shell, man-страницу, изменение `PATH` пользователя, что-либо специфичное для оболочки (`zsh`, `fish`).

---

### Слайс 16: панель, сервер, вход, безопасность

**Файлы:** `panel/cmd/panel/main.go`, `panel/internal/{api,auth,ctl,health}/`, минимальная оболочка `panel/web/` (страница входа и пустой Обзор).

**Что делает:** сервер, вход, сессии, CSRF, ограничение по IP, `GET /api/status`. Запускается вручную, установка в слайсе 17.

**Критерии приёмки:**

1. Без сессии любой `/api/*` кроме `POST /api/login` даёт 401.
2. Неверный пароль даёт 401; шестая попытка за 5 минут с одного IP даёт 429.
3. Изменяющий запрос без верного `X-CSRF-Token` даёт 403.
4. Клиент вне `LAN_CIDR` при `lan` и вне `127.0.0.1` при `localhost` получает 403; `X-Forwarded-For` учитывается только от `127.0.0.1`.
5. `GET /api/status` возвращает компоненты из `ctl status` и `health.json`; недоступный `ctl` даёт 502 с понятным текстом.
6. Отключить вход конфигом нельзя (ключа нет).

**Тесты:** `panel/internal/api/*_test.go`, `auth/*_test.go` по критериям 1–5.

**Не делать:** установку, остальные экраны, WebSocket, внешние JS-библиотеки.

---

### Слайс 17: панель, установка и Обзор

**Файлы:** `lib/step_panel.sh`, `templates/dpistack-panel.service.tpl`, `panel/web/` (экран Обзор).

**Что делает:** сборка или установка бинарника по `PANEL_SOURCE`, юнит, установка пароля (5.1), экран Обзор, привязка по `ACCESS_MODE`, проверка бюджета ресурсов.

**Критерии приёмки:**

1. `install.sh` ставит и запускает панель, вход по заданному или сгенерированному паролю работает, сгенерированный пароль показан в отчёте один раз и нигде не хранится в открытом виде.
2. Обзор показывает состояние компонентов и общий `overall` из `health.json`.
3. RSS панели в простое не больше 25 МБ, статика не больше 150 КБ (проверка скриптом в гейте).
4. Юнит содержит `MemoryMax`, `CPUQuota`, не содержит `NoNewPrivileges` и `ProtectSystem`.
5. `PANEL_SOURCE=prebuilt` без готового бинарника даёт код 3 на `preflight`.
6. Повторный запуск: без изменений.

**Тесты:** `tests/panel_step.bats` по критериям 4, 5, 6.

**Не делать:** остальные экраны.

---

### Слайс 18: компоненты и логи

**Что делает:** экран Компоненты (кнопки start/stop/restart/reload с подтверждением), экран Логи (последние N строк и SSE).

**Критерии приёмки:**

1. Кнопка выполняет `ctl` и обновляет статус без перезагрузки страницы.
2. Остановка `panel` из самой панели требует отдельного подтверждения.
3. `GET /api/logs/{id}?lines=5000` даёт 400 (предел 1000).
4. SSE закрывает процесс `ctl logs --follow` при разрыве соединения клиентом (нет висящих процессов).
5. Действие над компонентом, которого нет, даёт 404 и понятное сообщение.

**Тесты:** `panel/internal/api/components_test.go` по критериям 3–5.

**Не делать:** графики, фильтры по уровню логов.

---

### Слайс 19: редактор конфигов

**Что делает:** экран Конфиги: выбор файла из списка, редактор, «Проверить», «Сохранить», «Сохранить и применить», «Откатить».

**Критерии приёмки:**

1. Изменение `suricata.yaml`: «Проверить» возвращает вывод `suricata -T`, «Сохранить» при ошибке проверки не меняет файл.
2. «Сохранить и применить» перезагружает компонент; для `dpistack.conf` запускает `reconfigure`, а тяжёлое изменение показывает как отказ с текстом.
3. «Откатить» возвращает предыдущий бэкап.
4. `GET /api/config/etc-passwd` даёт 404 (имя вне списка), тело `PUT` больше 1 МБ даёт 413.
5. Файл, отредактированный через панель, установщик считает изменённым вручную (правило 5.4).

**Тесты:** `panel/internal/api/config_test.go` по критериям 1–4.

**Не делать:** подсветку синтаксиса, diff между версиями, редактор на Monaco или CodeMirror.

---

### Слайс 20: правила в панели

**Что делает:** экран Правила.

**Критерии приёмки:**

1. Список источников с включением, выключением и добавлением URL.
2. Включение и выключение групп.
3. Отключение правила по `sid` пишет его в `disable.conf`, после обновления правило не загружается.
4. Поиск по `sid` и тексту, до 50 результатов.
5. Кнопка «Обновить сейчас» показывает результат и время последнего обновления; провал обновления показывает причину и оставляет прежний набор.

**Тесты:** `panel/internal/api/rules_test.go` по критериям 3–5.

**Не делать:** редактор отдельных правил вне `local.rules`, импорт наборов из файла.

---

### Слайс 21: события EVE

**Файлы:** `panel/internal/eve/`, экран События.

**Критерии приёмки:**

1. `GET /api/eve?type=alert&limit=50` возвращает не больше 50 последних алертов; `limit=1000` даёт 400.
2. Чтение `eve.json` инкрементальное: после дозаписи одной строки читается только она (тест по смещению).
3. Ротация файла (новый inode или размер меньше смещения) не теряет события и не ломает чтение.
4. Битая или неполная последняя строка пропускается без ошибки.
5. При `EVE_FILE=no` экран показывает, что просмотр недоступен, а не пустой список.
6. SSE `eve/stream` отдаёт только новые события выбранного типа.

**Тесты:** `panel/internal/eve/*_test.go` по критериям 1–4.

**Не делать:** полнотекстовый поиск по всему файлу, экспорт, агрегации.

---

### Слайс 22: метрики, графики

**Файлы:** `panel/internal/metrics/`, экран Метрики.

**Критерии приёмки:**

1. Ряды pps, drops, cpu, rss, размер `eve.json`, диск за 1, 6, 24 часа.
2. После перезапуска панели ряды восстанавливаются из `metrics.json`.
3. Сброс накопительных счётчиков Suricata не даёт отрицательных значений на графике.
4. Кольцо не превышает 24 часа по 30 секунд.
5. Экран показывает недоступные ряды (`EVE_FILE=no`, нет `stats`) пометкой, а не нулём.

**Тесты:** `panel/internal/metrics/*_test.go` по критериям 2–4.

**Не делать:** запросы за произвольный период, сохранение на диск сверх `metrics.json`.

---

### Слайс 23: экспорт `/metrics`

**Что делает:** `GET /metrics` по разделу 4.9, генерация `METRICS_TOKEN` при установке.

**Критерии приёмки:**

1. Без токена и с неверным токеном 401, с верным 200 и `Content-Type: text/plain; version=0.0.4`.
2. Все метрики из 4.9 присутствуют, когда есть данные; `na`-проверки и метрики, зависящие от `EVE_FILE=no` или отсутствия `stats`, не выдаются.
3. Вывод проходит `promtool check metrics`, если он есть, иначе разбор тестовым парсером формата.
4. `METRICS_EXPORT=no` даёт 404.
5. Сброс счётчиков Suricata не даёт отрицательного `dpistack_suricata_drop_ratio`.
6. Токен не попадает в журнал, `dpistack.conf` и вывод `--dry-run`; в отчёте установщика показан вместе со строкой `scrape_config`.
7. Запросы `/metrics` не читают диск чаще раза в секунду.

**Тесты:** `panel/internal/api/metrics_export_test.go` по критериям 1–5, 7.

**Не делать:** `client_golang`, push-режим, дашборды Grafana.

---

### Слайс 24: тесты, оповещения, интерфейсы в панели

**Что делает:** экраны Тесты и Оповещения, добавление и удаление интерфейсов.

**Критерии приёмки:**

1. Кнопки запуска тестов вызывают `POST /api/tests/...`, результат показывается построчно со статусом `pass`, `fail`, `skip` и причиной.
2. «Последний результат» переживает перезапуск панели.
3. Экран Оповещений показывает `events.jsonl`, новые сверху, с фильтром по проверке.
4. Добавление и удаление интерфейса через панель вызывает `ctl iface` и обновляет статус.

**Тесты:** `panel/internal/api/tests_test.go`, `alerts_test.go` по критериям 1–3.

**Не делать:** настройку каналов оповещений из панели (правится через `dpistack.conf` в редакторе), кнопку IPS (слайс 29).

---

### Слайс 25: README и LICENSE

**Что делает:** `README.md`, `LICENSE`, `dpistack.conf.example` сверяется с 4.3.

**Критерии приёмки:**

1. README содержит: что это, топологическое ограничение, модель угроз, быструю установку, пример конфига, описание `install`/`reconfigure`, работу с `ctl`, пример `scrape_config` для Prometheus, VictoriaMetrics и `vmagent`.
2. Все команды из README выполнены руками на чистой Ubuntu LTS, результат совпал.
3. Все ссылки в README открываются.
4. `LICENSE` соответствует выбору владельца (A11).
5. Каждый ключ из `dpistack.conf.example` есть в 4.3, и наоборот.

**Тесты:** проверка критерия 5 скриптом в гейте.

**Не делать:** сайт документации, переводы.

---

### Слайс 26: dnf-семейство, SELinux (после MVP)

**Среда проверки:** Fedora, Rocky или Alma.

**Что делает:** `pkg_*` для dnf, репозитории (COPR/OISF, ntop, EveBox), имена пакетов и юнитов, SELinux-контексты, `firewalld`.

**Критерии приёмки:**

1. Слайсы 2–7 проходят на Fedora и на одном RHEL-совместимом дистрибутиве.
2. При `enforcing` панель, ntopng, EveBox и Suricata стартуют без AVC-отказов для нужных им путей (`restorecon`, `setsebool`, `semanage port`).
3. `FIREWALL_MANAGE=auto` открывает порты только для `LAN_CIDR` через `firewalld`.
4. `PIN_VERSIONS=yes` использует `versionlock`.
5. Отсутствующий источник для выбранной версии ОС даёт код 3 на `preflight`, а не ошибку посреди установки.

**Тесты:** `tests/os.bats` (расширение), `tests/pkg_dnf.bats` по критериям 4, 5.

**Не делать:** CentOS 7 и другие EOL-версии.

---

### Слайс 27: Docker runtime (после MVP)

**Файлы:** `lib/runtime_docker.sh`, `templates/compose.yaml.tpl`.

**Что делает:** любой из `suricata`, `evebox`, `ntopng` (и `redis` за `ntopng`) в контейнере. Suricata с `network_mode: host` и `NET_ADMIN`, `NET_RAW`; общий том с `eve.json`.

**Критерии приёмки:**

1. Смешанная схема (Suricata native, EveBox и ntopng docker) поднимается и видит те же события.
2. `dpistack-ctl status`, `start|stop|restart`, `logs` работают через `docker compose`.
3. `eve.json` из контейнерной Suricata доступен панели и watchdog по тому же пути `/var/log/suricata/eve.json`.
4. Образы и пути томов подтверждены (допущение A6).
5. Правила `DOCKER-USER` и другие чужие правила не затронуты.
6. Значения `*_RUNTIME=docker` перестают отклоняться как `пока не поддерживается`.

**Тесты:** `tests/runtime_docker.bats` по критериям 2, 5, 6 (заглушка `docker`).

**Не делать:** podman, swarm, kubernetes, LXD.

---

### Слайс 28: бэкенд метрик, VictoriaMetrics и Prometheus (после MVP)

**Файлы:** `lib/step_metrics.sh`, `templates/scrape.yaml.tpl`, юниты бэкенда.

**Что делает:** при `METRICS_BACKEND` не `none` ставит VictoriaMetrics (single-node) или Prometheus в `native` или `docker`, кладёт `scrape.yaml` с целью `GET /metrics` панели и токеном из файла, задаёт `METRICS_RETENTION`, привязывает по `ACCESS_MODE`.

**Критерии приёмки:**

1. Бэкенд активен, цель сбора имеет состояние `up`, ряды `dpistack_*` доступны запросом.
2. `METRICS_RETENTION=30d` попадает в параметры запуска бэкенда (`-retentionPeriod` или `--storage.tsdb.retention.time`).
3. Токен читается бэкендом из файла (`bearer_token_file` или `authorization`), в `dpistack.conf` и в командной строке процесса его нет.
4. Бэкенд слушает по правилам `ACCESS_MODE`, при `localhost` только на `127.0.0.1`.
5. Источник бинарника и проверка контрольной суммы для `native` подтверждены (допущение A10).
6. `disk.free` и проверки `<id>.process`/`<id>.port` учитывают бэкенд.
7. Смена `METRICS_BACKEND` через `reconfigure` считается тяжёлым изменением; `none` останавливает бэкенд, но не удаляет данные без `--purge`.
8. Повторный запуск: без изменений.

**Тесты:** `tests/metrics_step.bats` по критериям 2, 3, 4, 7, 8.

**Не делать:** Alertmanager, Grafana, remote write, `vmagent` как отдельный компонент.

---

### Слайс 29: режим IPS (после MVP)

**Что делает:** `dpistack-ctl mode`, шаблон IPS, цепочка `DPISTACK`, `dpistack-fw.service`, таймер отката, кнопка в панели.

**Критерии приёмки:**

1. `mode ips` включает выбранный `IPS_METHOD`, перезапускает Suricata, запускает таймер отката.
2. Без `mode-confirm` за `--confirm-timeout` режим возвращается в `ids`, правила `DPISTACK` убираются.
3. Правила NFQUEUE идут с `--queue-bypass`; остановка Suricata не отрезает сеть.
4. После перезагрузки хоста `dpistack-fw.service` восстанавливает правила `DPISTACK` в текущем режиме.
5. Чужие цепочки и правила не изменены (сравнение `iptables-save` до и после, без `DPISTACK`).
6. В панели переключение в IPS просит подтверждение и показывает обратный отсчёт до отката.
7. Значение `SURICATA_MODE=ips` перестаёт отклоняться как `пока не поддерживается`.

**Тесты:** `tests/ips.bats` по критериям 2, 3, 5, 7 (заглушки `iptables`, `nft`).

**Не делать:** автоматическую генерацию `drop`-правил, перевод `alert` в `drop` за пользователя.

---

### Слайс 30: единый файл (после MVP)

**Что делает:** `scripts/bundle.sh` собирает `dpistack-install.sh` из `install.sh`, `lib/`, `templates/`, `bin/` (встраивание в heredoc), без изменения логики.

**Критерии приёмки:**

1. `dpistack-install.sh --help` и `--dry-run -y` дают тот же вывод, что модульная версия.
2. Собранный файл проходит `bash -n` и `shellcheck`.
3. `bundle.sh --check` в гейте сравнивает собранный файл с тем, что сгенерирует скрипт из текущих исходников.

**Тесты:** `tests/bundle.bats` по критериям 1, 3.

**Не делать:** самообновление, упаковку в deb/rpm.

---

## 18. Ревью после каждого слайса

Отдельным заходом, после того как слайс готов и гейт зелёный. Задача захода: искать проблемы, а не хвалить написанное.

Чек-лист:

1. Ключи конфига, команды `ctl`, поля `health.json`, метрики, эндпоинты совпадают с разделом 4 дословно. Лишних нет.
2. Шаги не вызывают системные команды мимо `run`, пакетные и сервисные операции идут через `os.sh` и `runtime_*.sh`.
3. Все пути строятся через `lib/paths.sh`.
4. Каждый шаг установщика идемпотентен, `--dry-run` не меняет систему, `reconfigure` затрагивает только шаги из таблицы 5.3.
5. `dpistack-ctl` проверяет каждый аргумент по списку до действия. Нет `eval`, нет подстановки пользовательского ввода в строку команды.
6. Секреты (пароль панели, `METRICS_TOKEN`, токен Telegram, SMTP) нигде не печатаются и не пишутся в лог, кроме единственного показа в итоговом отчёте.
7. Панель не запускает ничего кроме `sudo -n dpistack-ctl`, не читает файлы вне списка из раздела 3.
8. Нет ложных ошибок при штатных ситуациях: ротация `eve.json`, сброс счётчиков `stats`, тихий интерфейс без событий.
9. Тесты проверяют критерии приёмки, а не повторяют реализацию. На каждый критерий с отказом есть тест на отказ.
10. Мёртвого кода нет: неиспользуемые функции, шаблоны, ключи схемы, JS-модули, CSS-селекторы без разметки.
11. Файлов и абстракций сверх раздела 3 не появилось.

Находки правятся в том же заходе, потом гейт прогоняется заново.

### 18.1 Результат полного ревью (v7)

Ревью шло по чек-листу выше: автоматические проходы (мёртвый код, пути мимо `paths.sh`, системные команды мимо `run`, неиспользуемые ключи и шаблоны), фаззинг аргументов `dpistack-ctl` (метасимволы, пустые значения, юникод, числа на границах), чтение кода оповещений, `common.sh`, `state.sh`, `schema.sh` и workflow. Каждая находка закрыта тестом из `tests/hardening.bats` или `tests/ci_config.bats`; новые тесты проверены на коде до исправления, там они падают.

| № | Важность | Находка | Исправление |
|---|---|---|---|
| R1 | критическая | `run` всегда возвращал 0: внутри `if ! cmd` `$?` равен результату отрицания, поэтому любой `run ... \|\| return 1` в шагах не срабатывал и сбой установки пакета или сервиса проходил молча | код возврата читается сразу после команды |
| R2 | высокая | `atomic_write` при ошибке записи (диск заполнен) всё равно подменял целевой файл обрезанным | при ошибке временный файл удаляется, цель не меняется |
| R3 | высокая | `state` переписывали без блокировки установщик и watchdog (потеря обновлений: отметки шагов, хэши рендера), ключи сравнивались как регулярные выражения | запись под `flock`, ключи сравниваются как текст |
| R4 | высокая | свободные ключи не проверялись: `LAN_CIDR`, `NGINX_CERT`, `BPF_FILTER`, `HOME_NET`, `IFACES` могли внести директивы в конфиг nginx или YAML, а `TEST_HTTPS_URL` с `-o...` стал бы опцией `curl` (запись файла от root) | шаблоны `SCHEMA_PATTERN` (4.3), `curl` вызывается с `--` |
| R5 | средняя | `config-write dpistack.conf` принимал секретные ключи и оставлял их в файле с правами 0644 | отказ с кодом 3 |
| R6 | средняя | `apt-get install -y` без `DEBIAN_FRONTEND=noninteractive` мог встать на вопросе debconf | `os_detect` выставляет `DEBIAN_FRONTEND` и `NEEDRESTART_MODE` |
| R7 | средняя | `ctl` менял конфиги, не дожидаясь блокировки установщика | `ctl_lock` (ждёт до 30 с) |
| R8 | средняя | `NTOPNG_VERSION` и `EVEBOX_VERSION` описаны в 4.3, но игнорировались | `pkg_spec` фиксирует версию пакета |
| R9 | низкая | `logs -n 08` отвергался (восьмеричная запись), `-n 01750` проходил лимит 1000 | десятичный разбор, не больше шести цифр |
| R10 | низкая | оповещения: токен Telegram не экранировался в конфиге `curl`, список получателей раскрывался глобом, `\r` не вычищался; десятичные значения watchdog зависели от локали | экранирование, `read -a`, `LC_NUMERIC=C` |
| R11 | высокая для CI | `trivy-action@0.28.0` не существует (тег `v0.28.0`): job падал бы; действия не закреплены по SHA; `actionlint` скачивался и пускался в `bash`; тег релиза не проверялся на `main`; SARIF из форка не загрузился бы | см. 12.1 |
| R12 | низкая | три пути определены мимо `lib/paths.sh` (`os-release`, каталог данных `suricata-update`, `libndpi`) | перенесены в `paths.sh` |

Осталось открытым:

- Перед установкой пакетов `apt-get update` вызывается только в шагах `oisf`, `evebox` и `ntopng`. На свежем образе без списков пакетов установка Suricata из дистрибутива может не найти пакет. Решение (общий `apt-get update` один раз за запуск) за владельцем: оно меняет последовательность команд, на которую опираются тесты.
- Смена `*_VERSION` у установленного пакета его не переустанавливает (4.3).
- Ключи `EVE_SYSLOG`, `IPS_METHOD`, `IPS_NFQ_CHAINS`, `METRICS_RETENTION`, `PANEL_SOURCE` описаны в схеме, но код их пока не читает: их слайсы (IPS, метрики, панель) впереди.
- `suricata.eve_fresh` опирается на время изменения `eve.json`, а не на метку последнего события: тихий интерфейс с включёнными `stats` не даёт ложной тревоги, при выключенных `stats` проверка получает `na`.
- Образ `actionlint` указан тегом, не digest.
- Не проверено на стенде: `sudo -n` от пользователя `dpistack`, `suricata -r` с `suricata-test.yaml`, правило `requires: keyword ndpi-protocol` на настоящей сборке, `argon2` на dnf-семействе, запуск workflow на GitHub.

### 18.2 Результат повторного ревью (v8)

Гейт до правок зелёный (223 bats). Каждая находка закрыта тестом в `tests/hardening.bats`; новые тесты падают на прежнем коде.

| № | Важность | Находка | Исправление |
|---|---|---|---|
| R13 | высокая | `atomic_write` отдавал цели права временного файла (0600): `evebox.yaml`, `ntopng.conf`, юниты, `logrotate`, конфиги nginx и Suricata, перерисованные установщиком, теряли права; пакетный EveBox работает от пользователя `evebox` и не читал свой конфиг | существующий файл сохраняет режим и владельца, новый получает 0644, секреты и `state` передают режим явно (`atomic_write <path> [mode]`, так же `dry_run_write` и `write_rendered_file`); `sudoers` пишется сразу с 0440 |
| R14 | высокая | шаги не передавали ошибку `run`: сбой `pkg_install`, добавления репозитория, `systemctl enable --now`, `git`, `openssl`, `ufw` проходил, шаг печатал «готово» или «применено частично», установка заканчивалась кодом 0; `redis` записывал `done` после сбоя | `|| return 1` в шагах `access`, `evebox`, `ntopng`, `redis`, `ndpi`, `suricata`, `rules`, `watch`; `run_apply` останавливается на упавшем шаге |
| R15 | средняя | `ntopng_repo_add` вызывал `add-apt-repository -y universe` на Debian, где такого компонента нет | вызов только при `ID=ubuntu`; сбой загрузки `apt-ntop.deb` останавливает шаг и удаляет временный файл |
| R16 | средняя | `config_snapshot_applied` переписывал `state` без блокировки, которую берут `state_write_value` и watchdog (потеря обновления, R3 закрыт не полностью) | тот же `flock` на `state.lock` |

Не менялось, остаётся открытым:

- `rules_register_sources`: `suricata-update add-source` для уже добавленного источника при повторном `reconfigure` может вернуть ошибку; на стенде не проверено, поэтому сбой не делается фатальным.
- `suricatasc -c ruleset-reload-nonblocking` после обновления правил: при остановленной Suricata ошибка не фатальна, оставлено как есть.
- URL репозитория ntop.org для Debian (`apt/<VERSION_ID>/...`) не проверен на стенде.
- Окно после R14: `check` после `apply` по-прежнему допускает «применено частично» для файла, изменённого вручную (5.4).
