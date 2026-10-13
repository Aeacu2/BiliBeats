"""Labelling batches from the unlabelled titles (data/titles.jsonl.gz), for Haiku.
python3 mkbatch_titles.py N [--size 110]   -> N new batches in label_haiku/tNNN.task.txt
python3 mkbatch_titles.py --dev            -> the validation set as batches (to measure the labeller)"""
import gzip, json, os, random, re, sys
S = os.path.dirname(os.path.abspath(__file__))
D, L = S + '/data', S + '/label_haiku'
os.makedirs(L, exist_ok=True)
MUSIC = re.compile(r'翻唱|cover|音乐|歌|演唱|live|mv|弹唱|合唱|ost|主题曲|单曲|专辑|纯享|现场|钢琴|吉他|vocal|原创|舞台', re.I)


def line(i, r):
    m = r.get('music')
    if m and m.get('t'):
        m = m['t'] + ('|' + '/'.join(m.get('a') or []) if m.get('a') else '')
    o = {'i': i, 't': r['title'], 'u': r['up'], 'd': r['dur'], 'g': (r.get('tags') or [])[:5]}
    if m: o['m'] = m
    return json.dumps(o, ensure_ascii=False, separators=(',', ':'))


def write(name, chunk, state):
    out = f'{L}/{name}.out.jsonl'
    body = open(S + '/prompt_lean.txt').read().replace('{OUT}', out).replace('{N}', str(len(chunk)))
    body += '\n=== 数据 ===\n' + '\n'.join(line(k + 1, r) for k, r in enumerate(chunk)) + '\n'
    open(f'{L}/{name}.task.txt', 'w').write(body)
    state[name] = [r['bvid'] for r in chunk]
    print(f'{L}/{name}.task.txt', len(chunk))


def candidates():
    """Videos that look like music, in a fixed random order; one in ten is anything else, for the negatives."""
    jl = lambda p: [json.loads(l) for l in open(p) if l.strip()]
    hold = {r['bvid'] for r in json.load(open(D + '/dev.json'))} | {r['bvid'] for p in ('/test121.jsonl', '/train.jsonl') for r in jl(D + p)}
    music, other, seen = [], [], set()
    for l in gzip.open(D + '/titles.jsonl.gz', 'rt'):
        r = json.loads(l)
        if r['bvid'] in hold or r['bvid'] in seen or not 45 <= r['dur'] <= 900: continue
        seen.add(r['bvid'])
        (music if '《' in r['title'] or MUSIC.search(r['title'] + ' ' + ' '.join(r.get('tags') or [])) else other).append(r)
    rng = random.Random(0); rng.shuffle(music); rng.shuffle(other)
    out = []
    while music:
        out += music[:9] + other[:1]; music, other = music[9:], other[1:]
    return out


def main():
    state_p = L + '/batches.json'
    state = json.load(open(state_p)) if os.path.exists(state_p) else {}
    size = int(sys.argv[sys.argv.index('--size') + 1]) if '--size' in sys.argv else 110
    if '--dev' in sys.argv:
        dev = json.load(open(D + '/dev.json'))
        half = (len(dev) + 1) // 2
        write('d01', dev[:half], state); write('d02', dev[half:], state)
    else:
        used = {b for v in state.values() for b in v}
        todo = [r for r in candidates() if r['bvid'] not in used]
        n = sum(k.startswith('t') for k in state)
        for k in range(int(sys.argv[1])):
            chunk, todo = todo[:size], todo[size:]
            if not chunk: break
            write('t%03d' % (n + k + 1), chunk, state)
    json.dump(state, open(state_p, 'w'))


if __name__ == '__main__':
    main()
