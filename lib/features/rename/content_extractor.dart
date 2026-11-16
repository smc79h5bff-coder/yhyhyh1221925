import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'rename_models.dart';

/// 解码器输出：文本 + 真正用上的编码名。
/// 尾部片段要复用头部探测出的编码，不能各自重新探测（尾部没有 BOM 容易误判）。
class DecodedChunk {
  const DecodedChunk(this.text, this.encoding);

  final String text;
  final String encoding;
}

/// [hint] 为 'auto' 时自动探测，否则当作固定编码名。
typedef ContentDecoder = Future<DecodedChunk> Function(
    Uint8List bytes, String hint);

class ExtractOutcome {
  const ExtractOutcome({
    this.variables = const <String, String>{},
    this.skipped = false,
    this.error,
    this.lineCount = 0,
    this.charCount = 0,
  });

  /// 变量名 → 清洗后的值。没找到的变量不放进来。
  final Map<String, String> variables;

  /// 扩展名或大小不符合配置，主动跳过（不是错误）。
  final bool skipped;
  final String? error;

  /// 本次读到的文本行数（保留兼容；命名变量已改用 {字数}）。
  final int lineCount;

  /// 本次读到的正文字符数，供内置变量 {字数} 使用。
  final int charCount;
}

/// 从文件内容里提取任意字段。
///
/// 关键约束：**不读整本书**。默认只读开头 32 KB；需要尾部时另读一段，
/// 两段分别解码再拼接，避免把多字节汉字从中间切断。
/// 解码器由外部注入，纯 Dart 测试环境可以传假的，不依赖 Android 的 ICU channel。
class ContentExtractor {
  const ContentExtractor(this.decoder);

  final ContentDecoder decoder;

  /// 参与匹配的文本硬上限。用户手写的正则可能灾难性回溯，
  /// 只读文件头还不够，这里再兜一道，避免把 UI 卡死。
  static const int maxScanChars = 200 * 1024;

  Future<ExtractOutcome> extract(String path, RenamePreset preset) async {
    final scan = preset.scan;

    final lower = path.toLowerCase();
    var extMatched = false;
    for (final raw in scan.extensions) {
      if (raw.trim().isEmpty) continue;
      final e = raw.trim().toLowerCase();
      final ext = e.startsWith('.') ? e : '.$e';
      if (lower.endsWith(ext)) {
        extMatched = true;
        break;
      }
    }
    if (!extMatched) {
      return const ExtractOutcome(skipped: true);
    }

    final file = File(path);
    int len;
    try {
      len = await file.length();
    } catch (_) {
      return const ExtractOutcome(error: '无法读取文件');
    }
    final needTail = scan.scope == 'tail' || scan.scope == 'both';
    // 给个初值，避免「try 里赋值、catch 里 return」这种写法在不同
    // Dart 版本的明确赋值分析上出现分歧。
    Uint8List head = Uint8List(0);
    var tail = Uint8List(0);
    try {
      final raf = await file.open();
      try {
        if (scan.scope == 'full') {
          // 全文模式读取上限（可配置，默认 8MB）：整本读进来再解码会 OOM。
          final readLen = math.min(len, scan.fullReadCapBytes);
          head = readLen > 0 ? await raf.read(readLen) : Uint8List(0);
        } else {
          // 按行数模式：为拿到前 N 行，把读取窗口放大到全文上限（仍受 OOM 上限保护）。
          final headWindow = scan.headMode == 'lines' && scan.headLines > 0
              ? math.min(len, scan.fullReadCapBytes)
              : math.min(len, scan.headBytes);
          head = headWindow > 0 ? await raf.read(headWindow) : Uint8List(0);
          if (needTail && len > headWindow) {
            // 按行数模式：为拿到后 N 行，把尾部窗口放大到 8MB 上限。
            final tailWindow = scan.tailMode == 'lines' && scan.tailLines > 0
                ? math.min(len - headWindow, 8 * 1024 * 1024)
                : math.min(len - headWindow, scan.tailBytes);
            if (tailWindow > 0) {
              await raf.setPosition(len - tailWindow);
              tail = await raf.read(tailWindow);
            }
          }
        }
      } finally {
        await raf.close();
      }
    } catch (_) {
      return const ExtractOutcome(error: '读文件失败');
    }

    String text;
    try {
      final headChunk = await decoder(head, scan.encoding);
      var headText = headChunk.text;
      // 「只前 N 行」只截头部；以前在拼接整段之后截，选了「开头+结尾」
      // 时刚读进来的结尾会被直接丢掉，等于白读。
      if (scan.headMode == 'lines' && scan.headLines > 0 && scan.scope != 'tail') {
        headText = const LineSplitter()
            .convert(headText)
            .take(scan.headLines)
            .join('\n');
      }
      var tailText = '';
      if (tail.isNotEmpty) {
        tailText = (await decoder(tail, headChunk.encoding)).text;
        if (scan.tailMode == 'lines' && scan.tailLines > 0) {
          final tLines = const LineSplitter().convert(tailText);
          if (tLines.length > scan.tailLines) {
            tailText = tLines.sublist(tLines.length - scan.tailLines).join('\n');
          }
        }
      }
      text = tailText.isEmpty ? headText : '$headText\n$tailText';
    } catch (_) {
      return const ExtractOutcome(error: '解码失败');
    }

    if (text.length > maxScanChars) {
      text = text.substring(0, maxScanChars);
    }

    return ExtractOutcome(
      variables: extractFromText(text, preset.fields, preset.clean),
      lineCount: const LineSplitter().convert(text).length,
      charCount: text.length,
    );
  }

