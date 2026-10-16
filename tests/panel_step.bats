#!/usr/bin/env bats
# Covers the slice 10 part of the panel step: user and sudoers rule.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	# Own scratch dir: BATS_TEST_TMPDIR does not exist before bats 1.4
	# (Ubuntu 22.04 has 1.2.1), and a shared one leaks files between tests.
	WORK="$(mktemp -d)"
	mkdir -p "$DPISTACK_ROOT/etc"
	cat >"$DPISTACK_ROOT/etc/os-release" <<'EOF_OS'
ID=ubuntu
ID_LIKE=debian
EOF_OS
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	SUDOERS="$DPISTACK_ROOT/etc/sudoers.d/dpistack"
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$WORK"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

@test "sudoers rule names only dpistack-ctl, mode 0440, checked by visudo" {
	run install_base
	[ "$status" -eq 0 ]
	[ "$(grep -v '^#' "$SUDOERS")" = "dpistack ALL=(root) NOPASSWD: $DPISTACK_ROOT/usr/local/sbin/dpistack-ctl" ]
	[ "$(stat -c %a "$SUDOERS")" = "440" ]
	grep -q "^visudo -cf " "$MOCK_CALLS_LOG"
}

@test "a rejected sudoers file is not written and the install stops with code 1" {
	# A failing visudo only for this test; the other mocks stay healthy.
	bad_bin="$(mktemp -d)"
	printf '#!/usr/bin/env bash\necho "visudo: parse error" >&2\nexit 1\n' >"$bad_bin/visudo"
	chmod +x "$bad_bin/visudo"
	PATH="$bad_bin:$PATH" run install_base
	rm -rf "$bad_bin"
	[ "$status" -eq 1 ]
	[ ! -e "$SUDOERS" ]
}

@test "second run reports panel unchanged; hand-edited sudoers needs --force" {
	run install_base
	[ "$status" -eq 0 ]
	run bash "$REPO_DIR/install.sh" status --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[[ "$output" == *"panel: в порядке"* ]]

	echo "# hand edit" >>"$SUDOERS"
	run install_base
	[ "$status" -eq 0 ]
	grep -q "hand edit" "$SUDOERS"
}

@test "dry-run writes no sudoers file and calls no useradd" {
	run bash "$REPO_DIR/install.sh" install -y --dry-run \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[ ! -e "$SUDOERS" ]
	run grep -c "^useradd\|^visudo" "$MOCK_CALLS_LOG"
	[ "$output" = "0" ]
}

@test "install -y writes the panel password as argon2id, 0640, group set once the user exists" {
	run install_base
	[ "$status" -eq 0 ]
	auth="$DPISTACK_ROOT/etc/dpistack/panel.auth"
	[[ "$(cat "$auth")" == '$argon2id$'* ]]
	[ "$(stat -c %a "$auth")" = "640" ]
	grep -q "^chown root:dpistack $auth" "$MOCK_CALLS_LOG"

	# A second run keeps the existing hash.
	before="$(cat "$auth")"
	run install_base
	[ "$(cat "$auth")" = "$before" ]
}

# installer_copy <dir> - a copy of the installer that can hold a ready
# dpistack-panel next to install.sh without touching the repository.
installer_copy() {
	mkdir -p "$1"
	(cd "$REPO_DIR" && cp -a --parents install.sh lib templates bin tests/data panel "$1")
}

unit_file() {
	echo "$DPISTACK_ROOT/etc/systemd/system/dpistack-panel.service"
}

@test "criterion 1: install builds the panel, writes the unit and starts it" {
	run install_base
	[ "$status" -eq 0 ]
	[ -x "$DPISTACK_ROOT/usr/local/bin/dpistack-panel" ]
	grep -q "^go build .* -o .* ./cmd/panel" "$MOCK_CALLS_LOG"
	grep -qx "ExecStart=$DPISTACK_ROOT/usr/local/bin/dpistack-panel -addr 127.0.0.1:9800 -access localhost -auth-file $DPISTACK_ROOT/etc/dpistack/panel.auth -health-file $DPISTACK_ROOT/var/lib/dpistack/health.json -ctl $DPISTACK_ROOT/usr/local/sbin/dpistack-ctl -metrics-file $DPISTACK_ROOT/var/lib/dpistack/metrics.json -eve-file $DPISTACK_ROOT/var/log/suricata/eve.json" "$(unit_file)"
	grep -q "^systemctl enable --now dpistack-panel.service" "$MOCK_CALLS_LOG"
}

@test "slice 22: metrics.json is created for the panel user and an existing history is kept" {
	run install_base
	[ "$status" -eq 0 ]
	mfile="$DPISTACK_ROOT/var/lib/dpistack/metrics.json"
	[ -f "$mfile" ]
	[ "$(stat -c %a "$mfile")" = "640" ]
	grep -q "^chown dpistack:dpistack $mfile" "$MOCK_CALLS_LOG"
	echo '{"version":1}' >"$mfile"
	run install_base --force
	[ "$status" -eq 0 ]
	grep -q '"version":1' "$mfile"
}

