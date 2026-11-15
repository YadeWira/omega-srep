#!/usr/bin/env python3
"""OSREP scoreboard: preprocessors alone and preprocessor + backend pipelines.

Every command is timed with wall clock and os.wait4() (peak RSS and CPU time
of the child). One heavy process at a time; before each step the harness
waits until MemAvailable is above --min-avail-gb. Results go to a TSV that
is appended row by row, so an interrupted run resumes where it stopped.

The harness itself does not cage anything: run it inside the memory cage,
e.g.

  systemd-run --user --scope --quiet --slice=osrep-review.slice \\
    -p MemoryMax=6G -p MemorySwapMax=0 -p OOMPolicy=continue -- \\
    nice python3 tools/scoreboard/scoreboard.py --work W --corpus C --tsv out.tsv

Columns (one row per corpus x preprocessor x backend; backend "none" is the
preprocessor alone, preprocessor "none" is the backend alone):

  corpus in_bytes pre backend
  pre_bytes pre_enc_s pre_enc_cpu_s pre_enc_rss_mb pre_dec_s pre_dec_rss_mb pre_rt
  be_bytes be_enc_s be_enc_cpu_s be_enc_rss_mb be_dec_s be_dec_rss_mb be_rt
  final_bytes total_enc_s total_dec_s pre_reps be_reps

Times are the median of the repetitions (pre_reps / be_reps); RSS is the
maximum over them. *_rt is "ok" when the decoded bytes equal the input.
"""
import argparse
import os
import shutil
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------
# Binaries (override with environment variables)

BIN = {
    'osrep': os.environ.get('OSREP', '/mnt/IA_LAB/agentes/osrep/score/build/bin/osrep'),
    'srep': os.environ.get('SREP', '/home/forum/git/srep/bin/srep'),
    'omega': os.environ.get('OMEGA', '/mnt/IA_LAB/agentes/osrep/r240/release-3.0.0/osrep-linux-x86_64'),
    'fa': os.environ.get('FA', '/mnt/IA_LAB/agentes/osrep/score/fa/linux/fa'),
    'zpaq': os.environ.get('ZPAQ', '/mnt/IA_LAB/agentes/osrep/zpaqclean/baseline/zpaq-std'),
    'xz': os.environ.get('XZ', shutil.which('xz') or 'xz'),
    'zstd': os.environ.get('ZSTD', shutil.which('zstd') or 'zstd'),
}

# --------------------------------------------------------------------------
# Preprocessors. Placeholders: {IN} input file name (hard link in the work
# dir), {OUT} encoded file, {DEC} decoded file, {DECDIR} extraction dir.
# 'decoded' is where the decoded copy ends up. 'stdout' redirects the
# command's stdout to OUT (encode) / DEC (decode).

def osrep(*args):
    return {'enc': [BIN['osrep'], *args, '{IN}', '{OUT}'],
            'dec': [BIN['osrep'], '-d', '{OUT}', '{DEC}'],
            'decoded': '{DEC}'}


def srep(*args):
    return {'enc': [BIN['srep'], *args, '{IN}', '{OUT}'],
            'dec': [BIN['srep'], '-d', '{OUT}', '{DEC}'],
            'decoded': '{DEC}'}


def omega(*args):
    return {'enc': [BIN['omega'], *args, '{IN}', '{OUT}'],
            'dec': [BIN['omega'], '-d', '{OUT}', '{DEC}'],
            'decoded': '{DEC}'}


def fa_rep(method):
    # FreeArc'Next 0.11 with only the REP filter: "-mrep:<dict>". The .fa
    # container adds ~175 bytes (header + directory) to the REP stream.
    return {'enc': [BIN['fa'], 'a', '{OUT}', '-m' + method, '{IN}'],
            'dec': [BIN['fa'], 'x', '{OUT}', '-dp{DECDIR}'],
            'decoded': '{DECDIR}/{IN}'}


