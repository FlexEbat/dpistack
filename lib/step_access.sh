#!/usr/bin/env bash
# Access: binds ntopng/EveBox/panel per ACCESS_MODE, an nginx reverse
# proxy for ACCESS_MODE=nginx, and firewall rules for FIREWALL_MANAGE
# (tech.md slice 7). ntopng/evebox stay on 127.0.0.1 for localhost and
# nginx modes (nginx does the proxying); lan makes them bind 0.0.0.0
# directly - access_effective_bind_host is what their own render
# functions call, so there is exactly one place that decides this.

NGINX_UNIT="nginx.service"

# access_backend_port <public-port> - the port a web service itself listens
# on. Only with ACCESS_MODE=nginx does it differ from the public one: nginx
# takes the public port on every address, so the service moves to
# 127.0.0.1:<public>+10000 (config validation keeps the public port at
# 55535 or below in that mode). Binding two sockets to the same port would
# fail with EADDRINUSE.
access_backend_port() {
	local port="$1"
	if [[ "${CONF[ACCESS_MODE]:-localhost}" == "nginx" ]]; then
		echo $((port + 10000))
	else
		echo "$port"
	fi
}

access_effective_bind_host() {
	case "${CONF[ACCESS_MODE]:-localhost}" in
	lan) echo "0.0.0.0" ;;
	*) echo "127.0.0.1" ;;
	esac
}

access_detect_lan_cidr() {
	local iface
	iface=$(ip -4 route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
	[[ -n "$iface" ]] || return 1
	local network
	network=$(ip -4 route show dev "$iface" scope link 2>/dev/null | awk '{print $1}' | head -1)
	[[ -n "$network" ]] || return 1
	echo "$network"
}

access_effective_lan_cidr() {
	local v="${CONF[LAN_CIDR]:-auto}"
	if [[ -z "$v" || "$v" == "auto" ]]; then
		access_detect_lan_cidr
	else
		echo "$v"
	fi
}

# access_render_service <name> <public-port> <upstream-port>
access_render_nginx_service() {
	local name="$1" port="$2" upstream="$3" cidr="$4"
	local listen tls_block
	if [[ "${CONF[NGINX_TLS]:-none}" == "none" ]]; then
		listen="${port}"
		tls_block=""
	else
		listen="${port} ssl"
		tls_block="    ssl_certificate $(access_tls_cert_path "$name");
    ssl_certificate_key $(access_tls_key_path "$name");"
	fi
	render_template "$SCRIPT_DIR/templates/nginx.conf.tpl" \
		"NAME=$name" \
		"LISTEN=$listen" \
		"TLS_BLOCK=$tls_block" \
		"ALLOW_BLOCK=    allow ${cidr};" \
		"UPSTREAM_PORT=$upstream"
}

access_tls_dir() { path_nginx_tls_dir; }
access_tls_cert_path() { echo "$(access_tls_dir)/${1}.crt"; }
access_tls_key_path() { echo "$(access_tls_dir)/${1}.key"; }

access_ensure_selfsigned_cert() {
	local name="$1"
	local cert key
	cert=$(access_tls_cert_path "$name")
	key=$(access_tls_key_path "$name")
	[[ -f "$cert" && -f "$key" ]] && return 0
	run mkdir -p "$(access_tls_dir)" || return 1
	run openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
		-keyout "$key" -out "$cert" -subj "/CN=dpistack-${name}" || return 1
}

access_render_nginx_full() {
	local cidr
	cidr=$(access_effective_lan_cidr) || cidr="127.0.0.1/32"
	local name port
	for name in ntopng evebox panel; do
		case "$name" in
		ntopng) port="${CONF[NTOPNG_PORT]:-3000}" ;;
		evebox) port="${CONF[EVEBOX_PORT]:-5636}" ;;
		panel) port="${CONF[PANEL_PORT]:-9800}" ;;
		esac
		access_render_nginx_service "$name" "$port" "$(access_backend_port "$port")" "$cidr"
		echo
	done
}

