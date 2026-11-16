import 'dart:typed_data';

import 'package:charset/charset.dart' show shiftJis;
import 'package:enough_convert/enough_convert.dart' as ec;
import 'package:gbk_codec/gbk_codec.dart' as gbkCodec;

import '../../preprocessing/domain/encoding_type.dart';
import '../domain/document_format.dart';
import '../domain/parsed_document.dart';
import 'parse_limits.dart';

/// .doc (Word 97-2003, OLE2 / CFB container) parser.
///
/// 只抽主正文，不还原排版：页眉页脚、脚注、批注、文本框、图片、域代码
/// 一律丢弃，和 DocxParser / EpubParser 保持同一个标准。对比引擎只吃
/// 纯文本，因此 .doc 可跟 txt / docx / epub 任意配对。
///
/// 实现依据与借鉴（公开的规范 / 开源实现，代码写进本文件，**不引入任何
/// 新依赖**，pubspec.yaml 一行不动）：
///   - [MS-CFB] 复合文档：扇区、DIFAT / FAT / MiniFAT、目录、流链。
///   - [MS-DOC] FIB、CLX / PlcPcd（piece table）、压缩位、fc/CP 映射。
///   - anydoc (Rust)：FIB 魔数 0xA5EC 校验、fEncrypted 检测、
///     0Table/1Table 双表回退、lcbClx=0 退化单 piece、按 lid 选 ANSI
///     编码、所有偏移做 saturating / 边界裁剪。
///   - doc_text (ArkTS, Apache-2.0)：piece table 失效时的直接提取兜底、
///     链循环 / 越界 / 超大分配 / 可读性复核四层防御。
///   - Apache POI HWPF：getTextFromPieces() 的「结构坏了也要吐正文」思路。
///
/// 全部是纯字节运算，只依赖 dart:typed_data 与项目里已有的三个纯 Dart
/// 编码包，因此能安全地在后台 isolate 中运行。
class DocParser {
  const DocParser();

  /// 可读性复核只看开头这么多字符，避免大文件重复遍历。
  static const int _readableSample = 20000;

  /// 低于此比例就认为解码不可靠，宁可明确报错也不给一屏乱码。
  /// 取 0.60：正常小说正文（含段落标记、少量域控制符）接近 1.0，
  /// 而把 UTF-16 字节当 GBK 解、或把 GBK 字节当 UTF-16 解出来的
  /// 乱码通常只有 0.1~0.45，两者之间有足够间隔。
  static const double _readableThreshold = 0.60;

