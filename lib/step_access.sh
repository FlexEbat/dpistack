#!/usr/bin/env bash
# Access: binds ntopng/EveBox/panel per ACCESS_MODE, an nginx reverse
# proxy for ACCESS_MODE=nginx, and firewall rules for FIREWALL_MANAGE
# (tech.md slice 7). ntopng/evebox stay on 127.0.0.1 for localhost and
# nginx modes (nginx does the proxying); lan makes them bind 0.0.0.0
# directly - access_effective_bind_host is what their own render
# functions call, so there is exactly one place that decides this.

NGINX_UNIT="nginx.service"

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
	run mkdir -p "$(access_tls_dir)"
	run openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
		-keyout "$key" -out "$cert" -subj "/CN=dpistack-${name}"
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
		access_render_nginx_service "$name" "$port" "$port" "$cidr"
		echo
	done
}

access_selinux_notice() {
	command -v getenforce >/dev/null 2>&1 || return 0
	local mode
	mode=$(getenforce 2>/dev/null)
	if [[ "$mode" == "Enforcing" ]]; then
		echo "access: SELinux в режиме Enforcing. Нужны setsebool/semanage для портов и прокси nginx - применяются только в слайсе 26 (поддержка Fedora/RHEL), сейчас не трогаю." >&2
	fi
}

access_firewall_apply() {
	[[ "${CONF[FIREWALL_MANAGE]:-no}" == "auto" ]] || return 0
	command -v ufw >/dev/null 2>&1 || {
		echo "access: FIREWALL_MANAGE=auto, но ufw не найден - правила не применены" >&2
		return 0
	}
	local cidr
	cidr=$(access_effective_lan_cidr) || cidr="127.0.0.1/32"
	local port
	if [[ "${CONF[ACCESS_MODE]:-localhost}" == "nginx" ]]; then
		for port in "${CONF[NTOPNG_PORT]:-3000}" "${CONF[EVEBOX_PORT]:-5636}" "${CONF[PANEL_PORT]:-9800}"; do
			run ufw allow from "$cidr" to any port "$port" proto tcp
		done
	elif [[ "${CONF[ACCESS_MODE]:-localhost}" == "lan" ]]; then
		for port in "${CONF[NTOPNG_PORT]:-3000}" "${CONF[EVEBOX_PORT]:-5636}" "${CONF[PANEL_PORT]:-9800}"; do
			run ufw allow from "$cidr" to any port "$port" proto tcp
		done
	fi
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
				access_ensure_selfsigned_cert "$name"
			done
		fi

		local rendered
		rendered=$(access_render_nginx_full)

		if [[ "${CONF[NGINX_MANAGE]:-snippet}" == "yes" ]]; then
			command -v nginx >/dev/null 2>&1 || pkg_install nginx
			write_rendered_file "$(path_nginx_confd)" "$rendered"
			if ! access_nginx_test_ok; then
				echo "access: nginx -t упал на отрендеренном конфиге, изменения не применены" >&2
				return 1
			fi
			run systemctl enable --now "$NGINX_UNIT"
			run systemctl reload "$NGINX_UNIT"
		else
			# snippet: never touches the system nginx.conf or reloads
			# nginx (criterion 3) - just leaves the file for the owner.
			write_rendered_file "$(path_nginx_snippet)" "$rendered"
			echo "access: конфиг nginx не применён автоматически (NGINX_MANAGE=snippet)." >&2
			echo "access: подключите его сами: include $(path_nginx_snippet); - и перезагрузите nginx." >&2
		fi
	fi

	access_firewall_apply

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