def zpaq_pre(level):
    # zpaq-std used as a preprocessor: -m0 = its deduplicator, stored
    # fragments (the archive is what a backend would see).
    return {'enc': [BIN['zpaq'], 'a', '{OUT}', '{IN}', level, '-threads', '1',
                    '-noeta', '-summary'],
            'dec': [BIN['zpaq'], 'x', '{OUT}', '-to', '{DECDIR}', '-threads', '1',
                    '-noeta', '-summary'],
            'decoded': '{DECDIR}/{IN}'}


PRE = {
    'none': None,
    'osrep-m1': osrep('-m1'),           # dedup only (fixed-window CDC), body stored
    'osrep-m2': osrep('-m2'),           # dedup only (order-1 CDC), body stored
    'osrep-m3': osrep('-m3'),
    'osrep-m5': osrep('-m5'),
    'osrep-dup-m5': osrep('-dup', '-m5'),
    'osrep-dup-m5-l32': osrep('-dup', '-m5', '-l32'),
    'osrep-dup-m5-l128': osrep('-dup', '-m5', '-l128'),
    # experiment: the whole file (up to 256 MiB) in one LZ block, to measure
    # how much the 8 MiB block-local search costs on multi-version data
    'osrep-m5-l128-b256': osrep('-m5', '-l128', '-b256mb', '-t1'),
    'osrep-m5-l512-b256': osrep('-m5', '-l512', '-b256mb', '-t1'),
    # long-range method (global index, records across blocks): -m6 -l<L>
    'osrep-m6-l512': osrep('-m6', '-l512'),
    'osrep-m6-l256': osrep('-m6', '-l256'),
    'osrep-m6-l128': osrep('-m6', '-l128'),
    'osrep-m6-l64': osrep('-m6', '-l64'),
    'osrep-m6-l32': osrep('-m6', '-l32'),
    'srep-m3f': srep('-m3f'),
    'srep-m5f': srep('-m5f'),
    'srep-m5f-l32': srep('-m5f', '-l32'),
    'omega-m3': omega('-m3'),
    'omega-m5': omega('-m5'),
    'rep-64mb': fa_rep('rep'),          # FA's "rep" default = 64 MB dictionary
    'rep-1gb': fa_rep('rep:1gb'),
    'zpaq-m0': zpaq_pre('-m0'),
}

# --------------------------------------------------------------------------
# Backends. {IN} is the preprocessed file, {OUT} the compressed one.

def zpaq_be(level, threads):
    return {'enc': [BIN['zpaq'], 'a', '{OUT}', '{IN}', level, '-threads', threads,
                    '-noeta', '-summary'],
            'dec': [BIN['zpaq'], 'x', '{OUT}', '-to', '{DECDIR}', '-threads', threads,
                    '-noeta', '-summary'],
            'decoded': '{DECDIR}/{IN}'}


def backend(name, big):
    if name == 'xz':
        return {'enc': [BIN['xz'], '-9', '-T1', '-c', '{IN}'], 'stdout': True,
                'dec': [BIN['xz'], '-d', '-T1', '-c', '{OUT}'], 'decoded': '{DEC}'}
    if name == 'zstd':
        return {'enc': [BIN['zstd'], '-19', '--long=27', '-T1', '-q', '-c', '{IN}'],
                'stdout': True,
                'dec': [BIN['zstd'], '-d', '--long=27', '-q', '-c', '{OUT}'],
                'decoded': '{DEC}'}
    if name == 'zpaq-m1':
        return zpaq_be('-m1', '1')
    if name == 'zpaq-m5':
        # single thread up to 128 MiB; 4 threads above (same archive bytes,
        # the CPU column keeps the comparable cost)
        return zpaq_be('-m5', '4' if big else '1')
    raise SystemExit('unknown backend ' + name)


