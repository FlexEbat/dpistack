%YAML 1.1
---
# Offline config for `dpistack pcap analyze`: the live rules, the live
# exceptions and the real HOME_NET, replayed on a capture someone brings.
# Events go only to the -l directory, so the live eve.json is never touched.
vars:
  address-groups:
    HOME_NET: "@@HOME_NET@@"
    EXTERNAL_NET: "!$HOME_NET"
    HTTP_SERVERS: "$HOME_NET"
    SMTP_SERVERS: "$HOME_NET"
    SQL_SERVERS: "$HOME_NET"
    DNS_SERVERS: "$HOME_NET"
    TELNET_SERVERS: "$HOME_NET"
    AIM_SERVERS: "$EXTERNAL_NET"
    DC_SERVERS: "$HOME_NET"
    DNP3_SERVER: "$HOME_NET"
    DNP3_CLIENT: "$HOME_NET"
    MODBUS_CLIENT: "$HOME_NET"
    MODBUS_SERVER: "$HOME_NET"
    ENIP_CLIENT: "$HOME_NET"
    ENIP_SERVER: "$HOME_NET"
  port-groups:
    HTTP_PORTS: "80"
    SHELLCODE_PORTS: "!80"
    ORACLE_PORTS: 1521
    SSH_PORTS: 22
    DNP3_PORTS: 20000
    MODBUS_PORTS: 502
    FILE_DATA_PORTS: "[$HTTP_PORTS,110,143]"
    FTP_PORTS: 21
    GENEVE_PORTS: 6081
    VXLAN_PORTS: 4789
    TEREDO_PORTS: 3544

default-rule-path: @@RULE_DIR@@
rule-files:
  - @@RULE_FILE@@
@@THRESHOLD@@

@@PLUGINS@@

outputs:
  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve.json
      types:
        - alert
        - flow

app-layer:
  protocols:
    tls:
      enabled: yes
    http:
      enabled: yes
    dns:
      enabled: yes
    ssh:
      enabled: yes
    ftp:
      enabled: yes
    smtp:
      enabled: yes
    imap:
      enabled: detection-only
    smb:
      enabled: yes
    rdp:
      enabled: yes
    quic:
      enabled: yes
    mqtt:
      enabled: yes
    dhcp:
      enabled: yes
    ntp:
      enabled: yes
    sip:
      enabled: yes
