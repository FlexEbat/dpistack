# Russian texts for docs/configuration.ru.md: "group:<id>|<title>" and "<KEY>|<hint>".
# The English ones live in panel/web/modules/settings-model.js.
group:capture|Захват трафика
group:components|Компоненты и установка
group:eve|События и хранение
group:rules|Правила
group:access|Доступ и порты
group:metrics|Метрики
group:watch|Контроль и оповещения
group:tests|Проверочные тесты
SURICATA_RUNTIME|Где работает Suricata: на хосте или в контейнере Docker.
SURICATA_ENABLE|Установить и запускать Suricata (движок IDS/IPS).
RULES_ENABLE|Установить правила и их автообновление (нужна Suricata).
EVEBOX_ENABLE|Установить EveBox, просмотр оповещений.
NTOPNG_ENABLE|Установить ntopng, монитор трафика, вместе с Redis.
PANEL_ENABLE|Установить эту панель управления.
EVEBOX_RUNTIME|Где работает EveBox: на хосте или в контейнере Docker.
NTOPNG_RUNTIME|Где работает ntopng: на хосте или в контейнере Docker.
SURICATA_SOURCE|Откуда берётся Suricata: пакет дистрибутива, пакет OISF или сборка из исходников.
SURICATA_VERSION|Закреплённая версия Suricata. Пусто: последняя стабильная.
NDPI_ENABLE|Определение приложений по nDPI в Suricata.
NDPI_SOURCE|nDPI из пакета или сборкой из исходников.
NDPI_VERSION|Закреплённая версия nDPI. Пусто: последняя стабильная.
NTOPNG_VERSION|Закреплённая версия ntopng.
EVEBOX_VERSION|Закреплённая версия EveBox.
PIN_VERSIONS|Закрепить установленные версии, чтобы обновление системы их не меняло.
SURICATA_MODE|ids только наблюдает, ips может блокировать. Переключение лучше делать на экране «Компоненты».
IFACES|Интерфейсы, с которых Suricata снимает трафик, через запятую.
BPF_FILTER|Фильтр BPF: какой трафик не анализировать или анализировать. Примеры: not port 22, host 10.0.0.5, net 192.168.0.0/16 and not port 53. Пусто: весь трафик.
CAPTURE_THREADS| Потоков захвата на интерфейс: auto (по числу очередей приёма) или число. Увеличьте, если растёт доля потерь, а CPU свободны.
CAPTURE_TPACKET| Версия кольца AF_PACKET: auto (решает Suricata), v2 или v3. v3 быстрее на загруженных каналах; IPS через AF_PACKET требует v2.
CAPTURE_RING_SIZE| Кадров в кольце захвата каждого потока. 0: значение Suricata. Увеличьте (например, 8192) при потерях пакетов всплесками.
CAPTURE_BLOCK_SIZE| Размер блока кольца v3 в байтах. 0: значение Suricata; иначе кратное 4096, от 32768.
CAPTURE_CPUS| Процессоры для рабочих потоков детектирования, например 2-5,8. Пусто: решает система.
NIC_OFFLOADS_OFF| Отключать GRO, LRO, GSO и TSO на интерфейсах захвата перед каждым запуском Suricata. Они склеивают пакеты и мешают сборке потоков и детектированию. Нужен нативный запуск.
PCAP_MAX_MB| Самый большой файл захвата в мегабайтах, который принимает dpistack pcap analyze.
FLOW_MEMCAP| Память под таблицу потоков, например 512mb или 1gb. Увеличьте, если в статистике растёт flow memcap.
STREAM_MEMCAP| Память под отслеживание TCP-потоков, например 256mb. Увеличьте, если в статистике растёт stream memcap.
STREAM_REASSEMBLY_MEMCAP| Память под сборку TCP-потоков, например 512mb. Увеличьте, если в статистике растёт reassembly memcap.
HOME_NET|Ваши сети (CIDR через запятую) или auto: определить по интерфейсам.
IPS_METHOD|Как IPS получает пакеты: очередь NFQUEUE или AF_PACKET.
IPS_NFQ_CHAINS|Цепочки iptables, из которых пакеты уходят в очередь.
NTOPNG_IFACES|Интерфейсы ntopng. Пусто: те же, что у Suricata.
EVE_FILE|Писать события в eve.json (нужен панели и watchdog).
EVE_TYPES|Какие типы событий писать в eve.json.
EVE_SYSLOG|Дублировать события в syslog (facility local5).
EVE_REDIS_MAXLEN|Сколько событий хранит поток Redis (EVE_REDIS). Redis обрезает его примерно до этой длины, поэтому поток, который никто не читает, не заполнит память. По умолчанию 100000.
EVE_REDIS|Отправлять события ещё и в Redis: yes (Redis этого хоста) или host[:port][/key], например 127.0.0.1:6379/suricata. Пусто или no: только eve.json. Нужен Suricata, собранный с поддержкой Redis (сборка из исходников её содержит).
EVE_ROTATE|Как ротировать eve.json: раз в день, в неделю или по размеру.
EVE_KEEP|Сколько ротированных файлов хранить.
EVE_MAX_SIZE_MB|Размер файла в МБ, при котором наступает ротация (режим «по размеру»). По умолчанию 100.
STATS_INTERVAL_SEC|Как часто Suricata пишет статистику (секунды).
RULES_SOURCES|Источники правил suricata-update, через пробел.
RULES_URLS|Свои адреса наборов правил, через пробел. Пусто: только источники правил выше.
RULES_GROUPS|Включённые группы правил, через запятую.
RULES_UPDATE|Обновлять правила по расписанию.
RULES_UPDATE_CALENDAR|Когда обновлять: daily, weekly или выражение systemd.
EXCEPTIONS_DEFAULT_DAYS|Сколько дней действует новое исключение, если срок не задан; 0 значит бессрочно.
EVEBOX_DB|Где EveBox хранит события.
EVEBOX_ES_URL|Адрес Elasticsearch для режима elasticsearch.
EVEBOX_PORT|Порт EveBox.
EVEBOX_RETENTION_DAYS|Сколько дней хранить события в EveBox (0: без ограничения).
ACCESS_MODE|Кто может открыть панели: localhost, локальная сеть или через nginx.
BIND_ADDR|Адрес, на котором слушают веб-службы: auto (127.0.0.1, а в режиме lan все адреса) или один IPv4-адрес этого хоста, например 192.168.1.156. Не loopback-адрес открывает панели для LAN_CIDR.
LAN_CIDR|Сеть, которой разрешён доступ в режиме lan, или auto; можно перечислить несколько сетей через запятую (auto означает сеть маршрута по умолчанию), например auto,172.18.0.0/16.
PANEL_PORT|Порт этой панели.
NTOPNG_PORT|Порт ntopng.
PANEL_RUNTIME|Где работает панель: службой на хосте или контейнером Docker (команды на хост идут через nsenter).
PANEL_SOURCE|Как получить программу панели: собрать, взять готовую или выбрать автоматически.
NGINX_MANAGE|Как управлять nginx: заменить конфигурацию или только положить фрагмент.
NGINX_TLS|TLS на nginx: без него, самоподписанный или свой сертификат.
NGINX_CERT|Путь к сертификату для режима existing.
NGINX_KEY|Путь к ключу для режима existing.
FIREWALL_MANAGE|Открывать нужные порты в firewall самостоятельно.
METRICS_EXPORT|Отдавать метрики панели на /metrics по токену.
METRICS_BACKEND|Хранилище метрик: без него, VictoriaMetrics или Prometheus.
METRICS_BACKEND_RUNTIME|Хранилище метрик на хосте или в Docker.
METRICS_BACKEND_PORT|Порт хранилища метрик.
METRICS_RETENTION|Срок хранения метрик, например 30d.
NODE_EXPORTER_ENABLE|Установить node_exporter (процессор, память, диск и сеть хоста); хранилище метрик собирает с него данные.
NODE_EXPORTER_RUNTIME|Где работает node_exporter: на хосте или в контейнере Docker.
NODE_EXPORTER_PORT|Порт node_exporter.
GRAFANA_ENABLE|Установить Grafana для дашбордов; хранилище метрик становится её источником данных по умолчанию.
GRAFANA_RUNTIME|Где работает Grafana: на хосте или в контейнере Docker.
GRAFANA_PORT|Порт Grafana. Первый вход admin/admin, затем Grafana просит новый пароль.
WATCH_ENABLE|Фоновый контроль состояния компонентов.
WATCH_INTERVAL_SEC|Как часто watchdog проверяет состояние (секунды).
WATCH_EVE_STALE_SEC|Через сколько секунд молчания eve.json считается зависшим.
WATCH_DROP_WARN_PCT|Процент потерянных пакетов для предупреждения.
WATCH_DROP_CRIT_PCT|Процент потерянных пакетов для тревоги.
WATCH_DISK_WARN_PCT|Свободное место на диске (%) для предупреждения.
WATCH_DISK_CRIT_PCT|Свободное место на диске (%) для тревоги.
WATCH_RULES_WARN_DAYS|Возраст правил (дни) для предупреждения.
WATCH_RULES_CRIT_DAYS|Возраст правил (дни) для тревоги.
WATCH_REPEAT_MIN|Через сколько минут повторять то же оповещение.
WATCH_AUTORESTART|Перезапускать упавший компонент автоматически (не чаще трёх раз в час).
ALERT_CHANNELS| Куда слать оповещения: panel, log, tg (Telegram), mail, webhook, syslog (через запятую).
ALERT_TG_CHAT_ID|Чат Telegram для оповещений.
ALERT_MAIL_TO|Получатели почты, через запятую.
ALERT_MAIL_FROM|Адрес отправителя.
ALERT_WEBHOOK_FORMAT| Тело сообщения вебхука: json (своя форма), slack, discord или ntfy.
ALERT_SYSLOG_TARGET| Сервер syslog для канала syslog: host, host:port или [ipv6]:port (порт 514 по умолчанию).
ALERT_SYSLOG_PROTO| Транспорт до сервера syslog: udp или tcp.
DETECT_NOTIFY| Отправлять срабатывания Suricata (alert) в каналы доставки, а не только состояние стека.
DETECT_NOTIFY_SEVERITY| Самая слабая важность для отправки: high, medium (и high) или low (все).
DETECT_NOTIFY_CHANNELS| Каналы для срабатываний через запятую, из ALERT_CHANNELS. Пусто: каналы ALERT_CHANNELS без panel.
DETECT_NOTIFY_MAX_PER_HOUR| Сколько сообщений о срабатываниях в час. Остальные считаются, уходит одно сводное сообщение.
DETECT_NOTIFY_DEDUP_MIN| Одна и та же сигнатура между теми же адресами отправляется раз в столько минут (0: каждое срабатывание).
HISTORY_ENABLE| Хранить суточную сводку трафика, приложений, устройств и срабатываний для dpistack report и dpistack devices.
HISTORY_DAYS| Сколько дней суточных сводок хранить.
DEVICE_NEW_NOTIFY| Сообщать, когда появляется адрес из частного диапазона, которого раньше не было. Нужен HISTORY_ENABLE=yes.
TEST_HTTPS_URL|Адрес для HTTPS-проверки на экране «Тесты».
TEST_BT_LIVE|Дополнительно проиграть файл BitTorrent через интерфейс захвата и искать оповещение в живом журнале. Добавляет в Suricata одно небольшое тестовое правило (sid 9000100).
TEST_ON_INSTALL|Запускать проверки после установки.
ALERT_TG_TOKEN|Токен бота Telegram. Хранится отдельно от основной конфигурации.
ALERT_SMTP_URL|Адрес SMTP, например smtps://user:pass@host:465. Хранится отдельно.
ALERT_WEBHOOK_URL| Адрес вебхука (Slack, Discord, тема ntfy или свой). Это и есть секрет, хранится отдельно.
METRICS_TOKEN|Токен доступа к /metrics. Хранится отдельно.
