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
# Resource budget (tech.md 9). NoNewPrivileges and ProtectSystem are left
# out on purpose: sudo inherits the unit's restrictions, and dpistack-ctl
# could not write to /etc under them.
MemoryMax=64M
CPUQuota=20%
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
