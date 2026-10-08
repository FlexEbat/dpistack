#!/usr/bin/env bash
# "verify" step and the checks behind `dpistack-ctl test` (tech.md 10).
# The same functions serve the step (TEST_ON_INSTALL=yes) and the ctl
# command, so the two cannot drift apart.
#
# Callers set before verify_run:
#   VERIFY_HTTPS_URL  TEST_HTTPS_URL
#   VERIFY_BT_LIVE    TEST_BT_LIVE (yes|no)
#   VERIFY_IFACES     IFACES (comma list)

VERIFY_TESTS=(bittorrent https)
VERIFY_DATA_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../tests/data" &>/dev/null && pwd)"
VERIFY_TEMPLATE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../templates" &>/dev/null && pwd)"
VERIFY_FAILED_NAMES=()
# Seconds to wait for a live event. The variable exists so tests do not
# sit through the 20 s of a real run.
VERIFY_WAIT="${DPISTACK_TEST_WAIT:-20}"

# shellcheck disable=SC2034 # set by the callers, read by the tests below
VERIFY_HTTPS_URL="" VERIFY_BT_LIVE="no" VERIFY_IFACES=""

# Result of the test that just ran.
VERIFY_STATUS=""
VERIFY_DETAIL=""

verify_json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/ }"
	s="${s//$'\t'/ }"
	printf '%s' "$s"
}

verify_set() {
	VERIFY_STATUS="$1"
	VERIFY_DETAIL="$2"
}

verify_p2p_enabled() {
	[[ -f "$(path_suricata_enable_conf)" ]] &&
		grep -qx 'group:emerging-p2p.rules' "$(path_suricata_enable_conf)"
}

verify_plugin_loaded() {
	[[ -e "$(path_suricata_ndpi_plugin)" ]]
}

verify_eve_size() {
	stat -c %s "$(path_suricata_eve_json)" 2>/dev/null || echo 0
}

# verify_eve_since <offset> - the part of the main eve.json written
# after <offset>; a shrunk file means rotation, so read it whole.
verify_eve_since() {
	local offset="$1" eve size
	eve=$(path_suricata_eve_json)
	size=$(verify_eve_size)
	((size < offset)) && offset=0
	tail -c +$((offset + 1)) "$eve" 2>/dev/null
}

# verify_bt_signature <eve-file> - first BitTorrent alert signature.
verify_bt_signature() {
	grep -E '"event_type": *"alert"' "$1" 2>/dev/null |
		grep -oE '"signature": *"[^"]*BitTorrent[^"]*"' | head -1 |
		sed -E 's/^"signature": *"//; s/"$//'
}

verify_test_bittorrent() {
	local p2p=0 plugin=0
	verify_p2p_enabled && p2p=1
	verify_plugin_loaded && plugin=1
	if ((!p2p && !plugin)); then
		verify_set skip "нет ни правил группы emerging-p2p, ни плагина nDPI: включите emerging-p2p (RULES_GROUPS) или NDPI_ENABLE=yes"
		return 0
	fi
	if ! command -v suricata >/dev/null 2>&1; then
		verify_set fail "suricata не установлен"
		return 0
	fi
	local pcap="$VERIFY_DATA_DIR/bittorrent.pcap"
	if [[ ! -r "$pcap" ]]; then
		verify_set fail "не найден $pcap"
		return 0
	fi

	local tmp rule_files plugins
	tmp=$(mktemp -d)
	rule_files=""
	if [[ -f "$(path_suricata_ruleset)" ]]; then
		rule_files="  - $(path_suricata_ruleset)"
	fi
	plugins=""
	if ((plugin)); then
		# With the plugin loaded the test brings its own rule: the plugin
		# adds no ndpi.* fields to EVE (A2), only the rule keywords.
		cat >"$tmp/dpistack-test.rules" <<'RULES'
alert tcp any any -> any any (msg:"dpistack test nDPI BitTorrent"; requires: keyword ndpi-protocol; ndpi-protocol:BitTorrent; sid:9000001; rev:1;)
RULES
		rule_files+="${rule_files:+$'\n'}  - $tmp/dpistack-test.rules"
		plugins=$'plugins:\n'"  - $(path_suricata_ndpi_plugin)"
	fi
	render_template "$VERIFY_TEMPLATE_DIR/suricata-test.yaml.tpl" \
		"RULE_DIR=$(dirname "$(path_suricata_ruleset)")" \
		"RULE_FILES=$rule_files" \
		"PLUGINS=$plugins" >"$tmp/suricata-test.yaml" || {
		rm -rf "$tmp"
		verify_set fail "не удалось подготовить suricata-test.yaml"
		return 0
	}

	local out rc sig
	out=$(suricata -r "$pcap" -c "$tmp/suricata-test.yaml" -l "$tmp" -k none 2>&1)
	rc=$?
	sig=$(verify_bt_signature "$tmp/eve.json")
	rm -rf "$tmp"

	if [[ -z "$sig" ]]; then
		if ((rc != 0)); then
			verify_set fail "suricata -r завершился с кодом $rc: $(printf '%s' "$out" | tail -1)"
		else
			verify_set fail "реплей bittorrent.pcap не дал алерта с BitTorrent: проверьте, что правила emerging-p2p загружены в suricata.rules или плагин nDPI подключён"
		fi
		return 0
	fi
	verify_set pass "сигнатура: $sig"
	[[ "$VERIFY_BT_LIVE" == "yes" ]] && verify_bittorrent_live "$pcap"
	return 0
}

