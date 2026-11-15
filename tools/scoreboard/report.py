#!/usr/bin/env python3
"""Turn scoreboard.tsv into the Markdown tables of docs/scoreboard.md.

  python3 tools/scoreboard/report.py out/scoreboard.tsv > tables.md

Per corpus: the preprocessor alone, a matrix of final sizes (preprocessor x
backend) and a matrix of total encode / decode times. Then a summary: for
each corpus and backend, the best OSREP configuration against the best
non-OSREP one (backend alone included).
"""
import sys
from collections import OrderedDict

PRE_ORDER = ['none', 'osrep-m1', 'osrep-m2', 'osrep-m3', 'osrep-m5', 'osrep-dup-m5', 'osrep-dup-m5-l32',
             'osrep-dup-m5-l128', 'osrep-m5-l128-b256', 'osrep-m5-l512-b256', 'srep-m3f', 'srep-m5f', 'srep-m5f-l32',
             'omega-m3', 'omega-m5', 'rep-64mb', 'rep-1gb', 'zpaq-m0']
BE_ORDER = ['none', 'xz', 'zstd', 'zpaq-m1', 'zpaq-m5']
CORPUS_ORDER = ['enwik8', 'silesia.tar', 'real64.bin', 'versions.tar', 'pja.tar',
                'zpaqstd-history.tar', 'game-assets.tar']


def num(s):
    return int(s) if s not in ('', None) else None


def flt(s):
    return float(s) if s not in ('', None) else None


def mb(n, dec=2):
    return f'{n / 1e6:,.{dec}f}'.replace(',', '_').replace('.', ',').replace('_', '.')


def sec(x):
    if x is None:
        return '—'
    if x >= 100:
        return f'{x:.0f}'
    if x >= 10:
        return f'{x:.1f}'.replace('.', ',')
    return f'{x:.2f}'.replace('.', ',')


def pct(x):
    return f'{x:+.1f} %'.replace('.', ',')


def load(path):
    rows = []
    with open(path) as f:
        hdr = f.readline().rstrip('\n').split('\t')
        for line in f:
            rows.append(dict(zip(hdr, line.rstrip('\n').split('\t'))))
    return rows


def is_osrep(p):
    return p.startswith('osrep')


def main():
    rows = load(sys.argv[1])
    by = OrderedDict()
    for r in rows:
        by.setdefault(r['corpus'], {})[(r['pre'], r['backend'])] = r
    corpora = [c for c in CORPUS_ORDER if c in by] + [c for c in by if c not in CORPUS_ORDER]
    summary = []
    for c in corpora:
        d = by[c]
        insize = int(next(iter(d.values()))['in_bytes'])
        print(f'### {c} ({mb(insize)} MB)\n')
        # 1. preprocessor alone
        print('Preprocesador solo (MB = 10^6 bytes; tiempos en s; RSS en MB):\n')
        print('| config | salida MB | % | cod s | cod CPU s | cod RSS | dec s | dec RSS | ida y vuelta |')
        print('|---|---:|---:|---:|---:|---:|---:|---:|:-:|')
        alone = [(p, d[(p, 'none')]) for p in PRE_ORDER if (p, 'none') in d]
        best = min((int(r['pre_bytes']) for p, r in alone), default=None)
        for p, r in alone:
            b = int(r['pre_bytes'])
            s = mb(b)
            if b == best:
                s = f'**{s}**'
            print(f'| `{p}` | {s} | {f'{100 * b / insize:.1f}'.replace('.', ',')} | {sec(flt(r["pre_enc_s"]))} | '
                  f'{sec(flt(r["pre_enc_cpu_s"]))} | {flt(r["pre_enc_rss_mb"]):.0f} | '
                  f'{sec(flt(r["pre_dec_s"]))} | {flt(r["pre_dec_rss_mb"]):.0f} | {r["pre_rt"]} |')
        print()
        # 2. final sizes
        bes = [b for b in BE_ORDER[1:] if any((p, b) in d for p in PRE_ORDER)]
        print('Tamaño final con backend (MB con tres decimales; en negrita, el mejor de la columna):\n')
        print('| preprocesador | ' + ' | '.join(bes) + ' |')
        print('|---|' + '---:|' * len(bes))
        colbest = {b: min((int(d[(p, b)]['final_bytes']) for p in PRE_ORDER if (p, b) in d))
                   for b in bes}
        for p in PRE_ORDER:
            if not any((p, b) in d for b in bes):
                continue
            cells = []
            for b in bes:
                r = d.get((p, b))
                if not r:
                    cells.append('')
                    continue
                v = int(r['final_bytes'])
                s = mb(v, 3)
                if r['pre_rt'] != 'ok' or r['be_rt'] != 'ok':
                    s += ' (rt FAIL)'
                cells.append(f'**{s}**' if v == colbest[b] else s)
            print(f'| `{p}` | ' + ' | '.join(cells) + ' |')
        print()
        # 3. times
        print('Tiempo total de la tubería, codificar / decodificar (s), y RSS pico '
              'de la etapa más pesada (MB):\n')
        print('| preprocesador | ' + ' | '.join(bes) + ' |')
        print('|---|' + '---:|' * len(bes))
        for p in PRE_ORDER:
            if not any((p, b) in d for b in bes):
                continue
            cells = []
            for b in bes:
                r = d.get((p, b))
                if not r:
                    cells.append('')
                    continue
                rss = max(flt(r['pre_enc_rss_mb']) or 0, flt(r['be_enc_rss_mb']) or 0)
                cells.append(f'{sec(flt(r["total_enc_s"]))} / {sec(flt(r["total_dec_s"]))}'
                             f' · {rss:.0f}')
            print(f'| `{p}` | ' + ' | '.join(cells) + ' |')
        print()
        # summary rows
        for b in bes:
            os_rows = [(p, d[(p, b)]) for p in PRE_ORDER if is_osrep(p) and (p, b) in d]
            ot_rows = [(p, d[(p, b)]) for p in PRE_ORDER if not is_osrep(p) and (p, b) in d
                       and not (p == 'none' and b == 'none')]
            if not os_rows or not ot_rows:
                continue
            po, ro = min(os_rows, key=lambda x: int(x[1]['final_bytes']))
            pc, rc = min(ot_rows, key=lambda x: int(x[1]['final_bytes']))
            vo, vc = int(ro['final_bytes']), int(rc['final_bytes'])
            summary.append((c, b, po, vo, flt(ro['total_enc_s']), pc, vc,
                            flt(rc['total_enc_s']), 100.0 * (vo - vc) / vc))
    print('### Resumen: mejor OSREP contra el mejor rival, con backend\n')
    print('Rival = la mejor configuración que no es OSREP, incluido el backend solo. '
          'Menos de 0,1 % es empate (SREP/Omega varían eso entre corridas).\n')
    print('| corpus | backend | mejor OSREP | MB | cod s | mejor rival | MB | cod s | OSREP vs rival |')
    print('|---|---|---|---:|---:|---|---:|---:|---:|')
    for c, b, po, vo, to, pc, vc, tc, m in summary:
        flag = 'empate' if abs(m) < 0.1 else ('**gana**' if m < 0 else 'pierde')
        print(f'| {c} | {b} | `{po}` | {mb(vo, 3)} | {sec(to)} | `{pc}` | {mb(vc, 3)} | {sec(tc)} | '
              f'{pct(m)} ({flag}) |')


if __name__ == '__main__':
    main()
