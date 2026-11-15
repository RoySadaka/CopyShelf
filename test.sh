#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
# Interpret together so tests exercise the same implementation without a package dependency.
cat History.swift QuickLookImage.swift tests/main.swift > build/history-tests.swift
/usr/bin/swift build/history-tests.swift
