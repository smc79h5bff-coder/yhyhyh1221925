import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:docdiff/features/parser/application/epub_parser.dart';
import 'package:docdiff/features/parser/application/parse_limits.dart';
import 'package:docdiff/features/parser/domain/document_format.dart';
import 'package:docdiff/features/preprocessing/domain/encoding_type.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一个最小的内存 .epub（zip + container.xml + opf + xhtml）。
/// chapters 的值可以是 String（UTF-8）或 List<int>（任意编码）。
Uint8List _buildEpub({
  required Map<String, Object> chapters,
}) {
  final manifestItems = <String>[];
  final spineItems = <String>[];
  var i = 0;
  for (final name in chapters.keys) {
    i++;
    manifestItems.add(
      '<item id="c$i" href="$name" '
      'media-type="application/xhtml+xml"/>',
    );
    spineItems.add('<itemref idref="c$i"/>');
  }

  final opf = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <manifest>${manifestItems.join()}</manifest>
  <spine>${spineItems.join()}</spine>
</package>''';

  return _buildEpubRaw(
    opf: opf,
    files: {for (final e in chapters.entries) 'OEBPS/${e.key}': e.value},
  );
}

/// 完全自定义 OPF 和包内文件，用于构造 nav / 坏 itemref 等特殊情况。
Uint8List _buildEpubRaw({
  required String opf,
  required Map<String, Object> files,
}) {
  const container = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0"
  xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf"
      media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

  final archive = Archive();
  void add(String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('META-INF/container.xml', utf8.encode(container));
  add('OEBPS/content.opf', utf8.encode(opf));
  files.forEach((name, content) {
    add(name, content is String ? utf8.encode(content) : content as List<int>);
  });

  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded ?? const <int>[]);
}

String _chapter(String title, String body) => '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>$title</title></head>
<body>$body</body>
</html>''';

void main() {
  group('EpubParser', () {
    const parser = EpubParser();

    test('按 spine 顺序输出正文，去标签并解实体', () {
      final bytes = _buildEpub(chapters: {
        'chapter1.xhtml':
            _chapter('第一章', '<h1>第一章</h1><p>你好&amp;世界</p>'),
        'chapter2.xhtml':
            _chapter('第二章', '<p>第二段</p><p>第三段&hellip;</p>'),
      });
      final r = parser.parse('book.epub', bytes, EncodingType.utf8);

      expect(r.format, DocumentFormat.epub);
      // <title> 属于元数据，不写入正文；正文标题以 h1 为准。
      expect(r.paragraphs, ['第一章', '你好&世界', '第二段', '第三段…']);
    });

    test('head 里的 title 不写入正文（避免跨格式假差异）', () {
      final bytes = _buildEpub(chapters: {
        'chapter1.xhtml': _chapter('只有标题', '<p>正文</p>'),
      });
      final r = parser.parse('book.epub', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['正文']);
      expect(r.paragraphs, isNot(contains('只有标题')));
    });

    test('正文 h1 仍然保留', () {
      final bytes = _buildEpub(chapters: {
        'chapter1.xhtml': _chapter('同名标题', '<h1>同名标题</h1><p>正文</p>'),
      });
      final r = parser.parse('book.epub', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['同名标题', '正文']);
    });

    test('spine 指向的章节缺失时插入明确标记，不静默跳过', () {
      final mixed = _buildEpub(chapters: {
        'chapter1.xhtml': _chapter('第一章', '<p>正文</p>'),
      });
      // 手工把 OPF 的 spine 指向一个不存在的章节。
      final archive = ZipDecoder().decodeBytes(mixed);
      final opfFile = archive.findFile('OEBPS/content.opf')!;
      final opfText = utf8
          .decode(opfFile.content as List<int>)
          .replaceAll('</spine>', '<itemref idref="missing"/></spine>')
          .replaceAll(
            '</manifest>',
            '<item id="missing" href="missing.xhtml" '
                'media-type="application/xhtml+xml"/></manifest>',
          );
      final patched = Archive();
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final data = f.name == 'OEBPS/content.opf'
            ? utf8.encode(opfText)
            : f.content as List<int>;
        patched.addFile(ArchiveFile(f.name, data.length, data));
      }
      final patchedBytes =
          Uint8List.fromList(ZipEncoder().encode(patched) ?? const []);
      final r = parser.parse('book.epub', patchedBytes, EncodingType.utf8);

      expect(r.paragraphs, contains('[EPUB 章节缺失]'));
      expect(r.paragraphs, contains('正文'));
    });

    test('OPF href 大小写与实际条目不一致时仍能读到（Windows 制作的书）', () {
      final mixed = _buildEpub(chapters: {
        'Chapter1.xhtml': _chapter('第一章', '<p>正文</p>'),
      });
      // 把 OPF 里的 href 改成小写，模拟 Windows 大小写不一致。
      final archive = ZipDecoder().decodeBytes(mixed);
      final opfFile = archive.findFile('OEBPS/content.opf')!;
      final opfText = utf8
          .decode(opfFile.content as List<int>)
          .replaceAll('Chapter1.xhtml', 'chapter1.xhtml');
      final patched = Archive();
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final data = f.name == 'OEBPS/content.opf'
            ? utf8.encode(opfText)
            : f.content as List<int>;
        patched.addFile(ArchiveFile(f.name, data.length, data));
      }
      final patchedBytes =
          Uint8List.fromList(ZipEncoder().encode(patched) ?? const []);
      final r = parser.parse('book.epub', patchedBytes, EncodingType.utf8);

      expect(r.paragraphs, contains('正文'));
    });

    test('畸形 XHTML 不抛异常，尽量抽出文字', () {
      final bytes = _buildEpub(chapters: {
        'chapter1.xhtml':
            '<html><head><title>标题</title></head><body><p>第一行<br>第二行',
      });
      final r = parser.parse('book.epub', bytes, EncodingType.utf8);

      expect(r.paragraphs, isNot(contains('标题')));
      expect(r.paragraphs.join('\n'), contains('第一行'));
    });

    test('properties="nav" 的导航文档不进入正文', () {
      const opf = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="nav"/>
    <itemref idref="c1"/>
  </spine>
</package>''';
      final bytes = _buildEpubRaw(opf: opf, files: {
        'OEBPS/nav.xhtml': _chapter('目录', '<p>第一章</p><p>第二章</p>'),
        'OEBPS/chapter1.xhtml': _chapter('正文', '<p>正文内容</p>'),
      });
      final r = parser.parse('book.epub', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['正文内容']);
    });

    test('itemref 指向不存在的 ID 时插入缺章标记', () {
      const opf = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <manifest>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ghost"/>
    <itemref idref="c1"/>
  </spine>
</package>''';
      final bytes = _buildEpubRaw(opf: opf, files: {
        'OEBPS/chapter1.xhtml': _chapter('正文', '<p>正文内容</p>'),
      });
      final r = parser.parse('book.epub', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['[EPUB 章节缺失]', '正文内容']);
    });

    test('GBK 章节按自带的编码声明解码', () {
      // <?xml encoding="gbk"?> + GBK 字节的「标题」「中文」。
      final gbkChapter = <int>[
        ...utf8.encode(
          '<?xml version="1.0" encoding="gbk"?><html><head><title>',
        ),
        0xB1, 0xEA, 0xCC, 0xE2, // 标题
        ...utf8.encode('</title></head><body><p>'),
        0xD6, 0xD0, 0xCE, 0xC4, // 中文
        ...utf8.encode('</p></body></html>'),
      ];
      final bytes = _buildEpub(chapters: {'chapter1.xhtml': gbkChapter});
      final r = parser.parse('gbk.epub', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['中文']);
    });

    test('无编码声明的 GBK 章节按候选打分解码', () {
      final gbkChapter = <int>[
        ...utf8.encode('<html><body><p>'),
        0xD6, 0xD0, 0xCE, 0xC4, // 中文
        ...utf8.encode('</p></body></html>'),
      ];
      final bytes = _buildEpub(chapters: {'chapter1.xhtml': gbkChapter});
      final r = parser.parse('gbk2.epub', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['中文']);
    });

    test('正文完全为空时用 title 兜底', () {
      final bytes = _buildEpub(chapters: {
        'chapter1.xhtml': _chapter('只有标题', ''),
      });
      final r = parser.parse('empty-body.epub', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['只有标题']);
    });

    test('表格单元格用制表符分隔，不会粘连', () {
      final bytes = _buildEpub(chapters: {
        'chapter1.xhtml': _chapter(
          '表格',
          '<table><tr><td>甲</td><td>乙</td></tr></table>',
        ),
      });
      final r = parser.parse('table.epub', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['甲\t乙']);
    });

    test('章节开头的 UTF-8 BOM 不会残留到正文', () {
      final bomChapter = <int>[
        0xEF, 0xBB, 0xBF, // UTF-8 BOM
        ...utf8.encode(_chapter('标题', '<p>正文</p>')),
      ];
      final bytes = _buildEpub(chapters: {'chapter1.xhtml': bomChapter});
      final r = parser.parse('bom.epub', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['正文']);
      expect(r.paragraphs.first.contains('\uFEFF'), isFalse);
    });

    test('单章超过大小上限时跳过并标记', () {
      final bytes = _buildEpub(chapters: {
        'chapter1.xhtml': _chapter('标题', '<p>正文</p>'),
      });
      final r = parser.parse(
        'big.epub',
        bytes,
        EncodingType.utf8,
        limits: ParseLimits(
          dangerRssBytes: 300 * 1024 * 1024,
          maxChapterBytes: 10,
          rssProbe: null,
        ),
      );

      expect(r.paragraphs, ['[EPUB 章节过大，已跳过]']);
    });

    test('章节数超过上限时中止解析', () {
      final bytes = _buildEpub(chapters: {
        'a.xhtml': _chapter('A', '<p>a</p>'),
        'b.xhtml': _chapter('B', '<p>b</p>'),
      });

      expect(
        () => parser.parse(
          'many.epub',
          bytes,
          EncodingType.utf8,
          limits: ParseLimits(
            dangerRssBytes: 300 * 1024 * 1024,
            maxChapters: 1,
            rssProbe: null,
          ),
        ),
        throwsA(isA<ParseAbortException>()),
      );
    });

    test('非 zip 数据抛 FormatException', () {
      expect(
        () => parser.parse(
          'bad.epub',
          Uint8List.fromList([1, 2, 3, 4, 5]),
          EncodingType.utf8,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
