#!/usr/bin/env bats
# Slice 41 (18.41), Rules v2: rules-stats, rules-history, rules-describe,
# rules-local check and config-history. The cache naming and the merged-set
# format in the fixtures are the ones suricata-update 1.3.3 really writes.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	FAKE_BIN="$(mktemp -d)"
	cat >"$FAKE_BIN/suricata" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == "-T" ]] || exit 0
yaml="$3"
rules=$(sed -n 's/^default-rule-path: *//p' "$yaml")
if grep -q INVALID "$rules/suricata.rules" 2>/dev/null; then
	echo "ERROR: invalid rule in the rule set"
	exit 1
fi
exit 0
FAKE
	chmod +x "$FAKE_BIN/suricata"
	PATH="$FAKE_BIN:$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0,eth1"
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1

	DATA="$DPISTACK_ROOT/var/lib/suricata"
	MERGED="$DATA/rules/suricata.rules"
	LOCAL="$DPISTACK_ROOT/etc/suricata/rules/local.rules"
	mkdir -p "$DATA/update/cache" "$DATA/update/sources" "$DATA/rules" "$(dirname "$LOCAL")"
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN"
	rm -f "$MOCK_CALLS_LOG"
}

# source_fixture <name> <url template> <resolved url> <kind: tar|plain> <rules...>
source_fixture() {
	local name="$1" template="$2" url="$3" kind="$4" h tmp
	shift 4
	printf 'source: %s\n' "$name" >"$DATA/update/sources/$(tr / - <<<"$name").yaml"
	if ! grep -q "^  $name:" "$DATA/update/cache/index.yaml" 2>/dev/null; then
		[[ -f "$DATA/update/cache/index.yaml" ]] || printf 'version: 1\nsources:\n' >"$DATA/update/cache/index.yaml"
		printf '  %s:\n    summary: x\n    url: %s\n' "$name" "$template" >>"$DATA/update/cache/index.yaml"
	fi
	h=$(printf '%s' "$url" | md5sum | cut -d' ' -f1)
	tmp=$(mktemp -d)
	mkdir -p "$tmp/rules"
	printf '%s\n' "$@" >"$tmp/rules/x.rules"
	if [[ "$kind" == tar ]]; then
		tar -czf "$DATA/update/cache/$h-${url##*/}" -C "$tmp" rules/x.rules
	else
		cp "$tmp/rules/x.rules" "$DATA/update/cache/$h-${url##*/}"
	fi
	rm -rf "$tmp"
}

rule() { printf 'alert tcp any any -> any 80 (msg:"%s"; sid:%s; rev:1;)' "$2" "$1"; }
off() {
	printf '# '
	rule "$@"
}

jq_() { jq -r "$1"; }

