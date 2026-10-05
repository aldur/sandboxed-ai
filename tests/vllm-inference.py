#!/usr/bin/env python3
"""Real vllm-metal smoke test: python3 tests/vllm-inference.py.

Requires a supported vLLM installation (PATH or VLLM). TEST_VLLM_MODEL
overrides the small default model; its first run downloads the weights.
"""

import http.client
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
MODEL = os.environ.get("TEST_VLLM_MODEL", "mlx-community/Qwen3-0.6B-4bit")


def exercise(endpoint, args, log):
    with log.open("w") as output:
        process = subprocess.Popen(
            [str(ROOT / "sandbox.sh"), "vllm", "--model", MODEL,
             "--served-model-name", "sandboxed-vllm-test", "--max-model-len", "512",
             "--max-num-seqs", "1", "--gpu-memory-utilization", "0.1", *args],
            stdout=output, stderr=subprocess.STDOUT, start_new_session=True,
        )

    def request(path, payload=None):
        connection = http.client.HTTPConnection("127.0.0.1", endpoint if isinstance(endpoint, int) else 80, timeout=60)
        if isinstance(endpoint, str):
            connection.sock = socket.socket(socket.AF_UNIX)
            connection.sock.settimeout(60)
            connection.sock.connect(endpoint)
        try:
            connection.request("POST" if payload else "GET", path,
                               json.dumps(payload) if payload else None,
                               {"Content-Type": "application/json"})
            response = connection.getresponse()
            body = response.read()
            assert response.status == 200, (response.status, body)
            return json.loads(body) if body else None
        finally:
            connection.close()

    try:
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            assert process.poll() is None, log.read_text()
            try:
                request("/health")
                break
            except (OSError, AssertionError, http.client.HTTPException):
                time.sleep(2)
        else:
            raise AssertionError("vLLM startup timed out\n" + log.read_text())
        models = request("/v1/models")
        assert any(model["id"] == "sandboxed-vllm-test" for model in models["data"]), models
        response = request("/v1/chat/completions", {
            "model": "sandboxed-vllm-test",
            "messages": [{"role": "user", "content": "Say OK"}], "max_tokens": 8,
        })
        assert response["choices"] and response["usage"]["completion_tokens"] > 0, response
        if isinstance(endpoint, str):
            assert os.stat(endpoint).st_mode & 0o077 == 0, "socket is not owner-only"
        print(f"vLLM {'TCP' if isinstance(endpoint, int) else 'UNIX socket'} inference passed", flush=True)
    finally:
        # Include engine and resource-tracker workers, even on startup failure.
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=15)
        except ProcessLookupError:
            pass
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise AssertionError("vLLM did not shut down within 15 seconds\n" + log.read_text())


def main():
    with tempfile.TemporaryDirectory(prefix=".vllm-inference-", dir=Path.home()) as temporary:
        work = Path(temporary).resolve()
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        exercise(port, ["--port", str(port)], work / "tcp.log")
        endpoint = str(work / "vllm.sock")
        exercise(endpoint, ["--host", endpoint], work / "unix.log")


if __name__ == "__main__":
    main()
