"""Compare SSD-streamed and resident GLM expert blocks using upstream's tiny fixture.

Runs with the real Metal kernels, file reader and prebuilt host-sync extension;
no mocks and no JIT compiler. The checkpoint is generated before sandboxing.
"""
import sys
from pathlib import Path

import mlx.core as mx
import numpy as np

import glm5_fakes
from tensorfold.families.glm5_next import stream, weights
from tensorfold.streaming import build
from tensorfold.streaming.pool import expert_nbytes, sources

assert mx.metal.is_available(), 'SSD test requires Metal'
mx.set_default_device(mx.gpu)
if sys.argv[1] == '--prepare':
    glm5_fakes.D = 512
    glm5_fakes.TEXT.update(hidden_size=512, moe_intermediate_size=512)
    glm5_fakes.write_checkpoint(Path(sys.argv[2]), seed=2)
    sys.exit(0)

# sandbox.sh supplies `serve MODEL ...`; this executable replaces only the
# TensorFold entry point, retaining every grant of the normal sandbox.
assert sys.argv[1] == 'serve', sys.argv
folder = Path(sys.argv[2])
module = build.load()
assert str(Path(module.__file__).resolve()).startswith('/nix/store/'), module.__file__
resident = weights.load_backbone(folder)
streamed = weights.load_backbone(folder, stream=True)
per = expert_nbytes(sources(folder, stream.expert_names(folder, 6))[0], 1)
streamer = stream.attach(streamed, folder, (2 * 8 + 4) * per / 2**30)
try:
    # Exercise both prompt-window and decode-LRU paths. Restrict this test
    # to expert blocks: whole GLM attention kernels require newer GPUs than
    # the M1 used for the sandbox's small-model tests.
    for rows in (40, 1, 1, 4, 16):
        x = mx.array(np.random.default_rng(rows).normal(0, 0.5, (rows, 512))).astype(mx.bfloat16)
        for layer in (1, 2):
            outputs = [model.layers[layer].mlp(x, rows <= 16) for model in (resident, streamed)]
            assert bool(mx.array_equal(*outputs).item()), f'streamed/resident mismatch at {rows} rows'
    assert streamer.misses > 0 and streamer.bytes_read > 0 and streamer.error is None
    print(f'ok   - TensorFold SSD streaming: resident parity, {streamer.bytes_read} bytes read, '
          f'{streamer.misses} misses; prebuilt extension loaded from Nix store', flush=True)
finally:
    streamer.close()
