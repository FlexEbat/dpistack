#!/usr/bin/env bats
# Slice 44 (18.44), Settings v2: what a key depends on and what a change
# touches (in `settings list --json`), and the profiles.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0,eth1"
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	PROFILES="$DPISTACK_ROOT/var/lib/dpistack/profiles.json"
	AUDIT="$DPISTACK_ROOT/var/lib/dpistack/audit/audit.jsonl"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

key() { jq -c --arg k "$1" '.keys[] | select(.key==$k)' <<<"$LIST"; }

@test "settings list --json: every key says what it touches and when it applies" {
	LIST=$("$CTL" settings list --json)
	[ "$(key IFACES | jq -c .touches)" = '["Suricata","ntopng"]' ]
	[ "$(key IFACES | jq -c .steps)" = '["suricata","ntopng"]' ]
	[ "$(key SURICATA_ENABLE | jq -c .depends)" = '[]' ]
	[ "$(key LAN_CIDR | jq -c .depends)" = '[{"key":"ACCESS_MODE","op":"=","values":["lan"]}]' ]
	[ "$(key IPS_NFQ_CHAINS | jq -c '[.depends[].key]')" = '["SURICATA_ENABLE","SURICATA_MODE"]' ]
	[ "$(key METRICS_BACKEND_PORT | jq -c .depends)" = '[{"key":"METRICS_BACKEND","op":"!=","values":["none"]}]' ]
	[ "$(key ALERT_TG_CHAT_ID | jq -c '.depends[1]')" = '{"key":"ALERT_CHANNELS","op":"~","values":["tg"]}' ]
	[ "$(key NGINX_CERT | jq -c '[.depends[].key]')" = '["ACCESS_MODE","NGINX_TLS"]' ]
	# a secret still shows no value
	[ "$(key ALERT_TG_TOKEN | jq -r .value)" = "" ]
	[ "$(jq '[.keys[] | select((.steps | type) != "array" or (.touches | type) != "array" or (.depends | type) != "array")] | length' <<<"$LIST")" = 0 ]
}

