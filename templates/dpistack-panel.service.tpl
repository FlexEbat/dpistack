[Unit]
Description=dpistack web panel
After=network.target

[Service]
Type=simple
User=@@USER@@
Group=@@USER@@
ExecStart=@@PANEL_BIN@@ @@ARGS@@
Restart=on-failure
RestartSec=5
# No MemoryMax or CPUQuota: the lite edition (PANEL_EDITION=lite) is the way
# to a lighter panel (tech.md 9). NoNewPrivileges and ProtectSystem are left
# out on purpose: sudo inherits the unit's restrictions, and dpistack
# could not write to /etc under them.
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
