#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$root/build_release"
binary="$build_dir/simsimd_bench"
extract_script="$root/scripts/extract_dense_benchmark_means.sh"
timestamp="$(date +%Y%m%d-%H%M%S)"
default_run_dir="$root/benchmark-results/run-$timestamp"
benchmark_min_time="10s"
benchmark_repetitions="5"

usage() {
    cat <<EOF
Usage: $(basename "$0") [run-dir] [--benchmark-min-time TIME] [--benchmark-repetitions N]

Builds the benchmark binary, selects the latest available ISA variant for:
  i8, i16, f16, bf16, f32
  dot, l2sq, cos
  64 B vectors
  384 element vectors

Each run gets its own output directory. Each benchmark group is written to a
separate file in that directory, and results.txt is generated from the _mean rows.

Options:
  --benchmark-min-time TIME   Passed to Google Benchmark. Default: $benchmark_min_time
  --benchmark-repetitions N   Passed to Google Benchmark. Default: $benchmark_repetitions
  -h, --help                  Show this help

Arguments:
  run-dir                     Output directory for this run.
                              Default: benchmark-results/run-YYYYMMDD-HHMMSS

Examples:
  ./scripts/run_dense_benchmarks.sh
  ./scripts/run_dense_benchmarks.sh benchmark-results/my-run
  ./scripts/run_dense_benchmarks.sh --benchmark-min-time 1s --benchmark-repetitions 1
EOF
}

run_dir=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --benchmark-min-time)
            benchmark_min_time="$2"
            shift 2
            ;;
        --benchmark-repetitions)
            benchmark_repetitions="$2"
            shift 2
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

cmake -DCMAKE_BUILD_TYPE=Release -DSIMSIMD_BUILD_BENCHMARKS=1 -B "$build_dir"
cmake --build "$build_dir" --config Release -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"

dimension_for() {
    local dtype="$1"
    local size_kind="$2"
    local size_value="$3"

    case "$size_kind" in
        bytes)
            case "$dtype" in
                i8) echo "$size_value" ;;
                i16|f16|bf16) echo $((size_value / 2)) ;;
                f32) echo $((size_value / 4)) ;;
                *) return 1 ;;
            esac
            ;;
        elements)
            echo "$size_value"
            ;;
        *)
            return 1
            ;;
    esac
}

pick() {
    local bench_list="$1"
    local metric="$2"
    local dtype="$3"
    local dim="$4"
    local arch
    local name

    for arch in sapphire genoa ice skylake haswell serial; do
        name="$(printf '%s\n' "$bench_list" | grep -E "^${metric}_${dtype}_${arch}<${dim}d>" | head -n1 | cut -d/ -f1 || true)"
        if [ -n "$name" ]; then
            printf '%s\n' "$name"
            return 0
        fi
    done

    return 1
}

regex_escape() {
    printf '%s\n' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

filter_for() {
    local names="$1"
    local filter=""
    local name

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        name="$(regex_escape "$name")"
        if [ -z "$filter" ]; then
            filter="^(${name}"
        else
            filter="${filter}|${name}"
        fi
    done <<< "$names"

    printf '%s)(/.*)?$\n' "$filter"
}

selected_file="$run_dir/selection.txt"
missing_file="$run_dir/missing.txt"
config_file="$run_dir/config.txt"

selected=()
missing=()
declare -A benchmarks_by_dim=()
declare -A group_label_by_dim=()
declare -A group_file_by_dim=()
dim_order=()

for spec in "64B|bytes|64" "384d|elements|384"; do
    IFS='|' read -r case_label size_kind size_value <<< "$spec"

    for dtype in i8 i16 f16 bf16 f32; do
        dim="$(dimension_for "$dtype" "$size_kind" "$size_value")"
        bench_list="$(SIMSIMD_BENCH_DENSE_DIMENSIONS="$dim" "$binary" --benchmark_list_tests=true)"

        for metric in dot l2sq cos; do
            if name="$(pick "$bench_list" "$metric" "$dtype" "$dim")"; then
                selected+=("$case_label|$dtype|$dim|$name")
                if [ -z "${benchmarks_by_dim[$dim]+x}" ]; then
                    dim_order+=("$dim")
                    benchmarks_by_dim[$dim]="$name"
                    group_label_by_dim[$dim]="$case_label"
                    group_file_by_dim[$dim]="group-${case_label}-${dim}d.txt"
                else
                    benchmarks_by_dim[$dim]+=$'\n'"$name"
                fi
            else
                missing+=("$case_label|$dtype|$dim|$metric")
            fi
        done
    done
done

{
    echo "# $(date -Is)"
    echo "run_dir=$run_dir"
    echo "benchmark_min_time=$benchmark_min_time"
    echo "benchmark_repetitions=$benchmark_repetitions"
} > "$config_file"

{
    echo "# Selected benchmarks"
    for entry in "${selected[@]}"; do
        IFS='|' read -r case_label dtype dim name <<< "$entry"
        echo "$case_label  $dtype  ${dim}d  $name"
    done
} > "$selected_file"

{
    echo "# Missing from --benchmark_list_tests=true"
    for entry in "${missing[@]}"; do
        IFS='|' read -r case_label dtype dim metric <<< "$entry"
        echo "$case_label  $dtype  ${dim}d  ${metric}_${dtype}"
    done
} > "$missing_file"

echo "Run directory: $run_dir"
echo "Selection: $selected_file"
echo "Missing: $missing_file"

for dim in "${dim_order[@]}"; do
    group_label="${group_label_by_dim[$dim]}"
    group_file="$run_dir/${group_file_by_dim[$dim]}"
    filter="$(filter_for "${benchmarks_by_dim[$dim]}")"

    {
        echo "# $(date -Is)"
        echo "# Run dir: $run_dir"
        echo "# Group: $group_label"
        echo "# Dense dimensions: ${dim}d"
        echo "# Benchmark filter: $filter"
        echo "# Benchmark min time: $benchmark_min_time"
        echo "# Benchmark repetitions: $benchmark_repetitions"
        echo "# Selected benchmarks"
        printf '%s\n' "${benchmarks_by_dim[$dim]}"
        echo
        OPENBLAS_NUM_THREADS=1 \
        MKL_NUM_THREADS=1 \
        VECLIB_MAXIMUM_THREADS=1 \
        BLIS_NUM_THREADS=1 \
        SIMSIMD_BENCH_DENSE_DIMENSIONS="$dim" \
        "$binary" \
            "--benchmark_filter=$filter" \
            "--benchmark_min_time=$benchmark_min_time" \
            "--benchmark_repetitions=$benchmark_repetitions" \
            --benchmark_color=false
    } | tee "$group_file"

    echo
done

"$extract_script" "$run_dir"

echo "Results written to $run_dir"
