#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$root/build_release"
binary="$build_dir/simsimd_bench"
timestamp="$(date +%Y%m%d-%H%M%S)"
default_run_dir="$root/benchmark-results/dot-i8-subtraction-$timestamp"

dense_dimensions="64"
working_set_mib="5120"
thread_counts=""
plateau_threads=""
benchmark_min_time="0.5s"
plateau_min_time="1s"
run_mlc="1"
mlc_bin="$root/intel-mlc/mlc"
skip_build="0"
run_dir=""
threads_overridden="0"
plateau_threads_overridden="0"

usage() {
    cat <<EOF
Usage: $(basename "$0") [run-dir] [options]

Builds and runs the 64-byte i8 fixed-query subtraction benchmark:
  dot_i8_ice_fixed_query_i8_dot_i8_by_subtraction<64d>

By default it will:
1. Run the main thread sweep.
2. Re-run the plateau points with a longer min-time.
3. Run Intel MLC max-bandwidth if available.
4. Write JSON, console logs, CSV, and Markdown summaries into the run dir.

Options:
  --dense-dimensions N        Dense dimensions. Default: $dense_dimensions
  --working-set-mib N         Target total working set in MiB. Default: $working_set_mib
  --threads CSV               Main thread sweep. Default: sparse host-aware sweep up to online CPU count
  --plateau-threads CSV       Confirmatory thread sweep. Default: last 4 points from main sweep
  --benchmark-min-time TIME   Main sweep min-time. Default: $benchmark_min_time
  --plateau-min-time TIME     Plateau sweep min-time. Default: $plateau_min_time
  --mlc-bin PATH              Path to Intel MLC binary. Default: $mlc_bin
  --skip-mlc                  Skip the Intel MLC run
  --skip-build                Reuse the existing benchmark binary
  -h, --help                  Show this help

Arguments:
  run-dir                     Output directory. Default:
                              benchmark-results/dot-i8-subtraction-YYYYMMDD-HHMMSS

Examples:
  ./scripts/run_dot_i8_subtraction_thread_sweep.sh
  ./scripts/run_dot_i8_subtraction_thread_sweep.sh benchmark-results/my-run
  ./scripts/run_dot_i8_subtraction_thread_sweep.sh --working-set-mib 64 --benchmark-min-time 0.05s --skip-mlc
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --dense-dimensions)
            dense_dimensions="$2"
            shift 2
            ;;
        --working-set-mib)
            working_set_mib="$2"
            shift 2
            ;;
        --threads)
            thread_counts="$2"
            threads_overridden="1"
            shift 2
            ;;
        --plateau-threads)
            plateau_threads="$2"
            plateau_threads_overridden="1"
            shift 2
            ;;
        --benchmark-min-time)
            benchmark_min_time="$2"
            shift 2
            ;;
        --plateau-min-time)
            plateau_min_time="$2"
            shift 2
            ;;
        --mlc-bin)
            mlc_bin="$2"
            shift 2
            ;;
        --skip-mlc)
            run_mlc="0"
            shift
            ;;
        --skip-build)
            skip_build="1"
            shift
            ;;
        --*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [ -n "$run_dir" ]; then
                echo "Only one run directory may be provided." >&2
                exit 1
            fi
            run_dir="$1"
            shift
            ;;
    esac
done

run_dir="${run_dir:-$default_run_dir}"

