# dpistack-rendered systemd unit for a from-source Suricata build
# (SURICATA_SOURCE=source). Based verbatim on Suricata's own reference
# unit (etc/suricata.service.in in the Suricata source tree), with the
# autoconf @e_rundir@/@e_sysconfdir@ placeholders replaced by
# dpistack's own and the binary path pointed at the source-build
# prefix, since distro/oisf packages ship their own unit instead.
[Unit]
Description=Suricata Intrusion Detection Service (built from source by dpistack)
After=syslog.target network-online.target

[Service]
ExecStartPre=/bin/rm -f %%DPISTACK_RUNDIR%%suricata.pid
ExecStart=/usr/local/bin/suricata -c %%DPISTACK_SYSCONFDIR%%suricata.yaml --pidfile %%DPISTACK_RUNDIR%%suricata.pid
ExecReload=/bin/kill -USR2 $MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
