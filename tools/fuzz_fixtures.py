"""Mutate every committed codestream fixture and check that the CLI decoders
fail closed: an error return is fine, a panic, crash, or hang is a finding.

Usage (from the repository root, after `zig build`):

    python tools/fuzz_fixtures.py [seed] [mutations-per-file] [exe]

Mutations are single- and multi-bit flips, truncation, zeroed runs, and byte
insertion, applied anywhere in the file. JP2 files go through
`decode-temp-jp2`, raw codestreams through `j2k-to-zraw`. Mutants that panic,
exit with a code other than 0 or 1, or run past the timeout are kept under
`zig-out/fuzz/` and listed at the end. A Debug build is the better target: it
turns the undefined behaviour a release build would hide into a panic.

The first campaign (seed 1, 20 mutations per file, 102 fixtures, 2039 runs)
found one hang, a SIZ with a 2^31-wide image over 16x16 tiles that walked a
2^53-tile grid; the tile grid now refuses more than 65535 tiles (ISO A.4.2).
"""
import glob
import hashlib
import os
import random
import subprocess
import sys

seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
per_file = int(sys.argv[2]) if len(sys.argv) > 2 else 20
exe = sys.argv[3] if len(sys.argv) > 3 else os.path.join("zig-out", "bin", "z2000.exe")
out_dir = os.path.join("zig-out", "fuzz")
os.makedirs(out_dir, exist_ok=True)
random.seed(seed)

files = sorted(
    glob.glob(os.path.join("src", "testdata", "*.jp2"))
    + glob.glob(os.path.join("src", "testdata", "*.j2c"))
    + glob.glob(os.path.join("src", "testdata", "*.j2k"))
)


def mutate(data):
    m = bytearray(data)
    kind = random.choice(["flip", "flip", "flip", "truncate", "zero", "insert"])
    if kind == "flip":
        for _ in range(random.choice([1, 1, 2, 4, 8])):
            i = random.randrange(len(m))
            m[i] ^= 1 << random.randrange(8)
    elif kind == "truncate":
        m = m[: random.randrange(16, len(m))]
    elif kind == "zero":
        i = random.randrange(len(m))
        n = random.randrange(1, 32)
        m[i : i + n] = b"\0" * len(m[i : i + n])
    else:
        i = random.randrange(len(m))
        m[i:i] = bytes(random.randrange(256) for _ in range(random.randrange(1, 8)))
    return kind, bytes(m)


findings = []
runs = 0
for path in files:
    data = open(path, "rb").read()
    if len(data) < 64 or len(data) > 200_000:
        continue
    is_jp2 = path.endswith(".jp2")
    for _ in range(per_file):
        kind, m = mutate(data)
        mutant = os.path.join(out_dir, "mutant.bin")
        open(mutant, "wb").write(m)
        if is_jp2:
            cmd = [exe, "decode-temp-jp2", mutant, os.path.join(out_dir, "out.tif")]
        else:
            cmd = [exe, "j2k-to-zraw", mutant, os.path.join(out_dir, "out.zraw")]
        tag = hashlib.sha1(m).hexdigest()[:10]
        ext = ".jp2" if is_jp2 else ".j2c"
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=60)
        except subprocess.TimeoutExpired:
            keep = os.path.join(out_dir, f"hang-{tag}{ext}")
            open(keep, "wb").write(m)
            findings.append((os.path.basename(path), kind, keep, "TIMEOUT"))
            print("HANG", os.path.basename(path), kind, keep, flush=True)
            continue
        runs += 1
        err = r.stderr.decode("utf-8", "replace")
        if "panic" in err or "Segmentation" in err or r.returncode not in (0, 1):
            keep = os.path.join(out_dir, f"crash-{tag}{ext}")
            open(keep, "wb").write(m)
            lines = err.strip().splitlines()
            msg = next((l for l in lines if "panic" in l), lines[0] if lines else f"rc={r.returncode}")
            findings.append((os.path.basename(path), kind, keep, msg[:160]))
            print("CRASH", os.path.basename(path), kind, keep, msg[:160], flush=True)

print(f"done seed={seed} runs={runs} files={len(files)} findings={len(findings)}")
for f in findings:
    print(" ", *f)
sys.exit(1 if findings else 0)
