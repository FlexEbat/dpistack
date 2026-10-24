# dpistack

[English](README.md) | Русский

Установщик и панель управления для лаборатории DPI/IDS на одном хосте: **nDPI + Suricata + EveBox + ntopng**. Одна команда `dpistack` ставит стек, настраивает его и обслуживает; веб-панель показывает состояние и меняет любые параметры без командной строки.

## Возможности

- **Одна команда `dpistack`.** Установка, обновление, удаление, управление службами, правила, интерфейсы, режим IDS/IPS, проверочные тесты и настройки: всё в одной программе (`dpistack help`). Запускается только от root.
- **Две панели на выбор.** `PANEL_EDITION=full`: насыщенная тёмная консоль с тихим фоном из частиц; `lite`: та же панель со всеми функциями на простой лёгкой странице для небольших хостов. Панель показывает состояние компонентов, **все параметры стека** на экране «Настройки» (с проверкой перед применением), редактор конфигов с откатом, правила, журналы, события, метрики, оповещения. Подробнее: [docs/dashboard.ru.md](docs/dashboard.ru.md).
- **Любое сочетание развёртывания.** Suricata, EveBox, ntopng, хранилище метрик и сама панель независимо запускаются на хосте или в Docker. Подробнее: [docs/deployment.md](docs/deployment.ru.md).
- **Любой Linux с systemd.** Ubuntu, Debian, Rocky, Alma, Fedora, RHEL на хосте или в Docker; openSUSE, Arch и любые другие дистрибутивы с компонентами в Docker. Подробнее: [docs/platforms.md](docs/platforms.ru.md).
- **Занятые порты.** Предупреждение с именем процесса и предложением свободного порта; можно выбрать другой.
- **Проверка конфигурации.** Отрисованный `suricata.yaml` соответствует серии установленной Suricata и проверяется `suricata -T` до записи.

## Документация

| Документ | О чём |
| --- | --- |
| [docs/installation.md](docs/installation.ru.md) | установка, обновление, удаление, занятые порты |
| [docs/configuration.md](docs/configuration.ru.md) | справочник всех параметров `dpistack.conf` |
| [docs/dashboard.md](docs/dashboard.ru.md) | экраны панели, настройки, безопасность |
| [docs/deployment.md](docs/deployment.ru.md) | runtime каждого компонента, панель в Docker, режимы панели, доступ |
| [docs/platforms.md](docs/platforms.ru.md) | поддерживаемые дистрибутивы |
| [docs/operations.md](docs/operations.ru.md) | команды, настройки, правила, IPS, watchdog, метрики |
| [docs/troubleshooting.md](docs/troubleshooting.ru.md) | типичные сообщения и что делать |
| [tech.md](tech.ru.md) | спецификация, контракты, журнал решений |
| [CONTRIBUTING.md](CONTRIBUTING.ru.md), [AGENTS.md](AGENTS.ru.md) | разработка |
| [SECURITY.md](SECURITY.ru.md) | сообщения об уязвимостях |

## Ограничение топологии

Хост видит только трафик своего интерфейса. Пассивный захват (`af-packet`) не покажет остальную сеть, пока трафик не приходит на этот хост: нужны зеркальный порт на коммутаторе, шлюз или включение в разрыв (режим IPS). Хост вне разрыва сети защищает и показывает только себя. Установщик напоминает об этом при выборе интерфейсов.

## Модель угроз

- Редактор конфигов панели равен root-доступу к хосту: правки `suricata.yaml` и запуск компонентов позволяют выполнить чужой код. Взлом панели равен взлому хоста.
- Поэтому по умолчанию `ACCESS_MODE=localhost`, вход по паролю обязателен и не отключается. Режимы `lan` и `nginx` включаются только после явного подтверждения предупреждения.
- Сама панель отдаёт HTTP без TLS. В режиме `lan` пароль и токен `/metrics` видны в сети: используйте `nginx` с TLS или SSH-туннель.
- `eve.json` содержит метаданные трафика (SNI, DNS-имена, адреса), права `0640`, читают Suricata и пользователь `dpistack`.
- Команды `dpistack` запускаются только от root. Панель работает не от root и привилегированные действия выполняет только через `sudo -n dpistack <команда>`: `dpistack` пускает пользователя панели лишь к командам управления (не к `install`, `upgrade`, `uninstall`) и сверяет каждый аргумент со списками. Правило `sudoers` разрешает пользователю `dpistack` только этот файл.
- Секреты (`ALERT_TG_TOKEN`, `ALERT_SMTP_URL`, `METRICS_TOKEN`) лежат только в `/etc/dpistack/secrets.conf` (`0600`). Пароль панели хранится как хэш argon2id.

Сообщения об уязвимостях: [SECURITY.md](SECURITY.ru.md).

## Быстрая установка

Нужен root и чистая машина (или снапшот): установщик ставит пакеты и репозитории.

```
git clone https://github.com/FlexEbat/dpistack.git
cd dpistack
sudo ./install.sh install
```

На терминале откроется меню (оно спросит, какую панель ставить: `full` или `lite`); без терминала или с `-y` вопросов нет:

