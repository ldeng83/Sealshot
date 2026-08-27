#!/bin/bash
# Compile and run the Vision OCR benchmark.
#
# Always compiles with -O so Intel and Apple Silicon results are comparable —
# an unoptimized (`swift file.swift`) run is not.
set -euo pipefail

cd "$(dirname "$0")"

BIN="$(mktemp -d)/vision-ocr-bench"
echo "compiling (-O)…"
swiftc -O -o "$BIN" vision-ocr-bench.swift

# Quieter, more repeatable numbers: this is a benchmark, not a race.
echo "running — takes about 2-4 minutes, please don't use the machine meanwhile"
echo ""
"$BIN" "$@"
