import 'dart:convert';

/// 从文件内容提取字段、按模板拼文件名的整套数据模型。
///
/// 三层概念：
///   1. [ContentField] 变量：从正文里「挖什么、怎么挖」；
///   2. [CleanConfig] / [ScanConfig]：挖哪一段、挖出来怎么洗；
///   3. [RenamePreset] 方案：以上全部 + 命名模板 + 兜底与格式策略。
///
/// 所有 fromJson 都对缺字段 / 类型不对做兜底，旧配置或手改 JSON 不会让弹窗崩。

/// 内置变量：不需要读文件内容就能得到，不允许被自定义变量占用。
const List<String> kBuiltinVariables = <String>[
  '原名',
  '扩展名',
  '目录名',
  '序号',
  '日期',
  '大小',
  '大小可读',
  '字数',
];

/// 变量在正文里的定位方式。
enum FieldLocator {
  /// 正则，取第 [ContentField.captureGroup] 个捕获组（0 = 整段匹配）。
  regex,

  /// 关键词行：找到包含关键词的行，取分隔符（：/: /空格）之后的内容。
  keywordLine,

  /// 固定行号，[ContentField.pattern] 里写 1 起的行号。
  lineNumber,

  /// 起止标记之间，[ContentField.pattern] 是起始标记，[endPattern] 是结束标记。
  between,

  /// 《》书名号里的第 N 个。
  bookTitleMark,
}

const List<String> kLocatorValues = <String>[
  'regex',
  'keywordLine',
  'lineNumber',
  'between',
  'bookTitleMark',
];

const List<String> kLocatorLabels = <String>[
  '正则',
  '关键词行',
  '固定行号',
  '起止标记之间',
  '书名号《》内容',
];

FieldLocator locatorFromString(String? v) {
  final i = kLocatorValues.indexOf(v ?? '');
  return i < 0 ? FieldLocator.regex : FieldLocator.values[i];
}

String locatorToString(FieldLocator l) => kLocatorValues[l.index];

String locatorLabel(FieldLocator l) => kLocatorLabels[l.index];

/// 一条变量定义。可以配多条规则按顺序兜底，见 [RenamePreset.fields]：
/// 同名变量允许出现多次，命中第一条非空结果即停止。
class ContentField {
  ContentField({
    this.name = '',
    this.locator = FieldLocator.regex,
    this.pattern = '',
    this.endPattern = '',
    this.captureGroup = 1,
    this.occurrence = 1,
    this.joiner = '、',
  });

  /// 变量名，不含花括号，例如「作者」对应 {作者}。
  String name;

  FieldLocator locator;

  /// 正则 / 关键词 / 行号 / 起始标记 / 书名号序号，含义随 [locator] 变化。
  /// 留空表示这条规则不启用（主角这类没固定写法的字段就先空着，由用户自己填）。
  String pattern;

  /// [FieldLocator.between] 的结束标记。
  String endPattern;

  /// [FieldLocator.regex] 取第几个捕获组，0 表示整段匹配。
  int captureGroup;

  /// 命中第几次：1 = 第一个，-1 = 最后一个，0 = 全部（用 [joiner] 连接）。
  int occurrence;

  String joiner;

  ContentField copy() => ContentField(
        name: name,
        locator: locator,
        pattern: pattern,
        endPattern: endPattern,
        captureGroup: captureGroup,
        occurrence: occurrence,
        joiner: joiner,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'locator': locatorToString(locator),
        'pattern': pattern,
        'endPattern': endPattern,
        'captureGroup': captureGroup,
        'occurrence': occurrence,
        'joiner': joiner,
      };

  static ContentField fromJson(Map<String, dynamic> j) {
    String s(String k, String d) => j[k] is String ? j[k] as String : d;
    int i(String k, int d) => j[k] is num ? (j[k] as num).toInt() : d;
    final f = ContentField(
      name: s('name', ''),
      locator: locatorFromString(s('locator', 'regex')),
      pattern: s('pattern', ''),
      endPattern: s('endPattern', ''),
      captureGroup: i('captureGroup', 1),
      occurrence: i('occurrence', 1),
      joiner: s('joiner', '、'),
    );
    if (f.captureGroup < 0) f.captureGroup = 0;
    if (f.captureGroup > 9) f.captureGroup = 9;
    return f;
  }
}

