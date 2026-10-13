"""Span model: propose candidate spans, let the encoder say song / performer / neither for each.

Whole candidates are judged, so an answer is never a fragment of a name.
"""
import unicodedata
import torch, torch.nn as nn
import tagger
from tagger import SEG, norm, fold, encode, features, depth_feats, char_class, dur_bucket, MAXLEN, NFEAT

OPEN, CLOSE = '《「『【[（(“"〈<', '》」』】]）)”"〉>'
KEYWORDS = ['翻唱', '翻自', 'cover', 'feat.', 'feat', 'ft.', '合唱', '演唱', '原唱', '献唱', '弹唱', '演绎', '共唱',
            '对唱', '主题曲', '片尾曲', '片头曲', '插曲', '推广曲', '纯享', '现场', 'live', '版', 'mv', '官方',
            '完整', '首唱', '再唱', '一曲', '歌曲', '唱']
MAXCAND = 96


def is_delim(c):
    if c < ' ': return True
    return unicodedata.category(c)[0] in 'PZS' or c == '丨'


def candidates(chars, segs, spans):
    """-> sorted list of (start, end) half-open spans over chars."""
    text = ''.join(fold(c) for c in chars)
    out = set()

    def add(a, b):
        while a < b and chars[a] <= ' ': a += 1
        while b > a and chars[b - 1] <= ' ': b -= 1
        if b > a and b - a <= 40: out.add((a, b))

    title = None
    needles = []
    for seg, a, b in spans:
        if seg == 't': title = (a, b)
        else:
            add(a, b)
            s = text[a:b].strip()
            if len(s) >= 2 or (seg == 'm' and s): needles.append(s)
    if title:
        a, b = title
        # bracket contents
        stack = []
        for i in range(a, b):
            c = chars[i]
            k = CLOSE.find(c)
            if k >= 0 and stack and stack[-1][0] == k:
                add(stack.pop()[1] + 1, i)
            elif c in OPEN:
                stack.append((OPEN.index(c), i))
        # known strings: other fields and singers' names
        cuts = set()
        for s in set(needles):
            k = text.find(s, a)
            while 0 <= k < b:
                if k + len(s) <= b:
                    add(k, k + len(s)); cuts.add((k, k + len(s)))
                k = text.find(s, k + 1)
        if tagger.LEX:
            for i in range(a, b):
                for L in range(min(tagger.LEXMAX, b - i), 1, -1):
                    w = text[i:i + L]
                    if w in tagger.LEX:
                        if w[0].isascii() and ((i > a and text[i - 1].isascii() and text[i - 1].isalnum()) or
                                               (i + L < b and text[i + L].isascii() and text[i + L].isalnum())):
                            continue
                        add(i, i + L); cuts.add((i, i + L))
                        break
        low = text
        for kw in KEYWORDS:
            k = low.find(kw, a)
            while 0 <= k < b:
                cuts.add((k, k + len(kw)))
                k = low.find(kw, k + 1)
        # delimiter-separated pieces, runs of latin words, and what is left between known strings
        pieces = []
        i = a
        while i < b:
            if is_delim(chars[i]): i += 1; continue
            j = i
            while j < b and not is_delim(chars[j]): j += 1
            pieces.append((i, j)); i = j
        for k, (i, j) in enumerate(pieces):
            add(i, j)
            for n in range(1, 4):  # "Golden Hour", "Taylor Swift"
                if k + n < len(pieces) and all(chars[x] == ' ' for x in range(pieces[k + n - 1][1], pieces[k + n][0])) \
                        and pieces[k + n][0] - pieces[k + n - 1][1] == 1:
                    add(i, pieces[k + n][1])
                else:
                    break
            inner = sorted(c for c in cuts if c[0] >= i and c[1] <= j)
            edges = [i] + [e for c in inner for e in c] + [j]
            edges = sorted(set(edges))
            for x in range(len(edges)):
                for y in range(x + 1, min(x + 4, len(edges))):
                    if (edges[x], edges[y]) != (i, j): add(edges[x], edges[y])
    cands = sorted(out)
    if len(cands) > MAXCAND:
        keep = [c for c in cands if not title or c[0] >= title[1]]
        rest = sorted((c for c in cands if title and c[0] < title[1]), key=lambda c: (c[1] - c[0] > 12, c[0]))
        cands = sorted(keep + rest[:MAXCAND - len(keep)])
    return cands


