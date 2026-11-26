import csv,sys,os
m=sys.argv[1]
d={}
for f,tag in [('base%s.tsv'%m,''),('cap4096%s.tsv'%m,'c4k'),('cap8192%s.tsv'%m,'c8k')]:
    if not os.path.exists(f): continue
    for r in csv.DictReader(open(f),delimiter='\t'):
        if not r.get('archive','').isdigit(): continue
        k,n=r['config'].split(':'); d[(r['corpus'],(k if not tag else 'osrep-'+tag),n)]=(int(r['archive']),r['extract'])
bad=[k for k,v in d.items() if v[1]!='ok']; print('not ok:',bad)
for c in sorted(set(k[0] for k in d)):
    z={n:d[(c,'zpaq',n)][0] for n in '0369' if (c,'zpaq',n) in d}
    if not z: continue
    bz=min(z.values()); print(c, 'zpaq best',bz, {n:v for n,v in z.items()})
    for kind in ['osrep','osrep-c4k','osrep-c8k']:
        o={n:d[(c,kind,n)][0] for n in '0369' if (c,kind,n) in d}
        if not o: continue
        print('  %-10s'%kind, ' '.join('N%s %+.2f%%'%(n,(v/z[n]-1)*100) for n,v in sorted(o.items()) if n in z), ' best %+.2f%%'%((min(o.values())/bz-1)*100))
