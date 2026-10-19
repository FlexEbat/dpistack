# Managed by dpistack. Puts the DPISTACK iptables chain back at boot when
# the host is in IPS mode (NFQUEUE); in ids mode it removes a leftover one.
[Unit]
Description=dpistack firewall chain DPISTACK
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=@@CTL@@ fw restore

[Install]
WantedBy=multi-user.target
