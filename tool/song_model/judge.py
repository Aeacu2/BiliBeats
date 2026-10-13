"""What the app ends up writing: the catalogue's answer and the model's reading, settled as
lib/services/song_judge.dart settles them.

  python3 judge.py rules.json reads.json        # scores on hold / dev / the 周深 fixture

rules.json : test/tools/rules_dump.dart run over work/eval.json (see mkeval.py)
reads.json : read.py run over the same file
"""
import json, sys
import evalkit as E
from tagger import find

SURE = 0.9   # SongJudge.sure


def judge(o, x, sure=SURE, up=''):
    """o: the rule matcher's entry; x: the model's reading; up: the uploader -> None or (song, [performers])."""
    R = E.rule_answer(o); M = x['ans'] and (x['ans'][0], list(x['ans'][1]))
    if o.get('never'): return R                      # a medley, a compilation: not the model's to name
    if M is None: return None                        # the model sees no song
    same = R is not None and E.same_name(R[0], M[0])
    if same and E.same_set(R[1], M[1]): return R
    if x.get('conf', 0) < sure or not M[1] or any(not p.strip() for p in M[1]):
        return (R[0], [up.strip()]) if same and up.strip() else None   # the song, if not who sings it
    return (R[0] if same else M[0], M[1])


def load(rules_file, reads_file):
    rows = json.load(open(find('eval.json'))); rules = json.load(open(find(rules_file))); reads = json.load(open(find(reads_file)))
    fixes = json.load(open(find('label_fixes.json')))
    for r in rows:
        f = fixes.get(r['bvid'])
        if f:
            if 'label' in f: r['label'] = f['label']
            r['alt'] = f.get('alt')
    return list(zip(rows, rules, reads))


if __name__ == '__main__':
    data = load(sys.argv[1], sys.argv[2])
    show = lambda t: ' '.join(f'{k}={t[k]}' for k in ('right', 'wrong', 'missed', 'false_song', 'wrong_song', 'wrong_perf')) + f" precision={t['precision']}"
    for s in ('hold', 'dev', 'zs'):
        d = [t for t in data if t[0]['set'] == s]; rows = [r for r, _, _ in d]
        print(f'{s} ({len(d)} videos)')
        print('  rules alone', show(E.summary(rows, [E.rule_answer(o) for _, o, _ in d])))
        print('  model alone', show(E.summary(rows, [x['ans'] and (x['ans'][0], x['ans'][1]) for _, _, x in d])))
        print('  judged     ', show(E.summary(rows, [judge(o, x, up=r['up']) for r, o, x in d])))
        named = [(r, judge(o, x, up=r['up'])) for r, o, x in d]
        songs = lambda r: [g['song'] for g in [r['label']] + list(r.get('alt') or []) if g]
        ok = sum(any(E.norm(a[0]) == E.norm(g) for g in songs(r)) for r, a in named if a)
        print(f'  song named  right={ok} of {sum(a is not None for _, a in named)} named'
              f' (the song alone, whoever is credited)')
