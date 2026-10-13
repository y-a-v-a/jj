#!/bin/sh
# Downloads the open datasets (cached in data/raw/) and regenerates the
# processed resources in Sources/MyriaData/Resources/Earth/, then verifies them.
set -eu
cd "$(dirname "$0")/.."
exec swift run -c release jj-data all "$@"
