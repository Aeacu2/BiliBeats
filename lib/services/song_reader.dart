import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// What the model reads in a video's title, uploader, tags and recognised
/// music: whether it is one song at all, which words name it, and which
/// name who is heard.
class SongReading {
  const SongReading({
    required this.pNone,
    required this.pOwn,
    required this.song,
    required this.performers,
    required this.own,
    required this.names,
    this.confidence = 0,
  });

  /// How likely this is not a song (a vlog, a medley, a lesson), 0–1.
  final double pNone;

  /// How likely it is the uploader's own version rather than a singer the
  /// video names, 0–1.
  final double pOwn;

  /// The song's name as the video writes it, or null when [pNone] wins or
  /// nothing in the video names one.
  final String? song;

  /// Who performs it, in the order the title names them; the uploader alone
  /// when [own].
  final List<String> performers;
  final bool own;

  /// How sure the answer is as a whole, 0–1: its weakest link among "this
  /// is a song", "this is its name", "these perform it" and "nobody else
  /// named does".
  final double confidence;

  /// Every name the model weighed, folded as [SongReader.fold] folds:
  /// how likely it is the song, and how likely a performer.
  final Map<String, ({double song, double performer})> names;

  /// How likely [name] is performing, by any spelling that contains it or
  /// that it contains (邓紫棋 in G.E.M.邓紫棋).
  double performing(String name) {
    final n = SongReader.fold(name);
    if (n.isEmpty) return 0;
    var best = 0.0;
    names.forEach((k, v) {
      if (k == n ||
          (n.length >= 2 &&
              k.length >= 2 &&
              (k.contains(n) || n.contains(k)))) {
        best = math.max(best, v.performer);
      }
    });
    return best;
  }
}

/// A small pretrained Chinese encoder, fine-tuned to read a video's song
/// and performers off its metadata. Every answer is a span copied from the
/// input, so it cannot invent a name.
///
/// Trained off-device (tool/song_model/); this is inference only, in plain
/// Dart, a second or two per video — run it off the UI isolate.
class SongReader {
  SongReader._(
      this._modern,
      this._hidden,
      this._layers,
      this._heads,
      this._head,
      this._w,
      this._vocab,
      this._merges,
      this._clsId,
      this._sepId,
      this._unkId,
      this._lex,
      this._lexMax);

  /// [model] is the weights file; [vocabulary] the tokenizer's tables (a
  /// WordPiece word list, or the JSON of a BPE vocabulary and its merges);
  /// [singers] the lexicon of known artists, one a line.
  factory SongReader.load(Uint8List model, String vocabulary, String singers) {
    final data = ByteData.sublistView(model);
    final headerLength = data.getUint32(0, Endian.little);
    final header = jsonDecode(
        utf8.decode(Uint8List.sublistView(model, 4, 4 + headerLength))) as Map;
    final weights = _Weights(data, 4 + headerLength, {
      for (final t in (header['tensors'] as List).cast<Map>())
        t['name'] as String: t,
    });
    final modern = header['arch'] == 'modernbert';
    final vocab = <String, int>{};
    final merges = <String, int>{};
    int cls, sep, unk;
    if (modern) {
      final tables = jsonDecode(vocabulary) as Map;
      var id = 0;
      for (final token in (tables['tokens'] as List).cast<String>()) {
        vocab[token] = id++;
      }
      var rank = 0;
      for (final pair in (tables['merges'] as List).cast<List>()) {
        merges['${pair[0]}\x00${pair[1]}'] = rank++;
      }
      cls = tables['cls'] as int;
      sep = tables['sep'] as int;
      unk = tables['unk'] as int;
    } else {
      var id = 0;
      for (final token in const LineSplitter().convert(vocabulary)) {
        vocab[token] = id++;
      }
      cls = vocab['[CLS]']!;
      sep = vocab['[SEP]']!;
      unk = vocab['[UNK]']!;
    }
    final lex = singers.split('\n').where((s) => s.isNotEmpty).toSet();
    var longest = 0;
    for (final s in lex) {
      longest = math.max(longest, s.runes.length);
    }
    return SongReader._(
      modern,
      header['hidden'] as int,
      header['layers'] as int,
      header['heads'] as int,
      header['head'] as int,
      weights,
      vocab,
      merges,
      cls,
      sep,
      unk,
      lex,
      longest,
    );
  }

  /// A ModernBERT encoder with a character BPE tokenizer (mmBERT), rather
  /// than a BERT with WordPiece.
  final bool _modern;
  final int _hidden, _layers, _heads, _head;
  final _Weights _w;
  final Map<String, int> _vocab;

  /// "left\x00right" → rank, lowest first (BPE only).
  final Map<String, int> _merges;
  final int _clsId, _sepId, _unkId;
  final Set<String> _lex;
  final int _lexMax;

  static const _maxLen = 256, _nFeat = 13, _maxCand = 96, _crossHeads = 4;
  static const _segT = 1, _segU = 2, _segG = 3, _segM = 4, _segA = 5;
  static final _open = '《「『【[（(“"〈<'.runes.toList();
  static final _close = '》」』】]）)”"〉>'.runes.toList();
  static const _keywords = [
    '翻唱', '翻自', 'cover', 'feat.', 'feat', 'ft.', '合唱', '演唱', '原唱', '献唱', '弹唱',
    '演绎', '共唱',
    '对唱', '主题曲', '片尾曲', '片头曲', '插曲', '推广曲', '纯享', '现场', 'live', '版', 'mv', '官方',
    '完整', '首唱', '再唱', '一曲', '歌曲', '唱', //
  ];
  static final _letterOrNumber = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _delimiter = RegExp(r'[\p{P}\p{Z}\p{S}]', unicode: true);
  static final _punctuation = RegExp(r'[\p{P}\p{S}]', unicode: true);
  static final _blank =
      RegExp(r'[\p{Zs}\p{Zl}\p{Zp}\p{Cc}\p{Cf}]', unicode: true);

