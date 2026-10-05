# Private launcher state, shared by logs and sockets.
# The subshell keeps its restrictive umask out of the tool's environment.
private_state_dir() (
  local dir="$STATE_DIR${1:+/$1}"
  [[ -z "${1:-}" || ! -L "$dir" ]] ||
    die "managed state directories must not be symlinks"
  umask 077
  mkdir -p -m 700 "$dir"
  [[ -O "$STATE_DIR" && -O "$dir" ]] ||
    die "state directories must be owned by you"
  chmod 700 "$STATE_DIR" "$dir"
)

# Host-side logging: the sandbox inherits pipes, never the log files.
start_logging() {
  local root="$STATE_DIR/logs" run
  [[ -x /usr/bin/tee ]] || die "/usr/bin/tee is required for logging"
  private_state_dir logs
  run="$(umask 077; mktemp -d "$root/$1.XXXXXX")" || die "cannot create log directory"
  printf '  Logs           %s\n' "$run" >&2
  # tee starts before sandbox-exec applies the profile. -i lets it drain
  # the tool's final output when the terminal sends Ctrl-C to both.
  exec > >(umask 077; exec /usr/bin/tee -i "$run/stdout.log") \
    2> >(umask 077; exec /usr/bin/tee -i "$run/stderr.log" >&2)
}
