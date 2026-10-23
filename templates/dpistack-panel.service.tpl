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
# Resource budget (tech.md 9) when PANEL_MODE=limited; with unlimited the
# unit has none. NoNewPrivileges and ProtectSystem are left
# out on purpose: sudo inherits the unit's restrictions, and dpistack
# could not write to /etc under them.
@@RESOURCE_LIMITS@@
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
