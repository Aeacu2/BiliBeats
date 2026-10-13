"""The Gemma-style tokenizer of mmBERT, written out so the app can do exactly the same:
space -> '▁', a '▁' before every field, split before each '▁', then BPE over characters
(a character the vocabulary lacks becomes its UTF-8 bytes)."""
import json, os


class CharBPE:
    def __init__(self, path=None, vocab=None, merges=None, cls=2, sep=1, unk=3):
        if path:
            j = json.load(open(os.path.join(path, 'tokenizer.json'), encoding='utf-8'))
            vocab, merges = j['model']['vocab'], j['model']['merges']
            cfg = json.load(open(os.path.join(path, 'config.json')))
            cls, sep = cfg['bos_token_id'], cfg['sep_token_id']
            unk = vocab['<unk>']
        self.stoi = vocab
        self.rank = {}
        for r, m in enumerate(merges):
            a, b = m if isinstance(m, list) else m.split(' ')
            self.rank.setdefault((a, b), r)
        self.cls, self.sep, self.unk = cls, sep, unk
        self.used = None   # set() to record the merges and tokens a corpus needs

    def word(self, w):
        """w: list of characters -> list of (token string, start, end) over w's indices."""
        sym = []
        for i, c in enumerate(w):
            if c in self.stoi: sym.append([c, i, i + 1])
            else:
                for b in c.encode('utf-8'): sym.append(['<0x%02X>' % b, i, i + 1])
        while len(sym) > 1:
            best, at = None, -1
            for k in range(len(sym) - 1):
                r = self.rank.get((sym[k][0], sym[k + 1][0]))
                if r is not None and (best is None or r < best): best, at = r, k
            if best is None: break
            a, b = sym[at][0], sym[at + 1][0]
            if self.used is not None: self.used.add((a, b))
            k, out = 0, []
            while k < len(sym):
                if k + 1 < len(sym) and sym[k][0] == a and sym[k + 1][0] == b:
                    out.append([a + b, sym[k][1], sym[k + 1][2]]); k += 2
                else:
                    out.append(sym[k]); k += 1
            sym = out
        return sym

    def field(self, text):
        """-> [(id, start, end)] with offsets into text; the '▁' put in front belongs to what follows it."""
        chars = ['▁' if c == ' ' else c for c in text]
        if not chars: return []
        pre = chars[0] != '▁'
        if pre: chars = ['▁'] + chars
        out, i = [], 0
        while i < len(chars):
            j = i + 1
            while j < len(chars) and chars[j] != '▁': j += 1
            for tok, a, b in self.word(chars[i:j]):
                a, b = i + a - pre, i + b - pre
                out.append((self.stoi.get(tok, self.unk), max(a, 0), b))
            i = j
        return out

    def tokens(self, chars):
        """chars: tagger.encode's sequence -> (token ids, char -> token index)."""
        ids, c2t = [], [0] * len(chars)
        i, n = 0, len(chars)
        while i < n:
            c = chars[i]
            if c == '\x01': ids.append(self.cls); c2t[i] = len(ids) - 1; i += 1; continue
            if c < ' ': ids.append(self.sep); c2t[i] = len(ids) - 1; i += 1; continue
            j = i
            while j < n and chars[j] >= ' ': j += 1
            last = max(0, len(ids) - 1)
            cover = [None] * (j - i)
            for tid, a, b in self.field(chars[i:j]):
                ids.append(tid)
                for x in range(a, b):
                    if cover[x] is None: cover[x] = len(ids) - 1
            for x in range(j - i):
                if cover[x] is None: cover[x] = last
                else: last = cover[x]
                c2t[i + x] = cover[x]
            i = j
        return ids, c2t
