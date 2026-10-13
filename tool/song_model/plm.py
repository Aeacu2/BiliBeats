"""A pretrained Chinese encoder under the span model.

The video is still laid out character by character (tagger.encode), so candidates, features and
decoding are those of spans.py. Characters are grouped into WordPiece tokens for the encoder and
each character reads the hidden state of the token that covers it.
"""
import json, os, unicodedata
import torch, torch.nn as nn
import tagger, spans
from tagger import fold, find, NFEAT


def is_cjk(c):
    o = ord(c)
    return (0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF or 0x20000 <= o <= 0x2A6DF or 0x2A700 <= o <= 0x2B73F
            or 0x2B740 <= o <= 0x2B81F or 0x2B820 <= o <= 0x2CEAF or 0xF900 <= o <= 0xFAFF or 0x2F800 <= o <= 0x2FA1F)


def is_punct(c):
    o = ord(c)
    if 33 <= o <= 47 or 58 <= o <= 64 or 91 <= o <= 96 or 123 <= o <= 126: return True
    return unicodedata.category(c)[0] in 'PS'


def is_space(c):
    return c in ' \t\n\r' or unicodedata.category(c) in ('Zs', 'Cc', 'Cf', 'Zl', 'Zp')


class WordPiece:
    def __init__(self, vocab_path):
        self.itos = [l.rstrip('\n') for l in open(vocab_path, encoding='utf-8')]
        self.stoi = {t: i for i, t in enumerate(self.itos)}
        self.unk, self.cls, self.sep = self.stoi['[UNK]'], self.stoi['[CLS]'], self.stoi['[SEP]']

    def tokens(self, chars):
        """chars: tagger.encode's sequence -> (token ids, char->token index)."""
        ids, c2t = [], [0] * len(chars)
        i, n = 0, len(chars)
        while i < n:
            c = chars[i]
            if c == '\x01': ids.append(self.cls); c2t[i] = len(ids) - 1; i += 1; continue
            if c < ' ' and c in '\x02\x03\x04\x05\x06': ids.append(self.sep); c2t[i] = len(ids) - 1; i += 1; continue
            f = fold(c)
            if is_space(f):
                c2t[i] = max(0, len(ids) - 1); i += 1; continue
            if is_cjk(f) or is_punct(f):
                ids.append(self.stoi.get(f, self.unk)); c2t[i] = len(ids) - 1; i += 1; continue
            j = i
            while j < n and chars[j] >= ' ' and not is_space(fold(chars[j])) and not is_cjk(fold(chars[j])) and not is_punct(fold(chars[j])): j += 1
            word = ''.join(fold(x) for x in chars[i:j])
            pieces, k, bad = [], 0, len(word) > 100
            while k < len(word) and not bad:
                e = len(word); cur = None
                while e > k:
                    s = word[k:e] if k == 0 else '##' + word[k:e]
                    if s in self.stoi: cur = (self.stoi[s], k, e); break
                    e -= 1
                if cur is None: bad = True
                else: pieces.append(cur); k = cur[2]
            if bad:
                ids.append(self.unk)
                for x in range(i, j): c2t[x] = len(ids) - 1
            else:
                for tid, a, b in pieces:
                    ids.append(tid)
                    for x in range(i + a, i + b): c2t[x] = len(ids) - 1
            i = j
        return ids, c2t


class HFTok:
    """Any fast tokenizer: each field is tokenized on its own, with the offsets it reports."""
    def __init__(self, path):
        from tokenizers import Tokenizer
        self.tk = Tokenizer.from_file(os.path.join(path, 'tokenizer.json'))
        self.tk.no_padding(); self.tk.no_truncation()
        cfg = json.load(open(os.path.join(path, 'config.json')))
        self.cls = cfg.get('cls_token_id', cfg.get('bos_token_id')); self.sep = cfg.get('sep_token_id', cfg.get('eos_token_id'))
        if self.cls == self.sep and cfg.get('bos_token_id') is not None: self.cls = cfg['bos_token_id']

    def tokens(self, chars):
        ids, c2t = [], [0] * len(chars)
        i, n = 0, len(chars)
        while i < n:
            c = chars[i]
            if c == '\x01': ids.append(self.cls); c2t[i] = len(ids) - 1; i += 1; continue
            if c < ' ': ids.append(self.sep); c2t[i] = len(ids) - 1; i += 1; continue
            j = i
            while j < n and chars[j] >= ' ': j += 1
            enc = self.tk.encode(''.join(chars[i:j]), add_special_tokens=False)
            last = max(0, len(ids) - 1)
            cover = [None] * (j - i)
            for tid, (a, b) in zip(enc.ids, enc.offsets):
                ids.append(tid)
                for x in range(a, b):
                    if cover[x] is None: cover[x] = len(ids) - 1
            for x in range(j - i):
                if cover[x] is None: cover[x] = last
                else: last = cover[x]
                c2t[i + x] = cover[x]
            i = j
        return ids, c2t


def make_tok(path):
    cfg = json.load(open(os.path.join(path, 'config.json')))
    if cfg.get('model_type') in ('bert', 'electra') and os.path.exists(os.path.join(path, 'vocab.txt')):
        return WordPiece(os.path.join(path, 'vocab.txt'))
    tk = json.load(open(os.path.join(path, 'tokenizer.json'), encoding='utf-8'))
    if (tk.get('pre_tokenizer') or {}).get('type') == 'Metaspace' and tk['model'].get('byte_fallback'):
        import bpe
        return bpe.CharBPE(path)      # mmBERT: the tokenizer the app implements
    return HFTok(path)


