import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../preprocessing/domain/encoding_type.dart';
import '../domain/document_format.dart';
import '../domain/parsed_document.dart';
import 'parse_limits.dart';
import 'zip_guard.dart';

/// .docx (Office Open XML) parser.
///
/// Walks `word/document.xml` body in document order, extracting:
///   - Each `<w:p>` as one paragraph (text from `<w:t>`, tab from `<w:tab/>`,
///     newline from `<w:br/>` and `<w:cr/>`)
///   - Each `<w:tbl>` as one paragraph containing cells joined by `\t` and
///     rows joined by `\n` (structured table extraction preserves row/col
///     boundaries for diff purposes)
///   - `<w:sdt>` content controls are recursed into so their paragraphs
///     and tables are picked up at the right position in document order
///
/// Empty paragraphs (no text after walk) are skipped, matching TxtParser
/// semantics. OOXML is always UTF-8 (declared in the XML prolog), so we
/// ignore the sniffed encoding and force UTF-8.
class DocxParser {
  const DocxParser();

  static const String _wNs =
      'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

  ParsedDocument parse(
    String fileName,
    Uint8List bytes,
    EncodingType encoding, {
    ParseLimits? limits,
  }) {
    final guard = limits ?? ParseLimits.fallback();
    final archive = _decodeZip(bytes, guard.maxUncompressedBytes);
    final xmlString = _readDocumentXml(archive);
    final doc = _parseXml(xmlString);

    final bodies = doc.findAllElements('body', namespace: _wNs);
    if (bodies.isEmpty) {
      throw FormatException('No <w:body> element in word/document.xml.');
    }

    final paragraphs = <String>[];
    _collectParagraphs(bodies.first, paragraphs, guard);

    return ParsedDocument(
      fileName: fileName,
      format: DocumentFormat.docx,
      encoding: EncodingType.utf8, // OOXML spec mandates UTF-8.
      paragraphs: paragraphs,
      byteSize: bytes.length,
    );
  }

  /// Recursively walks `parent`'s element children, emitting one entry per
  /// `<w:p>` (paragraph) or `<w:tbl>` (table-as-paragraph) in document order.
  /// `<w:sdt>` content controls are descended into via `<w:sdtContent>`.
  void _collectParagraphs(
    XmlElement parent,
    List<String> out,
    ParseLimits guard,
  ) {
    for (final child in parent.childElements) {
      switch (child.name.local) {
        case 'p':
          final text = _extractParagraphText(child);
          if (text.isNotEmpty) {
            out.add(text);
            guard.checkParagraphs(out.length);
            // 每 1 万段探一次内存；checkMemory 内部还有节流，不会真读这么勤。
            if (out.length % 10000 == 0) guard.checkMemory();
          }
          break;
        case 'tbl':
          final tableText = _extractTable(child, guard);
          if (tableText.isNotEmpty) {
            out.add(tableText);
            guard.checkParagraphs(out.length);
          }
          break;
        case 'sdt':
          // 只取直接子 sdtContent：findElements 会递归找到嵌套控件里的
          // sdtContent，导致内层内容被处理两次。
          for (final sdtContent in child.childElements) {
            if (sdtContent.name.local == 'sdtContent') {
              _collectParagraphs(sdtContent, out, guard);
            }
          }
          break;
        // customXml / smartTag 只是包一层，里面仍然是正常的段落/表格，
        // 不递归会漏掉 WPS 等生成器产出的正文。
        case 'customXml':
        case 'smartTag':
          _collectParagraphs(child, out, guard);
          break;
        // 修订：保留插入内容，跳过已删除内容（delText 本来也不会被 w:t 取到）。
        case 'ins':
        case 'moveTo':
          _collectParagraphs(child, out, guard);
          break;
        // 块级兼容内容同样只取一个分支，避免整段漏掉或读两遍。
        case 'AlternateContent':
          XmlElement? branch;
          for (final c in child.childElements) {
            if (c.name.local == 'Choice') {
              branch = c;
              break;
            }
          }
          if (branch == null) {
            for (final c in child.childElements) {
              if (c.name.local == 'Fallback') {
                branch = c;
                break;
              }
            }
          }
          if (branch != null) _collectParagraphs(branch, out, guard);
          break;
        // Other direct body children (sectPr, etc.) are ignored.
      }
    }
  }

  /// Walks `<w:p>` in document order, collecting text from `<w:t>`, tab from
  /// `<w:tab/>`, newline from `<w:br/>` and `<w:cr/>`.
  ///
  /// 递归而不是平铺遍历，因为有两类内容必须整棵子树跳过 / 只取一支：
  ///   - `w:moveFrom` 是"移动前"的旧内容，平铺会和新位置重复读出；
  ///   - `mc:AlternateContent` 的 Choice / Fallback 是同一内容的两个版本，
  ///     平铺会把同一句话读两遍。
  String _extractParagraphText(XmlElement paragraph) {
    final buf = StringBuffer();
    _collectText(paragraph, buf);
    return buf.toString();
  }

