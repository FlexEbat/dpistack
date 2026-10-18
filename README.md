# dpistack

Установщик и личная панель для домашней или небольшой лаборатории DPI/IDS на одном хосте: **nDPI + Suricata + EveBox + ntopng**. Одна команда ставит компоненты, сторож следит за ними, панель в браузере даёт статус, редактор конфигов, правила, тесты, логи, события и графики. Это не SIEM, не решение для нескольких хостов и не замена промышленного NDR.

Платформы: Ubuntu LTS от 22.04, Debian от 12, Rocky Linux и AlmaLinux от 8 (RHEL и CentOS Stream запускаются с предупреждением). Архитектуры `amd64` и `arm64`. Ставятся только стабильные версии.

Полное описание, решения и журнал ревью: [tech.md](tech.md). Не проверенное на реальном стенде перечислено в [docs/real-test-guide.md](docs/real-test-guide.md).

## Ограничение топологии

Хост видит только трафик своего интерфейса. Пассивный захват (`af-packet`) не покажет остальную сеть, пока трафик не приходит на этот хост: нужны зеркальный порт на коммутаторе, шлюз или включение в разрыв (режим IPS). Хост вне разрыва сети защищает и показывает только себя. Установщик напоминает об этом при выборе интерфейсов.

## Модель угроз

- Редактор конфигов панели равен root-доступу к хосту: правки `suricata.yaml` и запуск компонентов позволяют выполнить чужой код. Взлом панели равен взлому хоста.
- Поэтому по умолчанию `ACCESS_MODE=localhost`, вход по паролю обязателен и не отключается. Режимы `lan` и `nginx` включаются только после явного подтверждения предупреждения.
- Сама панель отдаёт HTTP без TLS. В режиме `lan` пароль и токен `/metrics` видны в сети: используйте `nginx` с TLS или SSH-туннель.
- `eve.json` содержит метаданные трафика (SNI, DNS-имена, адреса), права `0640`, читают Suricata и пользователь `dpistack`.
- Панель работает не от root и привилегированные действия выполняет только через `sudo -n dpistack-ctl`, который сверяет каждый аргумент со списками. Правило `sudoers` разрешает пользователю `dpistack` только этот файл.
- Секреты (`ALERT_TG_TOKEN`, `ALERT_SMTP_URL`, `METRICS_TOKEN`) лежат только в `/etc/dpistack/secrets.conf` (`0600`). Пароль панели хранится как хэш argon2id.

Сообщения об уязвимостях: [SECURITY.md](SECURITY.md).

## Быстрая установка

Нужен root и чистая машина (или снапшот): установщик ставит пакеты и репозитории.

```
git clone https://github.com/FlexEbat/dpistack.git
cd dpistack
sudo ./install.sh install
```

На терминале `install` открывает текстовое меню: «Быстрая установка» спрашивает интерфейсы, способ установки Suricata (`source` даёт плагин nDPI, `oisf` и `distro` ставятся быстрее, но без него), режим доступа и пароль панели, остальные разделы (захват, компоненты, EVE, правила, доступ, метрики, сторож, тесты, пароль панели) открываются по желанию, а `--advanced` спрашивает все ключи. Сама установка стартует отдельным пунктом меню. Без терминала или с `-y` вопросов нет, недостающее берётся из умолчаний:

```
sudo ./install.sh install -y --set IFACES=eth0 --set ACCESS_MODE=localhost
```

Сначала можно посмотреть план, ничего не меняя:

```
sudo ./install.sh install --dry-run -y
```

Итоговый отчёт один раз показывает сгенерированный пароль панели (на диске остаётся только хэш) и, если включён экспорт метрик, токен `/metrics` вместе с готовой записью для `scrape_configs`. Панель слушает `http://127.0.0.1:9800`, EveBox `5636`, ntopng `3000`. С другой машины: `ssh -L 9800:127.0.0.1:9800 user@host`.

Пароль можно задать заранее: `DPISTACK_PANEL_PASSWORD=... sudo -E ./install.sh install -y`.

После установки доступна команда `dpistack` (копия установщика в `/usr/local/sbin`). Без аргументов она открывает меню управления: настройка, статус, логи, тесты, обновление, удаление, пароль панели.

## Конфиг

Файл `/etc/dpistack/dpistack.conf`, формат `KEY=value`, по одному ключу в строке, без кавычек и подстановок. Неизвестный ключ или значение вне вариантов останавливает установщик. Полный список ключей с умолчаниями: [dpistack.conf.example](dpistack.conf.example), описание каждого: tech.md, раздел 4.3. Пример:

