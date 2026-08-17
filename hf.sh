# Shared Hugging Face machinery, sourced by sandbox.sh (macOS) and
# sandbox-linux.sh (Linux). Everything here runs on the host, before any
# sandbox starts: the sandboxes deny network access, so downloads happen
# out here and land in MODELS_DIR, which the sandboxes only read.
#
# The sourcing script must define: die, info, MODELS_DIR.
#
# Everything fetched here is later parsed by a server inside the sandbox —
# weights by llama.cpp/MLX, and config.json even decides which server binary
# runs (see cmd_mlx) — so downloads are checksum-verified against what the
# repo publishes, not merely TLS-transported. Network failure and "no such
# repo" both yield an empty listing; callers treat the two alike and fall
# back to local files.

# For the delimited quant-label match in select_gguf_files.
shopt -s extglob

# ── Generic helpers ───────────────────────────────────────

# Read the non-empty lines of $1 into the array named by $2.
split_lines() {
  local -n _lines="$2"
  _lines=()
  local line
  while IFS= read -r line; do [[ -n "$line" ]] && _lines+=("$line"); done <<<"$1"
  return 0
}

# Absolute, physical (symlink-free) path of existing file $1.
abspath() {
  local dir
  dir="$(CDPATH='' cd -P -- "$(dirname -- "$1")" && pwd)" ||
    die "cannot resolve path: $1"
  printf '%s/%s' "$dir" "${1##*/}"
}

# ── Hugging Face downloads ────────────────────────────────

# rfilenames of an HF repo, one per line; $2 optionally narrows to a
# (grep-escaped) filename-suffix pattern. Empty output when offline or the
# repo is unknown.
hf_listing() {
  curl -sf "https://huggingface.co/api/models/$1" |
    grep -o "\"rfilename\":\"[^\"]*${2:-}\"" |
    sed 's/"rfilename":"//;s/"//'
}

