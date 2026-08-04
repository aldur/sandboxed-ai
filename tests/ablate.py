#!/usr/bin/env python3
"""Ablation study over the seatbelt profiles.

For every `(allow …)` form — and, when a form survives, every filter clause
inside it — build a variant of the profile set with that entry removed and
check whether the tools still work. Anything that still works is a grant the
sandbox does not need.

Run it from the repo root:  tests/ablate.py [profile.sb …]

Not part of the e2e suite: this takes an hour or so and is a tool for
auditing the profiles, not a regression test. tests/e2e.sh is what proves
the result afterwards.
"""

import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILES = os.path.join(ROOT, "profiles")
RUN = os.path.expanduser("~/.sandboxed-ai-ablate")
# prepare() wipes RUN each time, so minimized profiles land outside it.
OUT = os.path.expanduser("~/.sandboxed-ai-ablate-out")
PORT = 8080
GGUF = os.environ.get("TEST_GGUF_MODEL", "bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M")
MLX = os.environ.get("TEST_MLX_MODEL", "mlx-community/SmolLM-135M-Instruct-4bit")

# Which smoke tests must pass for a variant of each profile to count as
# "still works". Every profile is exercised through each tool that imports
# it; a grant is only droppable if none of them needs it.
COVERAGE = {
    "common.sb": ["llama", "vision", "mlx", "shell", "pi", "tui", "llm"],
    "server.sb": ["llama", "vision", "mlx"],
    "client.sb": ["shell", "pi", "tui", "llm"],
    "llama-server.sb": ["llama", "vision"],
    "mlx-server.sb": ["mlx"],
    "pi.sb": ["shell", "pi", "tui"],
    "llm.sb": ["llm"],
    "net-tcp.sb": ["llama", "mlx"],
    "net-unix.sb": ["llama_sock"],
}

VISION = os.environ.get("TEST_VISION_MODEL", "ggml-org/SmolVLM-256M-Instruct-GGUF:Q8_0")


# ── s-expression splitting ────────────────────────────────
def top_forms(text):
    """Yield (start, end) spans of top-level parenthesised forms."""
    depth = start = 0
    in_str = False
    for i, ch in enumerate(text):
        if in_str:
            if ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == ";" and depth == 0:  # comment line outside a form
            continue
        elif ch == "(":
            if depth == 0:
                start = i
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                yield start, i + 1


def clause_spans(form_text):
    """Spans of the top-level clauses inside a form, skipping the head."""
    spans = []
    depth = 0
    start = None
    in_str = False
    for i, ch in enumerate(form_text):
        if in_str:
            if ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "(":
            depth += 1
            if depth == 2:
                start = i
        elif ch == ")":
            if depth == 2 and start is not None:
                spans.append((start, i + 1))
                start = None
            depth -= 1
    return spans


# ── smoke tests ───────────────────────────────────────────
def prepare(profile_name, new_text):
    """Materialise a run dir whose profiles differ in exactly one entry."""
    shutil.rmtree(RUN, ignore_errors=True)
    os.makedirs(os.path.join(RUN, "profiles"))
    for f in os.listdir(PROFILES):
        shutil.copy(os.path.join(PROFILES, f), os.path.join(RUN, "profiles", f))
    with open(os.path.join(RUN, "profiles", profile_name), "w") as fh:
        fh.write(new_text)
    link = os.path.join(RUN, "sandbox.sh")
    if not os.path.exists(link):
        os.symlink(os.path.join(ROOT, "sandbox.sh"), link)
    return link


def http_ok(url, timeout=1.5):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status == 200
    except Exception:
        return False


def chat_ok(url, model=None):
    import json

    body = {"messages": [{"role": "user", "content": "Say OK"}], "max_tokens": 8}
    if model:
        body["model"] = model
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return b"choices" in r.read()
    except Exception:
        return False


def stop(p):
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    except Exception:
        pass
    try:
        p.wait(timeout=10)
    except Exception:
        pass