```
IFACES=eth0
SURICATA_MODE=ids
ACCESS_MODE=nginx
NGINX_TLS=selfsigned
RULES_GROUPS=emerging-p2p,emerging-policy
WATCH_ENABLE=yes
ALERT_CHANNELS=panel,log,tg
ALERT_TG_CHAT_ID=123456789
METRICS_EXPORT=yes
```

Suricata, EveBox и ntopng (вместе с redis за ним) можно запускать в Docker: `SURICATA_RUNTIME=docker`, `EVEBOX_RUNTIME=docker`, `NTOPNG_RUNTIME=docker`, любая смесь с native. Нужен Docker с плагином `compose`; контейнеры идут с `network_mode: host`, файл `/opt/dpistack/compose/compose.yaml` генерирует установщик, а `dpistack-ctl` управляет ими так же, как службами (`status`, `start|stop|restart`, `logs`). Для Suricata в контейнере задайте `NDPI_ENABLE=no`: плагин nDPI в образ не ставится. Образы и тома пока проверены только на заглушках.

Секреты в этот файл не пишутся: `ALERT_TG_TOKEN` и `ALERT_SMTP_URL` вводятся в меню (или через `--set`) и сохраняются только в `secrets.conf`.

## install, reconfigure, upgrade, uninstall

```
install.sh <команда> [опции]
dpistack [команда] [опции]

команды:  install | reconfigure | upgrade | uninstall | status | diag | test | logs
опции:    --config FILE  --set KEY=VALUE  -y  --advanced  --dry-run
          --only STEP  --skip STEP  --force  --purge  --no-color
```

- `install` идемпотентен: повторный запуск на готовой системе даёт «без изменений». Шаги: `preflight`, `selfinstall`, `ndpi`, `suricata`, `rules`, `redis`, `ntopng`, `evebox`, `metrics`, `access`, `panel`, `watch`, `verify`.
- `reconfigure` применяет изменённый `dpistack.conf`: показывает разницу ключей, определяет затронутые шаги, проверяет новый `suricata.yaml` через `suricata -T` до записи и перезапускает только нужное. Тяжёлые изменения (смена источника, версии) он не делает и просит `install.sh reconfigure`. `--dry-run` показывает разницу и ничего не пишет.
- `upgrade` обновляет пакеты компонентов; закреплённые версии (`PIN_VERSIONS=yes`) не трогает.
- `uninstall` удаляет только созданное самим dpistack; пакеты компонентов остаются. `--purge` удаляет и конфиги с данными.
- `status` печатает по каждому шагу «в порядке» или «расхождение» с причиной, `diag` собирает отчёт для разбора проблем.

Код возврата: `0` успех, `1` ошибка шага, `2` неверные аргументы или конфиг, `3` preflight не пройден или изменение не поддерживается.

## dpistack-ctl

Единственная точка привилегированных действий для панели и сторожа; администратор тоже может пользоваться ею от root.

```
dpistack-ctl status --json            состояние компонентов
dpistack-ctl restart suricata         start | stop | restart <компонент>
dpistack-ctl reload suricata          перечитать правила без остановки
dpistack-ctl logs evebox -n 200       журнал компонента (до 1000 строк), --follow
dpistack-ctl config-read suricata.yaml
dpistack-ctl config-write suricata.yaml --check   проверить stdin, ничего не записывая
dpistack-ctl rules-update             suricata-update, проверка, перезагрузка, откат при ошибке
dpistack-ctl iface add eth1           список интерфейсов захвата, затем reconfigure
dpistack-ctl test all --json          проверка BitTorrent и HTTPS
dpistack-ctl health --json            один прогон сторожа
```

Полный список команд и допустимых аргументов: tech.md, раздел 4.5.

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

Установка VictoriaMetrics или Prometheus самим установщиком (`METRICS_BACKEND`) пока не поддерживается: по умолчанию `METRICS_BACKEND=none`, сбор настраиваете вы.

## Разработка

```
sudo apt-get install -y shfmt shellcheck bats jq argon2
bash scripts/gate.sh
```

Гейт запускает `shfmt`, `shellcheck`, проверки безопасности, `bats` и, если есть Go, `gofmt`, `go vet`, `go test` и проверку бюджета ресурсов панели. Ветка `dev` для работы, `main` для проверенного состояния; слияние в `main` идёт через pull request после зелёного гейта. Подробнее: tech.md, разделы 12 и 17.

Лицензия: [MIT](LICENSE).
