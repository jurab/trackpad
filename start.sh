#!/bin/bash
# Start the trackpad system
# Usage: ./start.sh
#
# Prerequisites:
#   1. iPhone connected via USB with PhoneTrackpad app running
#   2. Mac has Accessibility permissions granted to Terminal/iTerm
#   3. iproxy installed (brew install libimobiledevice)

set -e

echo "=== iPhone Trackpad ==="
echo ""

# Check iproxy
if ! command -v iproxy &> /dev/null; then
    echo "ERROR: iproxy not found. Install with: brew install libimobiledevice"
    exit 1
fi

# Start iproxy in background
echo "Starting USB tunnel (iproxy 8765:8765)..."
iproxy 8765:8765 &
IPROXY_PID=$!

# Cleanup on exit
cleanup() {
    echo ""
    echo "Shutting down..."
    kill $IPROXY_PID 2>/dev/null || true
    exit 0
}
trap cleanup EXIT INT TERM

sleep 1
echo "USB tunnel active (PID $IPROXY_PID)"
echo ""

# Build and run Mac receiver
echo "Building Mac receiver..."
cd "$(dirname "$0")/MacReceiver"
swift run 2>&1
