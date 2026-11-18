#!/usr/bin/env bash
# bats-shard.sh <I> <N> - prints the bats files of shard I of N (1-based), one
# per line, for the CI jobs that run the suite in parallel.
# The files are dealt out largest first, each to the shard with the smallest
# total so far (size in bytes stands in for run time), so the shards come out
# close in length and a new file lands in a shard without any list to edit.
set -euo pipefail

i="${1:?usage: bats-shard.sh <shard> <shards>}"
n="${2:?usage: bats-shard.sh <shard> <shards>}"
if [[ ! "$i" =~ ^[0-9]+$ || ! "$n" =~ ^[0-9]+$ ]] || ((i < 1 || i > n)); then
	echo "bats-shard: shard must be 1..N, got $i/$n" >&2
	exit 2
fi

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tests" && pwd)"
declare -a total
for ((k = 1; k <= n; k++)); do total[k]=0; done

# size, name; ties by name so the split is the same on every machine
while read -r size name; do
	best=1
	for ((k = 2; k <= n; k++)); do
		((total[k] < total[best])) && best=$k
	done
	total[best]=$((total[best] + size))
	((best == i)) && echo "$dir/$name"
done < <(cd "$dir" && for f in *.bats; do printf '%s %s\n' "$(wc -c <"$f")" "$f"; done | sort -k1,1nr -k2,2)
exit 0