  /// 纯函数：按变量分组，同名规则按顺序兜底，命中第一条非空结果即停止。
  static Map<String, String> extractFromText(
    String text,
    List<ContentField> fields,
    CleanConfig clean,
  ) {
    final result = <String, String>{};
    final lines = const LineSplitter().convert(text);

    for (final field in fields) {
      final name = field.name.trim();
      if (name.isEmpty || kBuiltinVariables.contains(name)) continue;
      if (result.containsKey(name)) continue; // 已有值，后面的兜底规则不用了
      if (field.pattern.trim().isEmpty) continue; // 留空的规则不启用

      String raw;
      try {
        raw = _matchField(text, lines, field);
      } catch (_) {
        raw = ''; // 非法正则 / 越界，静默跳过这条规则
      }
      final value = cleanValue(raw, clean);
      if (value.isNotEmpty) result[name] = value;
    }
    return result;
  }

  static String _matchField(
      String text, List<String> lines, ContentField f) {
    switch (f.locator) {
      case FieldLocator.regex:
        final re = RegExp(f.pattern, multiLine: true, caseSensitive: false);
        final hits = <String>[];
        for (final m in re.allMatches(text)) {
          String v;
          if (f.captureGroup == 0) {
            v = m.group(0) ?? '';
          } else {
            v = (f.captureGroup <= m.groupCount
                    ? m.group(f.captureGroup)
                    : null) ??
                m.group(0) ??
                '';
          }
          if (v.trim().isNotEmpty) hits.add(v);
        }
        return _pick(hits, f.occurrence, f.joiner);

      case FieldLocator.keywordLine:
        final key = f.pattern.trim();
        final hits = <String>[];
        for (final line in lines) {
          final idx = line.indexOf(key);
          if (idx < 0) continue;
          var rest = line.substring(idx + key.length);
          // 去掉常见分隔符后再取内容。
          rest = rest.replaceFirst(RegExp(r'^\s*[：:=＝\-\t]\s*'), '');
          rest = rest.replaceFirst(RegExp(r'^\s+'), '');
          if (rest.trim().isNotEmpty) hits.add(rest);
        }
        return _pick(hits, f.occurrence, f.joiner);

      case FieldLocator.lineNumber:
        final n = int.tryParse(f.pattern.trim()) ?? 0;
        if (n < 1 || n > lines.length) return '';
        return lines[n - 1];

      case FieldLocator.between:
        final start = f.pattern.trim();
        final end = f.endPattern.trim();
        final startIdx = text.indexOf(start);
        if (startIdx < 0) return '';
        final from = startIdx + start.length;
        final endIdx = end.isEmpty ? -1 : text.indexOf(end, from);
        final to = endIdx < 0 ? text.length : endIdx;
        return text.substring(from, to);

      case FieldLocator.bookTitleMark:
        final re = RegExp(r'《([^》]+)》');
        final hits = <String>[];
        for (final m in re.allMatches(text)) {
          final v = m.group(1) ?? '';
          if (v.trim().isNotEmpty) hits.add(v);
        }
        return _pick(hits, f.occurrence, f.joiner);
    }
    return '';
  }

