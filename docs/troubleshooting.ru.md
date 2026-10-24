# Диагностика

[English](troubleshooting.md) | Русский

Начните с отчёта: `sudo dpistack diag`. Он собирает платформу, версии, репозитории, конфигурацию без секретов, состояние служб и журналы в stdout и в файл (путь печатается).

| Симптом | Причина и действие |
| --- | --- |
| `the command runs as root only` | `dpistack` и `install.sh` запускаются только от root: `sudo dpistack ...` |
| `port N (KEY) is already busy (held by: ...)` | порт занят другим процессом: выберите свободный порт из подсказки (`--set KEY=порт`, меню или экран «Настройки») либо остановите процесс |
| `KEY=native: ... set --set KEY=docker` | на этой системе нет пакетов компонента: запускайте его в Docker, см. [platforms.md](platforms.ru.md) |
| `systemd is needed` | система без systemd не поддерживается |
| `suricata -T rejected the rendered suricata.yaml` | конфигурация не подошла установленной Suricata; файл на диске не изменён. Причину печатает сама Suricata выше в выводе. Проверьте `suricata -V` и ключи, влияющие на конфигурацию |
| `heavy changes ... need --force` | изменение запускает установку или пересборку: примените с `--force` (или `settings set --apply-heavy`) |
| `applying is already running` | идёт тяжёлая задача `dpistack-apply`: `dpistack settings job` показывает ход |
| IPS вернулся в IDS | переключение не подтверждено за отведённое время: `dpistack mode ips`, затем `dpistack mode-confirm` |
| страница выглядит простой | вы на редакции `lite`: так и задумано; для насыщенной консоли задайте `PANEL_EDITION=full` |
| панель не открывается | `dpistack status`, затем `dpistack logs panel`; проверьте `ACCESS_MODE` и порт панели |
| нет событий | `dpistack status` (Suricata, `eve.json`), `dpistack logs suricata`, интерфейс в `IFACES` и фильтр `BPF_FILTER` |
| правила не обновляются | `dpistack rules-update` печатает причину; прежний набор при ошибке возвращается |

Журналы служб: `dpistack logs <компонент> -n 200`. Один прогон проверок watchdog: `dpistack health`. Проверка, что обнаружение работает: `dpistack test all`.