  /// [s] as names are compared: case and width folded, letters and digits
  /// only.
  static String fold(String s) => _norm(s);

  /// Reads one video.
  SongReading read({
    required String title,
    required String uploader,
    List<String> tags = const [],
    String musicTitle = '',
    List<String> musicArtists = const [],
    int durationSeconds = 0,
  }) {
    // ---- lay the fields out as one character sequence
    final chars = <int>[1], segs = <int>[0];
    final spans = <(int, int, int)>[];
    void add(int seg, String text, int sep) {
      var runes = text.runes.toList();
      final limit = seg == _segT ? 120 : 40;
      if (runes.length > limit) runes = runes.sublist(0, limit);
      final start = chars.length;
      chars.addAll(runes);
      segs.addAll(List.filled(runes.length, seg));
      spans.add((seg, start, chars.length));
      chars.add(sep);
      segs.add(seg);
    }

    add(_segT, title, 2);
    add(_segU, uploader, 3);
    for (final g in tags.take(8)) {
      add(_segG, g, 4);
    }
    if (musicTitle.isNotEmpty) {
      add(_segM, musicTitle, 5);
      for (final a in musicArtists.take(4)) {
        add(_segA, a, 6);
      }
    }
    if (chars.length > _maxLen) {
      chars.removeRange(_maxLen, chars.length);
      segs.removeRange(_maxLen, segs.length);
    }
    final fields = [
      for (final s in spans)
        if (s.$2 < _maxLen) (s.$1, s.$2, math.min(s.$3, _maxLen)),
    ];
    final n = chars.length;
    final text = [for (final c in chars) _fold(c)];

    const none = SongReading(
        pNone: 1, pOwn: 0, song: null, performers: [], own: false, names: {});
    final feats = _features(chars, text, fields);
    final cands = _candidates(chars, text, fields);
    if (cands.isEmpty) return none;
    const nf = _nFeat;

    // ---- characters into tokens
    final tokens = <int>[];
    final c2t = List<int>.filled(n, 0);
    if (_modern) {
      _bpe(chars, tokens, c2t);
    } else {
      _wordPiece(chars, text, tokens, c2t);
    }
    final m = tokens.length;
    // A token takes the field of its characters and any feature one has.
    final tSeg = List<int>.filled(m, 0);
    final tFeat = Float32List(m * nf);
    for (var i = 0; i < n; i++) {
      if (chars[i] >= 32 && _isBlank(text[i])) continue;
      final t = c2t[i];
      tSeg[t] = segs[i];
      for (var k = 0; k < nf; k++) {
        final v = feats[i * nf + k];
        if (v > tFeat[t * nf + k]) tFeat[t * nf + k] = v;
      }
    }

    // ---- encoder
    final e = _hidden;
    final word = _w.rows(
        _modern
            ? 'bert.embeddings.tok_embeddings.weight'
            : 'bert.embeddings.word_embeddings.weight',
        tokens);
    final pos =
        _modern ? null : _w['bert.embeddings.position_embeddings.weight']!.v;
    final type =
        _modern ? null : _w['bert.embeddings.token_type_embeddings.weight']!.v;
    final seg = _w['seg.weight']!.v, dur = _w['dur.weight']!.v;
    final featW = _w['feat.weight']!.v, featB = _w['feat.bias']!.v;
    var x = Float32List(m * e);
    for (var i = 0; i < m; i++) {
      final o = i * e;
      for (var j = 0; j < e; j++) {
        var v = word[o + j] + seg[tSeg[i] * e + j] + featB[j];
        if (pos != null) v += pos[i * e + j] + type![j];
        for (var f = 0; f < nf; f++) {
          final fv = tFeat[i * nf + f];
          if (fv != 0) v += featW[j * nf + f] * fv;
        }
        x[o + j] = v;
      }
    }
    final bucket = _durBucket(durationSeconds);
    for (var j = 0; j < e; j++) {
      x[j] += dur[bucket * e + j];
    }
    if (_modern) {
      x = _layerNorm(x, m, 'bert.embeddings.norm');
      for (var l = 0; l < _layers; l++) {
        x = _modernLayer(x, m, l);
      }
      x = _layerNorm(x, m, 'bert.final_norm');
    } else {
      x = _layerNorm(x, m, 'bert.embeddings.LayerNorm', 1e-12);
      for (var l = 0; l < _layers; l++) {
        x = _bertLayer(x, m, 'bert.encoder.layer.$l');
      }
    }
    final ht = _w.containsKey('down.weight') ? _linear(x, m, 'down') : x;
    final d = _head;
    // each character reads the token that covers it
    final h = Float32List(n * d);
    for (var i = 0; i < n; i++) {
      h.setRange(i * d, (i + 1) * d, ht, c2t[i] * d);
    }

    final songP =
        _softmax(_linear(Float32List.sublistView(ht, 0, d), 1, 'song'));

    // ---- judge every candidate span, each seeing the others
    final width = _w['width.weight']!;
    final inDim = 3 * d + 16;
    final rep = Float32List(cands.length * inDim);
    for (var k = 0; k < cands.length; k++) {
      final (a, b) = cands[k];
      final o = k * inDim;
      for (var j = 0; j < d; j++) {
        rep[o + j] = h[a * d + j];
        rep[o + d + j] = h[(b - 1) * d + j];
        var sum = 0.0;
        for (var i = a; i < b; i++) {
          sum += h[i * d + j];
        }
        rep[o + 2 * d + j] = sum / (b - a);
      }
      final wi = math.min(b - a, 40);
      for (var j = 0; j < 16; j++) {
        rep[o + 3 * d + j] = width.v[wi * 16 + j];
      }
    }
    final proj = _gelu(_linear(rep, cands.length, 'proj.0'));
    final count = cands.length + 1;
    final seq = Float32List(count * d);
    seq.setRange(0, d, ht);
    seq.setRange(d, count * d, proj);
    final judged = Float32List.sublistView(_block(seq, count, 'cross'), d);
    final logits = _linear(judged, cands.length, 'out');

    // ---- read the answer off the scores
    String textOf((int, int) c) =>
        String.fromCharCodes(chars.sublist(c.$1, c.$2)).trim();
    final best = <(int, String), _Best>{};
    final names = <String, ({double song, double performer})>{};
    for (var k = 0; k < cands.length; k++) {
      final c = cands[k];
      final key = _norm(textOf(c));
      if (key.isEmpty) continue;
      final p = _softmax(Float32List.sublistView(logits, k * 3, k * 3 + 3));
      final seen = names[key];
      names[key] = (
        song: math.max(seen?.song ?? 0, p[1]),
        performer: math.max(seen?.performer ?? 0, p[2]),
      );
      for (final kind in const [1, 2]) {
        final entry = best.putIfAbsent((kind, key), () => _Best(c));
        if (p[kind] > entry.p) entry.p = p[kind];
        // the title's wording is the one to show
        if (segs[c.$1] == _segT && p[kind] >= entry.titleP) {
          entry.span = c;
          entry.titleP = p[kind];
        }
      }
    }
    int order(
        MapEntry<(int, String), _Best> a, MapEntry<(int, String), _Best> b) {
      final byP = b.value.p.compareTo(a.value.p);
      if (byP != 0) return byP;
      return b.key.$2.compareTo(a.key.$2);
    }

    SongReading reading(String? song, List<String> performers, bool own,
            [double confidence = 0]) =>
        SongReading(
          pNone: songP[0],
          pOwn: songP[2],
          song: song,
          performers: performers,
          own: own,
          names: names,
          confidence: confidence,
        );
    final songs = best.entries.where((s) => s.key.$1 == 1).toList()
      ..sort(order);
    if (songP[0] > 0.5 || songs.isEmpty || songs.first.value.p < 0.3) {
      return reading(null, const [], false);
    }
    final song = songs.first;
    final songText = textOf(song.value.span);
    final kind = songP[1] + songP[2] + 1e-9;
    var sure = math.min(1 - songP[0], song.value.p);
    if (songP[2] > songP[1]) {
      return reading(
          songText, [uploader], true, math.min(sure, songP[2] / kind));
    }
    sure = math.min(sure, songP[1] / kind);
    final singers = best.entries
        .where(
            (s) => s.key.$1 == 2 && s.value.p >= 0.5 && s.key.$2 != song.key.$2)
        .toList()
      ..sort(order);
    final chosen = <(int, int)>[];
    final chosenKeys = <String>[];
    for (final s in singers) {
      final c = s.value.span;
      // a name inside (or around) a better-scored name at the same place is
      // the same mention
      if (chosen.any((o) => c.$1 < o.$2 && o.$1 < c.$2)) continue;
      chosen.add(c);
      chosenKeys.add(s.key.$2);
      sure = math.min(sure, s.value.p);
    }
    // …and nobody else the video names is likely to be singing too
    names.forEach((key, p) {
      if (p.performer <= 0.05 && p.song <= 0.05) return;
      if (key == song.key.$2 ||
          chosenKeys.any((c) => c.contains(key) || key.contains(c))) {
        return;
      }
      sure = math.min(sure, 1 - p.performer);
    });
    chosen.sort((a, b) => a.$1.compareTo(b.$1));
    return reading(songText, [for (final c in chosen) textOf(c)], false, sure);
  }

