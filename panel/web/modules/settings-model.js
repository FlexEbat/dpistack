// The pure part of the settings screen: grouping, labels, hints and the
// computation of what changed. No DOM here, so node --test can run it.

export const GROUPS = [
  ["capture", "Захват трафика"],
  ["components", "Компоненты и установка"],
  ["eve", "События и хранение"],
  ["rules", "Правила"],
  ["access", "Доступ и порты"],
  ["metrics", "Метрики"],
  ["watch", "Контроль и оповещения"],
  ["tests", "Проверочные тесты"],
];

// What each key does, in a sentence. A key without a line shows its name only.
export const HINTS = {
  SURICATA_RUNTIME: "Где работает Suricata: на хосте или в контейнере Docker.",
  EVEBOX_RUNTIME: "Где работает EveBox: на хосте или в контейнере Docker.",
  NTOPNG_RUNTIME: "Где работает ntopng: на хосте или в контейнере Docker.",
  SURICATA_SOURCE: "Откуда берётся Suricata: пакет дистрибутива, пакет OISF или сборка из исходников.",
  SURICATA_VERSION: "Закреплённая версия Suricata. Пусто: последняя стабильная.",
  NDPI_ENABLE: "Определение приложений по nDPI в Suricata.",
  NDPI_SOURCE: "nDPI из пакета или сборкой из исходников.",
  NDPI_VERSION: "Закреплённая версия nDPI. Пусто: последняя стабильная.",
  NTOPNG_VERSION: "Закреплённая версия ntopng.",
  EVEBOX_VERSION: "Закреплённая версия EveBox.",
  PIN_VERSIONS: "Закрепить установленные версии, чтобы обновление системы их не меняло.",
  SURICATA_MODE: "ids только наблюдает, ips может блокировать. Переключение лучше делать на экране «Компоненты».",
  IFACES: "Интерфейсы, с которых Suricata снимает трафик, через запятую.",
  BPF_FILTER: "Фильтр BPF: какой трафик не анализировать или анализировать.",
  HOME_NET: "Ваши сети (CIDR через запятую) или auto: определить по интерфейсам.",
  IPS_METHOD: "Как IPS получает пакеты: очередь NFQUEUE или AF_PACKET.",
  IPS_NFQ_CHAINS: "Цепочки iptables, из которых пакеты уходят в очередь.",
  NTOPNG_IFACES: "Интерфейсы ntopng. Пусто: те же, что у Suricata.",
  EVE_FILE: "Писать события в eve.json (нужен панели и watchdog).",
  EVE_TYPES: "Какие типы событий писать в eve.json.",
  EVE_SYSLOG: "Дублировать события в syslog.",
  EVE_REDIS: "Отправлять события в Redis (адрес вида host:port/список).",
  EVE_ROTATE: "Как ротировать eve.json: раз в день, в неделю или по размеру.",
  EVE_KEEP: "Сколько ротированных файлов хранить.",
  EVE_MAX_SIZE_MB: "Размер файла в МБ, при котором наступает ротация (режим «по размеру»).",
  STATS_INTERVAL_SEC: "Как часто Suricata пишет статистику (секунды).",
  RULES_SOURCES: "Источники правил suricata-update, через пробел.",
  RULES_URLS: "Свои адреса наборов правил, через пробел.",
  RULES_GROUPS: "Включённые группы правил, через запятую.",
  RULES_UPDATE: "Обновлять правила по расписанию.",
  RULES_UPDATE_CALENDAR: "Когда обновлять: daily, weekly или выражение systemd.",
  EVEBOX_DB: "Где EveBox хранит события.",
  EVEBOX_ES_URL: "Адрес Elasticsearch для режима elasticsearch.",
  EVEBOX_PORT: "Порт EveBox.",
  EVEBOX_RETENTION_DAYS: "Сколько дней хранить события в EveBox (0: без ограничения).",
  ACCESS_MODE: "Кто может открыть панели: localhost, локальная сеть или через nginx.",
  LAN_CIDR: "Сеть, которой разрешён доступ в режиме lan, или auto.",
  PANEL_PORT: "Порт этой панели.",
  NTOPNG_PORT: "Порт ntopng.",
  PANEL_SOURCE: "Как получить программу панели: собрать, взять готовую или выбрать автоматически.",
  NGINX_MANAGE: "Как управлять nginx: заменить конфигурацию или только положить фрагмент.",
  NGINX_TLS: "TLS на nginx: без него, самоподписанный или свой сертификат.",
  NGINX_CERT: "Путь к сертификату для режима existing.",
  NGINX_KEY: "Путь к ключу для режима existing.",
  FIREWALL_MANAGE: "Открывать нужные порты в firewall самостоятельно.",
  METRICS_EXPORT: "Отдавать метрики панели на /metrics по токену.",
  METRICS_BACKEND: "Хранилище метрик: без него, VictoriaMetrics или Prometheus.",
  METRICS_BACKEND_RUNTIME: "Хранилище метрик на хосте или в Docker.",
  METRICS_BACKEND_PORT: "Порт хранилища метрик.",
  METRICS_RETENTION: "Срок хранения метрик, например 30d.",
  WATCH_ENABLE: "Фоновый контроль состояния компонентов.",
  WATCH_INTERVAL_SEC: "Как часто watchdog проверяет состояние (секунды).",
  WATCH_EVE_STALE_SEC: "Через сколько секунд молчания eve.json считается зависшим.",
  WATCH_DROP_WARN_PCT: "Процент потерянных пакетов для предупреждения.",
  WATCH_DROP_CRIT_PCT: "Процент потерянных пакетов для тревоги.",
  WATCH_DISK_WARN_PCT: "Свободное место на диске (%) для предупреждения.",
  WATCH_DISK_CRIT_PCT: "Свободное место на диске (%) для тревоги.",
  WATCH_RULES_WARN_DAYS: "Возраст правил (дни) для предупреждения.",
  WATCH_RULES_CRIT_DAYS: "Возраст правил (дни) для тревоги.",
  WATCH_REPEAT_MIN: "Через сколько минут повторять то же оповещение.",
  WATCH_AUTORESTART: "Перезапускать упавший компонент автоматически (не чаще трёх раз в час).",
  ALERT_CHANNELS: "Куда слать оповещения: panel, log, telegram, mail (через запятую).",
  ALERT_TG_CHAT_ID: "Чат Telegram для оповещений.",
  ALERT_MAIL_TO: "Получатели почты, через запятую.",
  ALERT_MAIL_FROM: "Адрес отправителя.",
  TEST_HTTPS_URL: "Адрес для HTTPS-проверки на экране «Тесты».",
  TEST_BT_LIVE: "Проверка BitTorrent по живому трафику, а не по файлу.",
  TEST_ON_INSTALL: "Запускать проверки после установки.",
  ALERT_TG_TOKEN: "Токен бота Telegram. Хранится отдельно от основной конфигурации.",
  ALERT_SMTP_URL: "Адрес SMTP, например smtps://user:pass@host:465. Хранится отдельно.",
  METRICS_TOKEN: "Токен доступа к /metrics. Хранится отдельно.",
};

