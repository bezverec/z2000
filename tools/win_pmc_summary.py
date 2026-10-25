"""Summarizes the traces tools/win_pmc_record.ps1 wrote, per decoder and case.

    python tools/win_pmc_summary.py C:\\temp\\pmc [runs]

Each Pmc event in an xperf dump carries one processor's cumulative counters
at a context switch and precedes its CSwitch event (same timestamp, same
incoming thread); the difference to that processor's previous switch belongs
to the outgoing thread. The counts of the decoder processes are summed and
divided by the number of runs per trace. Also prints the share of cycles
spent outside the requested mask's processors, which shows a decoder that
escapes its affinity.
"""
import os
import subprocess
import sys

XPERF = r'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe'
TARGETS = ('z2000.exe', 'kdu_expand.exe')
CASES = [('P1', 0x1), ('E1', 0x10000), ('P6', 0x555), ('P12HT', 0xFFF), ('E8', 0xFF000)]


def dump(etl):
    csv = etl[:-4] + '.csv'
    if not os.path.exists(csv) or os.path.getmtime(csv) < os.path.getmtime(etl):
        subprocess.run([XPERF, '-i', etl, '-o', csv], check=True, stdout=subprocess.DEVNULL)
    return csv


def process_name(field):
    return field.strip().rsplit(' (', 1)[0].strip()


def summarize(csv, mask):
    last = {}
    totals = [0, 0, 0, 0]
    outside_cycles = 0
    pending = None
    with open(csv, encoding='utf-8', errors='replace') as f:
        for line in f:
            kind, _, rest = line.partition(',')
            kind = kind.strip()
            if kind == 'Pmc':
                fields = [x.strip() for x in rest.split(',')]
                if fields[0] == 'TimeStamp':
                    continue
                pending = (int(fields[1]), [int(x) for x in fields[2:6]])
            elif kind == 'CSwitch':
                fields = rest.split(',')
                if fields[0].strip() == 'TimeStamp':
                    continue
                # TimeStamp, new process, new TID, ..., old process at 7, CPU at 15.
                if pending is None or pending[0] != int(fields[2]):
                    pending = None
                    continue
                values = pending[1]
                pending = None
                cpu = int(fields[15])
                previous = last.get(cpu)
                last[cpu] = values
                if previous is None or process_name(fields[7]) not in TARGETS:
                    continue
                delta = [v - p for v, p in zip(values, previous)]
                if min(delta) < 0:
                    continue
                for i in range(4):
                    totals[i] += delta[i]
                if not (mask >> cpu) & 1:
                    outside_cycles += delta[1]
    return totals, outside_cycles


def main():
    directory = sys.argv[1]
    runs = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    print('%-6s %-7s %8s %8s %5s %9s %8s %8s' % (
        'case', 'decoder', 'Ginstr', 'Gcycles', 'IPC', 'mispr/ki', 'LLCm/ki', 'outside'))
    for case, mask in CASES:
        for decoder in ('z2000', 'kakadu'):
            etl = os.path.join(directory, '%s-%s.etl' % (decoder, case))
            if not os.path.exists(etl):
                continue
            (instructions, cycles, mispredictions, llc), outside = summarize(dump(etl), mask)
            if not instructions or not cycles:
                print('%-6s %-7s no counters' % (case, decoder))
                continue
            print('%-6s %-7s %8.3f %8.3f %5.2f %9.2f %8.3f %7.1f%%' % (
                case, decoder, instructions / runs / 1e9, cycles / runs / 1e9,
                instructions / cycles, mispredictions * 1000 / instructions,
                llc * 1000 / instructions, outside * 100 / cycles))


if __name__ == '__main__':
    main()
