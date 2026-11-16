import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../domain/parsed_document.dart';
import 'doc_parser.dart';
import 'docx_parser.dart';
import 'epub_parser.dart';
import 'parse_limits.dart';
import 'txt_parser.dart';

/// Dispatches raw bytes to the format-specific parser.
///
/// 判定规则（按用户确认的策略）：
///   1. .docx → 走 [DocxParser] 抽正文（OOXML，解 zip + 读 document.xml）。
///   2. .epub → 走 [EpubParser] 抽正文（解 zip + 按 spine 顺序逐章去标签）。
///   3. .doc  → 走 [DocParser] 抽正文（OLE2 + FIB/CLX piece table）。
///   4. 其它后缀在 [_binaryExtensions] 白名单里 → 真二进制但暂无专用
///      解析器，一律提示"暂不支持"。
///   5. 其它所有后缀 / 无后缀 → 一律按纯文本处理，不管内容是不是文本。
///
/// 只看后缀，不嗅魔数。用户手动把 zip 改名为 .txt 时按文本读，读出乱码
/// 也认——宁可给出可对比的结果，也不做"看起来像二进制就拒绝"的猜测。
class DocumentParser {
  const DocumentParser._();

  /// 单次解析的总时限。
  ///
  /// 内存问题由 [ParseLimits] 在解析过程中主动熔断；这里的超时只兜底
  /// 死循环（比如畸形 HTML 触发的超长回溯）。超时后直接终止
  /// isolate，不会留在后台继续跑。
  static const Duration parseTimeout = Duration(seconds: 30);

  /// 真二进制格式的后缀白名单。命中这些后缀才走专门解析器。
  /// 其余后缀一律按 txt 处理。
  ///
  /// 分类：文档 / 表格 / 演示 / PDF / 图片 / 音频 / 视频 / 压缩包 /
  ///       可执行 / 字体 / 数据库。
  static const Set<String> _binaryExtensions = {
    // 文档（.docx / .epub / .doc 已由专用解析器支持，见 parse()，故不在此列）
    '.rtf', '.odt', '.wps',
    // 表格 / 演示
    '.xlsx', '.xls', '.ods', '.pptx', '.ppt', '.odp',
    // PDF
    '.pdf',
    // 图片
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.svg',
    // 音频
    '.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a',
    // 视频
    '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v',
    // 压缩包
    '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz',
    '.jar', '.apk', '.ipa', '.iso',
    // 可执行
    '.exe', '.dll', '.so', '.bin', '.deb', '.rpm',
    // 字体
    '.ttf', '.otf', '.woff', '.woff2',
    // 数据库
    '.db', '.sqlite', '.sqlite3',
  };

  /// [dangerRssBytes] 是这台机器的进程内存危险线，由调用方从
  /// `readDeviceMemory()` 取到后传入。传 null 时使用保守兜底值。
  ///
  /// 注意 [bytes] 的归属：.doc / .docx / .epub 走后台 isolate，为避免
  /// spawn 时整份深拷贝，这里用 TransferableTypedData 把底层缓冲「转移」
  /// 过去，因此调用返回后 [bytes] 已失效，不要再读取它。纯文本路径不走
  /// isolate，不受影响。现有调用点都只使用返回的 ParsedDocument。
  static Future<ParsedDocument> parse({
    required String fileName,
    required Uint8List bytes,
    int? dangerRssBytes,
  }) async {
    final ext = _extOf(fileName);

    // .docx / .epub 是 CPU 和内存密集的 zip + XML 解析；.doc 是 OLE2
    // 字节解析，同样可能很大。三种都放后台 isolate，避免几十 MB 的文档
    // 在解析期间冻住界面。
    if (ext == '.docx' || ext == '.epub' || ext == '.doc') {
      final limits = dangerRssBytes == null
          ? ParseLimits.fallback()
          : ParseLimits.forDevice(dangerRssBytes);

      // web 上没有真正的 isolate，也没法打断同步解析，
      // 依赖输入大小和规模上限兜底。
      const isWeb = bool.fromEnvironment('dart.library.js_util');
      if (isWeb) return _parseBinary(fileName, bytes, limits);

      return _parseInIsolate(fileName, bytes, limits);
    }

    if (_binaryExtensions.contains(ext)) {
      throw UnsupportedError(
        '暂不支持对比 ${ext.isEmpty ? "此类型" : ext} 格式文件。',
      );
    }

    // 其它一切按文本处理。
    final encoding = EncodingDetector.detect(bytes);
    return TxtParser().parse(fileName, bytes, encoding);
  }

