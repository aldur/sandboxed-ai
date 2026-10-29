"""Check that filelock imports without a temporary directory or a hard link."""

import importlib
import sys


def deny_probe(event, _args):
    if event in ("tempfile.mkdtemp", "os.link"):
        raise RuntimeError(f"filelock import attempted {event}")


sys.addaudithook(deny_probe)
importlib.import_module("filelock")
