[Unit]
Description=dpistack Caddy reverse proxy (HTTPS in front of ntopng, EveBox and the panel)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=@@CADDY_BIN@@ run --environ --config @@CADDYFILE@@ --adapter caddyfile
Restart=on-failure
RestartSec=5
# Its own transient user, with a state directory of its own: the keys of its
# local CA (or of the certificates it gets) are not readable by anyone else.
DynamicUser=yes
StateDirectory=dpistack-caddy
Environment=XDG_DATA_HOME=@@DATA_DIR@@ XDG_CONFIG_HOME=@@DATA_DIR@@
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
