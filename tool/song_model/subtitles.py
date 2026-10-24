"""Bilibili subtitles as evidence: how often there are any, and how well they tell the right song from
a wrong one — measured on `hold` before the app's thresholds (lib/services/subtitle_match.dart) are
believed.

Subtitles are given to logged-in viewers only. Put the account's SESSDATA (from a logged-in browser;
it stays on this machine) in the environment:

  SESSDATA='…' python3 subtitles.py rules.json reads.json [--set hold] [--limit 200]

Fetched subtitles and NetEase lyrics are cached in work/subtitles.jsonl and work/sub_lyrics.jsonl, so
a re-run (a changed threshold) costs no requests. Reports:
  1. coverage: videos with subtitles, the uploader's (CC) or machine (AI), and those listed but
     withheld (no address: not logged in, or not entitled);
  2. separation: the match against the right song's lyrics vs against the wrong songs the rules or the
     model proposed, over a grid of thresholds (confirm rate on right / on wrong);
  3. rescue: of the videos the judge leaves unnamed today, how many a subtitle match would name, and
     how many of those songs are right.
"""
import argparse, hashlib, json, os, re, sys, time, urllib.parse, urllib.request
from functools import reduce

import evalkit as E
from judge import judge, load
from tagger import find

UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0 Safari/537.36')


def get(url, cookies='', referer='https://www.bilibili.com'):
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Referer': referer, 'Cookie': cookies})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode('utf-8'))
    except Exception as e:
        print('  request failed:', url[:80], e, file=sys.stderr)
        return None


# ---- WBI signing (as lib/services/wbi_signer.dart) --------------------------------------------------
MIX = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28,
       14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21,
       56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52]
_mixin = None


def signed(params, cookies):
    global _mixin
    if _mixin is None:
        nav = get('https://api.bilibili.com/x/web-interface/nav', cookies) or {}
        img = (nav.get('data') or {}).get('wbi_img') or {}
        key = lambda u: u.rsplit('/', 1)[-1].split('.')[0]
        raw = key(img.get('img_url', '')) + key(img.get('sub_url', ''))
        _mixin = reduce(lambda s, i: s + raw[i], MIX, '')[:32] if len(raw) >= 64 else ''
    p = dict(params, wts=int(time.time()))
    p = {k: re.sub(r"[!'()*]", '', str(v)) for k, v in sorted(p.items())}
    q = urllib.parse.urlencode(p)
    return q + '&w_rid=' + hashlib.md5((q + _mixin).encode()).hexdigest()


# ---- caches ---------------------------------------------------------------------------------------
def cache(name):
    path = find(name); data = {}
    if os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            o = json.loads(line); data[o['k']] = o['v']
    def put(k, v):
        data[k] = v
        with open(path, 'a', encoding='utf-8') as f: f.write(json.dumps({'k': k, 'v': v}, ensure_ascii=False) + '\n')
    return data, put


def subtitles_of(bvid, cookies, subs, put):
    """-> {'state': none|withheld|cc|ai, 'lines': [[from, to, text]]} (cached)"""
    if bvid in subs: return subs[bvid]
    view = get(f'https://api.bilibili.com/x/web-interface/view?bvid={bvid}', cookies)
    cid = ((view or {}).get('data') or {}).get('cid')
    if not cid: return None
    player = get('https://api.bilibili.com/x/player/wbi/v2?' + signed({'bvid': bvid, 'cid': cid}, cookies), cookies)
    data = (player or {}).get('data')
    if data is None: return None
    listed = ((data.get('subtitle') or {}).get('subtitles')) or []
    usable = [s for s in listed if (s.get('subtitle_url') or '').strip()]
    out = {'state': 'none' if not listed else 'withheld', 'lines': []}
    if usable:
        ai = lambda s: s.get('type') == 1 or str(s.get('lan', '')).startswith('ai-')
        usable.sort(key=lambda s: (2 if ai(s) else 0) + (0 if 'zh' in str(s.get('lan', '')).lower() else 1))
        pick = usable[0]; url = pick['subtitle_url']
        url = ('https:' + url) if url.startswith('//') else url.replace('http:', 'https:')
        body = get(url, cookies)
        if body is None: return None
        out = {'state': 'ai' if ai(pick) else 'cc',
               'lines': sorted([[b['from'], b['to'], b['content'].strip()] for b in body.get('body', []) if b.get('content', '').strip()])}
    put(bvid, out); time.sleep(0.4)
    return out


def lyrics_of(title, artist, lyr, put, n=3):
    """The lyrics of up to n NetEase recordings called `title` (the one by `artist` first). Cached."""
    key = f'{title}\n{artist}'
    if key in lyr: return lyr[key]
    q = urllib.parse.quote(f'{title} {artist}'.strip())
    res = get(f'https://music.163.com/api/search/get?s={q}&type=1&limit=10', referer='https://music.163.com')
    if res is None: return None
    out = []
    for s in ((res.get('result') or {}).get('songs') or []):
        if len(out) >= n: break
        if not E.same_name(s.get('name', ''), title): continue
        l = get(f"https://music.163.com/api/song/lyric?id={s['id']}&lv=-1&tv=-1", referer='https://music.163.com')
        text = (((l or {}).get('lrc') or {}).get('lyric')) or ''
        lines = [m.group(2).strip() for m in re.finditer(r'\[(\d+:\d+[.:]?\d*)\](.*)', text) if m.group(2).strip()]
        if lines: out.append(lines)
        time.sleep(0.2)
    put(key, out)
    return out


