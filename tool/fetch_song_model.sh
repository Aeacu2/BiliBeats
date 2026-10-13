#!/usr/bin/env bash
#
# Puts the song model in assets/song_model/, from the GitHub release that
# holds it. The model is too large for the repository (one file is 143 MB,
# over GitHub's limit), so a clone has none and a build made from it names
# songs by the rules alone.
#
#   tool/fetch_song_model.sh          # does nothing when the files are right
#
# Shipping a new model: export it (tool/song_model/README.md), publish its
# four files as the assets of a release tagged song-model-N —
#
#   gh release create song-model-N assets/song_model/song_* --latest=false \
#       --title "Song model N" --notes "…"
#
# — then set TAG below and replace the checksums (shasum -a 256).
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="song-model-1"
BASE="https://github.com/Aeacu2/BiliBeats/releases/download/$TAG"
DIR="assets/song_model"

# sha256, file
FILES="
10d9159b8d7d58c5a95295b8562b38c0ace50078c232ffb2325dd4b62450777d song_model.bin
706cf3000c4e6748fa911c5e14ddefd029d14132fb8b9bbc149b413671ef5039 song_vocab.txt
488e435ac4161c57fb4ee63097f244927da0137a33917f8fc0a7113e9989fa60 song_singers.txt
bd6f261887417c7073154a1a922f3e2434407dae3256597334185214893a31d8 song_model.json
"

sum_of() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

mkdir -p "$DIR"
while read -r want name; do
  [[ -z "$name" ]] && continue
  if [[ -f "$DIR/$name" && "$(sum_of "$DIR/$name")" == "$want" ]]; then
    continue
  fi
  echo "==> $name ($TAG)"
  curl --fail --location --silent --show-error --retry 3 \
    --output "$DIR/$name.part" "$BASE/$name"
  got="$(sum_of "$DIR/$name.part")"
  if [[ "$got" != "$want" ]]; then
    rm -f "$DIR/$name.part"
    echo "error: $name from $TAG is not the file expected" >&2
    echo "       (sha256 $got, wanted $want)." >&2
    exit 1
  fi
  mv "$DIR/$name.part" "$DIR/$name"
done <<< "$FILES"
