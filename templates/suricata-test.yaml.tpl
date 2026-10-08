%YAML 1.1
---
# Offline config for `dpistack-ctl test bittorrent` (tech.md 10).
# Same ruleset and plugins as production. Events go only to the -l
# directory, so the main eve.json is never touched.
default-rule-path: @@RULE_DIR@@
rule-files:
@@RULE_FILES@@

@@PLUGINS@@

outputs:
  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve.json
      types:
        - alert
        - netflow

app-layer:
  protocols:
    tls:
      enabled: yes
    http:
      enabled: yes
