# Host-side logging: the sandbox inherits pipes, never the log files.
start_logging() {
  local root="$STATE_DIR/logs" run
  [[ -x /usr/bin/tee ]] || die "/usr/bin/tee is required for logging"
  [[ ! -L "$STATE_DIR" && ! -L "$root" ]] ||
    die "logging directories must not be symlinks"
  umask 077
  mkdir -p -m 700 "$root"
  [[ -O "$STATE_DIR" && -O "$root" ]] ||
    die "logging directories must be owned by you"
  chmod 700 "$STATE_DIR" "$root"
  run="$(mktemp -d "$root/$1.XXXXXX")" || die "cannot create log directory"
  printf '  Logs           %s\n' "$run" >&2
  # tee starts before sandbox-exec applies the profile. -i lets it drain
  # the tool's final output when the terminal sends Ctrl-C to both.
  exec > >(/usr/bin/tee -i "$run/stdout.log") \
    2> >(/usr/bin/tee -i "$run/stderr.log" >&2)
}
