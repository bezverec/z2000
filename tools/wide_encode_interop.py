"""Interop sweep for the wide native encoder (`z2000 zraw-to-j2k`).

For each precision it writes signed and unsigned ZRAW inputs with one and three
components, encodes them with z2000, decodes the codestream with z2000,
Kakadu, OpenJPEG, and Grok, and compares every sample with the input.

Usage: python -I tools/wide_encode_interop.py <workdir> <precision,...> [encoder flags...]
Tool paths default to this machine's installs and can be overridden with the
Z2000_BIN, KDU_EXPAND, OPJ_DECOMPRESS, and GRK_DECOMPRESS environment variables.
"""
import os, random, struct, subprocess, sys

Z = os.path.abspath(os.environ.get('Z2000_BIN', os.path.join('zig-out', 'bin', 'z2000.exe')))
KDU = os.environ.get('KDU_EXPAND', r'C:/Program Files/Kakadu/Kakadu Demo-Apps/kdu_expand.exe')
OPJ = os.environ.get('OPJ_DECOMPRESS', r'C:/tools/openjpeg-v2.5.4-windows-x64/bin/opj_decompress.exe')
GRK = os.environ.get('GRK_DECOMPRESS', r'C:/tools/grok-windows-20.4.12/bin/grk_decompress.exe')


def bytes_per_sample(precision):
    return 1 if precision <= 8 else 2 if precision <= 16 else 4 if precision <= 32 else 8


def write_zraw(path, width, height, components):
    out = bytearray(b'Z2KRAW1\n')
    out += struct.pack('>IIIIHH', 0, 0, width, height, len(components), 1)
    for precision, signed, _ in components:
        out += struct.pack('>BBBBIIIIHHQ', precision, int(signed), 1, 1, 0, 0, width, height, 0, 0, width * height)
    for precision, signed, samples in components:
        n = bytes_per_sample(precision)
        for value in samples:
            out += (value & ((1 << (8 * n)) - 1)).to_bytes(n, 'big')
    open(path, 'wb').write(out)


def read_zraw(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'Z2KRAW1\n'
    x0, y0, x1, y1, count, flags = struct.unpack('>IIIIHH', data[8:28])
    record = 32 if flags & 1 else 28
    layouts = []
    for c in range(count):
        rec = data[28 + c * record:28 + (c + 1) * record]
        precision, signed = rec[0], rec[1]
        n_samples = struct.unpack('>Q', rec[-8:])[0]
        layouts.append((precision, signed, n_samples))
    pos = 28 + count * record
    planes = []
    for precision, signed, n_samples in layouts:
        n = bytes_per_sample(precision)
        vals = []
        for i in range(n_samples):
            raw = int.from_bytes(data[pos + i * n:pos + (i + 1) * n], 'big')
            if signed and raw >> (8 * n - 1):
                raw -= 1 << (8 * n)
            vals.append(raw)
        pos += n_samples * n
        planes.append(vals)
    return planes


def read_pgx(path):
    data = open(path, 'rb').read()
    nl = data.index(b'\n')
    header = data[:nl].decode().replace('+', ' + ').replace('-', ' - ').split()
    if header[2] not in '+-':
        header.insert(2, '+')
    endian, signed, depth = header[1], header[2] == '-', int(header[3])
    width, height = int(header[4]), int(header[5])
    n = 1 if depth <= 8 else 2 if depth <= 16 else 4
    vals = []
    body = data[nl + 1:]
    for i in range(width * height):
        raw = int.from_bytes(body[i * n:(i + 1) * n], 'big' if endian == 'ML' else 'little') & ((1 << depth) - 1)
        if signed and raw >> (depth - 1):
            raw -= 1 << depth
        vals.append(raw)
    return vals


def run(args):
    return subprocess.run(args, capture_output=True, text=True)


def main():
    workdir = sys.argv[1]
    precisions = [int(p) for p in sys.argv[2].split(',')]
    extra = sys.argv[3:]
    os.makedirs(workdir, exist_ok=True)
    rng = random.Random(2000)
    width, height = 37, 23
    for precision in precisions:
        for signed in (False, True):
            for count in (1, 3):
                name = os.path.join(workdir, 'w%d%s%d' % (precision, 's' if signed else 'u', count))
                comps = []
                for c in range(count):
                    lo, hi = (-(1 << (precision - 1)), (1 << (precision - 1)) - 1) if signed else (0, (1 << precision) - 1)
                    # smooth ramp plus noise, with both extremes present
                    samples = []
                    for y in range(height):
                        for x in range(width):
                            base = lo + ((x * 7 + y * 13 + c * 5) * (hi - lo)) // (width * 7 + height * 13 + 15)
                            noise = rng.randint(-(1 << max(0, precision - 3)), 1 << max(0, precision - 3))
                            samples.append(min(hi, max(lo, base + noise)))
                    samples[0], samples[1] = lo, hi
                    comps.append((precision, signed, samples))
                write_zraw(name + '.zraw', width, height, comps)
                enc = run([Z, 'zraw-to-j2k', name + '.zraw', name + '.j2k'] + extra)
                if enc.returncode != 0:
                    print('%-28s ENCODE FAIL %s' % (os.path.basename(name), enc.stderr.strip().splitlines()[0] if enc.stderr else ''))
                    continue
                results = []
                # z2000
                dz = run([Z, 'j2k-to-zraw', name + '.j2k', name + '-z.zraw'])
                ok = dz.returncode == 0 and read_zraw(name + '-z.zraw') == [s for _, _, s in comps]
                results.append('z2000 ' + ('exact' if ok else 'FAIL'))
                # Kakadu
                outs = ','.join('%s-k%d.pgx' % (name, c) for c in range(count))
                dk = run([KDU, '-i', name + '.j2k', '-o', outs, '-num_threads', '0', '-quiet'])
                if dk.returncode == 0:
                    ok = all(read_pgx('%s-k%d.pgx' % (name, c)) == comps[c][2] for c in range(count))
                    results.append('kakadu ' + ('exact' if ok else 'DIFF'))
                else:
                    results.append('kakadu error')
                # OpenJPEG
                do = run([OPJ, '-i', name + '.j2k', '-o', name + '-o.pgx'])
                if do.returncode == 0:
                    files = [name + '-o.pgx'] if count == 1 and os.path.exists(name + '-o.pgx') else ['%s-o_%d.pgx' % (name, c) for c in range(count)]
                    try:
                        ok = all(read_pgx(files[c]) == comps[c][2] for c in range(count))
                        results.append('openjpeg ' + ('exact' if ok else 'DIFF'))
                    except FileNotFoundError:
                        results.append('openjpeg nofile')
                else:
                    results.append('openjpeg error')
                # Grok
                dg = run([GRK, '-i', name + '.j2k', '-o', name + '-g.pgx'])
                if dg.returncode == 0:
                    files = [name + '-g.pgx'] if count == 1 and os.path.exists(name + '-g.pgx') else ['%s-g_%d.pgx' % (name, c) for c in range(count)]
                    try:
                        ok = all(read_pgx(files[c]) == comps[c][2] for c in range(count))
                        results.append('grok ' + ('exact' if ok else 'DIFF'))
                    except FileNotFoundError:
                        results.append('grok nofile')
                else:
                    results.append('grok error')
                print('%-28s %s' % (os.path.basename(name), ' | '.join(results)))


main()
