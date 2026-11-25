[Unit]
Description=dpistack scheduled backup timer

[Timer]
OnCalendar=@@SCHEDULE@@
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
