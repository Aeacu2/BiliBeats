"""What a fine-tuned model reads in each video of a set (several models: their average).

  python3 read.py eval.json reads.json mmbert.pt

Per video: the decoded answer, its confidence, and every name weighed with [text, P(song), P(performer)]."""
import json, os, sys, warnings; warnings.filterwarnings('ignore')
import plm, tagger, spans, torch, torch.nn.functional as F
from tagger import norm
find = tagger.find
def load(p):
    ck = torch.load(find(p), map_location='cpu')
    m = plm.PLMSpan(find(ck['plm'])); m.load_state_dict(ck['state']); m.eval()
    return m, plm.make_tok(find(ck['plm']))
def read(rows, weights, dev='cpu'):
    tagger.load_lexicon(json.load(open(find('lexicon.json'))))
    models = [load(w) for w in weights]; out = []
    for m, _ in models: m.to(dev)
    its = [plm.tensorize(rows, wp, with_labels=False) for _, wp in models]
    with torch.no_grad():
        for k in range(0, len(rows), 32):
            sps, songs = 0, 0
            for (m, _), items in zip(models, its):
                sp, song = m(*plm.collate(items[k:k + 32], dev)[:7])
                sps = sps + F.softmax(sp, -1).cpu() / len(models); songs = songs + F.softmax(song, -1).cpu() / len(models)
            for j, it in enumerate(its[0][k:k + 32]):
                sp, song = sps[j], songs[j]
                ans = spans.decode(it, sp, song); best = {}
                for q, c in enumerate(it['cands']):
                    t = ''.join(it['chars'][c[0]:c[1]]).strip(); n = norm(t)
                    if not n: continue
                    e = best.setdefault(n, [t, 0.0, 0.0]); e[1] = max(e[1], sp[q, 1].item()); e[2] = max(e[2], sp[q, 2].item())
                out.append({'bvid': it['row']['bvid'], 'ans': ans, 'conf': spans.confidence(it, sp, song, ans), 'p_none': song[0].item(), 'p_named': song[1].item(), 'p_own': song[2].item(),
                            'cands': sorted(([t, round(a, 3), round(b, 3)] for t, a, b in best.values() if max(a, b) > 0.05), key=lambda x: -max(x[1], x[2]))})
    return out
if __name__ == '__main__':
    rows = json.load(open(find(sys.argv[1]))) if sys.argv[1].endswith('.json') else [json.loads(l) for l in open(find(sys.argv[1])) if l.strip()]
    json.dump(read(rows, sys.argv[3:], 'mps' if torch.backends.mps.is_available() else 'cpu'), open(find(sys.argv[2]), 'w'), ensure_ascii=False)
