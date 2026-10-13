"""Collect Bilibili music videos (title, uploader, tags, recognised music) for labelling.

Resumable: every finished video is appended to crawl.jsonl; searches are cached in
crawl_search.json. Usage: python3 crawl.py [max_videos]
"""
import hashlib, http.cookiejar, json, os, random, re, sys, time, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'crawl.jsonl')
SEARCH = os.path.join(HERE, 'crawl_search.json')
UA = ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36')
TAB = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19,
       29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
       22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52]

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
opener.addheaders = [('User-Agent', UA), ('Referer', 'https://www.bilibili.com/')]
_keys = None
pause = 0.35


class Refused(Exception):
    pass


def get(url, params=None, signed=False, tries=4):
    global pause
    for n in range(tries):
        p = dict(params or {})
        if signed:
            p = sign(p)
        full = url + ('?' + urllib.parse.urlencode(p) if p else '')
        time.sleep(pause + random.random() * 0.4)
        try:
            with opener.open(full, timeout=20) as r:
                j = json.loads(r.read().decode('utf-8', 'replace'))
        except Exception as e:  # network, 412, bad JSON
            code = getattr(e, 'code', None)
            wait = 60 * (n + 1) if code == 412 else 5 * (n + 1)
            print(f'  ! {type(e).__name__} {code or ""} on {url.split("/")[-1]}, sleep {wait}s', flush=True)
            time.sleep(wait)
            continue
        code = j.get('code')
        data = j.get('data')
        if code in (-352, -412, -509, -799) or (isinstance(data, dict) and data.get('v_voucher')):
            wait = 20 * (n + 1) if tries > 1 else 1
            pause = min(pause * 1.3, 3.0)
            print(f'  ! refused {code} on {url.split("/")[-1]}, sleep {wait}s', flush=True)
            time.sleep(wait)
            warm()
            continue
        return j
    raise Refused(url)


def warm():
    global _keys
    _keys = None
    jar.clear()
    try:
        opener.open('https://www.bilibili.com/', timeout=20).read(1000)
    except Exception:
        pass
    try:
        j = json.loads(opener.open('https://api.bilibili.com/x/frontend/finger/spi', timeout=20).read())
        for k, name in (('b_3', 'buvid3'), ('b_4', 'buvid4')):
            jar.set_cookie(http.cookiejar.Cookie(
                0, name, j['data'][k], None, False, '.bilibili.com', True, True, '/', True,
                False, None, False, None, None, {}))
    except Exception:
        pass


def keys():
    global _keys
    if _keys is None:
        j = json.loads(opener.open('https://api.bilibili.com/x/web-interface/nav', timeout=20).read())
        w = j['data']['wbi_img']
        raw = w['img_url'].rsplit('/', 1)[1].split('.')[0] + w['sub_url'].rsplit('/', 1)[1].split('.')[0]
        _keys = ''.join(raw[i] for i in TAB)[:32]
    return _keys


def sign(p):
    p = {k: re.sub(r"[!'()*]", '', str(v)) for k, v in p.items()}
    p['wts'] = int(time.time())
    q = urllib.parse.urlencode(sorted(p.items()))
    p['w_rid'] = hashlib.md5((q + keys()).encode()).hexdigest()
    return p


def seconds(s):
    n = 0
    for part in str(s).split(':'):
        n = n * 60 + int(part or 0)
    return n


def search(q, page):
    j = get('https://api.bilibili.com/x/web-interface/search/type',
            {'search_type': 'video', 'keyword': q, 'page': page}, tries=3)
    out = []
    for r in (j.get('data') or {}).get('result') or []:
        if r.get('type') != 'video' or not r.get('bvid'):
            continue
        out.append({
            'q': q, 'bvid': r['bvid'],
            'title': re.sub(r'<[^>]+>', '', r.get('title', '')).replace('&amp;', '&').replace('&quot;', '"').replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>'),
            'up': r.get('author', ''), 'dur': seconds(r.get('duration', '0')),
            'tags': [t.strip() for t in (r.get('tag') or '').split(',') if t.strip()],
            'zone': r.get('typename', ''), 'desc': (r.get('description') or '')[:200],
            'play': r.get('play', 0),
        })
    return out


def music(v):
    j = get('https://api.bilibili.com/x/player/pagelist', {'bvid': v['bvid']})
    d = j.get('data') or []
    cid = d[0].get('cid') if d else None
    v['pages'] = len(d)
    if not cid:
        return None
    j = get('https://api.bilibili.com/x/player/wbi/v2', {'bvid': v['bvid'], 'cid': cid}, signed=True)
    b = (j.get('data') or {}).get('bgm_info') or {}
    mid = b.get('music_id')
    if not mid:
        return None
    j = get('https://api.bilibili.com/x/copyright-music-publicity/bgm/detail', {'music_id': mid})
    d = j.get('data') or {}
    t = d.get('music_title') or b.get('music_title')
    if not t:
        return None
    return {'t': t, 'a': [a.strip() for a in re.split(r'[,，/／、]', d.get('origin_artist') or '') if a.strip()]}


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
    queries = json.load(open(os.path.join(HERE, 'queries.json')))
    cache = json.load(open(SEARCH)) if os.path.exists(SEARCH) else {}
    done = {}
    if os.path.exists(OUT):
        for line in open(OUT):
            r = json.loads(line)
            done[r['bvid']] = r
    warm()
    for q in queries:
        if q in cache:
            continue
        try:
            cache[q] = search(q, 1)
        except Refused:
            print('search refused, stopping searches', flush=True)
            break
        print(f'search {q}: {len(cache[q])}', flush=True)
        json.dump(cache, open(SEARCH, 'w'), ensure_ascii=False)
    # round-robin over queries so every query contributes before any is exhausted
    order, seen = [], set(done)
    rank = 0
    while len(order) + len(done) < limit:
        added = False
        for q in queries:
            rows = cache.get(q) or []
            if rank < len(rows):
                added = True
                v = rows[rank]
                if v['bvid'] not in seen and 30 <= v['dur'] <= 1200:
                    seen.add(v['bvid'])
                    order.append(v)
        rank += 1
        if not added:
            break
    order = order[:max(0, limit - len(done))]
    print(f'{len(done)} done, {len(order)} to fetch', flush=True)
    from concurrent.futures import ThreadPoolExecutor
    import threading
    lock, stop = threading.Lock(), threading.Event()
    count = [0]
    f = open(OUT, 'a')

    def work(v):
        if stop.is_set():
            return
        try:
            v['music'] = music(v)
        except Refused:
            stop.set(); print('refused for good; stop', flush=True); return
        except Exception as e:
            print('  ! skip', v['bvid'], type(e).__name__, e, flush=True); return
        with lock:
            f.write(json.dumps(v, ensure_ascii=False) + '\n'); f.flush()
            count[0] += 1
            if count[0] % 25 == 0:
                print(f'{count[0]}/{len(order)} pause={pause:.2f}', flush=True)

    with ThreadPoolExecutor(3) as ex:
        list(ex.map(work, order))
    print('finished', flush=True)


if __name__ == '__main__':
    main()
