import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// What the model reads off a video: the song and who is heard singing it.
class SongGuess {
  const SongGuess(this.song, this.performers, {required this.own, required this.confidence});

  final String song;
  final List<String> performers;

  /// The uploader's own version (a cover, a play-along) rather than a singer the video names.
  final bool own;

  /// How sure the model is that this is one song at all, 0–1.
  final double confidence;
}

/// A small transformer that names a video's song and performers from its title, uploader, tags
/// and the music Bilibili recognised. Every answer is a span copied from those inputs.
///
/// Trained off-device (see tool/song_model/); this is inference only, in plain Dart.
class SongModel {
  SongModel._(this._d, this._layers, this._heads, this._vocab, this._w, this._lex, this._lexMax);

  factory SongModel.load(Uint8List model, String singers) {
    final data = ByteData.sublistView(model);
    final headerLength = data.getUint32(0, Endian.little);
    final header = jsonDecode(utf8.decode(model.sublist(4, 4 + headerLength))) as Map;
    final base = 4 + headerLength;
    final weights = <String, _Tensor>{};
    for (final t in (header['tensors'] as List).cast<Map>()) {
      final shape = (t['shape'] as List).cast<int>();
      final count = shape.fold<int>(1, (a, b) => a * b);
      final values = Float32List(count);
      var at = base + (t['offset'] as int);
      for (var i = 0; i < count; i++, at += 2) {
        values[i] = _half(data.getUint16(at, Endian.little));
      }
      weights[t['name'] as String] = _Tensor(values, shape);
    }
    final vocab = <int, int>{};
    final codes = (header['vocab'] as List).cast<int>();
    for (var i = 0; i < codes.length; i++) {
      vocab[codes[i]] = i;
    }
    final lex = singers.split('\n').where((s) => s.isNotEmpty).toSet();
    var longest = 0;
    for (final s in lex) {
      longest = math.max(longest, s.runes.length);
    }
    return SongModel._(header['d'] as int, header['layers'] as int, header['heads'] as int, vocab,
        weights, lex, longest);
  }

  final int _d, _layers, _heads;
  final Map<int, int> _vocab;
  final Map<String, _Tensor> _w;
  final Set<String> _lex;
  final int _lexMax;

  static const _maxLen = 256, _nFeat = 13, _maxCand = 96;
  static const _segT = 1, _segU = 2, _segG = 3, _segM = 4, _segA = 5;
  static final _open = '《「『【[（(“"〈<'.runes.toList();
  static final _close = '》」』】]）)”"〉>'.runes.toList();
  static const _keywords = [
    '翻唱', '翻自', 'cover', 'feat.', 'feat', 'ft.', '合唱', '演唱', '原唱', '献唱', '弹唱', '演绎', '共唱',
    '对唱', '主题曲', '片尾曲', '片头曲', '插曲', '推广曲', '纯享', '现场', 'live', '版', 'mv', '官方',
    '完整', '首唱', '再唱', '一曲', '歌曲', '唱', //
  ];
  static final _letterOrNumber = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _letter = RegExp(r'\p{L}', unicode: true);
  static final _delimiter = RegExp(r'[\p{P}\p{Z}\p{S}]', unicode: true);

