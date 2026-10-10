# Security policy

dpistack runs as root on a host that sees network traffic, so reports about
privilege escalation, command injection, or leaked secrets are taken
seriously.

Report privately through GitHub Security Advisories on this repository
("Report a vulnerability"), not in a public issue. A first answer within
7 days is the goal.

Where the sensitive parts are:

- `bin/dpistack-ctl` is the only thing the panel user may run through
  `sudo`. Every argument is checked against allow-lists before any action.
- Secrets live in `secrets.conf` (0600) and reach `curl` through `-K -` on
  stdin, never on a command line.
- `scripts/security.sh` and the `security` workflow check for the
  patterns that usually lead to the problems above.