/// 挖出来的字符串怎么洗。
class CleanConfig {
  CleanConfig({
    this.trim = true,
    this.collapseWhitespace = true,
    this.stripTrailingWords = true,
    this.removePunctuation = false,
    this.toHalfWidth = false,
    this.maxLength = 24,
    this.blacklist = const <String>[
      '本站整理',
      '佚名',
      '未知',
      'TXT下载',
      'www.',
      'http',
    ],
  });

  bool trim;
  bool collapseWhitespace;

  /// 去掉结尾的「著 / 编 / 作品 / 全集」等尾巴。
  bool stripTrailingWords;
  bool removePunctuation;
  bool toHalfWidth;

  /// 单个变量最多保留几个字，0 = 不限。
  int maxLength;

  /// 命中任一条就当作没找到（广告、站点水印、占位词）。
  List<String> blacklist;

  CleanConfig copy() => CleanConfig(
        trim: trim,
        collapseWhitespace: collapseWhitespace,
        stripTrailingWords: stripTrailingWords,
        removePunctuation: removePunctuation,
        toHalfWidth: toHalfWidth,
        maxLength: maxLength,
        blacklist: List<String>.from(blacklist),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'trim': trim,
        'collapseWhitespace': collapseWhitespace,
        'stripTrailingWords': stripTrailingWords,
        'removePunctuation': removePunctuation,
        'toHalfWidth': toHalfWidth,
        'maxLength': maxLength,
        'blacklist': blacklist,
      };

  static CleanConfig fromJson(Map<String, dynamic> j) {
    bool b(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    int i(String k, int d) => j[k] is num ? (j[k] as num).toInt() : d;
    final c = CleanConfig(
      trim: b('trim', true),
      collapseWhitespace: b('collapseWhitespace', true),
      stripTrailingWords: b('stripTrailingWords', true),
      removePunctuation: b('removePunctuation', false),
      toHalfWidth: b('toHalfWidth', false),
      maxLength: i('maxLength', 24),
    );
    final raw = j['blacklist'];
    if (raw is List) {
      c.blacklist = <String>[for (final e in raw) if (e != null) e.toString()];
    }
    if (c.maxLength < 0) c.maxLength = 0;
    if (c.maxLength > 200) c.maxLength = 200;
    return c;
  }
}

/// 读文件的哪一段。
class ScanConfig {
  ScanConfig({
    this.scope = 'head',
    this.headBytes = 16 * 1024,
    this.headLines = 0,
    this.headMode = 'bytes',
    this.tailBytes = 16 * 1024,
    this.tailLines = 0,
    this.tailMode = 'bytes',
    this.encoding = 'auto',
    this.extensions = const <String>['.txt'],
    this.fullReadCapBytes = 8 * 1024 * 1024,
    this.includeSubfolders = false,
    this.concurrency = 3,
  });

  /// head / tail / both / full。
  String scope;
  int headBytes;

  /// 只在前 N 行里找，0 = 不限制（仅当 [headMode] 为 'lines' 时生效）。
  int headLines;

  /// 开头量法：'bytes' = 按大小（[headBytes]），'lines' = 按行数（[headLines]）。
  String headMode;

  int tailBytes;

  /// 只在后 N 行里找，0 = 不限制（仅当 [tailMode] 为 'lines' 时生效）。
  int tailLines;

  /// 结尾量法：'bytes' = 按大小（[tailBytes]），'lines' = 按行数（[tailLines]）。
  String tailMode;

  /// auto / utf8 / gbk / utf16le / utf16be / big5。
  String encoding;

  /// 只对哪些扩展名做内容提取；其它文件保持原名。
  List<String> extensions;

