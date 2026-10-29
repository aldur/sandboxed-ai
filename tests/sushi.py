#!/usr/bin/env python3
"""Sushi wrapper and real seatbelt checks, without downloading large packs.

Run with a Nix/Homebrew Python. Set SUSHI to the patched Nix engine for
native HTTP/socket checks on macOS >= 26.2. No model weights are needed;
tests/e2e.sh handles opt-in model inference.
"""

import os
import json
from pathlib import Path
import platform
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent


class SushiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if platform.system() != "Darwin":
            raise unittest.SkipTest("macOS seatbelt required")
        cls.python = str(Path(sys.executable).resolve())
        cls.echo = str(Path(shutil.which("echo")).resolve())
        cls.bash = shutil.which("bash")
        for binary in (cls.python, cls.echo):
            if not binary.startswith(("/nix/", "/opt/homebrew/")):
                raise unittest.SkipTest("Nix/Homebrew Python and coreutils required")
        cls.work = tempfile.TemporaryDirectory(prefix=".sushi-tests-", dir=Path.home())
        cls.base = Path(cls.work.name).resolve()
        cls.model = cls.base / "local model"
        cls.draft = cls.base / "draft model"
        cls.cache = cls.base / "state/sandboxed-ai/cache/sushi"
        cls.logs = cls.base / "state/sandboxed-ai/logs"
        cls.other_cache = cls.base / "state/sandboxed-ai/cache/mtplx"
        for directory in (cls.model, cls.draft, cls.cache, cls.logs, cls.other_cache):
            directory.mkdir(parents=True)
        # With Python as the pinned native executable, `serve` is a script
        # in its permitted cwd. It records the argv/env that crossed the
        # real wrapper + seatbelt boundary, with no model load or mock of
        # sandbox-exec. --version is Python's own native option.
        (cls.cache / "serve").write_text(
            "import json, os, sys\n"
            "print(json.dumps({'argv': sys.argv[1:], 'environment': dict(os.environ)}))\n"
        )
        for directory in (cls.model, cls.draft):
            (directory / "config.json").write_text("{}")
        cls.secret = cls.base / "caller-secret"
        cls.secret.write_text("unreachable")
        # A checksum-verified cached repo must resolve offline, as for MLX.
        cls.models = cls.base / "models"
        cached = cls.models / "test/sushi"
        cached.mkdir(parents=True)
        (cached / "config.json").write_text("{}")
        (cached / ".download-complete").touch()
        cls.env = dict(os.environ, XDG_STATE_HOME=str(cls.base / "state"),
                       SANDBOXED_AI_MODELS=str(cls.models), SUSHI=cls.python)
        cls.env.pop("MODEL", None)
        cls.darwin_tmp = str(Path(subprocess.check_output(
            ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()).resolve())
        darwin_cache = Path(subprocess.check_output(
            ["/usr/bin/getconf", "DARWIN_USER_CACHE_DIR"], text=True).strip()).resolve()
        cls.metal_cache = str(darwin_cache / "com.apple.metal")
        cls.metalfe_cache = str(darwin_cache / "com.apple.metalfe")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            cls.port = listener.getsockname()[1]

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def wrapper(self, *args, env=None):
        return subprocess.run([self.bash, str(ROOT / "sandbox.sh"), *args],
                              cwd=ROOT, env=env or self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    def sandbox_command(self, executable, *args, **overrides):
        params = {
            "COMMON_SB": ROOT / "profiles/common.sb",
            "SERVER_SB": ROOT / "profiles/server.sb",
            "NET_SB": ROOT / "profiles/net-tcp.sb",
            "NET_TARGET": f"*:{self.port}",
            "NET_SELF_SB": ROOT / "profiles/net-self-tcp.sb",
            "NET_SELF": f"localhost:{self.port}",
            "PKG_STORE": "/nix" if self.python.startswith("/nix/") else "/opt/homebrew",
            "HOME_DIR": Path.home().resolve(),
            "HOME_PARENT": Path.home().resolve().parent,
            "STDOUT_PATH": "/dev/null", "STDERR_PATH": "/dev/null",
            "DARWIN_USER_TEMP_DIR": self.darwin_tmp,
            "DARWIN_METAL_CACHE": self.metal_cache,
            "DARWIN_METALFE_CACHE": self.metalfe_cache,
            "SUSHI": self.python, "MODEL_DIR": self.model, "DRAFTER_DIR": self.draft,
            "CACHE_DIR": self.cache, "TOOL_SB": ROOT / "profiles/sushi.sb",
            "LOG_DIR": self.logs,
        }
        params.update(overrides)
        command = ["/usr/bin/sandbox-exec"]
        for name, value in params.items():
            command += ["-D", f"{name}={value}"]
        command += ["-f", str(ROOT / "profiles/run.sb"), executable, *args]
        return command

    def probe(self, source, **overrides):
        command = self.sandbox_command(self.python, "-I", "-c", source, **overrides)
        return subprocess.run(command, cwd=self.cache, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)

    def test_local_model_and_passthrough(self):
        result = self.wrapper("sushi", "serve", "--model", str(self.model),
                              "--host=0.0.0.0", "--port=18088", "--ctx-size", "4096")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])["argv"],
                         ["--model", str(self.model), "--host", "0.0.0.0", "--port", "18088",
                          "--no-update-check", "--log-file", "off", "--ctx-size", "4096"])

    def test_model_env_and_flag_override(self):
        env = dict(self.env, MODEL=str(self.draft))
        result = self.wrapper("sushi", "--model=" + str(self.model), env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout.splitlines()[-1])["argv"]
        self.assertEqual(args[:6], ["--model", str(self.model), "--host", "127.0.0.1", "--port", "8080"])
        result = self.wrapper("sushi", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])["argv"][:2], ["--model", str(self.draft)])

    def test_cached_hf_model(self):
        result = self.wrapper("sushi", "--model", "test/sushi")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])["argv"][:2],
                         ["--model", str(self.models / "test/sushi")])

    def test_external_drafter(self):
        result = self.wrapper("sushi", "--model", str(self.model), "--drafter", str(self.draft))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])["argv"][-2:], ["--drafter", str(self.draft)])

    def test_help_and_version_without_model(self):
        for args in ((), ("--help",), ("--version",)):
            with self.subTest(args=args):
                result = self.wrapper("sushi", *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                if args == ("--version",):
                    self.assertIn("Python ", result.stdout)
                else:
                    self.assertEqual(json.loads(result.stdout)["argv"], ["--help"])

    def test_bad_options_fail_before_downloading(self):
        for args, message in (
            (("--port", "garbage"), "not a port number"),
            (("--port=0",), "between 1 and 65535"),
            (("--port=65536",), "between 1 and 65535"),
            (("--model",), "requires an argument"),
            (("--drafter=",), "requires an argument"),
            (("--ctx-size", "4096"), "no model specified"),
        ):
            with self.subTest(args=args):
                result = self.wrapper("sushi", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_socket_options_and_last_host_wins(self):
        default = self.base / "state/sandboxed-ai/sockets/sushi.sock"
        custom = self.base / "custom socket.sock"
        for options, host in ((("--socket",), default),
                              (("--host", str(custom)), custom),
                              (("--host=" + str(custom),), custom),
                              (("--socket", "--host=127.0.0.1"), "127.0.0.1"),
                              (("--host=0.0.0.0", "--socket"), default)):
            with self.subTest(options=options):
                result = self.wrapper("sushi", "--model", str(self.model), *options)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads(result.stdout.splitlines()[-1])["argv"]
                self.assertEqual(args[2:4], ["--host", str(host)])

    def test_socket_path_protects_live_sockets_and_regular_files(self):
        path = self.base / "protected.sock"
        path.write_text("keep")
        try:
            result = self.wrapper("sushi", "--model", str(self.model), "--host", str(path))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), "keep")
        finally:
            path.unlink()
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(path))
            listener.listen()
            result = self.wrapper("sushi", "--model", str(self.model), "--host", str(path))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already served", result.stderr)
            self.assertTrue(path.exists())
        # Once the listener closes, the wrapper can remove the stale socket.
        result = self.wrapper("sushi", "--model", str(self.model), "--host", str(path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(path.exists())

    def test_socket_paths_are_canonicalized(self):
        directory = self.base / "socket directory"
        directory.mkdir()
        alias = self.base / "socket alias"
        alias.symlink_to(directory, target_is_directory=True)
        for path in (str(alias / "custom.sock"),
                     os.path.relpath(directory / "custom.sock", ROOT)):
            result = self.wrapper("sushi", "--model", str(self.model), "--host", path)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads(result.stdout.splitlines()[-1])["argv"]
            self.assertEqual(args[2:4], ["--host", str(directory / "custom.sock")])

    def test_long_socket_path_fails_before_downloading(self):
        path = self.base / ("x" * 104 + ".sock")
        result = self.wrapper("sushi", "--model", "nonexistent/repo", "--host", str(path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exceeds 103 bytes", result.stderr)

    def test_unix_profile_has_no_tcp_grants(self):
        path = self.base / "profile.sock"
        params = dict(NET_SB=ROOT / "profiles/net-unix.sb", NET_TARGET=path,
                      NET_SELF_SB=ROOT / "profiles/net-none.sb")
        result = self.probe(f"import socket; s = socket.socket(socket.AF_UNIX); s.bind({str(path)!r}); s.listen()", **params)
        self.assertEqual(result.returncode, 0, result.stderr)
        path.unlink()
        result = self.probe(f"import socket; s = socket.socket(); s.bind(('127.0.0.1', {self.port}))", **params)
        self.assertNotEqual(result.returncode, 0)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", self.port))
            listener.listen()
            result = self.probe(f"import socket; socket.create_connection(('127.0.0.1', {self.port}))", **params)
            self.assertEqual(result.returncode, -9, result.stderr)
        other = self.base / "other.sock"
        result = self.probe(f"import socket; s = socket.socket(socket.AF_UNIX); s.bind({str(other)!r})", **params)
        self.assertNotEqual(result.returncode, 0)

    def test_real_engine_serves_http_over_unix_socket(self):
        binary = os.environ.get("SUSHI") or shutil.which("sushi")
        macos = tuple(map(int, platform.mac_ver()[0].split(".")[:2]))
        if not binary or macos < (26, 2):
            self.skipTest("patched Sushi binary and macOS >= 26.2 required")
        binary = str(Path(binary).resolve())
        home = self.cache / "sushi-home"
        models = home / ".sushi/models"
        models.mkdir(parents=True, exist_ok=True)
        path = self.base / "native.sock"
        command = self.sandbox_command(
            binary, "serve", "--model-dir", str(models), "--host", str(path),
            "--no-update-check", "--log-file", "off", "--api-key-env", "SUSHI_API_KEY",
            SUSHI=binary, NET_SB=ROOT / "profiles/net-unix.sb", NET_TARGET=path,
            NET_SELF_SB=ROOT / "profiles/net-none.sb")
        process = subprocess.Popen(command, cwd=self.cache,
                                   env=dict(PATH=os.environ["PATH"], HOME=str(home),
                                            SUSHI_NO_UPDATE_CHECK="1", SUSHI_API_KEY="test-key"),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def request(endpoint, timeout=5):
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(timeout)
                client.connect(str(path))
                client.sendall(f"GET {endpoint} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode())
                response = bytearray()
                while chunk := client.recv(65536):
                    response.extend(chunk)
            return response

        try:
            deadline = time.monotonic() + 20
            ready = False
            while process.poll() is None and time.monotonic() < deadline:
                # The startup probe creates a socket briefly. Wait for an
                # HTTP response, rather than treating that path as ready.
                try:
                    ready = b"HTTP/1.1 200" in request("/health", timeout=0.2)
                except OSError:
                    pass
                if ready:
                    break
                time.sleep(0.05)
            self.assertTrue(ready, "native UNIX listener did not become healthy")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            for endpoint in ("/health", "/v1/models", "/props"):
                response = request(endpoint)
                self.assertIn(b"HTTP/1.1 200", response, response.decode(errors="replace"))
                json.loads(response.split(b"\r\n\r\n", 1)[1])
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            try:
                stdout, stderr = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate()
            if process.returncode:
                print((stdout + stderr).decode(errors="replace"), file=sys.stderr)
            try:
                self.assertEqual(process.returncode, 0, (stdout + stderr).decode(errors="replace"))
                self.assertFalse(path.exists(), "native listener left a stale socket after shutdown")
            finally:
                path.unlink(missing_ok=True)

    def test_requested_api_key_uses_fixed_environment_name(self):
        result = self.wrapper("sushi", "--model", str(self.model), "--api-key-env", "TEST_KEY",
                              env=dict(self.env, TEST_KEY="private-key-canary"))
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(record["argv"][-2:], ["--api-key-env", "SUSHI_API_KEY"])
        self.assertEqual(record["environment"]["SUSHI_API_KEY"], "private-key-canary")
        self.assertNotIn("TEST_KEY", record["environment"])
        self.assertNotIn("private-key-canary", result.stderr)

    def test_environment_is_isolated_and_updates_are_disabled(self):
        env = dict(self.env, GITHUB_TOKEN="credential-canary", PYTHONPATH="/untrusted",
                   SUSHI_NO_UPDATE_CHECK="0", SUSHI_PREFIX_CACHE_DIR="/untrusted",
                   SUSHI_API_KEY="unrequested-key-canary")
        result = self.wrapper("sushi", "--model", str(self.model), env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout.splitlines()[-1])["environment"]
        self.assertEqual(record["HOME"], str(self.cache / "sushi-home"))
        self.assertEqual(record["SUSHI_NO_UPDATE_CHECK"], "1")
        for name in ("GITHUB_TOKEN", "PYTHONPATH", "SUSHI_PREFIX_CACHE_DIR", "SUSHI_API_KEY"):
            self.assertNotIn(name, record)

    def test_logging(self):
        result = self.wrapper("--log", "sushi", "--model", str(self.model))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(list(self.logs.glob("*sushi*")))

    def test_model_and_drafter_are_readable(self):
        source = f"from pathlib import Path; Path({str(self.model / 'config.json')!r}).read_text(); "
        source += f"Path({str(self.draft / 'config.json')!r}).read_text()"
        result = self.probe(source)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cache_is_writable(self):
        result = self.probe(f"open({str(self.cache / 'probe')!r}, 'w').write('ok')")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_models_other_caches_and_secrets_are_protected(self):
        for path, mode in ((self.model / "config.json", "w"),
                           (self.draft / "config.json", "w"),
                           (self.other_cache / "probe", "w"), (self.secret, "r")):
            with self.subTest(path=path):
                self.assertNotEqual(self.probe(f"open({str(path)!r}, {mode!r})").returncode, 0)

    def test_logs_stay_protected_under_overlapping_grants(self):
        for mode in ("r", "w"):
            path = self.logs / "protected"
            path.write_text("host log")
            result = self.probe(f"open({str(path)!r}, {mode!r})", MODEL_DIR=self.base)
            self.assertNotEqual(result.returncode, 0)

    def test_fork_and_unrelated_executable_are_denied(self):
        fork = "import os; pid = os.fork(); os._exit(0) if pid == 0 else os.waitpid(pid, 0)"
        self.assertNotEqual(self.probe(fork).returncode, 0)
        self.assertNotEqual(self.probe(f"import os; os.execv({self.echo!r}, [{self.echo!r}])").returncode, 0)

    def test_listen_and_self_connect_are_scoped_to_selected_port(self):
        result = self.probe(f"import socket; s = socket.socket(); s.bind(('127.0.0.1', {self.port})); s.listen()")
        self.assertEqual(result.returncode, 0, result.stderr)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", self.port))
            listener.listen()
            result = self.probe(f"import socket; socket.create_connection(('127.0.0.1', {self.port}))")
            self.assertEqual(result.returncode, 0, result.stderr)
        with socket.socket() as other:
            other.bind(("127.0.0.1", 0))
            other.listen()
            result = self.probe(f"import socket; socket.create_connection(('127.0.0.1', {other.getsockname()[1]}))")
            self.assertEqual(result.returncode, -9, result.stderr)
        result = self.probe("import socket; s = socket.socket(); s.bind(('127.0.0.1', 0))")
        self.assertNotEqual(result.returncode, 0)

    def test_real_engine_help_and_version(self):
        binary = os.environ.get("SUSHI") or shutil.which("sushi")
        macos = tuple(map(int, platform.mac_ver()[0].split(".")[:2]))
        if not binary or macos < (26, 2):
            self.skipTest("Sushi binary and macOS >= 26.2 required")
        for option, expected in (("--version", "sushi "), ("--help", "Usage: sushi")):
            result = self.wrapper("sushi", option, env=dict(self.env, SUSHI=binary))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