  /// 在独立 isolate 中解析，超时后强制终止。
  ///
  /// 不用 `Isolate.run`，因为它不暴露句柄，超时后任务仍在后台跑。
  /// 这里自己 spawn，超时直接 kill，确保"停下"是真的停下。
  static Future<ParsedDocument> _parseInIsolate(
    String fileName,
    Uint8List bytes,
    ParseLimits limits,
  ) async {
    final receivePort = ReceivePort();
    final completer = Completer<ParsedDocument>();
    Isolate? isolate;
    Timer? timer;

    void cleanup() {
      timer?.cancel();
      receivePort.close();
      isolate?.kill(priority: Isolate.immediate);
    }

    void fail(String message) {
      if (completer.isCompleted) return;
      cleanup();
      completer.completeError(ParseAbortException(message));
    }

    timer = Timer(parseTimeout, () {
      fail(
        '解析超过 ${parseTimeout.inSeconds} 秒，文件可能已损坏，已停止。'
        '请换一个文件，或检查文件是否完整。',
      );
    });

    receivePort.listen((message) {
      if (completer.isCompleted) return;
      if (message is ParsedDocument) {
        cleanup();
        completer.complete(message);
      } else if (message is String) {
        fail(message);
      }
    });

    try {
      // 不直接把 Uint8List 放进 spawn 参数：那样消息传递会整份深拷贝一份
      // 给后台 isolate，等于同时占两份文件大小的内存。改成转移底层缓冲，
      // 全程只保留一份。代价是主 isolate 里的 bytes 随即失效（见 parse() 注释）。
      // web 分支在 parse() 里已直接同步解析，不会走到这里，bytes 不会被掏空。
      final transferable = TransferableTypedData.fromList([bytes]);
      isolate = await Isolate.spawn(
        _parseEntry,
        <Object?>[
          receivePort.sendPort,
          fileName,
          transferable,
          limits.dangerRssBytes,
          limits.maxUncompressedBytes,
          limits.maxChapterBytes,
          limits.maxChapters,
          limits.maxParagraphs,
        ],
      );
      // 超时可能先于 spawn 完成，这时补一次 kill。
      if (completer.isCompleted) {
        isolate!.kill(priority: Isolate.immediate);
      }
    } catch (e) {
      fail('启动解析任务失败：$e');
    }

    return completer.future;
  }

  /// 后台 isolate 入口。成功回传 [ParsedDocument]，失败回传用户可读文本。
  static void _parseEntry(List<Object?> args) {
    final sendPort = args[0] as SendPort;
    final fileName = args[1] as String;
    final transferable = args[2] as TransferableTypedData;
    final limits = ParseLimits(
      dangerRssBytes: args[3] as int,
      maxUncompressedBytes: args[4] as int,
      maxChapterBytes: args[5] as int,
      maxChapters: args[6] as int,
      maxParagraphs: args[7] as int,
    );

    try {
      // 取回转移过来的那份字节；materialize() 只能调用一次。
      final bytes = transferable.materialize().asUint8List();
      sendPort.send(_parseBinary(fileName, bytes, limits));
    } on ParseAbortException catch (e) {
      sendPort.send(e.message);
    } catch (e) {
      // FormatException / UnsupportedError 的 message 已经是给用户看的，
      // 不要再套一层类型名。
      if (e is FormatException) {
        sendPort.send(e.message);
      } else if (e is UnsupportedError) {
        sendPort.send(e.message);
      } else {
        sendPort.send('$e');
      }
    }
  }

  /// 二进制文档的解析入口，必须只依赖纯 Dart 包（docx / epub / doc 解析器
  /// 已满足），才能安全地在后台 isolate 里运行。
  static ParsedDocument _parseBinary(
    String fileName,
    Uint8List bytes,
    ParseLimits limits,
  ) {
    final ext = _extOf(fileName);
    if (ext == '.docx') {
      return const DocxParser()
          .parse(fileName, bytes, EncodingType.utf8, limits: limits);
    }
    if (ext == '.epub') {
      return const EpubParser()
          .parse(fileName, bytes, EncodingType.utf8, limits: limits);
    }
    if (ext == '.doc') {
      return const DocParser()
          .parse(fileName, bytes, EncodingType.utf8, limits: limits);
    }
    throw UnsupportedError('暂不支持对比 $ext 格式文件。');
  }

  /// 取小写后缀（含点）。无后缀返回空字符串。
  /// 特殊处理 `.tar.gz` 之类只取最后一段（`.gz`），因为 `.tar` 和 `.gz`
  /// 都在白名单里，取哪一段都会命中；返回 `.gz` 更简单。
  static String _extOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    // 目录分隔符之后没点：视为无后缀（比如路径里带点但文件名不带）。
    final slash = fileName.lastIndexOf('/');
    if (slash > dot) return '';
    return fileName.substring(dot).toLowerCase();
  }
}
