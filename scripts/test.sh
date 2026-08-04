#!/bin/sh
# Runs the full test suite at both Term_ID widths (STORE-A-0001
# guardrail: both build configurations stay green). CI should invoke
# exactly this script.
set -eu
cd "$(dirname "$0")/.."

echo "== tests: Term_ID 64-bit (default) =="
odin test store

echo "== tests: Term_ID 32-bit =="
odin test store -define:RDF_STORE_TERM_ID_BITS=32
