"""Model vs rules on the validation set, with the model's confidence. python3 analyse.py s5.pt"""
import json, os, re, sys, torch, torch.nn.functional as F
from collections import Counter
import tagger, spans
from tagger import norm, gold_key, answer_key, SEG
S = os.path.dirname(os.path.abspath(__file__)); torch.set_num_threads(2)
def load(p):
    ck = torch.load(S + '/' + p, map_location='cpu'); a = ck['args']
    vocab = tagger.Vocab(); vocab.itos = ck['vocab']; vocab.stoi = {c: i for i, c in enumerate(vocab.itos)}
    m = spans.SpanModel(len(vocab.itos), d=a['d'], layers=a['layers'], ff=a['ff'], cross=not a.get('no_cross'))
    m.load_state_dict(ck['state']); m.eval(); return m, vocab
tagger.load_lexicon(json.load(open(S + '/lexicon.json')))
models = [load(p) for p in sys.argv[1:]]
dev = json.load(open(S + '/dev.json')); rules = json.load(open(S + '/dev_rules.json'))
def rk(o): return None if 't' not in o else (norm(o['t']), frozenset(norm(p) for p in re.split(r'\s*&\s*|\s*/\s*|、', o['a'])))
preds = []
with torch.no_grad():
    its = [spans.tensorize(dev, v) for _, v in models]
    for k in range(len(dev)):
        sps, songs = [], []
        for (m, v), items in zip(models, its):
            it = items[k]
            ids, segs, cls, feats, dur, pad, cand = spans.collate([it], 'cpu')[:7]
            sp, song, _ = m(ids, segs, cls, feats, dur, pad, cand)
            sps.append(F.softmax(sp, -1)[0]); songs.append(F.softmax(song, -1)[0])
        sp, song = sum(sps) / len(sps), sum(songs) / len(songs)
        it = its[0][k]
        ans = spans.decode(it, sp, song)
        conf = 0.0
        if ans is not None:
            # weakest link: is it a song, is this the song, is each performer right, is nobody left out
            ps = {}
            for j, c in enumerate(it['cands']):
                n = norm(''.join(it['chars'][c[0]:c[1]]))
                ps[n] = max(ps.get(n, (0, 0)), (sp[j, 1].item(), sp[j, 2].item()), key=lambda t: t) if n in ps else (sp[j, 1].item(), sp[j, 2].item())
                ps[n] = (max(ps[n][0], sp[j, 1].item()), max(ps[n][1], sp[j, 2].item()))
            chosen = {norm(p) for p in ans[1]}
            conf = min([1 - song[0].item(), ps.get(norm(ans[0]), (0, 0))[0]] + [ps.get(p, (0, 1))[1] for p in chosen]
                       + [1 - v[1] for n, v in ps.items() if n not in chosen and n != norm(ans[0])] or [1])
        preds.append((ans, conf))
g = [gold_key(r) for r in dev]; m = [answer_key(a) for a, _ in preds]; u = [rk(o) for o in rules]
print('model exact', sum(a == b for a, b in zip(g, m)), 'rules exact', sum(a == b for a, b in zip(g, u)), 'of', len(dev))
for name, p in (('model', m), ('rules', u)):
    ans = [(a, b) for a, b in zip(g, p) if b is not None]
    print(f'  {name}: answers {len(ans)}, right {sum(a == b for a, b in ans)}, wrong {sum(a != b for a, b in ans)}; silent on {sum(1 for a, b in zip(g, p) if b is None and a is not None)} real songs')
for thr in (0.5, 0.7, 0.8, 0.9, 0.95):
    ans = [(a, b) for a, b, (_, c) in zip(g, m, preds) if b is not None and c >= thr]
    print(f'  model conf>={thr}: answers {len(ans)}, right {sum(a == b for a, b in ans)}, wrong {sum(a != b for a, b in ans)}')
agree = [(a, b) for a, b, c in zip(g, m, u) if b == c and b is not None]
print('  both agree and answer:', len(agree), 'right', sum(a == b for a, b in agree))
json.dump([{'bvid': r['bvid'], 'ans': a, 'conf': c} for r, (a, c) in zip(dev, preds)], open(S + '/dev_model.json', 'w'), ensure_ascii=False)
