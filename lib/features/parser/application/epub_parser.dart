import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/domain/encoding_type.dart';
import 'parse_limits.dart';
import 'zip_guard.dart';
import '../domain/document_format.dart';
import '../domain/parsed_document.dart';

/// .epub (EPUB 2/3) 解析器：把一本电子书还原成「按阅读顺序排列的正文纯文本」。
///
/// EPUB 本质是一个 ZIP 包，里面装的是一堆 XHTML 网页。与 DOCX 相比，
/// 正文不集中在单个文件，而是散落在多个章节文件里，因此多两步：
///   1. 读 META-INF/container.xml 找到 .opf，再从 .opf 的 <spine> 拿到
///      **阅读顺序**（不能按文件名排序，否则 chapter10 会排到 chapter2 前）。
///   2. 逐章把 XHTML 去标签、去 script/style、解码 HTML 实体，抽成纯文本。
///
/// 容错策略（真实书里畸形 XHTML 很多）：
///   - container.xml / .opf 是规范 XML，用 xml 包解析；解析失败则兜底找任意 .opf。
///   - 章节正文用宽容的正则方式处理，不要求严格 XML，遇到畸形标签也不会整本失败。
///   - 个别章节缺失 / 解压不出来只跳过该章；一章都读不到才抛 FormatException。
///
/// 图片、样式、封面、目录元数据、脚本一律不进正文——对比只关心文字。
/// EPUB 内部统一 UTF-8（XHTML/XML 规范强制），忽略外部嗅探到的编码。
class EpubParser {
  const EpubParser();

  ParsedDocument parse(
    String fileName,
    Uint8List bytes,
    EncodingType encoding, {
    ParseLimits? limits,
  }) {
    final guard = limits ?? ParseLimits.fallback();
    final archive = _decodeZip(bytes, guard.maxUncompressedBytes);

    // 建规范化索引：archive.findFile 要求精确路径，而书里的 href 常带
    // ./ 或 ../，先统一规范化再查，命中率高很多。
    // 再建一份小写索引：Windows 上制作的书经常出现 OPF 里 href 大小写
    // 与实际条目不一致，严格匹配会整章读不到（且不报错）。
    final index = <String, ArchiveFile>{};
    final lowerIndex = <String, ArchiveFile>{};
    for (final f in archive.files) {
      if (!f.isFile || f.name.isEmpty) continue;
      final normalized = _normalize(f.name);
      index[normalized] = f;
      lowerIndex.putIfAbsent(normalized.toLowerCase(), () => f);
    }

    final opfPath = _locateOpf(index, lowerIndex);
    final opfXml = _parseXml(_readEntry(index, lowerIndex, opfPath), 'OPF');
    final chapterHrefs = _spineHrefs(opfXml);

    final paragraphs = <String>[];
    var chapterCount = 0;

    // 主路径：严格按 spine 顺序读正文。
    for (final href in chapterHrefs) {
      guard.checkChapters(++chapterCount);
      guard.checkMemory();
      if (href == null) {
        // itemref 指向不存在的 manifest ID，同样不能静默跳过。
        paragraphs.add('[EPUB 章节缺失]');
        continue;
      }
      final path = _resolveEntryPath(opfPath, href);
      final file = _find(index, lowerIndex, path);
      if (file == null) {
        // 不静默跳过：缺章会让对比结果看起来像"整章被删除"，
        // 插入一行明确标记，让差异可见。
        paragraphs.add('[EPUB 章节缺失]');
        continue;
      }
      if (file.size > guard.maxChapterBytes) {
        // 单章异常大（通常是整本塞进一个 xhtml），跳过并标记，
        // 避免一章把内存撑爆。
        paragraphs.add('[EPUB 章节过大，已跳过]');
        continue;
      }
      final raw = _readEntry(index, lowerIndex, path);
      final chapterParagraphs = _toParagraphs(_xhtmlToText(raw));
      if (chapterParagraphs.isEmpty) {
        // 正文为空时才用 <title> 兜底：正常章节不插元数据，
        // 但只有标题的章节也不会整章消失。
        final title = _extractTitle(raw);
        if (title != null) paragraphs.add(title);
      } else {
        paragraphs.addAll(chapterParagraphs);
      }
      guard.checkParagraphs(paragraphs.length);
    }

    // 兜底：spine 为空（畸形 / 极简 epub）时，按文件名自然顺序收所有
    // html 文件。必须用自然排序，否则 chapter10 会排在 chapter2 前面，
    // 造成大面积假差异。跳过 nav/cover/toc 这类导航文件。
    if (paragraphs.isEmpty) {
      final htmlPaths = index.keys
          .where(_isHtmlName)
          .where((p) => !_isNavigationName(p))
          .toList()
        ..sort(_naturalCompare);
      var fallbackCount = 0;
      for (final path in htmlPaths) {
        guard.checkChapters(++fallbackCount);
        guard.checkMemory();
        final file = index[path];
        if (file != null && file.size > guard.maxChapterBytes) {
          paragraphs.add('[EPUB 章节过大，已跳过]');
          continue;
        }
        paragraphs.addAll(
          _toParagraphs(_xhtmlToText(_readEntry(index, lowerIndex, path))),
        );
        guard.checkParagraphs(paragraphs.length);
      }
    }

    if (paragraphs.isEmpty) {
      throw FormatException('No readable text found in .epub: $fileName');
    }

    return ParsedDocument(
      fileName: fileName,
      format: DocumentFormat.epub,
      encoding: EncodingType.utf8,
      paragraphs: paragraphs,
      byteSize: bytes.length,
    );
  }

