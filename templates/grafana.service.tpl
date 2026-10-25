[Unit]
Description=dpistack Grafana
After=network.target

[Service]
Type=simple
User=@@USER@@
WorkingDirectory=@@HOME@@
ExecStart=@@HOME@@/bin/grafana server --homepath=@@HOME@@ --config=@@INI@@
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
