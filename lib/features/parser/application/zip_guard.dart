import 'dart:typed_data';

/// ZIP 解压前的内存保护。
///
/// `archive` 的 `ZipDecoder.decodeBytes` 会把内容解压进内存。手机上遇到
/// 异常压缩包容易 OOM，所以在解压前只读 ZIP 中央目录估算规模。
///
/// **只统计文本条目**（xhtml / html / xml / opf / ncx / txt），
/// 不把图片、字体、音视频算进来：解析时根本不需要它们的内容，
/// 而它们往往是体积的大头。一本 30MB 的图文书正文可能才 1MB，
/// 拿 30MB 去卡它就是误判。
class ZipGuard {
  const ZipGuard._();

  /// 默认上限 200MB（只算文本条目）。
  static const int defaultMaxBytes = 200 * 1024 * 1024;

  /// 校验 [bytes] 是否是合法 ZIP，且**文本条目**解压后总大小不超过 [maxBytes]。
  ///
  /// 读不出中央目录（结构异常 / ZIP64）时放弃预检，不阻塞正常解析。
  static void check(
    Uint8List bytes, {
    required String format,
    int maxBytes = defaultMaxBytes,
  }) {
    if (bytes.length < 22) {
      throw FormatException(
        'Not a valid .${format.toLowerCase()} (zip) file: too short.',
      );
    }
    final total = _totalUncompressedSize(bytes);
    if (total != null && total > maxBytes) {
      throw FormatException(
        '$format 正文解压后约 ${(total / 1024 / 1024).round()}MB，'
        '超过 ${maxBytes ~/ (1024 * 1024)}MB 上限，请换体积更小的文件。',
      );
    }
  }

  /// 只读 ZIP 中央目录，求所有**文本条目**解压后的总大小（不真正解压）。
  ///
  /// 图片 / 字体 / 音视频条目直接不计入：它们的体积不影响文字提取。
  /// 结构异常或 ZIP64 时返回 null。
  static int? _totalUncompressedSize(Uint8List bytes) {
    final minPos = bytes.length - 65557 < 0 ? 0 : bytes.length - 65557;
    int? eocd;
    for (var i = bytes.length - 22; i >= minPos; i--) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4B &&
          bytes[i + 2] == 0x05 &&
          bytes[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd == null) return null;

    final count = _u16(bytes, eocd + 10);
    final startOffset = _u32(bytes, eocd + 16);
    if (startOffset == null) return null;
    var offset = startOffset;

    var total = 0;
    for (var i = 0; i < count; i++) {
      if (offset + 46 > bytes.length) return null;
      if (bytes[offset] != 0x50 ||
          bytes[offset + 1] != 0x4B ||
          bytes[offset + 2] != 0x01 ||
          bytes[offset + 3] != 0x02) {
        return null;
      }
      final size = _u32(bytes, offset + 24);
      // ZIP64 用 0xFFFFFFFF 占位，实际值在 extra field，放弃预检。
      if (size == null || size == 0xFFFFFFFF) return null;
      final nameLen = _u16(bytes, offset + 28);
      final extraLen = _u16(bytes, offset + 30);
      final commentLen = _u16(bytes, offset + 32);
      // 只累加文本条目：图片、字体、音频的体积不进总量。
      if (_isTextEntryName(bytes, offset + 46, nameLen)) {
        total += size;
      }
      offset += 46 + nameLen + extraLen + commentLen;
    }
    return total;
  }

  /// 中央目录里的条目名是不是文本类（正文 / 元数据）。
  ///
  /// 只比较后缀，不解析整条路径：扩展名都是 ASCII，取末 6 个字符就足以
  /// 覆盖 `.xhtml` / `.html` / `.xml` / `.opf` / `.ncx` / `.txt`。
  /// 长度异常或越界时按「非文本」处理，不计入总量。
  static bool _isTextEntryName(Uint8List b, int start, int len) {
    if (len <= 0 || start < 0 || start + len > b.length) return false;
    final from = len > 6 ? start + len - 6 : start;
    final suffix = String.fromCharCodes(b, from, start + len).toLowerCase();
    return suffix.endsWith('.xhtml') ||
        suffix.endsWith('.html') ||
        suffix.endsWith('.xml') ||
        suffix.endsWith('.opf') ||
        suffix.endsWith('.ncx') ||
        suffix.endsWith('.txt');
  }

  static int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
  static int? _u32(Uint8List b, int o) {
    if (o + 4 > b.length) return null;
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
  }
}
