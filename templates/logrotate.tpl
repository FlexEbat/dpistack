@@EVE_JSON_PATH@@ {
    @@ROTATE_DIRECTIVE@@
    rotate @@EVE_KEEP@@
    missingok
    notifempty
    compress
    delaycompress
    create 0640 root root
    sharedscripts
    postrotate
        /usr/bin/suricatasc -c reopen-log-files 2>/dev/null || true
    endscript
}