```
sudo ./install.sh install -y --set IFACES=eth0 --set ACCESS_MODE=localhost --set PANEL_EDITION=lite
sudo ./install.sh install --dry-run -y     # только план
```

Итоговый отчёт один раз показывает сгенерированный пароль панели (на диске остаётся только хэш). Панель слушает `http://127.0.0.1:9800`, EveBox `5636`, ntopng `3000`; с другой машины: `ssh -L 9800:127.0.0.1:9800 user@host`. Одним файлом: `dpistack-install.sh`. Подробности: [docs/installation.md](docs/installation.ru.md).

## Конфиг

Параметры лежат в `/etc/dpistack/dpistack.conf` (формат `KEY=VALUE`), секреты отдельно в `/etc/dpistack/secrets.conf` (`0600`). Пример: [dpistack.conf.example](dpistack.conf.example), справочник: [docs/configuration.md](docs/configuration.ru.md). Менять параметры можно на экране «Настройки», командой `dpistack settings set` или через `dpistack reconfigure`; лёгкое изменение применяется сразу, тяжёлое (установка или пересборка компонента) отдельной задачей.

## Команды

После установки доступна `dpistack` (копия установщика в `/usr/local/sbin`). Без аргументов она открывает меню управления.

```
dpistack status [--json]                 # компоненты и шаги установки
dpistack start|stop|restart <компонент>
dpistack logs <компонент> [-n N] [--follow]
dpistack settings list|check|set|secret|job
dpistack reconfigure                     # применить dpistack.conf
dpistack upgrade | uninstall [--purge]
dpistack rules-update | rules-sources | rules-group | rules-sid | rules-search
dpistack iface list|add|remove
dpistack mode ids|ips | mode-confirm
dpistack test bittorrent|https|all
dpistack diag
```

Старое имя `dpistack-ctl` осталось символической ссылкой на `dpistack` для служб, созданных прежними версиями. Все команды: [docs/operations.md](docs/operations.ru.md).

## Режим IPS

По умолчанию Suricata работает как IDS: смотрит трафик и ничего не блокирует. `dpistack mode ips` (или кнопка «Включить IPS» на экране «Компоненты») переводит её в IPS: через NFQUEUE (`IPS_METHOD=nfq`, правила в отдельной цепочке `DPISTACK`, которая восстанавливается при загрузке) или парами интерфейсов (`afpacket`). Правила идут с `--queue-bypass`, поэтому остановка Suricata не отрезает сеть. Переключение нужно подтвердить командой `mode-confirm` (кнопкой «Подтвердить IPS») за 120 секунд (`--confirm-timeout`, от 10 до 3600): иначе режим сам вернётся в IDS и правила уберутся. Чужие цепочки и правила не меняются. Решения о блокировке принимают ваши правила с действием `drop` (`drop.conf`), сами они не создаются. Хост вне разрыва сети защищает только себя.

## Метрики

Панель отдаёт `GET /metrics` в формате Prometheus с токеном в заголовке `Authorization: Bearer` (`METRICS_EXPORT=yes` по умолчанию, токен создаётся при установке). Пример `curl`:

```
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9800/metrics
```

Запись для `scrape_configs` (Prometheus и VictoriaMetrics; при `ACCESS_MODE=nginx` с TLS схема `https`, а адрес и порт это те, которыми вы открываете панель):

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

`credentials_file` держит токен вне конфига. Установщик в итоговом отчёте печатает ту же запись с `credentials: <токен>` вместо файла. Для `vmagent` берите тот же блок `scrape_configs` в файле, который указан флагом `-promscrape.config`, и добавьте `-remoteWrite.url` с адресом вашей VictoriaMetrics; одиночная VictoriaMetrics принимает такой файл флагом `-promscrape.config` сама.

По умолчанию `METRICS_BACKEND=none`: есть только эндпоинт, сбор настраиваете вы. Можно поручить это установщику: `METRICS_BACKEND=victoriametrics` или `prometheus` (бинарник с релиза проекта с проверкой sha256, либо контейнер при `METRICS_BACKEND_RUNTIME=docker`). Он кладёт `scrape.yaml` с этой целью, читает токен из файла, держит данные `METRICS_RETENTION` (число с суффиксом `h`, `d`, `w` или `y`, по умолчанию `30d`) в `/var/lib/dpistack-metrics` и слушает по правилам `ACCESS_MODE` (при `localhost` только на `127.0.0.1`; порт `METRICS_BACKEND_PORT`, по умолчанию 8428 и 9090). Смена бэкенда или `none` останавливает прежний и оставляет его данные, их удаляет только `uninstall --purge`.

## Разработка

```
bash scripts/gate.sh
```

Гейт запускает `shfmt`, `shellcheck`, проверки безопасности, `bats` и, если есть Go, `gofmt`, `go vet`, `go test`, тесты интерфейса и проверку бюджета ресурсов панели. Ветка `dev` для работы, `main` для проверенного состояния; слияние в `main` идёт через pull request после зелёного гейта. Подробнее: [CONTRIBUTING.md](CONTRIBUTING.ru.md), [AGENTS.md](AGENTS.ru.md), tech.md (разделы 12 и 17).

Лицензия: [MIT](LICENSE).
