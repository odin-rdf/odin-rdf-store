#!/bin/sh
# Runs the full test suite at both Term_ID widths (STORE-A-0001
# guardrail: both build configurations stay green). CI should invoke
# exactly this script.
set -eu
cd "$(dirname "$0")/.."

for width in 64 32; do
	echo "== Term_ID $width-bit =="
	for pkg in store store/memstore conformance store/kvstore; do
		echo "-- $pkg --"
		odin test "$pkg" -define:RDF_STORE_TERM_ID_BITS=$width
	done
done
