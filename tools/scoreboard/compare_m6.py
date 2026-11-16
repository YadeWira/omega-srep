#!/usr/bin/env python3
"""best osrep-m6-* vs best rival (srep/omega/rep/none) per corpus x backend."""
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
pref = sys.argv[2] if len(sys.argv) > 2 else 'osrep-m6'
cells = {}
for r in rows:
    if r['pre_rt'] not in ('ok', '') or r['be_rt'] not in ('ok', '', '-'):
        pass
    k = (r['corpus'], r['backend'])
    cells.setdefault(k, []).append(r)
print('corpus\tbackend\tbest m6\tbytes\tenc_s\tbest rival\tbytes\tenc_s\tdiff')
w = t = l = 0
for (c, b), rs in sorted(cells.items()):
    m6 = [r for r in rs if r['pre'].startswith(pref)]
    riv = [r for r in rs if not r['pre'].startswith('osrep') and r['pre'] != 'zpaq-m0']
    if not m6 or not riv:
        continue
    bm = min(m6, key=lambda r: int(r['final_bytes']))
    br = min(riv, key=lambda r: int(r['final_bytes']))
    d = 100.0 * (int(bm['final_bytes']) - int(br['final_bytes'])) / int(br['final_bytes'])
    tag = 'GANA' if d <= -0.1 else ('pierde' if d >= 0.1 else 'empate')
    w += tag == 'GANA'; l += tag == 'pierde'; t += tag == 'empate'
    print(f"{c}\t{b}\t{bm['pre']}\t{bm['final_bytes']}\t{bm['total_enc_s']}\t{br['pre']}\t{br['final_bytes']}\t{br['total_enc_s']}\t{d:+.2f}% {tag}")
print(f'gana {w} empata {t} pierde {l}')