  /// BERT's tokenizer: a character each for Chinese and punctuation, the
  /// longest known pieces for any other word.
  void _wordPiece(
      List<int> chars, List<int> text, List<int> tokens, List<int> c2t) {
    final unk = _unkId, clsId = _clsId, sepId = _sepId;
    final n = chars.length;
    bool wordChar(int c) =>
        c >= 32 && !_isBlank(c) && !_isCjk(c) && !_isPunct(c);
    for (var i = 0; i < n;) {
      final c = chars[i];
      if (c == 1) {
        tokens.add(clsId);
        c2t[i++] = tokens.length - 1;
        continue;
      }
      if (c >= 2 && c <= 6) {
        tokens.add(sepId);
        c2t[i++] = tokens.length - 1;
        continue;
      }
      final f = text[i];
      if (_isBlank(f)) {
        c2t[i++] = math.max(0, tokens.length - 1);
        continue;
      }
      if (_isCjk(f) || _isPunct(f)) {
        tokens.add(_vocab[String.fromCharCode(f)] ?? unk);
        c2t[i++] = tokens.length - 1;
        continue;
      }
      var j = i;
      while (j < n && chars[j] >= 32 && wordChar(text[j])) {
        j++;
      }
      final word = text.sublist(i, j);
      final pieces = <(int, int, int)>[];
      var bad = word.length > 100;
      for (var k = 0; k < word.length && !bad;) {
        var e = word.length;
        (int, int, int)? cur;
        while (e > k) {
          final s = (k == 0 ? '' : '##') + String.fromCharCodes(word, k, e);
          final id = _vocab[s];
          if (id != null) {
            cur = (id, k, e);
            break;
          }
          e--;
        }
        if (cur == null) {
          bad = true;
        } else {
          pieces.add(cur);
          k = cur.$3;
        }
      }
      if (bad) {
        tokens.add(unk);
        for (var x = i; x < j; x++) {
          c2t[x] = tokens.length - 1;
        }
      } else {
        for (final (id, a, b) in pieces) {
          tokens.add(id);
          for (var x = i + a; x < i + b; x++) {
            c2t[x] = tokens.length - 1;
          }
        }
      }
      i = j;
    }
  }

