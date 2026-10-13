"""Masked-character pretraining of the encoder on unlabelled videos. python3 pretrain.py --steps 20000"""
import argparse, json, os, random, time, collections
import torch, torch.nn.functional as F
import tagger
from tagger import fold
ap = argparse.ArgumentParser()
ap.add_argument('--steps', type=int, default=20000)
ap.add_argument('--d', type=int, default=128); ap.add_argument('--layers', type=int, default=4); ap.add_argument('--ff', type=int, default=256)
ap.add_argument('--save', default='pre.pt')
args = ap.parse_args()
S = tagger.S; random.seed(0); torch.manual_seed(0)
dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
tagger.load_lexicon(json.load(open(S + '/lexicon.json')))
hold = {json.loads(l)['bvid'] for l in open(S + '/test121.jsonl')} | {r['bvid'] for r in json.load(open(S + '/dev.json'))}
rows, seen = [], set()
for p in ('crawl.jsonl', 'titles.jsonl'):
    if not os.path.exists(S + '/' + p): continue
    for l in open(S + '/' + p):
        r = json.loads(l)
        if r['bvid'] in seen or r['bvid'] in hold: continue
        seen.add(r['bvid']); rows.append(r)
count = collections.Counter()
for r in rows:
    for s in [r['title'], r['up']] + (r.get('tags') or []) + ([r['music']['t']] + r['music'].get('a', []) if r.get('music') else []):
        count.update(fold(c) for c in s)
vocab = tagger.Vocab({c for c, n in count.items() if n >= 3})
print('rows', len(rows), 'vocab', len(vocab.itos), flush=True)
model = tagger.Tagger(len(vocab.itos), d=args.d, layers=args.layers, ff=args.ff).to(dev)
opt = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=0.01)
sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=1e-3, total_steps=args.steps, pct_start=0.05)
t0 = time.time(); tot = 0
for step in range(1, args.steps + 1):
    items = tagger.tensorize(random.sample(rows, 48), vocab, with_labels=False)
    ids, segs, cls, feats, dur, pad = tagger.collate(items, dev)
    m = (torch.rand(ids.shape, device=dev) < 0.15) & ~pad & (ids > 8)
    # whole fields too (a tag, the uploader): they must be recovered from what the title says
    for b, it in enumerate(items):
        for seg, a, e in it['spans']:
            if seg != 't' and random.random() < 0.1: m[b, a:e] = True
    m &= ~pad & (ids > 8)
    _, _, h = model(ids.masked_fill(m, 1), segs, cls.masked_fill(m, 7), feats * (~m)[..., None], dur, pad)
    loss = F.cross_entropy(model.lm(h[m]), ids[m])
    opt.zero_grad(); loss.backward(); torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0); opt.step(); sched.step()
    tot += loss.item()
    if step % 20 == 0 and dev == 'mps': torch.mps.empty_cache()
    if step % 1000 == 0:
        print(f'step {step} loss {tot/1000:.3f} {time.time()-t0:.0f}s', flush=True); tot = 0
        torch.save({'state': model.state_dict(), 'vocab': vocab.itos, 'args': vars(args)}, S + '/' + args.save)
