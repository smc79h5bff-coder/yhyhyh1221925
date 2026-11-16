import 'package:diff_match_patch/diff_match_patch.dart';

/// One character-level diff segment.
/// op: 0 = equal, 1 = insert (in new text), -1 = delete (in old text).
typedef CharSeg = (int op, String text);

/// Session-scoped cache for character-level diff results.
///
/// The previous implementation called `DiffMatchPatch().diff(a, b)` from
/// inside `InlineCharDiff.build()`, which re-ran Myers on every rebuild
/// (i.e. every scroll frame). That is the main reason scrolling felt
/// sluggish on files with many replace rows. This cache keeps one entry per
/// (before, after) pair so each pair is diffed exactly once per session.
class DiffCache {
  DiffCache._();

  static final DiffCache instance = DiffCache._();

  /// Upper bound on cached pairs. When exceeded the cache is cleared —
  /// cheap and good enough for a session-level cache.
  static const int _maxEntries = 2048;

  /// 单行字符级 diff 的长度上限。超过就不逐字比对，直接整行标记为
  /// 删除/新增，避免超长行在 UI 线程跑 Myers 卡死。
  static const int maxCharDiffChars = 1000;

  final Map<String, List<CharSeg>> _charCache = <String, List<CharSeg>>{};

  /// Returns the character-level segments for [a] vs [b], computing and
  /// memoising on first request.
  List<CharSeg> charSegments(String a, String b) {
    if (a == b) return <CharSeg>[(0, a)];
    if (a.length > maxCharDiffChars || b.length > maxCharDiffChars) {
      return <CharSeg>[
        if (a.isNotEmpty) (-1, a),
        if (b.isNotEmpty) (1, b),
      ];
    }
    final key = '${a.length}:$a\u0000$b';
    final hit = _charCache[key];
    if (hit != null) return hit;
    final segs = _compute(a, b);
    if (_charCache.length >= _maxEntries) {
      _charCache.clear();
    }
    _charCache[key] = segs;
    return segs;
  }

  /// Drops all cached entries. Call when the diff result itself changes so
  /// stale pairs do not accumulate across edits.
  void clear() => _charCache.clear();

  List<CharSeg> _compute(String a, String b) {
    final dmp = DiffMatchPatch();
    final raw = dmp.diff(a, b);
    final out = <CharSeg>[];
    for (final d in raw) {
      switch (d.operation) {
        case DIFF_EQUAL:
          out.add((0, d.text));
          break;
        case DIFF_INSERT:
          out.add((1, d.text));
          break;
        case DIFF_DELETE:
          out.add((-1, d.text));
          break;
        default:
          out.add((0, d.text));
      }
    }
    return out;
  }
}