#!/usr/bin/env bash
# Security checks for the shell code (tech.md section 12). Cheap, local,
# no network: the same script runs in the gate and in CI. gitleaks adds a
# deeper secret scan in CI when it is installed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

status=0
CODE=(install.sh lib bin scripts)

# The secret and CRLF scans read the tracked files. When git cannot list
# them (a repo owned by another user makes it refuse as root), an empty
# list would make both scans pass without looking at anything.
if ! tracked_count=$(git ls-files -z | tr -cd '\0' | wc -c) || ((tracked_count == 0)); then
	echo "FAIL: git ls-files returned no files; the secret and CRLF scans cannot run"
	echo "  (as root in a repo owned by someone else: git config --global --add safe.directory \"\$PWD\")"
	exit 1
fi

# fail <title> <matches...> - prints the matches and marks the run failed.
fail() {
	echo "FAIL: $1"
	shift
	printf '  %s\n' "$@"
	status=1
}

# check <title> <grep-args...> - fails when grep finds anything in CODE.
check() {
	local title="$1" found
	shift
	# Lines that only print a systemd ExecStart= are unit text, not code.
	found=$(grep -rnIE "$@" "${CODE[@]}" 2>/dev/null | grep -v '^scripts/security.sh:' | grep -v 'ExecStart=' || true)
	if [[ -n "$found" ]]; then
		fail "$title" "$found"
	else
		echo "ok:   $title"
	fi
}

echo "== security =="

# 1. Secrets in tracked files (tests included: they must use fake values).
secret_re='github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|xox[baprs]-[A-Za-z0-9-]{10,}|[0-9]{8,10}:AA[A-Za-z0-9_-]{33}'
found=$(git ls-files -z 2>/dev/null | xargs -0 grep -nIE "$secret_re" 2>/dev/null |
	grep -v '^scripts/security.sh:' || true)
if [[ -n "$found" ]]; then
	fail "secrets in tracked files" "$found"
else
	echo "ok:   no secrets in tracked files"
fi
if command -v gitleaks >/dev/null 2>&1; then
	if gitleaks detect --no-banner --redact >/dev/null 2>&1; then
		echo "ok:   gitleaks"
	else
		fail "gitleaks found something (run: gitleaks detect --redact)"
	fi
fi

# 2. Code that runs strings as code.
check "no eval" '(^|[^[:alnum:]_-])eval[[:space:]]'
check "no bash -c / sh -c on built strings in code" '(bash|sh)[[:space:]]+-c[[:space:]]+"?\$'

# 3. Downloads that run unverified.
check "no curl|wget piped into a shell" '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh'

# 4. File permissions and temp files.
check "no world-writable chmod" 'chmod[[:space:]]+(-R[[:space:]]+)?(0?[0-7]?[0-7][2367]|0?[0-7][0-7][2367]|[ugoa]*\+w)([[:space:]]|$)'
check "no fixed /tmp paths" '(^|[^A-Za-z0-9_$./{}-])/tmp/[A-Za-z]'
check "no mktemp -u (name race)" 'mktemp[^|;]*[[:space:]]-u'
check "no \$\$-named temp files" '/tmp/[^[:space:]]*\$\$|\.\$\$'

# 5. Every executable entry point is strict about unset variables.
for f in install.sh bin/dpistack-ctl bin/dpistack-watch scripts/gate.sh scripts/security.sh; do
	if ! grep -qE '^set -[a-z]*u' "$f"; then
		fail "set -u missing in $f"
	fi
done
echo "ok:   strict mode present in entry points"

# 6. Windows line endings break shebangs and sudoers.
crlf=$(git ls-files -z 2>/dev/null | xargs -0 grep -lI $'\r' 2>/dev/null || true)
if [[ -n "$crlf" ]]; then
	fail "CRLF line endings" "$crlf"
else
	echo "ok:   no CRLF line endings"
fi

# 7. Secrets must not be passed on a command line: curl takes them via
# `-K -`. A literal token or password variable in an argument is a leak
# into `ps`.
check "no secret variable in a curl argument" 'curl[^|]*(TOKEN|PASSWORD|SMTP_URL)'

exit "$status"
