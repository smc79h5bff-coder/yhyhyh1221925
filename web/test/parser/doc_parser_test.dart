import 'dart:typed_data';

import 'package:docdiff/features/parser/application/doc_parser.dart';
import 'package:docdiff/features/parser/application/document_parser.dart';
import 'package:docdiff/features/parser/application/parse_limits.dart';
import 'package:docdiff/features/parser/domain/document_format.dart';
import 'package:docdiff/features/preprocessing/domain/encoding_type.dart';
import 'package:flutter_test/flutter_test.dart';

const int _freeSect = 0xFFFFFFFF;
const int _endOfChain = 0xFFFFFFFE;
const int _fatSect = 0xFFFFFFFD;

const int _sectorSize = 512;
const int _wdSector = 2;
const int _tblSector = 10;
const int _streamSectors = 8;
const int _streamSize = _sectorSize * _streamSectors; // 4096，走常规 FAT
const int _textOff = 0x200;

void _put16(Uint8List b, int off, int v) {
  b[off] = v & 0xFF;
  b[off + 1] = (v >> 8) & 0xFF;
}

void _put32(Uint8List b, int off, int v) {
  b[off] = v & 0xFF;
  b[off + 1] = (v >> 8) & 0xFF;
  b[off + 2] = (v >> 16) & 0xFF;
  b[off + 3] = (v >> 24) & 0xFF;
}

Uint8List _utf16le(String s) {
  final out = <int>[];
  for (final unit in s.codeUnits) {
    out.add(unit & 0xFF);
    out.add((unit >> 8) & 0xFF);
  }
  return Uint8List.fromList(out);
}

void _writeDirEntry(
  Uint8List b,
  int off,
  String name,
  int type,
  int start,
  int size,
) {
  final nameBytes = <int>[];
  for (final unit in name.codeUnits) {
    nameBytes.add(unit & 0xFF);
    nameBytes.add((unit >> 8) & 0xFF);
  }
  nameBytes.addAll(<int>[0, 0]); // UTF-16 结尾
  for (var i = 0; i < nameBytes.length; i++) {
    b[off + i] = nameBytes[i];
  }
  _put16(b, off + 64, nameBytes.length);
  b[off + 66] = type;
  _put32(b, off + 116, start);
  _put32(b, off + 120, size);
  _put32(b, off + 124, 0);
}

