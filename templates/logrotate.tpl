@@EVE_JSON_PATH@@ {
    @@ROTATE_DIRECTIVE@@
    rotate @@EVE_KEEP@@
    missingok
    notifempty
    compress
    delaycompress
    create
    sharedscripts
    postrotate
        @@REOPEN_CMD@@ 2>/dev/null || true
    endscript
}
