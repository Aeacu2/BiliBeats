"""Character tagger that copies the song and its performers out of a video's metadata.

Input  : title, uploader, tags, Bilibili's recognised music (title, original artists), length.
Output : per character O / B-SONG / I-SONG / B-PERF / I-PERF, plus "is this one song" from [CLS].
Everything the model answers is a span of its input, so it cannot invent a name.
"""
import json, math, os, random, re, unicodedata
import torch, torch.nn as nn, torch.nn.functional as F

S = os.path.dirname(os.path.abspath(__file__))


def find(name):
    """Where a file of this toolkit is: labelled data in data/, and what is too big for the repository
    (pretrained encoders, checkpoints, caches) in the directory $SONG_MODEL_WORK names."""
    work = os.environ.get('SONG_MODEL_WORK', os.path.join(S, 'work'))
    for d in (S, os.path.join(S, 'data'), work):
        if os.path.exists(os.path.join(d, name)): return os.path.join(d, name)
    return os.path.join(work, name)
SEG = {'cls': 0, 't': 1, 'u': 2, 'g': 3, 'm': 4, 'a': 5}
O, BS, IS, BP, IP = range(5)
MAXLEN = 256
NFEAT = 11
LEX, LEXMAX = set(), 0


def load_lexicon(names):
    global LEX, LEXMAX
    LEX = {''.join(fold(c) for c in n).strip() for n in names}
    LEX = {n for n in LEX if 2 <= len(n) <= 16 and not n.isdigit()}
    LEXMAX = max((len(n) for n in LEX), default=0)


def fold(c):
    """One character, case and width folded. Kept simple so the app can do exactly the same."""
    o = ord(c)
    if 0xFF01 <= o <= 0xFF5E: c = chr(o - 0xFEE0)
    elif o == 0x3000 or o == 0xA0: c = ' '
    c = c.lower()
    return c[0] if c else ' '


def norm(s):
    return ''.join(f for f in (fold(c) for c in s) if f.isalnum())


def char_class(c):
    c = fold(c)
    if '\u4e00' <= c <= '\u9fff': return 0
    if '\u3040' <= c <= '\u30ff' or '\uac00' <= c <= '\ud7a3': return 1
    if '0' <= c <= '9': return 3
    if c.isalpha(): return 2
    if c in ' \t\n\r': return 4
    if c in '《》': return 5
    if c in '【】[]「」『』()<>“”"': return 6
    return 7


def encode(row):
    """-> chars, segs, field spans [(seg, start, end)] with one span per tag/artist."""
    chars, segs, spans = ['\x01'], [SEG['cls']], []

    def add(seg, text, sep):
        text = text[:120] if seg == 't' else text[:40]
        start = len(chars)
        chars.extend(text); segs.extend([SEG[seg]] * len(text))
        spans.append((seg, start, len(chars)))
        chars.append(sep); segs.append(SEG[seg])

    add('t', row['title'], '\x02')
    add('u', row['up'], '\x03')
    for g in (row.get('tags') or [])[:8]:
        add('g', g, '\x04')
    m = row.get('music')
    if m and m.get('t'):
        add('m', m['t'], '\x05')
        for a in (m.get('a') or [])[:4]:
            add('a', a, '\x06')
    chars, segs = chars[:MAXLEN], segs[:MAXLEN]
    spans = [(s, a, min(b, MAXLEN)) for s, a, b in spans if a < MAXLEN]
    return chars, segs, spans


