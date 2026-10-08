[Unit]
Description=dpistack watchdog timer

[Timer]
OnBootSec=60
OnUnitActiveSec=@@INTERVAL@@s
AccuracySec=1s

[Install]
WantedBy=timers.target
