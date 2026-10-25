[Unit]
Description=dpistack node_exporter
After=network.target

[Service]
Type=simple
User=@@USER@@
ExecStart=@@BIN@@ --web.listen-address=@@LISTEN@@
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
