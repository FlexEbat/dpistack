#!/usr/bin/env bash
# The dpistack.conf key table (tech.md 4.3), plus the menu group (5.0)
# and reconfigure step/weight metadata (5.3) that lib/schema.sh is also
# the single source for. Every dpistack.conf key must appear here; no
# step reads or invents a key outside this table.
#
# Row format (pipe separated, 9 fields):
#   KEY|TYPE|DEFAULT|OPTIONS|LEVEL|GROUP|STEPS|WEIGHT|SECRET
#
#   TYPE    enum | int | free
#   OPTIONS enum: comma list of allowed values
#           int:  MIN..MAX
#           free: unused, left empty
#   LEVEL   basic | advanced (5.0)
#   GROUP   capture|components|eve|rules|access|metrics|watch|tests (5.0)
#   STEPS   space separated step ids this key's change touches (5.3)
#   WEIGHT  light | heavy (5.3, "лёгкое"/"тяжёлое")
#   SECRET  yes | no (yes = lives in secrets.conf, never in dpistack.conf)

# shellcheck disable=SC2034 # SCHEMA_DEFAULT/GROUP/STEPS/WEIGHT are read by lib/config.sh
declare -A SCHEMA_TYPE SCHEMA_DEFAULT SCHEMA_OPTIONS SCHEMA_LEVEL \
	SCHEMA_GROUP SCHEMA_STEPS SCHEMA_WEIGHT SCHEMA_SECRET
SCHEMA_KEYS=()

# Key/value combinations whose implementation does not exist yet
# (tech.md 4.3: "docker", "ips", METRICS_BACKEND other than "none").
# Present as valid enum members so the schema does not reject them
# outright, but installer rejects them with "пока не поддерживается".
declare -A SCHEMA_NOT_YET_SUPPORTED
SCHEMA_NOT_YET_SUPPORTED["SURICATA_RUNTIME=docker"]=1
SCHEMA_NOT_YET_SUPPORTED["EVEBOX_RUNTIME=docker"]=1
SCHEMA_NOT_YET_SUPPORTED["NTOPNG_RUNTIME=docker"]=1
SCHEMA_NOT_YET_SUPPORTED["METRICS_BACKEND_RUNTIME=docker"]=1
SCHEMA_NOT_YET_SUPPORTED["SURICATA_MODE=ips"]=1
SCHEMA_NOT_YET_SUPPORTED["METRICS_BACKEND=victoriametrics"]=1
SCHEMA_NOT_YET_SUPPORTED["METRICS_BACKEND=prometheus"]=1

_schema_add() {
	# _schema_add <row as documented above>
	local IFS='|'
	# shellcheck disable=SC2206
	local fields=($1)
	local key="${fields[0]}"
	SCHEMA_KEYS+=("$key")
	SCHEMA_TYPE["$key"]="${fields[1]}"
	SCHEMA_DEFAULT["$key"]="${fields[2]}"
	SCHEMA_OPTIONS["$key"]="${fields[3]}"
	SCHEMA_LEVEL["$key"]="${fields[4]}"
	SCHEMA_GROUP["$key"]="${fields[5]}"
	SCHEMA_STEPS["$key"]="${fields[6]}"
	SCHEMA_WEIGHT["$key"]="${fields[7]}"
	SCHEMA_SECRET["$key"]="${fields[8]}"
}