  /// 全文模式最多读取多少字节（读取上限，防整本读入 OOM）。默认 8 MB。
  int fullReadCapBytes;

  /// 选中的文件夹是否递归展开成里面的文件。
  bool includeSubfolders;

  /// 同时读几个文件。默认 3，范围 1~8；太大会把低端机 IO 打满。
  int concurrency;

  ScanConfig copy() => ScanConfig(
        scope: scope,
        headBytes: headBytes,
        headLines: headLines,
        headMode: headMode,
        tailBytes: tailBytes,
        tailLines: tailLines,
        tailMode: tailMode,
        encoding: encoding,
        extensions: List<String>.from(extensions),
        fullReadCapBytes: fullReadCapBytes,
        includeSubfolders: includeSubfolders,
        concurrency: concurrency,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'scope': scope,
        'headBytes': headBytes,
        'headLines': headLines,
        'headMode': headMode,
        'tailBytes': tailBytes,
        'tailLines': tailLines,
        'tailMode': tailMode,
        'encoding': encoding,
        'extensions': extensions,
        'fullReadCapBytes': fullReadCapBytes,
        'includeSubfolders': includeSubfolders,
        'concurrency': concurrency,
      };

  static ScanConfig fromJson(Map<String, dynamic> j) {
    String s(String k, String d) => j[k] is String ? j[k] as String : d;
    bool b(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    int i(String k, int d) => j[k] is num ? (j[k] as num).toInt() : d;
    final c = ScanConfig(
      scope: s('scope', 'head'),
      headBytes: i('headBytes', 16 * 1024),
      headLines: i('headLines', 0),
      tailBytes: i('tailBytes', 16 * 1024),
      encoding: s('encoding', 'auto'),
      fullReadCapBytes: i('fullReadCapBytes', 8 * 1024 * 1024),
      includeSubfolders: b('includeSubfolders', false),
      concurrency: i('concurrency', 3),
    );
    final raw = j['extensions'];
    if (raw is List) {
      c.extensions = <String>[for (final e in raw) if (e != null) e.toString()];
    }
    if (c.extensions.isEmpty) c.extensions = <String>['.txt'];
    if (!const <String>['head', 'tail', 'both', 'full']
        .contains(c.scope)) {
      c.scope = 'head';
    }
    if (c.headBytes < 1024) c.headBytes = 1024;
    if (c.headBytes > 2 * 1024 * 1024) c.headBytes = 2 * 1024 * 1024;
    if (c.tailBytes < 1024) c.tailBytes = 1024;
    if (c.tailBytes > 2 * 1024 * 1024) c.tailBytes = 2 * 1024 * 1024;
    if (c.headLines < 0) c.headLines = 0;
    c.tailLines = i('tailLines', 0);
    if (c.tailLines < 0) c.tailLines = 0;
    // 旧预设没有 headMode/tailMode：按 headLines/tailLines 是否 >0 回推，保持原行为。
    final headModeRaw = j['headMode'];
    c.headMode = headModeRaw == 'lines' || headModeRaw == 'bytes'
        ? headModeRaw as String
        : (c.headLines > 0 ? 'lines' : 'bytes');
    final tailModeRaw = j['tailMode'];
    c.tailMode = tailModeRaw == 'lines' || tailModeRaw == 'bytes'
        ? tailModeRaw as String
        : (c.tailLines > 0 ? 'lines' : 'bytes');
    if (c.fullReadCapBytes < 1024 * 1024) c.fullReadCapBytes = 1024 * 1024;
    if (c.fullReadCapBytes > 2 * 1024 * 1024 * 1024) {
      c.fullReadCapBytes = 2 * 1024 * 1024 * 1024;
    }
    if (c.concurrency < 1) c.concurrency = 1;
    if (c.concurrency > 8) c.concurrency = 8;
    return c;
  }
}

/// 一整套可保存 / 切换的命名方案。
class RenamePreset {
  RenamePreset({
    this.name = '小说',
    this.template = '{原名} 作者：{作者}',
    List<ContentField>? fields,
    CleanConfig? clean,
    ScanConfig? scan,
    this.fallback = 'skip',
    this.defaultValue = '',
    this.applyExistingRules = true,
    this.illegalCharMode = 'delete',
    this.illegalReplacement = '-',
    this.spaceToUnderscore = false,
    this.maxNameLength = 120,
    this.conflictPolicy = 'skip',
    this.conflictSuffixFormat = '_{n}',
  })  : fields = fields ?? _defaultFields(),
        clean = clean ?? CleanConfig(),
        scan = scan ?? ScanConfig();