default_thread_sweep() {
    local max_threads="$1"
    local preferred="1,2,3,4,6,8,12,16,24,32,48,64,96,128,192,256"
    local result=()
    local thread
    for thread in ${preferred//,/ }; do
        if [ "$thread" -le "$max_threads" ]; then
            result+=("$thread")
        fi
    done
    if [ "${#result[@]}" -eq 0 ] || [ "${result[$(( ${#result[@]} - 1 ))]}" -ne "$max_threads" ]; then
        result+=("$max_threads")
    fi
    local IFS=,
    echo "${result[*]}"
}

default_plateau_threads() {
    local csv="$1"
    local values=(${csv//,/ })
    local count="${#values[@]}"
    local start=0
    if [ "$count" -gt 4 ]; then
        start=$((count - 4))
    fi
    local result=("${values[@]:$start}")
    local IFS=,
    echo "${result[*]}"
}

max_threads="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
if [ -z "$thread_counts" ]; then
    thread_counts="$(default_thread_sweep "$max_threads")"
fi
if [ -z "$plateau_threads" ]; then
    plateau_threads="$(default_plateau_threads "$thread_counts")"
fi
if [ "$threads_overridden" = "1" ] && [ "$plateau_threads_overridden" != "1" ]; then
    plateau_threads="$thread_counts"
fi

if [ -e "$run_dir" ]; then
    echo "Refusing to overwrite existing path: $run_dir" >&2
    exit 1
fi

mkdir -p "$run_dir"

config_file="$run_dir/config.txt"
thread_sweep_json="$run_dir/thread-sweep.json"
thread_sweep_txt="$run_dir/thread-sweep.txt"
plateau_json="$run_dir/plateau-check.json"
plateau_txt="$run_dir/plateau-check.txt"
mlc_txt="$run_dir/mlc-max-bandwidth.txt"
summary_csv="$run_dir/summary.csv"
summary_md="$run_dir/summary.md"
summary_txt="$run_dir/summary.txt"

{
    echo "# $(date -Is)"
    echo "run_dir=$run_dir"
    echo "dense_dimensions=$dense_dimensions"
    echo "working_set_mib=$working_set_mib"
    echo "thread_counts=$thread_counts"
    echo "plateau_threads=$plateau_threads"
    echo "benchmark_min_time=$benchmark_min_time"
    echo "plateau_min_time=$plateau_min_time"
    echo "run_mlc=$run_mlc"
    echo "mlc_bin=$mlc_bin"
} > "$config_file"

if [ "$skip_build" != "1" ]; then
    cmake -DCMAKE_BUILD_TYPE=Release -DSIMSIMD_BUILD_BENCHMARKS=1 -B "$build_dir"
    cmake --build "$build_dir" --config Release -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
fi

if [ ! -x "$binary" ]; then
    echo "Benchmark binary not found: $binary" >&2
    exit 1
fi

thread_filter() {
    local csv="$1"
    printf 'dot_i8_ice_fixed_query_i8_dot_i8_by_subtraction<%sd>/.*/threads:(%s)$' \
        "$dense_dimensions" "${csv//,/|}"
}

run_benchmark() {
    local filter="$1"
    local min_time="$2"
    local json_out="$3"
    local txt_out="$4"
    local threads_csv="$5"

    env \
        SIMSIMD_BENCH_DENSE_DIMENSIONS="$dense_dimensions" \
        SIMSIMD_BENCH_STREAM_WORKING_SET_MIB="$working_set_mib" \
        SIMSIMD_BENCH_THREADS="$threads_csv" \
        "$binary" \
        --benchmark_filter="$filter" \
        --benchmark_min_time="$min_time" \
        --benchmark_counters_tabular=true \
        --benchmark_out="$json_out" \
        --benchmark_out_format=json | tee "$txt_out"
}

run_benchmark "$(thread_filter "$thread_counts")" "$benchmark_min_time" "$thread_sweep_json" "$thread_sweep_txt" "$thread_counts"

if [ -n "$plateau_threads" ]; then
    run_benchmark "$(thread_filter "$plateau_threads")" "$plateau_min_time" "$plateau_json" "$plateau_txt" "$plateau_threads"
fi

if [ "$run_mlc" = "1" ]; then
    if [ -x "$mlc_bin" ]; then
        "$mlc_bin" --max_bandwidth -X -Z | tee "$mlc_txt"
    else
        echo "Skipping Intel MLC; binary not executable: $mlc_bin" | tee "$mlc_txt"
    fi
else
    echo "Skipping Intel MLC by request." > "$mlc_txt"
fi

python3 - "$thread_sweep_json" "$plateau_json" "$mlc_txt" "$summary_csv" "$summary_md" "$summary_txt" <<'PY'
import json
import math
import pathlib
import re
import sys

thread_sweep_path = pathlib.Path(sys.argv[1])
plateau_path = pathlib.Path(sys.argv[2])
mlc_path = pathlib.Path(sys.argv[3])
summary_csv_path = pathlib.Path(sys.argv[4])
summary_md_path = pathlib.Path(sys.argv[5])
summary_txt_path = pathlib.Path(sys.argv[6])


def load_rows(path: pathlib.Path, source: str):
    if not path.exists():
        return {}
    with path.open() as fh:
        data = json.load(fh)
    rows = {}
    for benchmark in data["benchmarks"]:
        rows[benchmark["threads"]] = {
            "threads": benchmark["threads"],
            "bytes_gbs": benchmark["bytes"] / 1e9,
            "pairs_mpairs": benchmark["pairs"] / 1e6,
            "real_time_ns": benchmark["real_time"],
            "working_set_per_thread_gib": benchmark["working_set_per_thread"] / (1024 ** 3),
            "working_set_total_gib": benchmark["working_set_total"] / (1024 ** 3),
            "source": source,
        }
    return rows


rows = load_rows(thread_sweep_path, "thread-sweep")
rows.update(load_rows(plateau_path, "plateau-check"))
ordered = [rows[key] for key in sorted(rows)]

mlc_read_gbs = None
if mlc_path.exists():
    text = mlc_path.read_text()
    match = re.search(r"ALL Reads\s*:\s*([0-9]+(?:\.[0-9]+)?)", text)
    if match:
        mlc_read_gbs = float(match.group(1)) / 1000.0
    else:
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        for idx, line in enumerate(lines):
            if line.startswith("ALL Reads") and idx + 1 < len(lines):
                try:
                    mlc_read_gbs = float(lines[idx + 1]) / 1000.0
                    break
                except ValueError:
                    pass

base_gbs = ordered[0]["bytes_gbs"] if ordered else None
peak_row = max(ordered, key=lambda row: row["bytes_gbs"]) if ordered else None

with summary_csv_path.open("w") as fh:
    fh.write("threads,bytes_gbs,pairs_mpairs_s,real_time_ns,working_set_per_thread_gib,working_set_total_gib,source\n")
    for row in ordered:
        fh.write(
            f'{row["threads"]},{row["bytes_gbs"]:.6f},{row["pairs_mpairs"]:.6f},{row["real_time_ns"]:.6f},'
            f'{row["working_set_per_thread_gib"]:.6f},{row["working_set_total_gib"]:.6f},{row["source"]}\n'
        )

with summary_md_path.open("w") as fh:
    fh.write("| Threads | Bytes (GB/s) | Pairs (Mpairs/s) | Real Time (ns) | Per-thread WS (GiB) | Total WS (GiB) | Source |\n")
    fh.write("|---:|---:|---:|---:|---:|---:|---|\n")
    for row in ordered:
        fh.write(
            f'| {row["threads"]} | {row["bytes_gbs"]:.3f} | {row["pairs_mpairs"]:.2f} | {row["real_time_ns"]:.2f} | '
            f'{row["working_set_per_thread_gib"]:.3f} | {row["working_set_total_gib"]:.3f} | {row["source"]} |\n'
        )

with summary_txt_path.open("w") as fh:
    if peak_row is not None:
        fh.write(
            f'Peak bandwidth: {peak_row["bytes_gbs"]:.3f} GB/s at {peak_row["threads"]} threads '
            f'({peak_row["pairs_mpairs"]:.2f} Mpairs/s)\n'
        )
    if base_gbs is not None:
        for key in (1, 2, 3):
            row = rows.get(key)
            if row is None:
                continue
            speedup = row["bytes_gbs"] / base_gbs
            efficiency = speedup / key
            fh.write(
                f'{key} threads: {row["bytes_gbs"]:.3f} GB/s, {row["pairs_mpairs"]:.2f} Mpairs/s, '
                f'speedup={speedup:.3f}x, linear-efficiency={efficiency:.3f}\n'
            )
    if mlc_read_gbs is not None:
        fh.write(f'Intel MLC all-read max bandwidth: {mlc_read_gbs:.3f} GB/s\n')
        if peak_row is not None:
            fh.write(
                f'Benchmark / MLC ratio at peak: {peak_row["bytes_gbs"] / mlc_read_gbs:.3f}x\n'
            )
PY

echo "Run directory: $run_dir"
echo "Config: $config_file"
echo "Thread sweep JSON: $thread_sweep_json"
echo "Plateau JSON: $plateau_json"
echo "MLC output: $mlc_txt"
echo "Summary CSV: $summary_csv"
echo "Summary Markdown: $summary_md"
echo "Summary Text: $summary_txt"