schema_init() {
	SCHEMA_KEYS=()
	_schema_add 'SURICATA_RUNTIME|enum|native|native,docker|basic|components|suricata|heavy|no'
	_schema_add 'EVEBOX_RUNTIME|enum|native|native,docker|basic|components|evebox|heavy|no'
	_schema_add 'NTOPNG_RUNTIME|enum|native|native,docker|basic|components|ntopng|heavy|no'
	_schema_add 'SURICATA_SOURCE|enum|source|distro,oisf,source|basic|components|suricata|heavy|no'
	_schema_add 'SURICATA_VERSION|free|||advanced|components|suricata|heavy|no'
	_schema_add 'NDPI_ENABLE|enum|yes|yes,no|basic|components|suricata|heavy|no'
	_schema_add 'NDPI_SOURCE|enum|source|pkg,source|advanced|components|suricata|heavy|no'
	_schema_add 'NDPI_VERSION|free|||advanced|components|suricata|heavy|no'
	_schema_add 'NTOPNG_VERSION|free|||advanced|components|ntopng|heavy|no'
	_schema_add 'EVEBOX_VERSION|free|||advanced|components|evebox|heavy|no'
	_schema_add 'PIN_VERSIONS|enum|no|yes,no|basic|components|suricata evebox ntopng|heavy|no'

	_schema_add 'SURICATA_MODE|enum|ids|ids,ips|advanced|capture|suricata|light|no'
	_schema_add 'IFACES|free|enp2s0||basic|capture|suricata ntopng|light|no'
	_schema_add 'BPF_FILTER|free|||advanced|capture|suricata|light|no'
	_schema_add 'HOME_NET|free|auto||advanced|capture|suricata|light|no'
	_schema_add 'IPS_METHOD|enum|nfq|nfq,afpacket|advanced|capture|suricata|light|no'
	_schema_add 'IPS_NFQ_CHAINS|free|INPUT,OUTPUT,FORWARD||advanced|capture|suricata|light|no'
	_schema_add 'NTOPNG_IFACES|free|||advanced|capture|ntopng access|light|no'

	_schema_add 'EVE_FILE|enum|yes|yes,no|advanced|eve|suricata watch|light|no'
	_schema_add 'EVE_TYPES|free|alert,flow,dns,tls,http,stats||basic|eve|suricata watch|light|no'
	_schema_add 'EVE_SYSLOG|enum|no|yes,no|advanced|eve|suricata|light|no'
	_schema_add 'EVE_REDIS|free|||advanced|eve|suricata|light|no'
	_schema_add 'EVE_ROTATE|enum|daily|daily,weekly,size|advanced|eve|suricata|light|no'
	_schema_add 'EVE_KEEP|int|14|0..3650|advanced|eve|suricata|light|no'
	_schema_add 'EVE_MAX_SIZE_MB|int||1..1000000|advanced|eve|suricata|light|no'
	_schema_add 'STATS_INTERVAL_SEC|int|30|5..300|advanced|eve|suricata watch|light|no'

	_schema_add 'RULES_SOURCES|free|et/open||advanced|rules|rules|light|no'
	_schema_add 'RULES_URLS|free|||advanced|rules|rules|light|no'
	_schema_add 'RULES_GROUPS|free|emerging-p2p,emerging-policy||advanced|rules|rules|light|no'
	_schema_add 'RULES_UPDATE|enum|on|on,off|advanced|rules|rules|light|no'
	_schema_add 'RULES_UPDATE_CALENDAR|free|weekly||advanced|rules|rules|light|no'

	_schema_add 'EVEBOX_DB|enum|sqlite|sqlite,elasticsearch|advanced|eve|evebox|heavy|no'
	_schema_add 'EVEBOX_ES_URL|free|||advanced|eve|evebox access|light|no'
	_schema_add 'EVEBOX_PORT|int|5636|1..65535|advanced|eve|evebox access|light|no'
	_schema_add 'EVEBOX_RETENTION_DAYS|int|30|0..36500|advanced|eve|evebox access|light|no'

	_schema_add 'ACCESS_MODE|enum|localhost|localhost,lan,nginx|basic|access|access panel|light|no'
	_schema_add 'LAN_CIDR|free|auto||advanced|access|access panel|light|no'
	_schema_add 'PANEL_PORT|int|9800|1..65535|advanced|access|access panel|light|no'
	_schema_add 'NTOPNG_PORT|int|3000|1..65535|advanced|access|ntopng access|light|no'
	_schema_add 'PANEL_SOURCE|enum|build|build,prebuilt|advanced|components|panel|heavy|no'
	_schema_add 'NGINX_MANAGE|enum|snippet|yes,snippet|advanced|access|access panel|light|no'
	_schema_add 'NGINX_TLS|enum|none|none,selfsigned,existing|advanced|access|access panel|light|no'
	_schema_add 'NGINX_CERT|free|||advanced|access|access panel|light|no'
	_schema_add 'NGINX_KEY|free|||advanced|access|access panel|light|no'
	_schema_add 'FIREWALL_MANAGE|enum|no|no,auto|advanced|access|access panel|light|no'

	_schema_add 'METRICS_EXPORT|enum|yes|yes,no|advanced|metrics|metrics panel|light|no'
	_schema_add 'METRICS_BACKEND|enum|none|none,victoriametrics,prometheus|basic|metrics|metrics|heavy|no'
	_schema_add 'METRICS_BACKEND_RUNTIME|enum|native|native,docker|advanced|metrics|metrics|heavy|no'
	_schema_add 'METRICS_BACKEND_PORT|int||1..65535|advanced|metrics|metrics panel|light|no'
	_schema_add 'METRICS_RETENTION|free|30d||advanced|metrics|metrics panel|light|no'

	_schema_add 'WATCH_ENABLE|enum|yes|yes,no|advanced|watch|watch|light|no'
	_schema_add 'WATCH_INTERVAL_SEC|int|60|10..3600|advanced|watch|watch|light|no'
	_schema_add 'WATCH_EVE_STALE_SEC|int|300|10..86400|advanced|watch|watch|light|no'
	_schema_add 'WATCH_DROP_WARN_PCT|int|1|0..100|advanced|watch|watch|light|no'
	_schema_add 'WATCH_DROP_CRIT_PCT|int|5|0..100|advanced|watch|watch|light|no'
	_schema_add 'WATCH_DISK_WARN_PCT|int|15|0..100|advanced|watch|watch|light|no'
	_schema_add 'WATCH_DISK_CRIT_PCT|int|5|0..100|advanced|watch|watch|light|no'
	_schema_add 'WATCH_RULES_WARN_DAYS|int|10|0..3650|advanced|watch|watch|light|no'
	_schema_add 'WATCH_RULES_CRIT_DAYS|int|30|0..3650|advanced|watch|watch|light|no'
	_schema_add 'WATCH_REPEAT_MIN|int|60|0..1440|advanced|watch|watch|light|no'
	_schema_add 'WATCH_AUTORESTART|enum|no|yes,no|advanced|watch|watch|light|no'
	_schema_add 'ALERT_CHANNELS|free|panel,log||basic|watch|watch|light|no'
	_schema_add 'ALERT_TG_CHAT_ID|free|||advanced|watch|watch|light|no'
	_schema_add 'ALERT_MAIL_TO|free|||advanced|watch|watch|light|no'
	_schema_add 'ALERT_MAIL_FROM|free|||advanced|watch|watch|light|no'

	_schema_add 'TEST_HTTPS_URL|free|https://example.com||advanced|tests|verify|light|no'
	_schema_add 'TEST_BT_LIVE|enum|no|yes,no|advanced|tests|verify|light|no'
	_schema_add 'TEST_ON_INSTALL|enum|yes|yes,no|advanced|tests|verify|light|no'

	# Secrets: live in secrets.conf, never dpistack.conf, never printed.
	_schema_add 'ALERT_TG_TOKEN|free|||advanced|watch|watch|light|yes'
	_schema_add 'ALERT_SMTP_URL|free|||advanced|watch|watch|light|yes'
	_schema_add 'METRICS_TOKEN|free|||advanced|metrics|metrics|heavy|yes'
}