@test "slice 22: the panel unit gets the metrics file, and nothing else in the state directory is handed over" {
	run install_base
	[ "$status" -eq 0 ]
	grep -q -- "-metrics-file $DPISTACK_ROOT/var/lib/dpistack/metrics.json" "$(unit_file)"
	! grep -E "^chown .*dpistack:dpistack .*/var/lib/dpistack/?( |$)" "$MOCK_CALLS_LOG"
	! grep -E "^chown .*dpistack:dpistack .*(health.json|/state|backups|staging)" "$MOCK_CALLS_LOG"
}

@test "slice 21: EVE_FILE=no leaves -eve-file out of the unit, so the panel says viewing is off" {
	run install_base --set EVE_FILE=no --set EVEBOX_DB=elasticsearch --set EVEBOX_ES_URL=http://es.local:9200
	[ "$status" -eq 0 ]
	grep -q "^ExecStart=.*dpistack-panel " "$(unit_file)"
	! grep -q -- "-eve-file" "$(unit_file)"
}

@test "slice 21: changing EVE_FILE on reconfigure rewrites the panel unit" {
	run install_base --set EVEBOX_DB=elasticsearch --set EVEBOX_ES_URL=http://es.local:9200
	[ "$status" -eq 0 ]
	grep -q -- "-eve-file" "$(unit_file)"
	run bash "$REPO_DIR/install.sh" reconfigure -y --set EVE_FILE=no
	[ "$status" -eq 0 ]
	! grep -q -- "-eve-file" "$(unit_file)"
}

@test "criterion 1: the generated password is shown once and never stored in plain text" {
	run install_base
	[ "$status" -eq 0 ]
	pw="$(printf '%s\n' "$output" | sed -n 's/^Создан пароль панели .*: \([A-Za-z0-9]\{24\}\)$/\1/p')"
	[ -n "$pw" ]
	[ "$(printf '%s\n' "$output" | grep -c "$pw")" -eq 1 ]
	! grep -rqF "$pw" "$DPISTACK_ROOT"
	! grep -qF "$pw" "$MOCK_CALLS_LOG"

	run install_base
	[[ "$output" != *"Создан пароль панели"* ]]
}

@test "criterion 1: a password from DPISTACK_PANEL_PASSWORD is not printed" {
	DPISTACK_PANEL_PASSWORD="my-own-secret-pass" run install_base
	[ "$status" -eq 0 ]
	[[ "$output" != *"my-own-secret-pass"* ]]
	[[ "$output" != *"Создан пароль панели"* ]]
}

@test "criterion 4: the unit has MemoryMax and CPUQuota, no NoNewPrivileges, no ProtectSystem" {
	run install_base
	[ "$status" -eq 0 ]
	grep -q '^MemoryMax=64M$' "$(unit_file)"
	grep -q '^CPUQuota=20%$' "$(unit_file)"
	! grep -qE '^(NoNewPrivileges|ProtectSystem)' "$(unit_file)"
}

@test "the unit follows ACCESS_MODE: lan binds all addresses with the resolved CIDR" {
	MOCK_IP_DEFAULT_IFACE=enp2s0 MOCK_IP_LINK_ROUTE=192.168.10.0/24 \
		run install_base --set ACCESS_MODE=lan --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	grep -q ' -addr 0.0.0.0:9800 -access lan -lan-cidr 192.168.10.0/24 ' "$(unit_file)"
}

@test "lan with an undetectable LAN_CIDR keeps the panel closed to everyone but the host" {
	run install_base --set ACCESS_MODE=lan --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	grep -q ' -addr 0.0.0.0:9800 -access lan -lan-cidr 127.0.0.1/32 ' "$(unit_file)"
}

@test "the unit follows ACCESS_MODE: nginx keeps the panel on loopback, behind nginx, and passes the CIDR" {
	run install_base --set ACCESS_MODE=nginx --set ACCESS_CONFIRM=yes --set NGINX_MANAGE=snippet \
		--set LAN_CIDR=10.1.0.0/16 --set PANEL_PORT=9900
	[ "$status" -eq 0 ]
	# nginx takes 9900, the panel itself moves to 19900.
	grep -q ' -addr 127.0.0.1:19900 -access nginx -lan-cidr 10.1.0.0/16 ' "$(unit_file)"
}

@test "criterion 5: PANEL_SOURCE=prebuilt without a ready binary stops preflight with code 3" {
	run install_base --set PANEL_SOURCE=prebuilt
	[ "$status" -eq 3 ]
	[[ "$output" == *"нет готового бинарника dpistack-panel"* ]]
	[ ! -e "$(unit_file)" ]
	! grep -q "^apt-get install" "$MOCK_CALLS_LOG"
}

@test "criterion 5: PANEL_SOURCE=prebuilt installs the binary that lies next to install.sh" {
	installer_copy "$WORK/inst"
	printf '#!/bin/sh\necho prebuilt\n' >"$WORK/inst/dpistack-panel"
	chmod 0755 "$WORK/inst/dpistack-panel"
	run bash "$WORK/inst/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set PANEL_SOURCE=prebuilt
	[ "$status" -eq 0 ]
	cmp "$WORK/inst/dpistack-panel" "$DPISTACK_ROOT/usr/local/bin/dpistack-panel"
	! grep -q "^go build" "$MOCK_CALLS_LOG"
}

