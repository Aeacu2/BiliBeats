"""Which of mmBERT's tokens and merges titles like ours use -> work/bpe_used.json.
Only needed for `export_plm.py --prune-vocab` (a smaller app; the default ships the whole vocabulary)."""
import gzip, json, sys
import bpe
from tagger import find
t = bpe.CharBPE(find(sys.argv[1] if len(sys.argv) > 1 else 'plm/mmbert-small')); t.used = set()
ids = set()
def take(r):
    m = r.get('music')
    for f in [r['title'], r['up']] + list(r.get('tags') or []) + ([m['t']] + list(m.get('a') or []) if m else []):
        for tid, a, b in t.field(f[:120]): ids.add(tid)
for p in ('crawl.jsonl.gz', 'titles.jsonl.gz'):
    for l in gzip.open(find(p), 'rt'): take(json.loads(l))
for p in ('train.jsonl', 'train_haiku.jsonl'):
    for l in open(find(p)):
        if l.strip(): take(json.loads(l))
json.dump({'ids': sorted(ids), 'merges': sorted(t.used)}, open(find('bpe_used.json'), 'w'), ensure_ascii=False)
print(len(ids), 'tokens,', len(t.used), 'merges')
