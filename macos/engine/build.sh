#!/bin/bash
# Build native tpws engine for macOS (universal arm64+x86_64 when possible)
set -euo pipefail
cd "$(dirname "$0")/tpws-src"
echo "==> Building tpws for macOS..."
make clean >/dev/null 2>&1 || true
# Prefer universal mac target from upstream Makefile
if make mac; then
  :
else
  echo "make mac failed, trying host build..." >&2
  make bsd || make
fi
mkdir -p ../bin ../../bin
cp -f tpws ../bin/tpws
cp -f tpws ../../bin/tpws
chmod +x ../bin/tpws ../../bin/tpws 2>/dev/null || true
echo "==> Built: $(cd .. && pwd)/bin/tpws"
file ../bin/tpws 2>/dev/null || true