#!/bin/bash
set -e

echo "Building release CLI..."
swift build -c release --product TurboFieldfareCLI

echo "Creating result directories..."
mkdir -p benchmark-results/system benchmark-results/warmup benchmark-results/measured

# Record system info
echo "Recording system information..."
{
  git status --short
  git rev-parse HEAD
  sw_vers
  swift --version
  system_profiler SPHardwareDataType |
    awk -F': ' '/Model Name|Model Identifier|Chip|Total Number of Cores|Memory/ { print $1 ": " $2 }'
  shasum -a 256 scratch/gemma4.gturbo/manifest.json
  shasum -a 256 docs/benchmark-prompts/real-generation-v1/*.json
} > benchmark-results/system/system.txt

echo "Running warmup passes (discarded)..."
for case_seed in \
  short-explanation:20260721 \
  medium-review:20260722 \
  long-synthesis:20260723; do
  case_id="${case_seed%%:*}"
  seed="${case_seed##*:}"
  
  echo "  - Warmup: ${case_id}"
  .build/release/TurboFieldfareCLI \
    --model scratch/gemma4.gturbo \
    --messages-file "docs/benchmark-prompts/real-generation-v1/${case_id}.json" \
    --max-new 1024 \
    --max-context 4096 \
    --temperature 0.2 \
    --top-k 64 \
    --top-p 0.95 \
    --seed "$seed" \
    > "benchmark-results/warmup/${case_id}.stdout" \
    2> "benchmark-results/warmup/${case_id}.stderr"
done

echo "Running measured passes..."
for case_seed in \
  short-explanation:20260721 \
  medium-review:20260722 \
  long-synthesis:20260723; do
  case_id="${case_seed%%:*}"
  seed="${case_seed##*:}"
  
  echo "  - Measuring: ${case_id}"
  .build/release/TurboFieldfareCLI \
    --model scratch/gemma4.gturbo \
    --messages-file "docs/benchmark-prompts/real-generation-v1/${case_id}.json" \
    --max-new 1024 \
    --max-context 4096 \
    --temperature 0.2 \
    --top-k 64 \
    --top-p 0.95 \
    --seed "$seed" \
    > "benchmark-results/measured/${case_id}.stdout" \
    2> "benchmark-results/measured/${case_id}.stderr"
done

echo ""
echo "--- Benchmark Results ---"
grep -h '^\[stop=' benchmark-results/measured/*.stderr | tee benchmark-results/summary.txt
echo "Results saved to benchmark-results/summary.txt"
