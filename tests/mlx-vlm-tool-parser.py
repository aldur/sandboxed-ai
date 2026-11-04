"""Check template detection without loading a model or the MLX runtime."""

import runpy
import sys

infer = runpy.run_path(sys.argv[1])["_infer_tool_parser"]

for template, expected in (
    (None, None),
    ({"default": "<tool_call>"}, None),
    ("", None),
    ("{{ messages }}", None),
    ("<tool_call>", None),
    ("<tool_call> tool_call.name", "json_tools"),
    ("<tool_call>\\n<function=", "qwen3_coder"),
    ("<tool_call>\n<function=", "qwen3_coder"),
    ("<|tool_call>", "gemma4"),
    ("<|tool_call> <tool_call|>", "gemma4"),
    ("<minimax:tool_call>", "minimax_m2"),
    ("<|tool_call> <minimax:tool_call>", "minimax_m2"),
    ("<start_function_call>", "function_gemma"),
    ("<|tool_list_start|>", "pythonic"),
):
    actual = infer(template)
    assert actual == expected, (template, actual, expected)
