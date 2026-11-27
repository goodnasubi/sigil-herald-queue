#!/usr/bin/env bash
# Stage 3 (ADR 0066 decision 5): wire codec, TCP server and client over loopback.
# Runs every check with the evaluator and with a native binary, using the pinned compiler and sigil-db core
# (see deps/pins.env and scripts/fetch-deps.sh). Set SIGIL and SIGIL_DB_CORE to use already prepared copies.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/deps/pins.env"
compiler="${SIGIL:-$root/.deps/sigil-compiler/target/debug/sigil}"
core="${SIGIL_DB_CORE:-$root/.deps/sigil-db-core}"

if [[ $(git -C "$core" rev-parse HEAD) != "$SIGIL_DB_CORE_SHA" ]]; then
  echo "sigil-db の固定版 $SIGIL_DB_CORE_SHA が必要です" >&2
  exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
project="$scratch/project"
mkdir "$project"
git -C "$core" archive "$SIGIL_DB_CORE_SHA" db | tar -xf - -C "$project"
cp "$root"/Sigil.toml "$root"/herald_*.sigil "$project/"

cd "$project"
set -x
"$compiler" fmt --check herald_queue.sigil herald_persistence.sigil herald_wire.sigil herald_server.sigil herald_client.sigil herald_wire_test.sigil herald_tcp_test.sigil

for entry in herald_wire_test.sigil herald_tcp_test.sigil; do
  "$compiler" check --root . "$entry"
  result="$(HERALD_QUEUE_TEST_DIR="$scratch/eval-db-$entry" "$compiler" run --root . "$entry" main)"
  test "$result" = 0
  "$compiler" build --root . "$entry" main -o "$scratch/native-$entry"
  result="$(HERALD_QUEUE_TEST_DIR="$scratch/native-db-$entry" "$scratch/native-$entry")"
  test "$result" = 0
done

# The long fuzz run of the codec: the evaluator and the native binary both run 200000 mutated frames.
result="$("$compiler" run --root . herald_wire_test.sigil fuzz 200000 20261127)"
test "$result" -ge 0
