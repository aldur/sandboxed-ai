#!/usr/bin/env bash
# Regression checks for private state without changing the tool's umask.
set -euo pipefail
ROOT="$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/logging.sh"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/sandboxed-ai-state.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
STATE_DIR="$work/state"

for mask in 022 002 077; do
  umask "$mask"
  before="$(umask)"
  private_state_dir
  private_state_dir logs
  private_state_dir sockets
  [[ "$(umask)" == "$before" ]] || die "private state changed the caller's umask"
done
umask 022
: > "$work/workspace-file"
[[ "$(ls -l "$work/workspace-file" | awk '{print $1}')" == -rw-r--r-- ]] ||
  die "workspace file permissions changed"
for dir in "$STATE_DIR" "$STATE_DIR/logs" "$STATE_DIR/sockets"; do
  [[ "$(ls -ld "$dir" | awk '{print $1}')" == drwx------ ]] ||
    die "state directory is not private: $dir"
done

ln -s "$STATE_DIR" "$work/relocated-state"
STATE_DIR="$work/relocated-state"
private_state_dir
private_state_dir logs
private_state_dir sockets
[[ "$(umask)" == 0022 ]] || die "relocated state changed the caller's umask"

mkdir "$work/target"
ln -s "$work/target" "$STATE_DIR/linked"
if (private_state_dir linked) 2>/dev/null; then
  die "managed state subdirectory symlink was accepted"
fi
printf 'Private state regression checks passed.\n'
