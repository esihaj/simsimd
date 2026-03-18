#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") RUN_DIR

Scans group-*.txt files in RUN_DIR and writes results.csv.
If benchmark_repetitions=1, it extracts the benchmark rows.
Otherwise, it extracts only the _mean rows.
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

run_dir="${1:-}"

if [ -z "$run_dir" ]; then
    usage >&2
    exit 1
fi

if [ ! -d "$run_dir" ]; then
    echo "Run directory not found: $run_dir" >&2
    exit 1
fi

output="$run_dir/results.csv"
config_file="$run_dir/config.txt"
found=0
row_mode="mean"

if [ -f "$config_file" ]; then
    repetitions="$(awk -F= '$1 == "benchmark_repetitions" { print $2 }' "$config_file")"
    if [ "$repetitions" = "1" ]; then
        row_mode="all"
    fi
fi

{
    echo "group,name,bytes,pairs"
    for file in "$run_dir"/group-*.txt; do
        [ -e "$file" ] || continue
        found=1
        awk -v group="$(basename "$file")" -v row_mode="$row_mode" '
            row_mode == "mean" && /_mean/ && $1 !~ /^#/ {
                name = $1
                sub(/\/.*/, "", name)
                bytes = ""
                pairs = ""
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^bytes=/) bytes = substr($i, 7)
                    if ($i ~ /^pairs=/) pairs = substr($i, 7)
                }
                printf "%s,%s,%s,%s\n", group, name, bytes, pairs
            }
            row_mode == "all" && $1 ~ /\/min_time:/ && $1 !~ /_(mean|median|stddev|cv)$/ {
                name = $1
                sub(/\/.*/, "", name)
                bytes = ""
                pairs = ""
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^bytes=/) bytes = substr($i, 7)
                    if ($i ~ /^pairs=/) pairs = substr($i, 7)
                }
                printf "%s,%s,%s,%s\n", group, name, bytes, pairs
            }
        ' "$file"
    done
} > "$output"

if [ "$found" -eq 0 ]; then
    echo "No group files found in $run_dir" >&2
    exit 1
fi

if [ "$(wc -l < "$output")" -le 1 ]; then
    echo "No matching rows found in $run_dir for row_mode=$row_mode." >&2
fi

echo "Results written to $output"
