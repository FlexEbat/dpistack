# bash completion for dpistack (installed to /etc/bash_completion.d/dpistack).
# Static on purpose: completing never runs dpistack, so Tab costs nothing and
# works for a user who may not run it. A test keeps the word lists in step
# with the CLI (tests/cli_help.bats).
_dpistack() {
	local cur prev verb
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD - 1]}"
	verb="${COMP_WORDS[1]:-}"
	local verbs="install reconfigure upgrade uninstall diag status start stop restart reload logs config config-read config-write config-revert config-history settings self-update rules rules-update rules-sources rules-group rules-sid rules-search rules-stats rules-history rules-describe rules-find rules-facets rules-local exceptions alerts tokens security iface mode mode-confirm ips fw panel-passwd test health diagnose runtime users backup version help info"
	local components="suricata evebox ntopng redis victoriametrics prometheus node_exporter grafana panel watch rules"
	local configs="suricata.yaml evebox.yaml ntopng.conf dpistack.conf local.rules enable.conf disable.conf modify.conf drop.conf threshold.config"
	local words=""
	if ((COMP_CWORD == 1)); then
		words="$verbs"
	else
		case "$verb" in
		start | stop | restart | logs | diagnose) words="$components" ;;
		config) ((COMP_CWORD == 2)) && words="read write revert history" || words="$configs" ;;
		config-read | config-write | config-revert | config-history) words="$configs" ;;
		rules) ((COMP_CWORD == 2)) && words="update sources group sid search stats history describe find facets local" ;;
		mode) words="ids ips status confirm" ;;
		settings) ((COMP_CWORD == 2)) && words="list check set secret profile job" ;;
		backup) ((COMP_CWORD == 2)) && words="create list verify restore" ;;
		users) ((COMP_CWORD == 2)) && words="list add passwd role disable enable remove" ;;
		tokens) ((COMP_CWORD == 2)) && words="create list revoke" ;;
		alerts) ((COMP_CWORD == 2)) && words="list history ack resolve reopen snooze" ;;
		exceptions) ((COMP_CWORD == 2)) && words="list add remove prune" ;;
		iface) ((COMP_CWORD == 2)) && words="list add remove" ;;
		test) ((COMP_CWORD == 2)) && words="bittorrent https all" ;;
		help) ((COMP_CWORD == 2)) && words="$verbs settings ids --all" ;;
		esac
		[[ "$prev" == "--config" ]] && return 0
	fi
	mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}
complete -F _dpistack dpistack