def features(chars, segs, spans):
    """Cross-field evidence per character: does this text also occur in another field?"""
    n = len(chars)
    f = [[0.0] * NFEAT for _ in range(n)]
    text = ''.join(fold(c) for c in chars)
    by = {}
    for seg, a, b in spans:
        by.setdefault(seg, []).append((a, b))
    title = by.get('t', [(1, 1)])[0]

    def mark(needle_span, hay_span, i_needle, i_hay):
        a, b = needle_span
        s = text[a:b].strip()
        if len(s) < 2 and not (len(s) == 1 and '一' <= s <= '鿿'):
            return
        ha, hb = hay_span
        hay = text[ha:hb]
        k = hay.find(s)
        hit = False
        while k >= 0:
            hit = True
            for j in range(ha + k, ha + k + len(s)):
                f[j][i_hay] = 1.0
            k = hay.find(s, k + 1)
        if hit and i_needle is not None:
            for j in range(a, b):
                f[j][i_needle] = 1.0

    for g in by.get('g', []):
        mark(g, title, 0, 1)                      # tag occurs in title
        for u in by.get('u', []): mark(g, u, 2, 2)  # tag occurs in uploader / uploader holds a tag
    for m in by.get('m', []):
        mark(m, title, 3, 4)                      # recognised song occurs in title
        for g in by.get('g', []): mark(m, g, 3, 5)  # ... or equals/occurs in a tag
    for a in by.get('a', []):
        mark(a, title, 6, 7)                      # original artist occurs in title
        for g in by.get('g', []): mark(a, g, 6, 8)
    for u in by.get('u', []):
        mark(u, title, 9, 9)                      # uploader's name occurs in title
    if LEX:                                       # a known singer's name stands here
        for seg, a, b in spans:
            i = a
            while i < b:
                hit = 0
                for L in range(min(LEXMAX, b - i), 1, -1):
                    w = text[i:i + L]
                    if w in LEX:
                        # latin names must not be cut out of a longer word
                        if w[0].isascii() and ((i > a and text[i - 1].isascii() and text[i - 1].isalnum()) or
                                               (i + L < b and text[i + L].isascii() and text[i + L].isalnum())):
                            continue
                        hit = L; break
                if hit:
                    for j in range(i, i + hit): f[j][10] = 1.0
                    i += hit
                else:
                    i += 1
    return f


def depth_feats(chars):
    """Inside 《》 / inside other brackets, per character."""
    out, book, other = [], 0, 0
    for c in chars:
        if c == '《': book += 1
        if c in '【[「『(（': other += 1
        out.append((min(book, 1), min(other, 1)))
        if c == '》': book = max(0, book - 1)
        if c in '】]」』)）': other = max(0, other - 1)
        if c in '\x02\x03\x04\x05\x06': book = other = 0
    return out


def find_all(hay, needle):
    k, out = hay.find(needle), []
    while k >= 0:
        out.append(k); k = hay.find(needle, k + 1)
    return out


def align(row, chars, segs, spans):
    """Gold tags from the label. Returns (tags, is_song, complete)."""
    tags = [O] * len(chars)
    lab = row['label']
    if not lab or not lab.get('song'):
        return tags, 0, True
    text = ''.join(fold(c) for c in chars)
    complete = True

    def paint(s, segs_ok, b, i):
        s = ''.join(fold(c) for c in s).strip()
        if not s: return False
        hit = False
        for seg, a, e in spans:
            if seg not in segs_ok: continue
            for k in find_all(text[a:e], s):
                # whole-field match for short fields; anywhere in the title
                if seg != 't' and not (k == 0 and len(s) == e - a) and seg != 'u':
                    if seg in 'ga' and len(s) != e - a: continue
                st = a + k
                if any(tags[j] != O for j in range(st, st + len(s))): continue
                tags[st] = b
                for j in range(st + 1, st + len(s)): tags[j] = i
                hit = True
        return hit

    if not paint(lab['song'], ('t',), BS, IS):
        if not paint(lab['song'], ('g', 'm'), BS, IS):
            complete = False
    else:
        paint(lab['song'], ('g', 'm'), BS, IS)
    for p in lab.get('performers') or []:
        if p.strip().upper() in ('UP主', 'UP'):
            p = row['up']
            ok = paint(p, ('u',), BP, IP)
        else:
            ok = paint(p, ('t',), BP, IP)
            ok = paint(p, ('g', 'a'), BP, IP) or ok
            if norm(p) == norm(row['up']) or not ok:
                ok = paint(p, ('u',), BP, IP) or ok
        complete = complete and ok
    return tags, 1, complete


class Vocab:
    def __init__(self, chars=None):
        self.itos = ['\x00', '\x7f'] + [chr(i) for i in range(1, 7)] + sorted(c for c in (chars or []) if c >= ' ' and c != '\x7f')
        self.stoi = {c: i for i, c in enumerate(self.itos)}

    def ids(self, chars):
        return [self.stoi.get(fold(c) if c >= ' ' else c, 1) for c in chars]


def dur_bucket(d):
    for i, lim in enumerate((60, 120, 180, 240, 300, 360, 480, 600, 900)):
        if d < lim: return i
    return 9