# Which backends each preprocessor feeds by default. zpaq-m5 is expensive
# (~0.4-0.5 MB/s per thread), so it only runs on the backend alone, the best
# OSREP for pipelines (-m1, chosen from the fast backends) and the best
# SREP/REP; Omega -m5 stays within 0.1 % of SREP -m5f on every fast backend.
FAST_BE = ['xz', 'zstd', 'zpaq-m1']
PIPE = {
    'none': ['none'] + FAST_BE + ['zpaq-m5'],
    'osrep-m1': ['none'] + FAST_BE + ['zpaq-m5'],
    'osrep-m2': ['none', 'zpaq-m1'],
    'osrep-m3': ['none'] + FAST_BE,
    'osrep-m5': ['none'] + FAST_BE,
    'osrep-dup-m5': ['none'] + FAST_BE,
    'osrep-dup-m5-l32': ['none'] + FAST_BE,
    'osrep-dup-m5-l128': ['none'] + FAST_BE,
    'osrep-m5-l128-b256': ['none', 'xz', 'zpaq-m1', 'zpaq-m5'],
    'osrep-m5-l512-b256': ['none', 'xz', 'zpaq-m1'],
    'osrep-m6-l512': ['none'] + FAST_BE + ['zpaq-m5'],
    'osrep-m6-l256': ['none'] + FAST_BE + ['zpaq-m5'],
    'osrep-m6-l128': ['none'] + FAST_BE + ['zpaq-m5'],
    'osrep-m6-l64': ['none'] + FAST_BE + ['zpaq-m5'],
    'osrep-m6-l32': ['none'] + FAST_BE + ['zpaq-m5'],
    'srep-m3f': ['none'] + FAST_BE,
    'srep-m5f': ['none'] + FAST_BE + ['zpaq-m5'],
    'srep-m5f-l32': ['none'],
    'omega-m3': ['none'],
    'omega-m5': ['none'] + FAST_BE,
    'rep-64mb': ['none'],
    'rep-1gb': ['none'] + FAST_BE + ['zpaq-m5'],
    'zpaq-m0': ['none'] + ['xz', 'zstd'],
}

COLS = ['corpus', 'in_bytes', 'pre', 'backend',
        'pre_bytes', 'pre_enc_s', 'pre_enc_cpu_s', 'pre_enc_rss_mb',
        'pre_dec_s', 'pre_dec_rss_mb', 'pre_rt',
        'be_bytes', 'be_enc_s', 'be_enc_cpu_s', 'be_enc_rss_mb',
        'be_dec_s', 'be_dec_rss_mb', 'be_rt',
        'final_bytes', 'total_enc_s', 'total_dec_s', 'pre_reps', 'be_reps']

# --------------------------------------------------------------------------


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, file=sys.stderr, flush=True)


def mem_available_gb():
    with open('/proc/meminfo') as f:
        for line in f:
            if line.startswith('MemAvailable:'):
                return int(line.split()[1]) / (1024 * 1024)
    return 0.0


def wait_for_memory(min_gb):
    first = True
    while True:
        avail = mem_available_gb()
        if avail >= min_gb:
            return
        if first:
            log(f'waiting: MemAvailable {avail:.1f} GB < {min_gb} GB')
            first = False
        time.sleep(30)


def subst(argv, env):
    return [a.format(**env) for a in argv]


def run(argv, cwd, stdout_path, errlog, min_gb):
    """Run one command; return (wall_s, cpu_s, rss_mb)."""
    wait_for_memory(min_gb)
    out = open(stdout_path, 'wb') if stdout_path else subprocess.DEVNULL
    err = open(errlog, 'ab')
    try:
        t0 = time.perf_counter()
        p = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                             stdout=out, stderr=err)
        _, status, ru = os.wait4(p.pid, 0)
        wall = time.perf_counter() - t0
        p.returncode = os.waitstatus_to_exitcode(status)
    finally:
        if stdout_path:
            out.close()
        err.close()
    if p.returncode != 0:
        raise RuntimeError(f'exit {p.returncode}: {" ".join(argv)} (see {errlog})')
    return wall, ru.ru_utime + ru.ru_stime, ru.ru_maxrss / 1024.0


