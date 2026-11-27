#!/usr/bin/env bash
# Stage 4 / G3 Item 2: Memory exhaustion simulation and WAL recovery verification.
# (ADR 0020 decision 3, ADR 0066 decisions 3 & 5, Issue #15)
# Tests that when herald-queue is terminated by memory exhaustion (OOM / allocation abort)
# under an OS memory limit (ulimit -v / cgroup equivalent):
# 1. The process terminates safely without corrupting on-disk state.
# 2. On restart and replay from sigil-db WAL:
#    - Zero loss of ACKed jobs (already deleted).
#    - Zero data corruption (payloads and IDs remain identical).
#    - Correct redelivery of unACKed jobs (leased jobs restored to Ready with attempt incremented).
#    - Clean subsequent processing and completion.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deps/pins.env
source "$root/deps/pins.env"
compiler="${SIGIL:-$root/.deps/sigil-compiler/target/debug/sigil}"
core="${SIGIL_DB_CORE:-$root/.deps/sigil-db-core}"
entry=herald_mem_test.sigil

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
"$compiler" fmt --check "$entry"
"$compiler" check --root . "$entry"

# Build native binary
"$compiler" build --root . "$entry" main -o "$scratch/mem-test"

db_dir="$scratch/wal-db"
mkdir -p "$db_dir"

echo "=== Phase 1: Running under memory limit (ulimit -v 1048576) to induce memory exhaustion ==="
phase1_status=0
(
  # Impose 1 GB virtual memory quota (simulating container/cgroup limit where process OOMs during allocation)
  ulimit -v 1048576
  HERALD_MEM_PHASE="1" HERALD_QUEUE_TEST_DIR="$db_dir" "$scratch/mem-test"
) || phase1_status=$?

echo "Phase 1 terminated with exit code: $phase1_status"
if [[ "$phase1_status" -ne 70 ]]; then
  if [[ "$phase1_status" -eq 0 ]]; then
    echo "Error: Process succeeded unexpectedly without memory exhaustion" >&2
  else
    echo "Error: Expected memory-exhaustion allocation failure abort (exit code 70), but got exit code: $phase1_status" >&2
  fi
  exit 1
fi
echo "Phase 1 confirmed terminated by memory exhaustion (exit code 70)."

echo "=== Phase 2: Reopening from disk WAL without memory constraint and verifying recovery ==="
phase2_output="$(HERALD_MEM_PHASE="2" HERALD_QUEUE_TEST_DIR="$db_dir" "$scratch/mem-test")"
echo "Phase 2 output: $phase2_output"
if [[ "$phase2_output" != "0" ]]; then
  echo "Error: Phase 2 WAL recovery verification failed with output $phase2_output" >&2
  exit 1
fi

echo "=== Memory exhaustion simulation and WAL recovery verification PASSED (0) ==="
