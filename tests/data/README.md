# tests/data/bittorrent.pcap

English | [Русский](README.ru.md)

Source: received from the project owner (a public training sample, 2007-04-11, 53 packets, TCP `10.10.10.23:1044` <-> `10.10.10.22:47309`).

The content was confirmed by hand (`tcpdump -X` and a parse of the BT wire protocol): 2 handshakes (`\x13BitTorrent protocol`), 1 bitfield, 48 `request` (piece request), 7 `have`, 1 `interested`, 2 `unchoke`.

## How to use it

Replay with any rule set:

```
suricata -r tests/data/bittorrent.pcap -S <rules-file> -l <outdir> -k none
```

The file is reused by `tests/pkg_dnf.bats` and by the nDPI and Suricata step tests, and by `dpistack test bittorrent` (the replay check).