def gold_classes(row, chars, segs, spans, cands):
    """Class per candidate (0 none, 1 song, 2 performer) and whether every gold name is covered."""
    lab = row['label']
    if not lab or not lab.get('song'):
        return [0] * len(cands), 0, True
    song = norm(lab['song'])
    up = None
    perf = set()
    for p in lab.get('performers') or []:
        if p.strip().upper() in ('UP主', 'UP'): up = norm(row['up']); perf.add(up)
        else: perf.add(norm(p))
    cls, seen = [], set()
    for a, b in cands:
        k = norm(''.join(chars[a:b]))
        if k and k == song and segs[a] in (SEG['t'], SEG['g'], SEG['m']): cls.append(1); seen.add(k)
        elif k and k in perf and segs[a] != SEG['m']: cls.append(2); seen.add(k)
        else: cls.append(0)
    complete = song in seen and all(p in seen for p in perf if p)
    # 2 = the uploader's own version (nobody else is heard), 1 = singers the video names
    return cls, 2 if up and perf == {up} else 1, complete


class SpanModel(nn.Module):
    def __init__(self, nvocab, d=128, layers=4, heads=4, ff=256, drop=0.1, cross=True):
        super().__init__()
        self.enc = tagger.Tagger(nvocab, d, layers, heads, ff, drop)
        self.width = nn.Embedding(41, 16)
        self.proj = nn.Sequential(nn.Linear(3 * d + 16, d), nn.GELU(), nn.Dropout(drop))
        # candidates look at each other and at the whole video before being judged
        self.cross = nn.TransformerEncoderLayer(d, heads, ff, drop, activation='gelu', batch_first=True, norm_first=True) if cross else None
        self.out = nn.Linear(d, 3)

    def forward(self, ids, segs, cls, feats, dur, pad, cand):
        """cand: (B, C, 2) start/end (end exclusive), padded with 0,0 -> logits (B, C, 3), is_song (B, 2), h"""
        _, song, h = self.enc(ids, segs, cls, feats, dur, pad)
        B, C, _ = cand.shape
        d = h.size(-1)
        a, b = cand[..., 0], cand[..., 1]
        ha = h.gather(1, a[..., None].expand(B, C, d))
        hb = h.gather(1, (b - 1).clamp(min=0)[..., None].expand(B, C, d))
        csum = torch.cat([h.new_zeros(B, 1, d), h.cumsum(1)], 1)
        mean = (csum.gather(1, b[..., None].expand(B, C, d)) - csum.gather(1, a[..., None].expand(B, C, d))) \
            / (b - a).clamp(min=1)[..., None]
        w = self.width((b - a).clamp(0, 40))
        x = self.proj(torch.cat([ha, hb, mean, w], -1))
        if self.cross is not None:
            x = torch.cat([h[:, :1], x], 1)
            mask = torch.cat([b.new_zeros(B, 1, dtype=torch.bool), b == 0], 1)
            x = self.cross(x, src_key_padding_mask=mask)[:, 1:]
        return self.out(x), song, h


