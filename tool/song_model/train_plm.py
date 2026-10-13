"""Fine-tune a pretrained encoder as the span model.

  python3 train_plm.py --plm plm/mmbert-small --freeze-emb --lr 5e-5 --save mmbert.pt
  python3 train_plm.py --plm plm/mmbert-small --freeze-emb --lr 5e-5 --use-hold --eval dev.json --save ship.pt

Trains on data/train.jsonl without the videos of dev.json, test121.jsonl and (unless --use-hold)
hold.json, and prints after every third epoch how many of each of those it gets wholly right."""
import argparse, copy, json, math, os, random, re, sys, time, warnings
warnings.filterwarnings('ignore')
import plm, tagger, spans
import torch, torch.nn.functional as F
from tagger import gold_key, answer_key
ap = argparse.ArgumentParser()
ap.add_argument('--plm', required=True); ap.add_argument('--train', default='train.jsonl'); ap.add_argument('--extra', default='')
ap.add_argument('--eval', default='hold.json'); ap.add_argument('--save', default='plm.pt')
ap.add_argument('--epochs', type=int, default=12); ap.add_argument('--lr', type=float, default=1e-4); ap.add_argument('--head-lr', type=float, default=1e-3)
ap.add_argument('--use-hold', action='store_true', help='train on the hold-out too (the model that ships)')
ap.add_argument('--freeze-emb', action='store_true', help='leave the word embeddings as pretrained (huge multilingual vocabularies)')
ap.add_argument('--bs', type=int, default=32); ap.add_argument('--seed', type=int, default=0); ap.add_argument('--no-aug', action='store_true')
args = ap.parse_args()
random.seed(args.seed); torch.manual_seed(args.seed)
dev = os.environ.get('DEV') or ('mps' if torch.backends.mps.is_available() else 'cpu')
find = tagger.find
tagger.load_lexicon(json.load(open(find('lexicon.json'))))
jl = lambda p: json.load(open(find(p))) if p.endswith('.json') else [json.loads(l) for l in open(find(p)) if l.strip()]
hold = {r['bvid'] for p in ('dev.json', 'test121.jsonl') + (() if args.use_hold else ('hold.json',)) for r in jl(p)}
train_rows = [r for r in jl(args.train) if r['bvid'] not in hold]
if args.extra: train_rows += [r for r in jl(args.extra) if r['bvid'] not in hold]
eval_rows = jl(args.eval); dev_rows = jl('dev.json'); zs_rows = jl('test121.jsonl')
wp = plm.make_tok(find(args.plm))
singers, songs = set(), set()
for r in train_rows:
    m = r.get('music')
    if m: songs.add(m['t']); singers.update(m.get('a') or [])
    lab = r.get('label')
    if lab and lab.get('song'):
        songs.add(lab['song']); singers.update(p for p in lab['performers'] if p.upper() not in ('UP主', 'UP'))
singers = [s for s in singers if 2 <= len(s) <= 20]; songs = [s for s in songs if 1 <= len(s) <= 24]
_nick = {r['up'] for r in train_rows if 2 <= len(r['up']) <= 10 and not re.search(r'[\d_\-]|音乐|官方|频道|工作室|卫视|娱乐|影视|综艺|MV|Live|live', r['up'])}
_lex = [n for n in json.load(open(find('lexicon.json'))) if 2 <= len(n) <= 12]
singers = singers + random.sample(_lex, min(len(_lex), 6000)) + sorted(_nick)

def swap(r):
    lab = r.get('label')
    if not lab or not lab.get('song'): return r
    r = copy.deepcopy(r); lab = r['label']; subs = {}
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

model = plm.PLMSpan(find(args.plm)).to(dev)
if args.freeze_emb:
    for p in model.bert.get_input_embeddings().parameters(): p.requires_grad_(False)
enc = [p for n, p in model.named_parameters() if n.startswith('bert.') and p.requires_grad]; head = [p for n, p in model.named_parameters() if not n.startswith('bert.')]
print(f'{args.plm}: params {sum(p.numel() for p in model.parameters())/1e6:.1f}M encoder {sum(p.numel() for p in enc)/1e6:.1f}M; train {len(train_rows)} device {dev}', flush=True)
steps_per = math.ceil(len(train_rows) / args.bs); total = steps_per * args.epochs
opt = torch.optim.AdamW([{'params': enc, 'lr': args.lr}, {'params': head, 'lr': args.head_lr}], weight_decay=0.01)
sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=[args.lr, args.head_lr], total_steps=total, pct_start=0.1)

def evaluate(rows):
    model.eval(); items = plm.tensorize(rows, wp); ok = song_ok = isok = 0
    with torch.no_grad():
        for k in range(0, len(items), 64):
            b = items[k:k + 64]
            sp, song = model(*plm.collate(b, dev)[:7])
            sp, song = F.softmax(sp, -1).cpu(), F.softmax(song, -1).cpu()
            for j, it in enumerate(b):
                g, a = gold_key(it['row']), answer_key(spans.decode(it, sp[j], song[j]))
                ok += g == a; isok += (g is None) == (a is None)
                song_ok += (g is None and a is None) or (g is not None and a is not None and g[0] == a[0])
    return f'{ok}/{len(items)} (song {song_ok}, is {isok})'

t0 = time.time(); step = 0
for ep in range(args.epochs):
    model.train()
    rows = train_rows if args.no_aug else [swap(r) if random.random() < 0.7 else r for r in train_rows]
    items = plm.tensorize(rows, wp); random.shuffle(items); tot = 0
    for k in range(0, len(items), args.bs):
        b = items[k:k + args.bs]
        tok, tseg, tfeat, dur, tpad, c2t, cand, gold, is_song = plm.collate(b, dev)
        sp, song = model(tok, tseg, tfeat, dur, tpad, c2t, cand)
        loss = F.cross_entropy(sp.reshape(-1, 3), gold.reshape(-1), ignore_index=-100, weight=torch.tensor([1.0, 3.0, 3.0], device=dev)) + F.cross_entropy(song, is_song)
        opt.zero_grad(); loss.backward(); torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0); opt.step(); sched.step(); tot += loss.item(); step += 1
        if dev == 'mps' and step % 10 == 0: torch.mps.empty_cache()
    if ep % 3 == 2 or ep == args.epochs - 1:
        print(f'ep {ep+1} loss {tot/steps_per:.3f} eval {evaluate(eval_rows)} dev {evaluate(dev_rows)} zs {evaluate(zs_rows)} {time.time()-t0:.0f}s', flush=True)
torch.save({'state': model.state_dict(), 'plm': args.plm, 'args': vars(args)}, find(args.save))