  /// 按 local name 找后代元素，忽略命名空间。
  ///
  /// EPUB 规范强制 container.xml / .opf 带默认命名空间（或 opf: 前缀），
  /// 而 findAllElements 的 namespace 形参语义在不同版本里不完全一致，
  /// 这里自己按 local name 过滤，带不带命名空间都能命中，避免整本解析失败。
  Iterable<XmlElement> _elements(XmlNode node, String localName) =>
      node.descendantElements.where((e) => e.name.local == localName);

  /// 同上：按 local name 取属性（属性一般无前缀，统一处理更稳）。
  String? _attr(XmlElement element, String localName) {
    for (final a in element.attributes) {
      if (a.name.local == localName) return a.value;
    }
    return null;
  }

  /// 定位 .opf：优先按 META-INF/container.xml 的 rootfile 指路；
  /// 容器缺失或指的路径找不到时，兜底取包里第一个 .opf 文件。
  String _locateOpf(
    Map<String, ArchiveFile> index,
    Map<String, ArchiveFile> lowerIndex,
  ) {
    final container = _find(
      index,
      lowerIndex,
      'META-INF/container.xml',
    );
    if (container != null) {
      try {
        final doc = XmlDocument.parse(
          _readEntry(index, lowerIndex, 'META-INF/container.xml'),
        );
        for (final rf in _elements(doc, 'rootfile')) {
          final fullPath = _attr(rf, 'full-path');
          if (fullPath == null || fullPath.isEmpty) continue;
          final normalized = _normalize(Uri.decodeComponent(fullPath));
          final hit = _find(index, lowerIndex, normalized);
          if (hit != null) return normalized;
        }
      } on Exception {
        // container.xml 损坏 → 落到下面的兜底。
      }
    }

    final opfs = index.keys.where((p) => p.toLowerCase().endsWith('.opf')).toList()
      ..sort();
    if (opfs.isNotEmpty) return opfs.first;

    throw FormatException('META-INF/container.xml or any .opf not found in .epub.');
  }

  /// 精确路径找不到时，回退到小写路径（兼容 Windows 上制作的书）。
  ArchiveFile? _find(
    Map<String, ArchiveFile> index,
    Map<String, ArchiveFile> lowerIndex,
    String path,
  ) {
    return index[path] ?? lowerIndex[path.toLowerCase()];
  }

  /// 导航/封面类文件名：只在 spine 缺失的兜底路径里用于排除。
  bool _isNavigationName(String path) {
    final name = path.split('/').last.toLowerCase();
    return name.startsWith('nav') ||
        name.startsWith('toc') ||
        name.startsWith('cover') ||
        name.startsWith('titlepage') ||
        name.startsWith('copyright');
  }

