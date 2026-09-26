%%DPISTACK_EVE_JSON_PATH%% {
    %%DPISTACK_ROTATE_DIRECTIVE%%
    rotate %%DPISTACK_EVE_KEEP%%
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
