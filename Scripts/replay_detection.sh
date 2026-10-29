#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
if (( $# != 2 )); then
  print -u2 'Usage: replay_detection.sh input.jsonl output.json'
  exit 2
fi
mkdir -p "$ROOT/build/Replay"
swiftc -O -module-cache-path "$ROOT/build/ModuleCache" \
  "$ROOT/Sources/Detection/DetectionGate.swift" "$ROOT/Scripts/ReplayDetection.swift" \
  -o "$ROOT/build/Replay/replay-detection"
"$ROOT/build/Replay/replay-detection" "$1" "$2"
