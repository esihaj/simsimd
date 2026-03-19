#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$root/build_release"
binary="$build_dir/simsimd_bench"
timestamp="$(date +%Y%m%d-%H%M%S)"
default_run_dir="$root/benchmark-results/dot-i8-fixed-query-triplet-$timestamp"

dense_dimensions="64"
working_set_kib="1"
benchmark_min_time="10s"
skip_build="0"
run_dir=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [run-dir] [options]

Builds and runs these 64d benchmarks in one Google Benchmark invocation:
  dot_i8_ice_fixed_query<64d>
  dot_i8_ice_fixed_query_i8_dot_i8_by_subtraction<64d>
  dot_i8_ice_fixed_query_i8_dot_i8_by_subtraction_batched16<64d>

Options:
  --dense-dimensions N        Dense dimensions. Default: $dense_dimensions
  --working-set-kib N         Target total working set in KiB. Default: $working_set_kib
  --benchmark-min-time TIME   Passed to Google Benchmark. Default: $benchmark_min_time
  --skip-build                Reuse the existing benchmark binary
  -h, --help                  Show this help

Arguments:
  run-dir                     Output directory. Default:
                              benchmark-results/dot-i8-fixed-query-triplet-YYYYMMDD-HHMMSS

Examples:
  ./scripts/run_dot_i8_fixed_query_triplet.sh
  ./scripts/run_dot_i8_fixed_query_triplet.sh benchmark-results/my-run
  ./scripts/run_dot_i8_fixed_query_triplet.sh --working-set-kib 64 --benchmark-min-time 1s
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
        --working-set-kib)
            working_set_kib="$2"
            shift 2
            ;;
        --benchmark-min-time)
            benchmark_min_time="$2"
            shift 2
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

if [ -e "$run_dir" ]; then
    echo "Refusing to overwrite existing path: $run_dir" >&2
    exit 1
fi

mkdir -p "$run_dir"

config_file="$run_dir/config.txt"
results_json="$run_dir/results.json"
results_txt="$run_dir/results.txt"

{
    echo "# $(date -Is)"
    echo "run_dir=$run_dir"
    echo "dense_dimensions=$dense_dimensions"
    echo "working_set_kib=$working_set_kib"
    echo "benchmark_min_time=$benchmark_min_time"
    echo "threads=1"
} > "$config_file"

if [ "$skip_build" != "1" ]; then
    cmake -DCMAKE_BUILD_TYPE=Release -DSIMSIMD_BUILD_BENCHMARKS=1 -B "$build_dir"
    cmake --build "$build_dir" --config Release -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
fi

if [ ! -x "$binary" ]; then
    echo "Benchmark binary not found: $binary" >&2
    exit 1
fi

benchmark_filter="^(dot_i8_ice_fixed_query<${dense_dimensions}d>|dot_i8_ice_fixed_query_i8_dot_i8_by_subtraction<${dense_dimensions}d>|dot_i8_ice_fixed_query_i8_dot_i8_by_subtraction_batched16<${dense_dimensions}d>)(/.*)?$"

env \
    SIMSIMD_BENCH_DENSE_DIMENSIONS="$dense_dimensions" \
    SIMSIMD_BENCH_STREAM_WORKING_SET_KIB="$working_set_kib" \
    SIMSIMD_BENCH_THREADS="1" \
    "$binary" \
    --benchmark_filter="$benchmark_filter" \
    --benchmark_min_time="$benchmark_min_time" \
    --benchmark_counters_tabular=true \
    --benchmark_out="$results_json" \
    --benchmark_out_format=json | tee "$results_txt"