# ---- the app's comparison (SubtitleMatcher.compare), without timing --------------------------------
def normalize(s): return ''.join(c for c in E.t2s(s).lower() if c.isalnum())
def grams(s): return {s[i:i + 2] for i in range(len(s) - 1)}


def same(a, b):
    if not a or not b: return False
    small, large = (a, b) if len(a) <= len(b) else (b, a)
    shared = sum(1 for g in small if g in large)
    return shared >= 2 and shared / len(small) >= 0.6


def compare(sub_lines, lyric_lines):
    lg = [g for g in (grams(normalize(l)) for l in lyric_lines) if len(g) >= 2]
    distinct = {normalize(l) for l in lyric_lines if len(grams(normalize(l))) >= 2}
    considered = matched = 0; heard = set()
    for _, _, text in sub_lines:
        g = grams(normalize(text))
        if len(g) < 2: continue
        considered += 1; hit = False
        for l, raw in zip(lg, [x for x in lyric_lines if len(grams(normalize(x))) >= 2]):
            if same(g, l): hit = True; heard.add(normalize(raw))
        matched += hit
    return dict(matched=matched, precision=matched / considered if considered else 0,
                coverage=len(heard) / len(distinct) if distinct else 0)


def confirms(m, k, p, c): return m['matched'] >= k and m['precision'] >= p and m['coverage'] >= c


APP = (6, 0.5, 0.3)   # SubtitleMatch.minMatched / minPrecision / minCoverage


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rules'); ap.add_argument('reads')
    ap.add_argument('--set', default='hold'); ap.add_argument('--limit', type=int, default=0)
    a = ap.parse_args()
    sess = os.environ.get('SESSDATA', '').strip()
    if not sess: sys.exit('SESSDATA is not set: Bilibili gives subtitles to logged-in viewers only.')
    cookies = f'SESSDATA={sess}'
    data = [t for t in load(a.rules, a.reads) if t[0]['set'] == a.set]
    if a.limit: data = data[:a.limit]
    subs, put_sub = cache('subtitles.jsonl'); lyr, put_lyr = cache('sub_lyrics.jsonl')

    from collections import Counter
    states = Counter(); right_m, wrong_m = [], []; rescue = []
    for i, (row, o, x) in enumerate(data):
        print(f'\r{i + 1}/{len(data)}', end='', file=sys.stderr)
        s = subtitles_of(row['bvid'], cookies, subs, put_sub)
        states[s['state'] if s else 'failed'] += 1
        if not s or not s['lines']: continue
        gold = [g for g in [row['label']] + list(row.get('alt') or []) if g]
        golds = {E.norm(g['song']) for g in gold}
        best = lambda title, artist: max((compare(s['lines'], l) for l in (lyrics_of(title, artist, lyr, put_lyr) or [])),
                                         key=lambda m: (m['matched'], m['precision']), default=None)
        if gold:
            m = best(gold[0]['song'], ' '.join(E.perf(gold[0], row['up'])))
            if m: right_m.append(m)
        cands = []
        R = E.rule_answer(o); M = x['ans'] and (x['ans'][0], list(x['ans'][1]))
        for c in (R, M):
            if c and E.norm(c[0]) not in golds and all(E.norm(c[0]) != E.norm(d[0]) for d in cands): cands.append(c)
        for c in cands:
            m = best(c[0], ' '.join(c[1]))
            if m: wrong_m.append(m)
        if judge(o, x, up=row['up']) is None:
            options = [c for c in (R, M) if c]
            for c in options:
                m = best(c[0], ' '.join(c[1]))
                if m and confirms(m, *APP):
                    rescue.append((row, c[0], E.norm(c[0]) in golds)); break
    print(file=sys.stderr)

    n = len(data)
    print(f'{a.set}: {n} videos')
    print('  subtitles:', ', '.join(f'{k}={v} ({v / n:.0%})' for k, v in states.most_common()))
    print(f'  compared: right song {len(right_m)} videos, wrong candidates {len(wrong_m)}')
    print('  thresholds (matched, precision, coverage): confirms right / wrong')
    for k in (4, 6, 8):
        for p in (0.3, 0.4, 0.5, 0.6):
            for c in (0.2, 0.3, 0.4):
                tp = sum(confirms(m, k, p, c) for m in right_m); fp = sum(confirms(m, k, p, c) for m in wrong_m)
                mark = '  <- app' if (k, p, c) == APP else ''
                print(f'    {k} {p:.1f} {c:.1f}: {tp}/{len(right_m)} right, {fp}/{len(wrong_m)} wrong{mark}')
    ok = sum(r for _, _, r in rescue)
    print(f'  rescue: {len(rescue)} unnamed videos would be named; the song is right in {ok}')


if __name__ == '__main__':
    main()