@test "a Go older than panel/go.mod and no ready binary stop preflight with code 3" {
	MOCK_GO_VERSION=go1.20.1 run install_base
	[ "$status" -eq 3 ]
	[[ "$output" == *"Go 1.20.1 старше требуемого"* ]]
	[[ "$output" == *"нет готового бинарника"* ]]
}

@test "a failing build stops the install and leaves no unit behind" {
	MOCK_GO_BUILD_FAIL=1 run install_base
	[ "$status" -ne 0 ]
	[ ! -e "$(unit_file)" ]
	[ ! -e "$DPISTACK_ROOT/usr/local/bin/dpistack-panel" ]
}

@test "criterion 6: a second run changes nothing and builds nothing" {
	run install_base
	[ "$status" -eq 0 ]
	: >"$MOCK_CALLS_LOG"
	run install_base
	[ "$status" -eq 0 ]
	! grep -q "^go build" "$MOCK_CALLS_LOG"
	! grep -q "dpistack-panel.service" "$MOCK_CALLS_LOG"
	run bash "$REPO_DIR/install.sh" status --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[[ "$output" == *"panel: в порядке"* ]]
}

@test "a changed source rebuilds the binary and restarts the unit" {
	installer_copy "$WORK/inst"
	inst() {
		bash "$WORK/inst/install.sh" install -y \
			--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	}
	run inst
	[ "$status" -eq 0 ]
	: >"$MOCK_CALLS_LOG"
	echo "// changed" >>"$WORK/inst/panel/internal/api/api.go"
	run inst
	[ "$status" -eq 0 ]
	grep -q "^go build" "$MOCK_CALLS_LOG"
	grep -q "^systemctl restart dpistack-panel.service" "$MOCK_CALLS_LOG"
}

@test "a changed PANEL_PORT rewrites the unit and restarts the panel" {
	run install_base
	[ "$status" -eq 0 ]
	: >"$MOCK_CALLS_LOG"
	run install_base --set PANEL_PORT=9911
	[ "$status" -eq 0 ]
	grep -q ' -addr 127.0.0.1:9911 ' "$(unit_file)"
	grep -q "^systemctl restart dpistack-panel.service" "$MOCK_CALLS_LOG"
	! grep -q "^go build" "$MOCK_CALLS_LOG"
}

@test "dry-run writes no unit and builds nothing" {
	run bash "$REPO_DIR/install.sh" install -y --dry-run \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[ ! -e "$(unit_file)" ]
	[ ! -e "$DPISTACK_ROOT/usr/local/bin/dpistack-panel" ]
	! grep -q "^go build" "$MOCK_CALLS_LOG"
}

@test "uninstall stops the panel and removes its unit and binary" {
	run install_base
	[ "$status" -eq 0 ]
	: >"$MOCK_CALLS_LOG"
	run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$(unit_file)" ]
	[ ! -e "$DPISTACK_ROOT/usr/local/bin/dpistack-panel" ]
	grep -q "^systemctl disable --now dpistack-panel.service" "$MOCK_CALLS_LOG"
}

# The ready binary a release archive ships for this CPU.
release_binary_name() {
	case "$(uname -m)" in
	x86_64) echo dpistack-panel-linux-amd64 ;;
	aarch64 | arm64) echo dpistack-panel-linux-arm64 ;;
	*) echo "dpistack-panel-linux-$(uname -m)" ;;
	esac
}

@test "PANEL_SOURCE=auto (the default) installs the release binary for this CPU and builds nothing" {
	installer_copy "$WORK/inst"
	printf '#!/bin/sh\necho release\n' >"$WORK/inst/$(release_binary_name)"
	chmod 0755 "$WORK/inst/$(release_binary_name)"
	# A binary of another CPU lies there too and must be ignored.
	printf '#!/bin/sh\necho other\n' >"$WORK/inst/dpistack-panel-linux-riscv64"
	run bash "$WORK/inst/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	cmp "$WORK/inst/$(release_binary_name)" "$DPISTACK_ROOT/usr/local/bin/dpistack-panel"
	! grep -q "^go build" "$MOCK_CALLS_LOG"
}

@test "PANEL_SOURCE=auto builds from panel/ when no ready binary lies next to install.sh" {
	run install_base
	[ "$status" -eq 0 ]
	grep -q "^go build" "$MOCK_CALLS_LOG"
}

@test "PANEL_SOURCE=build builds even when a ready binary lies next to install.sh" {
	installer_copy "$WORK/inst"
	printf '#!/bin/sh\necho release\n' >"$WORK/inst/$(release_binary_name)"
	chmod 0755 "$WORK/inst/$(release_binary_name)"
	run bash "$WORK/inst/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set PANEL_SOURCE=build
	[ "$status" -eq 0 ]
	grep -q "^go build" "$MOCK_CALLS_LOG"
}
