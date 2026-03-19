# Benchmark Scripts

This repository contains a few benchmark entry points with different goals. They are not interchangeable: some are intended to probe memory bandwidth limits, while others isolate single-core compute throughput.

## `./scripts/run_dot_i8_subtraction_thread_sweep.sh`

This script runs the more optimized `i8` dot-product subtraction path:

- `dot_i8_ice_fixed_query_i8_dot_i8_by_subtraction<64d>`

It sweeps over increasing thread counts to find the system saturation point. The goal is to see how quickly this kernel can drive the platform toward peak memory bandwidth. In a well-balanced setup, throughput should rise with thread count until the memory subsystem becomes the bottleneck.

By default the script:

1. Runs a broad thread sweep.
2. Re-runs the likely plateau points with a longer minimum benchmark time.
3. Optionally runs Intel MLC max-bandwidth for comparison.
4. Writes JSON, text, CSV, and Markdown summaries into a timestamped output directory.

If you have Intel MLC available, you can point the script at it with `--mlc-bin` to compare kernel throughput against a direct memory-bandwidth measurement.

## `./scripts/run_dot_i8_fixed_query_triplet.sh`

This script runs three different single-core implementations of `i8` dot-product on the same `64d` fixed-query problem:

- `dot_i8_ice_fixed_query<64d>/min_time:10.000`
- `dot_i8_ice_fixed_query_i8_dot_i8_by_subtraction<64d>/min_time:10.000`
- `dot_i8_ice_fixed_query_i8_dot_i8_by_subtraction_batched16<64d>/min_time:10.000`

It is configured to run with one thread, and the working set is intentionally tiny so the data should stay resident in L1. That makes this benchmark primarily useful for estimating the compute-bound limit of these implementations rather than DRAM bandwidth behavior.

Use this when you want an apples-to-apples comparison between the baseline fixed-query kernel, the subtraction-based implementation, and the batched-16 subtraction variant without interference from multi-core scaling or memory residency effects.

## `./scripts/run_dense_benchmarks.sh`

This script runs a broader matrix of dense benchmarks across:

- Distance functions: `l2sq`, `dot`, `cos`
- Precisions: `i8`, `fp16`, `bf16`, `fp32`
- Embedding dimensions: `64`, `384`

The data is not intended to be L1-resident, so this benchmark is better for measuring more realistic dense-vector behavior where cache and memory traffic matter.

It builds the benchmark binary, selects the best available ISA-specific implementation for each case, runs the selected groups, and writes per-group outputs plus a summarized result file.

## Choosing The Right Benchmark

Use `run_dot_i8_subtraction_thread_sweep.sh` when you care about multi-thread scaling and memory-bandwidth saturation.

Use `run_dot_i8_fixed_query_triplet.sh` when you care about single-core compute limits for three `i8` dot implementations on L1-resident data.

Use `run_dense_benchmarks.sh` when you want broader coverage across metrics, precisions, and embedding sizes under less cache-resident conditions.
