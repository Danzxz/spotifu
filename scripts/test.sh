#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local
swiftc -module-cache-path .local/swift-module-cache Shared/Core/*.swift Tests/Host/main.swift -o .local/core-tests
.local/core-tests
python3 -m unittest discover -s Tests -p 'test_*.py'