def server_test(sandbox, args, ready_url, chat_url, model=None, needs_gpu=False, image=False):
    logpath = os.path.join(RUN, "server.log")
    log = open(logpath, "w")
    p = subprocess.Popen(
        [sandbox] + args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
    )
    try:
        deadline = time.time() + 75
        while time.time() < deadline:
            if p.poll() is not None:
                return False
            if http_ok(ready_url):
                if not chat_ok(chat_url, model):
                    return False
                if image and not image_ok(chat_url, model):
                    return False
                if needs_gpu:
                    # llama.cpp falls back to CPU when Metal is unavailable
                    # and still answers, so check it really used the GPU.
                    text = open(logpath, errors="replace").read()
                    return "assigned to device MTL0" in text
                return True
            time.sleep(1)
        return False
    finally:
        stop(p)


def t_llama(sandbox):
    return server_test(
        sandbox,
        ["llama-server", "--model", GGUF, "-lv", "6"],
        "http://127.0.0.1:%d/health" % PORT,
        "http://127.0.0.1:%d/v1/chat/completions" % PORT,
        needs_gpu=True,
    )


def t_mlx(sandbox):
    return server_test(
        sandbox,
        ["mlx-server", "--model", MLX],
        "http://127.0.0.1:%d/v1/models" % PORT,
        "http://127.0.0.1:%d/v1/chat/completions" % PORT,
        model=MLX,
    )


MMPROJ_DIR = os.path.expanduser("~/.sandboxed-ai-ablate-mmproj")


def mmproj_elsewhere():
    """A copy of the projector outside the model dir, so --mmproj really
    exercises MMPROJ_DIR instead of resolving inside MODEL_DIR."""
    models = os.path.expanduser("~/.local/state/sandboxed-ai/models")
    repo = os.path.join(models, VISION.split(":")[0])
    src = next(
        os.path.join(repo, f)
        for f in os.listdir(repo)
        if f.startswith("mmproj") and f.endswith(".gguf")
    )
    os.makedirs(MMPROJ_DIR, exist_ok=True)
    dst = os.path.join(MMPROJ_DIR, os.path.basename(src))
    if not os.path.exists(dst):
        shutil.copy(src, dst)
    return dst


IMAGE_B64 = None


def test_image():
    """A 64x64 PNG as base64: a red square on white."""
    global IMAGE_B64
    if IMAGE_B64 is None:
        import zlib, struct, base64
        W = H = 64
        rows = b""
        for y in range(H):
            rows += b"\x00" + b"".join(
                b"\xd0\x20\x20" if 16 <= x < 48 and 16 <= y < 48 else b"\xff\xff\xff"
                for x in range(W))

        def chunk(t, d):
            c = t + d
            return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

        png = (b"\x89PNG\r\n\x1a\n"
               + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))
        IMAGE_B64 = base64.b64encode(png).decode()
    return IMAGE_B64


