[Unit]
Description=dpistack VictoriaMetrics (single-node)
After=network.target

[Service]
Type=simple
User=@@USER@@
# The token of /metrics is root:dpistack 0640.
SupplementaryGroups=dpistack
ExecStart=@@BIN@@ -storageDataPath=@@DATA_DIR@@ -retentionPeriod=@@RETENTION@@ -httpListenAddr=@@LISTEN@@ -promscrape.config=@@SCRAPE@@
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