# TEST_BT_LIVE=yes: the same pcap goes out of the first capture
# interface and the event is looked for in the main eve.json.
verify_bittorrent_live() {
	local pcap="$1" iface="${VERIFY_IFACES%%,*}" offset i
	if ! command -v tcpreplay >/dev/null 2>&1; then
		verify_set fail "TEST_BT_LIVE=yes, но tcpreplay не установлен"
		return 0
	fi
	offset=$(verify_eve_size)
	if ! tcpreplay -i "$iface" "$pcap" >/dev/null 2>&1; then
		verify_set fail "tcpreplay не смог отправить pcap в $iface"
		return 0
	fi
	for ((i = 0; i < VERIFY_WAIT; i++)); do
		if verify_eve_since "$offset" | grep -E '"event_type": *"alert"' | grep -qF 'BitTorrent'; then
			verify_set pass "$VERIFY_DETAIL; живой прогон через $iface: событие в eve.json"
			return 0
		fi
		sleep 1
	done
	verify_set fail "офлайн-проверка прошла, но в живом eve.json нет события после tcpreplay в $iface"
}

verify_url_host() {
	printf '%s' "$1" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#^[^@/]*@##; s#[/?\#].*$##; s#:[0-9]+$##'
}

verify_test_https() {
	local url="$VERIFY_HTTPS_URL" host eve offset i cerr rc
	host=$(verify_url_host "$url")
	if [[ -z "$host" ]]; then
		verify_set fail "в TEST_HTTPS_URL нет хоста: $url"
		return 0
	fi
	eve=$(path_suricata_eve_json)
	if [[ ! -f "$eve" ]]; then
		verify_set fail "не найден $eve: Suricata не пишет события, запущена ли она и включён ли EVE_FILE"
		return 0
	fi

	offset=$(verify_eve_size)
	# --max-time keeps a hung network from blocking the panel request.
	cerr=$(curl -sS --max-time 15 -o /dev/null "$url" 2>&1)
	rc=$?
	if ((rc != 0)); then
		verify_set fail "curl не прошёл (код $rc): $(printf '%s' "$cerr" | head -1)"
		return 0
	fi

	for ((i = 0; i < VERIFY_WAIT; i++)); do
		if verify_eve_since "$offset" | grep -F '"event_type":"tls"' | grep -qF "\"sni\":\"$host\""; then
			verify_set pass "событие tls с sni=$host получено"
			return 0
		fi
		sleep 1
	done

	local default_if hint=""
	default_if=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
	if [[ -n "$default_if" && ",$VERIFY_IFACES," != *",$default_if,"* ]]; then
		hint="curl идёт через $default_if, а Suricata слушает $VERIFY_IFACES: пакеты не видны"
	else
		hint="проверьте, что Suricata видит интерфейс, через который идёт curl (IFACES=$VERIFY_IFACES)"
	fi
	verify_set fail "curl прошёл, но события tls с sni=$host нет за ${VERIFY_WAIT} с: $hint"
}

