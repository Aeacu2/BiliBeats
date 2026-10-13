"""Export a fine-tuned span model for the app.  python3 export_plm.py lert.pt outdir [--int8] [--prune-vocab]

song_model.bin : uint32 header length, JSON header, tensor data.
                 Matrices are float16, or with --int8 one int8 row per output unit with a float32 scale.
song_vocab.txt : the tokenizer's tables;  song_singers.txt : the singer lexicon
song_model.json: a stamp naming this copy of the model
reference.json : videos with what this model reads in them, for the Dart port to reproduce.
"""
import json, os, struct, sys, warnings; warnings.filterwarnings('ignore')
import numpy as np, torch, torch.nn.functional as F
import plm, tagger, spans
find = tagger.find
ck = torch.load(find(sys.argv[1]), map_location='cpu'); out = sys.argv[2]; int8 = '--int8' in sys.argv
os.makedirs(out, exist_ok=True)
path = find(ck['plm']); cfg = json.load(open(path + '/config.json'))
modern = cfg['model_type'] == 'modernbert'
assert modern or cfg['model_type'] == 'bert', 'the app runs BERT and ModernBERT encoders'
tagger.load_lexicon(json.load(open(find('lexicon.json'))))
model = plm.PLMSpan(path); model.load_state_dict(ck['state']); model.eval()
wp = plm.make_tok(path)
keep = None
prune = '--prune-vocab' in sys.argv
if modern and not prune:
    itos = [None] * len(wp.stoi)
    for t, i in wp.stoi.items(): itos[i] = t
    merges = sorted(wp.rank, key=wp.rank.get)
    tables = {'tokens': itos, 'merges': [list(m) for m in merges], 'cls': wp.cls, 'sep': wp.sep, 'unk': wp.unk}
if modern and prune:
    # Only the part of the 256k vocabulary that titles like ours use is shipped: the tokens and
    # merges met in the corpus (bpe_used.json, written by vocab_used.py), every single character
    # of the scripts we see, and the bytes that spell anything else.
    used = json.load(open(find('bpe_used.json')))
    itos = [None] * len(wp.stoi)
    for t, i in wp.stoi.items(): itos[i] = t
    want = set(used['ids']) | {wp.cls, wp.sep, wp.unk, 0}
    merges = [tuple(m) for m in used['merges']]
    for a, b in merges: want |= {wp.stoi[a], wp.stoi[b], wp.stoi[a + b]}
    for t, i in wp.stoi.items():
        if len(t) == 6 and t.startswith('<0x'): want.add(i)
        elif len(t) == 1 and (t < '\u0250' or '\u3000' <= t <= '\u30ff' or '\u4e00' <= t <= '\u9fff' or '\uff00' <= t <= '\uffef'): want.add(i)
    keep = sorted(want); remap = {old: new for new, old in enumerate(keep)}
    merges.sort(key=lambda m: wp.rank[m])
    emb = model.bert.get_input_embeddings()
    small = torch.nn.Embedding(len(keep), emb.weight.shape[1]); small.weight.data.copy_(emb.weight.data[keep])
    model.bert.set_input_embeddings(small)
    wp.stoi = {itos[old]: new for old, new in remap.items()}
    wp.rank = {m: r for r, m in enumerate(merges)}
    wp.cls, wp.sep, wp.unk = remap[wp.cls], remap[wp.sep], remap[wp.unk]
    tables = {'tokens': [itos[i] for i in keep], 'merges': [list(m) for m in merges], 'cls': wp.cls, 'sep': wp.sep, 'unk': wp.unk}
index, blob = [], bytearray()
for name, t in model.state_dict().items():
    if 'pooler' in name or name.endswith('position_ids') or name.endswith('token_type_ids'): continue
    a = t.float().numpy()
    if name == 'bert.embeddings.position_embeddings.weight': a = a[:tagger.MAXLEN + 2]
    if name == 'bert.embeddings.token_type_embeddings.weight': a = a[:1]
    e = {'name': name, 'shape': list(a.shape), 'offset': len(blob)}
    if int8 and a.ndim == 2 and a.size >= 4096:
        scale = np.abs(a).max(axis=1) / 127.0; scale[scale == 0] = 1.0
        q = np.clip(np.round(a / scale[:, None]), -127, 127).astype('<i1')
        e['q'] = 8; blob += scale.astype('<f4').tobytes(); blob += q.tobytes()
        t.copy_(torch.from_numpy(q.astype('float32') * scale[:, None]) if a.shape == tuple(t.shape) else t)   # the reference is what the app computes
    else:
        blob += a.astype('<f2').tobytes()
        if a.shape == tuple(t.shape): t.copy_(torch.from_numpy(a.astype('<f2').astype('float32')))
    while len(blob) % 4: blob.append(0)
    index.append(e)
header = json.dumps({'arch': cfg['model_type'], 'hidden': cfg['hidden_size'], 'layers': cfg['num_hidden_layers'], 'heads': cfg['num_attention_heads'],
                     'head': model.song.in_features, 'tensors': index}, separators=(',', ':')).encode()
header += b' ' * (-(len(header) + 4) % 4)
with open(out + '/song_model.bin', 'wb') as f:
    f.write(struct.pack('<I', len(header))); f.write(header); f.write(blob)
if modern: json.dump(tables, open(out + '/song_vocab.txt', 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))
else: open(out + '/song_vocab.txt', 'w', encoding='utf-8').write('\n'.join(wp.itos))
open(out + '/song_singers.txt', 'w', encoding='utf-8').write('\n'.join(sorted(tagger.LEX)))
import hashlib
json.dump({'model': hashlib.sha256(open(out + '/song_model.bin', 'rb').read()).hexdigest()[:16], 'encoder': ck['plm'],
           'bytes': os.path.getsize(out + '/song_model.bin')}, open(out + '/song_model.json', 'w'))   # names this copy; the app unpacks anew when it changes
rows = [r for r in json.load(open(find('eval.json'))) if r['set'] in ('dev', 'zs')]
items = plm.tensorize(rows, wp, with_labels=False); ref = []
with torch.no_grad():
    for it in items:
        sp, song = model(*plm.collate([it], 'cpu')[:7])
        sp, song = F.softmax(sp, -1)[0], F.softmax(song, -1)[0]
        ans = spans.decode(it, sp, song); r = it['row']
        ref.append({'title': r['title'], 'up': r['up'], 'dur': r['dur'], 'tags': r['tags'], 'music': r.get('music'),
                    'tokens': it['tok'], 'conf': round(spans.confidence(it, sp, song, ans), 4), 'pNone': round(song[0].item(), 4), 'pOwn': round(song[2].item(), 4),
                    'answer': None if ans is None else {'song': ans[0], 'performers': ans[1]}})
json.dump(ref, open(out + '/reference.json', 'w'), ensure_ascii=False)
print(f'{os.path.getsize(out + "/song_model.bin") / 1e6:.1f} MB, {len(ref)} reference videos')