def same_file(a, b):
    if os.path.getsize(a) != os.path.getsize(b):
        return False
    return subprocess.run(['cmp', '-s', a, b]).returncode == 0


def rm(path):
    if os.path.isdir(path):
        shutil.rmtree(path)
    elif os.path.lexists(path):
        os.remove(path)


def measure(spec, in_name, work, tag, reps, min_gb, errlog):
    """Encode+decode `in_name` (in `work`) with `spec`, `reps` times.

    Returns a dict with sizes/times and leaves the encoded file in place."""
    out = f'{tag}.enc'
    dec = f'{tag}.dec'
    decdir = f'{tag}.decdir'
    env = {'IN': in_name, 'OUT': out, 'DEC': dec, 'DECDIR': decdir}
    enc_t, enc_c, enc_r, dec_t, dec_r = [], [], [], [], []
    rt = 'ok'
    for _ in range(reps):
        rm(os.path.join(work, out))
        w, c, r = run(subst(spec['enc'], env), work,
                      os.path.join(work, out) if spec.get('stdout') else None,
                      errlog, min_gb)
        enc_t.append(w); enc_c.append(c); enc_r.append(r)
        rm(os.path.join(work, dec)); rm(os.path.join(work, decdir))
        if '{DECDIR}' in spec['decoded']:
            os.makedirs(os.path.join(work, decdir))
        w, c, r = run(subst(spec['dec'], env), work,
                      os.path.join(work, dec) if spec.get('stdout') else None,
                      errlog, min_gb)
        dec_t.append(w); dec_r.append(r)
        decoded = os.path.join(work, spec['decoded'].format(**env))
        if not same_file(decoded, os.path.join(work, in_name)):
            rt = 'FAIL'
        rm(os.path.join(work, dec)); rm(os.path.join(work, decdir))
    return {'path': os.path.join(work, out), 'bytes': os.path.getsize(os.path.join(work, out)),
            'enc_s': statistics.median(enc_t), 'enc_cpu_s': statistics.median(enc_c),
            'enc_rss_mb': max(enc_r), 'dec_s': statistics.median(dec_t),
            'dec_rss_mb': max(dec_r), 'rt': rt}


def load_done(tsv):
    done = set()
    if os.path.exists(tsv):
        with open(tsv) as f:
            hdr = f.readline().rstrip('\n').split('\t')
            for line in f:
                row = dict(zip(hdr, line.rstrip('\n').split('\t')))
                done.add((row['corpus'], row['pre'], row['backend']))
    return done


