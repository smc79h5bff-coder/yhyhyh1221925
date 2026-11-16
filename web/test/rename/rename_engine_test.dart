import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:docdiff/features/rename/content_extractor.dart';
import 'package:docdiff/features/rename/preset_store.dart';
import 'package:docdiff/features/rename/rename_models.dart';
import 'package:docdiff/features/rename/rename_template.dart';
import 'package:docdiff/features/preprocessing/domain/encoding_type.dart';
import 'package:flutter_test/flutter_test.dart';

ContentDecoder _utf8Decoder() =>
    (Uint8List bytes, String hint) async =>
        DecodedChunk(utf8.decode(bytes, allowMalformed: true), 'utf8');

RenamePreset _presetWith(String template) {
  final p = RenamePreset.starter();
  p.template = template;
  return p;
}

TemplateResult _render(
  String template,
  Map<String, String> vars, {
  RenamePreset? preset,
  Set<String> contentNames = const <String>{'作者', '主角'},
}) {
  final p = preset ?? _presetWith(template);
  return RenameTemplateEngine.render(
    template: template,
    variables: vars,
    preset: p,
    contentVariableNames: contentNames,
  );
}

void main() {
  group('模板渲染', () {
    test('普通变量与内置变量', () {
      final r = _render('{原名}[ - {作者}]', <String, String>{
        '原名': '三体',
        '作者': '刘慈欣',
      });
      expect(r.baseName, '三体 - 刘慈欣');
      expect(r.missing, isEmpty);
      expect(r.usedContentVariable, isTrue);
    });

    test('可选片段：有值 / 部分缺失 / 全缺失', () {
      const t = '{原名}[ - {作者}][（{主角}）]';
      expect(
          _render(t, <String, String>{
            '原名': '三体',
            '作者': '刘慈欣',
            '主角': '汪淼',
          }).baseName,
          '三体 - 刘慈欣（汪淼）');
      expect(
          _render(t, <String, String>{
            '原名': '三体',
            '作者': '刘慈欣',
          }).baseName,
          '三体 - 刘慈欣');
      expect(
          _render(t, <String, String>{'原名': '三体'}).baseName,
          '三体');
    });

    test('缺失变量被记录，且可选片段不会留下空分隔符', () {
      final r = _render('{原名}[ - {作者}]', <String, String>{'原名': '三体'});
      expect(r.baseName, '三体');
      expect(r.missing, contains('作者'));
    });

    test('默认值语法 {变量|默认值}', () {
      final r = _render('{原名}[ - {作者|佚名}]',
          <String, String>{'原名': '三体'});
      expect(r.baseName, '三体 - 佚名');
      expect(r.missing, isEmpty);
    });

    test('方括号转义输出字面括号', () {
      final r = _render(r'{原名}\[{作者}\]', <String, String>{
        '原名': '三体',
        '作者': '刘慈欣',
      });
      expect(r.baseName, '三体[刘慈欣]');
    });

    test('嵌套可选片段', () {
      final r = _render('{原名}[ - [{作者}·]{主角}]', <String, String>{
        '原名': '三体',
        '作者': '刘慈欣',
      });
      expect(r.baseName, '三体');
    });

    test('非法字符被删除或替换，结尾点被去掉', () {
      final del = _render('{原名}', <String, String>{'原名': 'a/b:c?.txt'});
      expect(del.baseName, 'abc.txt');

      final rep = _presetWith('{原名}');
      rep.illegalCharMode = 'replace';
      rep.illegalReplacement = '-';
      final r = RenameTemplateEngine.render(
        template: '{原名}',
        variables: <String, String>{'原名': 'a/b:c'},
        preset: rep,
        contentVariableNames: const <String>{},
      );
      expect(r.baseName, 'a-b-c');
    });

    test('长度截断与空格转下划线', () {
      final p = _presetWith('{原名}');
      p.maxNameLength = 3;
      p.spaceToUnderscore = true;
      final r = RenameTemplateEngine.render(
        template: '{原名}',
        variables: <String, String>{'原名': 'a b c d e'},
        preset: p,
        contentVariableNames: const <String>{},
      );
      expect(r.baseName, 'a_b');
    });
  });

  group('清洗', () {
    test('黑名单命中当作没找到', () {
      expect(
          ContentExtractor.cleanValue('本站整理', CleanConfig()), isEmpty);
      expect(ContentExtractor.cleanValue('刘慈欣', CleanConfig()), '刘慈欣');
    });

    test('去尾部「著」/ 合并空白 / 截断', () {
      final c = CleanConfig();
      expect(ContentExtractor.cleanValue(' 刘慈欣 著 ', c), '刘慈欣');
      expect(ContentExtractor.cleanValue('刘  慈欣', c), '刘 慈欣');
      c.maxLength = 2;
      expect(ContentExtractor.cleanValue('刘慈欣', c), '刘慈');
    });
  });

  group('从文本提取字段', () {
    const text = '《三体》\n'
        '作者：刘慈欣\n'
        '主角：汪淼\n'
        '出版社：重庆出版社\n'
        '【人物表】\n'
        '汪淼、史强\n'
        '【正文】\n'
        '内容简介……';

    test('正则 + 捕获组', () {
      final f = ContentField(
        name: '作者',
        locator: FieldLocator.regex,
        pattern: r'作\s*者\s*[：:]\s*(.+)',
        captureGroup: 1,
      );
      final r = ContentExtractor.extractFromText(
          text, <ContentField>[f], CleanConfig());
      expect(r['作者'], '刘慈欣');
    });

    test('关键词行', () {
      final f = ContentField(
        name: '主角',
        locator: FieldLocator.keywordLine,
        pattern: '主角',
      );
      final r = ContentExtractor.extractFromText(
          text, <ContentField>[f], CleanConfig());
      expect(r['主角'], '汪淼');
    });

    test('固定行号', () {
      final f = ContentField(
        name: '第一行',
        locator: FieldLocator.lineNumber,
        pattern: '1',
      );
      final r = ContentExtractor.extractFromText(
          text, <ContentField>[f], CleanConfig());
      expect(r['第一行'], '《三体》');
    });

    test('起止标记之间', () {
      final f = ContentField(
        name: '人物',
        locator: FieldLocator.between,
        pattern: '【人物表】',
        endPattern: '【正文】',
      );
      final r = ContentExtractor.extractFromText(
          text, <ContentField>[f], CleanConfig());
      expect(r['人物'], '汪淼、史强');
    });

    test('书名号内容', () {
      final f = ContentField(
        name: '书名',
        locator: FieldLocator.bookTitleMark,
      );
      final r = ContentExtractor.extractFromText(
          text, <ContentField>[f], CleanConfig());
      expect(r['书名'], '三体');
    });

    test('同名多条规则按顺序兜底', () {
      final fields = <ContentField>[
        ContentField(
          name: '作者',
          locator: FieldLocator.keywordLine,
          pattern: '不存在的标签',
        ),
        ContentField(
          name: '作者',
          locator: FieldLocator.regex,
          pattern: r'作者[：:](.+)',
          captureGroup: 1,
        ),
      ];
      final r = ContentExtractor.extractFromText(
          text, fields, CleanConfig());
      expect(r['作者'], '刘慈欣');
    });

    test('非法正则不会抛异常', () {
      final f = ContentField(
        name: '作者',
        locator: FieldLocator.regex,
        pattern: '([',
      );
      final r = ContentExtractor.extractFromText(
          text, <ContentField>[f], CleanConfig());
      expect(r.containsKey('作者'), isFalse);
    });

    test('规则留空不会提取，内置变量名不会被覆盖', () {
      final fields = <ContentField>[
        ContentField(name: '主角'),
        ContentField(
          name: '原名',
          locator: FieldLocator.lineNumber,
          pattern: '1',
        ),
      ];
      final r = ContentExtractor.extractFromText(
          text, fields, CleanConfig());
      expect(r.containsKey('主角'), isFalse);
      expect(r.containsKey('原名'), isFalse);
    });
  });

  group('读文件（只取片段）', () {
    test('开头扫描能抓到作者，且不会把整本读进来', () async {
      final dir = Directory.systemTemp.createTempSync('rename_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}${Platform.pathSeparator}book.txt');
      f.writeAsStringSync(
          '作者：刘慈欣\n${List<String>.filled(20000, '正文').join()}');

      final p = RenamePreset.starter();
      p.scan.headBytes = 1024;
      final extractor = ContentExtractor(_utf8Decoder());

      final outcome = await extractor.extract(f.path, p);
      expect(outcome.error, isNull);
      expect(outcome.skipped, isFalse);
      expect(outcome.variables['作者'], '刘慈欣');
      // 只读了 1 KB，行数远小于整本。
      expect(outcome.lineCount, lessThan(100));
    });

    test('扩展名不匹配时主动跳过', () async {
      final dir = Directory.systemTemp.createTempSync('rename_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}${Platform.pathSeparator}book.epub');
      f.writeAsStringSync('作者：刘慈欣');

      final outcome =
          await ContentExtractor(_utf8Decoder()).extract(f.path, RenamePreset.starter());
      expect(outcome.skipped, isTrue);
      expect(outcome.variables, isEmpty);
    });
  });

  group('方案 JSON 往返', () {
    test('单套方案字段不丢', () {
      final p = RenamePreset.starter();
      p.template = '{作者} - {原名}[（{主角}）]';
      p.clean.maxLength = 9;
      p.scan.scope = 'both';
      p.scan.extensions = <String>['.txt', '.md'];
      p.fields.add(ContentField(
        name: '主角',
        locator: FieldLocator.regex,
        pattern: r'主角[：:](.+)',
      ));
      final restored = RenamePreset.decode(p.encode());
      expect(restored, isNotNull);
      expect(restored!.template, p.template);
      expect(restored.clean.maxLength, 9);
      expect(restored.scan.scope, 'both');
      expect(restored.scan.extensions, <String>['.txt', '.md']);
      expect(restored.fields.last.name, '主角');
    });

    test('损坏的输入返回 null，不抛异常', () {
      expect(RenamePreset.decode('{not json'), isNull);
      expect(RenamePresetStore.parseImport('oops'), isNull);
    });

    test('导出文本可再导入', () {
      final list = <RenamePreset>[RenamePreset.starter()];
      final text = RenamePresetStore.exportToText(list);
      final parsed = RenamePresetStore.parseImport(text);
      expect(parsed, isNotNull);
      expect(parsed!.length, 1);
      expect(parsed.first.name, '小说');
    });
  });

  group('自动序号与模板边界', () {
    test('序号插在扩展名前', () {
      expect(RenameTemplateEngine.withSeqSuffix('三体 - 刘慈欣.txt', 2),
          '三体 - 刘慈欣_2.txt');
      expect(RenameTemplateEngine.withSeqSuffix('无扩展名', 3), '无扩展名_3');
      expect(RenameTemplateEngine.withSeqSuffix('.hidden', 2), '.hidden_2');
      expect(RenameTemplateEngine.withSeqSuffix('a.', 2), 'a._2');
    });

    test('可选片段丢掉的变量仍算缺失，预览才能标黄', () {
      final r = _render('{原名}[ - {作者}]', <String, String>{'原名': '三体'});
      expect(r.baseName, '三体');
      expect(r.missing, contains('作者'));
    });

    test('有默认值语法不算缺失', () {
      final r = _render('{原名}[ - {作者|佚名}]',
          <String, String>{'原名': '三体'});
      expect(r.baseName, '三体 - 佚名');
      expect(r.missing, isEmpty);
    });

    test('全空的模板不会产生可用名字', () {
      expect(_render('[{作者}]', <String, String>{}).baseName, isEmpty);
    });
  });

  group('批量并发扫描', () {
    List<String> makeFiles(Directory dir, int n) {
      final paths = <String>[];
      for (var i = 0; i < n; i++) {
        final f = File('${dir.path}${Platform.pathSeparator}book$i.txt');
        f.writeAsStringSync('作者：作者$i\n');
        paths.add(f.path);
      }
      return paths;
    }

    test('结果按路径返回，进度回调到 100%', () async {
      final dir = Directory.systemTemp.createTempSync('rename_many');
      addTearDown(() => dir.deleteSync(recursive: true));
      final paths = makeFiles(dir, 6);
      final p = RenamePreset.starter();
      p.scan.concurrency = 3;
      final done = <int>[];
      final out = await ContentExtractor(_utf8Decoder()).extractMany(
        paths,
        p,
        onProgress: (d, t) => done.add(d),
      );
      expect(out.length, 6);
      for (var i = 0; i < 6; i++) {
        expect(out[paths[i]]!.variables['作者'], '作者$i');
      }
      expect(done.length, 6);
      expect(done.last, 6);
    });

    test('取消后只返回部分结果，不抛异常', () async {
      final dir = Directory.systemTemp.createTempSync('rename_cancel');
      addTearDown(() => dir.deleteSync(recursive: true));
      final paths = makeFiles(dir, 6);
      var calls = 0;
      final out = await ContentExtractor(_utf8Decoder()).extractMany(
        paths,
        RenamePreset.starter(),
        concurrency: 1,
        isCancelled: () => ++calls > 2,
      );
      expect(out.length, lessThan(6));
    });

    test('单个文件读失败不影响其它文件', () async {
      final dir = Directory.systemTemp.createTempSync('rename_err');
      addTearDown(() => dir.deleteSync(recursive: true));
      final paths = makeFiles(dir, 2);
      paths.insert(1, '${dir.path}${Platform.pathSeparator}missing.txt');
      final out = await ContentExtractor(_utf8Decoder()).extractMany(
        paths,
        RenamePreset.starter(),
        concurrency: 2,
      );
      expect(out.length, 3);
      expect(out[paths[1]]!.error, isNotNull);
      expect(out[paths[0]]!.variables['作者'], '作者0');
    });
  });

  group('扫描配置边界', () {
    test('并发数超出范围会被夹到 1~8', () {
      final p = RenamePreset.starter();
      p.scan.concurrency = 99;
      expect(RenamePreset.decode(p.encode())!.scan.concurrency, 8);
      final q = RenamePreset.starter();
      q.scan.concurrency = 0;
      expect(RenamePreset.decode(q.encode())!.scan.concurrency, 1);
    });

    test('编码下拉里的固定编码都是合法 EncodingType 名字', () {
      const values = <String>[
        'utf8', 'utf8bom', 'utf16le', 'utf16be', 'gbk', 'gb18030', 'big5',
      ];
      for (final v in values) {
        expect(EncodingType.values.byName(v), isA<EncodingType>());
      }
    });

    test('文本长度硬上限存在且合理', () {
      expect(ContentExtractor.maxScanChars, greaterThan(64 * 1024));
      expect(ContentExtractor.maxScanChars, lessThan(2 * 1024 * 1024));
    });
  });

  group('扫描范围与兜底（回归）', () {
    /// 造一个「作者写在开头、主角写在结尾」的文件，长度必须超过
    /// headBytes，否则不会触发尾部读取。
    File makeBook() {
      final dir = Directory.systemTemp.createTempSync('rename_scope');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}${Platform.pathSeparator}book.txt');
      final headPad = '头部填充' * 200;
      final tailPad = '尾部填充' * 200;
      f.writeAsStringSync(
          '作者：刘慈欣\n$headPad\n$tailPad\n主角：汪淼\n');
      return f;
    }

    RenamePreset presetWithProtagonist() {
      final p = RenamePreset.starter();
      p.scan.headBytes = 1024;
      p.scan.tailBytes = 1024;
      p.fields.add(ContentField(
        name: '主角',
        locator: FieldLocator.keywordLine,
        pattern: '主角',
      ));
      return p;
    }

    test('「开头+结尾」+ 只前 N 行：结尾仍能被扫到', () async {
      final f = makeBook();
      final p = presetWithProtagonist();
      p.scan.scope = 'both';
      p.scan.headLines = 2; // 只取头部前两行，不该把刚读进来的结尾丢掉
      final out =
          await ContentExtractor(_utf8Decoder()).extract(f.path, p);
      expect(out.variables['主角'], '汪淼');
    });

    test('只扫结尾时，结尾字段能抓到', () async {
      final f = makeBook();
      final p = presetWithProtagonist();
      p.scan.scope = 'tail';
      p.scan.headLines = 2;
      final out =
          await ContentExtractor(_utf8Decoder()).extract(f.path, p);
      expect(out.variables['主角'], '汪淼');
    });

    test('空基础名不会拼出隐藏文件名', () {
      expect(RenameTemplateEngine.withExtension('', 'txt'), isEmpty);
      expect(RenameTemplateEngine.withExtension('三体', ''), '三体');
      expect(RenameTemplateEngine.withExtension('三体', 'txt'), '三体.txt');
    });

    test('fallback 三种取值在 JSON 往返后不丢', () {
      for (final v in const <String>['skip', 'defaultValue', 'keep']) {
        final p = RenamePreset.starter();
        p.fallback = v;
        expect(RenamePreset.decode(p.encode())!.fallback, v);
      }
    });

    test('非法 fallback 会回落到 skip', () {
      final p = RenamePreset.fromJson(<String, dynamic>{'fallback': 'oops'});
      expect(p.fallback, 'skip');
    });
  });
}