  /// 从 .opf 的 <manifest> + <spine> 取出正文文件的引用列表（已按顺序）。
  /// 过滤掉图片/样式/脚本等非文本内容、linear="no" 的非正文项，
  /// 以及 EPUB 3 用 properties="nav" 标记的导航文档。
  ///
  /// 返回值里的 null 表示 itemref 指向了不存在的 manifest ID，
  /// 上层需要把它当成缺章处理，不能静默忽略。
  List<String?> _spineHrefs(XmlDocument opf) {
    final manifest = <String, _ManifestItem>{};
    for (final item in _elements(opf, 'item')) {
      final id = _attr(item, 'id');
      final href = _attr(item, 'href');
      if (id == null || href == null) continue;
      manifest[id] = _ManifestItem(
        href,
        _attr(item, 'media-type'),
        _attr(item, 'properties'),
      );
    }

    final hrefs = <String?>[];
    for (final ref in _elements(opf, 'itemref')) {
      final idref = _attr(ref, 'idref');
      if (idref == null) continue;
      final linear = _attr(ref, 'linear');
      if (linear != null && linear.toLowerCase() == 'no') continue;
      final item = manifest[idref];
      if (item == null) {
        // 坏引用：保留位置，让上层插入缺章标记。
        hrefs.add(null);
        continue;
      }
      // EPUB 3 规范的导航文档标记。
      if (item.isNav) continue;
      // 部分不规范的书不写 properties="nav"，用文件名兜底。
      if (_isSpineNavigationHref(item.href)) continue;
      if (!_isTextMedia(item.mediaType, item.href)) continue;
      hrefs.add(item.href);
    }
    return hrefs;
  }

  /// spine 路径只按 nav/toc 前缀兜底；不要用完整的 _isNavigationName，
  /// 否则会把名字正常的封面/版权正文页也误删。
  bool _isSpineNavigationHref(String href) {
    final name = href.split('/').last.toLowerCase();
    return name.startsWith('nav') || name.startsWith('toc');
  }

  bool _isTextMedia(String? mediaType, String href) {
    if (mediaType == null) return _isHtmlName(href);
    final m = mediaType.toLowerCase();
    if (m.startsWith('image/') ||
        m.startsWith('audio/') ||
        m.startsWith('video/')) {
      return false;
    }
    if (m.contains('css') || m.contains('javascript') || m.contains('json')) {
      return false;
    }
    return m.contains('html') || m == 'application/xml' || m == 'text/xml';
  }

  bool _isHtmlName(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.xhtml') ||
        lower.endsWith('.html') ||
        lower.endsWith('.htm');
  }

  /// 把 OPF 里的相对 href 解析成包内路径：
  /// 去掉 #fragment / ?query，解码百分号，相对 OPF 所在目录拼接，再规范化 ../。
  String _resolveEntryPath(String opfPath, String href) {
    var h = href.split('#').first.split('?').first;
    try {
      h = Uri.decodeComponent(h);
    } on FormatException {
      // 畸形百分号编码，按原样处理。
    }
    if (h.startsWith('/')) return _normalize(h.substring(1));
    final slash = opfPath.lastIndexOf('/');
    final base = slash < 0 ? '' : opfPath.substring(0, slash + 1);
    return _normalize(base + h);
  }