def fmt(v):
    if isinstance(v, float):
        return f'{v:.3f}'
    return str(v)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--corpus', required=True, help='directory with the corpus files')
    ap.add_argument('--files', nargs='*', help='corpus files (default: all)')
    ap.add_argument('--work', required=True, help='scratch directory (same filesystem)')
    ap.add_argument('--tsv', required=True)
    ap.add_argument('--pre', nargs='*', help='preprocessors (default: all)')
    ap.add_argument('--backends', nargs='*', help='limit backends (default: per PIPE)')
    ap.add_argument('--small', type=int, default=128 << 20,
                    help='files up to this size get --reps runs (default 128 MiB)')
    ap.add_argument('--reps', type=int, default=3, help='pre-stage runs on small files')
    ap.add_argument('--be-reps', type=int, default=1, help='backend runs')
    ap.add_argument('--min-avail-gb', type=float, default=12.0)
    ap.add_argument('--list', action='store_true', help='print the configs and exit')
    a = ap.parse_args()

    if a.list:
        for k, v in PRE.items():
            print(k, ' '.join(v['enc']) if v else '-', '->', ','.join(PIPE[k]))
        return

    os.makedirs(a.work, exist_ok=True)
    files = a.files or sorted(f for f in os.listdir(a.corpus)
                              if os.path.isfile(os.path.join(a.corpus, f)))
    pres = a.pre or list(PRE)
    done = load_done(a.tsv)
    new = not os.path.exists(a.tsv)
    tsv = open(a.tsv, 'a')
    if new:
        tsv.write('\t'.join(COLS) + '\n'); tsv.flush()
    errlog = os.path.join(a.work, 'stderr.log')

    for fname in files:
        src = os.path.join(a.corpus, fname)
        size = os.path.getsize(src)
        big = size > a.small
        reps = 1 if big else a.reps
        for pname in pres:
            bes = [b for b in PIPE[pname] if not a.backends or b in a.backends]
            todo = [b for b in bes if (fname, pname, b) not in done]
            if not todo:
                continue
            # fresh work dir per (file, pre): the input is a hard link
            wd = os.path.join(a.work, 'run')
            rm(wd); os.makedirs(wd)
            os.link(src, os.path.join(wd, fname))
            log(f'{fname} {pname} -> {",".join(todo)}')
            try:
                if PRE[pname] is None:
                    pre = {'path': os.path.join(wd, fname), 'bytes': size, 'enc_s': 0.0,
                           'enc_cpu_s': 0.0, 'enc_rss_mb': 0.0, 'dec_s': 0.0,
                           'dec_rss_mb': 0.0, 'rt': 'ok'}
                    pre_reps = 0
                else:
                    pre = measure(PRE[pname], fname, wd, 'pre', reps, a.min_avail_gb, errlog)
                    pre_reps = reps
                pre_name = os.path.basename(pre['path'])
                for bname in todo:
                    row = {'corpus': fname, 'in_bytes': size, 'pre': pname, 'backend': bname,
                           'pre_bytes': pre['bytes'], 'pre_enc_s': pre['enc_s'],
                           'pre_enc_cpu_s': pre['enc_cpu_s'], 'pre_enc_rss_mb': pre['enc_rss_mb'],
                           'pre_dec_s': pre['dec_s'], 'pre_dec_rss_mb': pre['dec_rss_mb'],
                           'pre_rt': pre['rt'], 'pre_reps': pre_reps}
                    if bname == 'none':
                        row.update({'be_bytes': '', 'be_enc_s': '', 'be_enc_cpu_s': '',
                                    'be_enc_rss_mb': '', 'be_dec_s': '', 'be_dec_rss_mb': '',
                                    'be_rt': '', 'be_reps': 0, 'final_bytes': pre['bytes'],
                                    'total_enc_s': pre['enc_s'], 'total_dec_s': pre['dec_s']})
                        if pname == 'none':
                            continue
                    else:
                        be = measure(backend(bname, big), pre_name, wd, 'be', a.be_reps,
                                     a.min_avail_gb, errlog)
                        rm(be['path'])
                        row.update({'be_bytes': be['bytes'], 'be_enc_s': be['enc_s'],
                                    'be_enc_cpu_s': be['enc_cpu_s'],
                                    'be_enc_rss_mb': be['enc_rss_mb'], 'be_dec_s': be['dec_s'],
                                    'be_dec_rss_mb': be['dec_rss_mb'], 'be_rt': be['rt'],
                                    'be_reps': a.be_reps, 'final_bytes': be['bytes'],
                                    'total_enc_s': pre['enc_s'] + be['enc_s'],
                                    'total_dec_s': pre['dec_s'] + be['dec_s']})
                    tsv.write('\t'.join(fmt(row[c]) for c in COLS) + '\n')
                    tsv.flush()
                    log(f'  {bname}: final {row["final_bytes"]} enc {fmt(row["total_enc_s"])} s'
                        f' rt {row["pre_rt"]}/{row["be_rt"]}')
            except RuntimeError as e:
                log('ERROR', e)
            finally:
                rm(wd)
    tsv.close()


if __name__ == '__main__':
    main()