class PLMSpan(nn.Module):
    def __init__(self, path, drop=0.1, cross=True, head=256):
        super().__init__()
        from transformers import AutoModel
        self.bert = AutoModel.from_pretrained(path, torch_dtype=torch.float32)
        cfg = self.bert.config
        E = getattr(cfg, 'embedding_size', None) or cfg.hidden_size
        H = cfg.hidden_size
        self.seg = nn.Embedding(len(tagger.SEG), E)
        self.feat = nn.Linear(NFEAT + 2, E)
        self.dur = nn.Embedding(10, E)
        for m in (self.seg, self.dur): nn.init.normal_(m.weight, std=0.02)
        nn.init.normal_(self.feat.weight, std=0.02); nn.init.zeros_(self.feat.bias)
        d = head
        self.down = nn.Linear(H, d) if H != d else nn.Identity()
        self.song = nn.Linear(d, 3)
        self.width = nn.Embedding(41, 16)
        self.proj = nn.Sequential(nn.Linear(3 * d + 16, d), nn.GELU(), nn.Dropout(drop))
        self.cross = nn.TransformerEncoderLayer(d, 4, 2 * d, drop, activation='gelu', batch_first=True, norm_first=True) if cross else None
        self.out = nn.Linear(d, 3)

    def forward(self, tok, tseg, tfeat, dur, tpad, c2t, cand):
        emb = self.bert.get_input_embeddings()(tok) + self.seg(tseg) + self.feat(tfeat)
        emb[:, 0] = emb[:, 0] + self.dur(dur)
        ht = self.bert(inputs_embeds=emb, attention_mask=(~tpad).long()).last_hidden_state
        ht = self.down(ht)
        d = ht.size(-1)
        h = ht.gather(1, c2t[..., None].expand(-1, -1, d))        # per character
        B, C, _ = cand.shape
        a, b = cand[..., 0], cand[..., 1]
        ha = h.gather(1, a[..., None].expand(B, C, d))
        hb = h.gather(1, (b - 1).clamp(min=0)[..., None].expand(B, C, d))
        csum = torch.cat([h.new_zeros(B, 1, d), h.cumsum(1)], 1)
        mean = (csum.gather(1, b[..., None].expand(B, C, d)) - csum.gather(1, a[..., None].expand(B, C, d))) / (b - a).clamp(min=1)[..., None]
        x = self.proj(torch.cat([ha, hb, mean, self.width((b - a).clamp(0, 40))], -1))
        if self.cross is not None:
            x = torch.cat([ht[:, :1], x], 1)
            mask = torch.cat([b.new_zeros(B, 1, dtype=torch.bool), b == 0], 1)
            x = self.cross(x, src_key_padding_mask=mask)[:, 1:]
        return self.out(x), self.song(ht[:, 0])


def tensorize(rows, wp, with_labels=True):
    items = []
    for r in rows:
        chars, segs, sp = tagger.encode(r)
        f = tagger.features(chars, segs, sp); dp = tagger.depth_feats(chars)
        feats = [fi + [float(x), float(y)] for fi, (x, y) in zip(f, dp)]
        nf = len(feats[0])
        cands = spans.candidates(chars, segs, sp)
        tok, c2t = wp.tokens(chars)
        tseg, tfeat = [0] * len(tok), [[0.0] * nf for _ in tok]
        for i, t in enumerate(c2t):
            if chars[i] >= ' ' and not is_space(fold(chars[i])) or chars[i] < ' ':
                tseg[t] = segs[i]
                tfeat[t] = [max(x, y) for x, y in zip(tfeat[t], feats[i])]
        it = {'row': r, 'chars': chars, 'segs': segs, 'cands': cands, 'tok': tok, 'c2t': c2t, 'tseg': tseg, 'tfeat': tfeat,
              'dur': tagger.dur_bucket(r.get('dur') or 0)}
        if with_labels:
            it['gold'], it['is_song'], it['complete'] = spans.gold_classes(r, chars, segs, sp, cands)
        items.append(it)
    return items


def collate(items, device):
    nt = max(len(i['tok']) for i in items); nc = max(len(i['chars']) for i in items)
    C = max(1, max(len(i['cands']) for i in items))
    T = lambda x, **k: torch.tensor(x, device=device, **k)
    tok = T([i['tok'] + [0] * (nt - len(i['tok'])) for i in items])
    tseg = T([i['tseg'] + [0] * (nt - len(i['tseg'])) for i in items])
    nf = len(items[0]['tfeat'][0])
    tfeat = T([i['tfeat'] + [[0.0] * nf] * (nt - len(i['tfeat'])) for i in items])
    tpad = T([[False] * len(i['tok']) + [True] * (nt - len(i['tok'])) for i in items])
    c2t = T([i['c2t'] + [0] * (nc - len(i['c2t'])) for i in items])
    dur = T([i['dur'] for i in items])
    cand = T([[list(c) for c in i['cands']] + [[0, 0]] * (C - len(i['cands'])) for i in items])
    out = [tok, tseg, tfeat, dur, tpad, c2t, cand]
    if 'gold' in items[0]:
        out.append(T([i['gold'] + [-100] * (C - len(i['gold'])) for i in items]))
        out.append(T([i['is_song'] for i in items]))
    return out
