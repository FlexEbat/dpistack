#!/usr/bin/env bash
# Single source of paths, built from DPISTACK_ROOT (tech.md 4.2, 3).
# No step reads /etc/... or /var/... directly; every path comes from here
# so tests can redirect the whole tree into a temp dir.

: "${DPISTACK_ROOT:=}"

path_etc() { echo "${DPISTACK_ROOT}/etc/dpistack"; }
path_conf() { echo "$(path_etc)/dpistack.conf"; }
path_conf_draft() { echo "$(path_etc)/dpistack.conf.draft"; }
path_secrets() { echo "$(path_etc)/secrets.conf"; }
path_panel_auth() { echo "$(path_etc)/panel.auth"; }

path_state_dir() { echo "${DPISTACK_ROOT}/var/lib/dpistack"; }
path_state_file() { echo "$(path_state_dir)/state"; }
path_health_json() { echo "$(path_state_dir)/health.json"; }
path_events_jsonl() { echo "$(path_state_dir)/events.jsonl"; }
path_tests_last_json() { echo "$(path_state_dir)/tests-last.json"; }
path_metrics_json() { echo "$(path_state_dir)/metrics.json"; }
path_backups_dir() { echo "$(path_state_dir)/backups"; }
path_staging_dir() { echo "$(path_state_dir)/staging"; }
path_scrape_yaml() { echo "$(path_state_dir)/scrape.yaml"; }

path_lock_file() { echo "${DPISTACK_ROOT}/var/lock/dpistack.lock"; }

path_log_dir() { echo "${DPISTACK_ROOT}/var/log/dpistack"; }
path_install_log() { echo "$(path_log_dir)/install.log"; }

path_sbin_dir() { echo "${DPISTACK_ROOT}/usr/local/sbin"; }
path_dpistack_bin() { echo "$(path_sbin_dir)/dpistack"; }
path_ctl_bin() { echo "$(path_sbin_dir)/dpistack-ctl"; }
path_watch_bin() { echo "$(path_sbin_dir)/dpistack-watch"; }
path_watch_service_unit() { echo "${DPISTACK_ROOT}/etc/systemd/system/dpistack-watch.service"; }
path_watch_timer_unit() { echo "${DPISTACK_ROOT}/etc/systemd/system/dpistack-watch.timer"; }
path_evebox_data_dir() { echo "${DPISTACK_ROOT}/var/lib/evebox"; }

path_lib_dir() { echo "${DPISTACK_ROOT}/usr/local/lib/dpistack"; }
path_installer_copy_dir() { echo "$(path_lib_dir)/installer"; }
path_panel_bin() { echo "${DPISTACK_ROOT}/usr/local/bin/dpistack-panel"; }
path_sudoers() { echo "${DPISTACK_ROOT}/etc/sudoers.d/dpistack"; }

path_suricata_yaml() { echo "${DPISTACK_ROOT}/etc/suricata/suricata.yaml"; }
path_suricata_enable_conf() { echo "${DPISTACK_ROOT}/etc/suricata/enable.conf"; }
path_suricata_disable_conf() { echo "${DPISTACK_ROOT}/etc/suricata/disable.conf"; }
path_suricata_modify_conf() { echo "${DPISTACK_ROOT}/etc/suricata/modify.conf"; }
path_suricata_drop_conf() { echo "${DPISTACK_ROOT}/etc/suricata/drop.conf"; }
path_suricata_local_rules() { echo "${DPISTACK_ROOT}/etc/suricata/rules/local.rules"; }
path_suricata_ruleset() { echo "${DPISTACK_ROOT}/var/lib/suricata/rules/suricata.rules"; }
path_suricata_eve_json() { echo "${DPISTACK_ROOT}/var/log/suricata/eve.json"; }
path_suricata_logrotate() { echo "${DPISTACK_ROOT}/etc/logrotate.d/suricata"; }
path_ndpi_src_dir() { echo "${DPISTACK_ROOT}/usr/local/src/dpistack-ndpi"; }
path_suricata_ndpi_plugin() { echo "${DPISTACK_ROOT}/usr/lib/suricata/ndpi.so"; }
path_suricata_src_dir() { echo "${DPISTACK_ROOT}/usr/local/src/dpistack-suricata"; }
path_suricata_service_unit() { echo "${DPISTACK_ROOT}/etc/systemd/system/suricata.service"; }
path_rules_service_unit() { echo "${DPISTACK_ROOT}/etc/systemd/system/dpistack-rules.service"; }
path_rules_timer_unit() { echo "${DPISTACK_ROOT}/etc/systemd/system/dpistack-rules.timer"; }
path_suricata_socket() { echo "${DPISTACK_ROOT}/run/suricata/suricata-command.socket"; }

path_evebox_yaml() { echo "${DPISTACK_ROOT}/etc/evebox/evebox.yaml"; }
path_evebox_keyring() { echo "${DPISTACK_ROOT}/etc/apt/keyrings/evebox.asc"; }
path_evebox_apt_list() { echo "${DPISTACK_ROOT}/etc/apt/sources.list.d/evebox.list"; }
path_ntopng_conf() { echo "${DPISTACK_ROOT}/etc/ntopng/ntopng.conf"; }
path_ntopng_pidfile() { echo "${DPISTACK_ROOT}/run/ntopng.pid"; }
path_nginx_snippet_dir() { echo "$(path_state_dir)/nginx"; }
path_nginx_snippet() { echo "$(path_nginx_snippet_dir)/dpistack.conf"; }
path_nginx_tls_dir() { echo "$(path_nginx_snippet_dir)/tls"; }
path_nginx_confd() { echo "${DPISTACK_ROOT}/etc/nginx/conf.d/dpistack.conf"; }
path_compose_yaml() { echo "${DPISTACK_ROOT}/opt/dpistack/compose/compose.yaml"; }
path_os_release() { echo "${DPISTACK_ROOT}/etc/os-release"; }
path_rules_data_dir() { echo "${DPISTACK_ROOT}/var/lib/suricata"; }
path_ndpi_lib_dir() { echo "${DPISTACK_ROOT}/usr/local/lib"; }
