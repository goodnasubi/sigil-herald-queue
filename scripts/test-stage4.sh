#!/usr/bin/env bash
# Stage 4 (ADR 0066 decision 5): load and boundary tests, resource limits, and pre-publish verification (G2).
# Runs every check with the evaluator and with a native binary, using the pinned compiler and sigil-db core
# (see deps/pins.env and scripts/fetch-deps.sh).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deps/pins.env
source "$root/deps/pins.env"
compiler="${SIGIL:-$root/.deps/sigil-compiler/target/debug/sigil}"
core="${SIGIL_DB_CORE:-$root/.deps/sigil-db-core}"
entry=herald_load_test.sigil

if [[ $(git -C "$core" rev-parse HEAD) != "$SIGIL_DB_CORE_SHA" ]]; then
  echo "sigil-db の固定版 $SIGIL_DB_CORE_SHA が必要です" >&2
  exit 1
fi

scratch="$(mktemp -d)"
if [[ ${KEEP_SCRATCH:-0} == 1 ]]; then
  printf 'KEEP_SCRATCH=1: 一時ディレクトリを保持します: %s\n' "$scratch" >&2
else
  trap 'rm -rf -- "$scratch"' EXIT
fi
project="$scratch/project"
mkdir "$project"
git -C "$core" archive "$SIGIL_DB_CORE_SHA" db | tar -xf - -C "$project"
cp "$root"/Sigil.toml "$root"/herald_*.sigil "$project/"

cd "$project"
set -x
"$compiler" fmt --check herald_queue.sigil herald_persistence.sigil herald_wire.sigil herald_server.sigil herald_client.sigil "$entry"
"$compiler" check --root . "$entry"

# Run in evaluator mode (interprets AST/SIR)
result="$(HERALD_QUEUE_TEST_DIR="$scratch/eval-db" "$compiler" run --root . "$entry" main)"
test "$result" = 0

# Build and run native binary
"$compiler" build --root . "$entry" main -o "$scratch/load-test"
result="$(HERALD_QUEUE_TEST_DIR="$scratch/native-db" "$scratch/load-test")"
test "$result" = 0
