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

    location / {
        proxy_pass http://127.0.0.1:@@UPSTREAM_PORT@@;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
