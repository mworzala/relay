#!/usr/bin/env bash
# Convenience wrapper around the Makefile so contributors who prefer a script
# have one. `./build.sh` builds; `./build.sh run` builds and launches.
set -euo pipefail
cd "$(dirname "$0")"
exec make "${@:-build}"
