"""Builds work/eval.json, the videos every change is measured on:

  hold : data/hold.json, 800 labelled videos kept out of training
  dev  : data/dev.json, the 233 the earlier models were selected on
  zs   : the hand-checked videos of test/fixtures/zhoushen_videos.json

each with the zone and description the crawl recorded, as the rule matcher wants them."""
import gzip, json, os, re
from tagger import S, find
crawl = {}
for l in gzip.open(find('crawl.jsonl.gz'), 'rt'):
    r = json.loads(l); crawl[r['bvid']] = r
rows = []
for name in ('hold', 'dev'):
    for r in json.load(open(find(name + '.json'))):
        c = crawl.get(r['bvid'], {})
        rows.append(dict(r, set=name, zone=r.get('zone') or c.get('zone', ''), desc=r.get('desc') or c.get('desc', '')))
for v in json.load(open(os.path.join(S, '../../test/fixtures/zhoushen_videos.json'))):
    if not v.get('checked'): continue
    m, e = v.get('music'), v.get('expect')
    rows.append({'set': 'zs', 'bvid': v['bvid'], 'title': v['title'], 'up': v['up'], 'dur': v['dur'], 'tags': v['tags'], 'zone': v['zone'], 'desc': v['desc'],
                 'music': m and {'t': m['title'], 'a': [a.strip() for a in re.split(r'[,，/／、]', m['artists']) if a.strip()]},
                 'label': e and {'song': e['title'], 'performers': e['artist'].split(' & ')}})
os.makedirs(os.path.dirname(find('eval.json')), exist_ok=True)
json.dump(rows, open(find('eval.json'), 'w'), ensure_ascii=False)
print(len(rows), 'videos ->', find('eval.json'))
