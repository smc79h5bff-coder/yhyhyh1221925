/// 解析被主动中止：规模超限或超时。
///
/// [message] 直接面向用户，UI 可以原样展示。
class ParseAbortException implements Exception {
  ParseAbortException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 解析阶段的安全边界。
///
/// 现在只用「按文件结构算出来」的几道边界：解压后总量、单章大小、
/// 章节数、段落数。这些都和手机当时剩多少内存无关，所以不会因为
/// 设备忙一点，就把一本正常能读的书判成「内存不足」。
///
/// 原先还有一道「进程 RSS 超过危险线就中止」的判断，已停用。原因是它
/// 拿进程**总**内存去比一条固定安全线、不扣基线，而 App 启动后基线本身
/// 就接近甚至超过那条线——结果是 30MB 的图文 EPUB（正文才 1MB 左右）
/// 也会被拒绝，3KB 的文本同样会被拒绝，等于把这套对比堵死。
class ParseLimits {
  ParseLimits({
    required this.dangerRssBytes,
    int? maxUncompressedBytes,
    this.maxChapterBytes = 32 * 1024 * 1024,
    this.maxChapters = 20000,
    this.maxParagraphs = 5000000,
  }) : maxUncompressedBytes = maxUncompressedBytes ?? _defaultUncompressed;

  /// 读不到设备内存时的保守值：低于大多数中低端机的堆上限。
  factory ParseLimits.fallback() => ParseLimits(
        dangerRssBytes: 260 * 1024 * 1024,
      );

  /// 按机型危险线构造。
  factory ParseLimits.forDevice(int dangerRssBytes) =>
      ParseLimits(dangerRssBytes: dangerRssBytes);

  /// 解压后总量的固定上限：200MB。
  ///
  /// 不再取「危险线的一半」（以前是 dangerRssBytes ~/ 2）：那样会让
  /// 同一本书在内存小的手机上被拒、在内存大的手机上能读，判断结果
  /// 随机型漂浮。解压后总量是文件自身的属性，标准就不该跟着机型变。
  /// 200MB 足够覆盖绝大多数电子书；真到这一步，解压出来的东西已经
  /// 不可能放进任何手机进程了。
  static const int _defaultUncompressed = 200 * 1024 * 1024;

  /// 本机进程 RSS 危险线（字节）。
  ///
  /// 现在**只用于诊断日志**：既不跟实际占用比较（原判断已停用），
  /// 也不再参与推算任何上限。
  final int dangerRssBytes;

  /// 压缩包解压后的总大小上限（字节）。
  final int maxUncompressedBytes;

  /// 单个 EPUB 章节解压后的大小上限（字节），超过则跳过该章。
  ///
  /// 取 32MB：以前是 8MB，但有些 epub 会把整本书塞进一个 xhtml，
  /// 8MB 会把整本跳过，用户看到的是“书打不开”而不是“某章丢了”。
  /// 正常章节通常几十 KB，碰不到这条。
  final int maxChapterBytes;

  /// EPUB 章节数上限。
  ///
  /// 取 20000：超长连载小说能到上万章，原先的 5000 会误伤。
  final int maxChapters;

  /// 解析结果段落数上限。
  ///
  /// 取 500 万：按每段 30 字估，相当于 150MB 级别的纯文本，
  /// 到这个量才真的需要担心内存。正常几十 MB 的小说碰不到。
  final int maxParagraphs;

  /// 采样点占位：不再按进程内存中止解析。
  ///
  /// 解析流程里原有的采样位置（DOCX 每 1 万段 / 每 1 千行表格、
  /// EPUB 每章开头）仍在调用它，所以保留成空实现，调用点不必改动。
  /// 将来若要重新加上内存兜底，只改这里即可。
  void checkMemory() {}

  /// 段落数超限时中止。
  void checkParagraphs(int count) {
    if (count <= maxParagraphs) return;
    throw ParseAbortException(
      '文档段落数超过 $maxParagraphs，已停止解析。请换小一点的文件。',
    );
  }

  /// 章节数超限时中止。
  void checkChapters(int count) {
    if (count <= maxChapters) return;
    throw ParseAbortException(
      'EPUB 章节数超过 $maxChapters，已停止解析。请换小一点的文件。',
    );
  }
}
