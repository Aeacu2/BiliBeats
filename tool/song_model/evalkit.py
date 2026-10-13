"""Scoring: a gold label against an answer (song, [performers]), forgiving how a name is written."""
import json, re, unicodedata
try:
    import zhconv                      # optional: pip install zhconv
    t2s = lambda s: zhconv.convert(s, 'zh-cn')
except Exception:
    _T = str.maketrans('師華樂愛夢語鄧張陳劉葉藝聲與戀優號記錄見鳥魚龍風雲會歲時東無間開關歸塵島園夜書畫', '师华乐爱梦语邓张陈刘叶艺声与恋优号记录见鸟鱼龙风云会岁时东无间开关归尘岛园夜书画')
    t2s = lambda s: s.translate(_T)


def norm(s): return ''.join(c for c in unicodedata.normalize('NFKC', t2s(str(s))).lower() if c.isalnum())


def same_name(a, b):
    a, b = norm(a), norm(b)
    return a == b or (min(len(a), len(b)) >= 2 and (a in b or b in a))


def same_set(xs, ys):
    xs, ys = list(xs), list(ys)
    if norm(''.join(xs)) == norm(''.join(ys)): return True   # "MYTH & ROID", "H//PE Princess"
    if len(xs) != len(ys): return False
    for x in xs:
        k = next((i for i, y in enumerate(ys) if same_name(x, y)), None)
        if k is None: return False
        ys.pop(k)
    return True


def perf(label, up): return [up if p.strip().upper() in ('UP主', 'UP') else p for p in label['performers']]


def rule_answer(o):
    """An entry of test/tools/rules_dump.dart's output -> None or (song, [performers])."""
    return None if 't' not in o else (o['t'], [p for p in re.split(r'\s*&\s*|\s*/\s*|、', o['a']) if p.strip()])


def grade(row, ans):
    """-> ok | silent_ok | missed | false_song | wrong_song | wrong_perf.  row['alt'] lists other answers as good."""
    def one(g):
        if g is None: return 'silent_ok' if ans is None else 'false_song'
        if ans is None: return 'missed'
        if norm(g['song']) != norm(ans[0]): return 'wrong_song'
        return 'ok' if same_set(perf(g, row['up']), ans[1]) else 'wrong_perf'
    rs = [one(g) for g in [row['label']] + list(row.get('alt') or [])]
    for best in ('ok', 'silent_ok'):
        if best in rs: return best
    return rs[0]


def summary(rows, answers):
    from collections import Counter
    c = Counter(grade(r, a) for r, a in zip(rows, answers))
    right, wrong = c['ok'], c['false_song'] + c['wrong_song'] + c['wrong_perf']
    return dict(right=right, wrong=wrong, missed=c['missed'], silent_ok=c['silent_ok'],
                precision=round(right / max(1, right + wrong), 3), **{k: c[k] for k in ('false_song', 'wrong_song', 'wrong_perf')})
