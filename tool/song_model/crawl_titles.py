"""Search-only crawl: many titles (with uploader and tags) for pretraining. Resumable."""
import json, os, random, threading, time
from concurrent.futures import ThreadPoolExecutor
import crawl
S = crawl.HERE
OUT = S + '/titles.jsonl'
done_q = set()
if os.path.exists(S + '/titles_done.txt'):
    done_q = set(open(S + '/titles_done.txt').read().split('\n'))
names = json.load(open(S + '/singers_netease.json'))
random.seed(7)
pool = [n for n, v in names.items() if 2 <= len(n) <= 14 and (v.get('hot') or v.get('mv', 0) > 0 or v.get('albums', 0) > 8)]
random.shuffle(pool)
suffix = ['', '', ' 翻唱', ' 现场', ' cover', ' 合唱', ' live', ' MV', ' 弹唱', ' 纯享']
queries = [n + random.choice(suffix) for n in pool[:5000]]
queries = [q for q in queries if q not in done_q]
print(len(pool), 'names,', len(queries), 'queries to run', flush=True)
crawl.warm(); crawl.pause = 0.5
lock = threading.Lock(); stop = threading.Event(); n = [0]
f = open(OUT, 'a'); fd = open(S + '/titles_done.txt', 'a')

def work(q):
    if stop.is_set(): return
    try:
        rows = crawl.search(q, 1)
    except crawl.Refused:
        stop.set(); print('refused; stop', flush=True); return
    except Exception as e:
        print('skip', q, e, flush=True); return
    with lock:
        for r in rows:
            f.write(json.dumps({k: r[k] for k in ('bvid', 'title', 'up', 'dur', 'tags')}, ensure_ascii=False) + '\n')
        f.flush(); fd.write(q + '\n'); fd.flush(); n[0] += 1
        if n[0] % 100 == 0: print(n[0], flush=True)

with ThreadPoolExecutor(2) as ex:
    list(ex.map(work, queries))
print('finished', flush=True)
