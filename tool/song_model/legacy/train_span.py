"""Train the tagger. python3 train.py [--epochs N] [--d 128] [--layers 4] [--no-aug] [--no-mlm] [--seed 0]"""
import argparse, copy, json, os, random, sys, time
import torch, torch.nn.functional as F
from tagger import *
import tagger, spans

ap = argparse.ArgumentParser()
ap.add_argument('--epochs', type=int, default=40)
ap.add_argument('--d', type=int, default=128)
ap.add_argument('--layers', type=int, default=4)
ap.add_argument('--ff', type=int, default=256)
ap.add_argument('--seed', type=int, default=0)
ap.add_argument('--narrow-swap', action='store_true')
ap.add_argument('--drop', type=float, default=0.1)
ap.add_argument('--wd', type=float, default=0.01)
ap.add_argument('--init', default='')
ap.add_argument('--no-cross', action='store_true')
ap.add_argument('--lr', type=float, default=1e-3)
ap.add_argument('--no-aug', action='store_true')
ap.add_argument('--no-mlm', action='store_true')
ap.add_argument('--train', default='train.jsonl')
ap.add_argument('--test', default='test121.jsonl')
ap.add_argument('--unlabelled', default='unlabelled.jsonl')
ap.add_argument('--save', default='span.pt')
ap.add_argument('-v', action='store_true')
args = ap.parse_args()
random.seed(args.seed); torch.manual_seed(args.seed)
_lex_path = os.path.join(S, 'lexicon.json')
if os.path.exists(_lex_path): load_lexicon(json.load(open(_lex_path)))
dev = os.environ.get('DEV') or ('mps' if torch.backends.mps.is_available() else 'cpu')

load = lambda p: [json.loads(l) for l in open(os.path.join(S, p)) if l.strip()]
train_rows, test_rows = load(args.train), load(args.test)
unl = load(args.unlabelled) if os.path.exists(os.path.join(S, args.unlabelled)) and not args.no_mlm else []
random.shuffle(train_rows)
# a fixed validation set, so runs (and the rules) are compared on the same videos
dev_rows = json.load(open(os.path.join(S, 'dev.json')))
_dev = {r['bvid'] for r in dev_rows} | {r['bvid'] for r in test_rows}
train_rows = [r for r in train_rows if r['bvid'] not in _dev]

chars = set()
for r in train_rows + unl:
    for s in [r['title'], r['up']] + (r.get('tags') or []) + ([r['music']['t']] + r['music'].get('a', []) if r.get('music') else []):
        chars.update(fold(c) for c in s)
vocab = Vocab(chars)
_init = torch.load(os.path.join(S, args.init), map_location='cpu') if args.init else None
if _init:
    vocab = Vocab(); vocab.itos = _init['vocab']; vocab.stoi = {c: i for i, c in enumerate(vocab.itos)}
MASK = 1

# lexicons for entity swapping
singers, songs = set(), set()
for r in train_rows + unl:
    m = r.get('music')
    if m:
        songs.add(m['t']); singers.update(m.get('a') or [])
for r in train_rows:
    lab = r.get('label')
    if lab and lab.get('song'):
        songs.add(lab['song'])
        singers.update(p for p in lab['performers'] if p.upper() not in ('UP主', 'UP'))
singers = [s for s in singers if 2 <= len(s) <= 20]; songs = [s for s in songs if 1 <= len(s) <= 24]
if not args.narrow_swap:
    # names the model has never seen, famous or not: NetEase's artists and plain uploader nicknames,
    # so "A 翻唱 B" is learnt from where the names stand rather than from who they are
    import re as _re
    _nick = {r['up'] for r in train_rows + unl if 2 <= len(r['up']) <= 10 and not _re.search(r'[\d_\-]|音乐|官方|频道|工作室|卫视|娱乐|影视|综艺|MV|Live|live', r['up'])}
    _lex = [n for n in json.load(open(_lex_path)) if 2 <= len(n) <= 12] if os.path.exists(_lex_path) else []
    singers = singers + random.sample(_lex, min(len(_lex), 6000)) + sorted(_nick)
    print('swap names', len(singers))
print(f'train {len(train_rows)} dev {len(dev_rows)} test {len(test_rows)} unlabelled {len(unl)} vocab {len(vocab.itos)} singers {len(singers)} songs {len(songs)} device {dev}')