  /// mmBERT's tokenizer: a space becomes '▁' and one is put before every
  /// field; each run from one '▁' to the next is merged pair by pair, lowest
  /// rank first; a character the vocabulary lacks becomes its UTF-8 bytes.
  void _bpe(List<int> chars, List<int> tokens, List<int> c2t) {
    final n = chars.length;
    for (var i = 0; i < n;) {
      final c = chars[i];
      if (c < 32) {
        tokens.add(c == 1 ? _clsId : _sepId);
        c2t[i++] = tokens.length - 1;
        continue;
      }
      var j = i;
      while (j < n && chars[j] >= 32) {
        j++;
      }
      // the field, with its '▁' in front (which no character of it is)
      final field = [
        for (var x = i; x < j; x++) chars[x] == 0x20 ? 0x2581 : chars[x]
      ];
      final pre = field.first != 0x2581 ? 1 : 0;
      if (pre == 1) field.insert(0, 0x2581);
      final cover = List<int>.filled(j - i, -1);
      for (var a = 0; a < field.length;) {
        var b = a + 1;
        while (b < field.length && field[b] != 0x2581) {
          b++;
        }
        for (final (token, from, to) in _bpeWord(field.sublist(a, b))) {
          tokens.add(_vocab[token] ?? _unkId);
          for (var x = math.max(a + from - pre, 0); x < a + to - pre; x++) {
            if (cover[x] < 0) cover[x] = tokens.length - 1;
          }
        }
        a = b;
      }
      var last = math.max(0, tokens.length - 1);
      for (var x = 0; x < j - i; x++) {
        if (cover[x] < 0) {
          cover[x] = last;
        } else {
          last = cover[x];
        }
        c2t[i + x] = cover[x];
      }
      i = j;
    }
  }

  List<(String, int, int)> _bpeWord(List<int> word) {
    var symbols = <(String, int, int)>[];
    for (var i = 0; i < word.length; i++) {
      final c = String.fromCharCode(word[i]);
      if (_vocab.containsKey(c)) {
        symbols.add((c, i, i + 1));
      } else {
        for (final byte in utf8.encode(c)) {
          symbols.add((
            '<0x${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}>',
            i,
            i + 1
          ));
        }
      }
    }
    while (symbols.length > 1) {
      int? best;
      var at = -1;
      for (var k = 0; k + 1 < symbols.length; k++) {
        final rank = _merges['${symbols[k].$1}\x00${symbols[k + 1].$1}'];
        if (rank != null && (best == null || rank < best)) {
          best = rank;
          at = k;
        }
      }
      if (best == null) break;
      final left = symbols[at].$1, right = symbols[at + 1].$1;
      final merged = <(String, int, int)>[];
      for (var k = 0; k < symbols.length;) {
        if (k + 1 < symbols.length &&
            symbols[k].$1 == left &&
            symbols[k + 1].$1 == right) {
          merged.add((left + right, symbols[k].$2, symbols[k + 1].$3));
          k += 2;
        } else {
          merged.add(symbols[k++]);
        }
      }
      symbols = merged;
    }
    return symbols;
  }

  static bool _isCjk(int c) =>
      (c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0x20000 && c <= 0x2A6DF) ||
      (c >= 0x2A700 && c <= 0x2CEAF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0x2F800 && c <= 0x2FA1F);

  static bool _isPunct(int c) =>
      (c >= 33 && c <= 47) ||
      (c >= 58 && c <= 64) ||
      (c >= 91 && c <= 96) ||
      (c >= 123 && c <= 126) ||
      (c >= 0x80 && _punctuation.hasMatch(String.fromCharCode(c)));

  static bool _isBlank(int c) =>
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0D ||
      _blank.hasMatch(String.fromCharCode(c));

  // ---------------------------------------------------------------- text

  static int _fold(int c) {
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
    if (c == 0x3000 || c == 0xA0) return 0x20;
    if (c < 0x41) return c;
    if (c <= 0x5A) return c + 32;
    if (c < 0x80) return c;
    final lower = String.fromCharCode(c).toLowerCase().runes;
    return lower.isEmpty ? 0x20 : lower.first;
  }

  static String _norm(String s) {
    final out = StringBuffer();
    for (final r in s.runes) {
      final c = String.fromCharCode(_fold(r));
      if (_letterOrNumber.hasMatch(c)) out.write(c);
    }
    return out.toString();
  }

  static bool _asciiAlnum(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A);

  static bool _isDelim(int c) =>
      c < 32 || c == 0x4E28 || _delimiter.hasMatch(String.fromCharCode(c));

  static int _durBucket(int seconds) {
    const limits = [60, 120, 180, 240, 300, 360, 480, 600, 900];
    for (var i = 0; i < limits.length; i++) {
      if (seconds < limits[i]) return i;
    }
    return 9;
  }