  ParsedDocument parse(
    String fileName,
    Uint8List bytes,
    EncodingType encoding, {
    ParseLimits? limits,
  }) {
    final guard = limits ?? ParseLimits.fallback();
    if (bytes.length > guard.maxUncompressedBytes) {
      throw ParseAbortException(
        '文档超过解析上限，已停止。请换小一点的 .doc 文件。',
      );
    }

    _checkMagic(bytes, fileName);

    final cfb = _Cfb(bytes, guard.maxUncompressedBytes);
    final wd = cfb.stream('WordDocument');
    if (wd == null) {
      // 流读不到分两种情况：真没有这个流，或流超过体积上限被 _Cfb 拒了。
      // 前者报损坏，后者报太大，别把大文件误导成「文件已损坏」。
      final raw = cfb.streamSize('WordDocument');
      if (raw != null && raw > guard.maxUncompressedBytes) {
        throw ParseAbortException(
          '这个 .doc 整份文件超过解析上限，已停止。请换小一点的文件。',
        );
      }
      throw const FormatException(
        '这个 .doc 里没有 WordDocument 流，可能已损坏。',
      );
    }
    if (wd.length < 0x200) {
      throw const FormatException(
        '这个 .doc 里没有 WordDocument 流，可能已损坏。',
      );
    }

    // anydoc: FIB 魔数必须先校验，否则后面所有偏移都是在读垃圾。
    if (_u16(wd, 0x00) != 0xA5EC) {
      throw const FormatException(
        '这个 .doc 的 FIB 头不合法，可能不是 Word 文档。',
      );
    }

    final flags = _u16(wd, 0x0A);
    if (flags & 0x0100 != 0) {
      throw const FormatException(
        '这个 .doc 已加密，请先去掉密码再对比。',
      );
    }

    final ccpText = _u32(wd, 0x4C);
    if (ccpText == 0) {
      throw const FormatException('这个 .doc 的主正文为空。');
    }
    // 正文一个字符至少占一个字节，且全部落在 WordDocument 流里。
    // 超过这个结构上界说明 FIB 已损坏，直接停，别按垃圾数去分配。
    if (ccpText > wd.length) {
      throw ParseAbortException(
        '这个 .doc 的正文字数超过文件容量，文件可能已损坏，已停止解析。',
      );
    }

    // anydoc: 首选表读不到就回退到另一张表，两张都没有才走 legacy 路径。
    final preferred = flags & 0x0200 != 0 ? '1Table' : '0Table';
    final fallback = flags & 0x0200 != 0 ? '0Table' : '1Table';
    final table = cfb.stream(preferred) ?? cfb.stream(fallback);
    final fcClx = _u32(wd, 0x1A2);
    final lcbClx = _u32(wd, 0x1A6);

    // 三条路径都生成「候选片段表」，逐个解码后按可读性择优。
    // 顺序即优先级：piece table 最可信，老版单段次之，直接提取兜底。
    final candidates = <List<_Piece>>[];
    if (table != null && lcbClx > 0) {
      final clx = _parseClx(table, fcClx, lcbClx, ccpText, wd.length);
      if (clx.isNotEmpty) candidates.add(clx);
    }
    candidates.addAll(_legacyCandidates(wd, ccpText));
    candidates.addAll(_directCandidates(wd, ccpText));

    final ansi = _ansiOf(wd, flags);
    String? bestText;
    var bestScore = -1.0;
    for (final pieces in candidates) {
      final raw = _extract(wd, pieces, ansi);
      if (raw.isEmpty) continue;
      final sample = raw.length > _readableSample
          ? raw.substring(0, _readableSample)
          : raw;
      final score = _readableRatio(sample);
      // 严格大于：同分时保留更靠前（更可信）的候选。
      if (score > bestScore) {
        bestScore = score;
        bestText = raw;
      }
    }
    if (bestText == null || bestScore < _readableThreshold) {
      throw FormatException(
        '这个 .doc 的正文解码不可靠（可读性 '
        '${(bestScore * 100).toStringAsFixed(0)}%），'
        '请用 Word / WPS 另存为 .txt 后再对比。',
      );
    }

    final paragraphs = _toParagraphs(_normalize(bestText), guard);
    if (paragraphs.isEmpty) {
      throw const FormatException('这个 .doc 里没有可读正文。');
    }

    return ParsedDocument(
      fileName: fileName,
      format: DocumentFormat.doc,
      encoding: EncodingType.utf8,
      paragraphs: paragraphs,
      byteSize: bytes.length,
    );
  }

