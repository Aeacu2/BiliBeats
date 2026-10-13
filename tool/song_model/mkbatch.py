"""Compact labelling batches: instructions + one JSON line per video in a single file."""
import json, os, sys
S = os.path.dirname(os.path.abspath(__file__))

def line(i, r):
    m = r.get('music')
    if m and m.get('t'):
        m = m['t'] + ('|' + '/'.join(m.get('a') or []) if m.get('a') else '')
    o = {'i': i, 't': r['title'], 'u': r['up'], 'd': r['dur'], 'g': (r.get('tags') or [])[:8]}
    if m: o['m'] = m
    return json.dumps(o, ensure_ascii=False, separators=(',', ':'))

def main(size=200):
    test = {json.loads(l)['bvid'] for l in open(S + '/test121.jsonl')}
    rows = [json.loads(l) for l in open(S + '/crawl.jsonl')]
    rows = [r for r in rows if r['bvid'] not in test]
    state_p = S + '/label/batches.json'
    state = json.load(open(state_p)) if os.path.exists(state_p) else {}
    used = {b for v in state.values() for b in v}
    todo = [r for r in rows if r['bvid'] not in used]
    final = '--all' in sys.argv
    prompt = open(S + '/prompt_lean.txt').read()
    while len(todo) >= size or (final and todo):
        chunk, todo = todo[:size], todo[size:]
        name = 'b%02d' % (len(state) + 1)
        out = f'{S}/label/{name}.out.jsonl'
        body = prompt.replace('{OUT}', out).replace('{N}', str(len(chunk)))
        body += '\n=== 数据 ===\n' + '\n'.join(line(k + 1, r) for k, r in enumerate(chunk)) + '\n'
        open(f'{S}/label/{name}.task.txt', 'w').write(body)
        state[name] = [r['bvid'] for r in chunk]
        print(f'{S}/label/{name}.task.txt', len(chunk))
    json.dump(state, open(state_p, 'w'))

if __name__ == '__main__':
    main()