  String name;

  /// 命名模板。支持 {变量}、{变量|默认值}、[可选片段]、\[ 转义。
  String template;

  /// 自定义变量。同名多条按顺序兜底。
  List<ContentField> fields;

  CleanConfig clean;
  ScanConfig scan;

  /// skip（不改 + 标黄待确认）/ defaultValue（用 [defaultValue]）/ keep（等于原名）。
  String fallback;
  String defaultValue;

  /// 模板生成的基础名，是否再过一遍现有的查找替换 / 前后缀 / 序号 / 日期规则。
  bool applyExistingRules;

  /// delete / replace，非法字符 \ / : * ? " < > | 的处理。
  String illegalCharMode;
  String illegalReplacement;
  bool spaceToUnderscore;

  /// 最终文件名（不含扩展名）最长几个字，0 = 不限。
  int maxNameLength;

  /// skip / sequence（重名自动加后缀）。
  String conflictPolicy;

  /// 自动加序号时用的后缀格式，必须含 {n}（会被换成 2、3…），插在扩展名之前。
  /// '_{n}' → 三体_2.txt；'_副本{n}' → 三体_副本2.txt；'({n})' → 三体(2).txt。
  /// 格式不合规时回退到 [defaultConflictSuffixFormat]。
  String conflictSuffixFormat;

  static const String defaultConflictSuffixFormat = '_{n}';

  /// 规范化后缀格式：去掉文件名非法字符、限长、强制含 {n}。
  /// 没有 {n} 的格式会让所有冲突行生成同一个名字，循环加到 999 也还是重名，
  /// 所以必须在这里兜住；手改坏的旧 JSON 也走同一条兜底。
  static String normalizeConflictSuffixFormat(String raw) {
    final s = raw
        .trim()
        .replaceAll(RegExp(r'[<>/\\:*?"|\x00-\x1F\x7F]'), '');
    if (s.isEmpty || s.length > 40 || !s.contains('{n}')) {
      return defaultConflictSuffixFormat;
    }
    return s;
  }

  static List<ContentField> _defaultFields() => <ContentField>[
        ContentField(
          name: '书名',
          locator: FieldLocator.regex,
          pattern: r'《([^》\n]{1,30})》',
          captureGroup: 1,
        ),
        // 作者：一条正则覆盖常见写法，且只用同一个捕获组 1（同名只保留一行）。
        // ① 作者：张三 / 著者：张三 / 原著：张三 / by顾绥
        // ② 封面《书名》张三著
        // ③ 《书名》作者：张三 / 《书名》by顾绥（书名号后再带标签）
        // 行首必须有「书名号或作者标签」、整行以人名收尾，避免把
        // 「《书名》第一章 初遇」这类正文误当成作者；
        // 捕获组是非贪婪的，封面写法的「著」字不会被一起抓进来。
        ContentField(
          name: '作者',
          locator: FieldLocator.regex,
          pattern: r'^[ \t]*(?:《[^》\n]{1,30}》|(?:作\s*者|著\s*者|原\s*著|by)\s*[：:]?)[ \t]*(?:(?:作\s*者|著\s*者|原\s*著|by)\s*[：:]?[ \t]*)?([\u4e00-\u9fa5A-Za-z·.]{2,12}?)[ \t]*(?:著)?[ \t]*$',
          captureGroup: 1,
        ),
        // 主角：按常见写法「主角：时絮，顾绥」预置（前导全角/半角空格、中英文冒号均可），
        // 多人逗号分隔会作为整段值；格式不符时用户可自行改正则。
        ContentField(
          name: '主角',
          locator: FieldLocator.regex,
          pattern: r'主角\s*[：:]\s*(.+)',
          captureGroup: 1,
        ),
      ];

