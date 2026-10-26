# Эксплуатация

[English](operations.md) | Русский

Все команды запускаются от root (`sudo dpistack ...`). `dpistack` без аргументов открывает меню управления; `dpistack help` печатает полный список команд.

## Состояние и управление

| Команда | Действие |
| --- | --- |
| `dpistack status [--json]` | состояние компонентов; без `--json` ещё и сверка каждого шага установки с конфигурацией |
| `dpistack start\|stop\|restart <компонент>` | управление компонентом |
| `dpistack reload suricata` | перечитать правила без остановки |
| `dpistack logs <компонент> [-n N] [--follow]` | журнал компонента, N до 1000 |
| `dpistack health [--json]` | один прогон watchdog |
| `dpistack test bittorrent\|https\|all [--json]` | проверочные тесты |
| `dpistack diag` | отчёт для разбора проблем: платформа, версии, конфигурация без секретов, службы, журналы |
| `dpistack version` | версия набора |

Компоненты: `suricata`, `evebox`, `ntopng`, `redis`, `victoriametrics`, `prometheus`, `node_exporter`, `grafana`, `panel`, `watch`, `rules`. Хранилище, `node_exporter` и `grafana` существуют, только когда выбраны. Компоненты в Docker управляются теми же командами.

## Настройки

| Команда | Действие |
| --- | --- |
| `dpistack settings list [--json]` | все параметры с текущими значениями; секреты показываются как `(set)` или `(not set)` |
| `dpistack settings check KEY=VALUE...` | проверка без записи: ошибки, вес изменения, занятые порты (JSON) |
| `dpistack settings set [--apply\|--apply-heavy] [--confirm-access] KEY=VALUE...` | записать и применить |
| `dpistack settings secret KEY` | записать секрет (значение со stdin) |
| `dpistack settings job` | ход тяжёлого применения (JSON) |

Пары `KEY=VALUE` можно передать аргументами или построчно через stdin (так делает панель: значения вроде фильтра BPF содержат символы, которые проверка аргументов не пропускает; правила схемы проверяют их в любом случае). Без `--apply` изменение только записывается. Лёгкое изменение с `--apply` применяется сразу; тяжёлое требует `--apply-heavy` и идёт отдельной задачей `dpistack-apply`, за которой следит `settings job`. Смена `ACCESS_MODE` на расширяющий доступ требует `--confirm-access`. Занятый порт отклоняется с указанием процесса и свободного порта.

`dpistack reconfigure --light [--dry-run]` применяет текущий `dpistack.conf` без вопросов и только для лёгких изменений; тяжёлые завершаются кодом 3.

## Конфигурационные файлы

```
dpistack config-read suricata.yaml
dpistack config-write suricata.yaml --check < новый.yaml     # только проверка
dpistack config-write suricata.yaml --apply < новый.yaml     # проверка, резервная копия, применение
dpistack config-revert suricata.yaml                          # вернуть последнюю копию
```

Имена: `suricata.yaml`, `evebox.yaml`, `ntopng.conf`, `dpistack.conf`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf`. Файл, правленный вручную, установщик не перезаписывает без `--force`. Отрисованный `suricata.yaml` проверяется командой `suricata -T` до записи, а ключ `suricata-version` в нём соответствует серии установленной Suricata.

## Правила

```
dpistack rules-update                         # suricata-update с откатом, если suricata -T отклонил набор
dpistack rules-sources list [--enabled]       # enable|disable|add-url|remove <имя>
dpistack rules-group enable|disable <группа>
dpistack rules-sid enable|disable <sid>
dpistack rules-search <запрос>                # до 50 правил по sid или тексту
```

Таймер обновления правил включается ключом `RULES_UPDATE`, расписание задаёт `RULES_UPDATE_CALENDAR`.

## Интерфейсы захвата

```
dpistack iface list
dpistack iface add eth1
dpistack iface remove eth1       # последний интерфейс удалить нельзя
```

## Режим IPS

По умолчанию Suricata работает как IDS: смотрит трафик и ничего не блокирует. `dpistack mode ips` переводит её в IPS: через NFQUEUE (`IPS_METHOD=nfq`, правила в отдельной цепочке `DPISTACK`, которая восстанавливается при загрузке) или парами интерфейсов (`afpacket`). Правила идут с `--queue-bypass`, поэтому остановка Suricata не отрезает сеть. Переключение нужно подтвердить командой `dpistack mode-confirm` за 120 секунд (`--confirm-timeout`, от 10 до 3600): иначе режим сам вернётся в IDS и правила уберутся. `dpistack mode status [--json]` показывает режим, метод и обратный отсчёт. Чужие цепочки и правила не меняются; блокируют трафик ваши правила с действием `drop` (`drop.conf`), сами они не создаются.

## Watchdog и оповещения

Таймер `dpistack-watch` раз в `WATCH_INTERVAL_SEC` проверяет службы, порты, свежесть `eve.json`, потери пакетов, место на диске и возраст правил (пороги `WATCH_*`). Упавший компонент перезапускается не чаще трёх раз в час (`WATCH_AUTORESTART`). Оповещения идут в каналы `ALERT_CHANNELS`: `panel`, `log`, `telegram`, `mail`. Токен Telegram и адрес SMTP хранятся как секреты.

## Метрики

См. раздел «Метрики» в [README.ru.md](../README.ru.md): эндпоинт `/metrics`, токен, готовая запись для `scrape_configs`, встроенное хранилище VictoriaMetrics или Prometheus.

## Стек метрик

Каждая часть выбирается отдельно: в быстрой установке, на экране «Настройки» или `dpistack settings set`:

| Часть | Ключ | Что делает |
| --- | --- | --- |
| хранилище | `METRICS_BACKEND=victoriametrics\|prometheus` | хранит `METRICS_RETENTION` данных и собирает `/metrics` панели |
| node_exporter | `NODE_EXPORTER_ENABLE=yes` | метрики хоста на порту 9100; в `scrape.yaml` хранилища добавляется задание `node` |
| Grafana | `GRAFANA_ENABLE=yes` | дашборды на порту 3030; при наличии хранилища оно настраивается источником данных по умолчанию; первый вход `admin`/`admin` |

`*_RUNTIME` выбирает хост или Docker для каждой части. Все они слушают там, где говорят `BIND_ADDR` и `ACCESS_MODE`; nginx ни одну не проксирует. Бинарники берутся из релизов проектов: node_exporter и хранилища с закреплённым sha256, Grafana с контрольной суммой, которую вендор публикует рядом с архивом. Выключение части останавливает её и оставляет данные.

## Резервные копии

Перед каждой записью конфигурации через `config-write` и `settings set` создаётся резервная копия; `config-revert` возвращает последнюю. Данные компонентов (правила, EveBox, ntopng, метрики) лежат в своих каталогах и удаляются только `uninstall --purge`.