def image_ok(url, model=None):
    """Ask about an image; true only if a non-empty answer comes back."""
    import json

    body = {"messages": [{"role": "user", "content": [
        {"type": "text", "text": "What color is the square?"},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64," + test_image()}}]}],
        "max_tokens": 20}
    if model:
        body["model"] = model
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            import json as _j
            return bool(_j.loads(r.read())["choices"][0]["message"]["content"].strip())
    except Exception:
        return False


def t_vision(sandbox):
    """A vision model whose projector sits in its own directory: exercises
    --mmproj and the MMPROJ_DIR grant, and decodes a real image."""
    return server_test(
        sandbox,
        ["llama-server", "--model", VISION, "--mmproj", mmproj_elsewhere(), "-lv", "6"],
        "http://127.0.0.1:%d/health" % PORT,
        "http://127.0.0.1:%d/v1/chat/completions" % PORT,
        needs_gpu=True,
        image=True,
    )


def t_shell(sandbox):
    """The agent running a shell command — pi's bash tool, which `pi -p`
    with a 135M model will not reliably trigger, so exercise it directly
    under the same profile."""
    ws = os.path.join(RUN, "ws")
    os.makedirs(ws, exist_ok=True)
    state = os.path.expanduser("~/.local/state/sandboxed-ai")
    os.makedirs(os.path.join(state, "tmp", "pi"), exist_ok=True)
    r = subprocess.run(
        [
            "/usr/bin/sandbox-exec",
            "-D", "COMMON_SB=%s/profiles/common.sb" % RUN,
            "-D", "CLIENT_SB=%s/profiles/client.sb" % RUN,
            "-D", "PKG_STORE=/nix",
            "-D", "HOME_DIR=%s" % os.path.expanduser("~"),
            "-D", "HOME_PARENT=%s" % os.path.dirname(os.path.expanduser("~")),
            "-D", "WORKSPACE=%s" % ws,
            "-D", "PI_DIR=%s/pi" % state,
            "-D", "PI_LLAMA_DIR=%s/pi" % state,
            "-D", "TMPDIR=%s/tmp/pi" % state,
            "-D", "TTY_DEV=/dev/null",
            "-D", "NET_ADDR=localhost:%d" % PORT,
            "-f", "%s/profiles/pi.sb" % RUN,
            "/bin/sh", "-c", "/usr/bin/env true && echo shell-ok",
        ],
        capture_output=True,
        timeout=60,
    )
    return b"shell-ok" in r.stdout


def t_llama_sock(sandbox):
    sock = os.path.expanduser("~/.ablate.sock")
    try:
        os.unlink(sock)
    except FileNotFoundError:
        pass
    log = open(os.path.join(RUN, "server.log"), "w")
    p = subprocess.Popen(
        [sandbox, "llama-server", "--model", GGUF, "--socket", sock],
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        import http.client, socket

        deadline = time.time() + 75
        while time.time() < deadline:
            if p.poll() is not None:
                return False
            if os.path.exists(sock):
                try:
                    s = socket.socket(socket.AF_UNIX)
                    s.settimeout(3)
                    s.connect(sock)
                    s.sendall(b"GET /health HTTP/1.0\r\n\r\n")
                    if b"200" in s.recv(200):
                        return True
                except Exception:
                    pass
            time.sleep(1)
        return False
    finally:
        stop(p)


def t_pi(sandbox):
    ws = os.path.join(RUN, "ws")
    os.makedirs(ws, exist_ok=True)
    try:
        r = subprocess.run(
            [sandbox, "pi", "-w", ws, "-p", "Say OK"],
            capture_output=True,
            timeout=180,
        )
        return r.returncode == 0 and bool(r.stdout.strip())
    except subprocess.TimeoutExpired:
        return False


def t_tui(sandbox):
    """Full TUI on a pty: raw mode, rendering, keystroke."""
    import pty, select

    ws = os.path.join(RUN, "tui")
    os.makedirs(ws, exist_ok=True)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        try:
            os.execv(sandbox, [sandbox, "pi", "-w", ws])
        finally:
            os._exit(127)
    out, deadline, sent = b"", time.time() + 30, False
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 1)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        if not sent and len(out) > 200:
            time.sleep(2)
            os.write(fd, b"hello\r")
            time.sleep(3)
            os.write(fd, b"\x03\x03")
            sent = True
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    os.close(fd)
    text = out.decode(errors="replace")
    ansi = len(re.findall(r"\x1b\[[0-9;?]*[a-zA-Z]", text))
    rawmode = bool(re.search(r"\x1b\[\?(1049|1006|25)", text))
    denied = "not permitted" in text or "EPERM" in text
    return ansi > 50 and rawmode and not denied


def t_llm(sandbox):
    try:
        r = subprocess.run([sandbox, "llm", "Say OK"], capture_output=True, timeout=180)
        return r.returncode == 0 and bool(r.stdout.strip())
    except subprocess.TimeoutExpired:
        return False


TESTS = {
    "llama": t_llama,
    "vision": t_vision,
    "shell": t_shell,
    "mlx": t_mlx,
    "llama_sock": t_llama_sock,
    "pi": t_pi,
    "tui": t_tui,
    "llm": t_llm,
}
# Client tests need a server; it runs from the pristine repo, so a variant
# never breaks the peer it is talking to.
NEEDS_SERVER = {"pi", "tui", "llm"}
# t_shell needs no peer server, but must not fight for the port either.


PRISTINE = [None]  # the peer server for client tests, from the unmodified repo


def ensure_pristine():
    if PRISTINE[0] is not None and PRISTINE[0].poll() is None:
        if http_ok("http://127.0.0.1:%d/health" % PORT):
            return True
        stop(PRISTINE[0])
    log = open(os.path.join(RUN, "pristine.log"), "w")
    PRISTINE[0] = subprocess.Popen(
        [os.path.join(ROOT, "sandbox.sh"), "llama-server", "--model", GGUF],
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    for _ in range(75):
        if http_ok("http://127.0.0.1:%d/health" % PORT):
            return True
        time.sleep(1)
    return False


def stop_pristine():
    if PRISTINE[0] is not None:
        stop(PRISTINE[0])
        PRISTINE[0] = None


def check(sandbox, tests):
    """Run the coverage set; server tests first (they need the port free)."""
    for t in [x for x in tests if x not in NEEDS_SERVER]:
        stop_pristine()
        if not TESTS[t](sandbox):
            return t
    client_tests = [x for x in tests if x in NEEDS_SERVER]
    if client_tests:
        if not ensure_pristine():
            return "peer server would not start"
        for t in client_tests:
            if not TESTS[t](sandbox):
                return t
    return None


def candidates(text):
    """Every removable entry, whole forms before their clauses."""
    out = []
    for s, e in top_forms(text):
        form = text[s:e]
        if not form.startswith("(allow"):
            continue
        out.append(("form", form))
        for cs, ce in clause_spans(form):
            clause = form[cs:ce]
            if clause.startswith("(require") or clause.startswith("(param"):
                continue
            out.append(("clause", clause))
    return out


def without(text, kind, snippet):
    """text minus snippet, or None if the removal is unsafe/ambiguous."""
    if text.count(snippet) != 1:
        return None  # appears twice: which one is meant is not obvious
    if kind == "form":
        i = text.index(snippet)
        # Take the whole line, so no blank line is left mid-continuation.
        start = text.rfind("\n", 0, i) + 1
        end = i + len(snippet)
        if text[end : end + 1] == "\n":
            end += 1
        return text[:start] + text[end:]
    # A clause: drop it and the whitespace that preceded it, then refuse if
    # its form would be left with no filter at all — that is an unfiltered
    # allow, i.e. a widening rather than an ablation.
    i = text.index(snippet)
    start = i
    while start > 0 and text[start - 1] in " \t":
        start -= 1
    if start > 0 and text[start - 1] == "\n":
        start -= 1
    trial = text[:start] + text[i + len(snippet) :]

    def bare_allows(t):
        return sum(
            1
            for a, b in top_forms(t)
            if t[a:b].startswith("(allow") and not clause_spans(t[a:b])
        )

    # Only reject if *this* removal created a new unfiltered allow; some
    # profiles legitimately contain clause-less ones, e.g. (allow
    # process-fork).
    if bare_allows(trial) > bare_allows(text):
        return None
    return trial


def main():
    names = sys.argv[1:] or sorted(COVERAGE)
    summary = []
    for name in names:
        tests = COVERAGE[name]
        original = open(os.path.join(PROFILES, name)).read()
        current = original
        cands = candidates(original)
        print("\n=== %s: %d candidate entries ===" % (name, len(cands)), flush=True)
        for kind, snippet in cands:
            if snippet not in current:
                continue  # already went with its enclosing form
            trial = without(current, kind, snippet)
            label = " ".join(snippet.split())[:70]
            if trial is None:
                print("  %-22s %s" % ("kept (unsafe to test)", label), flush=True)
                continue
            failed_on = check(prepare(name, trial), tests)
            if failed_on is None:
                # Cumulative: the next candidate is tested against a profile
                # that already lacks this one, so redundant alternatives
                # (several GPU user clients, say) collapse properly.
                current = trial
                print("  %-22s %s" % ("DROPPED", label), flush=True)
                summary.append((name, label))
            else:
                print("  %-22s %s" % ("needed (%s)" % failed_on, label), flush=True)
        os.makedirs(OUT, exist_ok=True)
        out = os.path.join(OUT, name)
        with open(out, "w") as fh:
            fh.write(current)
        print("  → minimized profile written to %s" % out, flush=True)
    stop_pristine()

    print("\n\n==== REMOVED ====")
    for name, label in summary:
        print("%-18s %s" % (name, label))
    print("\n(%d entries removed)" % len(summary))


if __name__ == "__main__":
    main()