# A Hugging Face repo id, and nothing that could walk out of MODELS_DIR:
# every spec becomes part of a local path ("$MODELS_DIR/$repo/$file"), and
# the HF URL normalizes ".." away at the host root, so a spec like
# ../../org/repo would still fetch while writing outside the models dir.
valid_hf_repo() { [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; }

# A relative path safe to append to a directory: non-empty, not absolute,
# and free of ".." or empty components. Applied to filenames from the
# caller *and* from HF's listing — the listing is remote input too.
safe_rel_path() {
  [[ -n "$1" && "$1" != /* ]] || return 1
  local -a parts
  local part
  IFS='/' read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != ".." ]] || return 1
  done
  return 0
}

# Hex SHA digest of stdin, $1 bits wide. macOS ships shasum (perl);
# Linux ships sha1sum/sha256sum (coreutils).
sha_hex() {
  if command -v shasum >/dev/null; then
    shasum -a "$1" 2>/dev/null | cut -d' ' -f1
  else
    "sha$1sum" 2>/dev/null | cut -d' ' -f1
  fi
}

# Digest of $1, in the "$2" scheme, or empty when it cannot be computed.
#   sha256  — plain content hash, what HF publishes for LFS objects
#   gitsha1 — git blob id: sha1 over "blob <bytes>\0" then the content,
#             which is the oid HF reports for non-LFS (small) files
file_digest() {
  local file="$1"
  case "$2" in
  sha256) sha_hex 256 <"$file" ;;
  gitsha1)
    {
      printf 'blob %d\0' "$(wc -c <"$file")"
      cat "$file"
    } | sha_hex 1
    ;;
  esac
}

# True when $1's content matches the expected digest $2 ("scheme:hex").
file_matches() {
  [[ -f "$1" && -n "$2" ]] || return 1
  [[ "$(file_digest "$1" "${2%%:*}")" == "${2#*:}" ]]
}

# Where a verified download records the digest it was checked against, so a
# cache hit costs a string compare instead of re-hashing gigabytes. Hidden,
# which also keeps it out of seed_hf_cache's snapshot.
digest_sidecar() { printf '%s/.%s.digest' "${1%/*}" "${1##*/}"; }

# Populate HF_DIGEST for repo $1: file path → "scheme:hex". Hugging Face
# publishes a SHA-256 for LFS objects (the weights) and a git blob SHA-1
# for everything else, both in the same tree listing. Stays empty when
# offline — callers then fall back to their weaker local checks.
declare -A HF_DIGEST=()
hf_load_digests() {
  HF_DIGEST=()
  local json entry path
  json="$(curl -sf "https://huggingface.co/api/models/$1/tree/main?recursive=1")" ||
    return 0
  # One JSON array on one line: split it into an entry per line first.
  while IFS= read -r entry; do
    [[ "$entry" =~ \"path\":\"([^\"]+)\" ]] || continue
    path="${BASH_REMATCH[1]}"
    if [[ "$entry" =~ \"lfs\":\{\"oid\":\"([0-9a-f]{64})\" ]]; then
      HF_DIGEST["$path"]="sha256:${BASH_REMATCH[1]}"
    elif [[ "$entry" =~ \"oid\":\"([0-9a-f]{40})\" ]]; then
      HF_DIGEST["$path"]="gitsha1:${BASH_REMATCH[1]}"
    fi
  done < <(sed 's/},{"type"/}\n{"type"/g' <<<"$json")
  return 0 # best-effort by contract: callers fall back when it finds nothing
}

# Download $2 from repo $1 into $3 (resumable), verifying it against the
# digest hf_load_digests published for it. A mismatch is retried once from
# scratch: `curl -C -` resumes by appending, so a file truncated mid-write
# by an earlier run splices old and new bytes into something no length or
# magic-byte check would catch. $4 is an optional fallback validator to run
# when no digest is known (offline) — currently only 'gguf'. All output
# goes to stderr.
hf_download() {
  local repo="$1" file="$2" target="$3" fallback="${4:-}"
  local want="${HF_DIGEST[$file]:-}"
  local sidecar
  sidecar="$(digest_sidecar "$target")"

  if [[ -f "$target" ]]; then
    if [[ -n "$want" ]]; then
      # A sidecar naming the expected digest means this exact content was
      # verified when it landed; otherwise hash it now (once) and record it.
      if [[ "$(cat "$sidecar" 2>/dev/null)" == "$want" ]] || file_matches "$target" "$want"; then
        printf '%s' "$want" >"$sidecar"
        info "cached:" "$file" >&2
        return
      fi
      rm -f "$target" "$sidecar"
      info "removed:" "checksum mismatch, re-downloading $file" >&2
    elif hf_fallback_ok "$target" "$fallback"; then
      info "cached:" "$file" >&2
      return
    else
      rm -f "$target" "$sidecar"
      info "removed:" "invalid cached file, re-downloading $file" >&2
    fi
  fi

  local url="https://huggingface.co/$repo/resolve/main/$file"
  local attempt http_code
  mkdir -p "${target%/*}"
  for attempt in 1 2; do
    ((attempt == 1)) || {
      rm -f "$target"
      info "retry:" "$file (fresh download)" >&2
    }
    info "download:" "$file" >&2
    curl -fL -C - --progress-bar -o "$target" "$url" || {
      # Only now pay for a HEAD probe, to say *why* it failed.
      http_code="$(curl -sI -o /dev/null -w '%{http_code}' "$url")" || http_code="000"
      [[ "$http_code" == 200 || "$http_code" == 302 ]] ||
        die "file not found on HF (HTTP $http_code): $repo/$file"
      die "failed to download $repo/$file"
    }

    if [[ -z "$want" ]]; then
      hf_fallback_ok "$target" "$fallback" || {
        rm -f "$target"
        die "downloaded file failed its $fallback check: $repo/$file"
      }
      return
    fi
    if file_matches "$target" "$want"; then
      printf '%s' "$want" >"$sidecar"
      return
    fi
  done

  rm -f "$target" "$sidecar"
  die "checksum mismatch for $repo/$file (expected $want)"
}

# Content check used only when HF published no digest (offline resolution
# against already-downloaded files). $2 selects it; empty means "non-empty
# file is good enough", which is all an arbitrary MLX repo file allows.
hf_fallback_ok() {
  case "$2" in
  gguf) [[ "$(head -c 4 "$1" 2>/dev/null)" == "GGUF" ]] ;;
  *) [[ -s "$1" ]] ;;
  esac
}

# ── Model resolution: GGUF (llama-server) ─────────────────

# Strip a GGUF split suffix (-00001-of-00003.gguf) or a plain .gguf
# extension, yielding a key shared by every shard of one quant. Sets
# shard_key (caller-read; avoids a subshell in the selection loops).
strip_shard() {
  if [[ "$1" =~ ^(.*)-[0-9]+-of-[0-9]+\.gguf$ ]]; then
    shard_key="${BASH_REMATCH[1]}"
  else
    shard_key="${1%.gguf}"
  fi
}

# Choose the GGUF file(s) for a selection within a repo's listing.
# Prints the chosen rfilename(s), newline-separated, to stdout.
# On a missing or ambiguous selection, explains on stderr and returns 1.
#   $1 repo, $2 selection (file.gguf or QUANT), $3 kind, remaining: rfilenames
# Kind scopes *quant-label* matching to one half of a vision repo: 'model'
# ignores multimodal projectors (mmproj-*.gguf), 'mmproj' considers only
# them. Explicit filenames bypass the filter — that's how a projector is
# named directly.
select_gguf_files() {
  local repo="$1" sel="$2" kind="$3"
  shift 3
  local -a all=("$@")
  local -a want=()
  local f shard_key

  if [[ "$sel" == *.gguf ]]; then
    # Explicit filename: pull in sibling shards if it is part of a split set.
    local key
    strip_shard "$sel"
    key="$shard_key"
    for f in "${all[@]}"; do
      strip_shard "$f"
      [[ "$shard_key" == "$key" ]] && want+=("$f")
    done
    # Trust the literal name if the listing did not surface it.
    [[ ${#want[@]} -gt 0 ]] || want=("$sel")
  else
    # Quant label, matched case-insensitively against the listing.
    [[ ${#all[@]} -gt 0 ]] || {
      printf "error: cannot resolve quant '%s': no GGUF listing for %s\n" "$sel" "$repo" >&2
      return 1
    }

    local sel_lc="${sel,,}"
    local -a matches=()
    for f in "${all[@]}"; do
      local base_lc="${f##*/}"
      base_lc="${base_lc,,}"
      case "$kind" in
      mmproj) [[ "$base_lc" == mmproj* ]] || continue ;;
      *) [[ "$base_lc" == mmproj* ]] && continue ;;
      esac
      # The label must appear delimited by [-_.] or an edge: 'F16' matches
      # '…-F16.gguf' but not '…-BF16.gguf', which a bare substring test
      # would quietly pick. "$sel_lc" is quoted, so it matches literally;
      # the extglob alternations supply the optional delimited context.
      [[ "$base_lc" == @(|*[-_.])"$sel_lc"@(|[-_.]*) ]] && matches+=("$f")
    done
    [[ ${#matches[@]} -gt 0 ]] || {
      printf "error: no GGUF matching quant '%s' in %s. Available:\n" "$sel" "$repo" >&2
      printf '  %s\n' "${all[@]}" | LC_ALL=C sort >&2
      return 1
    }

    # Collapse shards: group matches by quant key.
    local -A keyset=()
    for f in "${matches[@]}"; do
      strip_shard "$f"
      keyset["$shard_key"]=1
    done

    local -a keys=("${!keyset[@]}")
    local k
    if [[ ${#keys[@]} -gt 1 ]]; then
      # Tie-break: prefer the single quant whose name ends with the label
      # (e.g. 'Q6_K' over 'Q6_K_XL').
      keys=()
      for k in "${!keyset[@]}"; do
        local kb="${k##*/}"
        [[ "${kb,,}" == *"$sel_lc" ]] && keys+=("$k")
      done
    fi
    if [[ ${#keys[@]} -ne 1 ]]; then
      printf "error: quant '%s' is ambiguous in %s; matches:\n" "$sel" "$repo" >&2
      local -a bases=()
      for k in "${!keyset[@]}"; do bases+=("${k##*/}"); done
      printf '  %s\n' "${bases[@]}" | LC_ALL=C sort >&2
      printf 'specify a more precise quant or the full filename.\n' >&2
      return 1
    fi
    local chosen="${keys[0]}"

    for f in "${matches[@]}"; do
      strip_shard "$f"
      [[ "$shard_key" == "$chosen" ]] && want+=("$f")
    done
  fi

  printf '%s\n' "${want[@]}" | LC_ALL=C sort
}

# Resolve a model spec to a local GGUF file path, downloading from HF as
# needed. Accepts:
#   /path/to/model.gguf    → local file, used directly
#   org/repo:file.gguf     → that exact file (plus sibling shards if split)
#   org/repo:QUANT         → file matching the quant label (e.g. Q4_K_M)
#   org/repo               → lists available GGUF files in the repo
# Split models: all shards are fetched and the first shard's path is
# returned; llama-server loads the rest from the same directory.
# $2 (default 'model') scopes quant matching — see select_gguf_files.
resolve_model() {
  local spec="$1" kind="${2:-model}"

  # Local file path
  if [[ -f "$spec" ]]; then
    abspath "$spec"
    return
  fi

  # Must look like an HF ref: org/repo[...], not an absolute path.
  [[ "$spec" == */* && "$spec" != /* ]] ||
    die "model not found: $spec (use a local path, org/repo:file.gguf, or org/repo:QUANT)"

  local repo="$spec" sel=""
  if [[ "$spec" == *:* ]]; then
    repo="${spec%%:*}"
    sel="${spec#*:}"
  fi
  valid_hf_repo "$repo" ||
    die "not a Hugging Face repo id: $repo (expected org/name)"
  [[ -z "$sel" ]] || safe_rel_path "$sel" ||
    die "invalid file selection: $sel"

  # If everything the selection needs is already downloaded and verified
  # (each file has the digest sidecar hf_download writes), there is no
  # reason to talk to Hugging Face at all — resolve locally and return.
  # A split model only counts when every shard is present; the
  # -00001-of-00003 suffix says how many to expect. Anything missing or
  # unverified falls through to the normal remote path below. Deleting
  # the sidecars (or the files) forces a re-sync with upstream, same as
  # the .download-complete marker in resolve_mlx_model.
  if [[ -n "$sel" && -d "$MODELS_DIR/$repo" ]]; then
    local local_listing
    local_listing="$(cd "$MODELS_DIR/$repo" && find . -name '*.gguf' | sed 's|^\./||')"
    local -a lall=() lwant=()
    local lout lf lfirst="" complete=1
    split_lines "$local_listing" lall
    if [[ ${#lall[@]} -gt 0 ]] &&
      lout="$(select_gguf_files "$repo" "$sel" "$kind" "${lall[@]}" 2>/dev/null)"; then
      split_lines "$lout" lwant
      for lf in "${lwant[@]}"; do
        safe_rel_path "$lf" || {
          complete=0
          break
        }
        [[ -f "$MODELS_DIR/$repo/$lf" && -s "$(digest_sidecar "$MODELS_DIR/$repo/$lf")" ]] || {
          complete=0
          break
        }
        if [[ "$lf" =~ -[0-9]+-of-0*([0-9]+)\.gguf$ ]]; then
          [[ ${#lwant[@]} -eq ${BASH_REMATCH[1]} ]] || {
            complete=0
            break
          }
        fi
        [[ -n "$lfirst" ]] || lfirst="$MODELS_DIR/$repo/$lf"
      done
      if [[ ${#lwant[@]} -gt 0 && "$complete" == 1 ]]; then
        [[ ${#lwant[@]} -gt 1 ]] && info "split:" "${#lwant[@]} shards" >&2
        for lf in "${lwant[@]}"; do
          info "cached:" "$lf" >&2
        done
        printf '%s' "$lfirst"
        return
      fi
    fi
  fi

  # GGUF files available in the repo (may include subfolders).
  local listing
  listing="$(hf_listing "$repo" '\.gguf')" || listing=""

  # Offline fallback: resolve against the GGUFs already downloaded for this
  # repo, so a quant spec keeps working without network once fetched.
  # (hf_download then finds them cached; a quant that only exists upstream
  # still dies at download, as it must.)
  if [[ -z "$listing" && -d "$MODELS_DIR/$repo" ]]; then
    listing="$(cd "$MODELS_DIR/$repo" && find . -name '*.gguf' | sed 's|^\./||')"
    [[ -n "$listing" ]] && info "offline:" "resolving against local files for $repo" >&2
  fi

  # Bare repo (no selection): list available files and exit.
  if [[ -z "$sel" ]]; then
    [[ -n "$listing" ]] || die "no GGUF files found in $repo"
    printf 'Available GGUF files in %s:\n' "$repo" >&2
    LC_ALL=C sort <<<"$listing" | sed 's/^/  /' >&2
    printf '\nUse: --model %s:<filename>  or  --model %s:<QUANT>\n' "$repo" "$repo" >&2
    exit 1
  fi

  local -a all=()
  split_lines "$listing" all

  info "resolving:" "$repo:$sel" >&2
  local files_out
  files_out="$(select_gguf_files "$repo" "$sel" "$kind" "${all[@]}")" || exit 1

  local -a want=()
  split_lines "$files_out" want
  [[ ${#want[@]} -gt 1 ]] && info "split:" "${#want[@]} shards" >&2

  hf_load_digests "$repo"

  local f target first=""
  for f in "${want[@]}"; do
    safe_rel_path "$f" || die "unsafe filename in $repo: $f"
    target="$MODELS_DIR/$repo/$f"
    hf_download "$repo" "$f" "$target" gguf
    [[ -z "$first" ]] && first="$target"
  done

  printf '%s' "$first"
}

# ── Single-file resolution (chat templates & co.) ─────────

# Resolve one auxiliary file (e.g. a chat template) to a local path,
# downloading from HF as needed. Accepts:
#   /path/to/file          → local file, used directly
#   org/repo:path/to/file  → that exact file from the repo
#   org/repo               → lists files matching suffix $2
# $2 is a (grep-escaped) filename-suffix pattern for the bare-repo listing
# (e.g. '\.jinja'); $3 names the thing in messages. No quant grammar here:
# the selection is always an explicit repo-relative path.
resolve_hf_file() {
  local spec="$1" suffix="$2" what="$3"

  # Local file path
  if [[ -f "$spec" ]]; then
    abspath "$spec"
    return
  fi

  # Must look like an HF ref: org/repo[:file], not an absolute path.
  [[ "$spec" == */* && "$spec" != /* ]] ||
    die "$what not found: $spec (use a local path, org/repo:file, or org/repo to list)"

  local repo="$spec" sel=""
  if [[ "$spec" == *:* ]]; then
    repo="${spec%%:*}"
    sel="${spec#*:}"
  fi
  valid_hf_repo "$repo" ||
    die "not a Hugging Face repo id: $repo (expected org/name)"
  [[ -z "$sel" ]] || safe_rel_path "$sel" ||
    die "invalid file selection: $sel"

  # Bare repo (no selection): list matching files and exit.
  if [[ -z "$sel" ]]; then
    local listing
    listing="$(hf_listing "$repo" "$suffix")" || listing=""
    [[ -n "$listing" ]] || die "no matching files found in $repo"
    printf 'Available files in %s:\n' "$repo" >&2
    LC_ALL=C sort <<<"$listing" | sed 's/^/  /' >&2
    printf '\nUse: %s:<filename>\n' "$repo" >&2
    exit 1
  fi

  # A verified earlier download (digest sidecar present) resolves locally,
  # with no HF round-trip — delete the sidecar to force a re-sync.
  local target="$MODELS_DIR/$repo/$sel"
  if [[ -f "$target" && -s "$(digest_sidecar "$target")" ]]; then
    info "cached:" "$sel" >&2
    printf '%s' "$target"
    return
  fi

  info "resolving:" "$repo:$sel" >&2
  hf_load_digests "$repo"
  hf_download "$repo" "$sel" "$target"
  printf '%s' "$target"
}

# ── Model resolution: MLX (mlx-server) ────────────────────

# Resolve an MLX model spec to a local model directory, downloading from HF
# as needed. Accepts:
#   /path/to/model-dir     → local directory, used directly
#   org/repo               → full repo download (an MLX model is a directory:
#                            config.json, tokenizer files, *.safetensors)
resolve_mlx_model() {
  local spec="$1"

  # Local directory
  if [[ -d "$spec" ]]; then
    [[ -f "$spec/config.json" ]] ||
      die "not an MLX model directory (no config.json): $spec"
    local dir
    dir="$(CDPATH='' cd -P -- "$spec" && pwd)" || die "cannot resolve path: $spec"
    printf '%s' "$dir"
    return
  fi

  # Must look like an HF ref: org/repo, not an absolute path.
  [[ "$spec" == */* && "$spec" != /* ]] ||
    die "model not found: $spec (use a local directory or org/repo)"
  valid_hf_repo "$spec" ||
    die "not a Hugging Face repo id: $spec (expected org/name)"

  local target_dir="$MODELS_DIR/$spec"

  # A finished earlier download is a complete snapshot of the repo whose
  # files were checksum-verified as they landed (the marker is written only
  # once every one of them has), so resolve it locally — no HF round-trip,
  # works offline. Delete the marker (or the directory) to re-sync with
  # upstream. Anything that can rewrite a cached weight can also rewrite
  # this marker, so it records "verified on arrival", not "verified now".
  if [[ -f "$target_dir/.download-complete" ]]; then
    info "cached:" "$spec" >&2
    printf '%s' "$target_dir"
    return
  fi

  local listing
  listing="$(hf_listing "$spec")" || listing=""

  # Offline fallback for a download that predates the marker: a local copy
  # with a config.json is plausibly complete — use it (the server fails
  # loudly on missing weights), but don't mark it: the next online run
  # verifies against the real listing first.
  if [[ -z "$listing" ]]; then
    if [[ -f "$target_dir/config.json" ]]; then
      info "offline:" "cannot list $spec on HF; using local copy" >&2
      printf '%s' "$target_dir"
      return
    fi
    die "no files found on HF for $spec"
  fi

  info "resolving:" "$spec" >&2
  hf_load_digests "$spec"

  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    # Skip repo metadata (dotfiles like .gitattributes, README, ...).
    case "$f" in
    .* | */.* | README.md | *.md) continue ;;
    esac
    safe_rel_path "$f" || die "unsafe filename in $spec: $f"
    hf_download "$spec" "$f" "$target_dir/$f"
  done <<<"$listing"

  [[ -f "$target_dir/config.json" ]] ||
    die "not an MLX model repo (no config.json): $spec"

  touch "$target_dir/.download-complete"

  printf '%s' "$target_dir"
}

# Seed an HF hub cache entry for a side-loaded repo download. The mlx
# servers list (/v1/models) and resolve models through huggingface_hub's
# cache, so a symlinked cache entry makes them treat the download as if it
# came from the hub — offline: clients can auto-discover the model and
# address it by its repo id. Rebuilt from scratch on every start. Layout:
#   hub/models--{org}--{name}/refs/main           → pseudo revision
#   hub/models--{org}--{name}/snapshots/<rev>/<f> → models/<repo>/<f>
seed_hf_cache() {
  local repo="$1" model_dir="$2"
  : "${HF_HOME:?seed_hf_cache requires HF_HOME}"
  local entry="$HF_HOME/hub/models--${repo//\//--}"
  # Content-addressing is irrelevant locally, but the ref must name an
  # existing snapshot directory and look like a commit hash.
  local rev="0000000000000000000000000000000000000000"

  rm -rf "$entry"
  mkdir -p "$entry/refs" "$entry/snapshots/$rev"
  printf '%s' "$rev" >"$entry/refs/main"

  local f rel dest
  while IFS= read -r -d '' f; do
    rel="${f#"$model_dir/"}"
    dest="$entry/snapshots/$rev/$rel"
    mkdir -p "${dest%/*}"
    ln -s "$f" "$dest"
  done < <(find "$model_dir" -type f ! -name '.*' -print0)
}