  /// 1 = 第一个，-1 = 最后一个，0 = 全部拼接，其它正数 = 第 N 个。
  static String _pick(List<String> hits, int occurrence, String joiner) {
    if (hits.isEmpty) return '';
    if (occurrence == 0) return hits.join(joiner);
    if (occurrence == -1) return hits.last;
    final i = occurrence - 1;
    if (i < 0 || i >= hits.length) return '';
    return hits[i];
  }

  /// 提取后的清洗。纯函数，可直接单测。
  static String cleanValue(String raw, CleanConfig c) {
    var s = raw;
    if (c.trim) s = s.trim();
    if (c.collapseWhitespace) {
      s = s.replaceAll(RegExp(r'[\s\u3000]+'), ' ');
    }
    if (c.stripTrailingWords) {
      s = s.replaceAll(
          RegExp(r'[\s\u3000]*[（(]?\s*(著|编著|编|作品|全集|正版|完结)\s*[）)]?\s*$'),
          '');
    }
    if (c.removePunctuation) {
      s = s.replaceAll(
          RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9\s]'), '');
    }
    if (c.toHalfWidth) s = _toHalfWidth(s);
    s = s.trim();

    for (final bad in c.blacklist) {
      if (bad.isNotEmpty && s.contains(bad)) return '';
    }
    if (c.maxLength > 0 && s.length > c.maxLength) {
      s = s.substring(0, c.maxLength).trim();
    }
    return s;
  }

  static String _toHalfWidth(String s) {
    final sb = StringBuffer();
    for (final rune in s.runes) {
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        sb.writeCharCode(rune - 0xFEE0);
      } else {
        sb.writeCharCode(rune);
      }
    }
    return sb.toString();
  }

  /// 批量扫描：最多 [concurrency] 个文件同时在读，单线程事件循环下不会卡 UI。
  ///
  /// 结果按「路径 → 结果」返回；[onProgress] 每完成一个回调一次；
  /// [isCancelled] 返回 true 时所有 worker 尽快退出，返回的是部分结果，
  /// 调用方应直接丢弃（配置变了或弹窗关了，旧结果没有意义）。
  /// 单个文件抛异常不会拖垮整批，会记成一条 error。
  Future<Map<String, ExtractOutcome>> extractMany(
    List<String> paths,
    RenamePreset preset, {
    int concurrency = 3,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final out = <String, ExtractOutcome>{};
    final total = paths.length;
    var cursor = 0;
    var done = 0;
    final n = concurrency.clamp(1, 8).toInt();

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() ?? false) return;
        final i = cursor++;
        if (i >= total) return;
        final p = paths[i];
        ExtractOutcome res;
        try {
          res = await extract(p, preset);
        } catch (_) {
          res = const ExtractOutcome(error: '读取失败');
        }
        if (isCancelled?.call() ?? false) return;
        out[p] = res;
        done++;
        onProgress?.call(done, total);
      }
    }

    final workers = <Future<void>>[
      for (var w = 0; w < n && w < total; w++) worker(),
    ];
    await Future.wait(workers);
    return out;
  }
}
