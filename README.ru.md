<div align="center">

# dpistack

**Глубокий анализ пакетов и обнаружение вторжений на одном Linux-хосте, настраиваемые одной командой.**

nDPI · Suricata · EveBox · ntopng · по желанию Prometheus или VictoriaMetrics, Grafana и node_exporter; всё управляется из одной командной строки и одной веб-панели.

[![CI](https://github.com/FlexEbat/dpistack/actions/workflows/ci.yml/badge.svg)](https://github.com/FlexEbat/dpistack/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) | Русский

</div>

---

## Зачем dpistack

Собрать стек анализа трафика вручную значит поставить десяток пакетов, подключить три репозитория, править `suricata.yaml`, настроить обновление правил, запустить службы в нужном порядке и остаться без сигнала, когда что-то тихо перестало работать. dpistack берёт это на себя:

- **Одна команда ставит всё.** `dpistack` задаёт несколько вопросов (или ни одного с `-y`), ставит компоненты, рисует согласованные конфиги, запускает службы и проверяет, что обнаружение действительно работает.
- **Одна панель управляет.** Веб-панель показывает, что работает, а что нет, меняет любые параметры с проверкой, правит конфиги с откатом, управляет правилами, показывает журналы и события и запускает проверочные тесты.
- **Следит за собой.** Watchdog проверяет службы, порты, потери пакетов, диск и возраст правил и сообщает через панель, журнал, Telegram или почту.
- **Не привязывает к себе.** Каждый компонент работает на хосте или в Docker в любых сочетаниях; всё лежит обычными файлами в `/etc` и `/var/lib`.

## Что вы получаете

| Компонент | Что делает |
| --- | --- |
| **Suricata** + **nDPI** | движок: IDS или IPS, с определением приложений (BitTorrent, имена TLS и другое) |
| **EveBox** | просмотр и разбор алертов и событий Suricata |
| **ntopng** (+ Redis) | живой трафик, хосты и потоки |
| **Панель** | веб-интерфейс управления в двух редакциях: `full` и `lite` |
| **Watchdog** | проверки состояния, оповещения, автоперезапуск по желанию |
| **Prometheus** или **VictoriaMetrics** (по желанию) | хранилище метрик, собирающее данные с панели |
| **Grafana** (по желанию) | дашборды, хранилище подключено как источник данных по умолчанию |
| **node_exporter** (по желанию) | процессор, память, диск и сеть хоста |

```
                    ┌────────────────────── один хост ───────────────────────┐
  сетевой трафик ──▶│  Suricata (+ nDPI) ──▶ eve.json ──▶ EveBox             │
  (зеркало, шлюз    │        │                  │                            │
   или в разрыв)    │        ▼                  ▼                            │
                    │  обновление правил   Панель ◀── Watchdog ──▶ оповещения│
                    │  ntopng + Redis        │  /metrics                     │
                    │                        ▼                               │
                    │      Prometheus | VictoriaMetrics ──▶ Grafana          │
                    │                   node_exporter ──┘                    │
                    └────────────────────────────────────────────────────────┘
```

## Quick install

Нужны root и чистая машина (или снимок): установщик ставит пакеты и репозитории.

```
git clone https://github.com/FlexEbat/dpistack.git
cd dpistack
sudo ./install.sh              # меню (то же, что sudo ./install.sh install)
sudo ./install.sh --fast       # короткий опрос вместо пошаговой настройки
```

На терминале откроется меню и сначала предложит пошаговую настройку, которая спросит все применимые настройки. Клавиша `m` в меню позволяет выбрать части по одной (Suricata, nDPI, правила, EveBox, ntopng, панель, сторож, Grafana, node_exporter); каждое действие просит подтверждения, на каждом экране есть выход. Быстрая установка спрашивает только главное: интерфейсы захвата, способ получить Suricata, кому открывать панели (и на каком адресе), необязательный стек метрик и какую панель ставить. Остальное остаётся по умолчанию. Без терминала или с `-y` вопросов нет:

```
sudo ./install.sh install -y --set IFACES=eth0 --set PANEL_EDITION=lite
sudo ./install.sh install --dry-run -y        # показать план, ничего не менять
```

В конце вы получите отчёт с адресами, результатами проверочных тестов и один раз сгенерированным паролем панели (на диске остаётся только хэш). По умолчанию панель слушает `http://127.0.0.1:9800`, EveBox `5636`, ntopng `3000`; с другой машины используйте SSH-туннель: `ssh -L 9800:127.0.0.1:9800 user@host`. Весь установщик есть и одним файлом, `dpistack-install.sh`. Подробнее: [docs/installation.ru.md](docs/installation.ru.md).

**Требования:** Linux с systemd, root, `amd64` или `arm64`. Проверенные платформы: Ubuntu LTS от 22.04, Debian от 12, Rocky Linux и AlmaLinux от 8. Любой другой дистрибутив с systemd работает с компонентами в Docker ([docs/platforms.ru.md](docs/platforms.ru.md)).

## Выберите свою конфигурацию

| Выбор | Варианты | Ключ |
| --- | --- | --- |
| Какая панель | `full` (насыщенная тёмная консоль с тихим фоном из частиц) или `lite` (те же функции на простой светлой странице для небольших хостов) | `PANEL_EDITION` |
| Кто может открывать панели | `localhost` (только эта машина, по умолчанию), `lan` (ваша сеть) или `nginx` (обратный прокси, по желанию с TLS) | `ACCESS_MODE` |
| На каком адресе | `auto` или один адрес этого хоста из списка, который печатает установщик (например `192.168.1.156` на `enp2s0`) | `BIND_ADDR` |
| Где работает каждый компонент | хост или Docker независимо для Suricata, EveBox, ntopng, хранилища метрик, Grafana, node_exporter и панели | `*_RUNTIME` |
| Стек метрик | хранилище (`prometheus` или `victoriametrics`), Grafana и node_exporter, каждое выбирается отдельно | `METRICS_BACKEND`, `GRAFANA_ENABLE`, `NODE_EXPORTER_ENABLE` |
| Режим Suricata | `ids` (только наблюдение) или `ips` (может блокировать), переключается в любой момент | `SURICATA_MODE` |

Каждый параметр описан в [docs/configuration.ru.md](docs/configuration.ru.md).

## Панель

Десять экранов: Overview, Components, Settings, Configs, Rules, Logs, Events, Metrics, Tests и Alerts. Экран Settings строится из той же схемы, что и установщик, поэтому показывает каждый параметр, проверяет его перед применением, отмечает изменения, запускающие пересборку, и предупреждает о занятых портах, предлагая свободный. У обеих редакций совершенно одинаковые функции. Подробнее: [docs/dashboard.ru.md](docs/dashboard.ru.md).

## Адрес прослушивания и доступ

По умолчанию всё слушает `127.0.0.1`. Чтобы открыть панели из своей сети, либо выберите `ACCESS_MODE=lan` (все адреса), либо оставьте `ACCESS_MODE=localhost` и задайте `BIND_ADDR` одним адресом этого хоста: службы тогда слушают только на нём, а панель пускает клиентов из `LAN_CIDR`. Всё, что шире loopback, требует явного подтверждения. О занятом порте сообщается с именем держащего его процесса и свободным портом на выбор. Подробнее: [docs/deployment.ru.md](docs/deployment.ru.md).

## Режим IPS

По умолчанию Suricata работает как IDS: наблюдает и ничего не блокирует. `dpistack mode ips` (или кнопка «Enable IPS») превращает её в IPS: через NFQUEUE (`IPS_METHOD=nfq`, правила в отдельной цепочке `DPISTACK`, которая восстанавливается при загрузке) или парами интерфейсов (`afpacket`). Правила используют `--queue-bypass`, поэтому остановка Suricata не режет сеть. Переключение нужно подтвердить командой `mode-confirm` (кнопка «Confirm IPS») за 120 секунд (`--confirm-timeout`, от 10 до 3600): иначе режим сам вернётся в IDS. Чужие цепочки и правила не трогаются. Блокируют ваши правила с действием `drop` (`drop.conf`); сами они не создаются.

## Метрики

Панель отдаёт `GET /metrics` в формате Prometheus с токеном в заголовке `Authorization: Bearer` (`METRICS_EXPORT=yes` по умолчанию; токен создаётся при установке):

```
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9800/metrics
```

По умолчанию `METRICS_BACKEND=none`: есть только эндпоинт, а сборщик вы приносите свой. Запись для `scrape_configs` (Prometheus и VictoriaMetrics; при `ACCESS_MODE=nginx` с TLS схема `https`):

```yaml
scrape_configs:
  - job_name: dpistack
    metrics_path: /metrics
    scheme: http
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/dpistack.token
    static_configs:
      - targets: ['127.0.0.1:9800']
```

Для `vmagent` возьмите тот же блок `scrape_configs` в файле из флага `-promscrape.config` и добавьте `-remoteWrite.url` с адресом вашей VictoriaMetrics.

Или доверьте всё установщику: выберите хранилище (`METRICS_BACKEND=victoriametrics` или `prometheus`) и по желанию **Grafana** (`GRAFANA_ENABLE=yes`, порт 3030, хранилище настраивается источником данных по умолчанию, первый вход `admin`/`admin`) и **node_exporter** (`NODE_EXPORTER_ENABLE=yes`, порт 9100, его опрашивает хранилище). Каждое выбирается отдельно. Хранилище держит `METRICS_RETENTION` данных (число с `h`, `d`, `w` или `y`, по умолчанию `30d`). Смена или выключение части останавливает её и оставляет данные; удаляет данные только `uninstall --purge`.

## Повседневные команды

После установки `dpistack` доступна в `PATH`. Без аргументов она открывает меню управления.

```
dpistack status [--json]                  # компоненты и шаги установки
dpistack start|stop|restart <компонент>
dpistack logs <компонент> [-n N] [--follow]
dpistack settings list|check|set|secret|job
dpistack reconfigure                      # применить dpistack.conf
dpistack upgrade | uninstall [--purge]
dpistack self-update [--check]            # update dpistack itself from its latest release
dpistack rules-update | rules-sources | rules-group | rules-sid | rules-search
dpistack iface list|add|remove
dpistack mode ids|ips | mode-confirm
dpistack test bittorrent|https|all
dpistack diag                             # отчёт для разбора проблем
```

Все команды: [docs/operations.ru.md](docs/operations.ru.md). Параметры лежат в `/etc/dpistack/dpistack.conf`, секреты отдельно в `/etc/dpistack/secrets.conf` (`0600`); пример в [dpistack.conf.example](dpistack.conf.example). Лёгкое изменение применяется сразу, тяжёлое (установка или пересборка) идёт отдельной задачей.

## Ограничение топологии

Хост видит только трафик своего интерфейса. Пассивный захват (`af-packet`) не покажет остальную сеть, если этот трафик не приходит на хост: нужен зеркальный порт на коммутаторе, шлюз или включение в разрыв (режим IPS). Хост вне пути трафика защищает и показывает только себя. Установщик напоминает об этом при выборе интерфейсов.

## Модель угроз

- Редактор конфигов панели равен root-доступу к хосту: правки `suricata.yaml` и запуск компонентов позволяют выполнить чужой код. Взлом панели равен взлому хоста.
- Поэтому по умолчанию `ACCESS_MODE=localhost`, вход по паролю обязателен и не отключается. Режимы `lan` и `nginx`, как и любой адрес кроме loopback, включаются только после явного подтверждения предупреждения.
- Сама панель отдаёт HTTP без TLS. В режиме `lan` пароль и токен `/metrics` видны в сети: используйте `nginx` с TLS или SSH-туннель.
- `eve.json` содержит метаданные трафика (SNI, DNS-имена, адреса), права `0640`.
- Команды `dpistack` запускаются только от root. Панель работает не от root и доходит лишь до глаголов управления через `sudo -n dpistack <команда>`; каждый аргумент сверяется со списками.
- Секреты (`ALERT_TG_TOKEN`, `ALERT_SMTP_URL`, `METRICS_TOKEN`) лежат только в `/etc/dpistack/secrets.conf`. Пароль панели хранится как хэш argon2id.

О найденных уязвимостях сообщайте по [SECURITY.md](SECURITY.md).

## Документация

README и руководства есть на английском и русском (`*.ru.md`).

| Документ | О чём |
| --- | --- |
| [docs/installation.ru.md](docs/installation.ru.md) | установка, обновление, удаление, занятые порты |
| [docs/configuration.ru.md](docs/configuration.ru.md) | справочник всех параметров `dpistack.conf` |
| [docs/runtimes.ru.md](docs/runtimes.ru.md) | Docker или нативно: что где может работать и как части находят друг друга |
| [docs/dashboard.ru.md](docs/dashboard.ru.md) | панель: экраны, редакции, настройки, безопасность |
| [docs/deployment.ru.md](docs/deployment.ru.md) | runtime, панель в Docker, доступ и адрес прослушивания |
| [docs/platforms.ru.md](docs/platforms.ru.md) | поддерживаемые дистрибутивы |
| [docs/operations.ru.md](docs/operations.ru.md) | команды, правила, IPS, watchdog, стек метрик |
| [docs/troubleshooting.ru.md](docs/troubleshooting.ru.md) | типичные сообщения и что делать |
| [tech.md](tech.md) | спецификация, контракты и история проекта (на английском) |
| [CONTRIBUTING.md](CONTRIBUTING.md), [AGENTS.md](AGENTS.md) | разработка (на английском) |

## Разработка

```
bash scripts/gate.sh
```

Гейт запускает `shfmt`, `shellcheck`, проверки безопасности, `bats` и, если есть Go, `gofmt`, `go vet`, `go test`, тесты интерфейса и проверку бюджета ресурсов панели. Ветка `dev` для работы, `main` для проверенного состояния; выпуски это теги `vX.Y.Z` на `main`. См. [CONTRIBUTING.md](CONTRIBUTING.md).

Лицензия: [MIT](LICENSE).
