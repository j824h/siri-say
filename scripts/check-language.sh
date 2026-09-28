#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p .build
swiftc Sources/SiriSay/Runtime.swift Sources/SiriSay/LanguageDetection.swift \
    Tests/LanguageDetectionChecks.swift -o .build/check-language
.build/check-language