access_selinux_notice() {
	command -v getenforce >/dev/null 2>&1 || return 0
	local mode
	mode=$(getenforce 2>/dev/null)
	if [[ "$mode" == "Enforcing" ]]; then
		# nginx may not open connections to the local ntopng, EveBox and
		# panel ports until this boolean is on.
		if [[ "${CONF[ACCESS_MODE]:-localhost}" == "nginx" ]]; then
			run setsebool -P httpd_can_network_connect 1 ||
				echo "access: SELinux Enforcing, setsebool httpd_can_network_connect не прошёл: nginx не сможет проксировать на локальные порты" >&2
		else
			echo "access: SELinux в режиме Enforcing; для ACCESS_MODE=${CONF[ACCESS_MODE]:-localhost} изменений не требуется" >&2
		fi
	fi
}

# access_selinux_ports - in nginx mode nginx itself listens on the public
# ports (3000, 5636, 9800 by default), which SELinux only lets httpd_t use
# when they carry http_port_t.
access_selinux_ports() {
	[[ "${CONF[ACCESS_MODE]:-localhost}" == "nginx" ]] || return 0
	local port
	for port in "${CONF[NTOPNG_PORT]:-3000}" "${CONF[EVEBOX_PORT]:-5636}" "${CONF[PANEL_PORT]:-9800}"; do
		selinux_port http_port_t "$port"
	done
}

# The firewall rules dpistack added are written down in the state as
# "cidr,port" pairs (state key access.fw.rules), and only those are ever
# taken out again: a rule the administrator had before (or adds later) is
# never touched. A change of ACCESS_MODE, LAN_CIDR or FIREWALL_MANAGE, and
# uninstall, remove what is no longer wanted.
ACCESS_FW_STATE_KEY="access.fw.rules"

# access_fw_tool -> ufw | firewalld | (nothing)
access_fw_tool() {
	if command -v ufw >/dev/null 2>&1; then
		echo ufw
	elif command -v firewall-cmd >/dev/null 2>&1; then
		echo firewalld
	fi
	return 0
}

access_fw_rich_rule() {
	echo "rule family=ipv4 source address=${1} port port=${2} protocol=tcp accept"
}

# access_fw_has <cidr> <port> - the rule is there, whoever added it.
access_fw_has() {
	local cidr="$1" port="$2"
	if [[ "$(access_fw_tool)" == "ufw" ]]; then
		ufw show added 2>/dev/null | grep -qxF "ufw allow from $cidr to any port $port proto tcp"
	else
		firewall-cmd --permanent "--query-rich-rule=$(access_fw_rich_rule "$cidr" "$port")" >/dev/null 2>&1
	fi
}

# access_fw_delete <cidr> <port> - take one of our rules out.
access_fw_delete() {
	local cidr="$1" port="$2"
	if [[ "$(access_fw_tool)" == "ufw" ]]; then
		run ufw --force delete allow from "$cidr" to any port "$port" proto tcp
	else
		run firewall-cmd --permanent "--remove-rich-rule=$(access_fw_rich_rule "$cidr" "$port")"
	fi
}

# access_allow_port <cidr> <port> - one rule in whichever firewall the
# system has: ufw (Debian family) or firewalld (RHEL family). A rule that
# was already there and is not ours is left alone and not written down.
access_allow_port() {
	local cidr="$1" port="$2" rule="$1,$2" mine=1
	if access_fw_has "$cidr" "$port" && [[ " $(state_read_value "$ACCESS_FW_STATE_KEY") " != *" $rule "* ]]; then
		mine=0
	fi
	if [[ "$mine" == 1 ]]; then
		if [[ "$(access_fw_tool)" == "ufw" ]]; then
			run ufw allow from "$cidr" to any port "$port" proto tcp || return 1
		else
			run firewall-cmd --permanent "--add-rich-rule=$(access_fw_rich_rule "$cidr" "$port")" || return 1
		fi
		ACCESS_FW_OWNED+=("$rule")
	fi
	return 0
}

