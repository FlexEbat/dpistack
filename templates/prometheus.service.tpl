[Unit]
Description=dpistack Prometheus
After=network.target

[Service]
Type=simple
User=@@USER@@
# The token of /metrics is root:dpistack 0640.
SupplementaryGroups=dpistack
ExecStart=@@BIN@@ --config.file=@@SCRAPE@@ --storage.tsdb.path=@@DATA_DIR@@ --storage.tsdb.retention.time=@@RETENTION@@ --web.listen-address=@@LISTEN@@
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