  /// 先区分「真 OLE2」和「套了 .doc 后缀的别的东西」，给能照做的提示。
  static void _checkMagic(Uint8List bytes, String fileName) {
    const magic = <int>[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    if (bytes.length >= 8) {
      var ok = true;
      for (var i = 0; i < 8; i++) {
        if (bytes[i] != magic[i]) {
          ok = false;
          break;
        }
      }
      if (ok) return;
    }
    if (_asciiStartsWith(bytes, '{\\rtf')) {
      throw const FormatException(
        '这个文件其实是 RTF，请另存为 .txt 后再对比。',
      );
    }
    if (_asciiStartsWith(bytes, 'PK')) {
      throw const FormatException(
        '这个文件其实是 .docx 改了后缀，改回 .docx 就能对比。',
      );
    }
    if (_asciiStartsWith(bytes, '<html') ||
        _asciiStartsWith(bytes, '<HTML') ||
        _asciiStartsWith(bytes, '<!DOCTYPE')) {
      throw const FormatException(
        '这个文件其实是网页，请另存为 .txt 后再对比。',
      );
    }
    throw FormatException('$fileName 不是有效的旧版 .doc（OLE2）文件。');
  }

  static bool _asciiStartsWith(Uint8List bytes, String prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// 解析 CLX：跳过 Prc(0x01)，找到 Pcdt(0x02) 里的 PlcPcd。
  /// 每一步都做边界裁剪，坏数据返回空列表交给上层兜底。
  static List<_Piece> _parseClx(
    Uint8List table,
    int fcClx,
    int lcbClx,
    int ccpText,
    int wdLength,
  ) {
    if (lcbClx < 16 || fcClx >= table.length) return <_Piece>[];
    final end = fcClx + lcbClx > table.length ? table.length : fcClx + lcbClx;
    var pos = fcClx;
    while (pos < end) {
      final marker = table[pos];
      if (marker == 0x01) {
        if (pos + 3 > end) break;
        final cb = _u16(table, pos + 1);
        final next = pos + 3 + cb;
        if (next > end || next <= pos) break;
        pos = next;
      } else if (marker == 0x02) {
        if (pos + 5 > end) break;
        final lcbPlc = _u32(table, pos + 1);
        final p0 = pos + 5;
        final p1 = p0 + lcbPlc;
        if (lcbPlc < 16 || p1 > end) break;
        return _parsePlcPcd(
          Uint8List.sublistView(table, p0, p1),
          ccpText,
          wdLength,
        );
      } else {
        break;
      }
    }
    return <_Piece>[];
  }

  /// PlcPcd = (n+1) 个 CP + n 个 8 字节 PCD。
  /// PCD.fc 的 bit30 是压缩位：置位时真实偏移 = fc/2、每字符 1 字节；
  /// 未置位时真实偏移 = fc、每字符 2 字节（UTF-16LE）。
  static List<_Piece> _parsePlcPcd(
    Uint8List plc,
    int ccpText,
    int wdLength,
  ) {
    final n = (plc.length - 4) ~/ 12;
    if (n <= 0) return <_Piece>[];
    final pieces = <_Piece>[];
    for (var j = 0; j < n; j++) {
      final cp0 = _u32(plc, j * 4);
      final cp1 = _u32(plc, (j + 1) * 4);
      if (cp1 <= cp0 || cp0 >= ccpText) break;
      final pcdOff = 4 * (n + 1) + 8 * j;
      if (pcdOff + 8 > plc.length) break;
      final fcRaw = _u32(plc, pcdOff + 2);
      final compressed = fcRaw & 0x40000000 != 0;
      final fc = fcRaw & 0x3FFFFFFF;
      final count = (cp1 < ccpText ? cp1 : ccpText) - cp0;
      if (count <= 0 || count > wdLength) continue;
      final byteStart = compressed ? fc ~/ 2 : fc;
      final byteLen = compressed ? count : count * 2;
      if (byteLen <= 0 || byteStart + byteLen > wdLength) continue;
      pieces.add(_Piece(byteStart, byteLen, compressed));
    }
    return pieces;
  }

  /// anydoc 的 legacy_single_piece：FIB 里没有 CLX 时按 fcMin..fcMac 读。
  /// 单字节 / UTF-16LE 两种都生成，交给可读性复核选，不靠猜。
  static List<List<_Piece>> _legacyCandidates(Uint8List wd, int ccpText) {
    final fcMin = _u32(wd, 0x18);
    final fcMac = _u32(wd, 0x1C);
    if (fcMin <= 0 || fcMin >= wd.length) return <List<_Piece>>[];
    final available = wd.length - fcMin;
    final declared = fcMac > fcMin ? fcMac - fcMin : 0;
    final len = declared > 0 && declared < available ? declared : available;
    if (len <= 0) return <List<_Piece>>[];
    return <List<_Piece>>[
      <_Piece>[_Piece(fcMin, len & ~1, false)],
      <_Piece>[_Piece(fcMin, len, true)],
    ];
  }

  /// doc_text 的「直接提取」兜底：结构全坏时，从 FIB 之后按 UTF-16LE
  /// 或单字节各试一遍，只保留可读性达标的那种。
  static List<List<_Piece>> _directCandidates(Uint8List wd, int ccpText) {
    final start = wd.length > 0x200 ? 0x200 : 0;
    final available = wd.length - start;
    if (available <= 0) return <List<_Piece>>[];
    final wanted16 =
        (ccpText * 2 < available ? ccpText * 2 : available) & ~1;
    final wanted8 = ccpText < available ? ccpText : available;
    final out = <List<_Piece>>[];
    if (wanted16 > 0) {
      out.add(<_Piece>[_Piece(start, wanted16, false)]);
    }
    if (wanted8 > 0) {
      out.add(<_Piece>[_Piece(start, wanted8, true)]);
    }
    return out;
  }

  static String _extract(Uint8List wd, List<_Piece> pieces, _Ansi ansi) {
    final buf = StringBuffer();
    for (final p in pieces) {
      buf.write(
        p.compressed
            ? _decodeAnsi(wd, p.start, p.length, ansi)
            : _decodeUtf16Le(wd, p.start, p.length),
      );
    }
    return buf.toString();
  }

  /// anydoc 的 lid → ANSI code page 映射，按本项目实际用途做了两点调整：
  ///   - 没有 EUC-KR 解码器时用 GBK 兜底（韩文 .doc 罕见，不为此加依赖）；
  ///   - 未知 lid 默认 GBK 而不是 Windows-1252，因为这里比的是中文小说。
  static _Ansi _ansiOf(Uint8List wd, int flags) {
    // MS-DOC 规范：lidFE（远东语言 ID）在 FIB 偏移 0x2A，nFib 之前的 0x3C 是保留字段。
    final lid = flags & 0x4000 != 0
        ? (_u16(wd, 0x2A) != 0 ? _u16(wd, 0x2A) : _u16(wd, 0x06))
        : _u16(wd, 0x06);
    final key = lid & 0x03FF;
    if (key == 0x11) return _Ansi.shiftJis;
    if (key == 0x04) {
      return lid == 0x0404 || lid == 0x0C04 || lid == 0x1404 || lid == 0x7C04
          ? _Ansi.big5
          : _Ansi.gbk;
    }
    return _Ansi.gbk;
  }

  static String _decodeAnsi(
    Uint8List src,
    int start,
    int byteLen,
    _Ansi enc,
  ) {
    if (byteLen <= 0 || start < 0 || start + byteLen > src.length) return '';
    final part = Uint8List.sublistView(src, start, start + byteLen);
    try {
      return switch (enc) {
        _Ansi.gbk => gbkCodec.gbk.decode(part),
        _Ansi.big5 => ec.big5.decode(part),
        _Ansi.shiftJis => shiftJis.decode(part),
        _Ansi.latin1 => String.fromCharCodes(part),
      };
    } on Object {
      // 解码器对坏字节抛异常时，至少保留可打印字符，不让整段消失。
      return String.fromCharCodes(part);
    }
  }

  static String _decodeUtf16Le(Uint8List src, int start, int byteLen) {
    if (byteLen <= 0 || start < 0) return '';
    final end = start + byteLen > src.length ? src.length : start + byteLen;
    final units = <int>[];
    for (var i = start; i + 1 < end; i += 2) {
      units.add(src[i] | (src[i + 1] << 8));
    }
    // String.fromCharCodes 会合并合法 surrogate pair；孤立代理项不会被替换成
    // U+FFFD，而是原样保留在字符串里（Dart 字符串按 UTF-16 code unit 存储），
    // 由后面的可读性复核兜住。
    return String.fromCharCodes(units);
  }

  /// 可读性复核：解码选错编码时（Big5 当 GBK）会出现大量 Latin-1 /
  /// 私用区 / 控制字符。低于阈值就明确报错，绝不把乱码当成正文送进对比。
  static double _readableRatio(String s) {
    if (s.isEmpty) return 0;
    var ok = 0;
    var total = 0;
    for (final r in s.runes) {
      total++;
      if (r == 0xFFFD) continue;
      if (r == 0x09 || r == 0x0A || r == 0x0D || r == 0x20 ||
          (r >= 0x20 && r <= 0x7E) ||
          (r >= 0x00C0 && r <= 0x024F) ||
          (r >= 0x0370 && r <= 0x052F) ||
          (r >= 0x2000 && r <= 0x206F) ||
          (r >= 0x3000 && r <= 0x303F) ||
          (r >= 0x3040 && r <= 0x30FF) ||
          (r >= 0x3400 && r <= 0x4DBF) ||
          (r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0xAC00 && r <= 0xD7AF) ||
          (r >= 0xF900 && r <= 0xFAFF) ||
          (r >= 0xFF00 && r <= 0xFFEF)) {
        ok++;
      }
    }
    return total == 0 ? 0 : ok / total;
  }

  /// Word 正文里的段落标记 / 单元格结束 / 软换行 / 分页符统一成 \n，
  /// 其余控制字符（域代码、图片锚点、脚注锚点）全部丢弃，保留 \t。
  static String _normalize(String text) {
    final buf = StringBuffer();
    for (final r in text.runes) {
      if (r == 0x0D || r == 0x07 || r == 0x0B || r == 0x0C) {
        buf.writeCharCode(0x0A);
      } else if (r == 0x09 || r == 0x0A) {
        buf.writeCharCode(r);
      } else if (r < 0x20 || r == 0x7F) {
        continue;
      } else if (r >= 0xFFF9 && r <= 0xFFFB) {
        continue;
      } else {
        buf.writeCharCode(r);
      }
    }
    return buf.toString();
  }

  /// 与 EPUB 解析器同一套行清洗口径：全角空格、首尾空白一起处理，
  /// 空行丢弃，保证 .doc 与 txt / docx / epub 对比时不会冒出假差异。
  static List<String> _toParagraphs(String text, ParseLimits guard) {
    final out = <String>[];
    for (final line in text.split('\n')) {
      final clean = line
          .replaceAll('\u00A0', ' ')
          .trim()
          .replaceAll(RegExp(r'^[　\s]+|[　\s]+$'), '');
      if (clean.isEmpty) continue;
      out.add(clean);
      guard.checkParagraphs(out.length);
      if (out.length % 10000 == 0) guard.checkMemory();
    }
    return out;
  }
}

enum _Ansi { gbk, big5, shiftJis, latin1 }

class _Piece {
  const _Piece(this.start, this.length, this.compressed);

  final int start;
  final int length;
  final bool compressed;
}

class _Entry {
  const _Entry(this.name, this.type, this.start, this.size);

  final String name;
  final int type;
  final int start;
  final int size;
}

/// CFB / OLE2 复合文档读取器（[MS-CFB]）。
///
/// 只实现「按名字读一个流」这一个能力，不还原目录树、不写文件。
/// 链遍历带 seen 集合防循环、长度上限防超大分配、每一步都做越界检查。
class _Cfb {
  _Cfb(Uint8List bytes, this.maxBytes) {
    _b = bytes;
    _parse();
  }

  late final Uint8List _b;
  final int maxBytes;
  late final int sector;
  late final int miniSector;
  late final int cutoff;
  late final List<int> fat;
  late final List<int> miniFat;
  late final List<_Entry> entries;
  late final Uint8List miniStream;

  static const int _maxSid = 0xFFFFFFFA;

  void _parse() {
    final h = _b;
    if (h.length < 512) {
      throw const FormatException('.doc 文件头不完整。');
    }
    final sectorShift = _u16(h, 30);
    if (sectorShift < 9 || sectorShift > 12) {
      throw const FormatException(
        '.doc 的扇区大小不合法，文件可能已损坏。',
      );
    }
    sector = 1 << sectorShift;
    final miniShift = _u16(h, 32);
    miniSector = miniShift >= 1 && miniShift <= 12 ? 1 << miniShift : 64;
    final declaredCutoff = _u32(h, 56);
    cutoff = declaredCutoff > 0 && declaredCutoff <= 0x1000000
        ? declaredCutoff
        : 4096;

    // DIFAT：头部 109 项 + 后续 DIFAT 扇区链。
    final difat = <int>[];
    for (var i = 0; i < 109; i++) {
      final v = _u32(h, 76 + i * 4);
      if (v < _maxSid) difat.add(v);
    }
    var cur = _u32(h, 68);
    final nDifat = _u32(h, 72);
    var hops = 0;
    final seenDifat = <int>{};
    while (cur < _maxSid && hops < nDifat + 1 && hops < 1000) {
      if (!seenDifat.add(cur)) break;
      final s = _sector(cur);
      if (s == null) break;
      final slots = sector ~/ 4;
      for (var i = 0; i < slots - 1; i++) {
        final v = _u32(s, i * 4);
        if (v < _maxSid) difat.add(v);
      }
      cur = _u32(s, (slots - 1) * 4);
      hops++;
    }

    final fatLocal = <int>[];
    final fatCap = maxBytes ~/ 4;
    for (final sid in difat) {
      if (fatLocal.length >= fatCap) break;
      final s = _sector(sid);
      if (s == null) continue;
      for (var i = 0; i < sector ~/ 4 && fatLocal.length < fatCap; i++) {
        fatLocal.add(_u32(s, i * 4));
      }
    }
    fat = fatLocal;

    // MiniFAT：沿 FAT 链读，链循环直接停。
    final mf = <int>[];
    cur = _u32(h, 60);
    final nMf = _u32(h, 64);
    hops = 0;
    final seenMf = <int>{};
    while (cur < _maxSid && hops < nMf + 1 && hops < 1000) {
      if (!seenMf.add(cur)) break;
      final s = _sector(cur);
      if (s == null) break;
      for (var i = 0; i < sector ~/ 4; i++) {
        mf.add(_u32(s, i * 4));
      }
      if (cur >= fat.length) break;
      cur = fat[cur];
      hops++;
    }
    miniFat = mf;

    // 目录：128 字节一项，名称是 UTF-16LE。
    final dir = _readChain(_u32(h, 48), 1 << 24, mini: false);
    final list = <_Entry>[];
    for (var k = 0; k + 128 <= dir.length; k += 128) {
      final e = Uint8List.sublistView(dir, k, k + 128);
      final nameLen = _u16(e, 64);
      final type = e[66];
      if (type == 0 || type > 5 || nameLen < 2 || nameLen > 64) continue;
      // 高 32 位长度非 0 → 超过 4GB，跳过。
      if (_u32(e, 124) != 0) continue;
      list.add(
        _Entry(
          DocParser._decodeUtf16Le(e, 0, nameLen - 2),
          type,
          _u32(e, 116),
          _u32(e, 120),
        ),
      );
    }
    entries = list;

    _Entry? root;
    for (final e in entries) {
      if (e.type == 5) {
        root = e;
        break;
      }
    }
    miniStream = root == null
        ? Uint8List(0)
        : _readChain(root.start, root.size, mini: false);
  }

  Uint8List? _sector(int sid) {
    if (sid < 0 || sid >= _maxSid) return null;
    final off = (sid + 1) * sector;
    if (off + sector > _b.length) return null;
    return Uint8List.sublistView(_b, off, off + sector);
  }

  Uint8List _readChain(int start, int size, {required bool mini}) {
    if (size <= 0 || size > maxBytes) return Uint8List(0);
    final arr = mini ? miniFat : fat;
    final unit = mini ? miniSector : sector;
    final out = <int>[];
    final seen = <int>{};
    var cur = start;
    final limit = size + unit;
    while (cur < _maxSid && out.length < limit) {
      if (!seen.add(cur)) break; // 链成环，立即停。
      final Uint8List? chunk;
      if (mini) {
        final off = cur * unit;
        if (off + unit > miniStream.length) break;
        chunk = Uint8List.sublistView(miniStream, off, off + unit);
      } else {
        chunk = _sector(cur);
      }
      if (chunk == null) break;
      out.addAll(chunk);
      if (cur >= arr.length) break;
      cur = arr[cur];
    }
    final take = out.length > size ? size : out.length;
    return Uint8List.fromList(out.sublist(0, take));
  }

  Uint8List? stream(String name) {
    final found = _find(name);
    if (found == null) return null;
    if (found.size <= 0 || found.size > maxBytes) return null;
    return _readChain(found.start, found.size, mini: found.size < cutoff);
  }

  /// 只查目录里的流大小（不读扇区链），用于区分「流不存在」和
  /// 「流太大被上限挡住」两种失败，给上层更准确的报错文案。
  int? streamSize(String name) => _find(name)?.size;

  _Entry? _find(String name) {
    for (final e in entries) {
      if (e.type == 2 && e.name == name) return e;
    }
    return null;
  }
}

int _u16(List<int> d, int off) =>
    off >= 0 && off + 2 <= d.length ? d[off] | (d[off + 1] << 8) : 0;

int _u32(List<int> d, int off) => off >= 0 && off + 4 <= d.length
    ? d[off] | (d[off + 1] << 8) | (d[off + 2] << 16) | (d[off + 3] << 24)
    : 0;
