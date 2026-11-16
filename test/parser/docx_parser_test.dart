import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:docdiff/features/parser/application/docx_parser.dart';
import 'package:docdiff/features/parser/application/parse_limits.dart';
import 'package:docdiff/features/parser/domain/document_format.dart';
import 'package:docdiff/features/preprocessing/domain/encoding_type.dart';
import 'package:flutter_test/flutter_test.dart';

const _wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

/// 构造一个最小的内存 .docx（zip + word/document.xml）。
Uint8List _buildDocx(String bodyXml) {
  final xml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="$_wNs">
  <w:body>
$bodyXml
  </w:body>
</w:document>''';
  final archive = Archive()
    ..addFile(ArchiveFile(
      'word/document.xml',
      utf8.encode(xml).length,
      utf8.encode(xml),
    ));
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded ?? const <int>[]);
}

void main() {
  group('DocxParser', () {
    const parser = DocxParser();

    test('按文档顺序输出段落，空段落跳过', () {
      final bytes = _buildDocx('''
<w:p><w:r><w:t>Hello</w:t></w:r></w:p>
<w:p/>
<w:p><w:r><w:t>World</w:t></w:r></w:p>
''');
      final r = parser.parse('test.docx', bytes, EncodingType.utf8);

      expect(r.format, DocumentFormat.docx);
      expect(r.paragraphs, ['Hello', 'World']);
      expect(r.plainText, 'Hello\nWorld');
    });

    test('同一段多个 run 合并，tab / br 正确转换', () {
      final bytes = _buildDocx('''
<w:p><w:r><w:t>Hel</w:t></w:r><w:r><w:t>lo</w:t></w:r></w:p>
<w:p><w:r><w:t>a</w:t><w:tab/><w:t>b</w:t><w:br/><w:t>c</w:t></w:r></w:p>
''');
      final r = parser.parse('runs.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['Hello', 'a\tb\nc']);
    });

    test('普通表格：单元格用 tab、行用换行', () {
      final bytes = _buildDocx('''
<w:tbl>
  <w:tr>
    <w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc>
  </w:tr>
  <w:tr>
    <w:tc><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>d</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>
''');
      final r = parser.parse('tbl.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['a\tb\nc\td']);
    });

    test('嵌套表格不被外层重复收集', () {
      final bytes = _buildDocx('''
<w:tbl>
  <w:tr>
    <w:tc>
      <w:tbl>
        <w:tr>
          <w:tc><w:p><w:r><w:t>n1</w:t></w:r></w:p></w:tc>
          <w:tc><w:p><w:r><w:t>n2</w:t></w:r></w:p></w:tc>
        </w:tr>
      </w:tbl>
    </w:tc>
    <w:tc><w:p><w:r><w:t>outer</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>
''');
      final r = parser.parse('nested.docx', bytes, EncodingType.utf8);

      // 旧实现会递归收集内层 tr/tc，输出 n1\tn2\touter\tn1\tn2\nn1\tn2。
      expect(r.paragraphs, ['n1\tn2\touter']);
    });

    test('customXml / smartTag 包裹的段落不丢失', () {
      final bytes = _buildDocx('''
<w:customXml>
  <w:p><w:r><w:t>custom</w:t></w:r></w:p>
</w:customXml>
<w:smartTag>
  <w:p><w:r><w:t>smart</w:t></w:r></w:p>
</w:smartTag>
<w:p><w:r><w:t>plain</w:t></w:r></w:p>
''');
      final r = parser.parse('wrap.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['custom', 'smart', 'plain']);
    });

    test('内容控件 sdt 递归到 sdtContent', () {
      final bytes = _buildDocx('''
<w:sdt>
  <w:sdtContent>
    <w:p><w:r><w:t>sdt paragraph</w:t></w:r></w:p>
  </w:sdtContent>
</w:sdt>
<w:p><w:r><w:t>plain</w:t></w:r></w:p>
''');
      final r = parser.parse('sdt.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['sdt paragraph', 'plain']);
    });

    test('修订插入内容保留', () {
      final bytes = _buildDocx('''
<w:p>
  <w:r><w:t>before</w:t></w:r>
  <w:ins><w:r><w:t>inserted</w:t></w:r></w:ins>
  <w:del><w:r><w:delText>deleted</w:delText></w:r></w:del>
</w:p>
''');
      final r = parser.parse('rev.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['beforeinserted']);
    });

    test('保留不间断连字符，标记符号，忽略软连字符', () {
      final bytes = _buildDocx('''
<w:p><w:r>
  <w:t>a</w:t><w:noBreakHyphen/><w:t>b</w:t>
  <w:softHyphen/>
  <w:sym w:font="Wingdings" w:char="F0FC"/>
  <w:t>c</w:t>
</w:r></w:p>
''');
      final r = parser.parse('symbols.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['a\u2011b[符号]c']);
    });

    test('忽略 moveFrom（旧位置），保留 moveTo', () {
      final bytes = _buildDocx('''
<w:p>
  <w:r><w:t>before</w:t></w:r>
  <w:moveFrom><w:r><w:t>old</w:t></w:r></w:moveFrom>
  <w:moveTo><w:r><w:t>new</w:t></w:r></w:moveTo>
</w:p>
''');
      final r = parser.parse('move.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['beforenew']);
    });

    test('AlternateContent 只读 Choice 分支', () {
      final bytes = _buildDocx('''
<w:p>
  <w:r>
    <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">
      <mc:Choice Requires="wps"><w:t>choice</w:t></mc:Choice>
      <mc:Fallback><w:t>fallback</w:t></mc:Fallback>
    </mc:AlternateContent>
  </w:r>
</w:p>
''');
      final r = parser.parse('alt.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['choice']);
    });

    test('展开 sdt 包裹的表格行和单元格', () {
      final bytes = _buildDocx('''
<w:tbl>
  <w:tr><w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc></w:tr>
  <w:sdt><w:sdtContent>
    <w:tr>
      <w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc>
      <w:sdt><w:sdtContent>
        <w:tc><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc>
      </w:sdtContent></w:sdt>
    </w:tr>
  </w:sdtContent></w:sdt>
</w:tbl>
''');
      final r = parser.parse('sdt-table.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['a\nb\tc']);
    });

    test('嵌套 sdt 只提取一次', () {
      final bytes = _buildDocx('''
<w:sdt><w:sdtContent>
  <w:p><w:r><w:t>outer</w:t></w:r></w:p>
  <w:sdt><w:sdtContent>
    <w:p><w:r><w:t>inner</w:t></w:r></w:p>
  </w:sdtContent></w:sdt>
</w:sdtContent></w:sdt>
''');
      final r = parser.parse('nested-sdt.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['outer', 'inner']);
    });

    test('非 zip / 过短数据抛 FormatException', () {
      expect(
        () => parser.parse(
          'bad.docx',
          Uint8List.fromList([1, 2, 3, 4, 5]),
          EncodingType.utf8,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('document.xml 带 UTF-8 BOM 时仍能解析', () {
      final xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="$_wNs"><w:body>
<w:p><w:r><w:t>Hello</w:t></w:r></w:p>
</w:body></w:document>''';
      final documentBytes = <int>[
        0xEF, 0xBB, 0xBF, // UTF-8 BOM
        ...utf8.encode(xml),
      ];
      final archive = Archive()
        ..addFile(ArchiveFile(
          'word/document.xml',
          documentBytes.length,
          documentBytes,
        ));
      final bytes =
          Uint8List.fromList(ZipEncoder().encode(archive) ?? const []);
      final r = parser.parse('bom.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['Hello']);
    });

    test('段落数超过上限时中止解析', () {
      final bytes = _buildDocx(
        '<w:p><w:r><w:t>1</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>2</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>3</w:t></w:r></w:p>',
      );

      expect(
        () => parser.parse(
          'big.docx',
          bytes,
          EncodingType.utf8,
          limits: ParseLimits(
            dangerRssBytes: 300 * 1024 * 1024,
            maxParagraphs: 2,
            rssProbe: null,
          ),
        ),
        throwsA(isA<ParseAbortException>()),
      );
    });

    test('缺少 word/document.xml 抛 FormatException', () {
      final archive = Archive()
        ..addFile(ArchiveFile('foo/bar.xml', 1, [0x78]));
      final bytes =
          Uint8List.fromList(ZipEncoder().encode(archive) ?? const []);
      expect(
        () => parser.parse('noxml.docx', bytes, EncodingType.utf8),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