  /// Every start of [needle] in text[from, to).
  static Iterable<int> _findAll(
      List<int> text, int from, int to, List<int> needle) sync* {
    if (needle.isEmpty) return;
    outer:
    for (var i = from; i + needle.length <= to; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (text[i + j] != needle[j]) continue outer;
      }
      yield i;
    }
  }

  /// [a, b) without surrounding whitespace, as Python's str.strip() would leave it.
  static List<int> _stripped(List<int> text, int a, int b) {
    while (a < b && _isSpace(text[a])) {
      a++;
    }
    while (b > a && _isSpace(text[b - 1])) {
      b--;
    }
    return text.sublist(a, b);
  }

  static bool _isSpace(int c) =>
      c == 0x20 ||
      (c >= 0x09 && c <= 0x0D) ||
      (c >= 0x1C && c <= 0x1F) ||
      c == 0x85 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202F ||
      c == 0x205F;

  /// A singer's name starting at [i] within [a, b): its length, or 0.
  int _lexAt(List<int> text, int i, int a, int b) {
    for (var len = math.min(_lexMax, b - i); len > 1; len--) {
      if (!_lex.contains(String.fromCharCodes(text, i, i + len))) continue;
      // latin names must not be cut out of a longer word
      if (text[i] < 0x80 &&
          ((i > a && _asciiAlnum(text[i - 1])) ||
              (i + len < b && _asciiAlnum(text[i + len])))) {
        continue;
      }
      return len;
    }
    return 0;
  }

  /// Per character: does this text also stand in another field; is it bracketed; is it a known singer.
  Float32List _features(
      List<int> chars, List<int> text, List<(int, int, int)> fields) {
    final n = chars.length;
    final f = Float32List(n * _nFeat);
    List<(int, int)> of(int seg) => [
          for (final s in fields)
            if (s.$1 == seg) (s.$2, s.$3),
        ];
    final titles = of(_segT);
    final title = titles.isEmpty ? (1, 1) : titles.first;

    void mark((int, int) needle, (int, int) hay, int iNeedle, int iHay) {
      final s = _stripped(text, needle.$1, needle.$2);
      if (s.length < 2 &&
          !(s.length == 1 && s[0] >= 0x4E00 && s[0] <= 0x9FFF)) {
        return;
      }
      var hit = false;
      for (final k in _findAll(text, hay.$1, hay.$2, s)) {
        hit = true;
        for (var j = k; j < k + s.length; j++) {
          f[j * _nFeat + iHay] = 1;
        }
      }
      if (hit) {
        for (var j = needle.$1; j < needle.$2; j++) {
          f[j * _nFeat + iNeedle] = 1;
        }
      }
    }

    final ups = of(_segU), tags = of(_segG);
    for (final g in tags) {
      mark(g, title, 0, 1);
      for (final u in ups) {
        mark(g, u, 2, 2);
      }
    }
    for (final m in of(_segM)) {
      mark(m, title, 3, 4);
      for (final g in tags) {
        mark(m, g, 3, 5);
      }
    }
    for (final a in of(_segA)) {
      mark(a, title, 6, 7);
      for (final g in tags) {
        mark(a, g, 6, 8);
      }
    }
    for (final u in ups) {
      mark(u, title, 9, 9);
    }
    for (final s in fields) {
      var i = s.$2;
      while (i < s.$3) {
        final hit = _lexAt(text, i, s.$2, s.$3);
        if (hit > 0) {
          for (var j = i; j < i + hit; j++) {
            f[j * _nFeat + 10] = 1;
          }
          i += hit;
        } else {
          i++;
        }
      }
    }
    var book = 0, other = 0;
    for (var i = 0; i < n; i++) {
      final c = chars[i];
      if (c == 0x300A) book++;
      if ('【[「『(（'.runes.contains(c)) other++;
      f[i * _nFeat + 11] = math.min(book, 1).toDouble();
      f[i * _nFeat + 12] = math.min(other, 1).toDouble();
      if (c == 0x300B) book = math.max(0, book - 1);
      if ('】]」』)）'.runes.contains(c)) other = math.max(0, other - 1);
      if (c >= 2 && c <= 6) book = other = 0;
    }
    return f;
  }

  /// The spans worth judging: whole tags and names, bracketed text, pieces between punctuation,
  /// known strings found in the title and what is left between them.
  List<(int, int)> _candidates(
      List<int> chars, List<int> text, List<(int, int, int)> fields) {
    final out = <(int, int)>{};
    void add(int a, int b) {
      while (a < b && chars[a] <= 0x20) {
        a++;
      }
      while (b > a && chars[b - 1] <= 0x20) {
        b--;
      }
      if (b > a && b - a <= 40) out.add((a, b));
    }

    (int, int)? title;
    final needles = <String, List<int>>{};
    for (final s in fields) {
      if (s.$1 == _segT) {
        title = (s.$2, s.$3);
      } else {
        add(s.$2, s.$3);
        final w = _stripped(text, s.$2, s.$3);
        if (w.length >= 2 || (s.$1 == _segM && w.isNotEmpty)) {
          needles[String.fromCharCodes(w)] = w;
        }
      }
    }
    if (title != null) {
      final (a, b) = title;
      final stack = <(int, int)>[];
      for (var i = a; i < b; i++) {
        final c = chars[i];
        final k = _close.indexOf(c);
        if (k >= 0 && stack.isNotEmpty && stack.last.$1 == k) {
          add(stack.removeLast().$2 + 1, i);
        } else {
          final o = _open.indexOf(c);
          if (o >= 0) stack.add((o, i));
        }
      }
      final cuts = <(int, int)>{};
      for (final w in needles.values) {
        for (final k in _findAll(text, a, b, w)) {
          add(k, k + w.length);
          cuts.add((k, k + w.length));
        }
      }
      if (_lex.isNotEmpty) {
        for (var i = a; i < b; i++) {
          final len = _lexAt(text, i, a, b);
          if (len > 0) {
            add(i, i + len);
            cuts.add((i, i + len));
          }
        }
      }
      for (final kw in _keywords) {
        final w = kw.runes.toList();
        for (final k in _findAll(text, a, b, w)) {
          cuts.add((k, k + w.length));
        }
      }
      final pieces = <(int, int)>[];
      var i = a;
      while (i < b) {
        if (_isDelim(chars[i])) {
          i++;
          continue;
        }
        var j = i;
        while (j < b && !_isDelim(chars[j])) {
          j++;
        }
        pieces.add((i, j));
        i = j;
      }
      for (var k = 0; k < pieces.length; k++) {
        final (i, j) = pieces[k];
        add(i, j);
        for (var m = 1; m < 4; m++) {
          // "Golden Hour", "Taylor Swift": words one space apart
          if (k + m < pieces.length &&
              pieces[k + m].$1 - pieces[k + m - 1].$2 == 1 &&
              chars[pieces[k + m - 1].$2] == 0x20) {
            add(i, pieces[k + m].$2);
          } else {
            break;
          }
        }
        final edges = <int>{i, j};
        for (final c in cuts) {
          if (c.$1 >= i && c.$2 <= j) {
            edges
              ..add(c.$1)
              ..add(c.$2);
          }
        }
        final sorted = edges.toList()..sort();
        for (var x = 0; x < sorted.length; x++) {
          for (var y = x + 1; y < math.min(x + 4, sorted.length); y++) {
            if (sorted[x] != i || sorted[y] != j) add(sorted[x], sorted[y]);
          }
        }
      }
    }
    int byStart((int, int) p, (int, int) q) =>
        p.$1 != q.$1 ? p.$1.compareTo(q.$1) : p.$2.compareTo(q.$2);
    var cands = out.toList()..sort(byStart);
    if (cands.length > _maxCand) {
      final end = title?.$2 ?? 0;
      final keep = [
        for (final c in cands)
          if (title == null || c.$1 >= end) c
      ];
      final rest = [
        for (final c in cands)
          if (title != null && c.$1 < end) c
      ];
      // short spans first; the order within a group stays by position
      final short = [
        for (final c in rest)
          if (c.$2 - c.$1 <= 12) c
      ];
      final long = [
        for (final c in rest)
          if (c.$2 - c.$1 > 12) c
      ];
      final room = math.max(0, _maxCand - keep.length);
      cands = [
        ...keep,
        ...[...short, ...long].take(room)
      ]..sort(byStart);
    }
    return cands;
  }

  // ---------------------------------------------------------------- maths

  /// rows × in → rows × out with the weights stored as [out, in].
  ///
  /// This is nearly all of the work, so it is done four floats at a time
  /// where the widths allow (they do everywhere but the feature columns).
  Float32List _linear(Float32List x, int rows, String name) {
    final w = _w['$name.weight']!, b = _w['$name.bias']?.v;
    final outDim = w.shape[0], inDim = w.shape[1];
    final y = Float32List(rows * outDim);
    if (inDim % 4 == 0 && x.offsetInBytes % 16 == 0) {
      final quads = inDim ~/ 4;
      final w4 = w.quads;
      final x4 = Float32x4List.view(x.buffer, x.offsetInBytes, rows * quads);
      for (var r = 0; r < rows; r++) {
        final xo = r * quads;
        for (var o = 0; o < outDim; o++) {
          var sum = Float32x4.zero();
          final wo = o * quads;
          for (var i = 0; i < quads; i++) {
            sum += w4[wo + i] * x4[xo + i];
          }
          y[r * outDim + o] =
              sum.x + sum.y + sum.z + sum.w + (b == null ? 0.0 : b[o]);
        }
      }
      return y;
    }
    for (var r = 0; r < rows; r++) {
      final xo = r * inDim;
      for (var o = 0; o < outDim; o++) {
        var sum = b == null ? 0.0 : b[o];
        final wo = o * inDim;
        for (var i = 0; i < inDim; i++) {
          sum += w.v[wo + i] * x[xo + i];
        }
        y[r * outDim + o] = sum;
      }
    }
    return y;
  }

  Float32List _layerNorm(Float32List x, int rows, String name,
      [double eps = 1e-5]) {
    final g = _w['$name.weight']!.v, b = _w['$name.bias']?.v;
    final d = g.length;
    final y = Float32List(x.length);
    for (var r = 0; r < rows; r++) {
      final o = r * d;
      var mean = 0.0;
      for (var j = 0; j < d; j++) {
        mean += x[o + j];
      }
      mean /= d;
      var variance = 0.0;
      for (var j = 0; j < d; j++) {
        final t = x[o + j] - mean;
        variance += t * t;
      }
      final scale = 1 / math.sqrt(variance / d + eps);
      for (var j = 0; j < d; j++) {
        y[o + j] = (x[o + j] - mean) * scale * g[j] + (b == null ? 0 : b[j]);
      }
    }
    return y;
  }

  static Float32List _softmax(Float32List x) {
    var top = x[0];
    for (final v in x) {
      if (v > top) top = v;
    }
    final y = Float32List(x.length);
    var sum = 0.0;
    for (var i = 0; i < x.length; i++) {
      y[i] = math.exp(x[i] - top);
      sum += y[i];
    }
    for (var i = 0; i < x.length; i++) {
      y[i] /= sum;
    }
    return y;
  }

  static Float32List _gelu(Float32List x) {
    for (var i = 0; i < x.length; i++) {
      x[i] = 0.5 * x[i] * (1 + _erf(x[i] / math.sqrt2));
    }
    return x;
  }

  // Abramowitz & Stegun 7.1.26, |error| < 1.5e-7
  static double _erf(double x) {
    final sign = x < 0 ? -1.0 : 1.0;
    x = x.abs();
    final t = 1 / (1 + 0.3275911 * x);
    final y = 1 -
        (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t -
                        0.284496736) *
                    t +
                0.254829592) *
            t *
            math.exp(-x * x);
    return sign * y;
  }

  /// One pre-norm transformer block: x + attention(norm(x)), then x + feed-forward(norm(x)).
  Float32List _block(Float32List x, int n, String name) {
    final d = _head, hd = d ~/ _crossHeads;
    const heads = _crossHeads;
    final normed = _layerNorm(x, n, '$name.norm1');
    final wIn = _w['$name.self_attn.in_proj_weight']!.v,
        bIn = _w['$name.self_attn.in_proj_bias']!.v;
    final qkv = Float32List(n * 3 * d);
    for (var r = 0; r < n; r++) {
      final xo = r * d;
      for (var o = 0; o < 3 * d; o++) {
        var sum = bIn[o];
        final wo = o * d;
        for (var i = 0; i < d; i++) {
          sum += wIn[wo + i] * normed[xo + i];
        }
        qkv[r * 3 * d + o] = sum;
      }
    }
    final mixed = Float32List(n * d);
    final scale = 1 / math.sqrt(hd);
    final scores = Float32List(n);
    for (var hI = 0; hI < heads; hI++) {
      final qo = hI * hd, ko = d + hI * hd, vo = 2 * d + hI * hd;
      for (var i = 0; i < n; i++) {
        var top = double.negativeInfinity;
        for (var j = 0; j < n; j++) {
          var dot = 0.0;
          for (var k = 0; k < hd; k++) {
            dot += qkv[i * 3 * d + qo + k] * qkv[j * 3 * d + ko + k];
          }
          dot *= scale;
          scores[j] = dot;
          if (dot > top) top = dot;
        }
        var sum = 0.0;
        for (var j = 0; j < n; j++) {
          scores[j] = math.exp(scores[j] - top);
          sum += scores[j];
        }
        for (var j = 0; j < n; j++) {
          final p = scores[j] / sum;
          if (p < 1e-9) continue;
          for (var k = 0; k < hd; k++) {
            mixed[i * d + qo + k] += p * qkv[j * 3 * d + vo + k];
          }
        }
      }
    }
    final attended = _linear(mixed, n, '$name.self_attn.out_proj');
    final y = Float32List(n * d);
    for (var i = 0; i < y.length; i++) {
      y[i] = x[i] + attended[i];
    }
    final ff = _linear(
        _gelu(_linear(_layerNorm(y, n, '$name.norm2'), n, '$name.linear1')),
        n,
        '$name.linear2');
    for (var i = 0; i < y.length; i++) {
      y[i] += ff[i];
    }
    return y;
  }

  /// Tokens a local layer lets one attend to on either side; every third
  /// layer sees them all.
  static const _window = 64, _globalEvery = 3;
  static const _ropeTheta = 160000.0;

  /// One ModernBERT layer: attention over rotated queries and keys, then a
  /// gated feed-forward, each on the normalised input and added back.
  Float32List _modernLayer(Float32List x, int n, int layer) {
    final name = 'bert.layers.$layer';
    final d = _hidden, heads = _heads, hd = d ~/ heads, half = hd ~/ 2;
    final normed = layer == 0 ? x : _layerNorm(x, n, '$name.attn_norm');
    final qkv = _linear(normed, n, '$name.attn.Wqkv');
    // rotate queries and keys by position
    final cos = Float32List(n * half), sin = Float32List(n * half);
    for (var p = 0; p < n; p++) {
      for (var k = 0; k < half; k++) {
        final angle = p / math.pow(_ropeTheta, 2 * k / hd);
        cos[p * half + k] = math.cos(angle);
        sin[p * half + k] = math.sin(angle);
      }
    }
    for (var p = 0; p < n; p++) {
      for (var part = 0; part < 2; part++) {
        for (var hI = 0; hI < heads; hI++) {
          final o = p * 3 * d + part * d + hI * hd;
          for (var k = 0; k < half; k++) {
            final a = qkv[o + k], b = qkv[o + half + k];
            final c = cos[p * half + k], s = sin[p * half + k];
            qkv[o + k] = a * c - b * s;
            qkv[o + half + k] = b * c + a * s;
          }
        }
      }
    }
    final local = layer % _globalEvery != 0;
    final mixed = Float32List(n * d);
    final scale = 1 / math.sqrt(hd);
    final scores = Float32List(n);
    for (var hI = 0; hI < heads; hI++) {
      final ho = hI * hd;
      for (var i = 0; i < n; i++) {
        final from = local ? math.max(0, i - _window) : 0;
        final to = local ? math.min(n, i + _window + 1) : n;
        var top = double.negativeInfinity;
        final qi = i * 3 * d + ho;
        for (var j = from; j < to; j++) {
          var dot = 0.0;
          final kj = j * 3 * d + d + ho;
          for (var c = 0; c < hd; c++) {
            dot += qkv[qi + c] * qkv[kj + c];
          }
          dot *= scale;
          scores[j] = dot;
          if (dot > top) top = dot;
        }
        var sum = 0.0;
        for (var j = from; j < to; j++) {
          scores[j] = math.exp(scores[j] - top);
          sum += scores[j];
        }
        final mi = i * d + ho;
        for (var j = from; j < to; j++) {
          final p = scores[j] / sum;
          if (p < 1e-9) continue;
          final vj = j * 3 * d + 2 * d + ho;
          for (var c = 0; c < hd; c++) {
            mixed[mi + c] += p * qkv[vj + c];
          }
        }
      }
    }
    final y = _linear(mixed, n, '$name.attn.Wo');
    for (var i = 0; i < y.length; i++) {
      y[i] += x[i];
    }
    final wide = _linear(_layerNorm(y, n, '$name.mlp_norm'), n, '$name.mlp.Wi');
    final inner = wide.length ~/ n ~/ 2;
    final gated = Float32List(n * inner);
    for (var r = 0; r < n; r++) {
      for (var k = 0; k < inner; k++) {
        final v = wide[r * 2 * inner + k];
        gated[r * inner + k] = 0.5 *
            v *
            (1 + _erf(v / math.sqrt2)) *
            wide[r * 2 * inner + inner + k];
      }
    }
    final out = _linear(gated, n, '$name.mlp.Wo');
    for (var i = 0; i < out.length; i++) {
      out[i] += y[i];
    }
    return out;
  }

  /// One BERT layer: attention and feed-forward, each added back and then
  /// normalised.
  Float32List _bertLayer(Float32List x, int n, String name) {
    final d = _hidden, heads = _heads, hd = d ~/ heads;
    final q = _linear(x, n, '$name.attention.self.query');
    final k = _linear(x, n, '$name.attention.self.key');
    final v = _linear(x, n, '$name.attention.self.value');
    final mixed = Float32List(n * d);
    final scale = 1 / math.sqrt(hd);
    final scores = Float32List(n);
    for (var hI = 0; hI < heads; hI++) {
      final ho = hI * hd;
      for (var i = 0; i < n; i++) {
        var top = double.negativeInfinity;
        final qi = i * d + ho;
        for (var j = 0; j < n; j++) {
          var dot = 0.0;
          final kj = j * d + ho;
          for (var c = 0; c < hd; c++) {
            dot += q[qi + c] * k[kj + c];
          }
          dot *= scale;
          scores[j] = dot;
          if (dot > top) top = dot;
        }
        var sum = 0.0;
        for (var j = 0; j < n; j++) {
          scores[j] = math.exp(scores[j] - top);
          sum += scores[j];
        }
        for (var j = 0; j < n; j++) {
          final p = scores[j] / sum;
          if (p < 1e-9) continue;
          final vj = j * d + ho;
          for (var c = 0; c < hd; c++) {
            mixed[qi + c] += p * v[vj + c];
          }
        }
      }
    }
    final attended = _linear(mixed, n, '$name.attention.output.dense');
    for (var i = 0; i < attended.length; i++) {
      attended[i] += x[i];
    }
    final y =
        _layerNorm(attended, n, '$name.attention.output.LayerNorm', 1e-12);
    final ff = _linear(_gelu(_linear(y, n, '$name.intermediate.dense')), n,
        '$name.output.dense');
    for (var i = 0; i < ff.length; i++) {
      ff[i] += y[i];
    }
    return _layerNorm(ff, n, '$name.output.LayerNorm', 1e-12);
  }
}