@test "criterion 1: rules-stats counts the merged set, local.rules and each source by the state in the merged set" {
	source_fixture test/one 'http://example.invalid/open/suricata-%(__version__)s/one.rules.tar.gz' 'http://example.invalid/open/suricata-7.0.5/one.rules.tar.gz' tar \
		"$(rule 1000001 'ONE a')" "$(rule 1000002 'ONE b')" "$(off 1000003 'ONE c')"
	source_fixture test/two 'http://example.invalid/two.rules' 'http://example.invalid/two.rules' plain \
		"$(rule 2000001 'TWO a')" "$(rule 2000002 'TWO b')"
	{
		rule 2000001 'TWO a'
		echo
		off 2000002 'TWO b (disabled by disable.conf)'
		echo
		rule 1000001 'ONE a'
		echo
		rule 1000002 'ONE b'
		echo
		off 1000003 'ONE c'
		echo
	} >"$MERGED"
	{
		rule 9000001 mine
		echo
		off 9000002 'mine off'
		echo
	} >"$LOCAL"
	run "$CTL" rules-stats --json
	[ "$status" -eq 0 ]
	[ "$(jq_ '.ruleset | [.present, .total, .enabled, .disabled] | @csv' <<<"$output")" = "true,5,3,2" ]
	[ "$(jq_ '.local | [.total, .enabled, .disabled] | @csv' <<<"$output")" = "2,1,1" ]
	[ "$(jq_ '.sources[] | select(.name == "test/one") | [.cached, .total, .enabled, .disabled, .missing] | @csv' <<<"$output")" = "true,3,2,1,0" ]
	[ "$(jq_ '.sources[] | select(.name == "test/two") | [.cached, .total, .enabled, .disabled, .missing] | @csv' <<<"$output")" = "true,2,1,1,0" ]
	[[ "$(jq_ '.sources[0].fetched' <<<"$output")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
	[[ "$(jq_ '.ruleset.updated' <<<"$output")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "criterion 1: rules-stats as text prints one line per part" {
	source_fixture test/two 'http://example.invalid/two.rules' 'http://example.invalid/two.rules' plain "$(rule 2000001 'TWO a')"
	rule 2000001 'TWO a' >"$MERGED"
	echo >>"$MERGED"
	run "$CTL" rules-stats
	[ "$status" -eq 0 ]
	[[ "$output" == *$'ruleset\t1\t1\t0'* ]]
	[[ "$output" == *$'source\ttest/two\t1\t1\t0\t0\t'* ]]
}

@test "criterion 2: a source that was never downloaded says so, with no numbers" {
	printf 'source: test/never\n' >"$DATA/update/sources/test-never.yaml"
	printf 'version: 1\nsources:\n  test/never:\n    url: http://example.invalid/never.rules.tar.gz\n' >"$DATA/update/cache/index.yaml"
	rm -f "$MERGED"
	run "$CTL" rules-stats --json
	[ "$status" -eq 0 ]
	[ "$(jq_ '.sources[0] | [.name, .cached, .total, .fetched] | @csv' <<<"$output")" = '"test/never",false,,' ]
	[ "$(jq_ '.ruleset.present' <<<"$output")" = "false" ]
}

@test "criterion 2: a custom source is read from the url in its own file, and a rule the set lacks is counted as missing" {
	printf 'source: dpistack-custom-ab12cd34\nurl: http://example.invalid/custom.rules\n' >"$DATA/update/sources/dpistack-custom-ab12cd34.yaml"
	h=$(printf '%s' 'http://example.invalid/custom.rules' | md5sum | cut -d' ' -f1)
	printf '%s\n' "$(rule 3000001 c1)" "$(rule 3000002 c2)" "$(rule 3000002 'c2 again')" >"$DATA/update/cache/$h-custom.rules"
	rule 3000001 c1 >"$MERGED"
	echo >>"$MERGED"
	run "$CTL" rules-stats --json
	[ "$(jq_ '.sources[] | select(.name == "dpistack-custom-ab12cd34") | [.total, .enabled, .disabled, .missing] | @csv' <<<"$output")" = "2,1,0,1" ]
}

@test "criterion 2: the newest cache file of a source is the one counted, and a checksum file is ignored" {
	source_fixture test/two 'http://example.invalid/two.rules' 'http://example.invalid/two-old/two.rules' plain "$(rule 2000001 old)"
	source_fixture test/two 'http://example.invalid/two.rules' 'http://example.invalid/two.rules' plain "$(rule 2000001 a)" "$(rule 2000002 b)"
	h=$(printf '%s' 'http://example.invalid/two.rules' | md5sum | cut -d' ' -f1)
	touch -d '2 days ago' "$DATA/update/cache/$(printf '%s' 'http://example.invalid/two-old/two.rules' | md5sum | cut -d' ' -f1)-two.rules"
	printf 'abc\n' >"$DATA/update/cache/$h-two.rules.md5"
	: >"$MERGED"
	run "$CTL" rules-stats --json
	[ "$(jq_ '.sources[0].total' <<<"$output")" = "2" ]
}

@test "criterion 3: rules-describe says what each rule is and whether it is on, from both files" {
	{
		rule 1000001 'ONE a'
		echo
		off 1000002 'ONE b'
		echo
	} >"$MERGED"
	{
		rule 9000001 mine
		echo
	} >"$LOCAL"
	run "$CTL" rules-describe 1000001 1000002 9000001 424242
	[ "$status" -eq 0 ]
	[ "$(jq_ '.asked' <<<"$output")" = "4" ]
	[ "$(jq_ '[.rules[] | select(.sid == 1000001) | .msg, .enabled, .where] | @csv' <<<"$output")" = '"ONE a",true,"suricata.rules"' ]
	[ "$(jq_ '[.rules[] | select(.sid == 1000002) | .enabled] | @csv' <<<"$output")" = "false" ]
	[ "$(jq_ '[.rules[] | select(.sid == 9000001) | .where] | @csv' <<<"$output")" = '"local.rules"' ]
	[ "$(jq_ '[.rules[] | select(.sid == 424242)] | length' <<<"$output")" = "0" ]
}

@test "criterion 3: rules-describe keeps a quote or a backslash in a message valid JSON, and refuses bad arguments" {
	printf '%s\n' 'alert tcp any any -> any 1 (msg:"a \\ b"; sid:5; rev:1;)' >"$MERGED"
	run "$CTL" rules-describe 5
	[ "$status" -eq 0 ]
	jq -e '.rules[0].sid == 5' <<<"$output" >/dev/null
	run "$CTL" rules-describe abc
	[ "$status" -eq 5 ]
	run "$CTL" rules-describe
	[ "$status" -eq 2 ]
	run "$CTL" rules-describe $(seq 1 21)
	[ "$status" -eq 2 ]
}

@test "criterion 4: rules-local check passes a sound file, and says Suricata was tested" {
	run bash -c "printf '%s\n' '$(rule 9100001 ok)' | '$CTL' rules-local check"
	[ "$status" -eq 0 ]
	[ "$(jq_ '[.ok, .rules, (.problems | length), .suricata.run, .suricata.ok] | @csv' <<<"$output")" = "true,1,0,true,true" ]
}

@test "criterion 4: rules-local check finds a line that is no rule, a rule with no sid, a sid used twice and a sid the set uses" {
	rule 1000001 'ONE a' >"$MERGED"
	echo >>"$MERGED"
	run bash -c "printf '%s\n' '$(rule 1000001 clash)' '$(rule 9100002 b)' '$(rule 9100002 c)' 'nonsense line' 'alert tcp any any -> any 4 (msg:\"nosid\";)' | '$CTL' rules-local check"
	[ "$status" -eq 0 ]
	[ "$(jq_ '.ok' <<<"$output")" = "false" ]
	[ "$(jq_ '[.problems[] | "\(.line):\(.kind)"] | join(" ")' <<<"$output")" = "1:conflict 3:duplicate 4:not_a_rule 5:no_sid" ]
	[[ "$(jq_ '.problems[0].text' <<<"$output")" == *"already used by the rule set: ONE a"* ]]
	[[ "$(jq_ '.problems[1].text' <<<"$output")" == *"line 2"* ]]
}

@test "criterion 4: a sid outside the range for custom rules is a warning, not a problem; comments and blank lines are fine" {
	run bash -c "printf '%s\n' '# a note' '' '$(rule 55 low)' | '$CTL' rules-local check"
	[ "$(jq_ '[.ok, (.problems | length), (.warnings | length), .warnings[0].line] | @csv' <<<"$output")" = "true,0,1,3" ]
	[[ "$(jq_ '.warnings[0].text' <<<"$output")" == *"9000000-9999999"* ]]
}

@test "criterion 4: what suricata -T says is part of the answer, and a file it rejects is not ok" {
	run bash -c "printf '%s\n' 'INVALID line' | '$CTL' rules-local check"
	[ "$status" -eq 0 ]
	[ "$(jq_ '.ok' <<<"$output")" = "false" ]
	[ "$(jq_ '.suricata.ok' <<<"$output")" = "false" ]
	[[ "$(jq_ '.suricata.output' <<<"$output")" == *"invalid rule in the rule set"* ]]
}

@test "criterion 4: rules-local check writes nothing and refuses a file over 1 MiB and bad arguments" {
	before=$(cat "$LOCAL" 2>/dev/null || true)
	run bash -c "printf '%s\n' '$(rule 9100003 x)' | '$CTL' rules-local check"
	[ "$(cat "$LOCAL" 2>/dev/null || true)" = "$before" ]
	run bash -c "head -c 1100000 /dev/zero | tr '\0' 'a' | '$CTL' rules-local check"
	[ "$status" -eq 5 ]
	run "$CTL" rules-local check extra
	[ "$status" -eq 2 ]
	run "$CTL" rules-local
	[ "$status" -eq 2 ]
	run "$CTL" rules-local nonsense
	[ "$status" -eq 2 ]
}

@test "criterion 5: rules-update records the numbers suricata-update printed, newest first" {
	run "$CTL" rules-history --json
	[ "$(jq_ '.updates | length' <<<"$output")" = "0" ]
	MOCK_UPDATE_SUMMARY=1 run "$CTL" rules-update
	[ "$status" -eq 0 ]
	run "$CTL" rules-history --json
	[ "$(jq_ '.updates | length' <<<"$output")" = "1" ]
	[ "$(jq_ '.updates[0] | [.result, .loaded, .total, .enabled, .added, .removed, .modified, .parsed] | @csv' <<<"$output")" = '"ok",5,5,3,4,1,2,true' ]
	[[ "$(jq_ '.updates[0].time' <<<"$output")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
}

@test "criterion 5: a failed update is in the history as failed, with no invented numbers" {
	MOCK_SURICATA_UPDATE_FAIL=1 run "$CTL" rules-update
	[ "$status" -eq 1 ]
	MOCK_UPDATE_SUMMARY=1 "$CTL" rules-update >/dev/null 2>&1
	run "$CTL" rules-history --json
	[ "$(jq_ '[.updates[] | .result] | join(",")' <<<"$output")" = "ok,failed" ]
	[ "$(jq_ '.updates[1] | [.total, .parsed] | @csv' <<<"$output")" = "0,false" ]
}

@test "criterion 5: the history keeps the last 100 updates, and prints as text too" {
	mkdir -p "$DPISTACK_ROOT/var/lib/dpistack"
	for i in $(seq 1 130); do
		printf '{"time":"2026-01-01T00:00:00Z","result":"ok","loaded":%s,"total":0,"enabled":0,"added":0,"removed":0,"modified":0,"parsed":false}\n' "$i"
	done >"$DPISTACK_ROOT/var/lib/dpistack/rules-updates.jsonl"
	MOCK_UPDATE_SUMMARY=1 "$CTL" rules-update >/dev/null 2>&1
	[ "$(wc -l <"$DPISTACK_ROOT/var/lib/dpistack/rules-updates.jsonl")" -eq 100 ]
	run "$CTL" rules-history --json
	[ "$(jq_ '.updates | length' <<<"$output")" = "50" ]
	[ "$(jq_ '.updates[0].loaded' <<<"$output")" = "5" ]
	run "$CTL" rules-history
	[ "$status" -eq 0 ]
	[[ "$output" == *"result:ok"* ]]
	run "$CTL" rules-history --bogus
	[ "$status" -eq 2 ]
}

@test "criterion 6: config-history lists the saved versions of a file, newest first, and prints one" {
	printf '%s\n' "$(rule 9200001 first)" | "$CTL" config-write local.rules >/dev/null 2>&1
	sleep 1
	printf '%s\n' "$(rule 9200001 second)" | "$CTL" config-write local.rules >/dev/null 2>&1
	sleep 1
	printf '%s\n' "$(rule 9200001 third)" | "$CTL" config-write local.rules >/dev/null 2>&1
	run "$CTL" config-history local.rules
	[ "$status" -eq 0 ]
	[ "$(jq_ '.versions | length' <<<"$output")" -ge 2 ]
	[ "$(jq_ '.name' <<<"$output")" = "local.rules" ]
	[[ "$(jq_ '.versions[0].id' <<<"$output")" =~ ^[0-9]{8}T[0-9]{6}Z ]]
	[[ "$(jq_ '.versions[0].time' <<<"$output")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
	newest=$(jq_ '.versions[0].id' <<<"$output")
	oldest=$(jq_ '.versions[-1].id' <<<"$output")
	run "$CTL" config-history local.rules "$newest"
	[ "$status" -eq 0 ]
	[[ "$output" == *"second"* ]]
	run "$CTL" config-history local.rules "$oldest"
	[ "$status" -eq 0 ]
	[[ "$output" != *"second"* ]]
}

@test "criterion 6: config-history refuses an unknown file or a bad version id, and says no such version" {
	run "$CTL" config-history nonsense.txt
	[ "$status" -eq 5 ]
	run "$CTL" config-history local.rules '../../etc/passwd'
	[ "$status" -ne 0 ]
	run "$CTL" config-history local.rules 20990101T000000Z
	[ "$status" -eq 4 ]
	run "$CTL" config-history local.rules not-an-id
	[ "$status" -eq 5 ]
	run "$CTL" config-history
	[ "$status" -eq 2 ]
	run "$CTL" config-history drop.conf
	[ "$status" -eq 0 ]
	[ "$(jq_ '.versions | length' <<<"$output")" = "0" ]
}

@test "criterion 7: the usage text lists the new verbs and none of them is audited as a change" {
	run "$CTL" nonsense
	for v in rules-stats rules-history rules-describe rules-local config-history; do [[ "$output" == *"$v"* ]]; done
	"$CTL" rules-stats >/dev/null 2>&1
	"$CTL" rules-history >/dev/null 2>&1
	"$CTL" rules-describe 1 >/dev/null 2>&1
	"$CTL" config-history local.rules >/dev/null 2>&1
	audit="$DPISTACK_ROOT/var/lib/dpistack/audit/audit.jsonl"
	[ "$(jq -r 'select(.action | test("rules-stats|rules-history|rules-describe|rules-local|config-history")) | .action' "$audit" 2>/dev/null | wc -l)" -eq 0 ]
}

crule() { printf 'alert tcp any any -> any 80 (msg:"%s"; classtype:%s; sid:%s; rev:1;)' "$3" "$2" "$1"; }
coff() {
	printf '# '
	crule "$@"
}

find_fixture() {
	source_fixture test/one 'http://example.invalid/one.rules' 'http://example.invalid/one.rules' plain \
		"$(crule 1000001 trojan-activity 'ONE trojan')" "$(coff 1000002 trojan-activity 'ONE trojan off')" "$(crule 1000003 policy-violation 'ONE policy')"
	{
		crule 1000001 trojan-activity 'ONE trojan'
		echo
		coff 1000002 trojan-activity 'ONE trojan off'
		echo
		crule 1000003 policy-violation 'ONE policy'
		echo
		crule 2000001 Trojan-Activity 'TWO trojan \"quoted\" \\ back'
		echo
		crule 2000002 web-application-attack 'TWO web'
		echo
	} >"$MERGED"
}

@test "criterion 8: rules-find by category finds enabled and disabled rules, whatever the case of the name" {
	find_fixture
	run "$CTL" rules-find --class trojan-activity
	[ "$status" -eq 0 ]
	[ "$(jq_ '[.results[].sid] | sort | join(",")' <<<"$output")" = "1000001,1000002,2000001" ]
	[ "$(jq_ '[.results[] | select(.sid == 1000002) | .enabled] | @csv' <<<"$output")" = "false" ]
	[ "$(jq_ '.truncated' <<<"$output")" = "false" ]
	[ "$(jq -r '.results[] | select(.sid == 2000001) | .msg' <<<"$output")" = 'TWO trojan "quoted" \ back' ]
}

@test "criterion 8: rules-find by source finds only what that source holds; an unknown source says so" {
	find_fixture
	run "$CTL" rules-find --source test/one
	[ "$(jq_ '[.results[].sid] | sort | join(",")' <<<"$output")" = "1000001,1000002,1000003" ]
	[ "$(jq_ '.source_known' <<<"$output")" = "true" ]
	run "$CTL" rules-find --source test/none
	[ "$status" -eq 0 ]
	[ "$(jq_ '[(.results | length), .source_known] | @csv' <<<"$output")" = "0,false" ]
}

@test "criterion 8: rules-find combines state, category, source and text" {
	find_fixture
	run "$CTL" rules-find --state disabled
	[ "$(jq_ '[.results[].sid] | join(",")' <<<"$output")" = "1000002" ]
	run "$CTL" rules-find --state enabled --class trojan-activity --source test/one
	[ "$(jq_ '[.results[].sid] | join(",")' <<<"$output")" = "1000001" ]
	run "$CTL" rules-find --text 'trojan off'
	[ "$(jq_ '[.results[].sid] | join(",")' <<<"$output")" = "1000002" ]
	run "$CTL" rules-find --text 2000002
	[ "$(jq_ '[.results[].sid] | join(",")' <<<"$output")" = "2000002" ]
	run "$CTL" rules-find --text 200000
	[ "$(jq_ '.results | length' <<<"$output")" = "0" ]
}

@test "criterion 8: rules-find returns at most 50 rules and says it stopped" {
	for i in $(seq 1 60); do
		crule $((3000000 + i)) trojan-activity "many $i"
		echo
	done >"$MERGED"
	run "$CTL" rules-find --class trojan-activity
	[ "$(jq_ '[(.results | length), .truncated] | @csv' <<<"$output")" = "50,true" ]
}

@test "criterion 8: rules-find refuses no criterion, a value that is not allowed, and a missing rule set" {
	find_fixture
	run "$CTL" rules-find
	[ "$status" -eq 2 ]
	run "$CTL" rules-find --class
	[ "$status" -eq 2 ]
	run "$CTL" rules-find --bogus x
	[ "$status" -eq 2 ]
	run "$CTL" rules-find --class 'a;b'
	[ "$status" -eq 5 ]
	run "$CTL" rules-find --state maybe
	[ "$status" -eq 5 ]
	run "$CTL" rules-find --source '-x'
	[ "$status" -eq 5 ]
	run "$CTL" rules-find --text 'a|b'
	[ "$status" -eq 5 ]
	rm -f "$MERGED"
	run "$CTL" rules-find --class trojan-activity
	[ "$status" -eq 4 ]
}

@test "criterion 9: rules-facets lists the categories with their counts, largest first, and the enabled sources" {
	find_fixture
	run "$CTL" rules-facets
	[ "$status" -eq 0 ]
	[ "$(jq_ '.classes[0] | [.name, .count] | @csv' <<<"$output")" = '"trojan-activity",2' ]
	[ "$(jq_ '[.classes[] | .name] | sort | join(",")' <<<"$output")" = "Trojan-Activity,policy-violation,trojan-activity,web-application-attack" ]
	[ "$(jq_ '.sources | join(",")' <<<"$output")" = "test/one" ]
	run "$CTL" rules-facets extra
	[ "$status" -eq 2 ]
	rm -f "$MERGED"
	run "$CTL" rules-facets
	[ "$(jq_ '.classes | length' <<<"$output")" = "0" ]
}
