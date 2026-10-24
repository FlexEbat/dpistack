# Варианты развёртывания

[English](deployment.md) | Русский

Каждый из компонентов запускается независимо либо на хосте (`native`), либо в контейнере Docker (`docker`):

| Ключ | Компонент |
| --- | --- |
| `SURICATA_RUNTIME` | Suricata |
| `EVEBOX_RUNTIME` | EveBox |
| `NTOPNG_RUNTIME` | ntopng (redis за ним идёт следом) |
| `METRICS_BACKEND_RUNTIME` | хранилище метрик (VictoriaMetrics или Prometheus) |
| `PANEL_RUNTIME` | панель управления |

Допустимы все 32 сочетания; единственное ограничение: при `SURICATA_RUNTIME=docker` в образ не ставится плагин nDPI, задайте `NDPI_ENABLE=no`. Нужен Docker с плагином `compose`.

## Примеры

Панель в контейнере, Suricata на хосте:

```
sudo dpistack install -y --set PANEL_RUNTIME=docker
```

Suricata в контейнере, панель на хосте:

```
sudo dpistack install -y --set SURICATA_RUNTIME=docker --set NDPI_ENABLE=no
```

Всё в контейнерах:

```
sudo dpistack install -y --set SURICATA_RUNTIME=docker --set EVEBOX_RUNTIME=docker \
  --set NTOPNG_RUNTIME=docker --set PANEL_RUNTIME=docker --set NDPI_ENABLE=no
```

Переключение runtime у уже установленного компонента: меняется ключ (экран «Настройки» или `dpistack settings set --apply-heavy`), прежний вариант останавливается, новый создаётся.

## Как устроены контейнеры

Файл `/opt/dpistack/compose/compose.yaml` создаёт установщик; управлять контейнерами вручную не нужно: `dpistack status|start|stop|restart|logs` работают с ними так же, как со службами. Контейнеры идут с `network_mode: host`, поэтому порты и правила доступа (`ACCESS_MODE`) те же, что у служб на хосте.

### Панель в контейнере

- Образ `dpistack-panel:<хэш бинарника>` собирается на хосте командой `docker build` из каталога, в котором лежат только бинарник панели и Dockerfile на основе `alpine`. Новый бинарник даёт новый образ, прежний не пересобирается.
- Контейнер запускается с `pid: host` и `privileged: true`: команды управления панель выполняет на хосте через `nsenter -t 1 -m -u -i -n -p`, как `dpistack` от root. Контейнер называет себя в переменной `DPISTACK_CALLER=panel`, и `dpistack` пускает его только к командам управления (без `install`, `upgrade`, `uninstall`).
- Файлы подключаются по тем же путям, что на хосте: `/etc/dpistack` (только чтение), `/var/lib/dpistack`, `/var/log/suricata`, `/var/lib/suricata`, `/var/lib/evebox` (только чтение).
- Юнит `dpistack-panel.service` при этом не используется и удаляется; при возврате к `native` контейнер удаляется, юнит создаётся заново.

Панель с привилегиями root на хосте: так же, как и при запуске через `sudo`, взлом панели равен взлому хоста. Ограничение по `DPISTACK_CALLER` защищает от ошибок, а не от злоумышленника с доступом к контейнеру.

## Редакция панели

`PANEL_EDITION`: `full` (по умолчанию) или `lite`. Она не меняет возможности панели, только страницу, которую она отдаёт: `full` это насыщенная тёмная консоль с фоном из частиц, `lite` простая светлая страница для небольших хостов (см. [dashboard.ru.md](dashboard.ru.md)). У юнита панели нет `MemoryMax` и `CPUQuota`, ни в контейнере, ни на хосте, а число открытых потоков журналов равно 4. Редакция переключается на экране «Настройки» или `dpistack settings set --apply PANEL_EDITION=lite`.

Старый `dpistack.conf` с `PANEL_MODE` (переключатель limited/unlimited прежних версий) продолжает загружаться: ключ игнорируется.

## Доступ и порты

`ACCESS_MODE`: `localhost` (по умолчанию, только с этой машины), `lan` (сеть `LAN_CIDR`, по умолчанию определяется по интерфейсу) и `nginx` (nginx проксирует панель, EveBox и ntopng, опционально с TLS: `NGINX_TLS=selfsigned|existing`). Режимы `lan` и `nginx` включаются только после явного подтверждения. Порты: панель 9800, EveBox 5636, ntopng 3000; занятый порт даёт предупреждение и выбор другого (см. [installation.md](installation.ru.md)).