# access_fw_wanted - "cidr,port" for every port that should be open now.
access_fw_wanted() {
	[[ "${CONF[FIREWALL_MANAGE]:-no}" == "auto" ]] || return 0
	local cidr port
	local -a ports=()
	cidr=$(access_effective_lan_cidr) || cidr="127.0.0.1/32"
	case "${CONF[ACCESS_MODE]:-localhost}" in
	nginx)
		ports=("${CONF[NTOPNG_PORT]:-3000}" "${CONF[EVEBOX_PORT]:-5636}" "${CONF[PANEL_PORT]:-9800}")
		;;
	lan)
		ports=("${CONF[NTOPNG_PORT]:-3000}" "${CONF[EVEBOX_PORT]:-5636}" "${CONF[PANEL_PORT]:-9800}")
		# The metrics backend binds 0.0.0.0 in lan mode (and nginx does not
		# proxy it), so its own port is opened for LAN_CIDR too.
		[[ "${CONF[METRICS_BACKEND]:-none}" != "none" ]] && ports+=("$(metrics_port "${CONF[METRICS_BACKEND]}")")
		;;
	esac
	for port in "${ports[@]}"; do
		echo "$cidr,$port"
	done
	return 0
}

# access_firewall_sync <wanted rules...> - make the rules we own equal the
# wanted ones: take out what we added earlier and is no longer wanted, add
# what is missing, write the result down. Returns 0 when nothing could be
# done because the firewall is not there (the state stays as it was).
access_firewall_sync() {
	local -a wanted=("$@")
	local tool old rule changed=0
	tool=$(access_fw_tool)
	old=$(state_read_value "$ACCESS_FW_STATE_KEY")
	if [[ -z "$tool" ]]; then
		[[ ${#wanted[@]} -gt 0 ]] && echo "access: FIREWALL_MANAGE=auto, но ни ufw, ни firewalld не найдены - правила не применены" >&2
		return 0
	fi
	# firewalld installed but stopped: its permanent rules would be
	# written, but --reload fails and the ports stay closed or open by
	# accident. Say so and leave it to the administrator.
	if [[ "$tool" == "firewalld" ]] && ! firewall-cmd --state >/dev/null 2>&1; then
		if [[ ${#wanted[@]} -gt 0 || -n "$old" ]]; then
			echo "access: firewalld не запущен - правила не применены (запустите firewalld и повторите reconfigure)" >&2
		fi
		return 0
	fi
	ACCESS_FW_OWNED=()
	for rule in $old; do
		if [[ " ${wanted[*]} " == *" $rule "* ]]; then
			ACCESS_FW_OWNED+=("$rule")
		else
			access_fw_delete "${rule%,*}" "${rule#*,}" || return 1
			changed=1
		fi
	done
	for rule in "${wanted[@]}"; do
		[[ " ${ACCESS_FW_OWNED[*]} " == *" $rule "* ]] && continue
		access_allow_port "${rule%,*}" "${rule#*,}" || return 1
		changed=1
	done
	# firewalld keeps permanent rules apart from the running ones.
	if [[ "$tool" == "firewalld" && "$changed" == 1 ]]; then
		run firewall-cmd --reload || return 1
	fi
	state_write_value "$ACCESS_FW_STATE_KEY" "${ACCESS_FW_OWNED[*]}"
	return 0
}

access_firewall_apply() {
	local -a wanted=()
	local rule
	while IFS= read -r rule; do
		[[ -n "$rule" ]] && wanted+=("$rule")
	done < <(access_fw_wanted)
	access_firewall_sync "${wanted[@]}"
}

# access_firewall_forget - uninstall: take out every rule we added.
access_firewall_forget() {
	access_firewall_sync
}

step_access_check() {
	local mode="${CONF[ACCESS_MODE]:-localhost}"

	if [[ "$mode" == "nginx" ]]; then
		local rendered
		rendered=$(access_render_nginx_full)
		if [[ "${CONF[NGINX_MANAGE]:-snippet}" == "yes" ]]; then
			[[ -f "$(path_nginx_confd)" ]] || return 1
			[[ "$(state_hash_content <"$(path_nginx_confd)")" == "$(printf '%s\n' "$rendered" | state_hash_content)" ]] || return 1
			systemctl is-active --quiet "$NGINX_UNIT" || return 1
		else
			[[ -f "$(path_nginx_snippet)" ]] || return 1
			[[ "$(state_hash_content <"$(path_nginx_snippet)")" == "$(printf '%s\n' "$rendered" | state_hash_content)" ]] || return 1
		fi
	fi

	[[ "$(state_read_value step.access.status)" == "done" ]] || return 1
	return 0
}

step_access_apply() {
	local mode="${CONF[ACCESS_MODE]:-localhost}"

	access_selinux_notice
	access_selinux_ports

	if [[ "$mode" != "localhost" ]]; then
		echo "access: ACCESS_MODE=$mode открывает веб-интерфейсы за пределы localhost." >&2
		if [[ "$mode" == "lan" ]]; then
			echo "access: ntopng/EveBox/панель будут слушать на 0.0.0.0 и видны всей сети LAN_CIDR; пароли передаются по обычному HTTP, если не включён NGINX_TLS." >&2
		fi
	fi

	if [[ "$mode" == "nginx" ]]; then
		if [[ "${CONF[NGINX_TLS]:-none}" == "selfsigned" ]]; then
			local name
			for name in ntopng evebox panel; do
				access_ensure_selfsigned_cert "$name" || return 1
			done
		fi

		local rendered
		rendered=$(access_render_nginx_full)

		if [[ "${CONF[NGINX_MANAGE]:-snippet}" == "yes" ]]; then
			command -v nginx >/dev/null 2>&1 || pkg_install nginx || return 1
			write_rendered_file "$(path_nginx_confd)" "$rendered"
			if ! access_nginx_test_ok; then
				echo "access: nginx -t упал на отрендеренном конфиге, изменения не применены" >&2
				return 1
			fi
			run systemctl enable --now "$NGINX_UNIT" || return 1
			run systemctl reload "$NGINX_UNIT" || return 1
		else
			# snippet: never touches the system nginx.conf or reloads
			# nginx (criterion 3) - just leaves the file for the owner.
			write_rendered_file "$(path_nginx_snippet)" "$rendered"
			echo "access: конфиг nginx не применён автоматически (NGINX_MANAGE=snippet)." >&2
			echo "access: подключите его сами: include $(path_nginx_snippet); - и перезагрузите nginx." >&2
		fi
	fi

	access_firewall_apply || return 1

	state_write_value "step.access.status" "done"
	return 0
}

step_access_plan() {
	local mode="${CONF[ACCESS_MODE]:-localhost}"
	echo "access: ACCESS_MODE=$mode, bind $(access_effective_bind_host)"
	if [[ "$mode" == "nginx" ]]; then
		echo "access: nginx (NGINX_MANAGE=${CONF[NGINX_MANAGE]:-snippet}, TLS=${CONF[NGINX_TLS]:-none})"
	fi
	if [[ "${CONF[FIREWALL_MANAGE]:-no}" == "auto" ]]; then
		echo "access: ufw allow из $(access_effective_lan_cidr 2>/dev/null || echo "?")"
	fi
}

# access_nginx_test_ok - real nginx -t in an isolated directory
# (criterion 4), so a bad snippet never reaches the live nginx.conf.
access_nginx_test_ok() {
	local test_dir
	test_dir=$(mktemp -d)
	mkdir -p "$test_dir/logs" "$test_dir/tmp"
	cat >"$test_dir/nginx.conf" <<EOF_CONF
pid ${test_dir}/nginx.pid;
error_log ${test_dir}/logs/error.log;
events {}
http {
    access_log off;
    client_body_temp_path ${test_dir}/tmp/body;
    proxy_temp_path ${test_dir}/tmp/proxy;
    fastcgi_temp_path ${test_dir}/tmp/fcgi;
    uwsgi_temp_path ${test_dir}/tmp/uwsgi;
    scgi_temp_path ${test_dir}/tmp/scgi;
    include $(path_nginx_confd);
}
EOF_CONF
	local ok=0
	nginx -t -c "$test_dir/nginx.conf" -p "$test_dir/" >/dev/null 2>&1 || ok=1
	rm -rf "$test_dir"
	return "$ok"
}
