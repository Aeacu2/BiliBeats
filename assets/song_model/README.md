# The song model

The on-device model that reads a video's song and performers
(`lib/services/song_reader.dart`). Four files, written by
`tool/song_model/export_plm.py` (see `tool/song_model/README.md`):

- `song_model.bin` — the fine-tuned encoder, 8-bit (about 143 MB)
- `song_vocab.txt` — its tokenizer's vocabulary and merges
- `song_singers.txt` — the lexicon of artist names it is shown
- `song_model.json` — a stamp naming this copy; the app unpacks the files
  to its support directory once, and again when the stamp changes

They are too large for the repository (one is over GitHub's 100 MB limit)
and are not committed. They are published as the assets of a GitHub
release instead, and `tool/fetch_song_model.sh` puts the ones this version
ships here, checked against their checksums; `tool/build_release.sh` and CI
run it. A build without them still works: songs are then named by the
catalogue rules alone.
