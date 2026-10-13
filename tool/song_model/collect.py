"""Join Sonnet's answers with the crawled videos -> train.jsonl, unlabelled.jsonl, lexicon.json."""
import json, os, re
from tagger import norm
S = os.path.dirname(os.path.abspath(__file__))
rows = {}
for l in open(S + '/crawl.jsonl'):
    r = json.loads(l); rows[r['bvid']] = r
state = json.load(open(S + '/label/batches.json'))
test = {json.loads(l)['bvid'] for l in open(S + '/test121.jsonl')}
out, stats = [], {'songs': 0, 'none': 0, 'up': 0, 'unverbatim': 0, 'missing': 0}
for name, bvids in sorted(state.items()):
    p = f'{S}/label/{name}.out.jsonl'
    if not os.path.exists(p):
        print(name, 'not labelled yet'); continue
    ans = {}
    for l in open(p):
        l = l.strip().rstrip(',')
        if not l or l in '[]': continue
        try:
            a = json.loads(l); ans[a[0]] = a
        except Exception:
            print(name, 'bad line', l[:60])
    for k, b in enumerate(bvids, 1):
        r = rows[b]; a = ans.get(k)
        if a is None:
            stats['missing'] += 1; continue
        lab = None
        if len(a) > 2 and a[1]:
            perf = [p for p in a[2] if isinstance(p, str) and p.strip()]
            lab = {'song': a[1], 'performers': perf}
            hay = norm(r['title'] + ' '.join(r['tags']) + r['up'] + json.dumps(r.get('music') or {}, ensure_ascii=False))
            if any(norm(s) not in hay for s in [a[1]] + [p for p in perf if p != 'UP主']):
                stats['unverbatim'] += 1
            stats['songs'] += 1; stats['up'] += 'UP主' in perf
        else:
            stats['none'] += 1
        out.append({'bvid': b, 'q': r['q'], 'title': r['title'], 'up': r['up'], 'dur': r['dur'], 'tags': r['tags'],
                    'music': r.get('music'), 'label': lab})
open(S + '/train.jsonl', 'w').write('\n'.join(json.dumps(x, ensure_ascii=False) for x in out) + '\n')
print(len(out), stats)
# unlabelled: every searched video that is neither labelled nor in the test set
lab = {x['bvid'] for x in out}
unl, seen = [], set()
for q, rs in json.load(open(S + '/crawl_search.json')).items():
    for r in rs:
        if r['bvid'] in lab or r['bvid'] in test or r['bvid'] in seen: continue
        seen.add(r['bvid'])
        unl.append({'bvid': r['bvid'], 'title': r['title'], 'up': r['up'], 'dur': r['dur'], 'tags': r['tags'],
                    'music': rows.get(r['bvid'], {}).get('music')})
open(S + '/unlabelled.jsonl', 'w').write('\n'.join(json.dumps(x, ensure_ascii=False) for x in unl) + '\n')
names = set()
p = S + '/singers_netease.json'
if os.path.exists(p):
    for n, v in json.load(open(p)).items():
        names.add(n); names.update(v.get('alias') or [])
for r in rows.values():
    names.update((r.get('music') or {}).get('a') or [])
json.dump(sorted(names), open(S + '/lexicon.json', 'w'), ensure_ascii=False)
print('unlabelled', len(unl), 'lexicon', len(names))
