# The song model

A small pretrained encoder, fine-tuned to read a Bilibili video's metadata
(title, uploader, tags, the music Bilibili recognised, length) and say whether
it is one song, which words name it, and which name who is heard. The app runs
it in plain Dart (`lib/services/song_reader.dart`) beside the catalogue rules
(`LyricsEngine.identify`); `SongJudge` settles the two.

Everything it answers is a span copied from its input, so it cannot invent a
name. It is a second reader, not an oracle: see "How it is judged" below.

## Layout

```
data/      labelled videos and the crawl they came from (kept locally, not
           in the repository: it is other people's video metadata)
  train.jsonl        4737 videos labelled by Sonnet (prompt_lean.txt)
  train_haiku.jsonl  4238 more, labelled by Haiku
  hold.json          800 of train.jsonl, kept out of training to measure on
  dev.json           233, the set earlier models were selected on
  test121.jsonl      the surveyed 周深 videos (model's view of the fixture)
  label_fixes.json   labels found wrong on review, and answers as good
  lexicon.json       artist names (a feature: "a known singer stands here")
work/      pretrained encoders, checkpoints, caches (not in the repository;
           $SONG_MODEL_WORK moves it elsewhere)
legacy/    the character model trained from scratch that this replaced
```

## Train, measure, ship

```bash
pip install torch transformers            # zhconv too, for fairer scoring
mkdir -p work/plm/mmbert-small            # from huggingface.co/jhu-clsp/mmBERT-small:
                                          #   config.json tokenizer.json pytorch_model.bin

python3 mkeval.py                         # work/eval.json: hold + dev + the 周深 fixture
python3 train_plm.py --plm plm/mmbert-small --freeze-emb --lr 5e-5 --save mmbert.pt
python3 read.py eval.json reads.json mmbert.pt

# what the rules say about the same videos (from the repository root):
RULES_IN=tool/song_model/work/eval.json RULES_OUT=tool/song_model/work/rules.json \
RULES_CACHE=tool/song_model/work/netease.jsonl \
  flutter test test/tools/rules_dump.dart --tags live

python3 judge.py rules.json reads.json    # rules alone / model alone / judged

# the model that ships is trained on the hold-out as well:
python3 train_plm.py --plm plm/mmbert-small --freeze-emb --lr 5e-5 \
    --use-hold --eval dev.json --save ship.pt
python3 export_plm.py ship.pt ../../assets/song_model --int8
READER_DIR=assets/song_model flutter test test/tools/song_reader_parity.dart
```

Publishing the exported model, so that any clone can build with it, is in
the header of `tool/fetch_song_model.sh`.

`RULES_CACHE` keeps NetEase's answers, so a changed rule is re-measured on
the same evidence in seconds. `export_plm.py` also writes `reference.json`
(what the Python model reads in 346 videos); the parity test checks the Dart
port reproduces it — move that file out of `assets/` afterwards.

## How it is judged

Measure on `hold` (never trained on, never used to pick a model). `dev` chose
earlier models and flatters them; the 周深 fixture is what the rules were
tuned on, so the rules score 100% there and anything else looks worse.
A wrong name in the library is worse than no name: read `wrong` before
`right`.

One kind of `wrong_perf` is deliberate. Where the rules and the model read
the same song but not the same singer, the judge names the song and leaves
the uploader as the artist, exactly as an unnamed video is credited. Scored
strictly that is a wrong performer whenever the uploader is not the singer
(43 of 60 such videos on `hold`); what the listener sees is a right song name
where there was a video title (55 of 60), under the credit it already had.
`judge.py` prints `song named` for that reason: the song alone, whoever is
credited.

Encoders compared on `hold` (wholly right, of 800), same data, 12 epochs:
character model from scratch 546 · MiniRBT-h288 587 · ELECTRA-small 587 ·
bge-small-zh-v1.5 597 · LERT-small 600 · granite-97m-multilingual-r2 612 ·
**mmBERT-small 643**. Feeding the model the rules' answer as an input did not
help (the rules are right too seldom on training data to be worth trusting).

## Labelling more

`crawl.py` / `crawl_titles.py` collect videos, `mkbatch*.py` cut them into
tasks for a labelling model with `prompt_lean.txt`, `collect*.py` gather the
answers. Labellers disagree on about one video in ten, nearly all of it on
who performs: more labels of the same kind stopped helping long ago.
