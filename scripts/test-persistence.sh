#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/deps/pins.env"
compiler="${SIGIL:-$root/.deps/sigil-compiler/target/debug/sigil}"
core="${SIGIL_DB_CORE:-$root/.deps/sigil-db-core}"
entry=herald_queue_persistence_test.sigil

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
cp "$root"/Sigil.toml "$root"/herald_queue.sigil "$root"/herald_persistence.sigil "$root"/"$entry" "$project/"

cd "$project"
set -x
"$compiler" fmt --check herald_queue.sigil herald_persistence.sigil "$entry"
"$compiler" check --root . "$entry"
result="$(HERALD_QUEUE_TEST_DIR="$scratch/eval-db" "$compiler" run --root . "$entry" main)"
test "$result" = 0
"$compiler" build --root . "$entry" main -o "$scratch/persistence-test"
result="$(HERALD_QUEUE_TEST_DIR="$scratch/native-db" "$scratch/persistence-test")"
test "$result" = 0