  void _collectText(XmlElement parent, StringBuffer buf) {
    for (final child in parent.childElements) {
      switch (child.name.local) {
        case 't':
          buf.write(child.text);
          break;
        case 'tab':
          buf.write('\t');
          break;
        case 'br':
        case 'cr':
          buf.write('\n');
          break;
        case 'noBreakHyphen':
          buf.write('\u2011');
          break;
        // 软连字符是排版提示，显示时不占位，不写入正文，避免假差异。
        case 'softHyphen':
          break;
        // 符号字符是字体私有码位，无法可靠映射到 Unicode；
        // 写入固定占位符，让"这里有个符号"在对比里可见。
        case 'sym':
          buf.write('[符号]');
          break;
        // 已删除 / 移动前的内容不参与对比。
        case 'del':
        case 'moveFrom':
          break;
        // 兼容内容只取一个分支：优先 Choice，没有再取 Fallback。
        case 'AlternateContent':
          XmlElement? branch;
          for (final c in child.childElements) {
            if (c.name.local == 'Choice') {
              branch = c;
              break;
            }
          }
          if (branch == null) {
            for (final c in child.childElements) {
              if (c.name.local == 'Fallback') {
                branch = c;
                break;
              }
            }
          }
          if (branch != null) _collectText(branch, buf);
          break;
        default:
          _collectText(child, buf);
          break;
      }
    }
  }

  /// Extracts a table as one paragraph: cells in a row joined by `\t`,
  /// rows joined by `\n`. Nested tables inside cells recurse via
  /// [_collectParagraphs] and become a single multi-line "cell paragraph".
  ///
  /// 只取表格的**直接子行**（w:tr）：不能用 findElements 递归匹配，
  /// 否则嵌套表格的行/单元格会被外层表格重复收集，顺序错乱。
  String _extractTable(XmlElement table, ParseLimits guard) {
    final rows = <String>[];
    for (final tr in _tableRows(table)) {
      // 超大表格（几十万行）同样要把内存和规模卡住，
      // 否则一次 add 出来的 tableText 就能撑爆进程。
      guard.checkParagraphs(rows.length);
      if (rows.length % 1000 == 0) guard.checkMemory();
      final cells = <String>[];
      for (final tc in _rowCells(tr)) {
        final cellParagraphs = <String>[];
        _collectParagraphs(tc, cellParagraphs, guard);
        cells.add(cellParagraphs.join('\n'));
      }
      if (cells.isNotEmpty) rows.add(cells.join('\t'));
    }
    return rows.join('\n');
  }

  /// 表格的直接子行，同时展开 `w:sdt` 包裹的行（窗体、重复节）。
  /// 仍然不递归任意后代，避免把嵌套表格的行算进外层表格。
  Iterable<XmlElement> _tableRows(XmlElement table) sync* {
    for (final child in table.childElements) {
      if (child.name.local == 'tr') {
        yield child;
      } else if (child.name.local == 'sdt') {
        for (final content in child.childElements) {
          if (content.name.local == 'sdtContent') {
            yield* _tableRows(content);
          }
        }
      }
    }
  }

  /// 行的直接单元格，同时展开 `w:sdt` 包裹的单元格。
  Iterable<XmlElement> _rowCells(XmlElement tr) sync* {
    for (final child in tr.childElements) {
      if (child.name.local == 'tc') {
        yield child;
      } else if (child.name.local == 'sdt') {
        for (final content in child.childElements) {
          if (content.name.local == 'sdtContent') {
            yield* _rowCells(content);
          }
        }
      }
    }
  }

  Archive _decodeZip(Uint8List bytes, int maxUncompressedBytes) {
    // 解压前做内存预检（与 EPUB 共用 ZipGuard），避免大文档 OOM。
    ZipGuard.check(bytes, format: 'DOCX', maxBytes: maxUncompressedBytes);
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw FormatException('Not a valid .docx (zip) file: $e');
    }
  }

  String _readDocumentXml(Archive archive) {
    final file = archive.findFile('word/document.xml');
    if (file == null) {
      throw FormatException(
        'word/document.xml not found inside .docx archive.',
      );
    }
    final content = file.content;
    final List<int> raw;
    if (content is List<int>) {
      raw = content;
    } else if (content is Uint8List) {
      raw = content;
    } else {
      // Fallback for older archive versions exposing InputStream.
      throw FormatException(
        'Unexpected document.xml content type: ${content.runtimeType}',
      );
    }
    try {
      final text = utf8.decode(raw);
      // Word 通常不写 BOM，但个别生成器会带。
      // BOM 留着会让 XmlDocument.parse 直接失败。
      return text.startsWith('\uFEFF') ? text.substring(1) : text;
    } on FormatException catch (e) {
      throw FormatException('word/document.xml is not valid UTF-8: $e');
    }
  }

  XmlDocument _parseXml(String xmlString) {
    try {
      return XmlDocument.parse(xmlString);
    } on Exception catch (e) {
      throw FormatException('Invalid XML in word/document.xml: $e');
    }
  }
}
