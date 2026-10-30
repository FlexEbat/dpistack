%YAML 1.1
---
# Offline config for `dpistack test bittorrent` (tech.md 10).
# Same ruleset and plugins as production. Events go only to the -l
# directory, so the main eve.json is never touched.
# The sample pcap is a flow between two private hosts. With the real
# HOME_NET the ET rules (`$HOME_NET -> $EXTERNAL_NET`) cannot match it,
# so the replay treats every address as both: the test checks the
# ruleset, not the network layout of the host.
vars:
  address-groups:
    HOME_NET: "any"
    EXTERNAL_NET: "any"

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