/// 在内存里造一个最小但结构完整的 CFB / OLE2 .doc。
///
/// 版式：header → 1 个 FAT 扇区 → 1 个目录扇区 → 8 扇区 WordDocument
/// → 8 扇区表流。两个流都是 4096 字节（>= cutoff），因此走常规 FAT，
/// 测试不依赖 mini stream 之外的数据结构。
Uint8List _buildDoc({
  required String text,
  bool compressed = false,
  bool usePieceTable = true,
  bool noLegacy = false,
  int flags = 0,
  int fibIdent = 0xA5EC,
  int? ccpTextOverride,
  bool withWordDocument = true,
  bool withTable = true,
  String tableName = '0Table',
  Uint8List? rawTextBytes,
  List<int>? clxOverride,
}) {
  final textBytes = rawTextBytes ??
      (compressed
          ? Uint8List.fromList(text.codeUnits)
          : _utf16le(text));
  final chars = compressed ? textBytes.length : textBytes.length ~/ 2;
  final cp = ccpTextOverride ?? chars;

  const totalSectors = 18;
  final b = Uint8List(_sectorSize * (1 + totalSectors));

  // ---- CFB header ----
  const magic = <int>[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  for (var i = 0; i < 8; i++) {
    b[i] = magic[i];
  }
  _put16(b, 0x1A, 3); // major version
  _put16(b, 0x1C, 0xFFFE); // byte order
  _put16(b, 0x1E, 9); // sector shift → 512
  _put16(b, 0x20, 6); // mini sector shift → 64
  _put32(b, 0x2C, 1); // FAT 扇区数
  _put32(b, 0x30, 1); // 首个目录扇区
  _put32(b, 0x38, 4096); // mini stream cutoff
  _put32(b, 0x3C, _endOfChain); // 首个 MiniFAT 扇区
  _put32(b, 0x40, 0); // MiniFAT 扇区数
  _put32(b, 0x44, _endOfChain); // 首个 DIFAT 扇区
  _put32(b, 0x48, 0); // DIFAT 扇区数
  for (var i = 0; i < 109; i++) {
    _put32(b, 0x4C + i * 4, i == 0 ? 0 : _freeSect);
  }

  // ---- FAT（扇区 0，偏移 512）----
  const fatBase = _sectorSize;
  for (var i = 0; i < _sectorSize ~/ 4; i++) {
    _put32(b, fatBase + i * 4, _freeSect);
  }
  _put32(b, fatBase, _fatSect);
  _put32(b, fatBase + 4, _endOfChain); // 目录扇区链
  for (var i = _wdSector; i < _wdSector + _streamSectors - 1; i++) {
    _put32(b, fatBase + i * 4, i + 1);
  }
  _put32(b, fatBase + (_wdSector + _streamSectors - 1) * 4, _endOfChain);
  for (var i = _tblSector; i < _tblSector + _streamSectors - 1; i++) {
    _put32(b, fatBase + i * 4, i + 1);
  }
  _put32(b, fatBase + (_tblSector + _streamSectors - 1) * 4, _endOfChain);

  // ---- 目录（扇区 1，偏移 1024）----
  const dirBase = _sectorSize * 2;
  _writeDirEntry(b, dirBase, 'Root Entry', 5, _endOfChain, 0);
  if (withWordDocument) {
    _writeDirEntry(
      b,
      dirBase + 128,
      'WordDocument',
      2,
      _wdSector,
      _streamSize,
    );
  }
  if (withTable) {
    _writeDirEntry(
      b,
      dirBase + 256,
      tableName,
      2,
      _tblSector,
      _streamSize,
    );
  }

  // ---- WordDocument 流（扇区 2，偏移 1536）----
  final wdBase = (_wdSector + 1) * _sectorSize;
  _put16(b, wdBase + 0x00, fibIdent);
  _put16(b, wdBase + 0x06, 0x0804); // lid = 简体中文
  _put16(b, wdBase + 0x0A, flags);
  _put32(b, wdBase + 0x18, noLegacy ? 0 : _textOff); // fcMin
  _put32(
    b,
    wdBase + 0x1C,
    noLegacy ? 0 : _textOff + textBytes.length,
  ); // fcMac
  _put32(b, wdBase + 0x4C, cp); // ccpText
  _put32(b, wdBase + 0x1A2, 0); // fcClx
  final clx = clxOverride ?? _buildClx(cp, compressed);
  _put32(b, wdBase + 0x1A6, usePieceTable ? clx.length : 0); // lcbClx
  for (var i = 0; i < textBytes.length; i++) {
    b[wdBase + _textOff + i] = textBytes[i];
  }

  // ---- 表流（扇区 10，偏移 5632）----
  final tblBase = (_tblSector + 1) * _sectorSize;
  for (var i = 0; i < clx.length; i++) {
    b[tblBase + i] = clx[i];
  }

  return b;
}

/// CLX = Pcdt(0x02) + PlcPcd(n=1)。
/// 压缩片段按 [MS-DOC] 2.4.1：真实偏移 = fc/2，所以写进 fc 字段的
/// 必须是 offset*2；同时置 bit30。
List<int> _buildClx(int cp, bool compressed) {
  final fcRaw = compressed
      ? (_textOff * 2) | 0x40000000
      : _textOff;
  return <int>[
    0x02,
    16, 0, 0, 0, // lcbPlcPcd = 16
    0, 0, 0, 0, // aCp[0]
    cp & 0xFF, (cp >> 8) & 0xFF, (cp >> 16) & 0xFF, (cp >> 24) & 0xFF,
    0, 0, // PCD 前 2 字节
    fcRaw & 0xFF,
    (fcRaw >> 8) & 0xFF,
    (fcRaw >> 16) & 0xFF,
    (fcRaw >> 24) & 0xFF,
    0, 0, // prm
  ];
}

void main() {
  const parser = DocParser();

  group('DocParser: 正文抽取', () {
    test('UTF-16LE 片段按 piece table 抽出，段落标记转成行', () {
      final bytes = _buildDoc(text: '第一章 初遇\r第二章 重逢\r');
      final r = parser.parse('book.doc', bytes, EncodingType.utf8);

      expect(r.paragraphs, <String>['第一章 初遇', '第二章 重逢']);
      expect(r.format, DocumentFormat.doc);
      expect(r.encoding, EncodingType.utf8);
      expect(r.byteSize, bytes.length);
      expect(r.plainText, '第一章 初遇\n第二章 重逢');
    });

    test('压缩 ANSI 片段：按 fc/2 定位，每字符 1 字节', () {
      final bytes = _buildDoc(
        text: 'Hello world\rSecond line\r',
        compressed: true,
      );
      final r = parser.parse('ansi.doc', bytes, EncodingType.utf8);

      expect(r.paragraphs, <String>['Hello world', 'Second line']);
    });

    test('首选 1Table 不存在时回退到 0Table', () {
      final bytes = _buildDoc(
        text: '甲\r乙\r',
        flags: 0x0200, // fWhichTblStm → 首选 1Table
        tableName: '0Table', // 但文件里只有 0Table
      );
      final r = parser.parse('fallback.doc', bytes, EncodingType.utf8);

      expect(r.paragraphs, <String>['甲', '乙']);
    });

    test('lcbClx=0 时走老版单 piece 路径', () {
      final bytes = _buildDoc(text: '甲\r乙\r', usePieceTable: false);
      final r = parser.parse('legacy.doc', bytes, EncodingType.utf8);

      expect(r.paragraphs, <String>['甲', '乙']);
    });

    test('CLX 损坏且无 fcMin 时走直接提取兜底', () {
      final bytes = _buildDoc(
        text: '甲\r乙\r',
        noLegacy: true,
        clxOverride: <int>[0x02, 0, 0, 0, 0],
      );
      final r = parser.parse('direct.doc', bytes, EncodingType.utf8);

      expect(r.paragraphs, <String>['甲', '乙']);
    });

    test('Word 控制标记统一成换行，空行丢弃', () {
      final bytes = _buildDoc(text: '甲\x07乙\x0B丙\x0C丁\r\r戊\r');
      final r = parser.parse('marks.doc', bytes, EncodingType.utf8);

      expect(r.paragraphs, <String>['甲', '乙', '丙', '丁', '戊']);
    });

    test('全角空格 / 首尾空白按 EPUB 同一口径清洗', () {
      final bytes = _buildDoc(text: '　第一章　\r  第二章  \r');
      final r = parser.parse('space.doc', bytes, EncodingType.utf8);

      expect(r.paragraphs, <String>['第一章', '第二章']);
    });
  });

  group('DocParser: 异常与防御', () {
    test('非 OLE2 字节直接拒绝', () {
      expect(
        () => parser.parse(
          'bad.doc',
          Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
          EncodingType.utf8,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('RTF / docx / HTML 伪装成 .doc 时给出可照做的提示', () {
      const cases = <String, String>{
        '{\\rtf': '另存为',
        'PK': '改回 .docx',
        '<html': '另存为',
      };
      cases.forEach((prefixText, expected) {
        final prefix = prefixText.codeUnits;
        expect(
          () => parser.parse(
            'fake.doc',
            Uint8List.fromList(prefix + List<int>.filled(600, 0)),
            EncodingType.utf8,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(expected),
            ),
          ),
        );
      });
    });

    test('FIB 魔数不合法时拒绝', () {
      final bytes = _buildDoc(text: '甲\r', fibIdent: 0x1234);
      expect(
        () => parser.parse('badfib.doc', bytes, EncodingType.utf8),
        throwsA(isA<FormatException>()),
      );
    });

    test('加密位被拒绝，且提示先去密码', () {
      final bytes = _buildDoc(text: '甲\r', flags: 0x0100);
      expect(
        () => parser.parse('encrypted.doc', bytes, EncodingType.utf8),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('加密'),
          ),
        ),
      );
    });

    test('ccpText=0 拒绝；超过流容量时中止而不是乱分配', () {
      final empty = _buildDoc(text: '甲\r', ccpTextOverride: 0);
      expect(
        () => parser.parse('empty.doc', empty, EncodingType.utf8),
        throwsA(isA<FormatException>()),
      );

      final huge = _buildDoc(text: '甲\r', ccpTextOverride: 0x7FFFFFFF);
      expect(
        () => parser.parse('huge.doc', huge, EncodingType.utf8),
        throwsA(isA<ParseAbortException>()),
      );
    });

    test('缺 WordDocument 流时明确报错', () {
      final bytes = _buildDoc(text: '甲\r', withWordDocument: false);
      expect(
        () => parser.parse('nostream.doc', bytes, EncodingType.utf8),
        throwsA(isA<FormatException>()),
      );
    });

    test('可读性不达标时拒绝，绝不把乱码送进对比', () {
      final garbage = Uint8List.fromList(List<int>.filled(64, 0x03));
      final bytes = _buildDoc(text: '', rawTextBytes: garbage, noLegacy: true);
      expect(
        () => parser.parse('garbage.doc', bytes, EncodingType.utf8),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('解码不可靠'),
          ),
        ),
      );
    });
  });

  group('DocumentParser .doc 接线', () {
    test('真的把 .doc 分派给 DocParser（防"写完不接线"）', () async {
      final bytes = _buildDoc(text: '接线成功\r第二行\r');
      final r = await DocumentParser.parse(
        fileName: 'book.doc',
        bytes: bytes,
      );

      expect(r.format, DocumentFormat.doc);
      expect(r.paragraphs, <String>['接线成功', '第二行']);
    });

    test('大写 .DOC 后缀同样分派', () async {
      final bytes = _buildDoc(text: '大写后缀\r');
      final r = await DocumentParser.parse(
        fileName: 'BOOK.DOC',
        bytes: bytes,
      );

      expect(r.format, DocumentFormat.doc);
      expect(r.paragraphs, <String>['大写后缀']);
    });

    test('其它二进制格式仍被明确拒绝，不受 .doc 接线影响', () async {
      // DocumentParser.parse 是 async，异常走 Future.error，
      // 必须用 expectLater 而不是同步 throwsA。
      await expectLater(
        DocumentParser.parse(
          fileName: 'x.rtf',
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