def swap(r):
    """Same video, other names: teaches structure rather than who is famous."""
    lab = r.get('label')
    if not lab or not lab.get('song'):
        return r
    r = copy.deepcopy(r); lab = r['label']
    subs = {}
    names = [p for p in lab['performers'] if p.upper() not in ('UP主', 'UP') and len(p) >= 2]
    others = [a for a in ((r.get('music') or {}).get('a') or []) if a not in names and len(a) >= 2]
    for n in names + others:
        if random.random() < 0.5: subs[n] = random.choice(singers)
    if len(lab['song']) >= 2 and random.random() < 0.4: subs[lab['song']] = random.choice(songs)
    if not subs: return r
    def rep(s):
        for a, b in subs.items(): s = s.replace(a, b)
        return s
    r['title'] = rep(r['title']); r['tags'] = [rep(t) for t in r.get('tags') or []]
    if r.get('music'):
        r['music']['t'] = rep(r['music']['t']); r['music']['a'] = [rep(a) for a in r['music'].get('a') or []]
    if r['up'] in subs: r['up'] = subs[r['up']]
    lab['song'] = rep(lab['song']); lab['performers'] = [rep(p) for p in lab['performers']]
    return r


model = spans.SpanModel(len(vocab.itos), d=args.d, layers=args.layers, ff=args.ff, drop=args.drop, cross=not args.no_cross).to(dev)
if _init:
    print('init', model.enc.load_state_dict(_init['state'], strict=False))
print('params', sum(p.numel() for p in model.parameters()))
steps_per = math.ceil(len(train_rows) / 32)
total = steps_per * args.epochs
opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.wd)
sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=args.lr, total_steps=total, pct_start=0.1)
torch.set_num_threads(2)
random.Random(0).shuffle(unl)
unl_items = tagger.tensorize(unl[:8000], vocab, with_labels=False) if unl else []  # capped to keep memory small


def evaluate(rows, verbose=False):
    model.eval()
    items = spans.tensorize(rows, vocab)
    ok = song_ok = isok = 0; miss = []
    with torch.no_grad():
        for k in range(0, len(items), 64):
            b = items[k:k + 64]
            ids, segs, cls, feats, dur, pad, cand = spans.collate(b, dev)[:7]
            sp, song, _ = model(ids, segs, cls, feats, dur, pad, cand)
            sp, song = F.softmax(sp, -1).cpu(), F.softmax(song, -1).cpu()
            for j, it in enumerate(b):
                ans = spans.decode(it, sp[j], song[j])
                g, a = gold_key(it['row']), answer_key(ans)
                ok += g == a; isok += (g is None) == (a is None)
                song_ok += (g is None and a is None) or (g is not None and a is not None and g[0] == a[0])
                if g != a: miss.append((it['row']['title'][:60], it['row']['up'], it['row']['label'], ans))
    if verbose:
        for m in miss: print('  ✗', m)
    return ok, song_ok, isok, len(items)


best, best_state = -1, None
t0 = time.time()
step = 0
for ep in range(args.epochs):
    model.train()
    rows = train_rows if args.no_aug else [swap(r) if random.random() < 0.7 else r for r in train_rows]
    items = spans.tensorize(rows, vocab)
    random.shuffle(items)
    tot = 0
    for k in range(0, len(items), 32):
        b = items[k:k + 32]
        ids, segs, cls, feats, dur, pad, cand, gold, is_song = spans.collate(b, dev)
        sp, song, _ = model(ids, segs, cls, feats, dur, pad, cand)
        w = torch.tensor([1.0, 3.0, 3.0], device=dev)
        loss = F.cross_entropy(sp.reshape(-1, 3), gold.reshape(-1), ignore_index=-100, weight=w) + F.cross_entropy(song, is_song)
        if unl_items:
            ub = random.sample(unl_items, 32)
            ids, segs, cls, feats, dur, pad = tagger.collate(ub, dev)
            m = (torch.rand(ids.shape, device=dev) < 0.15) & ~pad & (ids > 8)
            _, _, h = model.enc(ids.masked_fill(m, MASK), segs, cls.masked_fill(m, 7), feats, dur, pad)
            if m.any(): loss = loss + 0.5 * F.cross_entropy(model.enc.lm(h[m]), ids[m])
        opt.zero_grad(); loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step(); sched.step(); tot += loss.item()
        step += 1
        if dev == 'mps' and step % 10 == 0: torch.mps.empty_cache()  # the allocator's cache otherwise grows to gigabytes
    if ep % max(1, args.epochs // 8) == max(1, args.epochs // 8) - 1 or ep == args.epochs - 1:
        d = evaluate(dev_rows); t = evaluate(test_rows)
        print(f'ep {ep+1} loss {tot/steps_per:.3f} dev {d[0]}/{d[3]} (song {d[1]}, is {d[2]}) test {t[0]}/{t[3]} (song {t[1]}, is {t[2]}) {time.time()-t0:.0f}s', flush=True)
        if d[0] >= best and ep >= args.epochs // 2:
            best, best_state = d[0], copy.deepcopy(model.state_dict())
if best_state: model.load_state_dict(best_state)
t = evaluate(test_rows, verbose=args.v)
print(f'FINAL test {t[0]}/{t[3]} song {t[1]} is_song {t[2]}')
torch.save({'state': model.state_dict(), 'vocab': vocab.itos, 'args': vars(args)}, os.path.join(S, args.save))
