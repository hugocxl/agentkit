#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build/validation
swift build --build-tests -Xswiftc -warnings-as-errors > build/validation/build.log 2>&1 || { tail -80 build/validation/build.log; exit 1; }
swift test --skip-build "$@" > build/validation/test.log 2>&1 || { tail -100 build/validation/test.log; exit 1; }
scripts/bundle-example.sh --skip-build
codesign --verify --deep --strict 'build/AgentKit Example.app'
awk '/Test Suite.*xctest.*passed/ {print; getline; print}' build/validation/test.log
echo 'validation passed'