  factory RenamePreset.starter() => RenamePreset();

  RenamePreset copy() => RenamePreset(
        name: name,
        template: template,
        fields: <ContentField>[for (final f in fields) f.copy()],
        clean: clean.copy(),
        scan: scan.copy(),
        fallback: fallback,
        defaultValue: defaultValue,
        applyExistingRules: applyExistingRules,
        illegalCharMode: illegalCharMode,
        illegalReplacement: illegalReplacement,
        spaceToUnderscore: spaceToUnderscore,
        maxNameLength: maxNameLength,
        conflictPolicy: conflictPolicy,
        conflictSuffixFormat: conflictSuffixFormat,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'template': template,
        'fields': <dynamic>[for (final f in fields) f.toJson()],
        'clean': clean.toJson(),
        'scan': scan.toJson(),
        'fallback': fallback,
        'defaultValue': defaultValue,
        'applyExistingRules': applyExistingRules,
        'illegalCharMode': illegalCharMode,
        'illegalReplacement': illegalReplacement,
        'spaceToUnderscore': spaceToUnderscore,
        'maxNameLength': maxNameLength,
        'conflictPolicy': conflictPolicy,
        'conflictSuffixFormat': conflictSuffixFormat,
      };

  static RenamePreset fromJson(Map<String, dynamic> j) {
    String s(String k, String d) => j[k] is String ? j[k] as String : d;
    bool b(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    int i(String k, int d) => j[k] is num ? (j[k] as num).toInt() : d;

    final p = RenamePreset(
      name: s('name', '小说'),
      template: s('template', '{原名} 作者：{作者}'),
      fields: <ContentField>[],
      fallback: s('fallback', 'skip'),
      defaultValue: s('defaultValue', ''),
      applyExistingRules: b('applyExistingRules', true),
      illegalCharMode: s('illegalCharMode', 'delete'),
      illegalReplacement: s('illegalReplacement', '-'),
      spaceToUnderscore: b('spaceToUnderscore', false),
      maxNameLength: i('maxNameLength', 120),
      conflictPolicy: s('conflictPolicy', 'skip'),
      conflictSuffixFormat: normalizeConflictSuffixFormat(
          s('conflictSuffixFormat', defaultConflictSuffixFormat)),
    );

    final rawFields = j['fields'];
    if (rawFields is List) {
      for (final e in rawFields) {
        if (e is Map) {
          p.fields.add(ContentField.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    if (p.fields.isEmpty) {
      p.fields = _defaultFields();
    }

    final rawClean = j['clean'];
    if (rawClean is Map) {
      p.clean = CleanConfig.fromJson(Map<String, dynamic>.from(rawClean));
    }
    final rawScan = j['scan'];
    if (rawScan is Map) {
      p.scan = ScanConfig.fromJson(Map<String, dynamic>.from(rawScan));
    }

    if (!const <String>['skip', 'defaultValue', 'keep'].contains(p.fallback)) {
      p.fallback = 'skip';
    }
    if (!const <String>['delete', 'replace'].contains(p.illegalCharMode)) {
      p.illegalCharMode = 'delete';
    }
    if (!const <String>['skip', 'sequence'].contains(p.conflictPolicy)) {
      p.conflictPolicy = 'skip';
    }
    if (p.maxNameLength < 0) p.maxNameLength = 0;
    if (p.maxNameLength > 240) p.maxNameLength = 240;
    return p;
  }

  String encode() => jsonEncode(toJson());

  static RenamePreset? decode(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map) return fromJson(Map<String, dynamic>.from(v));
    } catch (_) {}
    return null;
  }
}