@test "settings list --json: every step has a label and every dependency names a real key and a real value" {
	LIST=$("$CTL" settings list --json)
	[ "$(jq '[.keys[] | select((.touches | length) != (.steps | length))] | length' <<<"$LIST")" = 0 ]
	# no step falls back to its bare id for want of a label
	run bash -c "source '$REPO_DIR/lib/schema.sh'; for k in \"\${SCHEMA_KEYS[@]}\"; do for s in \${SCHEMA_STEPS[\$k]}; do [[ -n \"\${SCHEMA_STEP_LABEL[\$s]:-}\" ]] || echo \"no label for step \$s (\$k)\"; done; done"
	[ -z "$output" ]
	# every dependency key exists, and an enum value is one of its options
	run jq -r '(.keys | map({(.key): .options}) | add) as $opt
		| .keys[] | .key as $k | .depends[] | select(($opt[.key] // null) == null) | "unknown key \(.key) in \($k)"' <<<"$LIST"
	[ -z "$output" ]
	run jq -r '(.keys | map({(.key): {type, options}}) | add) as $m
		| .keys[] | .key as $k | .depends[] | select(.op != "~" and $m[.key].type == "enum") | .values[] as $v
		| select(($m[.key].options | index($v)) == null) | "bad value \($v) of \(.key) in \($k)"' <<<"$LIST"
	[ -z "$output" ]
}

@test "the dependency table agrees with the rules of the guided setup over many configs" {
	cd "$REPO_DIR"
	run bash -c '
		export DPISTACK_ROOT; DPISTACK_ROOT=$(mktemp -d)
		source lib/paths.sh; source lib/common.sh; source lib/schema.sh; source lib/menu.sh
		declare -A CONF
		val() { echo "${CONF[$1]-${SCHEMA_DEFAULT[$1]}}"; }
		bad=0; n=0
		check() {
			local k s o
			for k in "${SCHEMA_KEYS[@]}"; do
				[[ $k == METRICS_TOKEN ]] && continue # the guided setup never asks it, a different reason
				n=$((n + 1))
				if menu_key_skipped "$k"; then s=1; else s=0; fi
				if schema_depends_ok "$k" val; then o=0; else o=1; fi
				if [[ $s != "$o" ]]; then echo "MISMATCH $k menu_skips=$s table_skips=$o"; bad=1; fi
			done
		}
		for k in "${SCHEMA_KEYS[@]}"; do CONF[$k]="${SCHEMA_DEFAULT[$k]}"; done
		# every value of every switch the rules read, alone and in pairs
		dk="SURICATA_ENABLE SURICATA_MODE NDPI_ENABLE RULES_ENABLE EVEBOX_ENABLE EVEBOX_DB NTOPNG_ENABLE PANEL_ENABLE ACCESS_MODE NGINX_TLS METRICS_BACKEND NODE_EXPORTER_ENABLE GRAFANA_ENABLE WATCH_ENABLE ALERT_CHANNELS"
		declare -a combos=()
		for k in $dk; do
			if [[ $k == ALERT_CHANNELS ]]; then opts="panel,log panel,tg mail tg,mail tg,log,mail"; else opts="${SCHEMA_OPTIONS[$k]//,/ }"; fi
			for o in $opts; do combos+=("$k=$o"); done
		done
		check
		for a in "${combos[@]}"; do
			save_a="${CONF[${a%%=*}]}"; CONF[${a%%=*}]="${a#*=}"
			check
			for b in "${combos[@]}"; do
				[[ ${a%%=*} == "${b%%=*}" ]] && continue
				save_b="${CONF[${b%%=*}]}"; CONF[${b%%=*}]="${b#*=}"
				check
				CONF[${b%%=*}]="$save_b"
			done
			CONF[${a%%=*}]="$save_a"
		done
		echo "checked $n comparisons"
		exit $bad'
	[ "$status" -eq 0 ]
	[[ "$output" == *"checked"* ]]
	[[ "$output" != *MISMATCH* ]]
}

# --- profiles ---

@test "profile save, list, show: a profile keeps its keys and says who saved it" {
	run "$CTL" settings profile save lan-watch WATCH_INTERVAL_SEC=30 ACCESS_MODE=lan --by admin
	[ "$status" -eq 0 ]
	run "$CTL" settings profile list --json
	[ "$(jq -c '.profiles | map({name, count, by})' <<<"$output")" = '[{"name":"lan-watch","count":2,"by":"admin"}]' ]
	run "$CTL" settings profile show lan-watch --json
	[ "$(jq -c .keys <<<"$output")" = '{"ACCESS_MODE":"lan","WATCH_INTERVAL_SEC":"30"}' ] || [ "$(jq -c .keys <<<"$output")" = '{"WATCH_INTERVAL_SEC":"30","ACCESS_MODE":"lan"}' ]
	run "$CTL" settings profile show lan-watch
	[[ "$output" == *"WATCH_INTERVAL_SEC=30"* && "$output" == *"ACCESS_MODE=lan"* ]]
	[ "$(stat -c %a "$PROFILES")" = 644 ]
	run "$CTL" settings profile list
	[[ "$output" == *"lan-watch"*"2 keys"* ]]
}

@test "profile save: pairs may come from stdin, so a value with odd characters is possible" {
	run bash -c "printf 'BPF_FILTER=not (host 10.0.0.1 or port 22)\nWATCH_INTERVAL_SEC=45\n' | '$CTL' settings profile save odd --by admin"
	[ "$status" -eq 0 ]
	[ "$("$CTL" settings profile show odd --json | jq -r .keys.BPF_FILTER)" = "not (host 10.0.0.1 or port 22)" ]
}

@test "profile save: saving a name again replaces it" {
	"$CTL" settings profile save p1 WATCH_INTERVAL_SEC=30
	"$CTL" settings profile save p1 WATCH_INTERVAL_SEC=45 WATCH_REPEAT_MIN=10
	run "$CTL" settings profile show p1 --json
	[ "$(jq -r .keys.WATCH_INTERVAL_SEC <<<"$output")" = 45 ]
	[ "$("$CTL" settings profile list --json | jq '.profiles | length')" = 1 ]
}

@test "profile save: refuses what settings check refuses, and what never belongs in a profile" {
	run "$CTL" settings profile save bad STATS_INTERVAL_SEC=9999
	[ "$status" -eq 3 ]
	run "$CTL" settings profile save bad NOSUCH=1
	[ "$status" -eq 5 ]
	run "$CTL" settings profile save bad ALERT_TG_TOKEN=x
	[ "$status" -eq 5 ]
	[[ "$output" == *"secret"* ]]
	run "$CTL" settings profile save bad WATCH_INTERVAL_SEC=30 WATCH_INTERVAL_SEC=40
	[ "$status" -eq 5 ]
	run "$CTL" settings profile save bad novalue
	[ "$status" -eq 5 ]
	run "$CTL" settings profile save bad
	[ "$status" -eq 2 ] || [ "$status" -eq 5 ]
	[ ! -e "$PROFILES" ]
}

@test "profile names: a short lowercase word, nothing else" {
	for n in "Upper" "a b" "../x" "-x" "a;b" "$(printf 'a%.0s' $(seq 1 33))"; do
		run "$CTL" settings profile save "$n" WATCH_INTERVAL_SEC=30
		[ "$status" -eq 5 ]
	done
	run "$CTL" settings profile save "" WATCH_INTERVAL_SEC=30
	[ "$status" -eq 2 ]
	run "$CTL" settings profile save ok_name-1 WATCH_INTERVAL_SEC=30
	[ "$status" -eq 0 ]
	run "$CTL" settings profile show "../x"
	[ "$status" -eq 5 ]
	run "$CTL" settings profile frobnicate
	[ "$status" -eq 2 ]
}

@test "profile limits: 50 profiles and 100 keys" {
	for i in $(seq 1 50); do "$CTL" settings profile save "p$i" WATCH_INTERVAL_SEC=30; done
	run "$CTL" settings profile save one-too-many WATCH_INTERVAL_SEC=30
	[ "$status" -eq 5 ]
	# replacing one of the 50 is still fine
	run "$CTL" settings profile save p7 WATCH_INTERVAL_SEC=31
	[ "$status" -eq 0 ]
	run "$CTL" settings profile save keys $(for i in $(seq 1 101); do echo WATCH_INTERVAL_SEC=30; done)
	[ "$status" -eq 5 ]
}

@test "profile delete: removes one, refuses an unknown name" {
	"$CTL" settings profile save a WATCH_INTERVAL_SEC=30
	"$CTL" settings profile save b WATCH_INTERVAL_SEC=40
	run "$CTL" settings profile delete a --by admin
	[ "$status" -eq 0 ]
	[ "$("$CTL" settings profile list --json | jq -r '[.profiles[].name] | join(",")')" = b ]
	run "$CTL" settings profile delete a
	[ "$status" -eq 5 ]
	run "$CTL" settings profile show a
	[ "$status" -eq 5 ]
}

@test "profile apply: goes through settings set, so a light change applies and a heavy one needs its flag" {
	"$CTL" settings profile save light WATCH_INTERVAL_SEC=45
	"$CTL" settings profile save heavy SURICATA_SOURCE=distro
	run "$CTL" settings profile apply light
	[ "$status" -eq 0 ]
	grep -qx 'WATCH_INTERVAL_SEC=45' "$CONF_FILE"
	run "$CTL" settings profile apply heavy --apply
	[ "$status" -eq 3 ]
	[[ "$output" == *"--apply-heavy"* ]]
	run "$CTL" settings profile apply nothere
	[ "$status" -eq 5 ]
	run "$CTL" settings profile apply light --bogus
	[ "$status" -eq 2 ]
}

@test "profile apply: a wider access still needs its confirmation" {
	"$CTL" settings profile save open ACCESS_MODE=lan
	run "$CTL" settings profile apply open --apply
	[ "$status" -ne 0 ]
	grep -qx 'ACCESS_MODE=localhost' "$CONF_FILE"
}

@test "profiles: saving and deleting are audited, listing and showing are not" {
	rm -f "$AUDIT"
	"$CTL" settings profile list >/dev/null
	"$CTL" settings profile show nothere >/dev/null 2>&1 || true
	[ ! -s "$AUDIT" ]
	"$CTL" settings profile save a WATCH_INTERVAL_SEC=30 --by admin
	"$CTL" settings profile delete a --by admin
	[ "$(wc -l <"$AUDIT")" = 2 ]
	[ "$(jq -r .action "$AUDIT" | sort -u)" = "cli settings" ]
	[ "$(jq -r .target "$AUDIT" | sort -u)" = profile ]
}

@test "profiles: two saves at once both land, and a damaged file counts as empty" {
	"$CTL" settings profile save a WATCH_INTERVAL_SEC=30 &
	"$CTL" settings profile save b WATCH_INTERVAL_SEC=40 &
	wait
	[ "$(jq -r '.profiles | keys | join(",")' "$PROFILES")" = "a,b" ]
	echo 'not json' >"$PROFILES"
	run "$CTL" settings profile list --json
	[ "$status" -eq 0 ]
	[ "$(jq '.profiles | length' <<<"$output")" = 0 ]
	run "$CTL" settings profile save c WATCH_INTERVAL_SEC=30
	[ "$status" -eq 0 ]
	jq -e '.profiles.c' "$PROFILES"
}
