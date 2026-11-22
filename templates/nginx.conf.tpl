# dpistack-rendered nginx server for @@NAME@@ (one server per web
# interface, own port, no sub-paths). Access is limited to LAN_CIDR;
# X-Forwarded-For is overwritten with the real client address (not
# appended), so a client cannot spoof it towards the panel, which trusts
# the header only from 127.0.0.1.
server {
    listen @@LISTEN@@;
    server_name _;
@@TLS_BLOCK@@

@@ALLOW_BLOCK@@
    deny all;

    # The capture upload of the panel (dpistack pcap analyze): nginx's
    # defaults (1 MiB, 60 s) would stop a real capture. The panel caps it at
    # 512 MiB itself and dpistack applies PCAP_MAX_MB.
    location = /api/pcap/analyze {
        client_max_body_size 512m;
        proxy_request_buffering off;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
        proxy_pass http://127.0.0.1:@@UPSTREAM_PORT@@;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:@@UPSTREAM_PORT@@;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