def tensorize(rows, vocab, with_labels=True):
    items = []
    for r in rows:
        chars, segs, spans = encode(r)
        f = features(chars, segs, spans)
        dp = depth_feats(chars)
        cands = candidates(chars, segs, spans)
        it = {'row': r, 'chars': chars, 'ids': vocab.ids(chars), 'segs': segs,
              'cls': [char_class(c) for c in chars],
              'feats': [fi + [float(x), float(y)] for fi, (x, y) in zip(f, dp)],
              'dur': dur_bucket(r.get('dur') or 0), 'cands': cands}
        if with_labels:
            it['gold'], it['is_song'], it['complete'] = gold_classes(r, chars, segs, spans, cands)
        items.append(it)
    return items


def collate(items, device):
    base = tagger.collate([{k: v for k, v in i.items() if k not in ('tags', 'is_song')} for i in items], device)[:6]
    C = max(1, max(len(i['cands']) for i in items))
    cand = torch.tensor([[list(c) for c in i['cands']] + [[0, 0]] * (C - len(i['cands'])) for i in items], device=device)
    out = base + [cand]
    if 'gold' in items[0]:
        out.append(torch.tensor([i['gold'] + [-100] * (C - len(i['gold'])) for i in items], device=device))
        out.append(torch.tensor([i['is_song'] for i in items], device=device))
    return out


def decode(item, span_p, song_p, thr=0.5):
    """span_p: (C, 3) probabilities; song_p: (2,) -> None or (song, [performers])"""
    if song_p[0].item() > thr or not item['cands']:
        return None
    own = song_p[2].item() > song_p[1].item()
    chars, segs, cands = item['chars'], item['segs'], item['cands']
    text = lambda c: ''.join(chars[c[0]:c[1]]).strip()
    # the same wording found in several places supports itself
    best = {}
    for k, c in enumerate(cands):
        n = norm(text(c))
        if not n: continue
        for cl in (1, 2):
            p = span_p[k, cl].item()
            e = best.setdefault((cl, n), [0.0, c, 0.0])
            if p > e[0]: e[0] = p
            if segs[c[0]] == SEG['t'] and p >= e[2]: e[1], e[2] = c, p
    songs = sorted(((v[0], n, v[1]) for (cl, n), v in best.items() if cl == 1), reverse=True)
    if not songs or songs[0][0] < 0.3:
        return None
    song = songs[0]
    perf = sorted(((v[0], n, v[1]) for (cl, n), v in best.items() if cl == 2 and v[0] >= thr and n != song[1]), reverse=True)
    chosen = []
    for p, n, c in perf:
        # a name inside (or around) a better-scored name at the same place is the same mention
        if any(c[0] < o[2][1] and o[2][0] < c[1] for o in chosen): continue
        chosen.append((p, n, c))
    chosen.sort(key=lambda o: o[2][0])
    if own:
        return text(song[2]), [item['row']['up']]
    return text(song[2]), [text(o[2]) for o in chosen]


def confidence(item, span_p, song_p, ans):
    """How sure a decoded answer is, 0-1: the weakest of "a song", "this name", "these performers", "nobody else"."""
    if ans is None: return 0.0
    chars, cands = item['chars'], item['cands']
    best = {}
    for k, c in enumerate(cands):
        n = norm(''.join(chars[c[0]:c[1]]).strip())
        if not n: continue
        e = best.setdefault(n, [0.0, 0.0])
        e[0] = max(e[0], span_p[k, 1].item()); e[1] = max(e[1], span_p[k, 2].item())
    song = norm(ans[0]); kind = song_p[1].item() + song_p[2].item() + 1e-9
    sure = min(1 - song_p[0].item(), best.get(song, [0, 0])[0])
    if song_p[2].item() > song_p[1].item(): return min(sure, song_p[2].item() / kind)
    sure = min(sure, song_p[1].item() / kind)
    chosen = [norm(p) for p in ans[1]]
    for p in chosen: sure = min(sure, best.get(p, [0, 1])[1])
    for n, (a, b) in best.items():
        if a <= 0.05 and b <= 0.05: continue
        if n == song or any(c in n or n in c for c in chosen): continue
        sure = min(sure, 1 - b)
    return sure