  /// 规范化路径：去掉空段与 '.'，遇 '..' 回退一层。
  String _normalize(String path) {
    final parts = <String>[];
    for (final seg in path.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }

  /// 自然排序：数字段按数值比较，避免 chapter10 排在 chapter2 前面。
  int _naturalCompare(String a, String b) {
    final re = RegExp(r'(\d+|\D+)');
    final sa = re.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
    final sb = re.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
    final n = sa.length < sb.length ? sa.length : sb.length;
    for (var i = 0; i < n; i++) {
      final x = sa[i];
      final y = sb[i];
      final nx = int.tryParse(x);
      final ny = int.tryParse(y);
      final c = (nx != null && ny != null)
          ? nx.compareTo(ny)
          : x.compareTo(y);
      if (c != 0) return c;
    }
    return sa.length.compareTo(sb.length);
  }

  /// 宽容地把一章 XHTML 转成文本：先剥掉声明/注释/script/style/CDATA，
  /// 块级标签换成换行，其余标签直接去掉，最后解码 HTML 实体。
  /// 不要求严格 XML——畸形标签也不会抛异常，顶多少抽几个字。
  String _xhtmlToText(String raw) {
    var s = raw;
    s = s.replaceAll(RegExp(r'<\?xml[^>]*\?>', caseSensitive: false), '');
    s = s.replaceAll(
      RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false, dotAll: true),
      '',
    );
    s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
    s = s.replaceAllMapped(
      RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>'),
      (m) => m.group(1) ?? '',
    );
    // <head> 里是章节标题 / 样式 / 脚本等元数据，不属于正文，整段丢弃。
    s = s.replaceAll(
      RegExp(
        r'<head\b[^>]*>.*?</head\s*>',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    );
    s = s.replaceAll(
      RegExp(
        r'<script\b[^>]*>.*?</script\s*>',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    );
    s = s.replaceAll(
      RegExp(
        r'<style\b[^>]*>.*?</style\s*>',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    );
    // 注音：<ruby>漢字<rt>かんじ</rt></ruby> 只保留汉字，去掉读音，
    // 否则每个词后面都会多出一段假差异。
    s = s.replaceAll(
      RegExp(r'<rt\b[^>]*>[\s\S]*?</rt\s*>', caseSensitive: false),
      '',
    );
    s = s.replaceAll(
      RegExp(r'<rp\b[^>]*>[\s\S]*?</rp\s*>', caseSensitive: false),
      '',
    );
    // 表格单元格：结束标签换成制表符，开始标签直接去掉。
    // 否则 <td>A</td><td>B</td> 会粘成 "AB"，列边界丢失。
    s = s.replaceAll(
      RegExp(r'</(?:td|th)\s*>', caseSensitive: false),
      '\t',
    );
    s = s.replaceAll(
      RegExp(r'<(?:td|th)\b[^>]*>', caseSensitive: false),
      '',
    );
    s = s.replaceAll(
      RegExp(
        r'</?(?:p|div|h[1-6]|li|br|tr|blockquote|section|article|table|ul|ol|dl|dt|dd|hr)\b[^>]*>',
        caseSensitive: false,
      ),
      '\n',
    );
    s = s.replaceAll(RegExp(r'<[^>]*>'), '');
    return _decodeEntities(s);
  }

  /// 解码数字实体（十进制/十六进制）与常见命名实体。
  /// 未知命名实体原样保留，避免误伤正文里的 "&"。
  String _decodeEntities(String s) {
    s = s.replaceAllMapped(RegExp(r'&#(x[0-9a-fA-F]+|[0-9]+);'), (m) {
      final code = m.group(1)!;
      final cp = (code.startsWith('x') || code.startsWith('X'))
          ? int.tryParse(code.substring(1), radix: 16)
          : int.tryParse(code);
      if (cp == null || cp < 0 || cp > 0x10FFFF) return m.group(0)!;
      if (cp >= 0xD800 && cp <= 0xDFFF) return '';
      return String.fromCharCodes(<int>[cp]);
    });

    // 常用 HTML4 命名实体（拉丁字母 / 希腊字母 / 标点 / 数学符号）。
    // 表不可能穷尽，但覆盖真实书里 99% 的用法；未知实体原样保留。
    const named = <String, String>{
      // 基础
      'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'",
      // 拉丁-1
      'nbsp': ' ', 'iexcl': '¡', 'cent': '¢', 'pound': '£', 'curren': '¤',
      'yen': '¥', 'brvbar': '¦', 'sect': '§', 'uml': '¨', 'copy': '©',
      'ordf': 'ª', 'laquo': '«', 'not': '¬', 'shy': '', 'reg': '®',
      'macr': '¯', 'deg': '°', 'plusmn': '±', 'sup2': '²', 'sup3': '³',
      'acute': '´', 'micro': 'µ', 'para': '¶', 'middot': '·', 'cedil': '¸',
      'sup1': '¹', 'ordm': 'º', 'raquo': '»', 'frac14': '¼', 'frac12': '½',
      'frac34': '¾', 'iquest': '¿', 'Agrave': 'À', 'Aacute': 'Á',
      'Acirc': 'Â', 'Atilde': 'Ã', 'Auml': 'Ä', 'Aring': 'Å', 'AElig': 'Æ',
      'Ccedil': 'Ç', 'Egrave': 'È', 'Eacute': 'É', 'Ecirc': 'Ê', 'Euml': 'Ë',
      'Igrave': 'Ì', 'Iacute': 'Í', 'Icirc': 'Î', 'Iuml': 'Ï', 'ETH': 'Ð',
      'Ntilde': 'Ñ', 'Ograve': 'Ò', 'Oacute': 'Ó', 'Ocirc': 'Ô',
      'Otilde': 'Õ', 'Ouml': 'Ö', 'times': '×', 'Oslash': 'Ø',
      'Ugrave': 'Ù', 'Uacute': 'Ú', 'Ucirc': 'Û', 'Uuml': 'Ü', 'Yacute': 'Ý',
      'THORN': 'Þ', 'szlig': 'ß', 'agrave': 'à', 'aacute': 'á',
      'acirc': 'â', 'atilde': 'ã', 'auml': 'ä', 'aring': 'å', 'aelig': 'æ',
      'ccedil': 'ç', 'egrave': 'è', 'eacute': 'é', 'ecirc': 'ê', 'euml': 'ë',
      'igrave': 'ì', 'iacute': 'í', 'icirc': 'î', 'iuml': 'ï', 'eth': 'ð',
      'ntilde': 'ñ', 'ograve': 'ò', 'oacute': 'ó', 'ocirc': 'ô',
      'otilde': 'õ', 'ouml': 'ö', 'divide': '÷', 'oslash': 'ø',
      'ugrave': 'ù', 'uacute': 'ú', 'ucirc': 'û', 'uuml': 'ü', 'yacute': 'ý',
      'thorn': 'þ', 'yuml': 'ÿ',
      // 扩展拉丁 / 标点
      'OElig': 'Œ', 'oelig': 'œ', 'Scaron': 'Š', 'scaron': 'š', 'Yuml': 'Ÿ',
      'fnof': 'ƒ', 'circ': 'ˆ', 'tilde': '˜', 'ensp': ' ', 'emsp': ' ',
      'thinsp': ' ', 'zwnj': '', 'zwj': '', 'lrm': '', 'rlm': '',
      'ndash': '–', 'mdash': '—', 'lsquo': '‘', 'rsquo': '’', 'sbquo': '‚',
      'ldquo': '“', 'rdquo': '”', 'bdquo': '„', 'dagger': '†', 'Dagger': '‡',
      'bull': '•', 'hellip': '…', 'permil': '‰', 'prime': '′', 'Prime': '″',
      'lsaquo': '‹', 'rsaquo': '›', 'oline': '‾', 'frasl': '⁄', 'euro': '€',
      // 数学 / 箭头 / 货币符号
      'image': 'ℑ', 'weierp': '℘', 'real': 'ℜ', 'trade': '™',
      'alefsym': 'ℵ', 'larr': '←', 'uarr': '↑', 'rarr': '→', 'darr': '↓',
      'harr': '↔', 'crarr': '↵', 'lArr': '⇐', 'uArr': '⇑', 'rArr': '⇒',
      'dArr': '⇓', 'hArr': '⇔', 'forall': '∀', 'part': '∂', 'exist': '∃',
      'empty': '∅', 'nabla': '∇', 'isin': '∈', 'notin': '∉', 'ni': '∋',
      'prod': '∏', 'sum': '∑', 'minus': '−', 'lowast': '∗', 'radic': '√',
      'prop': '∝', 'infin': '∞', 'ang': '∠', 'and': '∧', 'or': '∨',
      'cap': '∩', 'cup': '∪', 'int': '∫', 'there4': '∴', 'sim': '∼',
      'cong': '≅', 'asymp': '≈', 'ne': '≠', 'equiv': '≡', 'le': '≤',
      'ge': '≥', 'sub': '⊂', 'sup': '⊃', 'nsub': '⊄', 'sube': '⊆',
      'supe': '⊇', 'oplus': '⊕', 'otimes': '⊗', 'perp': '⊥', 'sdot': '⋅',
      'lceil': '⌈', 'rceil': '⌉', 'lfloor': '⌊', 'rfloor': '⌋',
      'lang': '〈', 'rang': '〉', 'loz': '◊', 'spades': '♠', 'clubs': '♣',
      'hearts': '♥', 'diams': '♦',
      // 希腊字母
      'Alpha': 'Α', 'Beta': 'Β', 'Gamma': 'Γ', 'Delta': 'Δ', 'Epsilon': 'Ε',
      'Zeta': 'Ζ', 'Eta': 'Η', 'Theta': 'Θ', 'Iota': 'Ι', 'Kappa': 'Κ',
      'Lambda': 'Λ', 'Mu': 'Μ', 'Nu': 'Ν', 'Xi': 'Ξ', 'Omicron': 'Ο',
      'Pi': 'Π', 'Rho': 'Ρ', 'Sigma': 'Σ', 'Tau': 'Τ', 'Upsilon': 'Υ',
      'Phi': 'Φ', 'Chi': 'Χ', 'Psi': 'Ψ', 'Omega': 'Ω', 'alpha': 'α',
      'beta': 'β', 'gamma': 'γ', 'delta': 'δ', 'epsilon': 'ε', 'zeta': 'ζ',
      'eta': 'η', 'theta': 'θ', 'iota': 'ι', 'kappa': 'κ', 'lambda': 'λ',
      'mu': 'μ', 'nu': 'ν', 'xi': 'ξ', 'omicron': 'ο', 'pi': 'π', 'rho': 'ρ',
      'sigmaf': 'ς', 'sigma': 'σ', 'tau': 'τ', 'upsilon': 'υ', 'phi': 'φ',
      'chi': 'χ', 'psi': 'ψ', 'omega': 'ω', 'thetasym': 'ϑ', 'upsih': 'ϒ',
      'piv': 'ϖ',
    };
    s = s.replaceAllMapped(
      RegExp(r'&([A-Za-z][A-Za-z0-9]*);'),
      (m) => named[m.group(1)] ?? m.group(0)!,
    );
    // 少量书写不规范的书会漏掉分号，只兜底最常见的几个。
    s = s.replaceAllMapped(
      RegExp(r'&(nbsp|amp|lt|gt|quot|apos)(?=\s|[^A-Za-z0-9])'),
      (m) => named[m.group(1)] ?? m.group(0)!,
    );
    return s;
  }

  /// 按行切开、清理首尾空白（含全角空格）、丢弃空行，与 TxtParser 语义一致。
  List<String> _toParagraphs(String text) {
    return text
        .split(RegExp(r'\r\n|\r|\n'))
        .map(_cleanLine)
        .where((line) => line.isNotEmpty)
        .toList();
  }

  String _cleanLine(String line) {
    return line
        .replaceAll('\u00A0', ' ')
        .trim()
        .replaceAll(RegExp(r'^[　\s]+|[　\s]+$'), '');
  }

  Archive _decodeZip(Uint8List bytes, int maxUncompressedBytes) {
    // 解压前做内存预检（与 DOCX 共用 ZipGuard），避免图文书 OOM。
    ZipGuard.check(bytes, format: 'EPUB', maxBytes: maxUncompressedBytes);
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw FormatException('Not a valid .epub (zip) file: $e');
    }
  }

  /// 读取包内一个文本文件。EPUB 规范要求 UTF-8，但少数非规范书是 GBK/
  /// Big5：严格 UTF-8 失败时用项目已有的编码探测兜底，避免整章乱码。
  String _readEntry(
    Map<String, ArchiveFile> index,
    Map<String, ArchiveFile> lowerIndex,
    String path,
  ) {
    final file = _find(index, lowerIndex, path);
    if (file == null) {
      throw FormatException('Entry not found in .epub: $path');
    }
    final content = file.content;
    final Uint8List raw;
    if (content is Uint8List) {
      raw = content;
    } else if (content is List<int>) {
      raw = Uint8List.fromList(content);
    } else {
      throw FormatException(
        'Unexpected content type for $path: ${content.runtimeType}',
      );
    }
    try {
      return _stripBom(utf8.decode(raw));
    } on FormatException {
      // 非规范 EPUB 的编码兜底。注意不能只依赖 EncodingDetector.detect：
      // Android 上它遇到多字节候选会返回 unknown（等 ICU 复核），而
      // EPUB 解析在后台 isolate 里跑，拿不到 ICU，直接按 UTF-8 宽松解码
      // 会把 GBK/Big5 章节变成一片 U+FFFD。
      //
      // 1) 优先按章节自带的编码声明解码（XML prolog / meta charset）。
      final declared = _declaredEncoding(raw);
      if (declared != null) {
        try {
          final text = EncodingDetector.decode(raw, declared);
          if (_badRatio(text) <= 0.02) return _stripBom(text);
        } on FormatException {
          // 声明的编码和实际字节不符（比如写了 utf-8 实际是 GBK），
          // 不能让这一章直接失败，继续下面的候选尝试。
        }
      }
      // 2) 没有声明：按 GBK / Big5 各试一次，选坏字符更少的。
      String? best;
      var bestScore = 1.0;
      for (final enc in const [EncodingType.gbk, EncodingType.big5]) {
        String text;
        try {
          text = EncodingDetector.decode(raw, enc);
        } on FormatException {
          continue;
        }
        final score = _badRatio(text);
        if (score < bestScore) {
          bestScore = score;
          best = text;
        }
      }
      if (best != null && bestScore <= 0.05) return _stripBom(best);
      // 3) 都不像：退回 UTF-8 宽松解码，至少不抛异常。
      return _stripBom(utf8.decode(raw, allowMalformed: true));
    }
  }

  /// 去掉 UTF-8 BOM。BOM 不属于空白字符，trim 去不掉；
  /// 留着会让 XML 解析失败，或在正文首段带出一个不可见的 U+FEFF。
  String _stripBom(String s) =>
      s.startsWith('\uFEFF') ? s.substring(1) : s;

  /// 从 XHTML 头部读编码声明。只看前 4KB 的 ASCII 兼容区，
  /// 避免把 GBK 字节误当成标签内容。
  EncodingType? _declaredEncoding(Uint8List raw) {
    final head = raw.length > 4096 ? raw.sublist(0, 4096) : raw;
    final ascii = String.fromCharCodes(head.where((b) => b < 0x80));
    final m = RegExp(
      r'''(?:encoding\s*=\s*["']\s*([A-Za-z0-9_\-]+)|charset\s*=\s*["']?\s*([A-Za-z0-9_\-]+))''',
      caseSensitive: false,
    ).firstMatch(ascii);
    final name = (m?.group(1) ?? m?.group(2))?.toLowerCase();
    if (name == null) return null;
    if (name == 'gbk' || name == 'cp936' || name == 'x-gbk') {
      return EncodingType.gbk;
    }
    if (name == 'gb2312') return EncodingType.gb2312;
    if (name == 'gb18030') return EncodingType.gb18030;
    if (name == 'big5' || name == 'big-5' || name == 'cp950') {
      return EncodingType.big5;
    }
    if (name == 'shift_jis' ||
        name == 'shift-jis' ||
        name == 'sjis' ||
        name == 'cp932') {
      return EncodingType.shiftJis;
    }
    if (name == 'utf-8' || name == 'utf8') return EncodingType.utf8;
    if (name == 'utf-16' || name == 'utf-16le') return EncodingType.utf16le;
    if (name == 'utf-16be') return EncodingType.utf16be;
    return null;
  }

  /// 粗略衡量解码结果的坏字符比例：替换字符、控制字符、私用区。
  double _badRatio(String text) {
    if (text.isEmpty) return 0;
    var bad = 0;
    for (final rune in text.runes) {
      if (rune == 0xFFFD ||
          (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) ||
          (rune >= 0xE000 && rune <= 0xF8FF)) {
        bad++;
      }
    }
    return bad / text.length;
  }

  /// 只在章节正文完全为空时用于兜底，正常章节不读元数据。
  String? _extractTitle(String raw) {
    final m = RegExp(
      r'<title\b[^>]*>([\s\S]*?)</title\s*>',
      caseSensitive: false,
    ).firstMatch(raw);
    if (m == null) return null;
    final text = _decodeEntities(m.group(1) ?? '')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
    return text.isEmpty ? null : text;
  }

  XmlDocument _parseXml(String xmlString, String what) {
    try {
      return XmlDocument.parse(xmlString);
    } on Exception catch (e) {
      throw FormatException('Invalid XML in $what: $e');
    }
  }
}

class _ManifestItem {
  const _ManifestItem(this.href, this.mediaType, this.properties);

  final String href;
  final String? mediaType;
  final String? properties;

  /// EPUB 3 用 properties="nav" 标记导航文档（也可能是 "nav scripted"）。
  bool get isNav {
    final p = properties;
    if (p == null) return false;
    return p.toLowerCase().split(RegExp(r'\s+')).contains('nav');
  }
}