class _Tensor {
  _Tensor(this.v, this.shape);
  final Float32List v;
  final List<int> shape;

  /// [v] four at a time (its length is then a multiple of four).
  late final Float32x4List quads =
      Float32x4List.view(v.buffer, v.offsetInBytes, v.length ~/ 4);
}

/// The model's tensors, unpacked from the file as each is asked for: a
/// matrix is float16, or one int8 row per output unit with its own scale.
/// Only the small ones are kept — a layer's matrices are megabytes each
/// and used once per video — so the model is never in memory twice over.
class _Weights {
  _Weights(this._data, this._base, this._index);

  final ByteData _data;
  final int _base;
  final Map<String, Map> _index;
  final Map<String, _Tensor> _kept = {};

  bool containsKey(String name) => _index.containsKey(name);

  _Tensor? operator [](String name) {
    final kept = _kept[name];
    if (kept != null) return kept;
    final t = _index[name];
    if (t == null) return null;
    final shape = (t['shape'] as List).cast<int>();
    final count = shape.fold<int>(1, (a, b) => a * b);
    final values = Float32List(count);
    final rows = shape[0], cols = count ~/ rows;
    for (var r = 0; r < rows; r++) {
      _row(t, r, cols, rows, values, r * cols);
    }
    final tensor = _Tensor(values, shape);
    if (count <= 1 << 16) _kept[name] = tensor;
    return tensor;
  }

