#!/usr/bin/env python3
"""Regenerate sources.json from upstream releases: nix run .#update-vllm.

pip only resolves metadata here; Nix builds and installs the runtime.
"""

import base64
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlparse
from urllib.request import Request, urlopen

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name


ROOT = Path.cwd()
UPSTREAM = "https://raw.githubusercontent.com/vllm-project/vllm-metal"


def fetch(url):
    headers = {"User-Agent": "sandboxed-ai-vllm-update"}
    if url.startswith("https://api.github.com/") and os.environ.get("GH_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GH_TOKEN']}"
    with urlopen(Request(url, headers=headers), timeout=60) as response:
        return response.read()


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def sri(digest):
    return "sha256-" + base64.b64encode(bytes.fromhex(digest)).decode()


def package_name(name):
    name = canonicalize_name(name)
    # Both distributions contain cv2; vLLM already requires the headless one.
    return "opencv-python-headless" if name == "opencv-python" else name


def requirements(report):
    """Follow platform markers and requested extras, including transitive extras."""
    if report["version"] != "1":
        raise ValueError("Unsupported pip report version")
    items = {canonicalize_name(p["metadata"]["name"]): p for p in report["install"]}
    dependencies = {name: set() for name in items}
    pending = [(name, "") for name in ("vllm", "vllm-metal")]
    seen = set()
    while pending:
        name, extra = pending.pop()
        if (name, extra) in seen:
            continue
        seen.add((name, extra))
        for raw in items[name]["metadata"].get("requires_dist") or []:
            requirement = Requirement(raw)
            if requirement.marker and not requirement.marker.evaluate(
                {**report["environment"], "extra": extra}
            ):
                continue
            dependency = package_name(requirement.name)
            candidate = items[dependency]["metadata"]["version"]
            if requirement.specifier and candidate not in requirement.specifier:
                raise ValueError(f"{name}: {requirement} rejects {candidate}")
            if dependency != name:
                dependencies[name].add(dependency)
            pending.append((dependency, ""))
            pending.extend((dependency, requested) for requested in requirement.extras)
    return {name: sorted(dependencies[name]) for name, _ in seen}


def manifest(report, source):
    dependencies = requirements(report)
    return {
        canonicalize_name(item["metadata"]["name"]): {
            "version": item["metadata"]["version"],
            "source": source(item),
            "dependencies": dependencies[canonicalize_name(item["metadata"]["name"])],
        }
        for item in report["install"]
        if canonicalize_name(item["metadata"]["name"]) in dependencies
    }


def source(item):
    name = canonicalize_name(item["metadata"]["name"])
    info = item["download_info"]
    if "vcs_info" in info:
        vcs = info["vcs_info"]
        if name != "mlx-lm" or vcs["vcs"] != "git":
            raise ValueError(f"Add a Nix source build for {name} before updating")
        rev = vcs["commit_id"]
        pin = json.loads(run("nix-prefetch-git", "--fetch-submodules", "--url", info["url"], "--rev", rev))
        return {"url": info["url"], "rev": rev, "hash": pin["hash"]}
    filename = unquote(Path(urlparse(info["url"]).path).name)
    if not filename.endswith(".whl"):
        raise ValueError(f"No wheel for {name}: add an explicit Nix source build")
    return {
        "url": info["url"],
        "hash": sri(info["archive_info"]["hashes"]["sha256"]),
        "name": filename,
    }


def main():
    if not (ROOT / "packages/vllm/default.nix").is_file():
        raise SystemExit("Run the updater from the repository root")
    if sys.version_info[:2] != (3, 12) or platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Run nix run .#update-vllm on an Apple Silicon Mac")
    release = json.loads(fetch("https://api.github.com/repos/vllm-project/vllm-metal/releases/latest"))
    tag = release["tag_name"]
    core_tag = fetch(f"{UPSTREAM}/{tag}/.github/vllm-release-tag.commit").decode().strip()
    if not all(re.fullmatch(r"v\d+\.\d+\.\d+(?:\.post\d+)?", value) for value in (tag, core_tag)):
        raise ValueError(f"Unexpected stable release tags: {tag}, {core_tag}")
    wheels = [asset["browser_download_url"] for asset in release["assets"]
              if asset["name"].endswith("-cp312-cp312-macosx_15_0_arm64.whl")]
    if len(wheels) != 1:
        raise ValueError("Expected one Python 3.12/macOS 15 Metal wheel; review platform support")
    wheels.append(f"https://github.com/vllm-project/vllm/releases/download/{core_tag}/"
                  f"vllm-{core_tag[1:]}%2Bcpu-cp312-cp312-macosx_11_0_arm64.whl")
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        # Follow the flake's filelock, which avoids the import-time hardlink probe.
        version = run("nix", "eval", "--raw", ".#update-vllm.filelockVersion")
        constraints = directory / "constraints.txt"
        constraints.write_text(f"filelock=={version}\n")
        report_path = directory / "report.json"
        subprocess.run([
            sys.executable, "-m", "pip", "--isolated", "install", "--dry-run", "--ignore-installed",
            "--platform", "macosx_15_0_arm64", "--only-binary=:all:",
            "--report", str(report_path), "--constraint", str(constraints), *wheels,
        ], check=True, cwd=directory)
        pins = manifest(json.loads(report_path.read_text()), source)
    # Write only after resolution and source hashing have both succeeded.
    (ROOT / "packages/vllm/sources.json").write_text(json.dumps(pins, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
