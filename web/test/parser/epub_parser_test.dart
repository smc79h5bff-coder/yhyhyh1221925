import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:docdiff/features/parser/application/document_parser.dart';
import 'package:docdiff/features/parser/application/epub_parser.dart';
import 'package:docdiff/features/parser/domain/document_format.dart';
import 'package:docdiff/features/preprocessing/domain/encoding_type.dart';
import 'package:flutter_test/flutter_test.dart';

const _containerNs = 'urn:oasis:names:tc:opendocument:xmlns:container';
const _opfNs = 'http://www.idpf.org/2007/opf';

/// Build a minimal in-memory .epub (zip with container.xml + .opf + chapters).
Uint8List _buildEpub({
  String opfPath = 'OEBPS/content.opf',
  String? containerXml,
  required String opfXml,
  Map<String, String> chapters = const <String, String>{},
}) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('META-INF/container.xml', containerXml ?? '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="$_containerNs">
  <rootfiles>
    <rootfile full-path="$opfPath" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''');
  add(opfPath, opfXml);
  chapters.forEach(add);

  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded ?? const <int>[]);
}

/// OPF with default namespace (as real EPUBs have) + explicit spine order.
String _opf({
  required String manifest,
  required String spine,
  bool withNamespace = true,
}) => '''
<?xml version="1.0" encoding="UTF-8"?>
<package ${withNamespace ? 'xmlns="$_opfNs"' : ''} version="3.0" unique-identifier="uid">
  <metadata><title>A book</title></metadata>
  <manifest>
$manifest
  </manifest>
  <spine>
$spine
  </spine>
</package>''';

String _chapter(String body) => '''
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>章节标题</title><style>.a{color:red}</style><script>var x=1;</script></head>
<body>
$body
</body>
</html>''';

const _item = 'media-type="application/xhtml+xml"';

void main() {
  const parser = EpubParser();

  group('EpubParser', () {
    test('follows spine order, NOT filename order', () {
      final bytes = _buildEpub(
        opfXml: _opf(
          manifest: '''
    <item id="c10" href="Text/chapter10.xhtml" $_item/>
    <item id="c2" href="Text/chapter2.xhtml" $_item/>''',
          spine: '''
    <itemref idref="c2"/>
    <itemref idref="c10"/>''',
        ),
        chapters: {
          'OEBPS/Text/chapter10.xhtml': _chapter('<p>第十章</p>'),
          'OEBPS/Text/chapter2.xhtml': _chapter('<p>第二章</p>'),
        },
      );

      final r = parser.parse('book.epub', bytes, EncodingType.utf8);

      // Filenames would sort chapter10 before chapter2; spine says otherwise.
      expect(r.paragraphs, ['第二章', '第十章']);
      expect(r.plainText, '第二章\n第十章');
    });

    test('parses OPF without any namespace', () {
      final bytes = _buildEpub(
        opfXml: _opf(
          withNamespace: false,
          manifest: '<item id="c1" href="Text/a.xhtml" $_item/>',
          spine: '<itemref idref="c1"/>',
        ),
        chapters: {
          'OEBPS/Text/a.xhtml': _chapter('<p>无命名空间</p>'),
        },
      );

      final r = parser.parse('ns.epub', bytes, EncodingType.utf8);
      expect(r.paragraphs, ['无命名空间']);
    });

    test('strips head / script / style and HTML tags', () {
      final bytes = _buildEpub(
        opfXml: _opf(
          manifest: '<item id="c1" href="Text/a.xhtml" $_item/>',
          spine: '<itemref idref="c1"/>',
        ),
        chapters: {
          'OEBPS/Text/a.xhtml': _chapter(
            '<p>甲<em>乙</em>丙</p><div>丁</div>',
          ),
        },
      );

      final r = parser.parse('tags.epub', bytes, EncodingType.utf8);
      // head 里的「章节标题」/ 样式 / 脚本都不该进正文。
      expect(r.paragraphs, ['甲乙丙', '丁']);
    });

    test('block tags become line breaks; blank lines are dropped', () {
      final bytes = _buildEpub(
        opfXml: _opf(
          manifest: '<item id="c1" href="Text/a.xhtml" $_item/>',
          spine: '<itemref idref="c1"/>',
        ),
        chapters: {
          'OEBPS/Text/a.xhtml': _chapter(
            '<p>第一段</p><p></p><div>第二段<br/>续行</div>',
          ),
        },
      );

      final r = parser.parse('blocks.epub', bytes, EncodingType.utf8);
      expect(r.paragraphs, ['第一段', '第二段', '续行']);
    });

    test('decodes named, decimal and hexadecimal HTML entities', () {
      final bytes = _buildEpub(
        opfXml: _opf(
          manifest: '<item id="c1" href="Text/a.xhtml" $_item/>',
          spine: '<itemref idref="c1"/>',
        ),
        chapters: {
          'OEBPS/Text/a.xhtml': _chapter(
            '<p>A&nbsp;B&amp;C&#x4E2D;&#25991;&lt;x&gt;</p>',
          ),
        },
      );

      final r = parser.parse('entities.epub', bytes, EncodingType.utf8);
      expect(r.paragraphs, ['A B&C中文<x>']);
    });

    test('resolves ../ relative hrefs against the .opf directory', () {
      final bytes = _buildEpub(
        opfPath: 'OEBPS/Meta/book.opf',
        opfXml: _opf(
          manifest: '<item id="c1" href="../Text/a.xhtml" $_item/>',
          spine: '<itemref idref="c1"/>',
        ),
        chapters: {
          'OEBPS/Text/a.xhtml': _chapter('<p>相对路径</p>'),
        },
      );

      final r = parser.parse('rel.epub', bytes, EncodingType.utf8);
      expect(r.paragraphs, ['相对路径']);
    });

    test('skips linear="no" items and non-text media types', () {
      final bytes = _buildEpub(
        opfXml: _opf(
          manifest: '''
    <item id="cover" href="Images/c.jpg" media-type="image/jpeg"/>
    <item id="css" href="Styles/s.css" media-type="text/css"/>
    <item id="nav" href="Text/nav.xhtml" $_item/>
    <item id="c1" href="Text/a.xhtml" $_item/>''',
          spine: '''
    <itemref idref="nav" linear="no"/>
    <itemref idref="cover"/>
    <itemref idref="css"/>
    <itemref idref="c1"/>''',
        ),
        chapters: {
          'OEBPS/Text/nav.xhtml': _chapter('<p>目录不该出现</p>'),
          'OEBPS/Text/a.xhtml': _chapter('<p>正文</p>'),
        },
      );

      final r = parser.parse('skip.epub', bytes, EncodingType.utf8);
      expect(r.paragraphs, ['正文']);
    });

    test('marks missing chapter files instead of dropping them silently', () {
      final bytes = _buildEpub(
        opfXml: _opf(
          manifest: '''
    <item id="missing" href="Text/gone.xhtml" $_item/>
    <item id="c1" href="Text/a.xhtml" $_item/>''',
          spine: '''
    <itemref idref="missing"/>
    <itemref idref="c1"/>''',
        ),
        chapters: {
          'OEBPS/Text/a.xhtml': _chapter('<p>还在</p>'),
        },
      );

      final r = parser.parse('missing.epub', bytes, EncodingType.utf8);
      // 缺章不能静默消失，否则会被误判成"整章删除"。
      expect(r.paragraphs, ['[EPUB 章节缺失]', '还在']);
    });

    test('falls back to a bare .opf when container.xml is absent', () {
      final archive = Archive();
      final opfBytes = utf8.encode(_opf(
        manifest: '<item id="c1" href="a.xhtml" $_item/>',
        spine: '<itemref idref="c1"/>',
      ));
      archive.addFile(
          ArchiveFile('EPUB/package.opf', opfBytes.length, opfBytes));
      final chapter = utf8.encode(_chapter('<p>兜底定位</p>'));
      archive.addFile(
          ArchiveFile('EPUB/a.xhtml', chapter.length, chapter));
      final bytes = Uint8List.fromList(
          ZipEncoder().encode(archive) ?? const <int>[]);

      final r = parser.parse('nocontainer.epub', bytes, EncodingType.utf8);
      expect(r.paragraphs, ['兜底定位']);
    });

    test('falls back to all html files when spine is empty', () {
      final bytes = _buildEpub(
        opfXml: _opf(manifest: '', spine: ''),
        chapters: {
          'OEBPS/a.xhtml': _chapter('<p>甲</p>'),
          'OEBPS/b.xhtml': _chapter('<p>乙</p>'),
        },
      );

      final r = parser.parse('nospine.epub', bytes, EncodingType.utf8);
      expect(r.paragraphs, ['甲', '乙']);
    });

    test('metadata: format, encoding and byteSize', () {
      final bytes = _buildEpub(
        opfXml: _opf(
          manifest: '<item id="c1" href="a.xhtml" $_item/>',
          spine: '<itemref idref="c1"/>',
        ),
        chapters: {'OEBPS/a.xhtml': _chapter('<p>x</p>')},
      );

      final r = parser.parse('meta.epub', bytes, EncodingType.gbk);
      expect(r.format, DocumentFormat.epub);
      // EPUB 内部强制 UTF-8，忽略外部传入的 GBK。
      expect(r.encoding, EncodingType.utf8);
      expect(r.byteSize, bytes.length);
    });

    test('throws FormatException on non-zip bytes', () {
      expect(
        () => parser.parse(
            'bad.epub', Uint8List.fromList([1, 2, 3, 4, 5]), EncodingType.utf8),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when no readable text exists', () {
      final bytes = _buildEpub(
        opfXml: _opf(manifest: '', spine: ''),
      );
      expect(
        () => parser.parse('empty.epub', bytes, EncodingType.utf8),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('DocumentParser .epub dispatch', () {
    test('actually routes .epub to EpubParser (wiring regression guard)', () async {
      final bytes = _buildEpub(
        opfXml: _opf(
          manifest: '<item id="c1" href="a.xhtml" $_item/>',
          spine: '<itemref idref="c1"/>',
        ),
        chapters: {'OEBPS/a.xhtml': _chapter('<p>接线成功</p>')},
      );

      final r = await DocumentParser.parse(fileName: 'book.epub', bytes: bytes);
      expect(r.format, DocumentFormat.epub);
      expect(r.paragraphs, ['接线成功']);
    });

    test('uppercase .EPUB extension is dispatched too', () async {
      final bytes = _buildEpub(
        opfXml: _opf(
          manifest: '<item id="c1" href="a.xhtml" $_item/>',
          spine: '<itemref idref="c1"/>',
        ),
        chapters: {'OEBPS/a.xhtml': _chapter('<p>大写后缀</p>')},
      );

      final r = await DocumentParser.parse(fileName: 'BOOK.EPUB', bytes: bytes);
      expect(r.format, DocumentFormat.epub);
      expect(r.paragraphs, ['大写后缀']);
    });
  });
}