class Tagger(nn.Module):
    def __init__(self, nvocab, d=128, layers=4, heads=4, ff=256, drop=0.1):
        super().__init__()
        self.tok = nn.Embedding(nvocab, d)
        self.seg = nn.Embedding(len(SEG), d)
        self.pos = nn.Embedding(MAXLEN, d)
        self.cls = nn.Embedding(8, d)
        self.dur = nn.Embedding(10, d)
        self.feat = nn.Linear(NFEAT + 2, d)
        self.norm = nn.LayerNorm(d)
        self.drop = nn.Dropout(drop)
        layer = nn.TransformerEncoderLayer(d, heads, ff, drop, activation='gelu', batch_first=True, norm_first=True)
        self.enc = nn.TransformerEncoder(layer, layers, enable_nested_tensor=False)
        self.out_norm = nn.LayerNorm(d)
        self.tag = nn.Linear(d, 5)
        self.song = nn.Linear(d, 3)
        self.lm = nn.Linear(d, nvocab)

    def forward(self, ids, segs, cls, feats, dur, pad):
        pos = torch.arange(ids.size(1), device=ids.device)[None]
        x = self.tok(ids) + self.seg(segs) + self.pos(pos) + self.cls(cls) + self.feat(feats)
        x[:, 0] = x[:, 0] + self.dur(dur)
        x = self.drop(self.norm(x))
        h = self.out_norm(self.enc(x, src_key_padding_mask=pad))
        return self.tag(h), self.song(h[:, 0]), h


def tensorize(rows, vocab, with_labels=True):
    items = []
    for r in rows:
        chars, segs, spans = encode(r)
        f = features(chars, segs, spans)
        dp = depth_feats(chars)
        feats = [fi + [float(a), float(b)] for fi, (a, b) in zip(f, dp)]
        it = {'row': r, 'chars': chars, 'ids': vocab.ids(chars), 'segs': segs, 'spans': spans,
              'cls': [char_class(c) for c in chars], 'feats': feats, 'dur': dur_bucket(r.get('dur') or 0)}
        if with_labels:
            it['tags'], it['is_song'], it['complete'] = align(r, chars, segs, spans)
        items.append(it)
    return items


def collate(items, device):
    n = max(len(i['ids']) for i in items)
    def pad(key, fill):
        return torch.tensor([i[key] + [fill] * (n - len(i[key])) for i in items], device=device)
    ids, segs, cls = pad('ids', 0), pad('segs', 0), pad('cls', 7)
    feats = torch.tensor([i['feats'] + [[0.0] * (NFEAT + 2)] * (n - len(i['feats'])) for i in items], device=device)
    dur = torch.tensor([i['dur'] for i in items], device=device)
    mask = torch.tensor([[False] * len(i['ids']) + [True] * (n - len(i['ids'])) for i in items], device=device)
    out = [ids, segs, cls, feats, dur, mask]
    if 'tags' in items[0]:
        out.append(pad('tags', -100))
        out.append(torch.tensor([i['is_song'] for i in items], device=device))
    return out


def decode(item, tag_logp, song_logp, thr=0.5):
    """-> None or (song, [performers]) read off the predicted tags."""
    if song_logp[1].exp().item() < thr:
        return None
    pred = tag_logp.argmax(-1).tolist()
    prob = tag_logp.exp()
    chars, segs = item['chars'], item['segs']
    found = []  # (kind, text, score, seg, start)
    i = 0
    n = len(chars)
    while i < n:
        t = pred[i]
        if t in (BS, IS, BP, IP) and chars[i] >= ' ':
            kind = 'S' if t in (BS, IS) else 'P'
            inside = IS if kind == 'S' else IP
            j = i + 1
            while j < n and pred[j] == inside and segs[j] == segs[i] and chars[j] >= ' ':
                j += 1
            score = sum(prob[k, pred[k]].item() for k in range(i, j)) / (j - i)
            found.append((kind, ''.join(chars[i:j]).strip(), score, segs[i], i))
            i = j
        else:
            i += 1
    songs = [f for f in found if f[0] == 'S' and f[1]]
    if not songs:
        return None
    # the title's wording first, then the best-scored span
    songs.sort(key=lambda f: (f[3] != SEG['t'], -f[2]))
    perf, seen = [], set()
    for f in found:
        if f[0] != 'P' or not f[1]: continue
        k = norm(f[1])
        if k and k not in seen:
            seen.add(k); perf.append(f[1])
    return songs[0][1], perf


def answer_key(ans):
    return None if ans is None else (norm(ans[0]), frozenset(norm(p) for p in ans[1]))


def gold_key(row):
    lab = row['label']
    if not lab or not lab.get('song'):
        return None
    who = [row['up'] if p.strip().upper() in ('UP主', 'UP') else p for p in lab.get('performers') or []]
    return (norm(lab['song']), frozenset(norm(p) for p in who))