// groupSettings -> [{id, title, items}] in the order of GROUPS. Advanced keys
// are left out unless asked for; a group that ends up empty is left out too.
export function groupSettings(keys, showAdvanced) {
  const out = [];
  for (const [id, title] of GROUPS) {
    const items = keys.filter((k) => k.group === id && (showAdvanced || k.level === "basic"));
    if (items.length) out.push({ id, title, items });
  }
  return out;
}

// changedValues -> {KEY: value} of the non-secret keys whose edited value
// differs from the saved one.
export function changedValues(keys, edits) {
  const out = {};
  for (const k of keys) {
    if (k.secret) continue;
    if (!(k.key in edits)) continue;
    if (edits[k.key] !== k.value) out[k.key] = edits[k.key];
  }
  return out;
}

// localProblem -> a sentence for a value that cannot be right, or "". The
// server decides in the end; this only saves a round trip for the obvious.
export function localProblem(k, value) {
  if (k.type === "int") {
    if (value === "") return k.default === "" ? "" : "нужно число";
    if (!/^[0-9]+$/.test(value)) return "нужно целое число";
    const n = Number(value);
    if (k.min !== null && n < k.min) return "не меньше " + k.min;
    if (k.max !== null && n > k.max) return "не больше " + k.max;
  }
  if (k.type === "enum" && !k.options.includes(value)) return "значение вне списка";
  if (k.type === "free" && value.length > 1024) return "слишком длинное значение";
  if (/[\r\n]/.test(value)) return "без переводов строки";
  return "";
}

export const ACCESS_KEYS = ["ACCESS_MODE"];

// needsAccessConfirm: widening who can reach the panels is confirmed by the
// person, never implied.
export function needsAccessConfirm(changed, keys) {
  const k = keys.find((x) => x.key === "ACCESS_MODE");
  return Boolean(k && "ACCESS_MODE" in changed && changed.ACCESS_MODE !== "localhost");
}