  /// The rows [ids] of an embedding table, one after another.
  Float32List rows(String name, List<int> ids) {
    final t = _index[name]!;
    final shape = (t['shape'] as List).cast<int>();
    final out = Float32List(ids.length * shape[1]);
    for (var i = 0; i < ids.length; i++) {
      _row(t, ids[i], shape[1], shape[0], out, i * shape[1]);
    }
    return out;
  }

  void _row(Map t, int r, int cols, int rows, Float32List out, int at) {
    final start = _base + (t['offset'] as int);
    if (t['q'] == 8) {
      final scale = _data.getFloat32(start + r * 4, Endian.little);
      final from = start + rows * 4 + r * cols;
      for (var c = 0; c < cols; c++) {
        out[at + c] = _data.getInt8(from + c) * scale;
      }
    } else {
      final from = start + r * cols * 2;
      for (var c = 0; c < cols; c++) {
        out[at + c] = _half(_data.getUint16(from + c * 2, Endian.little));
      }
    }
  }

  static double _half(int bits) {
    final sign = (bits & 0x8000) != 0 ? -1.0 : 1.0;
    final exponent = (bits >> 10) & 0x1F, fraction = bits & 0x3FF;
    if (exponent == 0) return sign * fraction * 5.960464477539063e-8; // 2^-24
    if (exponent == 31) {
      return fraction == 0 ? sign * double.infinity : double.nan;
    }
    return sign * (1 + fraction / 1024) * math.pow(2, exponent - 15);
  }
}

class _Best {
  _Best(this.span);
  double p = 0, titleP = 0;
  (int, int) span;
}
