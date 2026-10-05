#!/usr/bin/env python3
"""Offline tests for the upstream-to-Nix dependency updater."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("vllm_update", ROOT / "packages/vllm/update.py")
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


def item(name, requirements=(), version="1.0"):
    return {"metadata": {"name": name, "version": version, "requires_dist": list(requirements)}}


def report(*items):
    return {
        "version": "1",
        "environment": {"sys_platform": "darwin", "platform_machine": "arm64", "python_version": "3.12"},
        "install": [item("vllm-metal"), *items],
    }


class UpdateTests(unittest.TestCase):
    def test_transitive_extras_markers_and_self_references(self):
        resolved = report(
            item("vllm", ["server[standard]", "linux-only; sys_platform == 'linux'"]),
            item("server", ["server[base]; extra == 'standard'", "uvloop; extra == 'base'"]),
            item("uvloop"),
        )
        self.assertEqual(update.requirements(resolved), {
            "vllm": ["server"], "vllm-metal": [], "server": ["uvloop"], "uvloop": [],
        })

    def test_opencv_alias_still_checks_version(self):
        resolved = report(item("vllm", ["opencv-python>=4"]), item("opencv-python-headless", version="4.13"))
        self.assertEqual(update.requirements(resolved)["vllm"], ["opencv-python-headless"])
        resolved["install"][-1]["metadata"]["version"] = "3.0"
        with self.assertRaisesRegex(ValueError, "rejects"):
            update.requirements(resolved)

    def test_preserves_wheel_filename_and_content_hash(self):
        pin = update.source({
            **item("vllm"),
            "download_info": {"url": "https://example.org/vllm-1.0%2Bcpu-cp312-cp312-macosx_11_0_arm64.whl",
                              "archive_info": {"hashes": {"sha256": "00" * 32}}},
        })
        self.assertIn("1.0+cpu", pin["name"])
        self.assertEqual(pin["hash"], "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")

    def test_git_uses_resolved_commit(self):
        with patch.object(update, "run", return_value=json.dumps({"hash": "sha256-example"})) as run:
            pin = update.source({
                **item("mlx-lm"),
                "download_info": {"url": "https://github.com/ml-explore/mlx-lm",
                                  "vcs_info": {"vcs": "git", "commit_id": "a" * 40}},
            })
        self.assertEqual(pin["rev"], "a" * 40)
        self.assertEqual(run.call_args.args[-1], "a" * 40)

    def test_unknown_report_and_source_build_fail(self):
        with self.assertRaisesRegex(ValueError, "report version"):
            update.requirements({"version": "2"})
        with self.assertRaisesRegex(ValueError, "No wheel"):
            update.source({**item("new-dependency"), "download_info": {"url": "https://example.org/source.tar.gz"}})

    def test_checked_in_manifest_is_closed_and_pinned(self):
        pins = json.loads((ROOT / "packages/vllm/sources.json").read_text())
        for name, pin in pins.items():
            with self.subTest(package=name):
                self.assertNotIn(name, pin["dependencies"])
                self.assertLessEqual(set(pin["dependencies"]), set(pins))
                self.assertTrue(pin["source"]["hash"].startswith("sha256-"))
                self.assertTrue(pin["source"]["url"].startswith("https://"))
        self.assertNotIn("opencv-python", pins)

    def test_failed_resolution_does_not_replace_pins(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "packages/vllm"
            directory.mkdir(parents=True)
            (directory / "default.nix").touch()
            pins = directory / "sources.json"
            pins.write_text("original")
            release = {"tag_name": "v1.0.0", "assets": [{
                "name": "vllm_metal-1.0.0-cp312-cp312-macosx_15_0_arm64.whl",
                "browser_download_url": "https://example.org/plugin.whl",
            }]}
            with (patch.object(update, "ROOT", root),
                  patch.object(update.sys, "version_info", (3, 12)),
                  patch.object(update.platform, "system", return_value="Darwin"),
                  patch.object(update.platform, "machine", return_value="arm64"),
                  patch.object(update, "fetch", side_effect=[json.dumps(release).encode(), b"v2.0.0"]),
                  patch.object(update, "run", return_value="3.29.7"),
                  patch.object(update.subprocess, "run", side_effect=RuntimeError("resolution failed")) as resolve):
                with self.assertRaisesRegex(RuntimeError, "resolution failed"):
                    update.main()
            args = resolve.call_args.args[0]
            self.assertIn("--dry-run", args)
            self.assertIn("macosx_15_0_arm64", args)
            self.assertIn("/v2.0.0/vllm-2.0.0", args[-1])
            self.assertEqual(pins.read_text(), "original")


if __name__ == "__main__":
    unittest.main()
