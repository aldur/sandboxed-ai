#!/usr/bin/env python3
"""Run one fixed workload against a running mtplx server.

Save every capability-shaped observable to OUTDIR:
  health.json, props.json, metrics.json,
  chat-short.json, chat-long-1.json, chat-long-2.json
Usage: mtplx-workload.py PORT OUTDIR
"""
import json
import sys
import urllib.request

port, outdir = sys.argv[1], sys.argv[2]
base = f"http://127.0.0.1:{port}"


def get(path, out):
    with urllib.request.urlopen(base + path, timeout=30) as r:
        data = json.load(r)
    with open(f"{outdir}/{out}", "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    return data


def chat(msgs, out, timeout=900):
    req = urllib.request.Request(
        base + "/v1/chat/completions",
        data=json.dumps({"messages": msgs, "max_tokens": 20}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.load(r)
    with open(f"{outdir}/{out}", "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    return data


get("/health", "health.json")
get("/props", "props.json")
chat([{"role": "user", "content": "Say OK."}], "chat-short.json")

filler = "The quick brown fox jumps over the lazy dog. " * 800
first = [{"role": "user", "content": filler + "\nSay READY."}]
grown = first + [
    {"role": "assistant", "content": "READY."},
    {"role": "user", "content": "Now say OK."},
]
chat(first, "chat-long-1.json")
chat(grown, "chat-long-2.json")
get("/metrics", "metrics.json")
print("workload done")