schema_init

schema_known() { [[ -n "${SCHEMA_TYPE[$1]+x}" ]]; }

schema_is_basic() { [[ "${SCHEMA_LEVEL[$1]}" == "basic" ]]; }
schema_is_secret() { [[ "${SCHEMA_SECRET[$1]}" == "yes" ]]; }

schema_not_yet_supported() {
	# schema_not_yet_supported <key> <value>
	local combo="$1=$2"
	[[ -n "${SCHEMA_NOT_YET_SUPPORTED[$combo]+x}" ]]
}

schema_validate_one() {
	# schema_validate_one <key> <value>
	# Prints an error to stdout and returns 1 if invalid, silent 0 if ok.
	local key="$1" value="$2"

	if ! schema_known "$key"; then
		echo "неизвестный ключ: $key"
		return 1
	fi

	if schema_not_yet_supported "$key" "$value"; then
		echo "$key=$value: пока не поддерживается"
		return 1
	fi

	local type="${SCHEMA_TYPE[$key]}"

	if [[ -z "$value" && "$type" != "enum" ]]; then
		return 0
	fi

	case "$type" in
	enum)
		local opts="${SCHEMA_OPTIONS[$key]}"
		local ok=0
		local IFS=','
		for opt in $opts; do
			[[ "$value" == "$opt" ]] && ok=1
		done
		if [[ "$ok" -ne 1 ]]; then
			echo "$key=$value: недопустимое значение, допустимо: $opts"
			return 1
		fi
		;;
	int)
		if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
			echo "$key=$value: ожидалось целое число"
			return 1
		fi
		local range="${SCHEMA_OPTIONS[$key]}"
		if [[ -n "$range" ]]; then
			local min="${range%..*}" max="${range#*..}"
			if ((value < min || value > max)); then
				echo "$key=$value: вне диапазона $range"
				return 1
			fi
		fi
		;;
	free) ;;
	*)
		echo "$key: неизвестный тип схемы $type"
		return 1
		;;
	esac
	return 0
}
