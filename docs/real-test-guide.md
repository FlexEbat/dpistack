# Проверка слайсов 0–7 на реальном стенде

Всё, что собрано в `dev`, проверено настолько, насколько это было
возможно в изолированной песочнице без сети до внешних репозиториев
(см. `docs/prototype.md`). Этот документ — что нужно проверить на
настоящей машине и что должно получиться.

## Стенд

- Чистая Ubuntu 22.04 или 24.04 (Debian тоже должен подойти, но
  проверялся именно Ubuntu). Лучше снапшот/одноразовая VM — установщик
  ставит реальные пакеты и репозитории.
- Root или sudo.
- Реальный сетевой интерфейс с именем, которое вы укажете в `IFACES`
  (`ip link` подскажет). Не обязательно «боевой» — подойдёт любой,
  через который пройдёт хоть немного трафика для проверки.
- Интернет: до `archive.ubuntu.com`, PPA `oisf/suricata-stable`,
  `packages.ntop.org`, `evebox.org`, `rules.emergingthreats.net`. Все
  четыре — как раз то, что я не мог проверить из песочницы.
- Свободно 1–4 ГБ на диске, Bash ≥4.4 (в Ubuntu 22.04+ уже такой).

## 0. Скачать код и прогнать гейт локально

```
git clone https://github.com/FlexEbat/dpistack.git
cd dpistack
git checkout dev
sudo apt-get install -y shfmt shellcheck bats
bash scripts/gate.sh
```

Ожидается: все проверки зелёные (в момент написания — 65 bats-тестов).
Если гейт красный уже здесь — дальше не идти, разбираться на месте.

## 1. Сухой прогон

```
sudo ./install.sh install --dry-run -y --set IFACES=<ваш интерфейс>
```

Ожидается: код возврата 0, план по всем 13 шагам, ничего не
записано на диск (`/etc/dpistack/dpistack.conf` не появляется).

## 2. Реальная установка (без nDPI, чтобы не упереться в Rust)

```
sudo ./install.sh install -y \
  --set IFACES=<ваш интерфейс> \
  --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
```

Ожидается:

- `preflight` проходит (или падает кодом 3 с конкретной, понятной
  причиной — тоже полезный результат, значит проверки реальные).
- Suricata ставится из PPA `oisf/suricata-stable`, стартует.
- `suricata-update` реально выкачивает `et/open`, группы
  `emerging-p2p`/`emerging-policy` включены.
- Redis, ntopng, EveBox ставятся и стартуют.
- Доступ по умолчанию — только `127.0.0.1`.

## 3. Ручная проверка после установки

```
sudo suricata -T -c /etc/suricata/suricata.yaml
systemctl status suricata redis-server ntopng evebox
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5636
```

Все сервисы — `active (running)`, оба `curl` — какой-то HTTP-код (не
`000`, то есть порт слушает).

## 4. Живой трафик

Откройте любой HTTPS-сайт или скачайте что-то по BitTorrent через
интерфейс из `IFACES`, затем:

```
tail -f /var/log/suricata/eve.json
```

Ожидается: строки реально появляются. Дальше откройте EveBox
(`http://127.0.0.1:5636`, туннелем по SSH если стенд без GUI) и ntopng
(`http://127.0.0.1:3000`, логин/пароль по умолчанию `admin`/`admin`) —
трафик должен быть виден в обоих.

## 5. Идемпотентность

```
sudo ./install.sh install -y --set IFACES=<ваш интерфейс> \
  --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
sudo ./install.sh status --set IFACES=<ваш интерфейс> \
  --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
```

Повторная установка: всё «без изменений». `status`: «в порядке» по
каждому шагу.

## 6. Reconfigure и доступ

```
sudo ./install.sh reconfigure --dry-run -y \
  --set ACCESS_MODE=lan --set ACCESS_CONFIRM=yes
```

Ожидается: список изменённых ключей и затронутых шагов, ничего не
применено. Затем без `--dry-run` — то же самое, но по-настоящему, и:

```
ss -ltn | grep -E ':(3000|5636)'
```

Оба порта теперь слушают на `0.0.0.0`, а не `127.0.0.1`.

## 7. nDPI и сборка из исходников (если есть машина с Rust ≥1.85)

Это единственное, что я не смог довести до конца сам — уткнулся в
версию Rust. Если у вас есть подходящая машина (свежий Debian/Ubuntu с
`rustup`, либо сама Ubuntu 24.04+ с `rustup toolchain install stable`):

```
sudo ./install.sh install -y --set IFACES=<интерфейс> \
  --set SURICATA_SOURCE=source --set NDPI_ENABLE=yes
suricata --build-info | grep -i ndpi
```

Ожидается: сборка проходит, в `--build-info` виден nDPI, а в правилах
с `ndpi-protocol`/`ndpi-risk` — реальные срабатывания.

## Чек-лист того, что я не проверял и что нужно ваше подтверждение

- [ ] PPA `oisf/suricata-stable` — реальная установка Suricata.
- [ ] `packages.ntop.org` — реальный пакет ntopng (я проверял формат
      конфига на пакете из архива Ubuntu, это другой пакет).
- [ ] `evebox.org` — реальный бинарник EveBox вообще ни разу не
      запускал, только конфиг по документации.
- [ ] `rules.emergingthreats.net` — реальная выкачка `et/open`.
- [ ] Сборка Suricata+nDPI из исходников (нужен Rust ≥1.85).
- [ ] `ufw` — правила реально применяются и работают.
- [ ] SELinux-ветка (актуально только на Fedora/RHEL, которые пока не
      поддерживаются).

Если что-то из этого списка не совпадёт с ожиданиями — это и есть
самое полезное, что можно найти на этом этапе.
