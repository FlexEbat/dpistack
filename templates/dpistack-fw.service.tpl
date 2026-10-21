# Managed by dpistack. Puts the NFQUEUE rules (the DPISTACK iptables chain or
# the nft table dpistack) back at boot when the host is in IPS mode; in ids
# mode it removes leftovers.
#
# Ordering, as systemd.special(7) asks of firewall units: before
# network-pre.target, so the rules are in place before any interface is
# configured and no packet passes uninspected; after local-fs.target, because
# the config and dpistack-ctl are read from disk. DefaultDependencies=no
# keeps it out of the cycle that basic.target would make with
# network-pre.target.
[Unit]
Description=dpistack firewall rules for the Suricata queue
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target
Wants=network-pre.target
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=@@CTL@@ fw restore

[Install]
WantedBy=multi-user.target
