# tests/data/bittorrent.pcap

Источник: получен от владельца проекта (публичный тренировочный сэмпл, 2007-04-11, 53 пакета, TCP `10.10.10.23:1044` ↔ `10.10.10.22:47309`).

Содержимое подтверждено вручную (`tcpdump -X` + разбор BT wire-protocol): 2 handshake (`\x13BitTorrent protocol`), 1 bitfield, 48 `request` (piece request), 7 `have`, 1 `interested`, 2 `unchoke`. Полный разбор и повторяемые команды — в `docs/prototype.md`, раздел «BitTorrent pcap и сигнатура».

## Как использовать

Реплей с любым набором правил:

```
suricata -r tests/data/bittorrent.pcap -S <rules-file> -l <outdir> -k none
```

**Известное ограничение окружения, в котором готовился слайс 0:** официальный набор ET Open (`emerging-p2p`) недоступен без сети до `rules.emergingthreats.net`, а nDPI не собран (см. `docs/prototype.md`, A3/A2). Поэтому официальный критерий приёмки слайса 0 (сигнатура ET P2P и/или `ndpi-protocol:BitTorrent`) на этом файле пока проверен только самописным тестовым правилом на magic-байты handshake — не заменяет реальный прогон с ET/nDPI.

Файл переиспользуется в дальнейших тестах: `tests/pkg_dnf.bats` и тестах слайсов 2/4 (nDPI/Suricata).
