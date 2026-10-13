"""Export a trained span model for the app: weights (float16), vocabulary, singer lexicon, and
reference answers the Dart port must reproduce.  python3 export.py s3.pt outdir"""
import json, os, struct, sys
import numpy as np, torch, torch.nn.functional as F
import tagger, spans

S = os.path.dirname(os.path.abspath(__file__))
ck = torch.load(os.path.join(S, sys.argv[1]), map_location='cpu')
out = sys.argv[2]
os.makedirs(out, exist_ok=True)
a = ck['args']
tagger.load_lexicon(json.load(open(S + '/lexicon.json')))
vocab = tagger.Vocab(); vocab.itos = ck['vocab']; vocab.stoi = {c: i for i, c in enumerate(vocab.itos)}
model = spans.SpanModel(len(vocab.itos), d=a['d'], layers=a['layers'], ff=a['ff'], cross=not a.get('no_cross'))
model.load_state_dict(ck['state']); model.eval()

skip = ('enc.lm.', 'enc.tag.')
index, blob = [], bytearray()
for name, t in model.state_dict().items():
    if name.startswith(skip): continue
    arr = t.numpy().astype('<f2')
    index.append({'name': name, 'shape': list(arr.shape), 'offset': len(blob)})
    blob += arr.tobytes()
header = json.dumps({'d': a['d'], 'layers': a['layers'], 'heads': 4, 'vocab': [ord(c) for c in vocab.itos],
                     'tensors': index}, separators=(',', ':')).encode()
with open(out + '/song_model.bin', 'wb') as f:
    f.write(struct.pack('<I', len(header))); f.write(header); f.write(blob)
open(out + '/song_singers.txt', 'w').write('\n'.join(sorted(tagger.LEX)))

rows = [json.loads(l) for l in open(S + '/test121.jsonl') if l.strip()] + json.load(open(S + '/dev.json'))
items = spans.tensorize(rows, vocab, with_labels=False)
ref = []
with torch.no_grad():
    for it in items:
        ids, segs, cls, feats, dur, pad, cand = spans.collate([it], 'cpu')[:7]
        sp, song, _ = model(ids, segs, cls, feats, dur, pad, cand)
        sp, song = F.softmax(sp, -1)[0], F.softmax(song, -1)[0]
        ans = spans.decode(it, sp, song)
        r = it['row']
        ref.append({'title': r['title'], 'up': r['up'], 'dur': r['dur'], 'tags': r['tags'], 'music': r.get('music'),
                    'cands': [list(c) for c in it['cands']], 'song_p': [round(x, 4) for x in song.tolist()],
                    'answer': None if ans is None else {'song': ans[0], 'performers': ans[1]}})
json.dump(ref, open(out + '/reference.json', 'w'), ensure_ascii=False)
print('model %.1f MB, lexicon %d names, %d reference rows' % (os.path.getsize(out + '/song_model.bin') / 1e6, len(tagger.LEX), len(ref)))