# verify_record <name> <status> <detail> <ms> - keeps the last result
# of every test in tests-last.json, one object per line so the file can
# be merged without jq. A run of one test leaves the other's result.
verify_record() {
	local name="$1" status="$2" detail="$3" ms="$4" file line
	local -a keep=()
	file=$(path_tests_last_json)
	mkdir -p "$(dirname "$file")"
	if [[ -f "$file" ]]; then
		while IFS= read -r line; do
			[[ "$line" == '{"name"'* ]] || continue
			line="${line%,}"
			[[ "$line" == '{"name":"'"$name"'"'* ]] && continue
			keep+=("$line")
		done <"$file"
	fi
	keep+=("$(printf '{"name":"%s","status":"%s","detail":"%s","duration_ms":%s,"timestamp":"%s"}' \
		"$name" "$status" "$(verify_json_escape "$detail")" "$ms" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")")
	local i
	{
		echo '{"results":['
		for i in "${!keep[@]}"; do
			if ((i < ${#keep[@]} - 1)); then
				echo "${keep[$i]},"
			else
				echo "${keep[$i]}"
			fi
		done
		echo ']}'
	} | atomic_write "$file"
	chmod 0644 "$file"
}

# verify_run <json:0|1> <name...> - runs the tests in order, records
# each, prints the result and returns 1 when any test failed.
verify_run() {
	local json="$1" name t0 ms failed=0 first=1
	shift
	((json)) && printf '['
	for name in "$@"; do
		t0=$(($(date +%s%N) / 1000000))
		"verify_test_$name"
		ms=$(($(date +%s%N) / 1000000 - t0))
		verify_record "$name" "$VERIFY_STATUS" "$VERIFY_DETAIL" "$ms"
		if [[ "$VERIFY_STATUS" == "fail" ]]; then
			failed=1
			VERIFY_FAILED_NAMES+=("$name")
		fi
		if ((json)); then
			((first)) || printf ','
			first=0
			printf '{"name":"%s","status":"%s","detail":"%s","duration_ms":%s}' \
				"$name" "$VERIFY_STATUS" "$(verify_json_escape "$VERIFY_DETAIL")" "$ms"
		else
			printf '%s: %s (%s мс) - %s\n' "$name" "$VERIFY_STATUS" "$ms" "$VERIFY_DETAIL"
		fi
	done
	((json)) && printf ']\n'
	return "$failed"
}

verify_final_report() {
	((${#VERIFY_FAILED_NAMES[@]} > 0)) || return 0
	echo "ВНИМАНИЕ: проверочные тесты не прошли: ${VERIFY_FAILED_NAMES[*]} (установка не отменена, повторить: dpistack test all)"
}

step_verify_check() {
	[[ "${CONF[TEST_ON_INSTALL]:-yes}" == "yes" ]] || return 0
	local file
	file=$(path_tests_last_json)
	[[ -f "$file" ]] || return 1
	grep -q '"name":"bittorrent"' "$file" && grep -q '"name":"https"' "$file"
}

step_verify_apply() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "+ dpistack-ctl test all"
		return 0
	fi
	VERIFY_HTTPS_URL="${CONF[TEST_HTTPS_URL]:-https://example.com}"
	VERIFY_BT_LIVE="${CONF[TEST_BT_LIVE]:-no}"
	VERIFY_IFACES="${CONF[IFACES]:-}"
	# A failed test never cancels the install: it lands in the final report.
	verify_run 0 "${VERIFY_TESTS[@]}" || true
	return 0
}

step_verify_plan() {
	if [[ "${CONF[TEST_ON_INSTALL]:-yes}" == "yes" ]]; then
		echo "verify: проверочные тесты (${VERIFY_TESTS[*]}) после установки"
	else
		echo "verify: TEST_ON_INSTALL=no, тесты не запускаются"
	fi
}