  SongGuess? guess({
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

    final feats = _features(chars, text, fields);
    final cands = _candidates(chars, text, fields);
    if (cands.isEmpty) return null;

    // ---- encoder
    final d = _d;
    final tok = _w['enc.tok.weight']!, seg = _w['enc.seg.weight']!, pos = _w['enc.pos.weight']!;
    final cls = _w['enc.cls.weight']!, dur = _w['enc.dur.weight']!;
    final featW = _w['enc.feat.weight']!, featB = _w['enc.feat.bias']!;
    var x = Float32List(n * d);
    for (var i = 0; i < n; i++) {
      final c = chars[i];
      final id = _vocab[c < 32 ? c : text[i]] ?? 1;
      final k = _charClass(text[i]);
      final o = i * d;
      for (var j = 0; j < d; j++) {
        var v = tok.v[id * d + j] + seg.v[segs[i] * d + j] + pos.v[i * d + j] + cls.v[k * d + j] + featB.v[j];
        for (var f = 0; f < _nFeat; f++) {
          final fv = feats[i * _nFeat + f];
          if (fv != 0) v += featW.v[j * _nFeat + f] * fv;
        }
        x[o + j] = v;
      }
    }
    final bucket = _durBucket(durationSeconds);
    for (var j = 0; j < d; j++) {
      x[j] += dur.v[bucket * d + j];
    }
    x = _layerNorm(x, n, 'enc.norm');
    for (var l = 0; l < _layers; l++) {
      x = _block(x, n, 'enc.enc.layers.$l');
    }
    final h = _layerNorm(x, n, 'enc.out_norm');

    final songP = _softmax(_linear(Float32List.sublistView(h, 0, d), 1, 'enc.song'));
    if (songP[0] > 0.5) return null;
    final own = songP[2] > songP[1];

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
    Float32List judged;
    if (_w.containsKey('cross.norm1.weight')) {
      final m = cands.length + 1;
      final seq = Float32List(m * d);
      seq.setRange(0, d, h);
      seq.setRange(d, m * d, proj);
      judged = Float32List.sublistView(_block(seq, m, 'cross'), d);
    } else {
      judged = proj;
    }
    final logits = _linear(judged, cands.length, 'out');

    // ---- read the answer off the scores
    String textOf((int, int) c) => String.fromCharCodes(chars.sublist(c.$1, c.$2)).trim();
    final best = <(int, String), _Best>{};
    for (var k = 0; k < cands.length; k++) {
      final c = cands[k];
      final key = _norm(textOf(c));
      if (key.isEmpty) continue;
      final p = _softmax(Float32List.sublistView(logits, k * 3, k * 3 + 3));
      for (final kind in const [1, 2]) {
        final e = best.putIfAbsent((kind, key), () => _Best(c));
        if (p[kind] > e.p) e.p = p[kind];
        // the title's wording is the one to show
        if (segs[c.$1] == _segT && p[kind] >= e.titleP) {
          e.span = c;
          e.titleP = p[kind];
        }
      }
    }
    int order(MapEntry<(int, String), _Best> a, MapEntry<(int, String), _Best> b) {
      final byP = b.value.p.compareTo(a.value.p);
      if (byP != 0) return byP;
      return b.key.$2.compareTo(a.key.$2);
    }

    final songs = best.entries.where((e) => e.key.$1 == 1).toList()..sort(order);
    if (songs.isEmpty || songs.first.value.p < 0.3) return null;
    final song = songs.first;
    final songText = textOf(song.value.span);
    final confidence = 1 - songP[0];
    if (own) return SongGuess(songText, [uploader], own: true, confidence: confidence);
    final singers = best.entries
        .where((e) => e.key.$1 == 2 && e.value.p >= 0.5 && e.key.$2 != song.key.$2)
        .toList()
      ..sort(order);
    final chosen = <(int, int)>[];
    for (final s in singers) {
      final c = s.value.span;
      // a name inside (or around) a better-scored name at the same place is the same mention
      if (chosen.any((o) => c.$1 < o.$2 && o.$1 < c.$2)) continue;
      chosen.add(c);
    }
    chosen.sort((a, b) => a.$1.compareTo(b.$1));
    return SongGuess(songText, [for (final c in chosen) textOf(c)], own: false, confidence: confidence);
  }

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

  static bool _asciiAlnum(int c) => (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

  static int _charClass(int c) {
    if (c >= 0x4E00 && c <= 0x9FFF) return 0;
    if ((c >= 0x3040 && c <= 0x30FF) || (c >= 0xAC00 && c <= 0xD7A3)) return 1;
    if (c >= 0x30 && c <= 0x39) return 3;
    if (c >= 32 && _letter.hasMatch(String.fromCharCode(c))) return 2;
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) return 4;
    if (c == 0x300A || c == 0x300B) return 5;
    if ('【】[]「」『』()<>“”"'.runes.contains(c)) return 6;
    return 7;
  }

  static bool _isDelim(int c) => c < 32 || c == 0x4E28 || _delimiter.hasMatch(String.fromCharCode(c));

  static int _durBucket(int seconds) {
    const limits = [60, 120, 180, 240, 300, 360, 480, 600, 900];
    for (var i = 0; i < limits.length; i++) {
      if (seconds < limits[i]) return i;
    }
    return 9;
  }

  /// Every start of [needle] in text[from, to).
  static Iterable<int> _findAll(List<int> text, int from, int to, List<int> needle) sync* {
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

  static bool _isSpace(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0D) || (c >= 0x1C && c <= 0x1F) || c == 0x85 ||
      c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F;

  /// A singer's name starting at [i] within [a, b): its length, or 0.
  int _lexAt(List<int> text, int i, int a, int b) {
    for (var len = math.min(_lexMax, b - i); len > 1; len--) {
      if (!_lex.contains(String.fromCharCodes(text, i, i + len))) continue;
      // latin names must not be cut out of a longer word
      if (text[i] < 0x80 &&
          ((i > a && _asciiAlnum(text[i - 1])) || (i + len < b && _asciiAlnum(text[i + len])))) {
        continue;
      }
      return len;
    }
    return 0;
  }

  /// Per character: does this text also stand in another field; is it bracketed; is it a known singer.
  Float32List _features(List<int> chars, List<int> text, List<(int, int, int)> fields) {
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
      if (s.length < 2 && !(s.length == 1 && s[0] >= 0x4E00 && s[0] <= 0x9FFF)) return;
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
  List<(int, int)> _candidates(List<int> chars, List<int> text, List<(int, int, int)> fields) {
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
        if (w.length >= 2 || (s.$1 == _segM && w.isNotEmpty)) needles[String.fromCharCodes(w)] = w;
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
          if (c.$1 >= i && c.$2 <= j) edges..add(c.$1)..add(c.$2);
        }
        final sorted = edges.toList()..sort();
        for (var x = 0; x < sorted.length; x++) {
          for (var y = x + 1; y < math.min(x + 4, sorted.length); y++) {
            if (sorted[x] != i || sorted[y] != j) add(sorted[x], sorted[y]);
          }
        }
      }
    }
    int byStart((int, int) p, (int, int) q) => p.$1 != q.$1 ? p.$1.compareTo(q.$1) : p.$2.compareTo(q.$2);
    var cands = out.toList()..sort(byStart);
    if (cands.length > _maxCand) {
      final end = title?.$2 ?? 0;
      final keep = [for (final c in cands) if (title == null || c.$1 >= end) c];
      final rest = [for (final c in cands) if (title != null && c.$1 < end) c];
      // short spans first; the order within a group stays by position
      final short = [for (final c in rest) if (c.$2 - c.$1 <= 12) c];
      final long = [for (final c in rest) if (c.$2 - c.$1 > 12) c];
      final room = math.max(0, _maxCand - keep.length);
      cands = [...keep, ...[...short, ...long].take(room)]..sort(byStart);
    }
    return cands;
  }

