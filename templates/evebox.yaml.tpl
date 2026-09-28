# dpistack-rendered evebox.yaml. Keys follow the official EveBox server
# configuration reference (https://evebox.org/docs/server/configuration).
# Bound to 127.0.0.1 in this slice regardless of ACCESS_MODE (network
# exposure is slice 7). TLS and EveBox's own authentication are off:
# access is restricted at the network level (localhost, LAN_CIDR via
# firewall, or nginx), and EveBox auth is out of scope for dpistack.
http:
  host: "@@EVEBOX_HOST@@"
  port: @@EVEBOX_PORT@@
  tls:
    enabled: false

authentication:
  required: false

database:
  type: @@EVEBOX_DB_TYPE@@
@@EVEBOX_ES_BLOCK@@
  retention:
    days: @@EVEBOX_RETENTION_DAYS@@

input:
  enabled: @@EVEBOX_INPUT_ENABLED@@
  paths:
@@EVEBOX_INPUT_PATHS@@
