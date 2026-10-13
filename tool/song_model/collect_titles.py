"""Join Haiku's answers (label_haiku/tNNN.out.jsonl) with the titles -> data/train_haiku.jsonl.
Answers that are not verbatim in the video's own text are dropped: the model can only point at what is there."""
import gzip, json, os
from tagger import norm
S = os.path.dirname(os.path.abspath(__file__))
D, L = S + '/data', S + '/label_haiku'
rows = {}
for l in gzip.open(D + '/titles.jsonl.gz', 'rt'):
    r = json.loads(l); rows.setdefault(r['bvid'], r)
state = json.load(open(L + '/batches.json'))
out, stats = [], {'batches': 0, 'songs': 0, 'none': 0, 'up': 0, 'unverbatim': 0, 'missing': 0, 'short': []}
for name, bvids in sorted(state.items()):
    p = f'{L}/{name}.out.jsonl'
    if not name.startswith('t') or not os.path.exists(p): continue
    ans = {}
    for l in open(p):
        l = l.strip().rstrip(',')
        if not l or l in '[]': continue
        try:
            a = json.loads(l); ans[a[0]] = a
        except Exception:
            pass
    if len(ans) < len(bvids): stats['short'].append(name)
    stats['batches'] += 1
    for k, b in enumerate(bvids, 1):
        r = rows[b]; a = ans.get(k)
        if a is None:
            stats['missing'] += 1; continue
        lab = None
        if len(a) > 2 and a[1] and isinstance(a[1], str) and isinstance(a[2], list):
            perf = [p for p in a[2] if isinstance(p, str) and p.strip()]
            hay = norm(r['title'] + ' '.join(r.get('tags') or []) + r['up'])
            if not perf or any(norm(s) not in hay for s in [a[1]] + [p for p in perf if p != 'UP主']):
                stats['unverbatim'] += 1; continue
            lab = {'song': a[1], 'performers': perf}
            stats['songs'] += 1; stats['up'] += 'UP主' in perf
        else:
            stats['none'] += 1
        out.append({'bvid': b, 'q': '', 'title': r['title'], 'up': r['up'], 'dur': r['dur'], 'tags': r.get('tags') or [],
                    'music': None, 'label': lab})
open(D + '/train_haiku.jsonl', 'w').write('\n'.join(json.dumps(x, ensure_ascii=False) for x in out) + '\n')
print(len(out), stats)