  // ---------------------------------------------------------------- maths

  /// rows × in → rows × out with the weights stored as [out, in].
  Float32List _linear(Float32List x, int rows, String name) {
    final w = _w['$name.weight']!, b = _w['$name.bias']!;
    final outDim = w.shape[0], inDim = w.shape[1];
    final y = Float32List(rows * outDim);
    for (var r = 0; r < rows; r++) {
      final xo = r * inDim;
      for (var o = 0; o < outDim; o++) {
        var sum = b.v[o];
        final wo = o * inDim;
        for (var i = 0; i < inDim; i++) {
          sum += w.v[wo + i] * x[xo + i];
        }
        y[r * outDim + o] = sum;
      }
    }
    return y;
  }

  Float32List _layerNorm(Float32List x, int rows, String name) {
    final g = _w['$name.weight']!.v, b = _w['$name.bias']!.v;
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
      final scale = 1 / math.sqrt(variance / d + 1e-5);
      for (var j = 0; j < d; j++) {
        y[o + j] = (x[o + j] - mean) * scale * g[j] + b[j];
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
        (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) *
            t *
            math.exp(-x * x);
    return sign * y;
  }

  /// One pre-norm transformer block: x + attention(norm(x)), then x + feed-forward(norm(x)).
  Float32List _block(Float32List x, int n, String name) {
    final d = _d, heads = _heads, hd = d ~/ heads;
    final normed = _layerNorm(x, n, '$name.norm1');
    final wIn = _w['$name.self_attn.in_proj_weight']!.v, bIn = _w['$name.self_attn.in_proj_bias']!.v;
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
    final ff = _linear(_gelu(_linear(_layerNorm(y, n, '$name.norm2'), n, '$name.linear1')), n, '$name.linear2');
    for (var i = 0; i < y.length; i++) {
      y[i] += ff[i];
    }
    return y;
  }

  static double _half(int bits) {
    final sign = (bits & 0x8000) != 0 ? -1.0 : 1.0;
    final exponent = (bits >> 10) & 0x1F, fraction = bits & 0x3FF;
    if (exponent == 0) return sign * fraction * 5.960464477539063e-8; // 2^-24
    if (exponent == 31) return fraction == 0 ? sign * double.infinity : double.nan;
    return sign * (1 + fraction / 1024) * math.pow(2, exponent - 15);
  }
}

class _Tensor {
  const _Tensor(this.v, this.shape);
  final Float32List v;
  final List<int> shape;
}

class _Best {
  _Best(this.span);
  double p = 0, titleP = 0;
  (int, int) span;
}
