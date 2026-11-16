import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:charset/charset.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/debug/compare_timing_log.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/theme/skin.dart';
import '../../../core/widgets/app_file_icon.dart';
import '../../../core/widgets/gradient_icon.dart';
import '../../help/presentation/help_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../share_intake/application/share_intake_service.dart';
import '../../share_intake/presentation/shared_trash_page.dart';
import '../../parser/application/document_parser.dart';
import '../../viewer/presentation/device_memory_guard.dart';
import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../../reader/reader_load_log.dart';
import '../../reader/reader_repository.dart';
import '../../reader/reader_screen.dart';
import '../../viewer/presentation/diff_list_page.dart';
import '../../viewer/presentation/diff_viewer_screen.dart';
import '../../viewer/presentation/providers/diff_viewer_providers.dart';
import '../../viewer/presentation/loading_palette.dart';
import '../../viewer/presentation/widgets/low_similarity_dialogs.dart';
import 'browser_settings_screen.dart';
import 'comparison_settings_screen.dart';
import 'config_io_service.dart';
import 'dialogs/directory_picker_dialog.dart';
import 'dir_loader.dart';
import 'file_open_helper.dart';
import 'providers/file_browser_providers.dart';
import 'single_file_editor_screen.dart';
import '../../rename/content_extractor.dart';
import '../../rename/preset_store.dart';
import '../../rename/rename_models.dart';
import '../../rename/rename_template.dart';

// ==================== 路由观察者 ====================

final RouteObserver<PageRoute<dynamic>> fileBrowserRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

// ==================== 导出文件清单 ====================

String _fmtSizeForListing(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String _fmtTimeForListing(DateTime t) {
  String two(int n) => n < 10 ? '0$n' : '$n';
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

Future<Uint8List> _folderListingWorker(String rootPath) async {
  final body = StringBuffer();
  var fileCount = 0;
  var dirCount = 0;
  var emptyDirCount = 0;
  var totalBytes = 0;

  void walk(String dirPath) {
    List<FileSystemEntity> entities;
    try {
      entities = Directory(dirPath).listSync(followLinks: false);
    } catch (_) {
      return;
    }

    final files = <File>[];
    final dirs = <Directory>[];
    for (final e in entities) {
      final name = e.path.split('/').last;
      if (name.isEmpty) continue;
      if (e is File) {
        files.add(e);
      } else if (e is Directory) {
        dirs.add(e);
      }
    }

    files.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    dirs.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    if (files.isEmpty && dirs.isEmpty) {
      body.writeln('$dirPath | (空目录) | —');
      emptyDirCount++;
      return;
    }

    for (final f in files) {
      int size = 0;
      DateTime? modified;
      try {
        final st = f.statSync();
        size = st.size;
        modified = st.modified;
      } catch (_) {}
      final sizeStr = _fmtSizeForListing(size);
      final timeStr =
          modified == null ? '—' : _fmtTimeForListing(modified);
      body.writeln('${f.path} | $sizeStr | $timeStr');
      fileCount++;
      totalBytes += size;
    }

    for (final d in dirs) {
      dirCount++;
      walk(d.path);
    }
  }

  walk(rootPath);

  final header = StringBuffer();
  header.writeln(
      '# ============================================================');
  header.writeln('# 文件夹文件清单');
  header.writeln(
      '# ============================================================');
  header.writeln('# 根目录：$rootPath');
  header.writeln('# 导出时间：${_fmtTimeForListing(DateTime.now())}');
  header.writeln('# 总文件数：$fileCount');
  header.writeln('# 总目录数：$dirCount（含空目录 $emptyDirCount）');
  header.writeln('# 总大小：${_fmtSizeForListing(totalBytes)}');
  header.writeln('#');
  header.writeln('# 格式说明：');
  header.writeln('#   每一行：完整路径 | 大小 | 修改时间');
  header.writeln('#   空目录：完整路径 | (空目录) | —');
  header.writeln('#   排序：按目录树顺序');
  header.writeln('#         （当前目录的文件在前，子目录按名称递归）');
  header.writeln(
      '# ============================================================');
  header.writeln();

  final builder = BytesBuilder();
  builder.add(utf8.encode(header.toString()));
  builder.add(utf8.encode(body.toString()));
  return builder.takeBytes();
}

/// 查重暂存篮：跨层级收集待查重的文件夹路径。
/// 去重、保持加入顺序；任何目录层级的文件夹都能加入，确认后一次性传给 DupeBox。
final dupBasketProvider = StateProvider<List<String>>((ref) => const []);

class FileBrowserScreen extends ConsumerStatefulWidget {
  const FileBrowserScreen({super.key, this.initialPath, this.revealPath});

  /// 以子页面方式打开时的起始目录。
  /// 为 null 表示主页面：沿用上次浏览目录，并继续写回该记录。
  final String? initialPath;

  /// 打开后需要定位的文件路径（仅子页面使用）：滚动到该文件并短暂高亮。
  final String? revealPath;

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}
enum _ConflictAction { skip, overwrite, rename }

// ==================== 批量重命名：内容提取解码器 ====================

/// 把项目现成的编码探测 + 宽容解码接给内容提取器。
/// [hint] 不是 auto 时当固定编码名；Android 上 GBK 等最终走系统 ICU。
Future<DecodedChunk> _decodeForRename(Uint8List bytes, String hint) async {
  EncodingType enc;
  if (hint == 'auto' || hint.isEmpty) {
    enc = EncodingDetector.detect(bytes);
  } else {
    try {
      enc = EncodingType.values.byName(hint);
    } catch (_) {
      enc = EncodingDetector.detect(bytes);
    }
  }
  final decoded = await EncodingDetector.decodeChunkedAsync(bytes, enc);
  return DecodedChunk(decoded.text, decoded.encoding.name);
}

// ==================== 批量重命名：配置 + 规则引擎 ====================

/// 卡片式阴影（范围按原型减小：淡、贴边）。
const List<BoxShadow> _kCardShadow = <BoxShadow>[
  BoxShadow(color: Color(0x1A000000), blurRadius: 3, offset: Offset(0, 1)),
  BoxShadow(color: Color(0x0D000000), blurRadius: 1, offset: Offset(0, 0.5)),
];

/// 分区标题 / 状态徽章用的强调色：亮主色混黑加深，其余走主题强调色。
Color _sectionAccentOf(ColorScheme cs) {
  final p = cs.primary;
  if (p.computeLuminance() > 0.5) {
    return Color.lerp(p, Colors.black, 0.4) ?? p;
  }
  return AppColors.textAccentOf(cs);
}

class _RenameConfig {
  /// 命名方式：rules = 保留原名（用加工改）；fullName = 命名格式（自己写格式）。
  String renameMode = 'rules';

  // 命名格式（fullName）：格式串支持 {变量}；想加序号就在格式里写 {序号}。
  String fullNameBase = ''; // 命名格式（不含扩展名）
  String fullNameSeqFormat = '({n})'; // {n} 会替换成序号（旧字段，保留兼容）

  /// 预览/序号顺序：browser / selected / name / nameDesc /
  /// mtime / mtimeDesc / size / sizeDesc / custom。
  String orderMode = 'browser';

  // 查找替换
  String findText = '';
  String replaceText = '';
  bool useRegex = false;

  // 前缀 / 后缀（扩展名前）
  String prefix = '';
  String suffix = '';

  // 序号分两套，与品红原型一致：各自独立、互不影响。
  // A = 命名格式里的 {序号}（含格式串变量 {序号}），点输入框旁 {序号} 的齿轮设置。
  // B = 「插入内容 → 序号」这张来源卡，配置就在卡内。
  bool sequenceEnabled = false; // B 的启用开关
  int sequenceStart = 1; // A：起始
  int sequenceStep = 1; // A：步长
  int sequenceWidth = 2; // A：位数
  int insertSeqStart = 1; // B：起始
  int insertSeqStep = 1; // B：步长
  int insertSeqWidth = 2; // B：位数
  bool sequenceAtPrefix = false; // B：false=放后面，true=放前面
  String sequenceSeparator = '_'; // B：编号与名字之间的分隔符

  // 扩展名 / 大小写（弹窗里拆成两个分组）
  bool changeExt = false;
  String newExt = '';
  String caseMode = 'none'; // none / lower / upper / capitalize

  // 高级：插入 / 删除
  int insertPos = 1; // 固定文字「第 N 位前」插入位置（1 起）；insertTextPosition 选 insert 时生效
  String insertTextPosition =
      'suffix'; // prefix / suffix / insert（固定文字插到名称前 / 后 / 中间）；默认名称后面，与原型一致
  String contentInsertPosition =
      'suffix'; // prefix / suffix / insert（从文件内容取值插到名称前 / 后 / 中间）
  int contentInsertPos = 1; // contentInsertPosition 选 insert 时生效
  String insertText = '';

  bool deleteEnabled = false;
  int deleteStart = 1; // 删除起点（1 起）
  int deleteLength = 1;

  // 日期
  bool dateEnabled = false;
  String dateFormat = 'yyyyMMdd'; // 日期格式模板
  String datePosition = 'suffix'; // prefix / suffix / insert
  int dateInsertPos = 1; // datePosition == insert 时：插在第 N 个字符前

  /// 插入内容来源之一：把从文件里挖到的变量值（多个用 _ 连接）插进名字。
  /// 开启后即使命名方式是「保留原名」也会读文件扫描（见 _extractionActive）。
  bool insertContentVars = false;

  /// 插入内容来源之一：前缀 / 后缀。默认开（为空就不拼），用来源开关控制。
  bool affixEnabled = true;

  /// 命名格式里 {日期} 的格式（点 {日期} 齿轮设置）。
  String varDateFormat = 'yyyyMMdd';

  /// 命名格式里 {大小可读} 的单位（auto/KB/MB/GB/B）与小数位（0/1/2）。
  String varSizeUnit = 'auto';
  int varSizeDec = 1;
}

/// 纯函数：原名 + 本批序号 + 配置 → 新名。
/// [isDir] 为 true 时不拆扩展名（文件夹名里的 . 不当扩展名处理）。
String _applyRenameRules(
  String original,
  int index,
  _RenameConfig c, {
  bool isDir = false,
  String? contentInsert,
}) {
  final dotIdx = original.lastIndexOf('.');
  final hasExt = !isDir && dotIdx > 0 && dotIdx < original.length - 1;
  String base = hasExt ? original.substring(0, dotIdx) : original;
  String ext = hasExt ? original.substring(dotIdx + 1) : '';

  // 1. 查找替换（普通 / 正则，支持 $1 $2 捕获组引用）
  if (c.findText.isNotEmpty) {
    if (c.useRegex) {
      try {
        final re = RegExp(c.findText);
        base = base.replaceAllMapped(re, (m) {
          return c.replaceText.replaceAllMapped(RegExp(r'\$(\d+)'), (mm) {
            final n = int.tryParse(mm.group(1) ?? '');
            if (n == null) return mm.group(0) ?? '';
            return m.group(n) ?? '';
          });
        });
      } catch (_) {
        // 正则非法：原样保留，预览里也不会崩
      }
    } else {
      base = base.replaceAll(c.findText, c.replaceText);
    }
  }

  // 2. 删除区间（先删再加，保证序号位置不受删除影响）
  if (c.deleteEnabled && base.isNotEmpty) {
    final s = (c.deleteStart - 1).clamp(0, base.length);
    final e = (s + c.deleteLength).clamp(0, base.length);
    if (s < e) base = base.substring(0, s) + base.substring(e);
  }

  // 3. 插入内容（来源可叠加：从文件内容取值在前，固定文字在后；各自独立插到）
  if (c.insertContentVars && (contentInsert ?? '').isNotEmpty) {
    base = _insertAt(base, c.contentInsertPosition, c.contentInsertPos, contentInsert!);
  }
  if (c.insertText.isNotEmpty) {
    base = _insertAt(base, c.insertTextPosition, c.insertPos, c.insertText);
  }

  // 4. 大小写（只改名称部分，扩展名不动）
  base = switch (c.caseMode) {
    'lower' => base.toLowerCase(),
    'upper' => base.toUpperCase(),
    'capitalize' => base.isEmpty
        ? base
        : base[0].toUpperCase() + base.substring(1).toLowerCase(),
    _ => base,
  };

  // 5. 日期：按用户选的格式，插到名称前 / 名称后 / 第 N 位前
  if (c.dateEnabled) {
    final fmt = c.dateFormat.isEmpty ? 'yyyyMMdd' : c.dateFormat;
    final dateStr = _formatDate(DateTime.now(), fmt);
    if (dateStr.isNotEmpty) {
      base = _insertAt(base, c.datePosition, c.dateInsertPos, dateStr);
    }
  }

  // 6. 序号：这里是「插入内容 → 序号」那套（B），
  // 与命名格式 {序号}（A）各自独立，互不影响。
  if (c.sequenceEnabled) {
    final n = c.insertSeqStart + index * c.insertSeqStep;
    final s = n.toString().padLeft(c.insertSeqWidth, '0');
    base = c.sequenceAtPrefix
        ? '$s${c.sequenceSeparator}$base'
        : '$base${c.sequenceSeparator}$s';
  }

  // 7. 前缀后缀。新 UI 里「前缀 / 后缀」是填内容即启用的常驻来源卡，
  // 不再有独立开关，故不受旧的 affixEnabled 门控（空串拼接本身是 no-op）。
  base = '${c.prefix}$base${c.suffix}';

  // 8. 扩展名（文件夹不改）
  if (c.changeExt && !isDir) ext = c.newExt;

  return ext.isEmpty ? base : '$base.$ext';
}

/// 把 [text] 按 [position] 插进 [base]：
/// 'prefix' = 名称最前面；'suffix' = 名称最后面；'insert' = 第 [pos] 个字符前。
String _insertAt(String base, String position, int pos, String text) {
  if (position == 'prefix') return '$text$base';
  if (position == 'insert') {
    final p = (pos - 1).clamp(0, base.length);
    return base.substring(0, p) + text + base.substring(p);
  }
  return '$base$text';
}

/// 全名重命名：新名字 + 可选序号，保留原扩展名。
///
/// [index] 是按当前顺序排好的序号下标；[useSequence] 为 false（只选了一个文件）
/// 时只改成新名字，不加序号，和 Windows 文件浏览器的行为一致。
String _applyFullNameRules(
  String original,
  int index,
  _RenameConfig c, {
  bool isDir = false,
  bool useSequence = true,
  String? baseOverride,
}) {
  final dotIdx = original.lastIndexOf('.');
  final hasExt = !isDir && dotIdx > 0 && dotIdx < original.length - 1;
  final ext = hasExt ? original.substring(dotIdx + 1) : '';

  // baseOverride：预览里已把 {日期} 这类内置变量替换成真实值的新名字。
  final base = (baseOverride ?? c.fullNameBase).trim();
  // 还没输入新名字：保持原名，预览会显示「不变」，执行按钮也会禁用。
  if (base.isEmpty) return original;

  var name = base;
  if (useSequence) {
    final n = c.sequenceStart + index * c.sequenceStep;
    final s = n.toString().padLeft(c.sequenceWidth, '0');
    name += c.fullNameSeqFormat.replaceAll('{n}', s);
  }
  return ext.isEmpty ? name : '$name.$ext';
}

/// 文件大小转成人能看懂的短文本。unit: auto/KB/MB/GB/B；dec: 小数位 0-2。
/// 模板变量 {大小可读} 和「命名格式」的变量替换共用。
String _humanSizeEx(int bytes, String unit, int dec) {
  String f(double v) =>
      dec <= 0 ? v.round().toString() : v.toStringAsFixed(dec);
  if (unit == 'B') return '$bytes B';
  if (unit == 'KB') return '${f(bytes / 1024)}KB';
  if (unit == 'MB') return '${f(bytes / 1048576)}MB';
  if (unit == 'GB') return '${f(bytes / 1073741824)}GB';
  if (bytes < 1024) return '${bytes}B';
  double v = bytes / 1024;
  if (v < 1024) return v < 10 ? '${f(v)}KB' : '${v.round()}KB';
  v /= 1024;
  if (v < 1024) return v < 10 ? '${f(v)}MB' : '${v.round()}MB';
  v /= 1024;
  return v < 10 ? '${f(v)}GB' : '${v.round()}GB';
}

/// 默认自适应单位、1 位小数。
String _humanSize(int bytes) => _humanSizeEx(bytes, 'auto', 1);

/// {字数}：<1万字用「千字」、≥1万字用「万」，均保留 1 位小数，尾随 .0 去掉。
/// 例：832 → 0.8千字，2400 → 2.4千字，2000 → 2千字，12345 → 1.2万，246800 → 24.7万。
String _humanCharCount(int n) {
  String trim(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  if (n < 10000) return '${trim(n / 1000)}千字';
  return '${trim(n / 10000)}万';
}

/// 日期格式化：支持 yyyy / yy / MM / M / dd / d / HH / H / mm / ss，
/// 其它字符（包括「年」「月」「日」、「-」「_」等）原样输出。
String _formatDate(DateTime t, String fmt) {
  String two(int n) => n.toString().padLeft(2, '0');
  // 长 token 在前，避免 yyyy 被 yy 抢先匹配。
  const tokens = ['yyyy', 'yy', 'MM', 'dd', 'HH', 'mm', 'ss', 'M', 'd', 'H'];
  final sb = StringBuffer();
  var i = 0;
  while (i < fmt.length) {
    var matched = false;
    for (final tk in tokens) {
      if (!fmt.startsWith(tk, i)) continue;
      sb.write(switch (tk) {
        'yyyy' => '${t.year}',
        'yy' => two(t.year % 100),
        'MM' => two(t.month),
        'M' => '${t.month}',
        'dd' => two(t.day),
        'd' => '${t.day}',
        'HH' => two(t.hour),
        'H' => '${t.hour}',
        'mm' => two(t.minute),
        'ss' => two(t.second),
        _ => tk,
      });
      i += tk.length;
      matched = true;
      break;
    }
    if (!matched) {
      sb.write(fmt[i]);
      i++;
    }
  }
  return sb.toString();
}

// ---------- 配置持久化 ----------

const String _kRenameConfigKey = 'batch_rename_config_v1';

/// 「记住上次规则」是独立开关，和规则内容分开存。
/// 默认 false：每次打开批量重命名都是空白规则，不用再手动重置。
const String _kRenameRememberKey = 'batch_rename_remember_v1';

/// 序号顺序的可选值（持久化时也要校验）。
const List<(String, String)> _kRenameOrderOptions = [
  ('browser', '列表顺序'),
  ('selected', '选择顺序'),
  ('name', '名称 ↑'),
  ('nameDesc', '名称 ↓'),
  ('mtime', '时间 ↑'),
  ('mtimeDesc', '时间 ↓'),
  ('size', '大小 ↑'),
  ('sizeDesc', '大小 ↓'),
  ('custom', '手动顺序'),
];

const Set<String> _kRenameOrderModes = {
  'browser',
  'selected',
  'name',
  'nameDesc',
  'mtime',
  'mtimeDesc',
  'size',
  'sizeDesc',
  'custom',
};

extension _RenameConfigJson on _RenameConfig {
  Map<String, dynamic> toJson() => <String, dynamic>{
        'renameMode': renameMode,
        'fullNameBase': fullNameBase,
        'fullNameSeqFormat': fullNameSeqFormat,
        'orderMode': orderMode,
        'findText': findText,
        'replaceText': replaceText,
        'useRegex': useRegex,
        'prefix': prefix,
        'suffix': suffix,
        'sequenceEnabled': sequenceEnabled,
        'sequenceStart': sequenceStart,
        'sequenceStep': sequenceStep,
        'sequenceWidth': sequenceWidth,
        'insertSeqStart': insertSeqStart,
        'insertSeqStep': insertSeqStep,
        'insertSeqWidth': insertSeqWidth,
        'sequenceAtPrefix': sequenceAtPrefix,
        'sequenceSeparator': sequenceSeparator,
        'changeExt': changeExt,
        'newExt': newExt,
        'caseMode': caseMode,
        'insertPos': insertPos,
        'insertTextPosition': insertTextPosition,
        'contentInsertPosition': contentInsertPosition,
        'contentInsertPos': contentInsertPos,
        'insertText': insertText,
        'deleteEnabled': deleteEnabled,
        'deleteStart': deleteStart,
        'deleteLength': deleteLength,
        'dateEnabled': dateEnabled,
        'dateFormat': dateFormat,
        'datePosition': datePosition,
        'dateInsertPos': dateInsertPos,
        'insertContentVars': insertContentVars,
        'affixEnabled': affixEnabled,
        'varDateFormat': varDateFormat,
        'varSizeUnit': varSizeUnit,
        'varSizeDec': varSizeDec,
      };
}

/// 从 JSON 恢复。任何字段缺失/类型不对都回退到默认值。
_RenameConfig _renameConfigFromJson(Map<String, dynamic> j) {
  final c = _RenameConfig();
  String str(String k, String d) => j[k] is String ? j[k] as String : d;
  bool boo(String k, bool d) => j[k] is bool ? j[k] as bool : d;
  int integer(String k, int d) =>
      j[k] is num ? (j[k] as num).toInt() : d;

  c.renameMode = str('renameMode', 'rules');
  c.fullNameBase = str('fullNameBase', '');
  c.fullNameSeqFormat = str('fullNameSeqFormat', '({n})');
  c.orderMode = str('orderMode', 'browser');

  c.findText = str('findText', '');
  c.replaceText = str('replaceText', '');
  c.useRegex = boo('useRegex', false);
  c.prefix = str('prefix', '');
  c.suffix = str('suffix', '');
  c.sequenceEnabled = boo('sequenceEnabled', false);
  c.sequenceStart = integer('sequenceStart', 1);
  c.sequenceStep = integer('sequenceStep', 1);
  c.sequenceWidth = integer('sequenceWidth', 2);
  // 旧存档没有 B 的三项：用 A 的值兜底，拆开前共用一份，行为保持不变。
  c.insertSeqStart = integer('insertSeqStart', c.sequenceStart);
  c.insertSeqStep = integer('insertSeqStep', c.sequenceStep);
  c.insertSeqWidth = integer('insertSeqWidth', c.sequenceWidth);
  c.sequenceAtPrefix = boo('sequenceAtPrefix', false);
  c.sequenceSeparator = str('sequenceSeparator', '_');
  c.changeExt = boo('changeExt', false);
  c.newExt = str('newExt', '');
  c.caseMode = str('caseMode', 'none');
  c.insertPos = integer('insertPos', 1);
  c.insertTextPosition = str('insertTextPosition', 'suffix');
  c.contentInsertPosition = str('contentInsertPosition', 'suffix');
  c.contentInsertPos = integer('contentInsertPos', 1);
  c.insertText = str('insertText', '');
  c.deleteEnabled = boo('deleteEnabled', false);
  c.deleteStart = integer('deleteStart', 1);
  c.deleteLength = integer('deleteLength', 1);
  c.dateEnabled = boo('dateEnabled', false);
  c.dateFormat = str('dateFormat', 'yyyyMMdd');
  c.datePosition = str('datePosition', 'suffix');
  c.dateInsertPos = integer('dateInsertPos', 1);
  c.insertContentVars = boo('insertContentVars', false);
  c.affixEnabled = boo('affixEnabled', true);
  c.varDateFormat = str('varDateFormat', 'yyyyMMdd');
  c.varSizeUnit = str('varSizeUnit', 'auto');
  c.varSizeDec = integer('varSizeDec', 1);
  if (c.varDateFormat.isEmpty) c.varDateFormat = 'yyyyMMdd';
  if (c.varSizeDec < 0 || c.varSizeDec > 2) c.varSizeDec = 1;
  if (!const {'auto', 'KB', 'MB', 'GB', 'B'}.contains(c.varSizeUnit)) {
    c.varSizeUnit = 'auto';
  }

  // 边界保护：负值/0 会让 padLeft / substring 炸
  if (c.sequenceWidth < 1) c.sequenceWidth = 1;
  if (c.sequenceWidth > 12) c.sequenceWidth = 12;
  if (c.insertSeqWidth < 1) c.insertSeqWidth = 1;
  if (c.insertSeqWidth > 12) c.insertSeqWidth = 12;
  if (c.insertPos < 1) c.insertPos = 1;
  if (c.contentInsertPos < 1) c.contentInsertPos = 1;
  if (c.deleteStart < 1) c.deleteStart = 1;
  if (c.deleteLength < 1) c.deleteLength = 1;
  if (c.dateInsertPos < 1) c.dateInsertPos = 1;
  if (c.dateFormat.isEmpty) c.dateFormat = 'yyyyMMdd';

  // 枚举值兑底，避免旧配置/手改 JSON 让下拉框拿到不存在的 value。
  if (c.renameMode != 'rules' && c.renameMode != 'fullName') {
    c.renameMode = 'rules';
  }
  if (!_kRenameOrderModes.contains(c.orderMode)) c.orderMode = 'browser';
  if (c.fullNameSeqFormat.isEmpty) c.fullNameSeqFormat = '({n})';
  if (!const {'prefix', 'suffix', 'insert'}.contains(c.datePosition)) {
    c.datePosition = 'suffix';
  }
  if (!const {'prefix', 'suffix', 'insert'}.contains(c.insertTextPosition)) {
    c.insertTextPosition = 'suffix';
  }
  if (!const {'prefix', 'suffix', 'insert'}
      .contains(c.contentInsertPosition)) {
    c.contentInsertPosition = 'suffix';
  }

  return c;
}

/// 读上次配置；没有或损坏就返回默认。永不抛异常。
Future<_RenameConfig> _loadRenameConfig() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRenameConfigKey);
    if (raw == null || raw.isEmpty) return _RenameConfig();
    final map = jsonDecode(raw);
    if (map is! Map) return _RenameConfig();
    return _renameConfigFromJson(map.cast<String, dynamic>());
  } catch (_) {
    return _RenameConfig();
  }
}

/// 写配置。失败静默忽略——记住规则失败不该阻断改名。
Future<void> _saveRenameConfig(_RenameConfig c) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRenameConfigKey, jsonEncode(c.toJson()));
  } catch (_) {}
}

/// 读「记住上次规则」开关。读不到 / 损坏都按关闭处理。
Future<bool> _loadRenameRemember() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kRenameRememberKey) ?? false;
  } catch (_) {
    return false;
  }
}

/// 写「记住上次规则」开关。失败静默忽略，不阻断改名。
Future<void> _saveRenameRemember(bool value) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRenameRememberKey, value);
  } catch (_) {}
}

/// 清掉已保存的规则（「重置」时用），避免下次打开又被读回来。
Future<void> _clearSavedRenameConfig() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kRenameConfigKey);
  } catch (_) {}
}

// ==================== 高级搜索条件 ====================

enum _SearchOperator { or, and, not }

class _SearchCondition {
  _SearchCondition({required this.operator, String text = ''})
      : controller = TextEditingController(text: text);
  _SearchOperator operator;
  final TextEditingController controller;
  String get text => controller.text;
  void dispose() => controller.dispose();
}
class _SearchHit {
  _SearchHit({
    required this.path,
    required this.name,
    this.isDir = false,
    this.size,
    this.modified,
  });
  final String path;
  final String name;
  final bool isDir;
  final int? size;
  final DateTime? modified;
}

class _AdvancedOverlayContent extends StatefulWidget {
  const _AdvancedOverlayContent({
    required this.panelTop,
    required this.panelLeft,
    required this.panelWidth,
    required this.conditions,
    required this.onChanged,
    required this.onClearAll,
    required this.onClearConditions,
    required this.onSubmit,
    required this.onClose,
    required this.filterSizeMinMb,
    required this.filterSizeMaxMb,
    required this.filterTimeFrom,
    required this.filterTimeTo,
    required this.onSizeChanged,
    required this.onTimeChanged,
    required this.clearToken,
    required this.visible,
  });

  final double panelTop;
  final double panelLeft;
  final double panelWidth;
  final List<_SearchCondition> conditions;
  final VoidCallback onChanged;
  final VoidCallback onClearAll;
  final VoidCallback onClearConditions;
  final VoidCallback onSubmit;
  final VoidCallback onClose;
  final double? filterSizeMinMb;
  final double? filterSizeMaxMb;
  final DateTime? filterTimeFrom;
  final DateTime? filterTimeTo;
  final void Function(double? minMb, double? maxMb) onSizeChanged;
  final void Function(DateTime? from, DateTime? to) onTimeChanged;
  /// 只在「清空全部」这类真正的外部清空时自增；普通输入/退格一律不动。
  final int clearToken;
  /// A1 / F2：外部控制「展开 / 收起」；收起时先把高度动画播完再 remove。
  final ValueNotifier<bool> visible;

  @override
  State<_AdvancedOverlayContent> createState() =>
      _AdvancedOverlayContentState();
}

class _AdvancedOverlayContentState extends State<_AdvancedOverlayContent> {
  int? _openMenuIndex;
  final Map<int, GlobalKey> _btnKeys = {};

  final TextEditingController _sizeMinCtrl = TextEditingController();
  final TextEditingController _sizeMaxCtrl = TextEditingController();
  final TextEditingController _timeFromCtrl = TextEditingController();
  final TextEditingController _timeToCtrl = TextEditingController();
  final FocusNode _timeFromFocus = FocusNode();
  final FocusNode _timeToFocus = FocusNode();
  // 光标最后落在哪个时间框：0 = 从框，1 = 到框
  int _lastFocusedTime = 0;

  @override
  void initState() {
    super.initState();
    _sizeMinCtrl.text = _fmtMb(widget.filterSizeMinMb);
    _sizeMaxCtrl.text = _fmtMb(widget.filterSizeMaxMb);
    _timeFromCtrl.text = _fmtDt(widget.filterTimeFrom);
    _timeToCtrl.text = _fmtDt(widget.filterTimeTo);
    _timeFromFocus.addListener(() {
      if (_timeFromFocus.hasFocus) _lastFocusedTime = 0;
    });
    _timeToFocus.addListener(() {
      if (_timeToFocus.hasFocus) _lastFocusedTime = 1;
    });
  }

  @override
  void didUpdateWidget(covariant _AdvancedOverlayContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 之前按 filterXxx 是否为 null 清框：输入/退格一旦停在解析失败的
    // 中间态（秒只有一位、大小敲到 "."），值变 null 就被当成"外部清空"，
    // 整框文字瞬间消失。改令牌：只在真正清空时自增，普通编辑一律不碰文本。
    if (widget.clearToken == oldWidget.clearToken) return;
    _sizeMinCtrl.clear();
    _sizeMaxCtrl.clear();
    _timeFromCtrl.clear();
    _timeToCtrl.clear();
  }

  GlobalKey _keyFor(int i) => _btnKeys.putIfAbsent(i, () => GlobalKey());

  Duration _fx(int ms) => MediaQuery.of(context).disableAnimations
      ? Duration.zero
      : Duration(milliseconds: ms);

  // A1：Tween / Curve 必须是同一个对象。TweenAnimationBuilder 用对象
  // identity 判断「要不要重播」，每敲一个字就新建会闪成一片。
  static final Tween<double> _kStaggerTween =
      Tween<double>(begin: 0, end: 1);
  static final List<Curve> _kStaggerCurves = <Curve>[
    Interval(0.0, 1.0, curve: Curves.easeOutCubic),
    Interval(0.12, 1.0, curve: Curves.easeOutCubic),
    Interval(0.24, 1.0, curve: Curves.easeOutCubic),
    Interval(0.36, 1.0, curve: Curves.easeOutCubic),
  ];

  /// A1 / F2：面板里几行依次错开淡入（约 60ms 一档）。
  Widget _stagger(int i, Widget child) {
    final idx = i < _kStaggerCurves.length ? i : _kStaggerCurves.length - 1;
    return TweenAnimationBuilder<double>(
      tween: _kStaggerTween,
      duration: _fx(420),
      curve: _kStaggerCurves[idx],
      builder: (_, v, c) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, -8 * (1 - v)),
          child: c,
        ),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.visible,
      builder: (ctx, open, _) {
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !open,
                child: GestureDetector(
                  onTap: _handleOutsideTap,
                  behavior: HitTestBehavior.translucent,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            Positioned(
              left: widget.panelLeft,
              top: widget.panelTop,
              width: widget.panelWidth,
              // A1 / F2：从搜索框下沿「卷」下来，顶边钉死。
              // 只动高度，绝不改 Positioned 的 top，否则会脱离搜索框。
              child: ClipRect(
                child: AnimatedSize(
                  alignment: Alignment.topCenter,
                  duration: _fx(320),
                  curve: Curves.easeOutCubic,
                  child: open
                      ? _buildPanel()
                      : const SizedBox(
                          width: double.infinity,
                          height: 0,
                        ),
                ),
              ),
            ),
            if (open && _openMenuIndex != null) _buildMenu(),
          ],
        );
      },
    );
  }

  void _handleOutsideTap() {
    if (_openMenuIndex != null) {
      setState(() => _openMenuIndex = null);
    } else {
      widget.onClose();
    }
  }

  Widget _buildPanel() {
    final hasAny = widget.conditions.any((c) => c.text.trim().isNotEmpty) ||
        widget.filterSizeMinMb != null ||
        widget.filterSizeMaxMb != null ||
        widget.filterTimeFrom != null ||
        widget.filterTimeTo != null;
    final cs = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      color: cs.surface,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.5,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _stagger(0, _addClearRow(hasAny)),
            if (widget.conditions.isEmpty)
              _stagger(1, const SizedBox(height: 8))
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  itemCount: widget.conditions.length,
                  itemBuilder: (_, i) => _stagger(2 + i, _row(i)),
                ),
              ),
            _stagger(3, _buildSizeTimeSection()),
            _stagger(4, _submitButton(hasAny)),
          ],
        ),
      ),
    );
  }

  Widget _buildSizeTimeSection() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 6),
          Text('文件大小（MB，可留空）',
              style: TextStyle(fontSize: 13, color: cs.onSurface)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                  child: _numField(_sizeMinCtrl, '最小', (_) => _notifySize())),
              const SizedBox(width: 8),
              Expanded(
                  child: _numField(_sizeMaxCtrl, '最大', (_) => _notifySize())),
              const SizedBox(width: 8),
              _textClearButton('清空', _clearSize),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text('修改时间（精确到秒，可留空）',
                    style: TextStyle(fontSize: 13, color: cs.onSurface)),
              ),
              _nowButton(),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(
                width: 76,
                child: Text('开始时间',
                    style: TextStyle(fontSize: 13, color: cs.onSurface)),
              ),
              Expanded(
                  child: _dateField(_timeFromCtrl,
                      focusNode: _timeFromFocus)),
              const SizedBox(width: 8),
              _textClearButton('清空', () => _clearTime(from: true)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(
                width: 76,
                child: Text('结束时间',
                    style: TextStyle(fontSize: 13, color: cs.onSurface)),
              ),
              Expanded(
                  child: _dateField(_timeToCtrl,
                      focusNode: _timeToFocus)),
              const SizedBox(width: 8),
              _textClearButton('清空', () => _clearTime(from: false)),
            ],
          ),
          const SizedBox(height: 2),
        ],
      ),
    );
  }

  Widget _numField(
      TextEditingController ctrl, String hint, ValueChanged<String> onCh) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 34,
      child: TextField(
        controller: ctrl,
        onChanged: onCh,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(fontSize: 14),
        cursorColor: cs.primary,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(color: cs.onSurfaceVariant),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: cs.primary, width: 1.5),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }

  Widget _dateField(TextEditingController ctrl, {FocusNode? focusNode}) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 34,
      child: TextField(
        controller: ctrl,
        focusNode: focusNode,
        onChanged: (_) => _notifyTime(),
        style: const TextStyle(fontSize: 13),
        cursorColor: cs.primary,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'y-m-d h:m:s',
          hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: cs.primary, width: 1.5),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        ),
      ),
    );
  }

  Widget _nowButton() {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 34,
      child: TextButton(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: cs.onSurfaceVariant),
          ),
        ),
        onPressed: _fillNow,
        child: Text('填入此刻', style: TextStyle(fontSize: 13, color: cs.primary)),
      ),
    );
  }

  // 点击「填入此刻」：把当前时间（精确到秒）填入光标最后所在的时间框。
  void _fillNow() {
    final txt = _fmtDt(DateTime.now());
    final targetCtrl =
        _lastFocusedTime == 1 ? _timeToCtrl : _timeFromCtrl;
    targetCtrl.text = txt;
    _notifyTime();
    // 把焦点设回目标框，光标归位，方便继续改。
    (_lastFocusedTime == 1 ? _timeToFocus : _timeFromFocus).requestFocus();
  }

  void _notifySize() {
    widget.onSizeChanged(
        _parseMb(_sizeMinCtrl.text), _parseMb(_sizeMaxCtrl.text));
  }

  void _notifyTime() {
    widget.onTimeChanged(
        _parseDt(_timeFromCtrl.text), _parseDt(_timeToCtrl.text));
  }

  // 文字「清空」按钮（无图标）。
  Widget _textClearButton(String label, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 34,
      child: TextButton(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: cs.onSurfaceVariant),
          ),
        ),
        onPressed: onTap,
        child: Text(label, style: TextStyle(fontSize: 13, color: cs.error)),
      ),
    );
  }

  void _clearSize() {
    _sizeMinCtrl.clear();
    _sizeMaxCtrl.clear();
    _notifySize();
  }

  void _clearTime({required bool from}) {
    if (from) {
      _timeFromCtrl.clear();
    } else {
      _timeToCtrl.clear();
    }
    _notifyTime();
  }

  // 点击「?」图标：解释整个高级搜索面板的用法。
  void _showAdvancedHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('高级搜索说明'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('【关键词条件】',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              Text('• 或者：文件名包含任意一个关键词即可（命中一个就行）。\n'
                  '• 同时：文件名必须同时包含所有关键词。\n'
                  '• 排除：文件名不能包含该关键词。\n'
                  '可点条件左侧的按钮切换「或者 / 同时 / 排除」，并添加多行组合。'),
              SizedBox(height: 10),
              Text('【文件大小】',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              Text('• 单位为 MB，填 5 即 5MB。\n'
                  '• 最小 / 最大均可单独留空：只填最小 → 搜「≥该值」；只填最大 → 搜「≤该值」；都填 → 区间内。\n'
                  '• 文件夹没有大小，任何大小筛选都会把文件夹排除。'),
              SizedBox(height: 10),
              Text('【修改时间】',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              Text('• 格式 y-m-d h:m:s，精确到秒。\n'
                  '• 开始 / 结束均可单独留空：只填开始 → 搜「该时间之后」；只填结束 → 搜「该时间之前」；都填 → 区间内。均为闭区间（含端点）。\n'
                  '• 时间对文件和文件夹都生效。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  double? _parseMb(String s) {
    s = s.trim();
    if (s.isEmpty) return null;
    return double.tryParse(s);
  }

  DateTime? _parseDt(String s) {
    s = s.trim();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  String _fmtMb(double? v) =>
      v == null ? '' : (v == v.roundToDouble() ? v.round().toString() : v.toString());

  String _fmtDt(DateTime? d) {
    if (d == null) return '';
    return '${d.year}-${_two(d.month)}-${_two(d.day)} '
        '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
  }

  Widget _row(int i) {
    final cond = widget.conditions[i];
    return Padding(
      padding: const EdgeInsets.only(left: 3, right: 1, top: 3, bottom: 3),
      child: Row(
        children: [
          _operatorBtn(i, cond),
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: cond.controller,
                onChanged: (_) => widget.onChanged(),
                style: const TextStyle(fontSize: 14),
                cursorColor: Theme.of(context).colorScheme.primary,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '输入文字',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 1.5,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 28,
            height: 36,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: Icon(Icons.close,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              tooltip: '删除此条件',
              onPressed: () => _remove(i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _operatorBtn(int i, _SearchCondition cond) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      key: _keyFor(i),
      width: 68,
      height: 36,
      child: Material(
        color: cs.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _toggleMenu(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _label(cond.operator),
                  style: TextStyle(fontSize: 13, color: cs.onSurface),
                ),
                Icon(Icons.arrow_drop_down,
                    size: 18, color: cs.onSurface),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toggleMenu(int i) {
    setState(() {
      _openMenuIndex = (_openMenuIndex == i) ? null : i;
    });
  }

  void _selectOperator(int i, _SearchOperator op) {
    setState(() {
      widget.conditions[i].operator = op;
      _openMenuIndex = null;
    });
    widget.onChanged();
  }

  void _add() {
    setState(() {
      widget.conditions
          .add(_SearchCondition(operator: _SearchOperator.or));
      _btnKeys.clear();
    });
    widget.onChanged();
  }

  void _remove(int i) {
    if (i < 0 || i >= widget.conditions.length) return;
    setState(() {
      if (_openMenuIndex == i) _openMenuIndex = null;
      widget.conditions[i].dispose();
      widget.conditions.removeAt(i);
      _btnKeys.clear();
    });
    widget.onChanged();
  }

  Widget _buildMenu() {
    final i = _openMenuIndex!;
    if (i < 0 || i >= widget.conditions.length) {
      return const SizedBox.shrink();
    }
    final key = _keyFor(i);
    final btnBox = key.currentContext?.findRenderObject() as RenderBox?;
    if (btnBox == null) return const SizedBox.shrink();
    final btnPos = btnBox.localToGlobal(Offset.zero);
    final top = btnPos.dy + btnBox.size.height + 2;
    final left = btnPos.dx;

    return Positioned(
      left: left,
      top: top,
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.surface,
        child: SizedBox(
          width: 210,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _menuItem(i, _SearchOperator.or, '或者', '命中一个就行'),
              _menuItem(i, _SearchOperator.and, '同时', '必须都出现'),
              _menuItem(i, _SearchOperator.not, '排除', '不要这个'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuItem(
      int i, _SearchOperator op, String label, String hint) {
    final cs = Theme.of(context).colorScheme;
    final selected = widget.conditions[i].operator == op;
    return InkWell(
      onTap: () => _selectOperator(i, op),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: selected
                  ? Icon(Icons.check,
                      size: 16, color: cs.primary)
                  : null,
            ),
            Text(label,
                style: TextStyle(
                    fontSize: 14, color: cs.onSurface)),
            const SizedBox(width: 12),
            Text(hint,
                style: TextStyle(
                    fontSize: 12, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _addClearRow(bool hasAny) {
    final cs = Theme.of(context).colorScheme;
    // 「清空条件」只清文字条件，按"是否有文字条件"决定可点状态。
    final hasTextConditions =
        widget.conditions.any((c) => c.text.trim().isNotEmpty);
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 12, 3, 0),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: FilledButton(
                onPressed: _add,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  '＋ 添加条件',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 40,
              child: Material(
                color: cs.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: hasTextConditions ? widget.onClearConditions : null,
                  child: Center(
                    child: Text(
                      '🗑 清空条件',
                      style: TextStyle(
                        fontSize: 13,
                        color: hasTextConditions
                            ? cs.onSurface
                            : cs.onSurfaceVariant.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(Icons.help_outline,
                size: 22, color: cs.onSurfaceVariant),
            tooltip: '高级搜索说明',
            onPressed: () => _showAdvancedHelp(context),
          ),
        ],
      ),
    );
  }

  Widget _submitButton(bool hasAny) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 12, 3, 10),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: hasAny ? widget.onClearAll : null,
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                  side: BorderSide(color: cs.onSurfaceVariant),
                ),
                child: Text(
                  '清空全部',
                  style: TextStyle(
                    fontSize: 15,
                    color: hasAny
                        ? cs.onSurface
                        : cs.onSurfaceVariant.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 44,
              child: FilledButton(
                onPressed: hasAny ? widget.onSubmit : null,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                ),
                child: const Text(
                  '搜索',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _sizeMinCtrl.dispose();
    _sizeMaxCtrl.dispose();
    _timeFromCtrl.dispose();
    _timeToCtrl.dispose();
    _timeFromFocus.dispose();
    _timeToFocus.dispose();
    super.dispose();
  }

  String _label(_SearchOperator op) {
    switch (op) {
      case _SearchOperator.or:
        return '或者';
      case _SearchOperator.and:
        return '同时';
      case _SearchOperator.not:
        return '排除';
    }
  }
}
// ==================== 统一列表项 ====================

class _DisplayItem {
  const _DisplayItem({
    required this.key,
    required this.displayName,
    required this.depth,
    this.isDir = false,
    this.isZip = false,
    this.isArchive = false,
    this.isZipInner = false,
    this.size,
    this.modified,
    this.diskEntry,
    this.searchHit,
    this.ownerZipKey,
    this.innerPath,
    this.innerPathForDisplay,
    this.innerArchive,
  });

  final String key;
  final String displayName;
  final int depth;

  final bool isDir;
  final bool isZip;
  final bool isArchive;
  final bool isZipInner;

  final int? size;
  final DateTime? modified;

  final EntryInfo? diskEntry;
  final _SearchHit? searchHit;

  final String? ownerZipKey;
  final String? innerPath;
  final String? innerPathForDisplay;
  final Archive? innerArchive;

  bool get isDiskItem => diskEntry != null || searchHit != null;
  bool get canExpand => isZip;
  String? get diskPath => diskEntry?.path ?? searchHit?.path;

  String get fullDisplayPath {
    if (ownerZipKey == null) return displayName;
    final zipName = ownerZipKey!.split('/').last;
    final inner = innerPathForDisplay ?? displayName;
    return '$zipName > $inner';
  }
}

// ==================== 虚拟 key 工具 ====================

const String _zipInnerPrefix = 'zip://';
const String _zipInnerSep = '§';

bool _isZipInnerKey(String key) => key.startsWith(_zipInnerPrefix);

String _makeZipInnerKey(String zipPath, String innerPath) =>
    '$_zipInnerPrefix$zipPath$_zipInnerSep$innerPath';

String _zipPathFromInnerKey(String key) {
  final body = key.substring(_zipInnerPrefix.length);
  final idx = body.indexOf(_zipInnerSep);
  return idx < 0 ? body : body.substring(0, idx);
}

String _innerPathFromInnerKey(String key) {
  final body = key.substring(_zipInnerPrefix.length);
  final idx = body.indexOf(_zipInnerSep);
  return idx < 0 ? '' : body.substring(idx + _zipInnerSep.length);
}

// ==================== 判断 zip / tar 文件名 ====================

bool _isExpandableArchiveName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz');
}

/// 比 [_isExpandableArchiveName] 宽：凡是"归档/压缩"类文件都画成压缩包图标，
/// 仅影响显示，不改变"能否解压"。覆盖 .rar/.7z/.gz/.bz2/.xz/.iso/.apk 等
/// 应用暂不支持解压、但外观上应识别为压缩包的格式。
bool _isArchiveName(String name) {
  if (_isExpandableArchiveName(name)) return true; // .zip/.tar/.tar.gz/.tgz
  const extras = {
    '.rar', '.7z', '.gz', '.bz2', '.xz', '.iso',
    '.cab', '.lz', '.lzma', '.zst', '.apk', '.apks', '.xapk', '.aab',
  };
  final lower = name.toLowerCase();
  for (final e in extras) {
    if (lower.endsWith(e)) return true;
  }
  return false;
}

// ==================== 从 archive 里读直接子节点 ====================

class _ZipNode {
  const _ZipNode({
    required this.name,
    required this.fullPath,
    required this.isDir,
    required this.isZip,
    required this.size,
  });

  final String name;
  final String fullPath;
  final bool isDir;
  final bool isZip;
  final int size;
}

List<_ZipNode> _directZipChildren(Archive archive, String at) {
  final prefix = at.isEmpty ? '' : '$at/';
  final dirNames = <String>{};
  final fileMap = <String, ArchiveFile>{};

  for (final f in archive.files) {
    final name = f.name;
    if (name.isEmpty) continue;
    if (name.startsWith('__MACOSX/')) continue;
    if (!name.startsWith(prefix)) continue;
    final rest = name.substring(prefix.length);
    if (rest.isEmpty) continue;

    final slash = rest.indexOf('/');
    if (slash < 0) {
      if (f.isFile) {
        fileMap[rest] = f;
      } else {
        dirNames.add(rest);
      }
    } else {
      dirNames.add(rest.substring(0, slash));
    }
  }

  final out = <_ZipNode>[];
  for (final name in dirNames) {
    out.add(_ZipNode(
      name: name,
      fullPath: '$prefix$name',
      isDir: true,
      isZip: false,
      size: 0,
    ));
  }
  for (final e in fileMap.entries) {
    final name = e.key;
    out.add(_ZipNode(
      name: name,
      fullPath: '$prefix$name',
      isDir: false,
      isZip: _isExpandableArchiveName(name),
      size: e.value.size,
    ));
  }

  out.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

// ==================== 主状态类（开始） ====================

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen>
    with RouteAware, SingleTickerProviderStateMixin {
  static const String _rootPath = '/storage/emulated/0';
  static const String _topPath = '/storage';

  static const EdgeInsets _dlgInset = EdgeInsets.all(4);
  static const EdgeInsets _dlgTitlePad =
      EdgeInsets.fromLTRB(12, 8, 12, 0);
  static const EdgeInsets _dlgContentPad = EdgeInsets.fromLTRB(8, 4, 8, 4);
  static const EdgeInsets _dlgActionsPad =
      EdgeInsets.fromLTRB(4, 0, 4, 4);

  static const double _gridCellPadH = 8.0;
  static const double _gridCellPadV = 6.0;
  static const double _gridDividerThickness = 0.5;

  static const Set<String> _textExts = {
    '.txt', '.md', '.markdown', '.log', '.lst', '.diz', '.nfo',
    '.json', '.xml', '.yaml', '.yml', '.toml', '.ini', '.conf', '.cfg',
    '.csv', '.tsv',
    '.sh', '.bash', '.zsh', '.bat', '.cmd', '.ps1',
    '.py', '.js', '.ts', '.java', '.kt', '.dart', '.c', '.cpp', '.cc',
    '.h', '.hpp', '.cs', '.go', '.rs', '.rb', '.php', '.lua', '.smali',
    '.html', '.htm', '.css', '.scss',
    '.diff', '.patch',
  };

  static const Set<String> _binaryExts = {
    '.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm', '.m4v',
    '.3gp', '.mpg', '.mpeg', '.rmvb', '.rm', '.vob',
    '.mp3', '.flac', '.wav', '.aac', '.ogg', '.m4a', '.wma', '.ape',
    '.opus',
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.ico',
    '.tif', '.tiff', '.heic', '.raw',
    '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.iso',
    '.cab', '.lz', '.lzma', '.zst', '.apk', '.apks', '.xapk', '.aab',
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.odt', '.ods', '.odp', '.epub', '.mobi', '.azw', '.azw3',
    '.exe', '.dll', '.so', '.bin', '.img', '.db', '.sqlite', '.mdb',
  };
static const Set<String> _imageExts = {
  '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.ico',
  '.tif', '.tiff', '.heic', '.raw',
};

static const Set<String> _videoExts = {
  '.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm', '.m4v',
  '.3gp', '.mpg', '.mpeg', '.rmvb', '.rm', '.vob',
};

static const Set<String> _audioExts = {
  '.mp3', '.flac', '.wav', '.aac', '.ogg', '.m4a', '.wma', '.ape',
  '.opus',
};

static const Set<String> _archiveExts = {
  '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.iso',
  '.cab', '.lz', '.lzma', '.zst', '.apk', '.apks', '.xapk', '.aab',
};
  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    if (i <= 0 || i == name.length - 1) return '';
    return name.substring(i).toLowerCase();
  }

  // 图标颜色不再由这里决定：默认皮肤用 AppFileIcon 的品牌渐变，
  // 其他皮肤回退 Material 图标；zip 内的次要条目通过 tint 参数弱化。

  Color _gridDividerColorOf(BuildContext context) =>
      Theme.of(context).colorScheme.outlineVariant;

  // ==================== 状态字段 ====================

  late String _currentPath;
  List<EntryInfo>? _entries;
  bool _loading = false;
  bool _showSkeleton = false;
  Timer? _skeletonTimer;
  int _bodyRevision = 0; // 每次切目录 +1，用来强制 AnimatedSwitcher 重建
  String? _error;

  LoadCancelToken? _loadCancelToken;

  final TextEditingController _searchCtrl = TextEditingController();

  /// 搜索输入框的焦点节点。
  /// 用于：展开搜索栏时自动聚焦；监听聚焦变化以刷新边框/标签颜色。
  final FocusNode _searchFocus = FocusNode();

  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();

  final Map<String, int> _dirScrollPositions = {};

  /// 下次列表体首次挂载时使用的初始滚动下标；在 build 里被消费（置 null），
  /// 因此只在「切换目录 / 重载」后的第一次挂载生效一次，后续 build 传 0 不影响已挂载的列表。
  /// 相比 postFrameCallback 的 jumpTo，它让列表第一次 layout 就落在正确位置，
  /// 不会有「先渲染第 0 行再跳」的一帧闪烁。
  int? _initialScrollIndex;

  /// 每次切换目录 / 重载递增，作为列表体 key 的一部分，强制 [ScrollablePositionedList]
  /// 重新挂载，从而让上面的 [initialScrollIndex] 重新生效。
  int _listGeneration = 0;

  /// 正在恢复滚动位置时置 true，临时抑制 [_recordCurrentScroll]，
  /// 避免路径锚点 jump 的瞬间把已存的滚动位置覆盖成跳转目标之外的值。
  bool _restoringScroll = false;

  /// 子页面打开后要定位的文件：是否已处理、当前高亮的路径及计时器。
  bool _revealHandled = false;
  String? _flashPath;
  Timer? _flashTimer;

  /// 「刚才去过的那一项」。
  ///
  /// 从编辑器 / 阅读器返回，或进入一个文件夹再退回上级时，
  /// 用它把那一项标出来（淡色底 + 左侧一条竖杠），
  /// 让用户一眼看到自己刚才在哪个位置——不用再回想、不用再找。
  ///
  /// 存的是完整路径而不是下标：路径全局唯一，回到哪个目录都不用换算，
  /// 而且列表重排 / 刷新后依然对得上。当前目录里没有这一项时自然就不显示。
  String? _lastVisitedPath;

  /// 「刚才去过」高亮的渐隐动画。出现即开始 ~700ms 由满色淡到透明，
  /// 结束自动把 [_lastVisitedPath] 置空，彻底消失。
  /// 用户要求：高亮不能一直挂着，要自动变浅消失（最长 1 秒）。
  late final AnimationController _visitedFadeCtrl;
  late final Animation<double> _visitedFade; // 1.0（最浓）→ 0.0（透明）

  /// 当前列表（网格模式按行算）的条目总数，供自定义滚动条与翻页按钮使用。
  /// 每次构建列表时刷新；非列表状态（加载中/空目录/出错）置 0。
  int _scrollItemCount = 0;

  bool _selectionMode = false;
  final Set<String> _selectedPaths = <String>{};
  String? _anchorPath;

  List<_SearchHit> _searchResults = <_SearchHit>[];
  bool _searching = false;
  bool _searchActive = false;
  int _searchTaskId = 0;
  DateTime _lastUiRefresh = DateTime.now();

  // ★ 新增：最近一次整行点击的 x 坐标（相对行左边）。
  // 用来判断点的是不是左侧图标区（图标区点=选中，其它=打开）。
  double _lastTapX = double.infinity;
// ==================== 高级搜索条件状态 ====================
bool _advancedOpen = false;
final List<_SearchCondition> _searchConditions = [];
final GlobalKey _searchBarBoxKey = GlobalKey();
final GlobalKey _searchInputKey = GlobalKey();
OverlayEntry? _advancedOverlay;
// A1 / F2：面板的「展开 / 收起」开关。收起时先让它把高度动画播完，
// 再由 _advancedCloseTimer 延后 remove()，避免「啪」一下消失。
ValueNotifier<bool>? _advancedPanelVisible;
Timer? _advancedCloseTimer;

// 高级搜索 · 大小 / 时间筛选（允许主框留空，仅按大小或时间搜）
double? _filterSizeMinMb;
double? _filterSizeMaxMb;
DateTime? _filterTimeFrom;
DateTime? _filterTimeTo;

// 悬浮菜单（顶栏「更多」和多选底栏「⋯」共用）：
// 不套任何底板，只在锚点旁竖排一列圆角按钮。
// 锚点 key / OverlayEntry 都是本页实例自己的（父子页面会同时挂载），不要挪到文件级。
final GlobalKey _appBarMoreAnchorKey = GlobalKey();
final GlobalKey _bottomMoreAnchorKey = GlobalKey();
OverlayEntry? _floatingMenuEntry;
// C1 / M5：菜单显隐开关。做成 State 常驻字段而不是 Overlay 里的局部对象，
// 因为 entry.remove() 后 ValueListenableBuilder 要到下一帧才卸载，
// 局部 notifier 若提前 dispose 会触发 debug 断言。
final ValueNotifier<bool> _menuVisible = ValueNotifier<bool>(false);
OverlayEntry? _menuEntryClosing;
Timer? _menuCloseTimer;
bool _menuClosing = false;
String _menuAnchor = ''; // 'top' = 顶栏三点，'bottom' = 底栏三点


  // ==================== zip 展开状态 ====================

  final Set<String> _expandedZipKeys = <String>{};
  final Map<String, Archive> _zipArchives = <String, Archive>{};
  final Set<String> _loadingZipKeys = <String>{};
  final Set<String> _encryptedNestedZipKeys = <String>{};
  final Map<String, String> _zipErrors = <String, String>{};

  /// ★ 粘性头部已停用，此字段保留但始终为 null。
String? _stickyZipKey;

// ==================== 过滤状态 ====================

int _filterTaskId = 0;

// 高级面板「清空全部」令牌：只在真正清空时自增。
// 用户编辑/退格到解析失败的中间态时值不变，输入框文字不会被整框抹掉。
int _advancedClearToken = 0;
List<_DisplayItem>? _visibleItems;
List<_DisplayItem>? _cachedDisplayItems;
List<String?>? _cachedOwnerZipPerIndex;

  static const int _maxZipBytes = 50 * 1024 * 1024;

  static const Set<String> _forceSystemPickerExts = {
    '.7z', '.rar', '.dzip', '.iso', '.tz', '.gz',
    '.epub', '.pdf', '.doc', '.docx',
  };

	/// 单次展开中，所有嵌套 zip 解压后的累计大小上限。
/// _maxZipBytes 只限制顶层 zip 磁盘大小，拦不住"小包大解压"
/// 和"嵌套 zip 层层解压"。这里累计统计解压后内容，超限停手。
static const int _maxTotalDecodedBytes = 200 * 1024 * 1024;
static const int _searchMaxDepth = 1000;

/// 本次展开中已累计的解压字节数。
int _expandedDecodedBytes = 0;

  // ==================== 生命周期 ====================

  
  @override
void initState() {
  super.initState();
  // 「刚才去过」高亮的渐隐：每帧重绘让底色 / 竖杠变浅，结束后清掉 path。
  _visitedFadeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  _visitedFade = Tween<double>(begin: 1.0, end: 0.0).animate(
    CurvedAnimation(parent: _visitedFadeCtrl, curve: Curves.easeOut),
  );
  _visitedFadeCtrl.addListener(() {
    if (mounted) setState(() {});
  });
  _visitedFadeCtrl.addStatusListener((status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _lastVisitedPath = null);
    }
  });
  // 清掉上次会话遗留的 zip 内临时文件。
  // 不 await：后台跑，不阻塞启动。子页面不重复清理，避免误删主页面正在用的临时文件。
  if (widget.initialPath == null) _cleanTempDirOnce();
  final saved = widget.initialPath ?? ref.read(lastPathProvider);
  _currentPath = _resolveInitialPath(saved);
  _positionsListener.itemPositions.addListener(_onPositionsChanged);
  _searchFocus.addListener(_onSearchFocusChanged);
  _load();
}

void _onSearchFocusChanged() {
  if (mounted) setState(() {});
}

/// 清空 systemTemp 里所有 zzz_ 前缀的文件。
/// 这个前缀专门标记 App 自己写的临时文件，避免误删别人的东西。
Future<void> _cleanTempDirOnce() async {
  try {
    final dir = Directory.systemTemp;
    if (!await dir.exists()) return;
    var n = 0;
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.path.split('/').last;
      if (!name.startsWith('zzz_')) continue;
      try {
        await e.delete();
        n++;
      } catch (_) {}
    }
    if (n > 0) {
      ReaderLoadLog.instance.info('[TempCleanup] 清理 $n 个临时文件');
    }
  } catch (_) {}
}

  String _resolveInitialPath(String? saved) {
    if (saved == null || saved.isEmpty) return _rootPath;
    if (!saved.startsWith(_topPath)) return _rootPath;
    if (!Directory(saved).existsSync()) return _rootPath;
    return saved;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      fileBrowserRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void dispose() {
    fileBrowserRouteObserver.unsubscribe(this);
    _visitedFadeCtrl.dispose();
    _skeletonTimer?.cancel();
    _flashTimer?.cancel();
    _loadCancelToken?.cancel();
    _positionsListener.itemPositions.removeListener(_onPositionsChanged);
  _searchFocus.removeListener(_onSearchFocusChanged);
  _searchFocus.dispose();
  _searchCtrl.dispose();
  _advancedCloseTimer?.cancel();
  _advancedOverlay?.remove();
  _advancedOverlay = null;
  // C1：菜单相关的计时器 / 待删 entry 一起清掉。
  _menuCloseTimer?.cancel();
  final closing = _menuEntryClosing;
  _menuEntryClosing = null;
  if (closing != null) closing.remove();
  _floatingMenuEntry?.remove();
  _floatingMenuEntry = null;
  // 故意不 dispose _menuVisible：Overlay 里的 ValueListenableBuilder
  // 要到下一帧才卸载，提前 dispose 会触发 debug 断言。
  for (final c in _searchConditions) {
    c.dispose();
  }
  _searchConditions.clear();
  super.dispose();
}

  Route<T> _noAnimRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );
  }

  // ==================== 悬浮圆角按钮菜单 ====================

  static const TextStyle _chipLabelStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
  );

  /// 悬浮菜单（顶栏「更多」/ 多选底栏「⋯」）选项按钮专用样式：
  /// 默认皮肤：背景统一为 #F4F5F7、主题蓝字、无描边（保持原样不动）。
  /// 自定义皮肤：与底栏第一行「复制路径 / 分享」按钮完全一致
  /// （同色系 surface 底 + outline 描边，字色 onSurface、字号 12/w500），
  /// 不再用统一的 #F4F5F7 灰底。
  /// 悬浮菜单选项的高度：统一锁定为与底栏「复制路径 / 分享」按钮相同的 38，
  /// 这样自定义皮肤（按钮 padding 更小）下也不会显得比底栏按钮矮一截。
  static const double _menuChipHeight = 38.0;

  ButtonStyle _menuChipStyle() {
    final s = Theme.of(context).colorScheme;
    final isDefaultSkin = ref.watch(skinProvider) == AppSkin.defaultBlue;
    // 锁高 38，并去掉默认 64×40 的最小尺寸干扰（否则短标签会被默认最小宽度撑开）。
    const minSize = WidgetStatePropertyAll(Size(0, _menuChipHeight));
    const shrink = MaterialTapTargetSize.shrinkWrap;
    if (isDefaultSkin) {
      return OutlinedButton.styleFrom(
        minimumSize: const Size(0, _menuChipHeight),
        tapTargetSize: shrink,
        // 竖向留白 16→4 缩小高度：内容高度落到 38 以下，由 minimumSize 38 兜底
        // 撑成与底栏第一行按钮同高（底栏固定 38，保持不动）。横向留白仍 16，与底栏一致。
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        foregroundColor: s.primary,
        backgroundColor: const Color(0xFFF4F5F7),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      );
    }
    // 自定义皮肤：复用「复制路径 / 分享」样式，竖向留白 16→4 缩小高度，
    // 再锁高 38 与底栏按钮对齐（底栏固定 38，保持不动）。
    // 注意：ButtonStyle.copyWith 的 tapTargetSize 是普通值 MaterialTapTargetSize?，
    // 不是 WidgetStateProperty，因此直接传 shrink，不能包 WidgetStatePropertyAll。
    return _softChipStyle(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ).copyWith(
      minimumSize: minSize,
      tapTargetSize: shrink,
    );
  }

  /// 与多选底栏「复制路径 / 分享」完全一致的按钮样式（正方形 16:16 留白）。
  ButtonStyle _softChipStyle({EdgeInsets? padding}) {
    final s = Theme.of(context).colorScheme;
    final isDefaultSkin = ref.watch(skinProvider) == AppSkin.defaultBlue;
    return OutlinedButton.styleFrom(
      padding: padding ??
          const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      foregroundColor: isDefaultSkin ? s.primary : s.onSurface,
      // 悬浮菜单直接压着文件列表，底必须不透明，否则文字和文件名叠在一起。
      // 默认皮肤：底色用 #F4F5F7，与三个点弹出的「反选 / 打开方式」菜单项完全一致；
      // 自定义皮肤：底色等于 surface（同色系），视觉上和原来的透明一致。
      backgroundColor:
          isDefaultSkin ? const Color(0xFFF4F5F7) : s.surface,
      side: isDefaultSkin ? BorderSide.none : BorderSide(color: s.outline),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
    );
  }

  Widget _menuChip({
    required String label,
    required ButtonStyle style,
    Widget? icon,
    VoidCallback? onPressed,
  }) {
    return OutlinedButton(
      style: style,
      onPressed: onPressed == null
          ? null
          : () {
              _closeFloatingMenu();
              onPressed();
            },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            icon,
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: _chipLabelStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// C1 / M5：把「正在播收起动画」的 entry 立刻清掉。
  /// 连续开关菜单时必须先做这一步，否则旧 entry 会永远留在 Overlay 里。
  void _removeClosingMenuEntry() {
    _menuCloseTimer?.cancel();
    _menuCloseTimer = null;
    final e = _menuEntryClosing;
    _menuEntryClosing = null;
    _menuClosing = false;
    // 字段守卫已经保证「一个 entry 只会被 remove 一次」，
    // 不依赖 OverlayEntry.mounted 这个 API。
    if (e != null) e.remove();
  }

  void _closeFloatingMenu({bool immediate = false}) {
    _removeClosingMenuEntry();
    final entry = _floatingMenuEntry;
    // 先把字段置空：PopScope.canPop 立刻恢复，返回键不会被卡住。
    _floatingMenuEntry = null;
    _menuVisible.value = false; // 反向播收起
    if (entry == null) {
      if (mounted) setState(() {});
      return;
    }
    final bool animate =
        !immediate && !MediaQuery.of(context).disableAnimations;
    if (!animate) {
      entry.remove();
    } else {
      // 动作（打开方式 / 属性…）立刻执行，只有视觉层延后消失。
      _menuEntryClosing = entry;
      _menuClosing = true;
      _menuCloseTimer = Timer(_fx(220), () {
        _removeClosingMenuEntry();
        if (mounted) setState(() {});
      });
    }
    // 菜单开关会影响 PopScope 的 canPop（返回键要先关菜单），需要重建一次。
    if (mounted) setState(() {});
  }

  /// 在 [anchorKey] 旁弹出竖排菜单。
  /// [above] 为 true 时向上展开（底栏「⋯」），否则向下展开（顶栏「更多」）。
  /// [isDefaultSkin] 为 true 时遮罩完全透明（默认皮肤不压暗页面），
  /// 为 false 时遮罩压暗约 4%（自定义皮肤保持原观感）。
  void _showFloatingMenu({
    required GlobalKey anchorKey,
    required List<Widget> items,
    required bool above,
    required bool isDefaultSkin,
  }) {
    // 连续点两个三点时，先把上一轮还在播收起动画的 entry 清掉。
    _closeFloatingMenu(immediate: true);
    final anchorContext = anchorKey.currentContext;
    if (anchorContext == null) return;
    final overlayState = Overlay.of(context);
    final overlayBox =
        overlayState.context.findRenderObject() as RenderBox?;
    final anchorBox = anchorContext.findRenderObject() as RenderBox?;
    if (overlayBox == null || anchorBox == null || !anchorBox.hasSize) return;

    final anchorTopLeft =
        anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final anchorSize = anchorBox.size;
    final overlaySize = overlayBox.size;
    const gap = 6.0;
    const margin = 8.0;
    final right = math.max(
      margin,
      overlaySize.width - anchorTopLeft.dx - anchorSize.width,
    );
    final maxHeight = above
        ? anchorTopLeft.dy - gap - margin
        : overlaySize.height -
            anchorTopLeft.dy -
            anchorSize.height -
            gap -
            margin;

    _menuAnchor = above ? 'bottom' : 'top';
    _menuVisible.value = false;

    _floatingMenuEntry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // C1 / M5：遮罩淡入淡出；收起期间立刻停止命中测试，
          // 否则这 220ms 会点不动下面的列表。
          Positioned.fill(
            child: ValueListenableBuilder<bool>(
              valueListenable: _menuVisible,
              builder: (_, open, __) => IgnorePointer(
                ignoring: !open,
                child: AnimatedOpacity(
                  opacity: open ? 1.0 : 0.0,
                  duration: _fx(220),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _closeFloatingMenu(),
                  child: ColoredBox(
                    // 默认皮肤：完全不压暗，页面保持原样（用户要求）。
                    // 非默认皮肤：压暗约 4%，保持原来「不套底板」的观感。
                    color: isDefaultSkin
                        ? Colors.transparent
                        : const Color(0x0A000000),
                    child: SizedBox.expand(),
                  ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: right,
            top: above ? null : anchorTopLeft.dy + anchorSize.height + gap,
            bottom:
                above ? overlaySize.height - anchorTopLeft.dy + gap : null,
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxHeight: math.max(80.0, maxHeight)),
              child: Material(
                // 透明 Material：只为按钮提供墨水和文字样式，不画底板。
                type: MaterialType.transparency,
                child: ValueListenableBuilder<bool>(
                  valueListenable: _menuVisible,
                  // 隐式动画首次构建直接显示终值，不会「先闪一帧」；
                  // 过冲只放在 scale 上，opacity 不过冲避免 >1 断言。
                  builder: (_, open, __) => IgnorePointer(
                    // 收起动画这 220ms 里别再响应点击，否则同一个
                    // 菜单项可能被连点两次、动作执行两遍。
                    ignoring: !open,
                    child: AnimatedOpacity(
                      opacity: open ? 1.0 : 0.0,
                      duration: _fx(open ? 220 : 180),
                      curve: open ? Curves.easeOutCubic : Curves.easeInCubic,
                      child: AnimatedScale(
                        scale: open ? 1.0 : 0.86,
                        duration: _fx(open ? 280 : 180),
                        curve: open
                            ? Curves.easeOutBack
                            : Curves.easeInCubic,
                        alignment: above
                            ? Alignment.bottomRight
                            : Alignment.topRight,
                        child: _FloatingMenuScroller(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (var i = 0; i < items.length; i++) ...[
                                if (i > 0) const SizedBox(height: 6),
                                _staggerMenuChip(i, items[i], above: above),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlayState.insert(_floatingMenuEntry!);
    // 先以 false 建一帧，下一帧再置 true，才有 0→1 的起点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _floatingMenuEntry != null) {
        _menuVisible.value = true;
      }
    });
    // 让 PopScope 的 canPop 立刻感知「菜单已打开」，返回键才会先关菜单。
    if (mounted) setState(() {});
  }

  /// 统一入口：顶栏按钮和三个点菜单都调它。
  Future<void> _dispatchTopBarAction(String id) async {
    switch (id) {
      case 'searchToggle':
        _toggleSearchBarCollapsed();
      case 'favorite':
        _toggleFavorite();
      case 'dedup':
        _onTapDedupButton();
      case 'comparisonRules':
        Navigator.of(context).push(_noAnimRoute(
          const ComparisonSettingsScreen(),
        ));
      case 'browserSettings':
        final beforeField = ref.read(sortFieldProvider);
        final beforeAsc = ref.read(sortAscProvider);
        await Navigator.of(context).push(_noAnimRoute(
          const BrowserSettingsScreen(),
        ));
        if (!mounted) return;
        final afterField = ref.read(sortFieldProvider);
        final afterAsc = ref.read(sortAscProvider);
        if (beforeField != afterField || beforeAsc != afterAsc) {
          DirCache.instance.invalidate(_currentPath);
          _load();
        }
      case 'configIo':
        _showConfigIoMenu();
      case 'refresh':
        DirCache.instance.invalidate(_currentPath);
        _load(skipCache: true);
      case 'jumpToPath':
        _showJumpToPathDialog();
      case 'jumpToTop':
        _jumpToTop();
      case 'dirInfo':
        _showDirInfoDialog();
      case 'favoritesList':
        _showFavorites();
      case 'newFolder':
        _newFolder();
      case 'help':
        Navigator.of(context).push(_noAnimRoute(const HelpScreen()));
      case 'sharedTrash':
        Navigator.of(context).push(_noAnimRoute(const SharedTrashPage()));
    }
  }

  // ==================== 滚动 → 粘性头部（已停用） ====================

  void _onPositionsChanged() {
    _recordCurrentScroll();
  }

  // ignore: unused_element
  void _updateStickyZip() {
    final items = _cachedDisplayItems;
    if (items == null || items.isEmpty) {
      if (_stickyZipKey != null) {
        setState(() => _stickyZipKey = null);
      }
      return;
    }

    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) {
      if (_stickyZipKey != null) {
        setState(() => _stickyZipKey = null);
      }
      return;
    }

    int topIdx = 1 << 30;
    for (final p in positions) {
      if (p.itemLeadingEdge <= 0.0 && p.index < topIdx) {
        topIdx = p.index;
      }
    }
    if (topIdx == 1 << 30) {
      if (_stickyZipKey != null) {
        setState(() => _stickyZipKey = null);
      }
      return;
    }

    final sticky = _computeStickyZipForIndex(topIdx, items);
    if (_stickyZipKey != sticky) {
      setState(() => _stickyZipKey = sticky);
    }
  }

  // ignore: unused_element
  String? _computeStickyZipForIndex(int topIdx, List<_DisplayItem> items) {
    if (topIdx < 0 || topIdx >= items.length) return null;
    final item = items[topIdx];
    if (item.isZip && item.ownerZipKey == null) return null;
    final owner = item.ownerZipKey;
    if (owner == null) return null;
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it.isZip && it.key == owner && it.ownerZipKey == null) {
        if (i < topIdx) return owner;
        return null;
      }
    }
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it.isZip && it.key == owner) {
        if (i < topIdx) return owner;
        return null;
      }
    }
    return null;
  }

  // ==================== 显示列表构建 ====================

  List<_DisplayItem> _buildDisplayItems() {
    final out = <_DisplayItem>[];

    if (_searchActive) {
      for (final hit in _searchResults) {
        final isZip = !hit.isDir && _isExpandableArchiveName(hit.name);
        final isArchive = !hit.isDir && _isArchiveName(hit.name);

        final key = hit.path;
       out.add(_DisplayItem(
  key: key,
  displayName: hit.name,
  depth: 0,
  isDir: hit.isDir,    // ★ 加这行
  isZip: isZip,
  isArchive: isArchive,
  size: hit.size,
  modified: hit.modified,
  searchHit: hit,
));
        if (isZip && _expandedZipKeys.contains(key)) {
          _appendZipChildren(
            out: out,
            zipDiskPath: key,
            zipArchive: _zipArchives[key],
            at: '',
            innerPrefix: '',
            parentOwnerKey: null,
            depth: 1,
            error: _zipErrors[key],
            loading: _loadingZipKeys.contains(key),
          );
        }
      }
      return out;
    }

    final entries = _entries ?? const <EntryInfo>[];
    for (final info in entries) {
      final isZip = !info.isDir && _isExpandableArchiveName(info.name);
      final isArchive = !info.isDir && _isArchiveName(info.name);
      final key = info.entity.path;
      out.add(_DisplayItem(
        key: key,
        displayName: info.name,
        depth: 0,
        isDir: info.isDir,
        isZip: isZip,
        isArchive: isArchive,
        size: info.size,
        modified: info.modified,
        diskEntry: info,
      ));
      if (isZip && _expandedZipKeys.contains(key)) {
        _appendZipChildren(
          out: out,
          zipDiskPath: key,
          zipArchive: _zipArchives[key],
          at: '',
          innerPrefix: '',
          parentOwnerKey: null,
          depth: 1,
          error: _zipErrors[key],
          loading: _loadingZipKeys.contains(key),
        );
      }
    }
    return out;
  }

  void _appendZipChildren({
    required List<_DisplayItem> out,
    required String zipDiskPath,
    required Archive? zipArchive,
    required String at,
    required String innerPrefix,
    required String? parentOwnerKey,
    required int depth,
    String? error,
    bool loading = false,
  }) {
    if (depth == 1) {
      if (loading) {
        out.add(_DisplayItem(
          key: '__loading__$zipDiskPath',
          displayName: '正在加载…',
          depth: depth,
          ownerZipKey: zipDiskPath,
          isZipInner: true,
        ));
        return;
      }
      if (error != null) {
        out.add(_DisplayItem(
          key: '__error__$zipDiskPath',
          displayName: '加载失败：$error',
          depth: depth,
          ownerZipKey: zipDiskPath,
          isZipInner: true,
        ));
        return;
      }
    }
    if (zipArchive == null) return;

    final children = _directZipChildren(zipArchive, at);
    for (final c in children) {
      final innerFullForDisplay = innerPrefix.isEmpty
          ? c.fullPath
          : '$innerPrefix>${c.fullPath}';

      final nodeKey = _makeZipInnerKey(zipDiskPath, innerFullForDisplay);
      final ownerKey = parentOwnerKey ?? zipDiskPath;

      out.add(_DisplayItem(
        key: nodeKey,
        displayName: c.name,
        depth: depth,
        isDir: c.isDir,
        isZip: c.isZip,
        isArchive: !c.isDir && _isArchiveName(c.name),
        isZipInner: true,
        size: c.size,
        ownerZipKey: ownerKey,
        innerPath: c.fullPath,
        innerPathForDisplay: innerFullForDisplay,
        innerArchive: zipArchive,
      ));

      if (c.isDir) {
        _appendZipChildren(
          out: out,
          zipDiskPath: zipDiskPath,
          zipArchive: zipArchive,
          at: c.fullPath,
          innerPrefix: innerPrefix,
          parentOwnerKey: ownerKey,
          depth: depth + 1,
        );
      } else if (c.isZip) {
        final nestedKey =
            _makeZipInnerKey(zipDiskPath, innerFullForDisplay);
        final nestedArchive = _zipArchives[nestedKey];
        if (nestedArchive != null) {
          _appendZipChildren(
            out: out,
            zipDiskPath: zipDiskPath,
            zipArchive: nestedArchive,
            at: '',
            innerPrefix: innerFullForDisplay,
            parentOwnerKey: nestedKey,
            depth: depth + 1,
          );
        }
      }
    }
  }

  // ==================== 加载目录 ====================

  Future<void> _load({
  bool restoreScroll = false,
  bool skipCache = false,
  bool silent = false,
}) async {
    _loadCancelToken?.cancel();
    final token = LoadCancelToken();
    _loadCancelToken = token;

    final log = ReaderLoadLog.instance;
    final t0 = DateTime.now();

    final anchor = restoreScroll ? _snapshotVisiblePaths() : const <String>[];
    var anchorRestored = false;

final sortField = ref.read(sortFieldProvider);
final sortAsc = ref.read(sortAscProvider);
final cacheKey = '$_currentPath|${sortField.name}|$sortAsc';
    if (_expandedZipKeys.isNotEmpty) {
      _clearZipExpansion();
    }

    if (!skipCache) {
      final cached = DirCache.instance.get(cacheKey);
      if (cached != null) {
        log.info('[DirCache] 命中  $cacheKey  (${cached.length} 项)');
        final saved = _dirScrollPositions[_currentPath] ?? 0;
        final grid = _isGridMode;
        final fileIdx = saved > 0 ? saved : 0;
        final jumpIdx = grid ? fileIdx ~/ 2 : fileIdx;
        setState(() {
          _entries = cached;
          _loading = false;
          _showSkeleton = false;
          _error = null;
          // 无锚点时用 initialScrollIndex 让列表首次挂载就落在原位置；
          // 有锚点（重命名/移动）走 _restoreScrollAnchor，不在这里抢位置。
          if (anchor.isEmpty) {
            _initialScrollIndex = jumpIdx;
            _listGeneration++;
          }
        });
        if (anchor.isNotEmpty) _restoreScrollAnchor(anchor);
        _maybeRevealTarget();
        // 兜底：initialScrollIndex 万一没生效（极端边界）时仍能跳回原位；
        // 正常它已是同位置 no-op，不会产生额外闪烁。
        if (anchor.isEmpty) _restoreDirScroll();
        return;
      }
    }



    if (_currentPath == _topPath) {
      List<EntryInfo> entries;
      try {
        entries = _listStorageRoot();
      } catch (_) {
        entries = <EntryInfo>[];
      }
      if (!mounted || token.isCancelled) return;
      final saved = _dirScrollPositions[_currentPath] ?? 0;
      final grid = _isGridMode;
      final fileIdx = saved > 0 ? saved : 0;
      final jumpIdx = grid ? fileIdx ~/ 2 : fileIdx;
      setState(() {
        _entries = entries;
        _loading = false;
        _showSkeleton = false;
        _error = null;
        if (anchor.isEmpty) {
          _initialScrollIndex = jumpIdx;
          _listGeneration++;
        }
      });
      DirCache.instance.put(cacheKey, entries);
      if (anchor.isNotEmpty) _restoreScrollAnchor(anchor);
      _maybeRevealTarget();
      if (anchor.isEmpty) _restoreDirScroll();
      return;
    }

   if (!silent) {
  setState(() {
    _loading = true;
    _error = null;
    _bodyRevision++; // 只在真正显示 loading 时递增，缓存命中/静默刷新保持原地更新
  });
  _skeletonTimer?.cancel();
  _showSkeleton = false;
  _skeletonTimer = Timer(const Duration(milliseconds: 180), () {
    if (mounted && _loading) {
      setState(() => _showSkeleton = true);
    }
  });
} else if (_error != null) {
  setState(() => _error = null);
}

try {
  await loadDirectoryAsync(
        path: _currentPath,
        sortField: sortField,
        sortAsc: sortAsc,
        cancelToken: token,
        onUpdate: (list) {
          if (!mounted || token.isCancelled) return;
          _skeletonTimer?.cancel();
          final saved = _dirScrollPositions[_currentPath] ?? 0;
          final grid = _isGridMode;
          final fileIdx = saved > 0 ? saved : 0;
          final jumpIdx = grid ? fileIdx ~/ 2 : fileIdx;
          setState(() {
            _entries = list;
            _loading = false;
            _showSkeleton = false;
            // 无锚点时用 initialScrollIndex 在首次挂载就定位，避免一帧闪烁。
            if (anchor.isEmpty && !anchorRestored) {
              _initialScrollIndex = jumpIdx;
              _listGeneration++;
            }
          });
          if (anchor.isNotEmpty && !anchorRestored) {
            _restoreScrollAnchor(anchor);
            anchorRestored = true;
          } else if (anchor.isEmpty && !anchorRestored) {
            anchorRestored = true;
          }
          _maybeRevealTarget();
        },
        onComplete: (list) {
          if (!mounted || token.isCancelled) return;
          _skeletonTimer?.cancel();
          setState(() {
            _entries = list;
            _showSkeleton = false;
          });
          DirCache.instance.put(cacheKey, list);
          // 稳定列表已在 onUpdate 通过 initialScrollIndex 定位，这里不再跳，
          // 只刷新数据并保持原位。
          _maybeRevealTarget();
        },
      );
    } catch (e) {
      if (!mounted || token.isCancelled) return;
      _skeletonTimer?.cancel();
      setState(() {
        _error = e.toString();
        _loading = false;
        _showSkeleton = false;
      });
    }
  }

  // ==================== 滚动锚点 ====================

  /// 子页面带 revealPath 时：目录加载完成后滚动到该文件并短暂高亮。
  /// 只滚动 + 闪一下底色，不进入多选，不改变任何选中态。
  void _maybeRevealTarget() {
    if (_revealHandled) return;
    final target = widget.revealPath;
    if (target == null) {
      _revealHandled = true;
      return;
    }
    final entries = _entries;
    if (entries == null) return; // 等加载回调再试

    final parent = target.contains('/')
        ? target.substring(0, target.lastIndexOf('/'))
        : target;
    if (_currentPath != parent) {
      _revealHandled = true;
      return;
    }
    _revealHandled = true;

    final grid = !_searchActive && ref.read(browserGridModeProvider);
    int? index;
    if (grid) {
      final filtered = _filterEntries(entries);
      final i = filtered.indexWhere((e) => e.entity.path == target);
      if (i >= 0) index = i ~/ 2; // 网格两列一行
    } else {
      final i = _buildDisplayItems().indexWhere((it) => it.key == target);
      if (i >= 0) index = i;
    }
    if (index == null) return;
    final jumpIndex = index;

    _flashPath = target;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToReveal(jumpIndex);
    });
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      setState(() => _flashPath = null);
    });
  }

  /// 列表可能还没挂载，最多重试 3 帧再放弃定位。
  void _jumpToReveal(int index, [int attempt = 0]) {
    if (!mounted) return;
    if (_itemScrollController.isAttached) {
      _itemScrollController.jumpTo(index: index);
      return;
    }
    if (attempt >= 3) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToReveal(index, attempt + 1);
    });
  }

  bool get _isGridMode =>
      !_searchActive && ref.read(browserGridModeProvider);

  List<String> _snapshotVisiblePaths() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return const <String>[];
    // 列表实际渲染的是 _visibleItems（过滤模式下的子集），
    // 用全量列表按下标取 key 会错位。
    final allItems = _visibleItems ?? _cachedDisplayItems;
    if (allItems == null || allItems.isEmpty) return const <String>[];

    final sorted = positions.toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final grid = _isGridMode;
    final out = <String>[];
    for (final p in sorted) {
      if (grid) {
        final i1 = p.index * 2;
        final i2 = i1 + 1;
        if (i1 >= 0 && i1 < allItems.length) out.add(allItems[i1].key);
        if (i2 >= 0 && i2 < allItems.length) out.add(allItems[i2].key);
      } else {
        if (p.index < 0 || p.index >= allItems.length) continue;
        out.add(allItems[p.index].key);
      }
    }
    return out;
  }

  void _restoreScrollAnchor(List<String> anchorKeys) {
    if (anchorKeys.isEmpty) return;
    final allItems = _visibleItems ?? _cachedDisplayItems;
    if (allItems == null || allItems.isEmpty) return;

    var targetIdx = -1;
    for (final k in anchorKeys) {
      final idx = allItems.indexWhere((it) => it.key == k);
      if (idx >= 0) {
        targetIdx = idx;
        break;
      }
    }
    if (targetIdx < 0) targetIdx = 0;

    final grid = _isGridMode;
    final jumpIdx = grid ? targetIdx ~/ 2 : targetIdx;

    _restoringScroll = true;
    _jumpToIndexWhenAttached(jumpIdx);
  }

  void _recordCurrentScroll() {
    if (_restoringScroll) return;
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    var minIdx = 1 << 30;
    for (final p in positions) {
      if (p.index < minIdx) minIdx = p.index;
    }
    if (minIdx < (1 << 30)) {
      final grid = _isGridMode;
      final fileIdx = grid ? minIdx * 2 : minIdx;
      _dirScrollPositions[_currentPath] = fileIdx;
    }
  }

  /// 跳到指定下标；控制器还没挂上时每帧重试，直到挂上为止。
  /// 重载目录时列表会先卸挂载再重挂，单帧 postFrameCallback 常常早于挂载，
  /// 不加重试就会静默跳过、列表停在顶部。
  void _jumpToIndexWhenAttached(int index, [int attempt = 0]) {
    if (!mounted) return;
    if (_itemScrollController.isAttached) {
      _itemScrollController.jumpTo(index: index);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoringScroll = false;
      });
      return;
    }
    if (attempt >= 20) {
      _restoringScroll = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToIndexWhenAttached(index, attempt + 1);
    });
  }

  void _restoreDirScroll() {
    final saved = _dirScrollPositions[_currentPath];
    final fileIdx = (saved != null && saved > 0) ? saved : 0;
    final grid = _isGridMode;
    final jumpIdx = grid ? fileIdx ~/ 2 : fileIdx;
    _restoringScroll = true;
    _jumpToIndexWhenAttached(jumpIdx);
  }

  void _navigateTo(String path) {
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
       if (path == _currentPath) return;
   _recordCurrentScroll();
_clearSelection();
_searchCtrl.clear();
_advancedCloseTimer?.cancel();
_advancedOverlay?.remove();
_advancedOverlay = null;
_advancedOpen = false;
// 换目录连大小/时间也清，否则限制会残留到下次搜索。
_clearAllFilters();
_filterTaskId++;
_searchTaskId++;
_clearZipExpansion();
    // 子页面只在本页导航，不覆盖主页面的「上次浏览目录」。
    if (widget.initialPath == null) {
      ref.read(lastPathProvider.notifier).update(path);
    }
    // 先算好再改 _currentPath——下面要用改动前的目录判断"进去还是出来"。
    final nextVisited = _visitedPathFor(from: _currentPath, to: path);
    setState(() {
      _currentPath = path;
      _searchResults = [];
      _searching = false;
      _searchActive = false;
      _lastVisitedPath = nextVisited;
    });
    _startVisitedFade();
    _load();
  }

  /// 从 [from] 走到 [to] 时，回到 [to] 之后该高亮哪一项。
  ///
  /// 三种走向：
  ///   · 进子目录（to 在 from 下面）→ 记住 to 本身。
  ///     退回 from 时 from 的列表里有 to，正好高亮刚进去过的那个文件夹。
  ///   · 回上级（from 在 to 下面）→ 记住 from 到 to 这条路上的第一级。
  ///     跨好几级直接回（面包屑点顶层）时也能标到正确的那一级，
  ///     而不是标一个当前列表里根本不存在的深层路径。
  ///   · 跳到不相干的目录（收藏、跳转、换存储）→ 清掉，不该继承旧高亮。
  String? _visitedPathFor({required String from, required String to}) {
    if (to.startsWith('$from/')) return to;
    if (from.startsWith('$to/')) {
      final rel = from.substring(to.length + 1);
      final slash = rel.indexOf('/');
      final first = slash < 0 ? rel : rel.substring(0, slash);
      if (first.isEmpty) return null;
      return '$to/$first';
    }
    return null;
  }

  /// 打开文件 / 进入目录后记一笔：回到列表时高亮这一项。
  void _markVisited(String path) {
    if (path.isEmpty) return;
    if (!mounted) return;
    setState(() => _lastVisitedPath = path);
    _startVisitedFade();
  }

  /// 让「刚才去过」高亮从满色渐隐到透明（~700ms），结束自动清除。
  /// 重复触发（连续进出目录）会重头再渐隐一次，不会叠加或卡住。
  void _startVisitedFade() {
    _visitedFadeCtrl
      ..stop()
      ..reset()
      ..forward();
  }

  /// 子页面和主页面共用同一套导航规则：能上跳就上跳，到存储根为止。
  bool get _canGoUp => _currentPath != _topPath;

  /// 返回键是否已经到达本页边界（存储根）：此时返回会关闭本页。
  bool get _atPageBoundary => _currentPath == _topPath;

  void _goUp() {
    if (!_canGoUp) return;
    final parent = Directory(_currentPath).parent.path;
    if (!parent.startsWith(_topPath)) return;
    if (parent == '/storage/emulated') {
      _navigateTo(_topPath);
      return;
    }
    _navigateTo(parent);
  }

  List<EntryInfo> _listStorageRoot() {
    final out = <EntryInfo>[];
    final seen = <String>{};

    void addDir(String path, String name) {
      if (seen.contains(path)) return;
      final dir = Directory(path);
      if (!dir.existsSync()) return;
      seen.add(path);
      out.add(EntryInfo(entity: dir, name: name, isDir: true));
    }

    addDir('/storage/emulated/0', '内部存储');

    try {
      final raw =
          Directory('/storage/emulated').listSync(followLinks: false);
      for (final e in raw) {
        if (e is! Directory) continue;
        final name = e.path.split('/').last;
        if (name == '0' || name == 'self') continue;
        if (!RegExp(r'^\d+$').hasMatch(name)) continue;
        addDir(e.path, '双开($name)');
      }
    } catch (_) {}

    final uuidPattern = RegExp(r'([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4})');
    const sources = <String>[
      '/proc/mounts', '/proc/self/mountinfo', '/proc/self/mounts',
      '/etc/mtab',
    ];
    final uuids = <String>{};
    for (final src in sources) {
      try {
        final content = File(src).readAsStringSync();
        for (final m in uuidPattern.allMatches(content)) {
          uuids.add(m.group(1)!);
        }
        if (uuids.isNotEmpty) break;
      } catch (_) {}
    }
    for (final uuid in uuids) {
      if (Directory('/storage/$uuid').existsSync()) {
        addDir('/storage/$uuid', '外部存储($uuid)');
      } else if (Directory('/mnt/media_rw/$uuid').existsSync()) {
        addDir('/mnt/media_rw/$uuid', '外部存储($uuid)');
      }
    }

    return out;
  }

  // ==================== 选中 ====================
// ==================== 高级搜索条件 · 逻辑 ====================

int get _activeConditionCount =>
    _searchConditions.where((c) => c.text.trim().isNotEmpty).length +
    (_isSizeTimeFilterActive() ? 1 : 0);

/// 有没有非空条件。
bool get _hasActiveConditions => _activeConditionCount > 0;

/// 上一次点"搜索"时的关键词。关键词变了就清空高级条件。
String _lastSearchedQuery = '';




void _clearConditions() {
  for (final c in _searchConditions) {
    c.dispose();
  }
  _searchConditions.clear();
}

/// 清空全部：文字条件 + 大小/时间筛选。
/// X / 退出搜索 / 换目录 / 换关键词，以及面板里的「清空全部」都走这里，
/// 保证条件不会偷偷留到下一次搜索；面板开着时靠令牌同步清 4 个输入框。
void _clearAllFilters() {
  _clearConditions();
  _filterSizeMinMb = null;
  _filterSizeMaxMb = null;
  _filterTimeFrom = null;
  _filterTimeTo = null;
  _advancedClearToken++;
  _filterTaskId++;
}

/// 只清文字条件行，大小/时间保留（对应面板上「🗑 清空条件」）。
void _clearTextConditionsOnly() {
  _clearConditions();
  _advancedOverlay?.markNeedsBuild();
}

/// 大小 / 时间筛选是否已设置（用于放行空文字搜索）。
bool _isSizeTimeFilterActive() =>
    _filterSizeMinMb != null ||
    _filterSizeMaxMb != null ||
    _filterTimeFrom != null ||
    _filterTimeTo != null;

/// 按大小（MB）/ 修改时间（精确到秒）过滤。
/// 大小筛选下，文件夹（size 为 null）一律不命中；时间对文件与文件夹都生效。
bool _passesSizeTimeFilter(int? size, DateTime? modified) {
  if (_filterSizeMinMb != null &&
      (size == null || size < _filterSizeMinMb! * 1024 * 1024)) {
    return false;
  }
  if (_filterSizeMaxMb != null &&
      (size == null || size > _filterSizeMaxMb! * 1024 * 1024)) {
    return false;
  }
  if (_filterTimeFrom != null &&
      (modified == null || modified.isBefore(_filterTimeFrom!))) {
    return false;
  }
  if (_filterTimeTo != null &&
      (modified == null || modified.isAfter(_filterTimeTo!))) {
    return false;
  }
  return true;
}

/// 核心匹配函数。所有搜索/过滤入口都用它。
bool _matchNameForSearch(String name) {
  final lower = name.toLowerCase();
  final mainText = _searchCtrl.text.trim().toLowerCase();
  final orTexts = <String>[];
  if (mainText.isNotEmpty) orTexts.add(mainText);

  final andTexts = <String>[];
  final notTexts = <String>[];

  for (final c in _searchConditions) {
    final t = c.text.trim().toLowerCase();
    if (t.isEmpty) continue;
    switch (c.operator) {
      case _SearchOperator.or:
        orTexts.add(t);
      case _SearchOperator.and:
        andTexts.add(t);
      case _SearchOperator.not:
        notTexts.add(t);
    }
  }

  if (orTexts.isEmpty && andTexts.isEmpty && notTexts.isEmpty) {
    return true;
  }
  if (orTexts.isNotEmpty && !orTexts.any(lower.contains)) return false;
  for (final t in andTexts) {
    if (!lower.contains(t)) return false;
  }
  for (final t in notTexts) {
    if (lower.contains(t)) return false;
  }
  return true;
}

// ==================== 高级搜索条件 · Overlay ====================

void _toggleAdvanced() {
  FocusManager.instance.primaryFocus?.unfocus();
  if (_advancedOpen) {
    _closeAdvanced();
  } else {
    setState(() => _advancedOpen = true);
    _showAdvancedOverlay();
  }
}

void _closeAdvanced() {
  _advancedCloseTimer?.cancel();
  // A1 / F2：先把面板高度收回去，等收起动画播完再 remove()，
  // 别「啪」一下把整个 OverlayEntry 删掉。
  _advancedPanelVisible?.value = false;
  if (mounted && _advancedOpen) {
    setState(() => _advancedOpen = false);
  }
  final Duration dur =
      mounted ? _fx(340) : const Duration(milliseconds: 340);
  _advancedCloseTimer = Timer(dur, () {
    _advancedOverlay?.remove();
    _advancedOverlay = null;
  });
}

void _showAdvancedOverlay() {
  _advancedCloseTimer?.cancel();
  _advancedOverlay?.remove();
  _advancedOverlay = null;
  // A1 / F2：先以 false 建一帧（高度 0），下一帧再置 true，
  // AnimatedSize 才有「从 0 长出来」的起点。
  final visible = ValueNotifier<bool>(false);
  _advancedPanelVisible = visible;

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final box =
        _searchBarBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screenWidth = MediaQuery.of(context).size.width;

    _advancedOverlay = OverlayEntry(
      builder: (ctx) => _AdvancedOverlayContent(
        panelTop: pos.dy + size.height + 2,
        panelLeft: 8,
        panelWidth: screenWidth - 16,
        conditions: _searchConditions,
        filterSizeMinMb: _filterSizeMinMb,
        filterSizeMaxMb: _filterSizeMaxMb,
        filterTimeFrom: _filterTimeFrom,
        filterTimeTo: _filterTimeTo,
        clearToken: _advancedClearToken,
        onChanged: () {
          if (!mounted) return;
          setState(() {});
          _advancedOverlay?.markNeedsBuild();
        },
        onClearAll: () {
          // 清全部：文字条件 + 大小/时间，令牌自增让 4 个输入框同步清空。
          _clearAllFilters();
          setState(() {});
          _advancedOverlay?.markNeedsBuild();
        },
        onClearConditions: () {
          // 只清文字条件行；大小/时间输入框保留，令牌不动。
          _clearTextConditionsOnly();
          setState(() {});
          _advancedOverlay?.markNeedsBuild();
        },
        onSizeChanged: (min, max) {
          // 顶栏高级按钮颜色 / 搜索栏「条件·N」徽章靠 _hasActiveConditions
          // 刷新，它已含大小时间；只在「有条件↔无条件」翻转时重建主界面，
          // 其余按键仅刷浮层，避免每敲一字整页 rebuild。
          final wasActive = _isSizeTimeFilterActive();
          _filterSizeMinMb = min;
          _filterSizeMaxMb = max;
          if (mounted && wasActive != _isSizeTimeFilterActive()) {
            setState(() {});
          }
          _advancedOverlay?.markNeedsBuild();
        },
        onTimeChanged: (from, to) {
          final wasActive = _isSizeTimeFilterActive();
          _filterTimeFrom = from;
          _filterTimeTo = to;
          if (mounted && wasActive != _isSizeTimeFilterActive()) {
            setState(() {});
          }
          _advancedOverlay?.markNeedsBuild();
        },
        onSubmit: () {
          _closeAdvanced();
          _doSearch();
        },
        onClose: _closeAdvanced,
        visible: visible,
      ),
    );
    Overlay.of(context).insert(_advancedOverlay!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 这两帧之间若用户已经点了关闭，就不要再把面板展开回来。
      if (mounted && _advancedOpen && _advancedOverlay != null) {
        visible.value = true;
      }
    });
  });
}

// ==================== 高级搜索条件 · UI ====================






/// A1：系统开了「减少动态效果」就把本轮所有动效退化为瞬切。
Duration _fx(int ms) => MediaQuery.of(context).disableAnimations
    ? Duration.zero
    : Duration(milliseconds: ms);

// A1：TweenAnimationBuilder 靠 Tween 的对象 identity 判断要不要重播，
// 所以这几个必须复用同一个对象；否则每敲一个字都会把动画重放一遍。
static final Tween<double> _kExecPop =
    Tween<double>(begin: 1.14, end: 1.0);
static final Tween<double> _kExecIdle =
    Tween<double>(begin: 1.0, end: 1.0);

// C1：TweenAnimationBuilder 靠「对象 identity」判断要不要重播。
// 下面两个长得一样的静态对象，用来在开关切换时恰好触发一次轻弹。
static final Tween<double> _kRowInTween =
    Tween<double>(begin: 0, end: 1);
static final Tween<double> _kPopA =
    Tween<double>(begin: 1.14, end: 1.0);
static final Tween<double> _kPopB =
    Tween<double>(begin: 1.14, end: 1.0);
static final List<Curve> _kRowCurves = <Curve>[
  Interval(0.0, 1.0, curve: Curves.easeOutCubic),
  Interval(0.16, 1.0, curve: Curves.easeOutCubic),
  Interval(0.32, 1.0, curve: Curves.easeOutCubic),
];

/// C1 / A5：搜索栏展开时左标签 / 输入框 / 右按钮按 80ms 一档浮入。
/// 折叠时整个子树被卸载，下次展开重新挂载就会重播一次；逐字 rebuild
/// 不会重播，因为 tween / curve 都是静态对象。
Widget _enterSearchRow(int i, Widget child) {
  final idx = i < _kRowCurves.length ? i : _kRowCurves.length - 1;
  return TweenAnimationBuilder<double>(
    tween: _kRowInTween,
    duration: _fx(420),
    curve: _kRowCurves[idx],
    builder: (_, v, c) => Opacity(
      opacity: v,
      child: Transform.translate(
        offset: Offset(0, 7 * (1 - v)),
        child: c,
      ),
    ),
    child: child,
  );
}

/// C1 / M5：菜单项按 index 分层浮入；收起时最后一条先退（倒序）。
/// 用隐式动画：首次构建直接显示终值，不会「先闪一帧再淡出」。
Widget _staggerMenuChip(int i, Widget chip, {required bool above}) {
  final int idx = i < 0 ? 0 : (i > 4 ? 4 : i);
  final int inMs = 160 + idx * 45;
  final int outMs = 100 + (4 - idx) * 25;
  return ValueListenableBuilder<bool>(
    valueListenable: _menuVisible,
    builder: (_, open, child) => AnimatedOpacity(
      opacity: open ? 1.0 : 0.0,
      duration: _fx(open ? inMs : outMs),
      curve: open ? Curves.easeOutCubic : Curves.easeInCubic,
      child: AnimatedSlide(
        offset: open ? Offset.zero : Offset(0.10, above ? 0.16 : -0.16),
        duration: _fx(open ? inMs + 20 : outMs),
        curve: open ? Curves.easeOutCubic : Curves.easeInCubic,
        child: child,
      ),
    ),
    child: chip,
  );
}

/// C1 / M5：只让被点中的那个三点按钮轻弹一下，另一个不动。
Widget _pulseAnchor(String which, Widget child) {
  return ValueListenableBuilder<bool>(
    valueListenable: _menuVisible,
    builder: (_, open, c) {
      final active = open && _menuAnchor == which;
      return TweenAnimationBuilder<double>(
        tween: active ? _kPopA : _kPopB,
        duration: _fx(active ? 280 : 0),
        curve: Curves.easeOutBack,
        builder: (_, s, w) => Transform.scale(scale: s, child: w!),
        child: c,
      );
    },
    child: child,
  );
}

/// 菜单打开中，或正在播收起动画 —— PopScope 都要把返回键先拦下来。
bool get _menuBusy => _floatingMenuEntry != null || _menuClosing;

Widget _buildAdvancedToggle() {
  final cs = Theme.of(context).colorScheme;
  // 只有两态：展开 / 收起。有没有条件靠颜色和 tooltip 表达。
  final color =
      _hasActiveConditions ? cs.primary : cs.onSurfaceVariant;
  final tip = _hasActiveConditions
      ? '高级搜索（有 $_activeConditionCount 条条件）'
      : '高级搜索';
  // A1 / F1：单颗「向下箭头」图标，展开时旋转 180° 变成向上箭头，
  // 以旋转代替原来的「交叉淡入 + 上下错位」，箭头随开合平滑翻转动画。
  return SizedBox(
    width: 40,
    height: 44,
    child: _SoftGlowTapButton(
      size: 40,
      color: color,
      spreadDuration: _fx(440),
      onTap: _toggleAdvanced,
      child: Tooltip(
        message: tip,
        child: AnimatedRotation(
          turns: _advancedOpen ? 0.5 : 0.0,
          duration: _fx(220),
          curve: Curves.easeOutCubic,
          child: GradientIcon(
            Icons.keyboard_arrow_down,
            size: 22,
            fallbackColor: color,
          ),
        ),
      ),
    ),
  );
}
  void _clearSelection() {
    // 底栏「⋯」的锚点随多选态一起消失，菜单必须跟着关，不能留在原位。
    // C1：这里跳过收起动画直接删，否则菜单会悬空播 220ms。
    _closeFloatingMenu(immediate: true);
    setState(() {
      _selectionMode = false;
      _selectedPaths.clear();
      _anchorPath = null;
    });
  }

  /// 把当前唯一选中的条目压入一个新页面，本页现场（搜索/滚动/多选）保持不变。
  /// 文件夹以自身为起点；文件以所在目录为起点，并定位到该文件。
  Future<void> _openSelectedInNewPage() async {
    if (_selectedPaths.length != 1) return;
    final path = _selectedPaths.first;
    final type = FileSystemEntity.typeSync(path);
    final isDir = type == FileSystemEntityType.directory;
    if (!isDir && type != FileSystemEntityType.file) {
      _toast('无法打开这个条目');
      return;
    }
    final targetDir =
        isDir || !path.contains('/') ? path : path.substring(0, path.lastIndexOf('/'));
    _clearSelection();
    await _pushChildPage(targetDir, revealPath: isDir ? null : path);
  }

  /// 搜索态点面包屑：压子页并把搜索现场留给当前页；普通浏览仍同页跳转。
  void _openBreadcrumb(String path) {
    if (_searchActive) {
      _pushChildPage(path);
    } else {
      _navigateTo(path);
    }
  }

  /// 压入以 [path] 为起点的子页面；返回后校正本页可能已失效的状态。
  Future<void> _pushChildPage(String path, {String? revealPath}) async {
    await Navigator.of(context).push(
      _noAnimRoute(
        FileBrowserScreen(initialPath: path, revealPath: revealPath),
      ),
    );
    if (!mounted) return;
    // 子页面里可能删/移过文件：剔除失效的搜索结果，并让当前目录重新取一次缓存。
    setState(_pruneSearchResults);
    if (!_searchActive) _load();
  }

  void _pruneSearchResults() {
    if (_searchResults.isEmpty) return;
    final still = <_SearchHit>[];
    var removed = 0;
    for (final hit in _searchResults) {
      if (FileSystemEntity.typeSync(hit.path) !=
          FileSystemEntityType.notFound) {
        still.add(hit);
      } else {
        removed++;
        _selectedPaths.remove(hit.path);
      }
    }
    if (removed == 0) return;
    _searchResults = still;
    if (_selectedPaths.isEmpty) {
      _selectionMode = false;
      _anchorPath = null;
    }
  }

  void _toggleSelectionByKey(String key) {
    setState(() {
      _selectionMode = true;
      if (_selectedPaths.contains(key)) {
        _selectedPaths.remove(key);
        if (_selectedPaths.isEmpty) {
          _selectionMode = false;
          _anchorPath = null;
        }
      } else {
        _selectedPaths.add(key);
        _anchorPath = key;
      }
    });
  }

  void _onLongPressItem(_DisplayItem item) {
    if (!_selectionMode) {
      setState(() {
        _selectionMode = true;
        _selectedPaths.add(item.key);
        _anchorPath = item.key;
      });
      return;
    }
    if (_anchorPath != null) {
      // 用屏幕上实际显示的列表，避免过滤模式下把隐藏项一起选上。
      final all =
          _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
      final from = all.indexWhere((it) => it.key == _anchorPath);
      final to = all.indexWhere((it) => it.key == item.key);
      if (from >= 0 && to >= 0) {
        final lo = from < to ? from : to;
        final hi = from < to ? to : from;
        setState(() {
          for (var i = lo; i <= hi; i++) {
            _selectedPaths.add(all[i].key);
          }
          _anchorPath = item.key;
        });
        return;
      }
    }
    setState(() {
      _selectedPaths.add(item.key);
      _anchorPath = item.key;
    });
  }

  void _toggleSelectAll() {
    final all =
        _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final selectable = all
        .where((it) => !it.key.startsWith('__loading__') &&
            !it.key.startsWith('__error__'))
        .map((it) => it.key)
        .toList();
    final allSelected = selectable.isNotEmpty &&
        selectable.every((k) => _selectedPaths.contains(k));
    setState(() {
      if (allSelected) {
        _selectedPaths.clear();
        _selectionMode = false;
        _anchorPath = null;
      } else {
        _selectionMode = true;
        _selectedPaths.addAll(selectable);
      }
    });
  }

  /// 反选：对当前列表里所有可选条目取反。
  /// 对任意选中数（1..n）都成立，用来保证多选底栏「⋯」里永远有可点的项。
  void _invertSelection() {
    final all =
        _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final selectable = all
        .where((it) => !it.key.startsWith('__loading__') &&
            !it.key.startsWith('__error__'))
        .map((it) => it.key);
    final next = <String>{
      for (final k in selectable)
        if (!_selectedPaths.contains(k)) k,
    };
    if (next.isEmpty && _selectedPaths.isEmpty) return;
    setState(() {
      _selectedPaths
        ..clear()
        ..addAll(next);
      _selectionMode = next.isNotEmpty;
      _anchorPath = next.isEmpty ? null : next.first;
    });
  }

  List<String> get _currentDisplayedPaths {
    if (_searchActive) {
      return _searchResults.map((h) => h.path).toList();
    }
    return (_entries ?? const <EntryInfo>[])
        .map((e) => e.entity.path)
        .toList();
  }

  // ==================== zip 展开 / 收起 ====================

Archive _fixZipNames(Archive archive) {
  var anyChanged = false;
  final newArchive = Archive();
  for (final f in archive.files) {
    final fixed = _fixZipName(f.name);
    if (fixed != f.name) anyChanged = true;
    newArchive.addFile(ArchiveFile(fixed, f.size, f.content));
  }
  return anyChanged ? newArchive : archive;
}

String _fixZipName(String name) {
  if (name.isEmpty) return name;

  var hasHigh = false;
  for (final r in name.runes) {
    if (r > 0xFF) return name;
    if (r >= 0x80) hasHigh = true;
  }
  if (!hasHigh) return name;

  final bytes = Uint8List.fromList(name.codeUnits);

  try {
    final utf8Name = utf8.decode(bytes);
    if (utf8Name != name) return utf8Name;
  } catch (_) {}

  try {
    final gbkName = gbk.decode(bytes);
    if (gbkName != name) return gbkName;
  } catch (_) {}

  return name;
}

  Future<bool> _isEncryptedZip(String path) async {
    try {
      final raf = await File(path).open();
      try {
        final header = await raf.read(8);
        if (header.length < 8) return false;
        if (header[0] != 0x50 ||
            header[1] != 0x4B ||
            header[2] != 0x03 ||
            header[3] != 0x04) {
          return false;
        }
        return (header[6] & 0x01) != 0;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

Archive _decodeArchiveBytes(String name, Uint8List bytes, {String? password}) {
  final lower = name.toLowerCase();
 if (lower.endsWith('.zip')) {
  final archive = (password == null || password.isEmpty)
      ? ZipDecoder().decodeBytes(bytes)
      : ZipDecoder().decodeBytes(bytes, password: password);
  return _fixZipNames(archive);
}
  if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
  final gunzipped = GZipDecoder().decodeBytes(bytes);
  return _parseTarWithGbk(Uint8List.fromList(gunzipped));
}
  if (lower.endsWith('.tar')) {
    return _parseTarWithGbk(bytes);
  }
  throw Exception('不支持的压缩格式：$name');
}

Archive _parseTarWithGbk(Uint8List bytes) {
  final archive = Archive();
  var offset = 0;
  Uint8List? pendingLongNameBytes;

  String decodeName(List<int> raw) {
    var end = raw.length;
    while (end > 0 && raw[end - 1] == 0) {
      end--;
    }
    if (end <= 0) return '';
    final slice = raw.sublist(0, end);
    try {
      return utf8.decode(slice);
    } catch (_) {}
    try {
      return gbk.decode(slice);
    } catch (_) {}
    return String.fromCharCodes(slice);
  }

  int readOctal(Uint8List buf, int start, int len) {
    var result = 0;
    for (var i = start; i < start + len; i++) {
      final b = buf[i];
      if (b == 0 || b == 0x20) break;
      if (b < 0x30 || b > 0x37) break;
      result = result * 8 + (b - 0x30);
    }
    return result;
  }

  int alignTo512(int n) => ((n + 511) ~/ 512) * 512;

  while (offset + 512 <= bytes.length) {
    final header = Uint8List.sublistView(bytes, offset, offset + 512);

    var allZero = true;
    for (var i = 0; i < 512; i++) {
      if (header[i] != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) break;

    var name = decodeName(header.sublist(0, 100));
    final size = readOctal(header, 124, 12);
    final type = header[156];
    final prefix = decodeName(header.sublist(345, 500));
    if (prefix.isNotEmpty) {
      name = '$prefix/$name';
    }

    offset += 512;
    if (offset + size > bytes.length) break;

    if (type == 0x4C) {
      pendingLongNameBytes =
          Uint8List.fromList(bytes.sublist(offset, offset + size));
      offset += alignTo512(size);
      continue;
    }

    if (type == 0x78 || type == 0x67) {
      offset += alignTo512(size);
      continue;
    }

    if (type == 0x00 || type == 0x30 || type == 0x35) {
      if (pendingLongNameBytes != null) {
        name = decodeName(pendingLongNameBytes);
        pendingLongNameBytes = null;
      }

      final isDir = type == 0x35;
      final content = isDir
          ? Uint8List(0)
          : Uint8List.fromList(bytes.sublist(offset, offset + size));

      final cleanName = isDir && name.endsWith('/')
          ? name.substring(0, name.length - 1)
          : name;

      if (cleanName.isNotEmpty) {
        archive.addFile(ArchiveFile(cleanName, content.length, content));
      }
      offset += alignTo512(size);
    } else {
      offset += alignTo512(size);
    }
  }

  return archive;
}

int _le32(Uint8List b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) &
        0xFFFFFFFF;

/// 扫描 zip 本地文件头，累加解压后总字节数，用于解码前的大小上限判断。
/// 遇到流式写入（数据描述符）导致本地头大小为 0 时返回 null，表示无法预估。
int? _zipUncompressedTotal(Uint8List bytes) {
  var offset = 0;
  var total = 0;
  while (offset + 30 <= bytes.length) {
    if (bytes[offset] != 0x50 ||
        bytes[offset + 1] != 0x4B ||
        bytes[offset + 2] != 0x03 ||
        bytes[offset + 3] != 0x04) {
      break;
    }
    final flags = bytes[offset + 6] | (bytes[offset + 7] << 8);
    final comp = _le32(bytes, offset + 18);
    final uncomp = _le32(bytes, offset + 22);
    final nameLen = bytes[offset + 26] | (bytes[offset + 27] << 8);
    final extraLen = bytes[offset + 28] | (bytes[offset + 29] << 8);
    if (uncomp == 0 && (flags & 0x08) != 0) return null;
    total += uncomp;
    final next = offset + 30 + nameLen + extraLen + comp;
    if (next <= offset) break; // 防御：大小为 0 时避免死循环
    offset = next;
  }
  return total;
}


Future<void> _expandZip(String zipDiskPath) async {
  if (_expandedZipKeys.contains(zipDiskPath)) return;
  if (_loadingZipKeys.contains(zipDiskPath)) return;

  try {
    final length = await File(zipDiskPath).length();
    if (length > _maxZipBytes) {
      if (!mounted) return;
      await openFileWithSystemPicker(zipDiskPath, context);
      if (mounted) {
        _toast('压缩包过大（${_formatSize(length)}），已交给其他 App 打开');
      }
      return;
    }
  } catch (_) {}

  setState(() {
    _loadingZipKeys.add(zipDiskPath);
    _zipErrors.remove(zipDiskPath);
    _expandedZipKeys.add(zipDiskPath);
  });

  try {
  final bytes = await File(zipDiskPath).readAsBytes();
  final lower = zipDiskPath.toLowerCase();

  final Archive archive;
  if (lower.endsWith('.zip') && await _isEncryptedZip(zipDiskPath)) {
    // 加密 ZIP：能预估解压体积时先判断上限，超限交给系统打开；
    // 否则弹密码框解密（输错可重试，取消则退回未展开）。
    final uncomp = _zipUncompressedTotal(bytes);
    if (uncomp != null && uncomp > _maxTotalDecodedBytes) {
      if (!mounted) return;
      await openFileWithSystemPicker(zipDiskPath, context);
      if (mounted) {
        _toast('压缩包解压后过大（${_formatSize(uncomp)}），已交给其他 App 打开');
      }
      return;
    }
    final decrypted = await _tryDecodeEncryptedZip(zipDiskPath, bytes);
    if (decrypted == null) {
      if (!mounted) return;
      setState(() {
        _loadingZipKeys.remove(zipDiskPath);
        _expandedZipKeys.remove(zipDiskPath);
      });
      return;
    }
    archive = decrypted;
  } else {
    // 原有未加密路径
    if (lower.endsWith('.zip')) {
      final uncomp = _zipUncompressedTotal(bytes);
      if (uncomp != null && uncomp > _maxTotalDecodedBytes) {
        if (!mounted) return;
        await openFileWithSystemPicker(zipDiskPath, context);
        if (mounted) {
          _toast('压缩包解压后过大（${_formatSize(uncomp)}），已交给其他 App 打开');
        }
        return;
      }
    }
    archive = _decodeArchiveBytes(zipDiskPath, bytes);
  }

  if (!mounted) return;

  // 重置本次展开的累计解压计数，并把顶层解压后的内容算进去。
  _expandedDecodedBytes = 0;
  final topDecodedSize =
      archive.files.fold<int>(0, (s, f) => s + f.size);
  _expandedDecodedBytes = topDecodedSize;

  _zipArchives[zipDiskPath] = archive;
  _collectNestedZips(zipDiskPath, archive, '', '');


		

    if (!mounted) return;
    setState(() {
      _loadingZipKeys.remove(zipDiskPath);
    });
  } catch (e) {
    if (!mounted) return;

    setState(() {
      _loadingZipKeys.remove(zipDiskPath);
      _expandedZipKeys.remove(zipDiskPath);
    });

    await openFileWithSystemPicker(zipDiskPath, context);
    if (mounted) {
      _toast('此压缩包无法解压（可能已加密），已交给其他 App 打开');
    }
  }
}

  /// 弹密码框。返回 null 表示用户取消。
  Future<String?> _askZipPassword(String zipPath) async {
    if (!mounted) return null;
    final name = zipPath.split('/').last;
    final ctrl = TextEditingController();
    var obscure = true;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          insetPadding: _dlgInset,
          title: const Text('压缩包已加密'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('「$name」需要密码才能解压。',
                    style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: '密码',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: Icon(obscure
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () => setS(() => obscure = !obscure),
                    ),
                  ),
                  onSubmitted: (v) => Navigator.pop(c, v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, ctrl.text),
              child: const Text('解压'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (result == null || result.isEmpty) return null;
    return result;
  }

  /// 弹密码 → 解密 → 失败重试，直到成功或用户取消。
  /// 返回 null 表示取消；返回 Archive 表示解密成功。
  Future<Archive?> _tryDecodeEncryptedZip(
    String zipPath,
    Uint8List bytes,
  ) async {
    var pwd = await _askZipPassword(zipPath);
    while (pwd != null) {
      try {
        final archive = _decodeArchiveBytes(zipPath, bytes, password: pwd);
        // 触发一次解密以校验密码（AES 在读取内容时才校验 MAC，
        // 部分版本 decodeBytes 不会立即抛错）。
        for (final f in archive.files) {
          if (f.isFile) {
            final _ = f.content;
            break;
          }
        }
        return archive;
      } catch (e) {
        if (!mounted) return null;
        final action = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('解压失败'),
            content: Text('密码可能不正确，或该压缩包使用了暂不支持的加密方式。\n$e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, 'retry'),
                child: const Text('重试'),
              ),
            ],
          ),
        );
        if (action != 'retry' || !mounted) return null;
        pwd = await _askZipPassword(zipPath);
      }
    }
    return null;
  }

  void _collectNestedZips(
  String ownerZipDiskPath,
  Archive archive,
  String at,
  String innerPrefix,
) {
  if (_expandedDecodedBytes >= _maxTotalDecodedBytes) return;
  final children = _directZipChildren(archive, at);
    for (final c in children) {
      if (c.isDir) {
        _collectNestedZips(ownerZipDiskPath, archive, c.fullPath, innerPrefix);
      } else if (c.isZip) {
  // 累计已超上限，不再展开更深的嵌套。
  if (_expandedDecodedBytes >= _maxTotalDecodedBytes) continue;

  final innerFull = innerPrefix.isEmpty
      ? c.fullPath
      : '$innerPrefix>${c.fullPath}';
  final nestedKey = _makeZipInnerKey(ownerZipDiskPath, innerFull);

  try {
    final f = archive.findFile(c.fullPath);
    if (f == null) continue;
    final content = f.content;
    final Uint8List bytes;
    if (content is Uint8List) {
      bytes = content;
    } else if (content is List<int>) {
      bytes = Uint8List.fromList(content);
    } else {
      continue;
    }
    final inner = _decodeArchiveBytes(c.name, bytes);

    // 把这一层的解压内容累计进去。
    final innerDecodedSize =
        inner.files.fold<int>(0, (s, file) => s + file.size);
    _expandedDecodedBytes += innerDecodedSize;
    if (_expandedDecodedBytes > _maxTotalDecodedBytes) {
      // 超限：不再记录这一层，也不再往下钻。
      continue;
    }

    _zipArchives[nestedKey] = inner;
    _expandedZipKeys.add(nestedKey);
    _collectNestedZips(ownerZipDiskPath, inner, '', innerFull);
  } catch (_) {
    // 解不开（大概率是嵌套加密 ZIP）：记一笔，列表里打 🔒。
    _encryptedNestedZipKeys.add(nestedKey);
  }
}
    }
  }

  void _collapseZip(String zipDiskPath) {
    setState(() {
      _expandedZipKeys.remove(zipDiskPath);
      _expandedZipKeys.removeWhere((k) => _isZipInnerKey(k) &&
          _zipPathFromInnerKey(k) == zipDiskPath);
      _zipArchives.remove(zipDiskPath);
      _zipArchives.removeWhere((k, _) => _isZipInnerKey(k) &&
          _zipPathFromInnerKey(k) == zipDiskPath);
      _zipErrors.remove(zipDiskPath);
      if (_stickyZipKey == zipDiskPath) {
        _stickyZipKey = null;
      }
    });
  }

  /// 收起所有已展开的压缩包，并释放其解码缓存（_zipArchives 等），
  /// 避免导航/返回/退出搜索后残留占用内存。
  void _clearZipExpansion() {
    _expandedZipKeys.clear();
    _zipArchives.clear();
    _zipErrors.clear();
    _loadingZipKeys.clear();
    _encryptedNestedZipKeys.clear();
    _stickyZipKey = null;
  }

  Future<void> _toggleZipExpand(_DisplayItem zipItem) async {
    if (zipItem.isZipInner) {
      if (_encryptedNestedZipKeys.contains(zipItem.key)) {
        _toast('嵌套在压缩包里的加密 ZIP 暂不支持，请先解压到本地再打开');
        return;
      }
      setState(() {
        _expandedZipKeys.remove(zipItem.key);
        _expandedZipKeys.removeWhere((k) => k.startsWith(zipItem.key));
      });
      return;
    }
    if (_expandedZipKeys.contains(zipItem.key)) {
      _collapseZip(zipItem.key);
    } else {
      await _expandZip(zipItem.key);
    }
  }

  // ignore: unused_element
  void _onStickyZipTap(String zipDiskPath) {
    _collapseZip(zipDiskPath);
  }

  // ==================== 打开 / 查看 ====================

  Future<void> _handleTapItem(_DisplayItem item) async {
    if (item.key.startsWith('__loading__') ||
        item.key.startsWith('__error__')) {
      return;
    }

    if (item.isZip) {
      await _toggleZipExpand(item);
      return;
    }

    if (item.isZipInner && item.isDir) {
      return;
    }

    if (item.isZipInner) {
      await _openZipInnerFile(item);
      return;
    }

    if (item.isDir) {
      final p = item.diskPath;
      if (p != null) _navigateTo(p);
      return;
    }

    final p = item.diskPath;
    if (p != null) {
      await _openFile(p, item.displayName, item.size);
    }
  }

  Future<void> _openZipInnerFile(_DisplayItem item) async {
    final ext = _extOf(item.displayName);
    final isText = _textExts.contains(ext);

    final bytes = _readZipInnerBytes(item);
    if (bytes == null) {
      _toast('读取失败');
      return;
    }

    if (isText) {
      final tmp = await _writeTempFile(bytes, item.displayName);
      if (tmp == null) {
        _toast('无法创建临时文件');
        return;
      }
      final mode = ref.read(fileOpenModeProvider);
      switch (mode) {
        case FileOpenMode.reader:
          await _openInReader(tmp, item.displayName);
        case FileOpenMode.editor:
        // 行编辑器已下线，旧配置一律走 re_editor 全文编辑器。
        // 枚举值故意保留：老用户 SharedPreferences 里存的是 "lineEditor"，
        // 删掉会让 decode 回落到 defaultValue，反而不好控制。
        case FileOpenMode.lineEditor:
          await _openInEditor(tmp, item.displayName);
        case FileOpenMode.ask:
          final picked = await _askOpenMode(item.displayName);
          if (picked == null) return;
          switch (picked) {
            case FileOpenMode.reader:
              await _openInReader(tmp, item.displayName);
            case FileOpenMode.editor:
            case FileOpenMode.lineEditor:
              await _openInEditor(tmp, item.displayName);
            case FileOpenMode.ask:
              break;
          }
      }
    } else {
      final tmp = await _writeTempFile(bytes, item.displayName);
      if (tmp == null) {
        _toast('无法创建临时文件');
        return;
      }
      if (!mounted) return;
      await showOpenOrShareSheet(context, tmp, item.displayName);
    }
  }

  Uint8List? _readZipInnerBytes(_DisplayItem item) {
    final archive = item.innerArchive;
    final path = item.innerPath;
    if (archive == null || path == null) return null;
    try {
      final f = archive.findFile(path);
      if (f == null) return null;
      final content = f.content;
      if (content is Uint8List) return content;
      if (content is List<int>) return Uint8List.fromList(content);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 把 zip 内文件写到临时目录。
///
/// 用固定文件名（不带时间戳）：同名文件自动覆盖，不积累。
/// 上次会话遗留的文件，App 启动时由 _cleanTempDirOnce 清掉。
Future<String?> _writeTempFile(Uint8List bytes, String fileName) async {
  try {
    final dir = Directory.systemTemp;
    final safe = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final path = '${dir.path}/zzz_$safe';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  } catch (_) {
    return null;
  }
}

  // ==================== 打开磁盘文件 ====================

Future<void> _openFile(
  String path,
  String name,
  int? size, {
  bool allowExpand = true,
}) async {
  final isText = _textExts.contains(_extOf(name));

  if (!isText) {
    final lowerName = name.toLowerCase();

    if (_isExpandableArchiveName(name)) {
if (!allowExpand) {
  if (!mounted) return;
  await openFileWithSystemPicker(path, context);
  return;
}
      await _expandZip(path);
      return;
    }

    if (_forceSystemPickerExts.any((ext) => lowerName.endsWith(ext))) {
      if (!mounted) return;
      await openFileWithSystemPicker(path, context);
      return;
    }

    await showOpenOrShareSheet(context, path, name);
    return;
  }

  final configured = ref.read(fileOpenModeProvider);
  FileOpenMode resolved;
  if (configured == FileOpenMode.ask) {
    final picked = await _askOpenMode(name);
    if (picked == null) return;
    resolved = picked;
  } else {
    resolved = configured;
  }

  switch (resolved) {
    case FileOpenMode.reader:
      await _openInReader(path, name);
    case FileOpenMode.editor:
    case FileOpenMode.lineEditor:
      await _openInEditor(path, name);
    case FileOpenMode.ask:
      break;
  }
}

  Future<void> _openInReader(String path, String name) async {
    final textPaths = _collectTextFilePaths();
    var index = textPaths.indexOf(path);
    if (index < 0) {
      textPaths.insert(0, path);
      index = 0;
    }

    final openedPath = path;
    final result = await Navigator.of(context).push<String>(
      PageRouteBuilder<String>(
        pageBuilder: (_, __, ___) => ReaderScreen(
          filePaths: textPaths,
          initialIndex: index,
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );

    if (!mounted) return;

    final deleted = ref.read(readerDeletedPathsProvider);
    if (deleted.isNotEmpty) {
      ref.read(readerDeletedPathsProvider.notifier).state = const [];
      final deletedSet = deleted.toSet();
      final current = _entries ?? const <EntryInfo>[];
      final stillThere = <EntryInfo>[];
      for (final info in current) {
        if (!deletedSet.contains(info.entity.path)) {
          stillThere.add(info);
        }
      }
      if (stillThere.length != current.length) {
        setState(() => _entries = stillThere);
        DirCache.instance.applyToAll(
          _currentPath,
          (list) => list.where((e) => !deletedSet.contains(e.path)).toList(),
        );
      }
    }

    if (result != null && result != openedPath) {
      _scrollToPath(result);
    }
    // 阅读器里可能翻到别的文件：标最后读的那个，不是最初打开的那个。
    _markVisited(result ?? openedPath);
  }

  /// 只刷新单个文件的 stat（size / modified），不重新 list、不重新排序。
  ///
  /// 编辑器返回时用：文件内容改了但目录结构没变，没必要全量重载
  /// （全量重载会闪空 + 分批 stat 重排导致位置抖动）。
  Future<void> _refreshSingleEntry(String path) async {
    final entries = _entries;
    if (entries == null || entries.isEmpty) return;
    final idx = entries.indexWhere((e) => e.path == path);
    if (idx < 0) return;

    FileStat st;
    try {
      st = await FileStat.stat(path);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (st.type == FileSystemEntityType.notFound) return;

    final old = entries[idx];
    if (old.size == st.size && old.modified == st.modified) return;

    // EntryInfo 是可变类，但这里重建一份新实例并替换列表元素，
    // 保证 build() 用最新值重建显示、且与缓存引用脱钩更稳妥。
    final updated = EntryInfo(
      entity: old.entity,
      name: old.name,
      isDir: old.isDir,
      size: st.size,
      modified: st.modified,
    );
    setState(() {
      final copy = List<EntryInfo>.from(entries);
      copy[idx] = updated;
      _entries = copy;
    });

    // 同步缓存（所有排序方式），下次再进这个目录能看到新值。
    DirCache.instance.applyToAll(_currentPath, (list) {
      final i = list.indexWhere((e) => e.path == path);
      if (i < 0) return list;
      final c = List<EntryInfo>.from(list);
      c[i] = updated;
      return c;
    });
  }

  /// path 是不是当前目录的直接子文件（zip 内临时文件不算）。
  bool _isInCurrentDir(String path) {
    if (path.isEmpty || _currentPath.isEmpty) return false;
    if (!path.startsWith('$_currentPath/')) return false;
    final rest = path.substring(_currentPath.length + 1);
    return !rest.contains('/');
  }

  Future<void> _openInEditor(String path, String name) async {
    await Navigator.of(context).push(_noAnimRoute(SingleFileEditorScreen(
      filePath: path,
      fileName: name,
    )));
    if (!mounted) return;
    // 原来这里 invalidate + _load() 会导致：
    //   1. _loading=true → 列表变空闪一下
    //   2. 完整 list + 分批 stat + 重排 → 位置要几十~几百毫秒才稳定
    // 编辑器只改了文件内容，目录结构没变，只刷新那一个文件的 stat 即可。
    if (_isInCurrentDir(path)) {
      await _refreshSingleEntry(path);
      if (!mounted) return;
      _markVisited(path);
    }
    // zip 内文件（tmp 路径不在当前目录下）：不刷新、不 invalidate、不重载，
    // 交给 _openZipInnerFile 用 item.key 高亮，避免列表闪空。
  }

  // 行编辑器（LineEditorScreen）暂时下线，入口统一走上面的 _openInEditor。
  // 页面文件本身还留着（lib/features/file_browser/presentation/line_editor_screen.dart），
  // 要恢复就把上面几处 switch 的 lineEditor 分支接回去，并把它 import 回来。

  Future<FileOpenMode?> _askOpenMode(String fileName) async {
    final remember = ValueNotifier<bool>(false);
    final picked = await showModalBottomSheet<FileOpenMode>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c) => SafeArea(
        child: StatefulBuilder(
          builder: (c, setS) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.open_in_new, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '用哪种方式打开「$fileName」？',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.menu_book),
                title: const Text('阅读器'),
                subtitle: const Text('分页翻页，看小说用'),
                onTap: () => Navigator.pop(c, FileOpenMode.reader),
              ),
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('编辑器'),
                subtitle: const Text('全文编辑，大文件也流畅'),
                onTap: () => Navigator.pop(c, FileOpenMode.editor),
              ),
              const Divider(height: 1),
              CheckboxListTile(
                value: remember.value,
                onChanged: (v) => setS(() => remember.value = v ?? false),
                title: const Text('记住我的选择'),
                subtitle: const Text(
                  '下次不再询问，直接按选中的方式打开。\n'
                  '想改回询问：右上角设置 → 打开方式 → 每次询问',
                  style: TextStyle(fontSize: 11),
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );

    if (picked != null && remember.value) {
      ref.read(fileOpenModeProvider.notifier).update(picked);
    }
    return picked;
  }
void _jumpToTop() {
  if (!_itemScrollController.isAttached) return;
  _itemScrollController.jumpTo(index: 0);
}
  void _scrollToPath(String path) {
    final allItems = _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final index = allItems.indexWhere((it) => it.key == path);
    if (index < 0) return;

    final grid = _isGridMode;
    final jumpIdx = grid ? index ~/ 2 : index;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_itemScrollController.isAttached) return;
      _itemScrollController.jumpTo(index: jumpIdx);
    });
  }

  List<String> _collectTextFilePaths() {
    if (_searchActive) {
      return [
        for (final hit in _searchResults)
          if (_textExts.contains(_extOf(hit.name))) hit.path,
      ];
    }
    final entries = _entries ?? const <EntryInfo>[];
    return [
      for (final info in entries)
        if (!info.isDir && _textExts.contains(_extOf(info.name)))
          info.entity.path,
    ];
  }

  Widget _leading({
    required bool selectionMode,
    required bool selected,
    required bool isDir,
    required String name,
    required VoidCallback onToggle,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: AppFileIcon(isDir: isDir),
    );
  }

  // ==================== 搜索 ====================

  void _onSearchChanged(String v) {
  final mode = ref.read(searchBoxModeProvider);
  if (mode == SearchBoxMode.filter) {
    _onFilterTextChanged(v);
  } else {
    setState(() {});
  }
}
// ==================== 过滤 ====================

void _onFilterTextChanged(String q) {
  _filterTaskId++;
  setState(() {
    // 过滤条件变了，屏幕上看得见的项也跟着变了。
    // 把已经不在可见列表里的选中项清掉，避免"看不见却选着"
    // 导致数量对不上、删/移动/复制时误伤隐藏文件。
    if (ref.read(searchBoxModeProvider) == SearchBoxMode.filter) {
      final visible = _computeVisibleItems(_buildDisplayItems());
      final visibleKeys = visible.map((it) => it.key).toSet();
      _selectedPaths.removeWhere((k) => !visibleKeys.contains(k));
      if (_selectedPaths.isEmpty) {
        _selectionMode = false;
        _anchorPath = null;
      }
    }
  });
}

List<_DisplayItem> _computeVisibleItems(List<_DisplayItem> all) {
  if (_searchActive) return all;
  if (ref.read(searchBoxModeProvider) != SearchBoxMode.filter) return all;

  final q = _searchCtrl.text.trim().toLowerCase();
  if (q.isEmpty) return all;

  final matchedTop = <String>{};
  for (final it in all) {
    if (it.depth != 0) continue;
    if (it.displayName.toLowerCase().contains(q)) {
      matchedTop.add(it.key);
    }
  }

  return [
    for (final it in all)
      if (it.depth == 0 && matchedTop.contains(it.key))
        it
      else if (it.ownerZipKey != null &&
          matchedTop.contains(it.ownerZipKey))
        it,
  ];
}

List<EntryInfo> _filterEntries(List<EntryInfo> entries) {
  if (ref.read(searchBoxModeProvider) != SearchBoxMode.filter) {
    return entries;
  }
  final q = _searchCtrl.text.trim().toLowerCase();
  final sizeTimeActive = _isSizeTimeFilterActive();
  return entries.where((e) {
    if (q.isNotEmpty && !e.name.toLowerCase().contains(q)) return false;
    if (sizeTimeActive && !_passesSizeTimeFilter(e.size, e.modified)) {
      return false;
    }
    return true;
  }).toList();
}

void _clearFilter() {
  _searchTaskId++;
  _filterTaskId++;
  _searchCtrl.clear();
  _selectionMode = false;
  _selectedPaths.clear();
  _anchorPath = null;
  // X 连高级条件一起清（文字条件 + 大小/时间），面板开着也同步清空。
  _clearAllFilters();
  setState(() {});
}
  void _doSearch() {
  final q = _searchCtrl.text.trim();
  if (q.isEmpty && !_hasActiveConditions) return;

  // 关键词变了 → 只清文字条件行，大小/时间作为独立筛选维度保留。
  // 用户从"搜张三+排除斗罗"改到"搜我吃西红柿"时，文字条件不应跟着走；
  // 但不能连大小/时间一起清，否则「先搜关键词、再清空文字只按大小搜」
  // 会在 _startSearch 里因无条件而直接返回空结果。
  if (_lastSearchedQuery != q) {
    if (_searchConditions.isNotEmpty) {
      _clearConditions();
      _advancedCloseTimer?.cancel();
      _advancedOverlay?.remove();
      _advancedOverlay = null;
      _advancedOpen = false;
    }
    _lastSearchedQuery = q;
  }

  if (q.isNotEmpty) {
    ref.read(browserSearchHistoryProvider.notifier).add(q);
  }
  setState(() {
    _searchActive = true;
    _bodyRevision++; // 搜索/普通列表共用 _itemScrollController，整体重建避免交叉淡入期双挂载
  });
  _startSearch();
}
/// 清空输入框 + 全部高级条件；退出搜索交给 AppBar 的返回箭头。
void _clearSearchInput() {
  _searchTaskId++;
  _searchCtrl.clear();
  _selectionMode = false;
  _selectedPaths.clear();
  _anchorPath = null;
  _clearZipExpansion();
  // X 连条件一起清，别让大小/时间限制留到下一次搜索。
  _clearAllFilters();
  setState(() {
    _searchResults = [];
    _searching = false;
    // 注意：_searchActive 保持 true，留在搜索模式
  });
}
  void _clearSearch() {
    _searchTaskId++;
    _searchCtrl.clear();
    _selectionMode = false;
    _selectedPaths.clear();
    _anchorPath = null;
    _clearZipExpansion();
    // 退出搜索时条件一并清掉，避免大小/时间限制偷偷留到下一次搜索。
    _clearAllFilters();
    setState(() {
      _searchResults = [];
      _searching = false;
      _searchActive = false;
      _bodyRevision++; // 退出搜索时整体重建，避免新旧列表交叉淡入双挂载 controller
    });
  }

  void _cancelSearch() {
    _searchTaskId++;
    setState(() => _searching = false);
  }

  Future<void> _showSearchHistory() async {
    await showDialog<void>(
      context: context,
      builder: (c) => Consumer(
        builder: (c, ref, _) {
          final history = ref.watch(browserSearchHistoryProvider);
          return AlertDialog(
            insetPadding: _dlgInset,
            titlePadding: _dlgTitlePad,
            contentPadding: _dlgContentPad,
            actionsPadding: _dlgActionsPad,
            title: const Text('搜索历史'),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(c).size.height * 0.7,
              child: history.isEmpty
                  ? const Center(child: Text('还没有搜索记录'))
                  : ListView.builder(
                      itemCount: history.length,
                      itemBuilder: (ctx, i) {
                        final q = history[i];
                        return ListTile(
                          dense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          leading: const Icon(Icons.history, size: 20),
                          title: Text(
                            q,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: '删除',
                            onPressed: () {
                              ref
                                  .read(browserSearchHistoryProvider.notifier)
                                  .remove(q);
                            },
                          ),
                          onTap: () {
                            _searchCtrl.text = q;
                            setState(() {});
                            Navigator.pop(c);
                          },
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  List<String> _dedupFolders(List<String> folders) {
    final sorted = List<String>.from(folders)..sort();
    final out = <String>[];
    for (final f in sorted) {
      final covered = out.any((p) => f == p || f.startsWith('$p/'));
      if (!covered) out.add(f);
    }
    return out;
  }

Future<void> _startSearch() async {
  final taskId = ++_searchTaskId;
  final q = _searchCtrl.text.trim();
  if (q.isEmpty && !_hasActiveConditions) {
    setState(() {
      _searchResults = [];
      _searching = false;
    });
    return;
  }

  setState(() {
    _searching = true;
    _searchResults = [];
  });
  _lastUiRefresh = DateTime.now();

  final scope = ref.read(searchScopeProvider);
  final customFolders = ref.read(customSearchFoldersProvider);

  final roots = <String>[];
  if (scope == SearchScope.currentRecursive) {
    roots.add(_currentPath);
  } else {
    if (customFolders.isEmpty) {
      _toast('请先点击左侧搜索设置 → 管理搜索范围');
      if (mounted) setState(() => _searching = false);
      return;
    }
    roots.addAll(_dedupFolders(customFolders));
  }

  final results = <_SearchHit>[];

  for (final root in roots) {
    if (taskId != _searchTaskId) return;
    await _scanDir(root, results, taskId);
  }

  if (taskId != _searchTaskId) return;
  if (!mounted) return;

  final sortField = ref.read(searchSortFieldProvider);
  final sortAsc = ref.read(searchSortAscProvider);

  results.sort((a, b) {
    int cmp;
    switch (sortField) {
      case SortField.name:
        cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case SortField.modified:
        final at = a.modified?.millisecondsSinceEpoch ?? 0;
        final bt = b.modified?.millisecondsSinceEpoch ?? 0;
        cmp = at.compareTo(bt);
      case SortField.size:
        final as = a.size ?? 0;
        final bs = b.size ?? 0;
        cmp = as.compareTo(bs);
    }
    return sortAsc ? cmp : -cmp;
  });

  setState(() {
    _searching = false;
    _searchResults = List.from(results);
  });
}

  Future<void> _scanDir(
  String dirPath,
  List<_SearchHit> results,
  int taskId, {
  int depth = 0,
}) async {
  if (depth > _searchMaxDepth) return;
  if (results.length >= 2000) return;
  try {
    await for (final e in Directory(dirPath).list(followLinks: false)) {
      if (taskId != _searchTaskId) return;
      if (results.length >= 2000) return;

      if (e is Directory) {
        final name = e.path.split('/').last;
        if (name.startsWith('.')) continue;
        final lower = e.path.toLowerCase();
        if (lower.contains('/android/data') ||
            lower.contains('/android/obb')) {
          continue;
        }

          if (_matchNameForSearch(name)) {
          DateTime? modified;
          try {
            final st = await e.stat();
            modified = st.modified;
          } catch (_) {}
          // stat 是 await 断点：期间可能已清空/重开搜索，旧任务不能再写回结果。
          if (taskId != _searchTaskId) return;

          if (_passesSizeTimeFilter(null, modified)) {
            results.add(_SearchHit(
              path: e.path,
              name: name,
              isDir: true,
              size: null,
              modified: modified,
            ));
          }

          final now = DateTime.now();
          if (mounted &&
              now.difference(_lastUiRefresh).inMilliseconds > 100) {
            _lastUiRefresh = now;
            setState(() => _searchResults = List.from(results));
          }
        }

        await _scanDir(e.path, results, taskId, depth: depth + 1);
      } else if (e is File) {
        final name = e.path.split('/').last;
          if (_matchNameForSearch(name)) {
          int? size;
          DateTime? modified;
          try {
            final st = await e.stat();
            size = st.size;
            modified = st.modified;
          } catch (_) {}
          if (taskId != _searchTaskId) return;

          if (_passesSizeTimeFilter(size, modified)) {
            results.add(_SearchHit(
              path: e.path,
              name: name,
              isDir: false,
              size: size,
              modified: modified,
            ));
          }

          final now = DateTime.now();
          if (mounted &&
              now.difference(_lastUiRefresh).inMilliseconds > 100) {
            _lastUiRefresh = now;
            setState(() => _searchResults = List.from(results));
          }
        }
      }
    }
  } catch (_) {}
}

  Future<void> _showSearchFolderPicker() async {
    final current = ref.read(customSearchFoldersProvider);
    final result = await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SearchFolderPickerDialog(
        rootPath: _topPath,
        initialPath: _currentPath,
        initialSelected: current,
      ),
    );
    if (result != null && mounted) {
      ref.read(customSearchFoldersProvider.notifier).setAll(result);
      // 主框留空但设了高级条件/大小时间时，改范围同样要重搜。
      if (_searchActive &&
          (_searchCtrl.text.trim().isNotEmpty || _hasActiveConditions)) {
        _startSearch();
      }
    }
  }

  // ==================== 对比 / MD5 / 属性 / 复制路径 ====================

  List<_DisplayItem> _resolveSelectedItems() {
    final items = _cachedDisplayItems ?? const <_DisplayItem>[];
    final out = <_DisplayItem>[];
    for (final key in _selectedPaths) {
      final it = items.firstWhere(
        (x) => x.key == key,
        orElse: () => _DisplayItem(
          key: key,
          displayName: key.split('/').last,
          depth: 0,
        ),
      );
      out.add(it);
    }
    return out;
  }

  /// 首次安装后，选中两个文件对比时弹一次引导。
  ///
  /// 第一行红字提醒「对比页不改原文件」，并解释替换 / 编辑 / 快捷操作按钮的用途。
  /// 点「知道了」或「不再显示」都视为已看过，写标记后不再弹。
  Future<void> _maybeShowCompareOnboard() async {
    if (ref.read(compareOnboardProvider)) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('对比前先看一眼'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '⚠ 对比页里的单击编辑不会改动原文件！',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  height: 1.5,
                ),
              ),
              SizedBox(height: 12),
              Text(
                '单击编辑、查找替换只改对比页的临时视图，'
                '原文件一个字不动，退出对比页就恢复原样。',
                style: TextStyle(fontSize: 13.5, height: 1.65),
              ),
              SizedBox(height: 8),
              Text(
                '想真正改源文件：长按某行 → 弹出的迷你编辑器里改 → '
                '点「保存源文件」。只有这一步会写回磁盘，并自动生成 .bak 备份。',
                style: TextStyle(fontSize: 13.5, height: 1.65),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('不再显示'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    ref.read(compareOnboardProvider.notifier).update(true);
  }

  /// 简洁对比（差异清单）入口：与完整对比并列，不经过对比页。
  Future<void> _startQuickCompare() => _startCompare(quick: true);

  /// quick = true 时打开「简洁对比」页（不建块、不排版、只列差异行）；
  /// quick = false 时打开原来的完整对比页。读盘 / 解析 / 写入 provider 完全共用。
  Future<void> _startCompare({bool quick = false}) async {
    if (_selectedPaths.length != 2) return;

    // 简洁对比页没有替换/编辑/快捷操作按钮，引导弹窗只针对完整对比页。
    if (!quick) {
      await _maybeShowCompareOnboard();
      if (!mounted) return;
    }

    final items = _resolveSelectedItems();
    if (items.length != 2) return;

    for (final it in items) {
      if (it.isDir) {
        _toast('对比只支持文件，请勿选中文件夹');
        return;
      }
      if (it.isZip && !it.isZipInner) {
        _toast('对比不支持直接对比压缩包本身，请展开后选里面的文件');
        return;
      }
    }

    // 从这里开始记录一次完整对比：从「点按钮」一直到页面首帧出内容。
    // 引导弹窗不计时（那是用户在看提示，不是程序在算）。
    final log = CompareTimingLog.instance;
    log.start(quick ? '简洁对比' : '完整对比');
    log.param('入口/左文件名', items[0].displayName);
    log.param('入口/右文件名', items[1].displayName);
    log.param('入口/左为压缩包内条目', items[0].isZipInner);
    log.param('入口/右为压缩包内条目', items[1].isZipInner);
    log.param('入口/左为磁盘文件', items[0].isDiskItem);
    log.param('入口/右为磁盘文件', items[1].isDiskItem);
    log.mark('入口参数记录完成，开始推入页面路由');

    // ── 读盘前体积软提示（真正吃内存的是"读盘 + 解码成 String"这一步）──
    // 推路由之前只 stat 一下元数据（lengthSync 不读内容，极快）。
    // 只看单个文件：任一文件 > 20MB 才提示一次；两份合计不再作为条件。
    // 3KB、4MB、十几 MB 这类正常小说一律不弹。
    // epub / docx / zip 体积里多是图片，正文可能才 1MB，不参与预检。
    // 提示是「象征性拦一下」：可继续、可取消，不硬拦。
    final bigSide = _oversizedCompareItem(items);
    if (bigSide != null && mounted) {
      final maxMb = (bigSide.maxBytes / 1024 / 1024).round();
      final totalMb = (bigSide.totalBytes / 1024 / 1024).round();
      log.param('入口/大文件软提示',
          '${bigSide.name} 约 ${maxMb}MB · 两份合计 ${totalMb}MB');
      final choice = await showLargeCompareWarning(
        context,
        fileName: bigSide.name,
        maxMb: maxMb,
        totalMb: totalMb,
      );
      if (choice != CompareRiskChoice.proceed) return; // 取消：不推路由、不读盘
      if (!mounted) return;
    }

    String? leftText;
    String? rightText;
    String? leftName;
    String? rightName;
    String? leftPath;
    String? rightPath;

    // 只保留对比页里的那一个加载动画：
    // 先把对比页推出来（跳格圆环立刻显示），再在它背后读盘 + 解析，
    // 期间把阶段写进 compareLoadStageProvider，让用户知道现在到哪一步。
    // 原来的「灰底 + 空心转圈」对话框已删除，避免出现两个加载页。
    resetCompareLoadState(ref);
    // 本次对比的加载圆环配色只抽一次：后面加载页会重建多次、还要进切视图
    // 遮罩，都读同一个值，不会在同一次对比过程中突然换色。
    pickLoadingPalette(ref);
    ref.read(compareLoadStageProvider.notifier).state = '正在读取文件…';

    final viewerRoute = Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) =>
            quick ? const DiffListPage() : const DiffViewerScreen(),
        // 零转场：进入/退出对比页均无动画
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
    // 用户在超时提示里点了「取消对比」（或直接返回）会 pop 掉对比页。
    // 这里记一笔：读盘/解析还没结束时别再把大文本写回 provider，
    // 否则页面都关了还在后台占着内存。
    var routeClosed = false;
    unawaited(viewerRoute.then((_) {
      routeClosed = true;
    }));
    log.mark('对比页路由已推入（加载页开始显示）');

    try {
      // 两个文件同时读盘：File.readAsBytes 走 IO 线程池，可以真正重叠；
      // 解码与规范化仍在同一 isolate 内串行执行。
      // 先让对比页把加载页画出来，再开始干重活。
      ref.read(compareLoadStageProvider.notifier).state = '正在读取两个文件…';
      await WidgetsBinding.instance.endOfFrame;
      log.mark('加载页已画出，开始并行读盘');

      final results = await Future.wait([
        _readAndParseForCompare(items[0], '左侧', showStage: false),
        _readAndParseForCompare(items[1], '右侧', showStage: false),
      ]);
      leftText = results[0].text;
      leftName = results[0].fileName;
      leftPath = items[0].isDiskItem ? items[0].diskPath : null;
      rightText = results[1].text;
      rightName = results[1].fileName;
      rightPath = items[1].isDiskItem ? items[1].diskPath : null;
      log.mark('两个文件读盘 + 解析全部完成');
      log.param('文件/左解析后字符数', leftText?.length ?? 0);
      log.param('文件/右解析后字符数', rightText?.length ?? 0);

      if (!mounted || routeClosed) {
        log.param('入口/对比已取消', '读盘完成后不再写入 provider');
        return;
      }

      // 预处理规则是在对比页里同步跑的，先把这条文案画出来再交棒，
      // 这样规则跑到一半时屏幕上写的是"正在应用预处理规则"，不是停住的表情。
      ref.read(compareLoadStageProvider.notifier).state = '正在应用预处理规则…';
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || routeClosed) return;
      log.mark('规则阶段文案已画出，开始写入 provider');

      ref.read(originalRawTextProvider.notifier).state = leftText;
      ref.read(modifiedRawTextProvider.notifier).state = rightText;
      ref.read(originalFileNameProvider.notifier).state = leftName;
      ref.read(modifiedFileNameProvider.notifier).state = rightName;
      ref.read(originalEncodingProvider.notifier).state = 'UTF-8';
      ref.read(modifiedEncodingProvider.notifier).state = 'UTF-8';
      ref.read(originalFilePathProvider.notifier).state = leftPath;
      ref.read(modifiedFilePathProvider.notifier).state = rightPath;
      ref.read(originalSharedTempPathProvider.notifier).state = null;
      ref.read(modifiedSharedTempPathProvider.notifier).state = null;
      ref.read(importRevisionProvider.notifier).state++;
      ref.read(fromDupeBoxProvider.notifier).state = false;
      ref.read(editedOriginalProvider.notifier).state = null;
      ref.read(editedModifiedProvider.notifier).state = null;

      if (!mounted || routeClosed) return;

      // 交棒：之后由 diffResultProvider 自己的加载文案接管。
      ref.read(compareLoadStageProvider.notifier).state = null;
      log.mark('provider 写入完成，交给 diffResultProvider 算差异');

      await viewerRoute;
      if (!mounted) return;
      setState(() => _pruneSearchResults());
    } catch (e) {
      if (!mounted || routeClosed) return;
      ref.read(compareLoadStageProvider.notifier).state = null;
      // UnsupportedError 是解析器主动抛的「暂不支持 xx 格式」，
      // 直接用它自己的文案，别带上 "Unsupported operation:" 这种前缀。
      final msg = e is UnsupportedError ? '${e.message}' : '$e';
      log.fail('读取文件失败：$msg');
      ref.read(compareLoadErrorProvider.notifier).state = '读取文件失败：$msg';
      // 简洁对比页没有加载错误界面：出错时直接退回并提示，避免一直转圈。
      if (quick && mounted) {
        Navigator.of(context).pop();
        _toast('读取文件失败：$msg');
      }
    }
  }

  /// 读盘前体积预检：软提示的触发线。
  /// 只看单个文件：任一文件 > 20MB → 弹一次风险提示；合计大小不参与判断。
  /// 用体积当粗指标是因为读盘前拿不到内容，算不了相似度；
  /// 它只说明"可能慢/可能闪退"，不代表一定有问题，所以弹窗可继续。
  ///
  /// 注意：体积只对"字节数≈正文字数"的格式有意义，压缩格式见
  /// [_hasVolumeMeaning]，它们根本不进这个预检。
  static const int _compareSoftWarnSingleBytes = 20 * 1024 * 1024;

  /// 该格式的体积能不能代表正文量。
  ///
  /// epub / docx / zip 的体积绝大部分是图片和字体，正文常常只占几十分之一
  /// （比如 30MB 的图文书正文才 1MB）。拿体积提示"可能很慢"必然误报，
  /// 所以这些格式直接跳过预检。纯文本、PDF 这类体积与内容量基本一致，
  /// 保留原有提示。
  static bool _hasVolumeMeaning(String name) {
    final n = name.toLowerCase();
    return !n.endsWith('.epub') &&
        !n.endsWith('.docx') &&
        !n.endsWith('.zip');
  }

  /// 返回较大文件与两份合计字节数；没到触发线返回 null。
  /// 磁盘文件用 lengthSync（只读元数据），zip 内条目用已记录的解压后大小。
  /// 任一读不到就当 0（不让预检本身出错挡住对比）。
  ({String name, int maxBytes, int totalBytes})? _oversizedCompareItem(
      List<_DisplayItem> items) {
    ({String name, int bytes})? biggest;
    var total = 0;
    for (final it in items) {
      // 压缩格式的体积说明不了正文有多少，不算进预检。
      if (!_hasVolumeMeaning(it.displayName)) continue;
      int bytes = 0;
      try {
        if (it.isDiskItem) {
          final p = it.diskPath;
          if (p != null) bytes = File(p).lengthSync();
        } else {
          bytes = it.size ?? 0;
        }
      } catch (_) {
        bytes = 0;
      }
      total += bytes;
      if (biggest == null || bytes > biggest.bytes) {
        biggest = (name: it.displayName, bytes: bytes);
      }
    }
    if (biggest == null) return null;
    if (biggest.bytes <= _compareSoftWarnSingleBytes) return null;
    return (
      name: biggest.name,
      maxBytes: biggest.bytes,
      totalBytes: total,
    );
  }

  /// 对比入口用：读盘 + 解析一项，并把当前阶段写进对比页的加载文案。
  ///
  /// 每换一次文案都等一下帧，保证「正在读取 xx.txt…」真的被画出来，
  /// 而不是刚设上去就被后面的大段同步解析卡住。
  Future<({String text, String fileName})> _readAndParseForCompare(
    _DisplayItem item,
    String side, {
    // 两侧并行读盘时由外层统一显示一条文案，避免两边互相覆盖，
    // 也省掉各自多等一帧。
    bool showStage = true,
  }) async {
    if (!mounted) throw Exception('页面已关闭');
    final name = item.displayName;

    if (showStage) {
      ref.read(compareLoadStageProvider.notifier).state =
          '正在读取$side文件 $name…';
      await WidgetsBinding.instance.endOfFrame;
    }

    final log = CompareTimingLog.instance;
    final swRead = Stopwatch()..start();
    final bytes = await _readBytesOfItem(item);
    swRead.stop();
    if (bytes == null) throw Exception('读取$side文件失败');
    log.param('文件/$side 名称', name);
    log.param('文件/$side 压缩包内条目', item.isZipInner);
    log.param('文件/$side 原始字节数', bytes.length);
    log.param('文件/$side 读盘Ms', swRead.elapsedMilliseconds);

    if (showStage) {
      ref.read(compareLoadStageProvider.notifier).state = '正在解析 $name…';
      await WidgetsBinding.instance.endOfFrame;
    }

    final swParse = Stopwatch()..start();
    final mem = await readDeviceMemory();
    final parsed = await DocumentParser.parse(
      fileName: name,
      bytes: bytes,
      dangerRssBytes: mem.dangerRssBytes,
    );
    swParse.stop();
    log.param('文件/$side 解析Ms', swParse.elapsedMilliseconds);
    log.param('文件/$side 解析后字符数', parsed.plainText.length);
    log.param('文件/$side 解析器返回文件名', parsed.fileName);
    log.mark('读盘 + 解析完成 / $side');
    return (text: parsed.plainText, fileName: parsed.fileName);
  }

  Future<Uint8List?> _readBytesOfItem(_DisplayItem item) async {
    if (item.isZipInner) {
      return _readZipInnerBytes(item);
    }
    final p = item.diskPath;
    if (p == null) return null;
    try {
      return await File(p).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static String _md5Worker(Uint8List bytes) {
    return md5.convert(bytes).toString();
  }

  /// 计算单个选中项的 MD5：磁盘文件走分块流式（不整文件入内存），
  /// zip 内部文件内容已在内存中，直接对字节求哈希。
  Future<String> _md5OfItem(_DisplayItem it) async {
    if (it.isZipInner) {
      final b = await _readZipInnerBytes(it);
      if (b == null) throw Exception('读取文件失败');
      return compute(_FileBrowserScreenState._md5Worker, b);
    }
    final p = it.diskPath;
    if (p == null) throw Exception('读取文件失败');
    return compute(_md5FileOfPath, p);
  }

  Future<void> _md5Compare() async {
    if (_selectedPaths.length != 2) return;
    final items = _resolveSelectedItems();
    if (items.length != 2) return;

    for (final it in items) {
      if (it.isDir) {
        _toast('MD5 对比只支持文件，请勿选中文件夹');
        return;
      }
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final h1 = await _md5OfItem(items[0]);
      final h2 = await _md5OfItem(items[1]);

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      final same = h1 == h2;
      final name1 = items[0].displayName;
      final name2 = items[1].displayName;

      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          insetPadding: _dlgInset,
          titlePadding: _dlgTitlePad,
          contentPadding: _dlgContentPad,
          actionsPadding: _dlgActionsPad,
          title: const Text('MD5 对比'),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.7,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name1,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SelectableText(h1,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                  const SizedBox(height: 14),
                  Text(name2,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SelectableText(h2,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                  const SizedBox(height: 16),
                  Text(
                    same ? '相同' : '不同',
                    style: TextStyle(
                      color: same
                          ? Theme.of(c).colorScheme.primary
                          : Theme.of(c).colorScheme.error,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _toast('计算 MD5 失败：$e');
    }
  }

  // ==================== 顶栏查重：先选范围，再查 ====================

  /// 顶栏查重按钮的入口。
  ///
  /// 原来一点就直接扫当前目录，用户没有反悔的余地。
  /// 现在先问一句「查哪个范围」：此目录 / 自定义目录。
  Future<void> _onTapDedupButton() async {
    final remembered = ref.read(dupScopeFoldersProvider);

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Image.asset(
                    'assets/images/dupebox_icon.png',
                    width: 20,
                    height: 20,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '查重哪个范围？',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('查重此目录'),
              subtitle: Text(
                _currentPath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => Navigator.pop(c, 'current'),
            ),
            ListTile(
              leading: const Icon(Icons.checklist),
              title: const Text('自定义目录'),
              subtitle: Text(
                remembered.isEmpty
                    ? '自己勾选一个或多个文件夹'
                    : '已记住 ${remembered.length} 个目录',
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => Navigator.pop(c, 'custom'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );

    if (choice == 'current') {
      await _findDuplicatesCurrentFolder();
    } else if (choice == 'custom') {
      await _runCustomDupScan();
    }
  }

  /// 自定义目录查重的完整流程：
  ///   记住过 → 先问「沿用 / 重选」；
  ///   没记住 → 直接打开选择器；
  ///   选完   → 问「要不要记住」；
  ///   最后   → 发起扫描。
  Future<void> _runCustomDupScan() async {
    final remembered = ref.read(dupScopeFoldersProvider);

    if (remembered.isNotEmpty) {
      final act = await _askReuseRememberedScope(remembered);
      if (act == null || !mounted) return;
      if (act == 'reuse') {
        await _launchDupScan(_dedupFolders(remembered));
        return;
      }
    }

    final picked = await _pickDupFolders(remembered);
    if (picked == null || !mounted) return;
    if (picked.isEmpty) {
      _toast('没有勾选任何文件夹');
      return;
    }

    // 选完范围、要真的去查了，才问记不记住。
    final remember = await _askRememberScope(picked);
    if (!mounted) return;
    ref
        .read(dupScopeFoldersProvider.notifier)
        .setAll(remember == true ? picked : const <String>[]);
    if (remember == true) {
      _toast('已记住 ${picked.length} 个目录，下次点查重直接沿用');
    }
    await _launchDupScan(_dedupFolders(picked));
  }

  /// 打开文件夹勾选器。首次使用会叠一层引导（高亮勾选区 / 进入区）。
  Future<List<String>?> _pickDupFolders(List<String> initial) async {
    final needGuide = !ref.read(dupScopeGuideSeenProvider);
    final result = await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SearchFolderPickerDialog(
        rootPath: _topPath,
        initialPath: _currentPath,
        initialSelected: initial,
        titleText: '勾选要查重的文件夹',
        showGuide: needGuide,
      ),
    );
    if (needGuide) {
      ref.read(dupScopeGuideSeenProvider.notifier).update(true);
    }
    return result;
  }

  /// 已有记住的范围时，问是沿用还是重新选。
  Future<String?> _askReuseRememberedScope(List<String> folders) {
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('查重范围'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('上次记住了这些目录：'),
              const SizedBox(height: 8),
              ...folders.take(4).map(
                    (p) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '· ${p.split('/').last}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
              if (folders.length > 4)
                Text(
                  '· 等共 ${folders.length} 个',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'reselect'),
            child: const Text('重新选'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'reuse'),
            child: const Text('用这些'),
          ),
        ],
      ),
    );
  }

  /// 选完范围、发起查重之前，问要不要记住。
  ///
  /// 两个选项都把后果写清楚，避免用户随手一点后不知道会发生什么。
  Future<bool?> _askRememberScope(List<String> folders) {
    return showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('记住这次的扫描范围吗？'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '已勾选 ${folders.length} 个文件夹。',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              const Text(
                '记住：\n'
                '下次点查重直接用这些目录，不用再选一遍。\n'
                '想换范围时，在同一个菜单里选「重新选」即可。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 10),
              const Text(
                '不记住：\n'
                '只查这一次。下次点查重会重新打开选择器让你再选。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('不记住'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('记住'),
          ),
        ],
      ),
    );
  }

  /// 选中单个文件夹时，跳转到 DupeBox 对该文件夹进行重复扫描。
  /// 通过原生通道拉起 DupeBox（com.dupebox.dupe_box）并传入真实文件夹路径。
  Future<void> _findDuplicates() async {
    final sel = _resolveSelectedItems();
    // 支持多选文件夹：仅取其中所有文件夹，至少 1 个才发起扫描。
    final folders = sel.where((it) => it.isDir).map((it) => it.key).toList();
    if (folders.isEmpty) return;
    await _launchDupScan(folders);
  }

  /// 向 DupeBox 发起对给定文件夹列表的重复扫描（统一深链通道）。
  /// 返回是否成功发起（未装 DupeBox 等情况返回 false 并 toast）。
  Future<bool> _launchDupScan(List<String> folders) async {
    if (folders.isEmpty) return false;
    try {
      await const MethodChannel('docdiff/dupebox_launcher')
          .invokeMethod('scanFolder', {'folderPaths': folders});
      return true;
    } on PlatformException catch (e) {
      final msg = e.code == 'NO_DUPEBOX'
          ? '未安装 DupeBox，请先安装后重试'
          : (e.message ?? '无法启动 DupeBox');
      if (!mounted) return false;
      _toast(msg);
      return false;
    }
  }

  /// 对「当前所在文件夹」直接发起查重：单文件夹深链跳转到 DupeBox。
  /// 满足“点进文件夹就能查”的预期，无需先回到上级再多选。
  Future<void> _findDuplicatesCurrentFolder() async {
    // _currentPath 即当前目录的真实路径，作为深链 roots 使用。
    final folder = _currentPath;
    if (folder.isEmpty) return;
    try {
      await const MethodChannel('docdiff/dupebox_launcher')
          .invokeMethod('scanFolder', {
        'folderPaths': <String>[folder],
      });
    } on PlatformException catch (e) {
      final msg = e.code == 'NO_DUPEBOX'
          ? '未安装 DupeBox，请先安装后重试'
          : (e.message ?? '无法启动 DupeBox');
      if (!mounted) return;
      _toast(msg);
    }
  }

  // ==================== 查重暂存篮 ====================

  /// 把当前选中的文件夹（多选也支持）加入查重暂存篮，去重。
  void _addSelectionToBasket() {
    final sel = _resolveSelectedItems();
    final folders = sel.where((it) => it.isDir).map((it) => it.key).toList();
    if (folders.isEmpty) return;
    final cur = ref.read(dupBasketProvider);
    final next = <String>[...cur];
    for (final f in folders) {
      if (!next.contains(f)) next.add(f);
    }
    ref.read(dupBasketProvider.notifier).state = next;
    _toast('已加入去重盒子扫描范围（${next.length}）');
  }

  /// 从暂存篮移除某个路径（管理弹窗内单条删除用）。
  void _removeFromBasket(String path) {
    final cur = ref.read(dupBasketProvider);
    ref.read(dupBasketProvider.notifier).state =
        cur.where((p) => p != path).toList();
  }

  /// 清空暂存篮。
  void _clearBasket() {
    ref.read(dupBasketProvider.notifier).state = const [];
  }

  /// 用暂存篮里的所有文件夹发起查重。
  ///
  /// 注意：深链是 fire-and-forget——只要 DupeBox 已安装就返回成功，无法得知
  /// 对方是否真的开扫（例如「全盘访问」权限不足时 DupeBox 会直接拒绝，
  /// 而这里收不到任何失败通知）。因此不再发送后自动清空，避免用户辛苦
  /// 跨层级收集的目录被静默丢弃；改为弹一条带「清空」操作的提示，
  /// 由用户自己决定何时清空。
  Future<void> _launchDupScanFromBasket() async {
    final basket = ref.read(dupBasketProvider);
    final ok = await _launchDupScan(basket);
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('已发送到 DupeBox（扫描范围已保留，方便重试）'),
        action: SnackBarAction(
          label: '清空',
          onPressed: _clearBasket,
        ),
      ),
    );
  }

  /// 打开“去重盒子扫描范围”管理弹窗：查看/增删路径，确认后一次性传给 DupeBox。
  Future<void> _openDupBasketSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            final basket = ref.watch(dupBasketProvider);
            final s = Theme.of(context).colorScheme;
            return SafeArea(
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                decoration: BoxDecoration(
                  color: s.brightness == Brightness.light
                      ? Colors.white
                      : s.surface,
                  border: Border(
                    top: BorderSide(color: s.outlineVariant),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '去重盒子扫描范围（${basket.length}）',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (basket.isNotEmpty)
                            TextButton(
                              onPressed: () {
                                _clearBasket();
                                setSheet(() {});
                              },
                              child: const Text('清空'),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    if (basket.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '暂无文件夹。在任意层级选中文件夹后，\n点底部「加入扫描范围」（在「去查重」旁边）即可添加。',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight:
                              MediaQuery.of(context).size.height * 0.5,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: basket.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final p = basket[i];
                            return ListTile(
                              leading: const Icon(Icons.folder_outlined),
                              title: Text(p.split('/').last),
                              subtitle: Text(
                                p,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: '移除',
                                onPressed: () {
                                  _removeFromBasket(p);
                                  setSheet(() {});
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Text(
                        '提示：DupeBox 需「全盘访问」权限才能按路径扫描这些目录。'
                        '若跳转后提示权限不足，请先到 DupeBox 设置里开启，'
                        '扫描范围已保留可直接重试。',
                        style: TextStyle(
                          fontSize: 12,
                          color: s.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: Image.asset(
                            'assets/images/dupebox_icon.png',
                            width: 18,
                            height: 18,
                          ),
                          label: const Text('去 DupeBox 查重'),
                          onPressed: basket.isEmpty
                              ? null
                              : () => _launchDupScanFromBasket(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 底部“去重盒子扫描范围”条：非空时显示，点开管理、一键去查重。
  Widget _buildDupBasketBar() {
    final basket = ref.watch(dupBasketProvider);
    final s = Theme.of(context).colorScheme;
    return Container(
      // 顶边不再画线：整块的边界由 _buildBottomOverlay 的羽化带统一处理，
      // 这里再画一条就会在渐变下面冒出一道硬边。
      color: s.brightness == Brightness.light ? Colors.white : s.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: _openDupBasketSheet,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  children: [
                    Image.asset(
                      'assets/images/dupebox_icon.png',
                      width: 18,
                      height: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '去重盒子扫描范围（${basket.length}）',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.expand_less, size: 18),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          OutlinedButton(
            onPressed: _openDupBasketSheet,
            child: const Text('管理'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: () => _launchDupScanFromBasket(),
            child: const Text('去查重'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportFolderListing() async {
    if (_selectedPaths.length != 1) {
      _toast('导出清单一次只能选一个文件夹');
      return;
    }
    final items = _resolveSelectedItems();
    if (items.isEmpty || !items[0].isDir) {
      _toast('导出清单只能用于文件夹');
      return;
    }
    final path = items[0].diskPath;
    if (path == null) {
      _toast('此文件夹不在磁盘上');
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    Uint8List bytes;
    try {
      bytes = await compute(_folderListingWorker, path);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _toast('扫描失败：$e');
      return;
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    final name = path.split('/').last;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final out = await FilePicker.saveFile(
      fileName: '$name-list-$ts.txt',
      bytes: bytes,
      mimeType: 'text/plain',
      dialogTitle: '保存文件夹清单',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (out != null && mounted) {
      _toast('清单已导出');
    }
  }

  Future<void> _showProperties() async {
    if (_selectedPaths.isEmpty) return;
    final items = _resolveSelectedItems();
    if (items.isEmpty) return;

    // 多选：只做统计，不进下面那个带 MD5 的单文件弹窗。
    if (items.length > 1) {
      await _showMultiProperties(items);
      return;
    }
    final it = items[0];

    if (it.isZipInner) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          insetPadding: _dlgInset,
          titlePadding: _dlgTitlePad,
          contentPadding: _dlgContentPad,
          actionsPadding: _dlgActionsPad,
          title: const Text('属性'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _propRow(context, '名称', it.displayName),
                _propRow(context, '来源', it.fullDisplayPath),
                _propRow(context, '类型', it.isDir ? '文件夹' : '文件'),
                _propRow(
                  context,
                  '大小',
                  it.size == null ? '—' : _formatSize(it.size),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }

    final path = it.diskPath;
    if (path == null) return;
    final name = it.displayName;

    int? size;
    DateTime? modified;
    DateTime? accessed;
    bool isDir = false;
    try {
      final st = await FileStat.stat(path);
      modified = st.modified;
      accessed = st.accessed;
      size = st.size;
      isDir = st.type == FileSystemEntityType.directory;
    } catch (_) {}

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _PropertiesDialog(
        name: name,
        path: path,
        isDir: isDir,
        size: size,
        modified: modified,
        accessed: accessed,
      ),
    );
  }

  /// 多选属性：只统计，不算 MD5（⋯ 菜单里已有「MD5对比」）。
  /// 大小/时间优先用列表里已有的元数据；缺了才补一次 FileStat.stat，
  /// 所以两个普通文件通常是零额外读盘，点开即出。
  Future<void> _showMultiProperties(List<_DisplayItem> items) async {
    final details = <_PropDetail>[];
    int fileCount = 0;
    int dirCount = 0;
    int? totalBytes = 0;
    bool hasUnknownSize = false;
    DateTime? newest;
    String? newestName;
    DateTime? oldest;
    String? oldestName;

    for (final it in items) {
      int? size = it.size;
      DateTime? modified = it.modified;
      // 磁盘项缺元数据时补一次 stat；压缩包内的条目只能用它自带的 size。
      final p = it.diskPath;
      if ((size == null || modified == null) && p != null) {
        try {
          final st = await FileStat.stat(p);
          size ??= st.size;
          modified ??= st.modified;
        } catch (_) {}
      }

      if (it.isDir) {
        // 跟单文件属性一致：文件夹大小显示 —，也不计入总大小。
        dirCount++;
      } else if (size == null) {
        hasUnknownSize = true;
      } else {
        totalBytes = (totalBytes ?? 0) + size;
      }

      if (modified != null) {
        if (newest == null || modified.isAfter(newest)) {
          newest = modified;
          newestName = it.displayName;
        }
        if (oldest == null || modified.isBefore(oldest)) {
          oldest = modified;
          oldestName = it.displayName;
        }
      }

      details.add(_PropDetail(
        name: it.displayName,
        path: p,
        isDir: it.isDir,
        size: size,
        modified: modified,
      ));
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) {
        final s = Theme.of(c).colorScheme;

        Widget kv(String label, String value) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(c).textTheme.labelSmall),
                  const SizedBox(height: 2),
                  SelectableText(value, style: const TextStyle(fontSize: 13)),
                ],
              ),
            );

        final sizeNote = dirCount > 0
            ? '（不含文件夹）'
            : (hasUnknownSize ? ' + 部分未统计' : '');
        final sizeText = '${_formatSize(totalBytes)}$sizeNote';

        return AlertDialog(
          insetPadding: const EdgeInsets.all(16),
          title: const Text('属性'),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(c).size.height * 0.7,
            ),
            child: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '已选 ${items.length} 项',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "$fileCount 个文件${dirCount > 0 ? ' · $dirCount 个文件夹' : ''}",
                      style: TextStyle(fontSize: 13, color: s.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    kv('总大小', sizeText),
                    if (dirCount == 0 && !hasUnknownSize && items.length > 1)
                      kv('平均大小', _formatSize(totalBytes! ~/ items.length)),
                    if (newest != null)
                      kv('最新修改', '$newestName（${_formatTimeFull(newest!)}）'),
                    if (oldest != null && oldest != newest)
                      kv('最旧修改', '$oldestName（${_formatTimeFull(oldest!)}）'),
                    const SizedBox(height: 4),
                    const Divider(height: 1),
                    const SizedBox(height: 10),
                    Text(
                      '明细',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: s.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ...List.generate(details.length, (i) {
                      final d = details[i];
                      final sizeLabel = d.isDir
                          ? '—'
                          : (d.size == null ? '大小未知' : _formatSize(d.size));
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${i + 1}. ',
                                    style: const TextStyle(fontSize: 13)),
                                Expanded(
                                  child: Text(
                                    d.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                sizeLabel,
                                if (d.modified != null)
                                  '修改 ${_formatTime(d.modified)}',
                              ].join(' · '),
                              style: TextStyle(
                                fontSize: 12,
                                color: s.onSurfaceVariant,
                              ),
                            ),
                            if (d.path != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: SelectableText(
                                  d.path!,
                                  maxLines: 2,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: s.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Widget _propRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 2),
          SelectableText(value),
        ],
      ),
    );
  }

  Future<void> _openWithApp() async {
    if (_selectedPaths.length != 1) return;
    final items = _resolveSelectedItems();
    if (items.isEmpty) return;
    final it = items[0];
    if (it.isDir) {
      _toast('文件夹不能"打开方式"');
      return;
    }
    if (it.isZipInner) {
      final bytes = _readZipInnerBytes(it);
      if (bytes == null) {
        _toast('读取失败');
        return;
      }
      final tmp = await _writeTempFile(bytes, it.displayName);
      if (tmp == null) {
        _toast('无法创建临时文件');
        return;
      }
      if (!mounted) return;
      await openFileWithSystemPicker(tmp, context);
      return;
    }
    final p = it.diskPath;
    if (p == null) return;
    await openFileWithSystemPicker(p, context);
  }

  /// 「对比(w)」：把选中的两个文件直接交给 WinMerge Mobile（包名 com.winmergemobile）
  /// 去对比。原生侧会发 ACTION_SEND_MULTIPLE 并指定该包名，对方把第一个当左栏、
  /// 第二个当右栏，一步进对比页；不弹系统分享面板。
  ///
  /// 与「对比」按钮共用 canCompare 判定（正好两个、且都是可对比的文件）。
  /// 压缩包内条目先落地成临时文件，再交给对方；磁盘文件直接给绝对路径。
  /// 未安装该 App 时原生侧返回特定错误码，这里弹提示，不做任何跳转。
  static const _winMergeChannel = MethodChannel('docdiff/winmerge_launcher');

  Future<void> _compareWithWinMerge() async {
    if (_selectedPaths.length != 2) return;
    final items = _resolveSelectedItems();
    if (items.length != 2) return;

    final paths = <String>[];
    for (final it in items) {
      if (it.isDir) {
        _toast('对比只支持文件，请勿选中文件夹');
        return;
      }
      if (it.isZip && !it.isZipInner) {
        _toast('对比不支持直接对比压缩包本身，请展开后选里面的文件');
        return;
      }
      if (it.isZipInner) {
        final bytes = _readZipInnerBytes(it);
        if (bytes == null) {
          _toast('读取压缩包内文件失败');
          return;
        }
        final tmp = await _writeTempFile(bytes, it.displayName);
        if (tmp == null) {
          _toast('解压临时文件失败');
          return;
        }
        paths.add(tmp);
      } else {
        final p = it.diskPath;
        if (p == null) {
          _toast('找不到选中的文件');
          return;
        }
        paths.add(p);
      }
    }
    if (paths.length != 2) return;

    try {
      await _winMergeChannel.invokeMethod<bool>(
        'openInWinMerge',
        {'paths': paths},
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      switch (e.code) {
        case 'NO_WINMERGE':
          _toast('未安装 WinMerge Mobile，请先安装再使用对比(w)');
          break;
        case 'NO_FILE':
          _toast('文件不存在或已被删除');
          break;
        default:
          _toast('交给 WinMerge 失败：${e.message ?? e.code}');
      }
    } catch (e) {
      if (!mounted) return;
      _toast('交给 WinMerge 失败：$e');
    }
  }

  Future<void> _shareSelected() async {
    if (_selectedPaths.isEmpty) return;
    final items = _resolveSelectedItems();

    final diskPaths = <String>[];
    final tempPaths = <String>[];
    for (final it in items) {
      if (it.isZipInner) {
        final bytes = _readZipInnerBytes(it);
        if (bytes == null) continue;
        final tmp = await _writeTempFile(bytes, it.displayName);
        if (tmp != null) tempPaths.add(tmp);
      } else {
        final p = it.diskPath;
        if (p != null) diskPaths.add(p);
      }
    }

    final all = <String>[...diskPaths, ...tempPaths];
    if (all.isEmpty) {
      _toast('没有可分享的文件');
      return;
    }
    if (!mounted) return;
    await shareMany(all, context);
  }

  Future<void> _copyPath() async {
    if (_selectedPaths.length != 1) return;
    final items = _resolveSelectedItems();
    if (items.isEmpty) return;
    final it = items[0];
    final path = it.isZipInner ? it.fullDisplayPath : (it.diskPath ?? '');
    if (path.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (mounted) _toast('路径已复制');
  }

  static String _formatTimeFull(DateTime t) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // ==================== 视图弹窗 ====================

  String _sortLabel(SortField f) {
    switch (f) {
      case SortField.name:
        return '名称';
      case SortField.modified:
        return '修改时间';
      case SortField.size:
        return '大小';
    }
  }

// ==================== 当前目录信息 ====================

Future<void> _showDirInfoDialog() async {
  if (_loading) {
    _toast('目录还在加载中，请稍候');
    return;
  }

  final entries = _entries ?? const <EntryInfo>[];

  var dirCount = 0;
  var fileCount = 0;
  var totalBytes = 0;
  var hasUnknownSize = false;

  var textCount = 0;
  var imageCount = 0;
  var videoCount = 0;
  var audioCount = 0;
  var archiveCount = 0;
  var otherCount = 0;

  int? maxSize;
  String? maxSizeName;
  DateTime? newestTime;
  String? newestName;
  DateTime? oldestTime;
  String? oldestName;

  for (final info in entries) {
    if (info.isDir) {
      dirCount++;
      continue;
    }
    fileCount++;

    final sz = info.size;
    if (sz != null) {
      totalBytes += sz;
      if (maxSize == null || sz > maxSize) {
        maxSize = sz;
        maxSizeName = info.name;
      }
    } else {
      hasUnknownSize = true;
    }

    final t = info.modified;
    if (t != null) {
      if (newestTime == null || t.isAfter(newestTime)) {
        newestTime = t;
        newestName = info.name;
      }
      if (oldestTime == null || t.isBefore(oldestTime)) {
        oldestTime = t;
        oldestName = info.name;
      }
    }

    final ext = _extOf(info.name);
    if (_textExts.contains(ext)) {
      textCount++;
    } else if (_imageExts.contains(ext)) {
      imageCount++;
    } else if (_videoExts.contains(ext)) {
      videoCount++;
    } else if (_audioExts.contains(ext)) {
      audioCount++;
    } else if (_archiveExts.contains(ext)) {
      archiveCount++;
    } else {
      otherCount++;
    }
  }

  if (!mounted) return;

  final sortField = ref.read(sortFieldProvider);
  final sortAsc = ref.read(sortAscProvider);
  final gridMode = ref.read(browserGridModeProvider);

  String sizeText;
  if (hasUnknownSize) {
    sizeText = '${_formatSize(totalBytes)} + 部分未统计';
  } else {
    sizeText = _formatSize(totalBytes);
  }

  await showDialog<void>(
    context: context,
    builder: (c) {
      final s = Theme.of(c).colorScheme;

      Widget kv(String label, String value, {bool selectable = false}) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(c).textTheme.labelSmall),
              const SizedBox(height: 2),
              selectable
                  ? SelectableText(value, style: const TextStyle(fontSize: 13))
                  : Text(value, style: const TextStyle(fontSize: 13)),
            ],
          ),
        );
      }

      return AlertDialog(
        insetPadding: const EdgeInsets.all(16),
        title: const Text('当前目录信息'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(c).size.height * 0.7,
          ),
          child: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  kv('路径', _currentPath, selectable: true),
                  const SizedBox(height: 4),

                  Text(
                    '共 ${entries.length} 项',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$dirCount 个文件夹 · $fileCount 个文件',
                    style: TextStyle(
                      fontSize: 13,
                      color: s.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),

                  kv('总大小（不含子目录）', sizeText),

                  if (maxSizeName != null)
                    kv('最大文件',
                        '$maxSizeName（${_formatSize(maxSize!)}）'),

                  if (newestTime != null)
                    kv('最新文件',
                        '$newestName（${_formatTime(newestTime!)}）'),

                  if (oldestTime != null)
                    kv('最旧文件',
                        '$oldestName（${_formatTime(oldestTime!)}）'),

                  kv('当前排序',
                      '${_sortLabel(sortField)} · ${sortAsc ? "升序" : "降序"}'),

                  kv('显示模式', gridMode ? '网格' : '列表'),

                  const SizedBox(height: 4),
                  const Divider(height: 1),
                  const SizedBox(height: 8),

                  Text(
                    '类型分布',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: s.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '文本 $textCount · 图片 $imageCount · 视频 $videoCount · '
                    '音频 $audioCount · 压缩包 $archiveCount · 其他 $otherCount',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}

  // ==================== 收藏 / 配置 ====================

  void _toggleSearchBarCollapsed() {
    final notifier = ref.read(searchBarCollapsedProvider.notifier);
    final currentlyCollapsed = ref.read(searchBarCollapsedProvider);

    if (currentlyCollapsed) {
      // 极简：展开只显示搜索栏，不自动聚焦、不弹键盘、不出光标。
      // 原来 300ms 后 requestFocus，会「一展开就弹键盘」，还与
      // 240ms 边框光晕、260ms 卷帘抢同一帧导致闪烁。用户点输入框才聚焦。
      notifier.update(false);
    } else {
      // 折叠：只收起 UI，不清空搜索内容（对标 Solid Explorer）。
      // 想清空请用输入框右边的 × 按钮。
      FocusManager.instance.primaryFocus?.unfocus();
      notifier.update(true);
    }
  }

  /// 搜索栏区域当前是否可见。
  /// - 选择模式：始终可见（显示提示条）
  /// - 始终显示：可见
  /// - 可折叠 + 已折叠：隐藏
  bool get _searchBarAreaVisible {
    if (_selectionMode) return true;
    if (ref.watch(searchBarVisibilityProvider) ==
        SearchBarVisibility.alwaysVisible) {
      return true;
    }
    return !ref.watch(searchBarCollapsedProvider);
  }

  void _toggleFavorite() {
    final favs = ref.read(favoritesProvider);
    final wasFav = favs.contains(_currentPath);
    ref.read(favoritesProvider.notifier).toggle(_currentPath);
    _toast(wasFav ? '已取消收藏' : '已收藏当前目录');
  }

  /// 导入 / 导出合并成一个入口，点开后再选方向。
  Future<void> _showConfigIoMenu() async {
    final action = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: _dlgInset,
        title: const Text('配置导入导出'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('导出配置'),
                onPressed: () => Navigator.pop(c, 'export'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.download_for_offline_outlined, size: 18),
                label: const Text('导入配置'),
                onPressed: () => Navigator.pop(c, 'import'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'export') {
      await _exportConfig();
    } else {
      await _importConfig();
    }
  }

  Future<void> _exportConfig() async {
    try {
      final ok = await ConfigIoService.instance.export();
      if (!mounted) return;
      if (ok) _toast('配置已导出');
    } catch (e) {
      if (mounted) _toast('导出失败：$e');
    }
  }

  Future<void> _importConfig() async {
    final result = await ConfigIoService.instance.import();
    if (!mounted) return;
    if (!result.ok && result.message == null) return;
    if (!result.ok) {
      _toast(result.message ?? '导入失败');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('导入成功'),
        content: const Text(
          '配置已导入。请手动退出 App 再重新打开，配置才会生效。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _showFavorites() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setInnerState) {
          final favorites = ref.watch(favoritesProvider);
          final isFav = favorites.contains(_currentPath);
          final cs = Theme.of(context).colorScheme;

          return AlertDialog(
            insetPadding: const EdgeInsets.all(16),
            title: const Text('已收藏目录'),
            content: SizedBox(
              width: 360,
              height: MediaQuery.of(context).size.height * 0.55,
              child: Column(
                children: [
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        isFav ? Icons.star : Icons.star_border,
                        color: isFav ? Colors.amber : cs.onSurfaceVariant,
                      ),
                      title: Text(
                        isFav ? '取消收藏当前目录' : '收藏当前目录',
                        style: TextStyle(color: cs.onSurface),
                      ),
                      subtitle: Text(
                        _currentPath,
                        style: const TextStyle(fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        ref
                            .read(favoritesProvider.notifier)
                            .toggle(_currentPath);
                        setInnerState(() {});
                      },
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: favorites.isEmpty
                          ? Center(
                              child: Text(
                                '还没有收藏任何目录',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: favorites.length,
                              itemBuilder: (ctx, i) {
                                final p = favorites[i];
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: const AppFileIcon(isDir: true),
                                  title: Text(
                                    p,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => Navigator.pop(c, p),
                                  trailing: IconButton(
                                    icon: Icon(
                                      Icons.delete_outline,
                                      size: 20,
                                      color: cs.onSurfaceVariant,
                                    ),
                                    tooltip: '移除收藏',
                                    onPressed: () async {
                                      final ok = await showDialog<bool>(
                                        context: ctx,
                                        builder: (dc) => AlertDialog(
                                          title: const Text('移除收藏？'),
                                          content: Text(p),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(dc, false),
                                              child: const Text('取消'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(dc, true),
                                              child: const Text('移除'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (ok != true) return;
                                      ref
                                          .read(favoritesProvider.notifier)
                                          .remove(p);
                                      setInnerState(() {});
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    if (picked != null && mounted) {
  if (Directory(picked).existsSync()) {
    _navigateTo(picked);
  } else {
    // 权限被收回时 existsSync 也会返回 false。
    // 不自动删收藏，让用户自己决定。
    final action = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: _dlgInset,
        title: const Text('目录打不开'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('无法访问：', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(
              picked,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '可能原因：\n'
              '· 目录已被删除或重命名\n'
              '· 存储卡已拔出\n'
              '· 文件访问权限被收回',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            const Text(
              '这条收藏要保留吗？',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('保留'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, 'remove'),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (action == 'remove' && mounted) {
      ref.read(favoritesProvider.notifier).remove(picked);
      _toast('已移除');
    }
  }
}
  }

  // ==================== 文件操作 ====================

  // 记录上一次 toast 的消息和时间，用于"短时间内相同消息不重复弹"。
  String? _lastToastMsg;
  DateTime? _lastToastTime;

  void _toast(String msg) {
    if (!mounted) return;

    // 去重：1.5 秒内同一条消息不再重弹。
    final now = DateTime.now();
    if (_lastToastMsg == msg &&
        _lastToastTime != null &&
        now.difference(_lastToastTime!) < const Duration(milliseconds: 1500)) {
      return;
    }
    _lastToastMsg = msg;
    _lastToastTime = now;

    final ms = msg.length <= 10 ? 1500 : 2000;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onInverseSurface,
            fontWeight: FontWeight.bold,
          ),
        ),
        duration: Duration(milliseconds: ms),
        // 悬浮样式：浮在底部操作栏上方，不会被遮挡。
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: 72,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<bool> _confirm(String title, String message) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 32,
          vertical: 24,
        ),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  List<String> _selectedDiskPaths() {
    final out = <String>[];
    for (final p in _selectedPaths) {
      if (_isZipInnerKey(p)) continue;
      out.add(p);
    }
    return out;
  }

  Future<void> _rename() async {
    // 多选：转批量重命名
    if (_selectedPaths.length > 1) {
      await _batchRename();
      return;
    }

    if (_selectedPaths.length != 1) {
      _toast('重命名一次只能操作一个');
      return;
    }
    final key = _selectedPaths.first;
    if (_isZipInnerKey(key)) {
      _toast('压缩包内的文件不支持重命名');
      return;
    }
    final oldPath = key;
    final oldName = oldPath.split('/').last;

    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _TextInputDialog(
        title: '重命名',
        initialValue: oldName,
      ),
    );
    if (newName == null) return;

    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == oldName) return;
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      _toast('名称不能包含斜杠');
      return;
    }
    if (trimmed == '.' || trimmed == '..') {
      _toast('名称无效');
      return;
    }

    final parent = File(oldPath).parent.path;
    final newPath = '$parent/$trimmed';

    if (FileSystemEntity.typeSync(newPath) !=
        FileSystemEntityType.notFound) {
      _toast('目标已存在：$trimmed');
      return;
    }

    try {
      if (Directory(oldPath).existsSync()) {
        await Directory(oldPath).rename(newPath);
      } else {
        await File(oldPath).rename(newPath);
      }
  DirCache.instance.invalidate(_currentPath);
_clearSelection();
_load(restoreScroll: true, silent: true);
_toast('已重命名为 $trimmed');
    } catch (e) {
      _toast('重命名失败：$e');
    }
  }

  // ==================== 批量重命名：执行 ====================

  Future<void> _batchRename() async {
    var paths = _selectedDiskPaths();
    if (paths.isEmpty) {
      _toast('压缩包内的文件不支持重命名');
      return;
    }

    // 同时选中了文件夹和它内部子项时，去掉子项（父级改名后子路径失效）
    paths = [
      for (final p in paths)
        if (!paths.any((q) => q != p && p.startsWith('$q/'))) p
    ];

    // 把当前列表的显示顺序带进弹窗，供「列表顺序」排序使用。
    final visible = _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final selectedSet = paths.toSet();
    final orderHint = <String>[
      for (final it in visible)
        if (selectedSet.contains(it.key)) it.key,
    ];
    for (final p in paths) {
      if (!orderHint.contains(p)) orderHint.add(p);
    }

    final outcome = await showDialog<_BatchRenameOutcome>(
      context: context,
      builder: (_) {
        // 仅作用于批量重命名弹窗子树：把 near-black 的 onSurface(#1C1C1C)
        // 压成纯黑 #000000，使弹窗内所有文字（含继承文字/标题/文字按钮）
        // 统一纯黑，与写死 Colors.black 的「添加变量」按钮一致。
        // 不影响文件浏览器/阅读器等其它界面（那些仍走全局 onSurface）。
        final t = Theme.of(_);
        return Theme(
          data: t.copyWith(
            colorScheme: t.colorScheme.copyWith(onSurface: Colors.black),
            textTheme: t.textTheme.apply(
                bodyColor: Colors.black, displayColor: Colors.black),
            dialogTheme: t.dialogTheme.copyWith(
              contentTextStyle:
                  const TextStyle(color: Colors.black, fontSize: 14),
              titleTextStyle: const TextStyle(
                  color: Colors.black, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(foregroundColor: Colors.black),
            ),
          ),
          child: _BatchRenameDialog(
            paths: paths,
            orderHint: orderHint,
            onUndo: _undoLastBatchRename,
          ),
        );
      },
    );
    if (outcome == null || outcome.renames.isEmpty || !mounted) return;
    final result = outcome.renames;
    final skipped = outcome.skipped;

    // 两阶段改名，避免链式覆盖（a→b、b→c）
    var ok = 0;
    var fail = 0;
    final tempMap = <String, String>{};
    final undoMap = <String, String>{};

    // 阶段 1：全部改成临时名
    for (final oldPath in result.keys) {
      final tmp =
          '$oldPath.renaming_${DateTime.now().microsecondsSinceEpoch}';
      try {
        if (Directory(oldPath).existsSync()) {
          await Directory(oldPath).rename(tmp);
        } else {
          await File(oldPath).rename(tmp);
        }
        tempMap[oldPath] = tmp;
      } catch (_) {
        fail++;
      }
    }

    // 阶段 2：临时名 → 目标名
    for (final entry in result.entries) {
      final tmp = tempMap[entry.key];
      if (tmp == null) continue;
      try {
        if (Directory(tmp).existsSync()) {
          await Directory(tmp).rename(entry.value);
        } else {
          await File(tmp).rename(entry.value);
        }
        ok++;
        // 撤销记录要存「新路径 → 旧路径」：撤销时 key 是磁盘上现存的文件，
        // value 才是要改回去的名字。存反了撤销会全部失败。
        undoMap[entry.value] = entry.key;
      } catch (_) {
        // 阶段 2 失败：把临时名改回去，别留下奇怪后缀
        try {
          if (Directory(tmp).existsSync()) {
            await Directory(tmp).rename(entry.key);
          } else {
            await File(tmp).rename(entry.key);
          }
        } catch (_) {}
        fail++;
      }
    }

    // 只把真正改成功的项目记进撤销记录，失败的不记，否则撤销会指错文件。
    if (undoMap.isNotEmpty) {
      await RenamePresetStore.instance.saveUndo(undoMap);
    }
    DirCache.instance.invalidate(_currentPath);
    _clearSelection();
    _load(restoreScroll: true, silent: true);
    _toast('已重命名 $ok 项${fail > 0 ? "，$fail 项失败" : ""}'
        '${skipped > 0 ? "，另有 $skipped 项未改名（冲突/待确认）" : ""}');
  }

  /// 撤销上一次批量改名：把记录里的「新路径 → 旧路径」反向执行。
  /// 同样用两阶段临时名，避免链式覆盖；只记成功项，所以不会指错文件。
  Future<void> _undoLastBatchRename() async {
    final store = RenamePresetStore.instance;
    final map = await store.loadUndo();
    if (map == null || map.isEmpty) {
      _toast('没有可撤销的批量改名');
      return;
    }

    // 撤销是「改回原名」。如果原名已经被别的文件占住，直接 rename 会
    // 静默覆盖对方；宁可整个不撤，保留记录让用户处理后再点一次。
    // 例外：目标正好也是本批要移走的源（链式改名），两阶段能安全处理。
    final blocked = <String>[
      for (final e in map.entries)
        if (!map.containsKey(e.value) &&
            FileSystemEntity.typeSync(e.value) !=
                FileSystemEntityType.notFound)
          e.value,
    ];
    if (blocked.isNotEmpty) {
      _toast('有 ${blocked.length} 个原名已被占用，为避免覆盖已取消撤销');
      return;
    }

    var ok = 0;
    var fail = 0;
    final tempMap = <String, String>{};
    final undone = <String>{};

    for (final e in map.entries) {
      final tmp = '${e.key}.undo_${DateTime.now().microsecondsSinceEpoch}';
      try {
        if (Directory(e.key).existsSync()) {
          await Directory(e.key).rename(tmp);
        } else {
          await File(e.key).rename(tmp);
        }
        tempMap[e.key] = tmp;
      } catch (_) {
        fail++;
      }
    }
    for (final e in map.entries) {
      final tmp = tempMap[e.key];
      if (tmp == null) continue;
      try {
        if (Directory(tmp).existsSync()) {
          await Directory(tmp).rename(e.value);
        } else {
          await File(tmp).rename(e.value);
        }
        ok++;
        undone.add(e.key);
      } catch (_) {
        try {
          if (Directory(tmp).existsSync()) {
            await Directory(tmp).rename(e.key);
          } else {
            await File(tmp).rename(e.key);
          }
        } catch (_) {}
        fail++;
      }
    }
    // 只清掉成功的项：部分失败时保留剩余记录，还能再点一次重试。
    // 以前是无条件 clearUndo，失败的那几项就再也撤不回来了。
    final remaining = <String, String>{
      for (final e in map.entries)
        if (!undone.contains(e.key)) e.key: e.value,
    };
    if (remaining.isEmpty) {
      await store.clearUndo();
    } else {
      await store.saveUndo(remaining);
    }
    DirCache.instance.invalidate(_currentPath);
    _clearSelection();
    _load(restoreScroll: true, silent: true);
    _toast('已撤销 $ok 项${fail > 0 ? "，$fail 项失败（可再点撤销重试）" : ""}');
  }

  Future<void> _move() async {
  final paths = _selectedDiskPaths();
  if (paths.isEmpty) {
    _toast('压缩包内的文件不支持移动');
    return;
  }
  final target = await _pickDirectory('移动到哪？', paths);
  if (target == null) return;

  // 冲突预检
  final conflictNames = <String>[];
  for (final src in paths) {
    final name = src.split('/').last;
    final dst = '$target/$name';
    if (src == dst) continue;
    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      conflictNames.add(name);
    }
  }

  _ConflictAction? action;
  if (conflictNames.isNotEmpty) {
    action = await _askConflict(conflictNames);
    if (action == null) return; // 用户取消
  }

 var ok = 0, fail = 0, skipped = 0;
final movedSources = <String>{};
for (final src in paths) {
    final name = src.split('/').last;
    var dst = '$target/$name';
    if (src == dst) continue;

    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      if (action == _ConflictAction.skip) {
        skipped++;
        continue;
      } else if (action == _ConflictAction.rename) {
        dst = _findNonConflictPath(dst);
      } else if (action == _ConflictAction.overwrite) {
        try {
          if (Directory(dst).existsSync()) {
            await Directory(dst).delete(recursive: true);
          } else {
            await File(dst).delete();
          }
        } catch (_) {}
      }
    }

    try {


		
       if (Directory(src).existsSync()) {
      await Directory(src).rename(dst);
    } else {
      await File(src).rename(dst);
    }
    ok++;
    movedSources.add(src);
  } catch (_) {
    fail++;
  }
}

 if (ok > 0) {
  ref.read(recentMoveTargetsProvider.notifier).add(target);
  DirCache.instance.invalidate(target);
}
_clearSelection();

if (movedSources.isNotEmpty && target != _currentPath) {
  // 目标不是当前目录：就地剔除源
  setState(() {
    _entries = (_entries ?? const <EntryInfo>[])
        .where((e) => !movedSources.contains(e.path))
        .toList();
  });
  DirCache.instance.applyToAll(
    _currentPath,
    (list) => list
        .where((e) => !movedSources.contains(e.path))
        .toList(),
  );
} else if (target == _currentPath) {
  // 目标就是当前目录（少见）：退化为静默重载
  _load(restoreScroll: true, silent: true);
}

final parts = <String>['已移动 $ok 项'];
	  
  if (skipped > 0) parts.add('跳过 $skipped 项');
  if (fail > 0) parts.add('$fail 项失败');
  _toast(parts.join('，'));
}

 Future<void> _copy() async {
  final paths = _selectedDiskPaths();
  if (paths.isEmpty) {
    _toast('压缩包内的文件不支持复制');
    return;
  }
  final target = await _pickDirectory('复制到哪？', paths);
  if (target == null) return;

  final conflictNames = <String>[];
  for (final src in paths) {
    final name = src.split('/').last;
    final dst = '$target/$name';
    if (src == dst) continue;
    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      conflictNames.add(name);
    }
  }

  _ConflictAction? action;
  if (conflictNames.isNotEmpty) {
    action = await _askConflict(conflictNames);
    if (action == null) return;
  }

  var ok = 0, fail = 0, skipped = 0;
  for (final src in paths) {
    final name = src.split('/').last;
    var dst = '$target/$name';
    if (src == dst) continue;

    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      if (action == _ConflictAction.skip) {
        skipped++;
        continue;
      } else if (action == _ConflictAction.rename) {
        dst = _findNonConflictPath(dst);
      } else if (action == _ConflictAction.overwrite) {
        try {
          if (Directory(dst).existsSync()) {
            await Directory(dst).delete(recursive: true);
          } else {
            await File(dst).delete();
          }
        } catch (_) {}
      }
    }

    try {
      if (Directory(src).existsSync()) {
        await _copyDir(Directory(src), Directory(dst));
      } else {
        await File(src).copy(dst);
      }
      ok++;
    } catch (_) {
      fail++;
    }
  }

if (ok > 0) {
  ref.read(recentMoveTargetsProvider.notifier).add(target);
  DirCache.instance.invalidate(target);
  if (target == _currentPath) {
    DirCache.instance.invalidate(_currentPath);
  }
}
_clearSelection();
_load(restoreScroll: true, silent: true);

final parts = <String>['已复制 $ok 项'];
  if (skipped > 0) parts.add('跳过 $skipped 项');
  if (fail > 0) parts.add('$fail 项失败');
  _toast(parts.join('，'));
}

  Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list(followLinks: false)) {
      final name = e.path.split('/').last;
      final target = '${dst.path}/$name';
      if (e is Directory) {
        await _copyDir(e, Directory(target));
      } else if (e is File) {
        await e.copy(target);
      }
    }
  }
Future<_ConflictAction?> _askConflict(List<String> conflictNames) async {
  return showDialog<_ConflictAction>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      insetPadding: _dlgInset,
      title: const Text('目标目录有同名项'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(c).size.height * 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('以下 ${conflictNames.length} 个名称已在目标目录中存在：'),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: conflictNames.length,
                itemBuilder: (ctx, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '· ${conflictNames[i]}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, _ConflictAction.skip),
          child: const Text('跳过'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(c).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(c, _ConflictAction.overwrite),
          child: const Text('覆盖'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, _ConflictAction.rename),
          child: const Text('重命名'),
        ),
      ],
    ),
  );
}

/// 给 dst 找一个不冲突的路径：加 " (1)" " (2)" 之类的后缀。
String _findNonConflictPath(String originalDst) {
  final dotIdx = originalDst.lastIndexOf('.');
  final slashIdx = originalDst.lastIndexOf('/');
  final hasExt = dotIdx > slashIdx && dotIdx < originalDst.length - 1;
  final base = hasExt ? originalDst.substring(0, dotIdx) : originalDst;
  final ext = hasExt ? originalDst.substring(dotIdx) : '';
  for (var i = 1; i < 10000; i++) {
    final candidate = '$base ($i)$ext';
    if (FileSystemEntity.typeSync(candidate) ==
        FileSystemEntityType.notFound) {
      return candidate;
    }
  }
  return '$base (${DateTime.now().millisecondsSinceEpoch})$ext';
}

  Future<void> _delete() async {
    final paths = _selectedDiskPaths();
    if (paths.isEmpty) {
      _toast('压缩包内的文件不支持删除');
      return;
    }
    final n = paths.length;
final ok = await showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _DeleteConfirmDialog(paths: paths),
);
if (ok != true) return;

    final deletedPaths = <String>{};
    var fail = 0;
    var trashed = 0; // 移入回收站的项数
    var direct = 0; // 直接物理删除的项数（文件夹 / 回收站写入失败回退）
    for (final p in paths) {
      try {
        if (Directory(p).existsSync()) {
          await Directory(p).delete(recursive: true);
          direct++;
        } else {
          // 文件删除：先移入共享回收站（fromDupeBox=false → 在 docdiff 回收站入口可见）；
          // 回收站不可用时退化为永久删除，绝不阻断用户删除。
          var moved = false;
          try {
            await ShareIntakeCoordinator.moveToSharedTrash(p, fromDupeBox: false);
            moved = true;
          } catch (_) {
            try {
              await File(p).delete();
            } on FileSystemException catch (_) {
              // 原文件已不存在（极少数：moveToSharedTrash 已删原文件）视为成功。
            }
          }
          if (moved) {
            trashed++;
          } else {
            direct++;
          }
        }
        deletedPaths.add(p);
      } catch (_) {
        fail++;
      }
    }

    final deleted = deletedPaths.length;
    _clearSelection();

    if (_searchActive) {
      final anchor = _snapshotVisiblePaths();
      setState(() {
        _searchResults = _searchResults.where((h) {
          if (deletedPaths.contains(h.path)) return false;
          for (final dp in deletedPaths) {
            if (h.path.startsWith('$dp/')) return false;
          }
          return true;
        }).toList();
      });
      if (anchor.isNotEmpty) _restoreScrollAnchor(anchor);
  
	
	} else {
  // 就地移除，不重载
  setState(() {
    _entries = (_entries ?? const <EntryInfo>[])
        .where((e) => !deletedPaths.contains(e.path))
        .toList();
  });
  DirCache.instance.applyToAll(
    _currentPath,
    (list) => list
        .where((e) => !deletedPaths.contains(e.path))
        .toList(),
  );
}

    final destNote = trashed > 0 && direct > 0
        ? '（$trashed 项已移入回收站，$direct 项直接删除无法恢复）'
        : trashed > 0
            ? '（已移入回收站，可在「⋯ → 回收站」恢复）'
            : direct > 0
                ? '（直接删除，无法恢复）'
                : '';
    _toast('已删除 $deleted 项$destNote${fail > 0 ? "，$fail 项失败" : ""}');
  }

  Future<void> _newFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _TextInputDialog(
        title: '新建文件夹',
        initialValue: '新建文件夹',
      ),
    );
    if (name == null) return;

    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _toast('名称不能为空');
      return;
    }
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      _toast('名称不能包含斜杠');
      return;
    }
    if (trimmed == '.' || trimmed == '..') {
      _toast('名称无效');
      return;
    }

    final path = '$_currentPath/$trimmed';
    if (FileSystemEntity.typeSync(path) !=
        FileSystemEntityType.notFound) {
      _toast('同名文件或文件夹已存在');
      return;
    }
    try {
     await Directory(path).create();
DirCache.instance.invalidate(_currentPath);
_load(silent: true);
_toast('已新建 $trimmed');
    } catch (e) {
      _toast('新建失败：$e');
    }
  }

  Future<void> _showJumpToPathDialog() async {
    final ctrl = TextEditingController();
    final cs = Theme.of(context).colorScheme;
    final path = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 32,
          vertical: 24,
        ),
        title: const Text('跳转到目录'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '输入或粘贴完整路径',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                autofocus: true,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '/storage/emulated/0/xxx',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: cs.primary, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                onSubmitted: (v) => Navigator.pop(c, v),
              ),
              const SizedBox(height: 8),
              Text(
                '若粘贴的是文件路径，会跳到该文件所在目录',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    ctrl.dispose();

    if (!mounted || path == null || path.isEmpty) return;

  var target = path.trim();
  if (target.isEmpty) return;

  // 常见路径前缀统一换成 /storage/emulated/0
  target = _normalizePath(target);

  if (FileSystemEntity.typeSync(target) == FileSystemEntityType.file) {
    target = File(target).parent.path;
  }

  if (!Directory(target).existsSync()) {
    _toast('目录不存在：$target');
    return;
  }
  if (!target.startsWith('/storage/')) {
    _toast('只能跳到 /storage 以内的路径');
    return;
  }
  _navigateTo(target);
}

/// 归一化用户粘贴的路径。
/// · /sdcard/...         → /storage/emulated/0/...
/// · /storage/self/primary/... → /storage/emulated/0/...
/// · /storage/emulated/legacy/... → /storage/emulated/0/...
/// · /mnt/sdcard/...     → /storage/emulated/0/...
String _normalizePath(String path) {
  const prefixes = <String, String>{
    '/sdcard/': '/storage/emulated/0/',
    '/sdcard': '/storage/emulated/0',
    '/mnt/sdcard/': '/storage/emulated/0/',
    '/mnt/sdcard': '/storage/emulated/0',
    '/storage/self/primary/': '/storage/emulated/0/',
    '/storage/self/primary': '/storage/emulated/0',
    '/storage/emulated/legacy/': '/storage/emulated/0/',
    '/storage/emulated/legacy': '/storage/emulated/0',
  };
  for (final e in prefixes.entries) {
    if (path.startsWith(e.key)) {
      return e.value + path.substring(e.key.length);
    }
  }
  return path;
}




	  
  

  Future<String?> _pickDirectory(String title, List<String> pickedPaths) async {
  return showDialog<String>(
    context: context,
    builder: (_) => DirectoryPickerDialog(
      title: title,
      rootPath: _topPath,
      initialPath: _currentPath,
      pickedPaths: pickedPaths,
    ),
  );
}

  // ==================== 面包屑 ====================

  List<({String label, String path})>? _crumbsCache;
  String? _crumbsCacheForPath;

  List<({String label, String path})> get _crumbs {
    if (_crumbsCacheForPath == _currentPath && _crumbsCache != null) {
      return _crumbsCache!;
    }
    final out = _computeCrumbs();
    _crumbsCacheForPath = _currentPath;
    _crumbsCache = out;
    return out;
  }

  List<({String label, String path})> _computeCrumbs() {
    if (_currentPath == _topPath) {
      return [(label: '存储', path: _topPath)];
    }

    if (_currentPath == _rootPath ||
        _currentPath.startsWith('$_rootPath/')) {
      final out = <({String label, String path})>[
        (label: '内部存储', path: _rootPath),
      ];
      final relative = _currentPath.substring(_rootPath.length);
      final segments =
          relative.split('/').where((s) => s.isNotEmpty).toList();
      var acc = _rootPath;
      for (final seg in segments) {
        acc = '$acc/$seg';
        out.add((label: seg, path: acc));
      }
      return out;
    }

    final out = <({String label, String path})>[
      (label: '存储', path: _topPath),
    ];
    if (!_currentPath.startsWith('$_topPath/')) return out;
    final relative = _currentPath.substring(_topPath.length);
    final segments =
        relative.split('/').where((s) => s.isNotEmpty).toList();

    var acc = _topPath;
    for (final seg in segments) {
      acc = '$acc/$seg';
      if (seg == 'emulated') continue;
      out.add((label: _crumbLabelFor(acc, seg), path: acc));
    }
    return out;
  }

  String _crumbLabelFor(String fullPath, String segment) {
    if (segment == 'emulated') return 'emulated';
    if (segment == 'self') return 'self';
    if (fullPath == _rootPath) return '内部存储';
    if (fullPath.startsWith('$_topPath/emulated/')) {
      return '双开($segment)';
    }
    if (RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$').hasMatch(segment)) {
      return '外部存储($segment)';
    }
    return segment;
  }

  Widget _buildBreadcrumbs() {
    final crumbs = _crumbs;
    final s = Theme.of(context).colorScheme;
    final widgets = <Widget>[];
    for (var i = 0; i < crumbs.length; i++) {
      final c = crumbs[i];
      final isLast = i == crumbs.length - 1;
      if (i > 0) {
        widgets.add(Icon(
          Icons.chevron_right,
          size: 16,
          color: _selectionMode ? s.outlineVariant : s.outline,
        ));
      }
      widgets.add(
        GestureDetector(
          onTap: (_selectionMode || isLast)
              ? null
              : () => _openBreadcrumb(c.path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              c.label,
              style: TextStyle(
                fontSize: 12,
                color: _selectionMode
                    ? s.onSurfaceVariant.withValues(alpha: 0.4)
                    : (isLast ? s.onSurface : s.onSurfaceVariant),
                fontWeight: FontWeight.normal,
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(children: widgets),
      ),
    );
  }

  static String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String _formatTime(DateTime? t) {
    if (t == null) return '';
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  static String _formatGridTime(DateTime t) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  String get _title {
    if (_currentPath == _topPath) return '存储';
    if (_currentPath == _rootPath) return '内部存储';
    return _currentPath.split('/').last;
  }

  String _relPath(String fullPath) {
    if (fullPath == _rootPath) return '~/';
    if (fullPath.startsWith('$_rootPath/')) {
      return '~${fullPath.substring(_rootPath.length)}';
    }
    return fullPath;
  }
  
  // ==================== build ====================
    // ==================== build ====================
    @override
    Widget build(BuildContext context) {
      _cachedDisplayItems = _buildDisplayItems();
      _visibleItems = _computeVisibleItems(_cachedDisplayItems!);
      return PopScope(
        canPop: _atPageBoundary &&
            !_selectionMode &&
            !_searchActive &&
            _expandedZipKeys.isEmpty &&
            !_menuBusy &&
            _advancedOverlay == null,
                onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          // 高级面板是浮在最上层的临时层，返回键先把它关掉，不动页面状态。
          if (_advancedOverlay != null) {
            _closeAdvanced();
            return;
          }
          // 悬浮菜单是浮在最上层的临时层，返回键先把它关掉，不动页面状态。
          // C1 / M5：正在播收起动画时只吞掉这一次返回，别触发别的分支。
          if (_menuClosing) return;
          if (_floatingMenuEntry != null) {
            _closeFloatingMenu();
            return;
          }
          if (_selectionMode) {
            setState(_clearSelection);
          } else if (_searchActive) {
            _clearSearch();
          } else if (_expandedZipKeys.isNotEmpty) {
            setState(() {
              _clearZipExpansion();
            });
          } else if (_canGoUp) {
            _goUp();
          }
          // 主页面在存储选择页（_topPath）、子页面在自己的起始目录时 canPop 为 true：
          // 主页面直接退出 App，子页面则 pop 回上一页，都不走这里。
        },

      child: Scaffold(
        // A1 / S1：顶栏整条 260ms 交叉淡入淡出，高度不变（列表不跳）。
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: AnimatedSwitcher(
            duration: _fx(260),
            reverseDuration: Duration.zero, // 退出选中：顶栏瞬间消失，不留渐隐
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            child: KeyedSubtree(
              key: ValueKey<bool>(_selectionMode),
              child: _selectionMode
                  ? _buildSelectionAppBar()
                  : _buildNormalAppBar(),
            ),
          ),
        ),
       body: SafeArea(
  top: false,
  child: Stack(
    children: [
      Column(
        children: [
          _buildBreadcrumbs(),
          ClipRect(
            child: AnimatedSize(
              // C1 / A5：顶边钉死、只动高度；时长交给 _fx，
              // 系统「减少动态效果」时退化为瞬切。
              alignment: Alignment.topCenter,
              duration: _fx(260),
              curve: Curves.easeOutCubic,
              child: _searchBarAreaVisible
                  ? _buildTopBarWithSelectionOverlay()
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ),
          // 顶栏（标题 + 面包屑 + 搜索栏）与文件列表之间的一条极淡分割线。
          Container(
            height: 1,
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withValues(alpha: 0.5),
          ),
          Expanded(child: _buildBodyWithOverlays()),
        ],
      ),
      // 选中底栏改为覆盖层：ScrollablePositionedList 是底部锚定的，
      // 用 bottomNavigationBar 改变列表高度会让整个列表上下跳动。
      // 查重暂存篮条（非空时）与选中底栏共用同一底部覆盖层，竖向叠放：
      // 篮子条在上、选中底栏在下，互不遮挡。
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: _buildBottomOverlay(),
      ),
    ],
  ),
),
        floatingActionButton: null,
      ),
    );
  }

  /// 底部覆盖层：查重暂存篮条（非空时）+ 选中底栏，竖向叠放。
  ///
  /// 外缘做了一层羽化（见 [_buildFeatheredTop]）——
  /// 原来这里是一条 1px 的 outlineVariant 横线，把列表和底栏硬生生切开，
  /// 现在改成向上渐隐到透明，像图片边缘羽化那样过渡过去。
  /// 底栏是浮在列表上的，这样过渡才不显得突兀。
  Widget _buildBottomOverlay() {
    final basketOn = ref.watch(dupBasketProvider).isNotEmpty;
    final visible = basketOn || _selectionMode;

    // A1 / S1：整块底栏 260ms 交叉淡入淡出。AnimatedSwitcher 会把旧 child
    // 保留到淡出播完才移除 —— 高度「撑到淡出播完再收回」，不会半路留下
    // 一条空白白条。仍是 Positioned(bottom:0) 浮层，列表布局完全不受影响。
    // 不做整块位移过冲：往上冲过头会在屏幕最底下露缝。
    // 淡出的 260ms 里旧底栏还在屏幕上，别让它继续拦截列表点击。
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSwitcher(
        duration: _fx(260),
        reverseDuration: Duration.zero, // 退出选中（且暂存篮也空）：底栏瞬间消失，不留渐隐
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.bottomCenter,
          children: <Widget>[
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        ),
        child: visible
            ? KeyedSubtree(
                key: const ValueKey('bottom-on'),
                child: _bottomOverlayBody(basketOn),
              )
            : const KeyedSubtree(
                key: ValueKey('bottom-off'),
                child: SizedBox.shrink(),
              ),
      ),
    );
  }

  Widget _bottomOverlayBody(bool basketOn) {
    final s = Theme.of(context).colorScheme;
    final bg = s.brightness == Brightness.light ? Colors.white : s.surface;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: -_bottomFeatherHeight,
          height: _bottomFeatherHeight,
          child: _buildFeatheredTop(bg),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (basketOn) _buildDupBasketBar(),
            if (_selectionMode) _buildBottomBar(),
          ],
        ),
      ],
    );
  }

  /// 羽化条高度：够看清渐变，又不至于吃掉列表太多内容。
  static const double _bottomFeatherHeight = 20;

  /// 从透明渐变到 [bg] 的一条羽化带，垫在覆盖层上方。
  ///
  /// 中间多加两个停靠点是为了让曲线更接近高斯羽化：
  /// 线性渐变两头会显得生硬，前段慢、后段快才像"晕开"。
  Widget _buildFeatheredTop(Color bg) {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              bg.withValues(alpha: 0),
              bg.withValues(alpha: 0.35),
              bg.withValues(alpha: 0.72),
              bg.withValues(alpha: 0.93),
              bg,
            ],
            stops: const <double>[0, 0.3, 0.62, 0.85, 1],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar() {
    final favorites = ref.watch(favoritesProvider);
    final isFav = favorites.contains(_currentPath);
    final isChildPage = widget.initialPath != null;
    final s = Theme.of(context).colorScheme;
    final isDefaultSkin = ref.watch(skinProvider) == AppSkin.defaultBlue;
    // 新页面统一用中性灰顶栏，和原页面区分；不跟随各套皮肤的彩色表面色。
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 自定义皮肤：主页面顶栏用皮肤 tint 的 surface，与「浏览器设置」页顶栏同色；
    // 默认皮肤保持纯白不染 tint。子页面（灰色）/ 深色维持原逻辑。
    final appBarColor = isChildPage
        ? (isDark ? Colors.grey.shade900 : Colors.grey.shade200)
        : (isDark
            ? s.surface
            : (isDefaultSkin ? Colors.white : s.surface));
    // ===== 顶栏按钮 + 三个点菜单：按用户配置渲染 =====
    final layoutRaw = ref.watch(browserTopBarLayoutProvider);
    final layout = parseTopBarLayout(layoutRaw);

    // 顶栏按钮（按配置顺序）
    final topBarActions = <Widget>[];
    for (final a in layout.order) {
      if (!layout.onTopBar.contains(a)) continue;
      final w = _buildTopBarActionButton(a, isFav: isFav);
      if (w != null) topBarActions.add(w);
    }

    // 三个点菜单项（按配置顺序）
    final moreChipStyle = _menuChipStyle();
    final menuItems = <Widget>[];
    for (final a in layout.order) {
      if (layout.onTopBar.contains(a)) continue;
      if (!_isActionAvailable(a)) continue;
      final label = a == BrowserTopBarAction.favoritesList
          ? '已收藏目录 (${favorites.length})'
          : a.label;
      menuItems.add(_menuChip(
        label: label,
        icon: a == BrowserTopBarAction.dedup
            ? Image.asset(
                'assets/images/dupebox_icon.png',
                width: 14,
                height: 14,
              )
            : Icon(_iconForAction(a), size: 14),
        style: moreChipStyle,
        onPressed: () => _dispatchTopBarAction(a.id),
      ));
    }

    return AppBar(
      automaticallyImplyLeading: false, // 左侧按钮完全自绘，避免存储根冒出自动返回键
      backgroundColor: appBarColor,
      surfaceTintColor: Colors.transparent, // Material3 下防止主题色 tint 覆盖
      elevation: 0, // 不要阴影，保持和面包屑同一平面
      title: GestureDetector(
        onLongPress: _showJumpToPathDialog,
        child: Text(
          (_searchActive &&
                  ref.watch(searchScopeProvider) == SearchScope.custom)
              ? '自定义的搜索范围'
              : _title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w400,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
      leading: _searchActive
          ? IconButton(
              icon: const GradientIcon(Icons.arrow_back),
              onPressed: _clearSearch,
            )
          : (isChildPage
              // 子页面：上一级一直可用，直到存储根（与主页面同规则）。
              ? (_canGoUp ? _smallBackButton(onPressed: _goUp) : null)
              : (_currentPath == _topPath
                  ? _smallBackButton(
                      onPressed: () => _navigateTo(_rootPath),
                    )
                  : (_canGoUp
                      ? _smallBackButton(onPressed: _goUp)
                      : null))),
      actions: [
        // 子页面「关闭」按钮：固定，不参与自定义
        if (widget.initialPath != null)
          IconButton(
            icon: const GradientIcon(Icons.close),
            tooltip: '关闭此页面',
            onPressed: () => Navigator.of(context).pop(),
          ),
        // 用户配置的顶栏按钮
        ...topBarActions,
        // 「更多」：固定永远在最后
        KeyedSubtree(
          key: _appBarMoreAnchorKey,
          // C1 / M5：点开时这三个点轻弹一下。KeyedSubtree 仍是最外层，
          // GlobalKey 量到的锚点范围不变。
          child: _pulseAnchor('top', IconButton(
            icon: const GradientIcon(Icons.more_vert),
            tooltip: '更多',
            onPressed: () {
              if (menuItems.isEmpty) {
                _toast('菜单已空。可在「浏览器设置 → 顶栏按钮」里添加。');
                return;
              }
              _showFloatingMenu(
                anchorKey: _appBarMoreAnchorKey,
                above: false,
                items: menuItems,
                isDefaultSkin: isDefaultSkin,
              );
            },
          )),
        ),
      ],
    );
  }

  Widget _smallBackButton({required VoidCallback onPressed}) {
    return Center(
      child: SizedBox(
        width: 36,
        height: 36,
        child: IconButton(
          icon: const GradientIcon(Icons.arrow_back, size: 20),
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 36,
            maxWidth: 36,
            maxHeight: 36,
          ),
          tooltip: null,
        ),
      ),
    );
  }

  /// 按当前配置渲染单个顶栏按钮。
  /// 返回 null 表示当前状态下这个按钮不适用（如「搜索栏开关」在始终显示模式下）。
  Widget? _buildTopBarActionButton(
    BrowserTopBarAction a, {
    required bool isFav,
  }) {
    switch (a) {
      case BrowserTopBarAction.searchToggle:
        if (ref.watch(searchBarVisibilityProvider) !=
            SearchBarVisibility.collapsible) {
          return null;
        }
        final collapsed = ref.watch(searchBarCollapsedProvider);
        // C1 / A5：点一下轻弹；两个放大镜图标交叉淡入、不旋转
        // （它们本来就是两个 IconData，赌几何旋转会出错）。
        return TweenAnimationBuilder<double>(
          tween: collapsed ? _kPopA : _kPopB,
          duration: _fx(280),
          curve: Curves.easeOutBack,
          builder: (_, s, child) =>
              Transform.scale(scale: s, child: child!),
          child: IconButton(
            iconSize: 22,
            icon: AnimatedSwitcher(
              duration: _fx(220),
              child: GradientIcon(
                collapsed ? Icons.search : Icons.search_off,
                key: ValueKey<bool>(collapsed),
              ),
            ),
            tooltip: collapsed ? '展开搜索栏' : '收起搜索栏',
            onPressed: _toggleSearchBarCollapsed,
          ),
        );

      case BrowserTopBarAction.favorite:
        return IconButton(
          icon: isFav
              ? const Icon(Icons.star, color: Colors.amber)
              : const GradientIcon(Icons.star_border),
          tooltip: isFav ? '取消收藏此目录' : '收藏此目录',
          onPressed: _toggleFavorite,
        );

      case BrowserTopBarAction.dedup:
        return IconButton(
          icon: Image.asset(
            'assets/images/dupebox_icon.png',
            width: 22,
            height: 22,
          ),
          tooltip: '查重',
          onPressed: _onTapDedupButton,
        );

      case BrowserTopBarAction.comparisonRules:
        return IconButton(
          icon: const GradientIcon(Icons.tune),
          tooltip: '对比规则设置',
          onPressed: () => _dispatchTopBarAction('comparisonRules'),
        );

      default:
        return IconButton(
          icon: GradientIcon(browserTopBarActionIcon(a)),
          tooltip: a.label,
          onPressed: () => _dispatchTopBarAction(a.id),
        );
    }
  }

  /// 当前状态下该动作是否可用（用于菜单过滤）。
  bool _isActionAvailable(BrowserTopBarAction a) {
    if (a == BrowserTopBarAction.searchToggle) {
      return ref.watch(searchBarVisibilityProvider) ==
          SearchBarVisibility.collapsible;
    }
    return true;
  }

  IconData _iconForAction(BrowserTopBarAction a) => browserTopBarActionIcon(a);

  PreferredSizeWidget _buildSelectionAppBar() {
    final all =
        _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final selectable = all
        .where((it) => !it.key.startsWith('__loading__') &&
            !it.key.startsWith('__error__'))
        .map((it) => it.key)
        .toList();
    final allSelected = selectable.isNotEmpty &&
        selectable.every((k) => _selectedPaths.contains(k));
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => setState(_clearSelection),
      ),
      title: Text('已选 ${_selectedPaths.length} 个'),
      actions: [
        IconButton(
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          tooltip: allSelected ? '全不选' : '全选',
          onPressed: _toggleSelectAll,
        ),
      ],
    );
  }

  // ==================== 搜索栏 UI ====================


/// 顶部区域：搜索栏（+状态栏/展开条）。
/// 选择模式下不替换，而是把提示条覆盖在上面。
/// 用 Stack + Visibility(maintainSize) 保证两种模式高度一致，
/// 否则 Expanded 的列表会跟着上下跳。
/// ExcludeFocus 在选择模式下把搜索框的焦点断掉，
/// 防止透明状态下仍弹输入法。
Widget _buildTopBarWithSelectionOverlay() {
  final normal = ExcludeFocus(
    excluding: _selectionMode,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchBar(),
        if (_searchActive) _buildSearchStatusBar(),
        if (!_searchActive && _expandedZipKeys.isNotEmpty)
          _buildExpandedZipBar(),
      ],
    ),
  );

  return Stack(
    children: [
      // 高度基准。选择模式下隐藏但仍占位。
      Visibility(
        visible: !_selectionMode,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: normal,
      ),
      // A1 / S1：提示条只做 260ms 交叉淡入淡出；高度由下面那个
      // Visibility(maintainSize) 撑住，绝不动高度，列表不会上下跳。
      // IgnorePointer：这块透明层常驻，退出选中时必须立刻停止命中测试，
      // 否则会挡住下面的搜索框（原来的 if 条件构建没这个问题）。
      Positioned.fill(
        child: IgnorePointer(
          ignoring: !_selectionMode,
          child: AnimatedSwitcher(
            duration: _fx(260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            // 原来是 Positioned.fill 给 tight 约束，提示条会撑满搜索栏高度；
            // StackFit.expand 保持这一点，否则提示条会缩成内容高度并居中。
            layoutBuilder: (currentChild, previousChildren) => Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ...previousChildren,
                if (currentChild != null) currentChild,
              ],
            ),
            child: _selectionMode
                ? KeyedSubtree(
                    key: const ValueKey('hint-on'),
                    child: _buildSelectionHintBar(),
                  )
                : const KeyedSubtree(
                    key: ValueKey('hint-off'),
                    child: SizedBox.shrink(),
                  ),
          ),
        ),
      ),
    ],
  );
}

/// 选中模式下替代搜索栏显示的提示条。
/// 高度与搜索栏（8 + 44 + 4 ≈ 56）对齐，切换时不跳动。
Widget _buildSelectionHintBar() {
  final n = _selectedPaths.length;
  final items = _resolveSelectedItems();

  bool isComparable(_DisplayItem it) =>
      !it.isDir && !(it.isZip && !it.isZipInner);

  final allComparable =
      items.isNotEmpty && items.every(isComparable);

  String line1;
  String line2;

  if (allComparable && n == 2) {
    // 两个文件都在，左右已经可以自证，直接给出角色
    line1 = '左：${items[0].displayName}';
    line2 = '右：${items[1].displayName} · 可对比 / MD5 对比';
  } else {
    line1 = '长按另一个文件可进行区间选择，点击可继续加选';
    if (allComparable && n == 1) {
      line2 = '此项会放在对比页左边';
    } else {
      line2 = '如果想对比文件，请选择两个文件';
    }
  }

  final cs = Theme.of(context).colorScheme;
  return Container(
    width: double.infinity,
    // 高度不再写死：由 Positioned.fill 从 Stack 拉满，
    // 等于搜索栏（+状态栏/展开条）的实际高度，切换选择模式时列表不动。
    margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    decoration: BoxDecoration(
      color: cs.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: cs.outlineVariant),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          line1,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.25,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          line2,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.25,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

  Widget _buildSearchBar() {
  final cs = Theme.of(context).colorScheme;
  final scope = ref.watch(searchScopeProvider);
  final mode = ref.watch(searchBoxModeProvider);
  final isFilter = mode == SearchBoxMode.filter;
  final isCustom = scope == SearchScope.custom;
  final customFolders = ref.watch(customSearchFoldersProvider);
  final hasText = _searchCtrl.text.isNotEmpty;
  final focused = _searchFocus.hasFocus;
  // 默认皮肤才启用品牌渐变；其他皮肤保持原来的实色描边与单色图标。
  final useBrandGradient = ref.watch(skinProvider) == AppSkin.defaultBlue;

  // ===== 左侧标签 =====
  final String label;
  final String? badge;
  if (isFilter) {
    label = '过滤';
    badge = null;
  } else if (isCustom) {
    label = '自定义';
    badge = customFolders.isEmpty ? null : '${customFolders.length}';
  } else {
    label = '当前目录';
    badge = null;
  }

  // ===== 输入框占位文案 =====
  final String hintText;
  if (isFilter) {
    hintText = '过滤当前目录';
  } else if (isCustom) {
    if (customFolders.isEmpty) {
      hintText = '点左侧标签设置搜索范围';
    } else if (customFolders.length == 1) {
      hintText = '在 1 个自定义目录中搜索';
    } else {
      hintText = '在 ${customFolders.length} 个自定义目录中搜索';
    }
  } else {
    hintText = '在当前目录中搜索';
  }

  // ===== 右侧按钮：形状区分模式 =====
  final IconData actionIcon =
      isFilter ? Icons.filter_alt_outlined : Icons.search;
  final Color actionColor = (isFilter || !hasText)
      ? cs.onSurfaceVariant
      : cs.onSurface;

  // ===== 输入框形状：搜索=胶囊，过滤=圆角矩形 =====
  final double radius = isFilter ? 8.0 : 22.0;
  // 聚焦时只加粗描边；不改颜色、不加光晕（用户要求：仅描边加粗）。
  final double borderThickness = focused ? 1.5 : 1.0;
  final Color borderColor = cs.outline; // 颜色恒定，不随聚焦加深
  // 渐变描边：浅色直接用品牌蓝，深色压深一档，避免在暗底上发亮。
  final List<Color> borderGradient = cs.brightness == Brightness.dark
      ? const [Color(0xFF2A476E), Color(0xFF5C8FC9), Color(0xFF1E3554)]
      : GradientIcon.colors;
  // 默认皮肤渐变描边：聚焦时透明度加深（仅默认皮肤有，自定义皮肤走 borderColor 恒定、不加深）。
  final double borderAlpha = focused ? 1.0 : 0.6;

  // ===== 标签：可随聚焦/有字加粗；宽度用隐形加粗占位恒定，
  // 避免字形变粗导致整行变宽、挤压搜索框（只变粗、不加宽）。 =====
  final bool labelActive = focused || hasText;
  final Color labelColor = cs.onSurfaceVariant;

  return TapRegion(
    onTapOutside: (_) {
      FocusManager.instance.primaryFocus?.unfocus();
    },
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          // ===== 左侧活字标签 =====
          // 位置恒定，不随聚焦位移（用户要求仅描边加粗，输入框宽度稳定）。
          // C1 / A5：展开时这一段第 0 档浮入。
          _enterSearchRow(0, AnimatedContainer(
            duration: _fx(240),
            curve: Curves.easeOutCubic,
            margin: EdgeInsets.zero,
            child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _showSearchSettings,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 隐形加粗文字专门撑宽度；实际文字按 labelActive 加粗，
                    // 两者叠放，整行宽度恒等于加粗宽度，变粗时不挤压搜索框。
                    Stack(
                      children: [
                        Opacity(
                          opacity: 0,
                          child: Text(
                            label,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: labelActive
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: labelColor,
                          ),
                        ),
                      ],
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 3),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: cs.surfaceVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 3),
                    GradientIcon(
                      Icons.settings_outlined,
                      size: 14,
                      fallbackColor: labelColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
          )),
          const SizedBox(width: 6),

          // ===== 输入框 =====
          Expanded(
            child: _enterSearchRow(1, AnimatedContainer(
              key: _searchBarBoxKey,
              duration: _fx(240),
              curve: Curves.easeOutCubic,
              height: 44,
              padding: useBrandGradient
                  ? EdgeInsets.all(borderThickness)
                  : null,
              decoration: useBrandGradient
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: borderGradient
                            .map((c) => c.withValues(alpha: borderAlpha))
                            .toList(),
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    )
                  : BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      border: Border.all(
                        color: borderColor,
                        width: borderThickness,
                      ),
                    ),
              child: Container(
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(
                    useBrandGradient ? radius - borderThickness : radius,
                  ),
                ),
                child: Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: _searchInputKey,
                      controller: _searchCtrl,
                      focusNode: _searchFocus,
                      cursorColor: cs.primary,
                      style: TextStyle(fontSize: 14, color: cs.onSurface),
                      decoration: InputDecoration(
                        hintText: hintText,
                        hintStyle: TextStyle(
                          fontSize: 14,
                          color: cs.onSurfaceVariant,
                        ),
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: _onSearchChanged,
                      onSubmitted: isFilter
                          ? (_) => FocusManager.instance
                              .primaryFocus
                              ?.unfocus()
                          : (_) => _doSearch(),
                    ),
                  ),
                  // A1 / F1：条件徽章 260ms 弹入 / 淡出。
                  // 原来是 if 条件构建 —— 条件一清空组件就被直接移除，
                  // 退场动画根本播不到；换成 AnimatedSwitcher 后，旧徽章
                  // 会留到淡出播完才收回宽度。
                  AnimatedSwitcher(
                    duration: _fx(260),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      alignment: Alignment.centerRight,
                      children: <Widget>[
                        ...previousChildren,
                        if (currentChild != null) currentChild,
                      ],
                    ),
                    transitionBuilder: (c, a) => ScaleTransition(
                      // 过冲只给缩放用；透明度走线性 a，避免 easeOutBack
                      // 把 opacity 推到 1 以上触发 debug 断言。
                      scale: Tween<double>(begin: 0.6, end: 1.0)
                          .chain(CurveTween(curve: Curves.easeOutBack))
                          .animate(a),
                      child: FadeTransition(opacity: a, child: c),
                    ),
                    child: _hasActiveConditions
                        ? Padding(
                            key: const ValueKey('badge-on'),
                            padding: const EdgeInsets.only(right: 2),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: _toggleAdvanced,
                                borderRadius: BorderRadius.circular(4),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: cs.primaryContainer,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '条件·$_activeConditionCount',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: cs.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(key: ValueKey('badge-off')),
                  ),
                  // 高级搜索（搜索模式下常驻，不再要求输入框有内容）
                  if (!isFilter) _buildAdvancedToggle(),
                  // 清空 / 历史
                  SizedBox(
                    width: 40,
                    height: 44,
                    child: _SoftGlowTapButton(
                      size: 40,
                      color: cs.onSurfaceVariant,
                      spreadDuration: _fx(440),
                      onTap: hasText
                          ? (isFilter ? _clearFilter : _clearSearchInput)
                          : _showSearchHistory,
                      child: Tooltip(
                        message: hasText ? '清空输入' : '搜索历史',
                        // A1 / F1：历史 ↔ 清空，旋转 + 淡入接力。
                        child: AnimatedSwitcher(
                          duration: _fx(220),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeOutCubic,
                          transitionBuilder: (c, a) => RotationTransition(
                            turns: Tween<double>(begin: 0.85, end: 1.0)
                                .animate(a),
                            child: FadeTransition(opacity: a, child: c),
                          ),
                          child: GradientIcon(
                            hasText ? Icons.close : Icons.history,
                            key: ValueKey<bool>(hasText),
                            size: 20,
                            fallbackColor: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              ),
            )),
          ),
          const SizedBox(width: 4),

          // ===== 右侧执行 / 标识按钮 =====
          // 方案B：去掉圆形水波纹，改柔光铺开——点击时从中心向外柔化扩散并淡出，
          // 范围略大于原水波纹（约 1.8×），无硬边涟漪。图标保留聚焦回弹。
          _enterSearchRow(2, SizedBox(
            width: 44,
            height: 44,
            child: _SearchExecButton(
              icon: actionIcon,
              color: actionColor,
              focused: focused,
              spreadDuration: _fx(440),
              pressDuration: _fx(240),
              onTap: () {
                if (isFilter) {
                  // 过滤模式：点击 = 收键盘（过滤是实时的，无"执行"语义）
                  FocusManager.instance.primaryFocus?.unfocus();
                } else if (hasText || _hasActiveConditions) {
                  _doSearch();
                } else {
                  // 搜索模式无内容：聚焦输入框
                  _searchFocus.requestFocus();
                }
              },
            ),
          )),
        ],
      ),
    ),
  );
}

/// 通用「柔光铺开」图标按钮：点击时从中心向外柔和扩散并淡出（无硬边涟漪），
/// 与 [_SearchExecButton] 同款点击反馈，但无聚焦回弹，用于高级搜索箭头、
/// 清空 / 历史等小图标按钮。
class _SoftGlowTapButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final Color color;
  final double size;
  final Duration spreadDuration;
  const _SoftGlowTapButton({
    required this.child,
    required this.onTap,
    required this.color,
    required this.size,
    required this.spreadDuration,
  });

  @override
  State<_SoftGlowTapButton> createState() => _SoftGlowTapButtonState();
}

class _SoftGlowTapButtonState extends State<_SoftGlowTapButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spread;

  @override
  void initState() {
    super.initState();
    _spread = AnimationController(
      vsync: this,
      duration: widget.spreadDuration,
      value: 0,
    );
  }

  @override
  void dispose() {
    _spread.dispose();
    super.dispose();
  }

  void _handleTap() {
    _spread.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _spread,
              builder: (_, __) {
                final t = _spread.value;
                final opacity = (1 - t) * 0.45;
                final scale = 1.0 + t * 0.8; // 最大约 1.8× 按钮
                return Opacity(
                  opacity: opacity,
                  child: Transform.scale(
                    scale: scale,
                    child: Container(
                      width: widget.size,
                      height: widget.size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.color.withValues(alpha: 0.5),
                        boxShadow: [
                          BoxShadow(
                            color: widget.color.withValues(alpha: 0.35),
                            blurRadius: 16,
                            spreadRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            widget.child,
          ],
        ),
      ),
    );
  }
}

class _SearchExecButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final bool focused;
  final Duration spreadDuration;
  final Duration pressDuration;
  final VoidCallback onTap;
  const _SearchExecButton({
    required this.icon,
    required this.color,
    required this.focused,
    required this.spreadDuration,
    required this.pressDuration,
    required this.onTap,
  });

  @override
  State<_SearchExecButton> createState() => _SearchExecButtonState();
}

class _SearchExecButtonState extends State<_SearchExecButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spread;

  @override
  void initState() {
    super.initState();
    _spread = AnimationController(
      vsync: this,
      duration: widget.spreadDuration,
      value: 0,
    );
  }

  @override
  void dispose() {
    _spread.dispose();
    super.dispose();
  }

  void _handleTap() {
    _spread.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            // 柔光铺开：点击时从中心向外柔化扩散并淡出（无硬边涟漪）。
            AnimatedBuilder(
              animation: _spread,
              builder: (_, __) {
                final t = _spread.value; // 0 → 1
                final opacity = (1 - t) * 0.45;
                final scale = 1.0 + t * 0.8; // 最大约 1.8× 按钮
                return Opacity(
                  opacity: opacity,
                  child: Transform.scale(
                    scale: scale,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.color.withValues(alpha: 0.5),
                        boxShadow: [
                          BoxShadow(
                            color: widget.color.withValues(alpha: 0.35),
                            blurRadius: 16,
                            spreadRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            // 图标（保留聚焦回弹）
            TweenAnimationBuilder<double>(
              key: ValueKey<bool>(widget.focused),
              tween: widget.focused ? _kExecPop : _kExecIdle,
              duration: widget.pressDuration,
              curve: Curves.easeOutBack,
              builder: (_, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: GradientIcon(
                widget.icon,
                size: 22,
                fallbackColor: widget.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showSearchSettings() async {
  FocusManager.instance.primaryFocus?.unfocus();

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (c) => Consumer(
      builder: (c, ref, _) {
        final cs = Theme.of(c).colorScheme;
        final scope = ref.watch(searchScopeProvider);
        final customFolders = ref.watch(customSearchFoldersProvider);
        final searchSortField = ref.watch(searchSortFieldProvider);
        final searchSortAsc = ref.watch(searchSortAscProvider);
        final boxMode = ref.watch(searchBoxModeProvider);
        final isFilter = boxMode == SearchBoxMode.filter;

        final String scopeLabel;
        if (isFilter) {
          scopeLabel = '过滤当前目录';
        } else if (scope == SearchScope.custom) {
          scopeLabel = '在 ${customFolders.length} 个自定义目录中搜索';
        } else {
          scopeLabel = '在当前目录及子目录中搜索';
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // drag handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 标题
                Text(
                  '搜索设置',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  scopeLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),

                // ===== 搜索框行为 =====
                _settingsSectionHeader(cs, '搜索框行为'),
                const SizedBox(height: 8),
                _settingsChoiceGroup<SearchBoxMode>(
                  context: context,
                  cs: cs,
                  value: boxMode,
                  onChanged: (v) => ref
                      .read(searchBoxModeProvider.notifier)
                      .update(v),
                  options: const [
                    (
                      value: SearchBoxMode.search,
                      label: '搜索',
                      hint: '回车或点搜索按钮才执行，扫子目录',
                    ),
                    (
                      value: SearchBoxMode.filter,
                      label: '过滤',
                      hint: '边打字边筛，只当前目录',
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // ===== 搜索模式：范围 + 排序 =====
                if (!isFilter) ...[
                  _settingsSectionHeader(cs, '搜索范围'),
                  const SizedBox(height: 8),
                  _settingsChoiceGroup<SearchScope>(
                    context: context,
                    cs: cs,
                    value: scope,
                    onChanged: (v) {
                      ref.read(searchScopeProvider.notifier).update(v);
                      // 主框留空但设了高级条件/大小时间时，同样按新范围重搜。
                      if (_searchActive &&
                          (_searchCtrl.text.trim().isNotEmpty ||
                              _hasActiveConditions)) {
                        _startSearch();
                      }
                    },
                    options: const [
                      (
                        value: SearchScope.currentRecursive,
                        label: '当前目录及子目录',
                        hint: null,
                      ),
                      (
                        value: SearchScope.custom,
                        label: '自定义的搜索范围',
                        hint: null,
                      ),
                    ],
                  ),
                  if (scope == SearchScope.custom) ...[
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: cs.primary,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.folder_special, size: 16),
                        label: Text(
                          customFolders.isEmpty
                              ? '选择搜索目录'
                              : '管理搜索目录（${customFolders.length}）',
                          style: const TextStyle(fontSize: 13),
                        ),
                        onPressed: () => _showSearchFolderPicker(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),

                  _settingsSectionHeader(cs, '结果排序'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _settingsSortChip(
                        cs: cs,
                        label: '名称',
                        selected: searchSortField == SortField.name,
                        onTap: () {
                          ref
                              .read(searchSortFieldProvider.notifier)
                              .update(SortField.name);
                          _resortSearchResults();
                        },
                      ),
                      _settingsSortChip(
                        cs: cs,
                        label: '修改时间',
                        selected: searchSortField == SortField.modified,
                        onTap: () {
                          ref
                              .read(searchSortFieldProvider.notifier)
                              .update(SortField.modified);
                          _resortSearchResults();
                        },
                      ),
                      _settingsSortChip(
                        cs: cs,
                        label: '大小',
                        selected: searchSortField == SortField.size,
                        onTap: () {
                          ref
                              .read(searchSortFieldProvider.notifier)
                              .update(SortField.size);
                          _resortSearchResults();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _settingsSortChip(
                        cs: cs,
                        label: '升序',
                        selected: searchSortAsc,
                        onTap: () {
                          ref
                              .read(searchSortAscProvider.notifier)
                              .update(true);
                          _resortSearchResults();
                        },
                      ),
                      _settingsSortChip(
                        cs: cs,
                        label: '降序',
                        selected: !searchSortAsc,
                        onTap: () {
                          ref
                              .read(searchSortAscProvider.notifier)
                              .update(false);
                          _resortSearchResults();
                        },
                      ),
                    ],
                  ),
                ] else ...[
                  // ===== 过滤模式：说明条 =====
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '过滤只在当前目录内生效。\n'
                      '想跨目录查找，请切回"搜索"模式。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),

                // ===== 完成按钮 =====
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text(
                      '完成',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

// ==================== 搜索设置弹窗 · 小部件 ====================

/// 设置弹窗里的小节标题。13px，主题色，字重 600。
Widget _settingsSectionHeader(ColorScheme cs, String text) {
  return Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: AppColors.textAccentOf(cs),
      letterSpacing: 0.3,
    ),
  );
}

/// 一组单选项，卡片式。第一个和最后一个圆角，中间直角。
/// 每一项：圆点 + 标题 + 可选副标题。
Widget _settingsChoiceGroup<T>({
  required BuildContext context,
  required ColorScheme cs,
  required T value,
  required ValueChanged<T> onChanged,
  required List<({T value, String label, String? hint})> options,
}) {
  return Container(
    decoration: BoxDecoration(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              indent: 44,
              endIndent: 16,
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
          InkWell(
            onTap: () => onChanged(options[i].value),
            borderRadius: i == 0
                ? const BorderRadius.vertical(top: Radius.circular(10))
                : i == options.length - 1
                    ? const BorderRadius.vertical(bottom: Radius.circular(10))
                    : BorderRadius.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      value == options[i].value
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 20,
                      color: value == options[i].value
                          ? cs.primary
                          : cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          options[i].label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: value == options[i].value
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: value == options[i].value
                                ? AppColors.textAccentOf(cs)
                                : cs.onSurface,
                          ),
                        ),
                        if (options[i].hint != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            options[i].hint!,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.4,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// 排序胶囊。选中：主题色底 + 主题色边框；未选中：浅灰底。
Widget _settingsSortChip({
  required ColorScheme cs,
  required String label,
  required bool selected,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? cs.secondaryContainer : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          color: selected ? cs.onSecondaryContainer : cs.onSurface,
        ),
      ),
    ),
  );
}

void _resortSearchResults() {
  if (_searchResults.isEmpty) return;
  final sortField = ref.read(searchSortFieldProvider);
final sortAsc = ref.read(searchSortAscProvider);
_searchResults.sort((a, b) {
 
    int cmp;
    switch (sortField) {
      case SortField.name:
        cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case SortField.modified:
        final at = a.modified?.millisecondsSinceEpoch ?? 0;
        final bt = b.modified?.millisecondsSinceEpoch ?? 0;
        cmp = at.compareTo(bt);
      case SortField.size:
        final as = a.size ?? 0;
        final bs = b.size ?? 0;
        cmp = as.compareTo(bs);
    }
    return sortAsc ? cmp : -cmp;
  });
  setState(() {});
}
/// 有压缩包展开时，在搜索栏下方固定显示一条提示条。
Widget _buildExpandedZipBar() {
  final topLevelCount =
      _expandedZipKeys.where((k) => !_isZipInnerKey(k)).length;
  if (topLevelCount == 0) return const SizedBox.shrink();

  final cs = Theme.of(context).colorScheme;
  return Container(
    width: double.infinity,
    color: cs.secondaryContainer,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: Row(
      children: [
    const AppFileIcon(isDir: true, isZip: true, size: 16),
              const SizedBox(width: 8),
        Expanded(
          child: Text(
            '已展开 $topLevelCount 个压缩包',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSecondaryContainer,
            ),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: cs.onSecondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          onPressed: () {
            setState(() {
              _expandedZipKeys.clear();
              _zipArchives.clear();
              _zipErrors.clear();
              _loadingZipKeys.clear();
              _encryptedNestedZipKeys.clear();
              _stickyZipKey = null;
            });
          },
          child: const Text('全部收起'),
        ),
      ],
    ),
  );
}


  Widget _buildSearchStatusBar() {
    final textTheme = Theme.of(context).textTheme;
    // 极简：状态条不做任何切换动画。
    // 旧实现用 AnimatedSwitcher 交叉淡入，切换的 220ms 内新旧两行叠在一起
    // （重影）；完成态 child key 带结果数，数字一变整块重建并再播一次
    // 淡入 + 数字轻弹（闪）；两态 padding 2/6 还让高度跳变，叠加外层
    // AnimatedSize 一起抖。现在固定高度、按状态直接构建，全部消除。
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            if (_searching)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            if (_searching) const SizedBox(width: 8),
            Expanded(
              child: Text(
                _searching
                    ? '扫描中... 已找到 ${_searchResults.length} 个'
                    : (_searchResults.length >= 500
                        ? '已达上限，只显示前 2000 个'
                        : '共找到 ${_searchResults.length} 个'),
                style: textTheme.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_searching)
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(48, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                onPressed: _cancelSearch,
                child: const Text('取消'),
              ),
          ],
        ),
      ),
    );
  }

  // ==================== 底部栏 ====================

  bool get _selectionAllDisk {
    if (_selectedPaths.isEmpty) return false;
    for (final k in _selectedPaths) {
      if (_isZipInnerKey(k)) return false;
    }
    return true;
  }

  bool get _selectionHasZipInner {
    for (final k in _selectedPaths) {
      if (_isZipInnerKey(k)) return true;
    }
    return false;
  }

  Widget _buildBottomBar() {
    final n = _selectedPaths.length;
    // 与提示条同一套判定：文件夹 / 压缩包本体不能对比，按钮置灰。
    final selItems = _resolveSelectedItems();
    bool isComparable(_DisplayItem it) =>
        !it.isDir && !(it.isZip && !it.isZipInner);
    final allComparable =
        selItems.isNotEmpty && selItems.every(isComparable);
    final canCompare = n == 2 && allComparable;
    final canMd5 = n == 2 && allComparable;
    // 属性不再只认单选：多选也要能看数量 / 总大小等统计（见 _showMultiProperties）。
    final canProps = n >= 1;
    final canOpenWith = n == 1;
    final canShare = n >= 1;
    final allDisk = _selectionAllDisk;

    final canCopyPath = n == 1;
    final canRename = n >= 1 && allDisk;
    final canMove = n >= 1 && allDisk;
    final canCopy = n >= 1 && allDisk;
    final canDelete = n >= 1 && allDisk;
    final canOpenNewPage = n == 1 && selItems.length == 1 && allDisk;
    final openNewPageLabel =
        selItems.length == 1 && !selItems.first.isDir ? '所在目录打开' : '新页面打开';

    final s = Theme.of(context).colorScheme;
    final isDefaultSkin = ref.watch(skinProvider) == AppSkin.defaultBlue;
    // 菜单项（顶栏「更多」/ 底栏「⋯」）仍用 16:16 留白。
    final chipStyle = _menuChipStyle();
    // 底栏第一行四个描边按钮（简洁对比 / 复制路径 / 分享 / ⋯）共用这一套：
    // 横向内边距归零 —— 按钮本来就是 Expanded 撑满、文字居中，宽度富余时自然留白；
    // 固定留白反而让窄屏上 4 个字的「复制路径」被挤成省略号，也跟其他按钮不齐。
    // 竖向 4 保留：当年从 16 改到 4 才修复被 SizedBox(38) 裁成"半截字"的问题。
    final rowChipStyle = _softChipStyle(
      padding: const EdgeInsets.symmetric(vertical: 4),
    );

    const labelStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
    );

    final moreMenuItems = <Widget>[
      _menuChip(
        label: '打开方式',
        style: chipStyle,
        onPressed: canOpenWith ? _openWithApp : null,
      ),
      _menuChip(
        label: openNewPageLabel,
        style: chipStyle,
        onPressed: canOpenNewPage ? _openSelectedInNewPage : null,
      ),
      _menuChip(
        label: 'MD5对比',
        style: chipStyle,
        onPressed: canMd5 ? _md5Compare : null,
      ),
      // 任意选中数都成立，保证「⋯」永远不会是一个全灰的空菜单。
      _menuChip(
        label: '反选',
        style: chipStyle,
        onPressed: _invertSelection,
      ),
    ];

    return SafeArea(
      child: Container(
        // 不再画顶部那条 outlineVariant 分割线：
        // 边界交给 _buildBottomOverlay 的羽化带去做，这里保持纯色块。
        color: s.brightness == Brightness.light ? Colors.white : s.surface,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 第一行：对比 + 对比(w) + 复制路径 + 分享 + 「⋯」。
            // 按 flex 20 : 16 : 16 : 16 : 9 分配（合计 77 份）：
            // 「对比(w)」占的就是原「简洁对比」那一格（原按钮代码仍保留在下方注释里）。
            // 按钮随屏幕变宽变窄、始终铺满第一行，不再横向滚动。
            SizedBox(
              height: 38,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 20,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.compare_arrows, size: 16),
                      label: const Text(
                        '对比',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      // 默认皮肤：原淡底蓝字 → 反色为实色蓝底 + 浅字，与「反选 / 打开方式」
                      // 菜单项区分开、强调主操作；自定义皮肤保持原样（已是实色蓝底）。
                      //
                      // 字色写死白色：默认皮肤的 onPrimary 是深蓝（#0B2A55），
                      // 压在浅蓝底（#6FA9F0）上发闷、像没点亮的按钮；
                      // 自定义皮肤的底色也偏深，onPrimary 同样读不清。
                      // 主操作按钮要的是「一眼看到能点」，统一白字。
                      style: FilledButton.styleFrom(
                        backgroundColor: isDefaultSkin ? s.primary : null,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: canCompare ? _startCompare : null,
                    ),
                  ),
                  const SizedBox(width: 3),
                  // ── 「简洁对比」按钮暂时隐藏：代码整段保留，日后要恢复删掉行首 // 即可 ──
                  // Expanded(
                  //   flex: 16,
                  //   child: LayoutBuilder(
                  //     builder: (context, box) => _adaptiveRowButton(
                  //       context: context,
                  //       allocatedWidth: box.maxWidth,
                  //       label: '简洁对比',
                  //       style: rowChipStyle,
                  //       labelStyle: labelStyle,
                  //       onPressed: canCompare ? _startQuickCompare : null,
                  //     ),
                  //   ),
                  // ),
                  // ── 新按钮：把选中的两个文件交给 WinMerge Mobile 去对比 ──
                  Expanded(
                    flex: 16,
                    child: LayoutBuilder(
                      builder: (context, box) => _adaptiveRowButton(
                        context: context,
                        allocatedWidth: box.maxWidth,
                        label: '对比(w)',
                        style: rowChipStyle,
                        labelStyle: labelStyle,
                        onPressed: canCompare ? _compareWithWinMerge : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    flex: 16,
                    child: LayoutBuilder(
                      builder: (context, box) => _adaptiveRowButton(
                        context: context,
                        allocatedWidth: box.maxWidth,
                        label: '复制路径',
                        style: rowChipStyle,
                        labelStyle: labelStyle,
                        onPressed: canCopyPath ? _copyPath : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    flex: 16,
                    child: OutlinedButton(
                      style: rowChipStyle,
                      onPressed: canShare ? _shareSelected : null,
                      child: const Text(
                        '分享',
                        style: labelStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    flex: 9,
                    child: Tooltip(
                      message: '更多',
                      // C1 / M5：底栏这三个点向上展开，点开时轻弹一下。
                      child: _pulseAnchor('bottom', OutlinedButton(
                        key: _bottomMoreAnchorKey,
                        style: rowChipStyle,
                        onPressed: () => _showFloatingMenu(
                          anchorKey: _bottomMoreAnchorKey,
                          above: true,
                          items: moreMenuItems,
                          isDefaultSkin: isDefaultSkin,
                        ),
                        child: const Icon(Icons.more_horiz, size: 18),
                      )),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: _wideAction(
                    icon: Icons.info_outline,
                    label: '属性',
                    onPressed: canProps ? _showProperties : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.drive_file_rename_outline,
                    label: '重命名',
                    onPressed: canRename ? _rename : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.drive_file_move_outline,
                    label: '移动',
                    onPressed: canMove ? _move : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.copy_all_outlined,
                    label: '复制',
                    onPressed: canCopy ? _copy : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.delete_outline,
                    label: '删除',
                    color: canDelete ? s.error : null,
                    onPressed: canDelete ? _delete : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 底栏第一行「简洁对比 / 复制路径」的 4 字按钮标签，按按钮「自身分到的宽度」自适应：
  ///
  /// 宽到放得下 4 个字（再留一点呼吸）就维持一排 12 号；放不下就折成 2+2 两排。
  /// 判断依据用 LayoutBuilder 的 [allocatedWidth] 而非屏幕宽 —— 决定放不放得下的是
  /// 按钮自己占多宽，同样屏宽下 flex 一变结论就变，用屏幕宽判断会失准。
  /// 再乘系统字体缩放 [textScaler]：用户把字调大时更早折行，避免挤成省略号。
  ///
  /// 两排时用 11 号 + 行高 1.1：两行约 24dp，加按钮竖向 padding 8dp 共约 32dp，
  /// 稳稳落在锁死的 38dp 高度内（12 号两排会到约 41.6dp 被裁，故必须降号压紧）。
  Widget _adaptiveRowButton({
    required BuildContext context,
    required double allocatedWidth,
    required String label,
    required ButtonStyle style,
    required TextStyle labelStyle,
    required VoidCallback? onPressed,
  }) {
    // 一排舒适下限 = 4 字 48dp + 左右各 13dp 呼吸 = 74dp：
    // 对应 16 份按钮在 360/375dp 屏（约 69.8/72.9）折两排、390dp 屏（约 76.1）维持一排。
    // 随字体缩放同步放大，字体 130% 时下限抬到约 96dp，更早折行，避免大字体挤成省略号。
    final scaler = MediaQuery.textScalerOf(context);
    final oneLineMin = (4 * 12 + 2 * 13) * scaler.scale(1.0);
    final twoLines = allocatedWidth < oneLineMin;

    final child = twoLines
        ? Text(
            '${label.substring(0, 2)}\n${label.substring(2)}',
            textAlign: TextAlign.center,
            style: labelStyle.copyWith(fontSize: 11, height: 1.1),
            maxLines: 2,
          )
        : Text(
            label,
            style: labelStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );

    return OutlinedButton(
      style: style,
      onPressed: onPressed,
      child: child,
    );
  }

  Widget _wideAction({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    final disabled = onPressed == null;
    // 与第一行的 OutlinedButton 保持同一套配色：默认皮肤用主题蓝，其他皮肤用正文色。
    final isDefaultSkin = ref.watch(skinProvider) == AppSkin.defaultBlue;
    final s = Theme.of(context).colorScheme;
    final c = disabled
        ? Theme.of(context).disabledColor
        : (color ?? (isDefaultSkin ? s.primary : s.onSurface));
    return InkWell(
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: c),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: c,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 主体 ====================

  Widget _buildBody() {
    return AnimatedSwitcher(
      key: ValueKey('switcher_$_bodyRevision'),
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: _buildBodyState(),
    );
  }

  // ==================== 列表之上的覆盖层（滚动条 / 悬浮翻页按钮） ====================
  //
  // 不改文件浏览器本身的滚动实现，只在外面盖一层：
  //   · 可拖动滚动条（默认关）
  //   · 上下悬浮翻页按钮（默认关）

  Widget _buildBodyWithOverlays() {
    final scrollbarOn = ref.watch(browserScrollbarEnabledProvider);
    final floatingOn = ref.watch(browserFloatingPageEnabledProvider);
    final body = _buildBody();
    if (!scrollbarOn && !floatingOn) return body;
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        if (scrollbarOn) _buildBrowserScrollbar(),
        if (floatingOn) _buildFloatingPageOverlay(),
      ],
    );
  }

  Widget _buildBrowserScrollbar() {
    final track = ref.watch(browserScrollbarTrackColorProvider);
    final thumb = ref.watch(browserScrollbarThumbColorProvider);
    final opacity = (ref.watch(browserScrollbarOpacityProvider) / 100)
        .clamp(0.0, 1.0)
        .toDouble();
    final width = ref
        .watch(browserScrollbarWidthProvider)
        .clamp(2.0, 28.0)
        .toDouble();

    return Positioned(
      top: 2,
      bottom: 2,
      right: 0,
      width: math.max(width + 12, 24),
      child: _BrowserScrollbar(
        positions: _positionsListener.itemPositions,
        itemCount: () => _scrollItemCount,
        thumbWidth: width,
        trackColor: track.withValues(alpha: opacity * 0.35),
        thumbColor: thumb.withValues(alpha: opacity),
        onJump: _jumpToIndex,
      ),
    );
  }

  Widget _buildFloatingPageOverlay() {
    final color = ref.watch(browserFloatingPageColorProvider);
    final opacity = (ref.watch(browserFloatingPageOpacityProvider) / 100)
        .clamp(0.0, 1.0)
        .toDouble();
    final size = ref
        .watch(browserFloatingPageSizeProvider)
        .clamp(28.0, 88.0)
        .toDouble();
    final upX = ref.watch(browserFloatingPageUpXProvider);
    final upY = ref.watch(browserFloatingPageUpYProvider);
    final downX = ref.watch(browserFloatingPageDownXProvider);
    final downY = ref.watch(browserFloatingPageDownYProvider);

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (ctx, c) {
          Widget btn({
            required double x,
            required double y,
            required bool up,
          }) {
            final left =
                (c.maxWidth - size) * (x.clamp(0.0, 100.0).toDouble() / 100);
            final top =
                (c.maxHeight - size) * (y.clamp(0.0, 100.0).toDouble() / 100);
            return Positioned(
              left: left,
              top: top,
              width: size,
              height: size,
              child: _BrowserFloatingPageButton(
                size: size,
                color: color.withValues(alpha: opacity),
                up: up,
                onTap: up ? _pageUp : _pageDown,
              ),
            );
          }

          return Stack(
            children: [
              btn(x: upX, y: upY, up: true),
              btn(x: downX, y: downY, up: false),
            ],
          );
        },
      ),
    );
  }

  /// 跳到指定条目（顶部对齐）。
  void _jumpToIndex(int index) {
    if (!_itemScrollController.isAttached) return;
    final count = _scrollItemCount;
    if (count <= 0) return;
    try {
      _itemScrollController.jumpTo(
        index: index.clamp(0, count - 1).toInt(),
        alignment: 0,
      );
    } catch (_) {}
  }

  /// 当前可见区间的首/末条目索引与可见条目数。
  _VisibleRange _visibleRange() {
    var first = -1;
    var last = -1;
    var visible = 0;
    for (final p in _positionsListener.itemPositions.value) {
      if (p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1) {
        visible++;
        if (first < 0 || p.index < first) first = p.index;
        if (p.index > last) last = p.index;
      }
    }
    return _VisibleRange(first: first, last: last, visible: visible);
  }

  /// 向下翻一页：上一页最后一个文件仍显示在最上面。
  void _pageDown() {
    final r = _visibleRange();
    if (r.last < 0) return;
    _jumpToIndex(r.last);
  }

  /// 向上翻一页。
  void _pageUp() {
    final r = _visibleRange();
    if (r.first <= 0) return;
    final step = r.visible > 1 ? r.visible - 1 : 1;
    _jumpToIndex(r.first - step);
  }

  Widget _keyed(String k, Widget child) =>
      KeyedSubtree(key: ValueKey(k), child: child);

  Widget _buildBodyState() {
    // 先清零，下面各列表构建时再写入真实条目数。
    _scrollItemCount = 0;

    if (_searchActive) {
      return _keyed('search', _buildSearchResultsList());
    }

    if (_showSkeleton) {
      return const _LoadingSkeleton(key: ValueKey('skeleton'));
    }

    if (_loading) {
      // 180ms 延迟窗口内：什么都不显示，避免闪烁
      return const SizedBox.shrink(key: ValueKey('blank'));
    }

    if (_error != null) {
      return _keyed(
        'error',
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 12),
                Text('无法访问目录：\n$_error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          ),
        ),
      );
    }

  final entries = _entries ?? const <EntryInfo>[];
    if (entries.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      return _keyed(
        'empty',
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_open_outlined,
                size: 64,
                color: cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                '这里还没有文件',
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

  final mode = ref.read(searchBoxModeProvider);
  if (mode == SearchBoxMode.filter &&
      _searchCtrl.text.trim().isNotEmpty) {
    final items = _visibleItems ?? const <_DisplayItem>[];
    if (items.isEmpty) {
      return _keyed('nomatch', const Center(child: Text('无匹配')));
    }
  }

  return _keyed(
    'content',
    ref.watch(browserGridModeProvider)
        ? _buildGridBody(_filterEntries(entries))
        : _buildListBody(),
  );
}
  // ==================== 列表模式（无粘性头部） ====================

Widget _buildListBody() {
  final fontName = ref.watch(browserFontListNameProvider);
  final fontMeta = ref.watch(browserFontListMetaProvider);
  final colorScheme = Theme.of(context).colorScheme;
  final scrollbarOn = ref.watch(browserScrollbarEnabledProvider);

  final items = _visibleItems ?? const <_DisplayItem>[];
  // 选中模式下底栏是 Stack 覆盖层，不占布局；
  // 在列表末尾补一段滚动留白，让最后一个文件能滚出底栏遮挡。
  // 留白在滚动内容末尾，不改变可视区高度，进入/退出选中模式内容不跳。
  final extra = _selectionMode ? 1 : 0;
  _scrollItemCount = items.length + extra;
  final initial = _initialScrollIndex;
  _initialScrollIndex = null; // 消费一次：仅本次挂载用，下次 build 传 0。
  final list = ScrollablePositionedList.builder(
    key: ValueKey('list_${_currentPath}_$_listGeneration'),
    initialScrollIndex: initial ?? 0,
    itemScrollController: _itemScrollController,
    itemPositionsListener: _positionsListener,
    itemCount: items.length + extra,
    itemBuilder: (ctx, i) {
      if (i >= items.length) {
        return SizedBox(
          height: MediaQuery.of(context).padding.bottom + 110,
        );
      }
      final item = items[i];
      return RepaintBoundary(
        key: ValueKey('rb_${item.key}'),
        child: _buildDisplayItemTile(item, fontName, fontMeta, colorScheme),
      );
    },
  );
  // 自定义可拖动滚动条开启时，默认 Scrollbar 就关掉，避免两条并存。
  return scrollbarOn ? list : Scrollbar(child: list);
}

  /// 行的底色。优先级：选中 > 定位闪烁 > 刚访问过 > 默认（透明）。
  ///
  /// 「刚访问过」用主题主色的淡底，不用黄色——黄色在这一屏里已经被
  /// 「查重扫描范围」等提示占用了，而且和收藏的琥珀色容易混。
  /// 淡蓝底 + 左侧一条竖杠，扫一眼就知道刚才在哪，又不抢选中态。
  Color? _rowBgFor(String key, bool selected, ColorScheme cs) {
    if (selected) return cs.primary.withValues(alpha: 0.14);
    if (_flashPath == key) return cs.primary.withValues(alpha: 0.10);
    if (_lastVisitedPath == key) {
      // 渐隐：_visitedFade 1→0，底色随之由 0.10 变到 0。
      // 0.10 比选中态的 0.14 浅一档，不抢选中。
      return cs.primary.withValues(alpha: 0.10 * _visitedFade.value);
    }
    return null;
  }

  /// 「刚访问过」的左侧竖杠。选中态已经够醒目，不再叠一层。
  bool _showVisitedMark(String key, bool selected) =>
      !selected && _lastVisitedPath == key;

  /// 竖杠本体：贴着行左边，只留左侧两个圆角，和行的圆角对齐。
  /// 随 [_visitedFade] 一起变浅，和底色同步消失。
  Widget _visitedMarkBar(ColorScheme cs) {
    final a = 0.85 * _visitedFade.value;
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: 3,
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: a),
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(10),
          ),
        ),
      ),
    );
  }

  /// 渲染一个 display item。磁盘项、zip 头、zip 内项各有不同样式。
  ///
  /// ★ 改动点：整行用 Listener 记录点击的 x 坐标。
  ///   左侧图标区（宽度 48 + depth*18）点 = 选中/取消；
  ///   其它区点 = 打开（或选择模式下切换选中）。
  Widget _buildDisplayItemTile(
    _DisplayItem item,
    double fontName,
    double fontMeta,
    ColorScheme colorScheme,
  ) {
    // loading / error 提示行
    if (item.key.startsWith('__loading__')) {
      return Padding(
        padding: EdgeInsets.only(
          left: 8.0 + item.depth * 18.0,
          right: 12,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              item.displayName,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    if (item.key.startsWith('__error__')) {
      return Padding(
        padding: EdgeInsets.only(
          left: 8.0 + item.depth * 18.0,
          right: 12,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber,
                size: 16, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.displayName,
                style: TextStyle(fontSize: 12, color: colorScheme.error),
              ),
            ),
          ],
        ),
      );
    }

    final selected = _selectedPaths.contains(item.key);
    final compact = ref.watch(browserListCompactProvider);

    // 左侧图标区宽度（含缩进）。点这块 = 选中/取消。
    final iconZoneRight = (compact ? 36.0 : 48.0) + item.depth * 18.0;

    // zip 头（顶层或嵌套）：和普通文件一样的 ListTile，
    // 右侧箭头表示展开/折叠状态。
if (item.isZip) {
  final isExpanded = _expandedZipKeys.contains(item.key);
  final isTopLevel = item.ownerZipKey == null;
  final metaLine = _buildItemMetaLine(item);

return Listener(
  onPointerDown: (e) => _lastTapX = e.localPosition.dx,
  child: Container(
    margin: EdgeInsets.symmetric(horizontal: 6, vertical: compact ? 1 : 2),
    decoration: BoxDecoration(
      color: _rowBgFor(item.key, selected, colorScheme),
      borderRadius: BorderRadius.circular(10),
    ),
  child: Stack(
    children: [
  ListTile(
      dense: true,
  visualDensity: const VisualDensity(horizontal: 0, vertical: 0),
      contentPadding: EdgeInsets.only(
  left: item.depth * 18.0,
  right: 8,
  top: compact ? 1 : 4,
  bottom: compact ? 1 : 4,
),
leading: SizedBox(
  width: compact ? 36 : 48,
  child: Padding(
    padding: EdgeInsets.only(left: compact ? 4 : 8),
    child: Center(
      child: AppFileIcon(
        isDir: true,
        isZip: true,
        size: compact ? 20 : 24,
        tint: isTopLevel
            ? null
            : colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    ),
  ),
),
      title: Text(
        item.displayName,
        maxLines: compact ? 1 : 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontName,
          fontWeight: FontWeight.w400,
          height: compact ? 1.15 : 1.3,
        ),
      ),
      subtitle: metaLine.isEmpty
          ? null
          : Text(
              metaLine,
              style: TextStyle(
                fontSize: fontMeta,
                color: colorScheme.onSurfaceVariant,
                height: 1.3,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      // 图标不再是「空心/实心」两态，用箭头保留展开状态。
      trailing: _encryptedNestedZipKeys.contains(item.key)
          ? Icon(Icons.lock_outline,
              size: 18, color: colorScheme.error)
          : Icon(
              isExpanded
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
      onTap: () {
        // ★ 左侧图标区点 = 选中/取消
        if (_lastTapX < iconZoneRight) {
          _toggleSelectionByKey(item.key);
          return;
        }
        if (_selectionMode) {
          _toggleSelectionByKey(item.key);
          return;
        }
        _handleTapItem(item);
      },
      onLongPress: () => _onLongPressItem(item),
    ),
      if (_showVisitedMark(item.key, selected)) _visitedMarkBar(colorScheme),
    ],
  ),
  ),
);
}

    // zip 内目录
    if (item.isZipInner && item.isDir) {
      return Padding(
        padding: EdgeInsets.only(
          left: 8.0 + item.depth * 18.0,
          right: 12,
          top: compact ? 4 : 7,
          bottom: compact ? 4 : 7,
        ),
        child: Row(
          children: [
            const SizedBox(width: 22),
            const AppFileIcon(isDir: true, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontName - 1,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 通用文件行（磁盘文件 或 zip 内文件）
    final isZipInner = item.isZipInner;
    final metaLine = _buildItemMetaLine(item);

return Listener(
  onPointerDown: (e) => _lastTapX = e.localPosition.dx,
  child: Container(
    margin: EdgeInsets.symmetric(horizontal: 6, vertical: compact ? 1 : 2),
    decoration: BoxDecoration(
      color: _rowBgFor(item.key, selected, colorScheme),
      borderRadius: BorderRadius.circular(10),
    ),
  child: Stack(
    children: [
  ListTile(
  dense: true,
  visualDensity: const VisualDensity(horizontal: 0, vertical: 0),

  contentPadding: EdgeInsets.only(
        left: item.depth * 18.0,
        right: 8,
        top: compact ? 1 : 4,
        bottom: compact ? 1 : 4,
      ),
      leading: SizedBox(
        width: compact ? 36 : 48,
        child: Padding(
          padding: EdgeInsets.only(left: compact ? 4 : 8),
          child: Center(
            child: AppFileIcon(
              isDir: item.isDir,
              isZip: item.isArchive,
              size: compact ? 20 : 24,
              tint: isZipInner
                  ? colorScheme.onSurfaceVariant.withValues(alpha: 0.6)
                  : null,
            ),
          ),
        ),
      ),
        title: Text(
          item.displayName,
          maxLines: compact ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: fontName,
            fontWeight: FontWeight.w400,
            height: compact ? 1.15 : 1.3,
            color: isZipInner
                ? colorScheme.onSurface.withOpacity(0.85)
                : null,
          ),
        ),
        subtitle: metaLine.isEmpty
            ? null
            : Text(
                metaLine,
                style: TextStyle(
                  fontSize: fontMeta,
                  color: colorScheme.onSurfaceVariant,
                  height: 1.3,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        onTap: () {
          // ★ 左侧图标区点 = 选中/取消
          if (_lastTapX < iconZoneRight) {
            _toggleSelectionByKey(item.key);
            return;
          }
          if (_selectionMode) {
            _toggleSelectionByKey(item.key);
            return;
          }
          _handleTapItem(item);
        },
        onLongPress: () => _onLongPressItem(item),
      ),
      if (_showVisitedMark(item.key, selected)) _visitedMarkBar(colorScheme),
    ],
  ),
    ),
  );
  }

  String _buildItemMetaLine(_DisplayItem item) {
    final parts = <String>[];
    if (item.size != null && !item.isDir) {
      final s = _formatSize(item.size);
      if (s.isNotEmpty) parts.add(s);
    }
    if (item.modified != null) {
      parts.add(_formatTime(item.modified));
    }
    return parts.join(' · ');
  }

  // ==================== 网格模式（不支持 zip 展开） ====================

  Widget _buildGridBody(List<EntryInfo> entries) {
    final showSize = ref.watch(browserGridShowSizeProvider);
    final showTime = ref.watch(browserGridShowTimeProvider);
    final fontName = ref.watch(browserFontGridNameProvider);
    final fontMeta = ref.watch(browserFontGridMetaProvider);
    final scrollbarOn = ref.watch(browserScrollbarEnabledProvider);

    final rowCount = (entries.length + 1) ~/ 2;
    // 选中模式下底栏是覆盖层，网格末尾同样补一段滚动留白。
    final extraRow = _selectionMode ? 1 : 0;
    _scrollItemCount = rowCount + extraRow;

    final initial = _initialScrollIndex;
    _initialScrollIndex = null; // 消费一次：仅本次挂载用，下次 build 传 0。
    final list = ScrollablePositionedList.builder(
      key: ValueKey('grid_${_currentPath}_$_listGeneration'),
      initialScrollIndex: initial ?? 0,
      itemScrollController: _itemScrollController,
      itemPositionsListener: _positionsListener,
      itemCount: rowCount + extraRow,
      itemBuilder: (ctx, rowIdx) {
        if (rowIdx >= rowCount) {
          return SizedBox(
            height: MediaQuery.of(context).padding.bottom + 110,
          );
        }
        final leftIdx = rowIdx * 2;
        final rightIdx = leftIdx + 1;

        final leftInfo = entries[leftIdx];
        final rightInfo =
            rightIdx < entries.length ? entries[rightIdx] : null;

        final leftWidget = _buildGridCell(
          info: leftInfo,
          showSize: showSize,
          showTime: showTime,
          fontName: fontName,
          fontMeta: fontMeta,
        );

        final rightWidget = rightInfo == null
            ? const SizedBox.shrink()
            : _buildGridCell(
                info: rightInfo,
                showSize: showSize,
                showTime: showTime,
                fontName: fontName,
                fontMeta: fontMeta,
              );

        return RepaintBoundary(
          key: ValueKey('rb_grid_$rowIdx'),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: leftWidget),
                Container(
                  width: _gridDividerThickness,
                  color: _gridDividerColorOf(context),
                ),
                Expanded(child: rightWidget),
              ],
            ),
          ),
        );
      },
    );
    return scrollbarOn ? list : Scrollbar(child: list);
  }

  Widget _buildGridCell({
    required EntryInfo info,
    required bool showSize,
    required bool showTime,
    required double fontName,
    required double fontMeta,
  }) {
    final e = info.entity;
    final selected = _selectedPaths.contains(e.path);
    final colorScheme = Theme.of(context).colorScheme;

    final metaParts = <String>[];
    if (showSize && !info.isDir && info.size != null) {
      metaParts.add(_formatSize(info.size));
    }
    if (showTime && info.modified != null) {
      metaParts.add(_formatGridTime(info.modified!));
    }
    final metaLine = metaParts.join(' · ');

    final displayItem = _displayItemForEntry(info);

    return GestureDetector(
      onTap: () {
        if (_selectionMode) {
          _toggleSelectionByKey(e.path);
          return;
        }
        if (info.isDir) {
          _navigateTo(e.path);
        } else {
          _openFile(e.path, info.name, info.size, allowExpand: false);
        }
      },
      onLongPress: () => _onLongPressItem(displayItem),
      child: Container(
        decoration: BoxDecoration(
          // 背景只保留选中态，和列表模式一致；
          // 文本/二进制靠图标颜色区分，灰底属于隐式规则。
          color: _rowBgFor(e.path, selected, colorScheme),
        ),
        foregroundDecoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: _gridDividerColorOf(context),
              width: _gridDividerThickness,
            ),
          ),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: _gridCellPadH,
          vertical: _gridCellPadV,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _toggleSelectionByKey(e.path),
                  onLongPress: () => _onLongPressItem(displayItem),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: Center(
                        child: AppFileIcon(
                          isDir: info.isDir,
                          isZip: displayItem.isArchive,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(child: _buildGridName(info, fontName)),
              ],
            ),
            if (metaLine.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                metaLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontMeta,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 网格长按需要的 item 解析逻辑，图标/整格手势共用一份。
  _DisplayItem _displayItemForEntry(EntryInfo info) {
    final all = _cachedDisplayItems ?? const <_DisplayItem>[];
    return all.firstWhere(
      (x) => x.key == info.entity.path,
      orElse: () => _DisplayItem(
        key: info.entity.path,
        displayName: info.name,
        depth: 0,
      ),
    );
  }

  Widget _buildGridName(EntryInfo info, double fontSize) {
    if (info.isDir) {
      return Text(
        '/${info.name}/',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w400,
          height: 1.3,
        ),
      );
    }
    // 粗细与列表模式对齐：文件夹和文件都用常规字重。
    return Text(
      info.name,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w400,
        height: 1.3,
      ),
    );
  }

  // ==================== 搜索结果列表（无粘性头部） ====================

  Widget _buildSearchResultsList() {
    if (_searchResults.isEmpty) {
      final emptyHint = _searchCtrl.text.trim().isEmpty
          ? '请输入关键词后搜索'
          : (_searching ? '正在扫描...' : '未找到匹配');
      // 仅做淡入淡出：不做滑动/缩放等其它动效。
      return Center(
        child: AnimatedSwitcher(
          duration: _fx(220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
          child: Text(
            key: ValueKey<String>(emptyHint),
            emptyHint,
          ),
        ),
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    final fontName = ref.watch(browserFontListNameProvider);
    final fontMeta = ref.watch(browserFontListMetaProvider);
    final scrollbarOn = ref.watch(browserScrollbarEnabledProvider);

    final items = _cachedDisplayItems ?? const <_DisplayItem>[];
    // 选中模式下底栏是覆盖层，搜索结果列表末尾同样补滚动留白。
    final extra = _selectionMode ? 1 : 0;
    _scrollItemCount = items.length + extra;
    // 搜索结果始终从头开始；消费掉可能残留的 _initialScrollIndex，
    // 避免退出搜索后泄漏到主列表导致莫名跳位。
    _initialScrollIndex = null;

    final list = ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      itemPositionsListener: _positionsListener,
      itemCount: items.length + extra,
      itemBuilder: (ctx, i) {
        if (i >= items.length) {
          return SizedBox(
            height: MediaQuery.of(context).padding.bottom + 110,
          );
        }
        final item = items[i];
        return RepaintBoundary(
          key: ValueKey('rb_search_${item.key}'),
          child: _buildSearchResultTile(item, fontName, fontMeta, colorScheme),
        );
      },
    );
    return scrollbarOn ? list : Scrollbar(child: list);
  }

  /// 搜索结果模式的列表项渲染（跟普通列表不同：显示路径副标题）。
  ///
  /// ★ 改动点：整行用 Listener 记录点击的 x 坐标。
  ///   左侧图标区（宽度 48 + depth*18）点 = 选中/取消；
  ///   其它区点 = 打开（或选择模式下切换选中）。
  Widget _buildSearchResultTile(
    _DisplayItem item,
    double fontName,
    double fontMeta,
    ColorScheme colorScheme,
  ) {
    if (item.key.startsWith('__loading__') ||
        item.key.startsWith('__error__')) {
      return _buildDisplayItemTile(item, fontName, fontMeta, colorScheme);
    }

    if (item.isZipInner && item.isDir) {
      return _buildDisplayItemTile(item, fontName, fontMeta, colorScheme);
    }

    final selected = _selectedPaths.contains(item.key);
    final isZipInner = item.isZipInner;
    final metaLine = _buildItemMetaLine(item);
    final pathLine = isZipInner
        ? item.fullDisplayPath
        : (item.diskPath ?? '');

    final compact = ref.watch(browserListCompactProvider);

    // 左侧图标区宽度（含缩进）。点这块 = 选中/取消。
    final iconZoneRight = (compact ? 36.0 : 48.0) + item.depth * 18.0;

    return Listener(
      onPointerDown: (e) => _lastTapX = e.localPosition.dx,
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 6, vertical: compact ? 1 : 2),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.14)
              : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: ListTile(
          dense: true,
          isThreeLine: true,
          visualDensity: const VisualDensity(horizontal: 0, vertical: 0),
          contentPadding: EdgeInsets.only(
            left: item.depth * 18.0,
            right: 8,
            top: compact ? 1 : 4,
            bottom: compact ? 1 : 4,
          ),
          leading: SizedBox(
            width: compact ? 36 : 48,
            child: Padding(
              padding: EdgeInsets.only(left: compact ? 4 : 8, top: compact ? 2 : 4),
              child: Align(
                alignment: Alignment.topCenter,
                child: item.isZip
                    ? AppFileIcon(
                        isDir: true,
                        isZip: true,
                        size: compact ? 20 : 24,
                        tint: isZipInner
                            ? colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6)
                            : null,
                      )
                    : AppFileIcon(
                        isDir: item.isDir,
                        isZip: item.isArchive,
                        size: compact ? 20 : 24,
                        tint: isZipInner
                            ? colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6)
                            : null,
                      ),
              ),
            ),
          ),
          title: Text(
            item.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontName,
              fontWeight: FontWeight.w400,
              height: 1.3,
              color: isZipInner
                  ? colorScheme.onSurface.withOpacity(0.85)
                  : null,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (metaLine.isNotEmpty)
                Text(
                  metaLine,
                  style: TextStyle(
                    fontSize: fontMeta,
                    color: colorScheme.onSurfaceVariant,
                    height: 1.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              Text(
                pathLine,
                style: TextStyle(
                  fontSize: fontMeta,
                  color: colorScheme.onSurfaceVariant,
                  height: 1.3,
                ),
                softWrap: true,
              ),
            ],
          ),
          onTap: () {
            // ★ 左侧图标区点 = 选中/取消
            if (_lastTapX < iconZoneRight) {
              _toggleSelectionByKey(item.key);
              return;
            }
            if (_selectionMode) {
              _toggleSelectionByKey(item.key);
              return;
            }
            _handleTapItem(item);
          },
          onLongPress: () => _onLongPressItem(item),
        ),
      ),
    );
  }
}

// ==================== 辅助 Widget ====================

/// 悬浮菜单的滚动容器：内容超出可用高度时可滚动，
/// 滚动过程中出现滚动条，避免「看不出还有更多项」。
class _FloatingMenuScroller extends StatefulWidget {
  const _FloatingMenuScroller({required this.child});

  final Widget child;

  @override
  State<_FloatingMenuScroller> createState() => _FloatingMenuScrollerState();
}

class _FloatingMenuScrollerState extends State<_FloatingMenuScroller> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        child: widget.child,
      ),
    );
  }
}

const EdgeInsets _dlgInsetG = EdgeInsets.all(4);
const EdgeInsets _dlgTitlePadG = EdgeInsets.fromLTRB(12, 8, 12, 0);
const EdgeInsets _dlgContentPadG = EdgeInsets.fromLTRB(8, 4, 8, 4);
const EdgeInsets _dlgActionsPadG = EdgeInsets.fromLTRB(4, 0, 4, 4);

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.initialValue,
  });

  final String title;
  final String initialValue;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 32,
        vertical: 24,
      ),
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: cs.primary, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

// ==================== 批量重命名：弹窗 ====================

typedef _RenameItem = ({
  String oldPath,
  String oldName,
  String parent,
  bool isDir
});

/// 预览表一行。抽成 typedef，避免预览生成 / 渲染 / 能否提交三处
/// 各写一遍匿名 record 类型，改字段时漏一处就编译失败。
typedef _RenamePreviewEntry = ({
  String oldPath,
  String oldName,
  String newName,
  String? conflict,
  String? note,
  bool pending,
});

/// 批量重命名弹窗的返回值：真正要改的名字映射 + 本次没改名的数量。
/// 有冲突/待确认的行允许跳过（不再锁死整批），数量带出来好提示用户。
typedef _BatchRenameOutcome = ({
  Map<String, String> renames,
  int skipped,
});

class _BatchRenameDialog extends StatefulWidget {
  const _BatchRenameDialog({
    required this.paths,
    this.orderHint = const [],
    this.onUndo,
  });

  final List<String> paths;

  /// 这些文件在文件浏览器当前列表里的显示顺序（用于「列表顺序」）。
  /// 不在里面的文件会排在后面，保持原有选择顺序。
  final List<String> orderHint;

  /// 点标题栏「撤销上次批量改名」。由外层负责真正改回去并刷新列表。
  final VoidCallback? onUndo;

  @override
  State<_BatchRenameDialog> createState() => _BatchRenameDialogState();
}

class _BatchRenameDialogState extends State<_BatchRenameDialog> {
  late _RenameConfig _cfg;
  // 递归子目录时会在弹窗内追加条目，所以不是 final。
  late List<_RenameItem> _items;

  // 文本 controller 全部提到 State，避免每次 build 新建导致光标跳动
  late final TextEditingController _findCtrl;
  late final TextEditingController _replaceCtrl;
  late final TextEditingController _prefixCtrl;
  late final TextEditingController _suffixCtrl;
  late final TextEditingController _extCtrl;
  late final TextEditingController _insertTextCtrl;
  late final TextEditingController _fullNameCtrl;
  late final TextEditingController _fullNameFormatCtrl;

  // 整数 / 分隔符 controller 也提到 State（方案原只提了文本，漏了这 7 个）
  // 三张「＋ 添加」来源卡的固定 key：点添加后能直接展开对应卡，
  // 同时让卡在整页重建时保持自己的展开状态。
  final GlobalKey<_ExpandableSectionState> _dateCardKey = GlobalKey();
  final GlobalKey<_ExpandableSectionState> _seqCardKey = GlobalKey();
  final GlobalKey<_ExpandableSectionState> _contentCardKey = GlobalKey();

  // B（插入内容 → 序号）专用的三个输入框，与 A 的 _seq*Ctrl 分开。
  late final TextEditingController _insertSeqStartCtrl;
  late final TextEditingController _insertSeqStepCtrl;
  late final TextEditingController _insertSeqWidthCtrl;
  late final TextEditingController _seqStartCtrl;
  late final TextEditingController _seqStepCtrl;
  late final TextEditingController _seqWidthCtrl;
  late final TextEditingController _insertPosCtrl;
  late final TextEditingController _contentInsertPosCtrl;
  late final TextEditingController _deleteStartCtrl;
  late final TextEditingController _deleteLenCtrl;
  late final TextEditingController _seqSepCtrl;
  late final TextEditingController _dateFmtCtrl;
  late final TextEditingController _datePosCtrl;

  /// 用户是否在「读 prefs 期间」动过任何控件。动过就不覆盖，避免把刚输入的内容冲掉。
  bool _touched = false;

  /// 是否记住上次规则。默认 false —— 每次打开弹窗都是空白规则。
  /// 这个开关单独存，不写进 _RenameConfig 的 JSON。
  bool _rememberConfig = false;

  /// 手动微调后的顺序（仅 orderMode == custom 时生效）。
  List<String> _manualOrder = const [];

  /// 浏览器列表顺序的排名（initState 里按 orderHint 建一次）。
  late final Map<String, int> _browserRank;

  /// 修改时间 / 大小缓存，避免排序时反复 stat。
  final Map<String, ({DateTime? modified, int size})> _statCache = {};

  // ============ 从文件内容提取字段 ============
  // 提取激活 = 模板重写模式，或插入内容里选了「从文件内容取值」。
  // 后者即使在「保留原名」下也会读文件扫描，只是不做「挖不到标黄」那些兜底。
  bool get _extractionActive => _cfg.insertContentVars;

  late RenamePreset _preset;
  List<RenamePreset> _presets = <RenamePreset>[RenamePreset.starter()];
  bool _rememberPreset = false;
  late final ContentExtractor _extractor;
  late final TextEditingController _templateCtrl;

  /// 路径 → 提取到的变量。
  final Map<String, Map<String, String>> _varsByPath =
      <String, Map<String, String>>{};
  final Map<String, int> _charCountByPath = <String, int>{};
  final Map<String, String> _errorsByPath = <String, String>{};

  /// 手填值，key 为 "路径\u0000变量名"。
  final Map<String, String> _manualValues = <String, String>{};

  /// 手动指定的目标文件名（完整文件名，含扩展名）：路径 → 名字。
  /// 只是本次弹窗里的临时覆盖，不写进方案、不落盘。
  /// _preview 会在冲突检测【之前】用它覆盖规则算出来的名字。
  final Map<String, String> _manualNames = <String, String>{};

  bool _scanning = false;
  int _scanned = 0;
  int _scanTotal = 0;

  /// 扫描代次：配置一变就 +1，让上一轮 worker 尽快退出，避免旧结果盖住新配置。
  int _scanGeneration = 0;

  /// 扫描设置改动后的防抖重扫定时器。
  Timer? _rescanTimer;

  /// 配置面板的输入框控制器按 key 复用，避免每次 build 新建导致光标跳动。
  final Map<String, TextEditingController> _contentCtrls =
      <String, TextEditingController>{};

  TextEditingController _ctrl(String key, String initial) =>
      _contentCtrls.putIfAbsent(
          key, () => TextEditingController(text: initial));

  _RenameItem _toRenameItem(String p) {
    final idx = p.lastIndexOf('/');
    return (
      oldPath: p,
      oldName: p.substring(idx + 1),
      parent: p.substring(0, idx),
      isDir: Directory(p).existsSync(),
    );
  }

  Set<String> get _contentVariableNames => <String>{
        for (final f in _preset.fields)
          if (f.name.trim().isNotEmpty &&
              !kBuiltinVariables.contains(f.name.trim()))
            f.name.trim(),
      };

  /// 「改抓出来的内容」菜单项是否可用：这一批真的在用内容变量取名时才有意义
  /// （模板重写模式，或插入内容里选了「从文件内容取值」）。
  /// 抽成 getter 是为了让小预览和完整预览共用同一条判定，不再各写一遍。
  bool get _canEditVariables =>
      _cfg.insertContentVars && _contentVariableNames.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _cfg = _RenameConfig(); // 先给默认值，UI 立刻能画
    _preset = RenamePreset.starter();
    _extractor = ContentExtractor(_decodeForRename);

    _items = <_RenameItem>[for (final p in widget.paths) _toRenameItem(p)];

    _findCtrl = TextEditingController();
    _replaceCtrl = TextEditingController();
    _prefixCtrl = TextEditingController();
    _suffixCtrl = TextEditingController();
    _extCtrl = TextEditingController();
    _insertTextCtrl = TextEditingController();
    _fullNameCtrl = TextEditingController();
    _fullNameFormatCtrl = TextEditingController(
      text: _cfg.fullNameSeqFormat,
    );

    // 浏览器显示顺序的排名：命中的用它在列表里的位置，没命中的接在后面。
    _browserRank = {};
    for (var i = 0; i < widget.orderHint.length; i++) {
      _browserRank[widget.orderHint[i]] = i;
    }
    var tail = widget.orderHint.length;
    for (final it in _items) {
      _browserRank.putIfAbsent(it.oldPath, () => tail++);
    }

    _seqStartCtrl = TextEditingController(text: '${_cfg.sequenceStart}');
    _seqStepCtrl = TextEditingController(text: '${_cfg.sequenceStep}');
    _seqWidthCtrl = TextEditingController(text: '${_cfg.sequenceWidth}');
    _insertSeqStartCtrl =
        TextEditingController(text: '${_cfg.insertSeqStart}');
    _insertSeqStepCtrl =
        TextEditingController(text: '${_cfg.insertSeqStep}');
    _insertSeqWidthCtrl =
        TextEditingController(text: '${_cfg.insertSeqWidth}');
    _insertPosCtrl = TextEditingController(text: '${_cfg.insertPos}');
    _contentInsertPosCtrl =
        TextEditingController(text: '${_cfg.contentInsertPos}');
    _deleteStartCtrl = TextEditingController(text: '${_cfg.deleteStart}');
    _deleteLenCtrl = TextEditingController(text: '${_cfg.deleteLength}');
    _seqSepCtrl = TextEditingController(text: _cfg.sequenceSeparator);
    _dateFmtCtrl = TextEditingController(text: _cfg.dateFormat);
    _datePosCtrl = TextEditingController(text: '${_cfg.dateInsertPos}');
    _templateCtrl = TextEditingController(text: _preset.template);

    _loadSavedConfig(); // 读「记住上次规则」开关；默认关，不恢复旧规则
    _loadPresets(); // 读多套命名方案
  }

  @override
  void dispose() {
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    _prefixCtrl.dispose();
    _suffixCtrl.dispose();
    _extCtrl.dispose();
    _insertTextCtrl.dispose();
    _fullNameCtrl.dispose();
    _fullNameFormatCtrl.dispose();
    _seqStartCtrl.dispose();
    _seqStepCtrl.dispose();
    _seqWidthCtrl.dispose();
    _insertSeqStartCtrl.dispose();
    _insertSeqStepCtrl.dispose();
    _insertSeqWidthCtrl.dispose();
    _insertPosCtrl.dispose();
    _contentInsertPosCtrl.dispose();
    _deleteStartCtrl.dispose();
    _deleteLenCtrl.dispose();
    _seqSepCtrl.dispose();
    _dateFmtCtrl.dispose();
    _datePosCtrl.dispose();
    _templateCtrl.dispose();
    for (final c in _contentCtrls.values) {
      c.dispose();
    }
    _rescanTimer?.cancel();
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _toastEntry = null;
    _scanGeneration++; // 让还在跑的扫描 worker 尽快退出
    super.dispose();
  }

  /// 「记住上次规则」入口已隐藏：读一下历史 prefs 保持兼容，但一律不再应用，
  /// 保证旧数据不会悄悄把规则带回来——每次打开都是空白规则。
  Future<void> _loadSavedConfig() async {
    await _loadRenameRemember();
    await _loadRenameConfig();
  }

  // ============ 从文件里提取内容：方案、扫描、手填 ============

  Future<void> _loadPresets() async {
    final store = RenamePresetStore.instance;
    final list = await store.loadPresets();
    final remember = await store.loadRememberPreset();
    if (!mounted) return;
    String? active;
    if (remember) active = await store.loadActiveName();
    if (!mounted) return;

    var chosen = list.first;
    if (active != null) {
      for (final p in list) {
        if (p.name == active) {
          chosen = p;
          break;
        }
      }
    }
    if (_touched) {
      setState(() {
        _presets = list;
        _rememberPreset = remember;
      });
      return;
    }
    setState(() {
      _presets = list;
      _rememberPreset = remember;
      _preset = chosen.copy();
      _templateCtrl.text = _preset.template;
    });
    _syncContentCtrls();
  }

  Future<void> _persistPreset() async {
    final store = RenamePresetStore.instance;
    final list = <RenamePreset>[for (final p in _presets) p.copy()];
    final i = list.indexWhere((p) => p.name == _preset.name);
    if (i >= 0) {
      list[i] = _preset.copy();
    } else {
      list.add(_preset.copy());
    }
    _presets = list;
    await store.savePresets(list);
    if (_rememberPreset) await store.saveActiveName(_preset.name);
  }

  /// 切换 / 导入方案后，把面板里已创建的输入框同步到新方案的值。
  void _syncContentCtrls() {
    void set(String k, String v) {
      final c = _contentCtrls[k];
      if (c != null && c.text != v) c.text = v;
    }

    set('headKB', '${(_preset.scan.headBytes / 1024).round()}');
    set('headLines', '${_preset.scan.headLines}');
    set('tailKB', '${(_preset.scan.tailBytes / 1024).round()}');
    set('tailLines', '${_preset.scan.tailLines}');
    set('exts', _preset.scan.extensions.join(','));
    set('fullCapMB',
        '${(_preset.scan.fullReadCapBytes / (1024 * 1024)).round()}');
    set('blacklist', _preset.clean.blacklist.join(','));
    set('valueMax', '${_preset.clean.maxLength}');
    set('defaultValue', _preset.defaultValue);
    set('illegalRep', _preset.illegalReplacement);
    set('nameMax', '${_preset.maxNameLength}');
    set('conflictSuffix', _preset.conflictSuffixFormat);
    set('concurrency', '${_preset.scan.concurrency}');
  }

  Timer? _toastTimer;
  OverlayEntry? _toastEntry;

  /// 弹窗里的提示不能用 ScaffoldMessenger 的 SnackBar：它挂在底层 Scaffold 上，
  /// 会被当前打开的批量重命名 / 完整预览弹窗整个盖住，用户根本看不见。
  /// 改成插到根 Overlay 的悬浮胶囊，保证浮在所有 route（含弹窗）之上。
  void _snack(String msg, {Duration duration = const Duration(seconds: 2)}) {
    if (!mounted) return;
    // 连发提示时先撤掉上一条，避免叠成一摞。
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _toastEntry = null;

    final cs = Theme.of(context).colorScheme;
    final top = MediaQuery.of(context).padding.top + 16;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        // 靠上悬浮：既不挡弹窗底部按钮，也不会被弹窗遮住。
        top: top,
        left: 24,
        right: 24,
        child: IgnorePointer(
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 180),
              builder: (_, opacity, child) =>
                  Opacity(opacity: opacity, child: child),
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(10),
                color: cs.inverseSurface.withValues(alpha: 0.92),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  child: Text(
                    msg,
                    style: TextStyle(
                        color: cs.onInverseSurface, fontSize: 13),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _toastEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
    _toastTimer = Timer(duration, () {
      if (_toastEntry == entry) {
        entry.remove();
        _toastEntry = null;
      }
    });
  }

  /// 命名格式里的 {变量} 替换：只认内置变量，不认识的名字替换成空。
  /// {n} 是序号格式专用符号，不在这里处理，会被当文字保留。
  String _renderFullNameBase(String tpl, Map<String, String> vars) {
    return tpl
        .replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (m) {
          final k = (m.group(1) ?? '').trim();
          return vars[k] ?? '';
        })
        .trim();
  }

  /// 并发读文件头（IO 不阻塞 UI），结果缓存住；改模板/正则不重读磁盘。
  /// 配置变化用 _scanGeneration 让上一轮尽快退出并重开一轮，
  /// 否则「扫描中改了扫描范围」或「递归新增了文件」会拿到旧结果 / 漏扫。
  Future<void> _rescan() async {
    if (!_extractionActive) return;
    final gen = ++_scanGeneration;
    final preset = _preset.copy();
    final files = <String>[
      for (final it in _items)
        if (!it.isDir) it.oldPath,
    ];
    if (mounted) {
      setState(() {
        _scanning = true;
        _scanned = 0;
        _scanTotal = files.length;
        _varsByPath.clear();
        _errorsByPath.clear();
        _charCountByPath.clear();
      });
    }
    final results = await _extractor.extractMany(
      files,
      preset,
      concurrency: preset.scan.concurrency,
      isCancelled: () => gen != _scanGeneration || !mounted,
      onProgress: (done, _) {
        if (mounted && gen == _scanGeneration) {
          setState(() => _scanned = done);
        }
      },
    );
    if (!mounted || gen != _scanGeneration) return;
    setState(() {
      _scanning = false;
      _scanned = files.length;
      for (final e in results.entries) {
        if (e.value.error != null) {
          _errorsByPath[e.key] = e.value.error!;
        }
        _varsByPath[e.key] = e.value.variables;
        _charCountByPath[e.key] = e.value.charCount;
      }
    });
  }

  /// 递归开关：把选中的文件夹展开成里面的文件，直接加进本次预览列表。
  Future<void> _setRecursive(bool on) async {
    _preset.scan.includeSubfolders = on;
    await _persistPreset();
    if (!on) {
      setState(() {
        _items = <_RenameItem>[for (final p in widget.paths) _toRenameItem(p)];
      });
      _rescan();
      return;
    }
    final seen = <String>{for (final it in _items) it.oldPath};
    final extra = <String>[];
    for (final p in widget.paths) {
      if (!Directory(p).existsSync()) continue;
      try {
        await for (final entity in Directory(p).list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File && !seen.contains(entity.path)) {
            extra.add(entity.path);
          }
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _items.addAll(<_RenameItem>[for (final p in extra) _toRenameItem(p)]);
      // 文件夹不参与扫描，别把目录算进进度总数。
      _scanTotal = _items.where((it) => !it.isDir).length;
    });
    _rescan();
  }

  /// 内置变量 + 本文件提取到的变量 + 手填覆盖值。
  Map<String, String> _variablesFor(_RenameItem it, int index) {
    final dot = it.oldName.lastIndexOf('.');
    final hasExt = !it.isDir && dot > 0 && dot < it.oldName.length - 1;
    final base = hasExt ? it.oldName.substring(0, dot) : it.oldName;
    final ext = hasExt ? it.oldName.substring(dot + 1) : '';
    final segs = it.parent.split('/').where((s) => s.isNotEmpty).toList();
    final st = _statFor(it.oldPath);
    final t = DateTime.now();
    final vars = <String, String>{
      '原名': base,
      '扩展名': ext,
      '目录名': segs.isEmpty ? '' : segs.last,
      // {序号}：按序号设置算出的数字本身（受起始/步长/位数影响），
      // 不带 ({n}) 包裹；命名格式里不写 {序号} 就不会编号。
      '序号': (_cfg.sequenceStart + index * _cfg.sequenceStep)
          .toString()
          .padLeft(_cfg.sequenceWidth, '0'),
      '日期': _formatDate(t, _cfg.varDateFormat),
      '大小': '${st.size}',
      '大小可读': _humanSizeEx(st.size, _cfg.varSizeUnit, _cfg.varSizeDec),
      '字数': _humanCharCount(_charCountByPath[it.oldPath] ?? 0),
    };
    vars.addAll(_varsByPath[it.oldPath] ?? const <String, String>{});
    for (final n in _contentVariableNames) {
      final manual = _manualValues['${it.oldPath}\u0000$n'];
      if (manual != null && manual.trim().isNotEmpty) {
        vars[n] = manual.trim();
      }
    }
    return vars;
  }

  Future<void> _addOrEditField([ContentField? initial]) async {
    final result = await showDialog<ContentField>(
      context: context,
      builder: (_) => _FieldEditorDialog(initial: initial),
    );
    if (result == null) return;
    _edit(() {
      if (initial == null) {
        _preset.fields.add(result);
      } else {
        final i = _preset.fields.indexOf(initial);
        if (i >= 0) _preset.fields[i] = result;
      }
    });
    _persistPreset();
    if (_extractionActive) _rescan();
  }

  Future<void> _removeField(ContentField f) async {
    _edit(() => _preset.fields.remove(f));
    _persistPreset();
    if (_extractionActive) _rescan();
  }

  /// 删除变量前先弹确认框，避免误删。
  Future<void> _confirmRemoveField(ContentField f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除变量'),
        content: Text('确定要删除变量「{${f.name}}」吗？此操作不可撤销。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) _removeField(f);
  }

  /// 点预览里「待确认」的行：把缺的变量手填进去，只影响这一行。
  /// 打开按变量手填/修改对话框。
  /// 初始值优先取已手填值，其次取已提取到的值（便于「提取错也能改」），
  /// 都没有才空。返回 true 表示用户确实改了并确认。
  Future<bool> _editManual(String path, Set<String> names) async {
    // 先算出这一行真正生效的模板，再看模板用到了哪些变量。
    // 原名已经带作者标记时 _preview 会把模板降级成 {原名}，那种情况下
    // 所有内容变量都不参与取名，也要一并提示（和算法保持一致）。
    final oldName = path.replaceAll('\\', '/').split('/').last;
    final alreadyTagged = _nameAlreadyTagged(oldName);
    final usedInTemplate = RenameTemplateEngine.variableNames(
        alreadyTagged ? '{原名}' : _preset.template);
    final unused = names.where((n) => !usedInTemplate.contains(n)).toList();
    // 提前拼好，避免字符串插值里再套一层字符串字面量。
    final unusedLabel = unused.map((n) => '{$n}').join('、');

    // 这几种情况改变量不会改变这一行的名字，提前说清楚，免得以为没生效：
    // 1) 本行已手改文件名 / 保持原名（手改覆盖优先）；
    // 2) 整名替换抢先（⋯ 菜单里已隐藏该入口，这里留作兜底）；
    // 3) 原名已带作者信息，本次只保留原名、不套模板；
    // 4) 模板里根本没写到这些变量 —— 对话框列出的是全部变量，但只有
    //    模板引用到的那些才会影响文件名。
    final String? notice;
    if (_manualNames.containsKey(path)) {
      notice = '这一行已经手动指定了文件名（或选择了保持原名），改这里不会改变它的名字。'
          '想让规则重新生效，请在这一行的 ⋯ 菜单里点「还原成规则算出来的名字」。';
    } else if (_cfg.renameMode == 'fullName') {
      notice = '整名替换已开启，本次内容取名不生效；改这里也不会改变文件名。'
          '请关闭上面的「新名字 + 序号」。';
    } else if (alreadyTagged) {
      notice = '这一行的原名已经带作者信息，本次不再套模板追加，改这里不会改变文件名。'
          '如需重新按模板取名，请先去掉原名里的作者标记。';
    } else if (unused.isNotEmpty) {
      notice = '命名模板里没用到：$unusedLabel。'
          '改这些不会改变文件名；想让内容生效，请在「命名模板」里写上它们'
          '（例如 {作者}）。';
    } else {
      notice = null;
    }
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ManualValuesDialog(
        names: names.toList(),
        initial: <String, String>{
          for (final n in names)
            n: _manualValues['$path\u0000$n'] ?? _varsByPath[path]?[n] ?? '',
        },
        notice: notice,
      ),
    );
    if (result == null) return false;
    setState(() {
      _touched = true;
      for (final e in result.entries) {
        final key = '$path\u0000${e.key}';
        if (e.value.trim().isEmpty) {
          _manualValues.remove(key);
        } else {
          _manualValues[key] = e.value.trim();
        }
      }
    });
    return true;
  }

  /// 手动改某一行的最终文件名。返回 true 表示确实改了（调用方据此刷新预览弹窗）。
  /// 填完整文件名；不写扩展名会自动补回原扩展名；清空 = 还原成规则算的名字。
  Future<bool> _editTargetName(
      String path, String currentName, String oldName) async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => _ManualNameDialog(
        initialValue: currentName,
        oldName: oldName,
      ),
    );
    if (raw == null) return false;
    final isReset = raw.trim().isEmpty;
    final cleaned = isReset
        ? ''
        : RenameTemplateEngine.sanitizeManualName(raw, _preset, oldName);
    if (!isReset && cleaned.isEmpty) {
      _snack('这个名字全是非法字符，请重新输入');
      return false;
    }
    _edit(() {
      if (isReset || cleaned.isEmpty) {
        _manualNames.remove(path);
      } else {
        _manualNames[path] = cleaned;
      }
    });
    return true;
  }

  /// 还原某一行：清掉手改覆盖，回到规则算出来的名字。
  void _resetTargetName(String path) {
    if (!_manualNames.containsKey(path)) return;
    _edit(() => _manualNames.remove(path));
  }

  Future<void> _saveAsPreset() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _TextInputDialog(
        title: '另存为方案',
        initialValue: '${_preset.name} 副本',
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    // 重名会在 _persistPreset 里直接覆盖已有方案，用户会以为「另存为」成功
    // 其实原方案被悄悄改掉了，这里提前拦一下。
    if (_presets.any((p) => p.name == name.trim())) {
      _snack('已经有同名方案，请换个名字');
      return;
    }
    final copy = _preset.copy();
    copy.name = name.trim();
    _edit(() {
      _presets = <RenamePreset>[..._presets, copy];
      _preset = copy;
    });
    await _persistPreset();
    await RenamePresetStore.instance.saveActiveName(copy.name);
  }

  Future<void> _deletePreset() async {
    if (_presets.length <= 1) {
      _snack('至少保留一套方案');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除方案', style: TextStyle(fontSize: 15)),
        content: Text('确定删除「${_preset.name}」？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    _edit(() {
      _presets.removeWhere((p) => p.name == _preset.name);
      _preset = _presets.first.copy();
      _templateCtrl.text = _preset.template;
    });
    await _persistPreset();
  }

  void _copyPresets() {
    final text = RenamePresetStore.exportToText(_presets);
    Clipboard.setData(ClipboardData(text: text));
    _snack('已复制 ${_presets.length} 套方案 JSON');
  }

  Future<void> _pastePresets() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final list = RenamePresetStore.parseImport(data?.text ?? '');
    if (list == null) {
      _snack('剪贴板里不是有效的方案 JSON');
      return;
    }
    _edit(() {
      for (final p in list) {
        final i = _presets.indexWhere((q) => q.name == p.name);
        if (i >= 0) {
          _presets[i] = p;
        } else {
          _presets.add(p);
        }
      }
      _preset = _presets.first.copy();
      _templateCtrl.text = _preset.template;
    });
    await RenamePresetStore.instance.savePresets(_presets);
    _snack('已导入 ${list.length} 套方案');
  }

  /// 所有用户编辑的统一入口：标记「已改动」并刷新。
  /// _loadSavedConfig 据此判断要不要覆盖用户输入。
  void _edit(void Function() fn) {
    _touched = true;
    setState(fn);
  }

  /// 扫描范围 / 清洗设置变了必须重新读文件（清洗是在提取时做的）。
  /// 输入时防抖 600ms，避免每敲一个字就重扫一整批。
  void _editScan(void Function() fn) {
    _edit(fn);
    _rescanTimer?.cancel();
    _rescanTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted && _extractionActive) _rescan();
    });
  }

  /// 通用「使用说明」问号按钮：点击弹 AlertDialog 显示该段每个选项的用法。
  /// 弹窗加大：占满左右留白宽度 + 最多 65% 屏高，长解释也能完整看完。
  Widget _helpIcon(String title, String body) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 26,
      height: 26,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 26, height: 26),
        visualDensity: VisualDensity.compact,
        iconSize: 15,
        tooltip: '使用说明',
        icon: Icon(Icons.help_outline, color: cs.onSurfaceVariant),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
            title: Text(title, style: const TextStyle(fontSize: 15)),
            content: SingleChildScrollView(
              child: SizedBox(
                width: double.maxFinite,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx).size.height * 0.6),
                  child: Text(body,
                      style: const TextStyle(fontSize: 13, height: 1.65)),
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('知道了')),
            ],
          ),
        ),
      ),
    );
  }

  /// 扩展名里是否含有明显二进制类型（mp3/zip/pdf/...），有则提示用户风险。
  bool _scanExtHasBinary() {
    const binary = <String>{
      '.mp3', '.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.zip', '.rar',
      '.7z', '.tar', '.gz', '.tgz', '.pdf', '.doc', '.docx', '.ppt', '.pptx',
      '.xls', '.xlsx', '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.exe', '.dll',
      '.apk', '.iso', '.bin', '.dat', '.epub', '.mobi', '.azw', '.azw3',
      '.cab', '.dmg', '.pkg', '.deb',
    };
    for (final e in _preset.scan.extensions) {
      final k = e.trim().toLowerCase();
      final ext = k.startsWith('.') ? k : '.$k';
      if (binary.contains(ext)) return true;
    }
    return false;
  }

  /// 把配置刷回所有 controller（文本 + 整数 + 分隔符）。
  /// 整数 / 分隔符 controller 已提到 State，这里一并同步，load / 重置时调用。
  void _syncControllersFromConfig() {
    _findCtrl.text = _cfg.findText;
    _replaceCtrl.text = _cfg.replaceText;
    _prefixCtrl.text = _cfg.prefix;
    _suffixCtrl.text = _cfg.suffix;
    _extCtrl.text = _cfg.newExt;
    _insertTextCtrl.text = _cfg.insertText;
    _fullNameCtrl.text = _cfg.fullNameBase;
    _fullNameFormatCtrl.text = _cfg.fullNameSeqFormat;
    _seqStartCtrl.text = '${_cfg.sequenceStart}';
    _seqStepCtrl.text = '${_cfg.sequenceStep}';
    _seqWidthCtrl.text = '${_cfg.sequenceWidth}';
    _insertSeqStartCtrl.text = '${_cfg.insertSeqStart}';
    _insertSeqStepCtrl.text = '${_cfg.insertSeqStep}';
    _insertSeqWidthCtrl.text = '${_cfg.insertSeqWidth}';
    _insertPosCtrl.text = '${_cfg.insertPos}';
    _deleteStartCtrl.text = '${_cfg.deleteStart}';
    _deleteLenCtrl.text = '${_cfg.deleteLength}';
    _seqSepCtrl.text = _cfg.sequenceSeparator;
    _dateFmtCtrl.text = _cfg.dateFormat;
    _datePosCtrl.text = '${_cfg.dateInsertPos}';
    _contentInsertPosCtrl.text = '${_cfg.contentInsertPos}';
  }

  /// 修改时间 / 大小缓存。stat 失败时返回 null/0，不让排序崩。
  ({DateTime? modified, int size}) _statFor(String path) {
    final cached = _statCache[path];
    if (cached != null) return cached;
    try {
      final st = FileStat.statSync(path);
      final v = (modified: st.modified, size: st.size);
      _statCache[path] = v;
      return v;
    } catch (_) {
      final v = (modified: null as DateTime?, size: 0);
      _statCache[path] = v;
      return v;
    }
  }

  List<_RenameItem> get _orderedItems {
    final list = [..._items];

    int byName(_RenameItem a, _RenameItem b) =>
        a.oldName.toLowerCase().compareTo(b.oldName.toLowerCase());

    switch (_cfg.orderMode) {
      case 'browser':
        list.sort((a, b) {
          final ra = _browserRank[a.oldPath] ?? (1 << 30);
          final rb = _browserRank[b.oldPath] ?? (1 << 30);
          return ra.compareTo(rb);
        });
        break;
      case 'name':
        list.sort(byName);
        break;
      case 'nameDesc':
        list.sort((a, b) => byName(b, a));
        break;
      case 'mtime':
      case 'mtimeDesc':
        list.sort((a, b) {
          final am = _statFor(a.oldPath).modified;
          final bm = _statFor(b.oldPath).modified;
          // 没有修改时间的始终排最后（倒序也不把它翻到最前）。
          if (am == null && bm == null) return byName(a, b);
          if (am == null) return 1;
          if (bm == null) return -1;
          final c = am.compareTo(bm);
          final v = _cfg.orderMode == 'mtimeDesc' ? -c : c;
          return v != 0 ? v : byName(a, b);
        });
        break;
      case 'size':
      case 'sizeDesc':
        list.sort((a, b) {
          final sizeA = _statFor(a.oldPath).size;
          final sizeB = _statFor(b.oldPath).size;
          final c = sizeA.compareTo(sizeB);
          final v = _cfg.orderMode == 'sizeDesc' ? -c : c;
          return v != 0 ? v : byName(a, b);
        });
        break;
      case 'custom':
        final rank = <String, int>{};
        for (var i = 0; i < _manualOrder.length; i++) {
          rank[_manualOrder[i]] = i;
        }
        // 手动顺序里没有的（例如刚重置过）：接在末尾，保持原有顺序。
        final fallback = <String, int>{};
        for (var i = 0; i < list.length; i++) {
          fallback[list[i].oldPath] = _manualOrder.length + i;
        }
        list.sort((a, b) {
          final ra = rank[a.oldPath] ?? fallback[a.oldPath] ?? (1 << 30);
          final rb = rank[b.oldPath] ?? fallback[b.oldPath] ?? (1 << 30);
          return ra.compareTo(rb);
        });
        break;
      default:
        break;
    }
    return list;
  }

  /// 预览里点上/下箭头：交换相邻两项，并自动切到「手动顺序」。
  void _moveOrderedItem(String oldPath, int delta) {
    final ordered = _orderedItems.map((e) => e.oldPath).toList();
    final from = ordered.indexOf(oldPath);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= ordered.length) return;
    setState(() {
      _touched = true;
      final moved = ordered.removeAt(from);
      ordered.insert(to, moved);
      _manualOrder = ordered;
      _cfg.orderMode = 'custom';
    });
  }

  /// 下拉切换排序方式。切到「手动顺序」时，先以当前预览顺序为基准。
  void _setOrderMode(String? mode) {
    if (mode == null) return;
    setState(() {
      _touched = true;
      if (mode == 'custom') {
        _manualOrder = _orderedItems.map((e) => e.oldPath).toList();
      }
      _cfg.orderMode = mode;
    });
  }

  /// 原文件名里已经带过作者信息就不再追加，避免反复执行内容取名后
  /// 出现「时絮传 作者：张三 作者：张三」这种重复。
  /// 只认明确的标记（作者：/ 著者：/ 原著：/ Author：/ 《…》by名字），
  /// 不做「原名里碰巧有作者两个字」的模糊判断，免得误伤书名。
  bool _nameAlreadyTagged(String base) {
    final s = base.toLowerCase();
    const marks = <String>[
      '作者：',
      '作者:',
      '著者：',
      '著者:',
      '原著：',
      '原著:',
      'author：',
      'author:',
    ];
    for (final m in marks) {
      if (s.contains(m)) return true;
    }
    // 《书名》by顾绥 / 书名 by 顾绥；要求 by 前是书名号或空白，
    // 免得把 Baby、byebye 这类普通单词误判成已带作者。
    return RegExp(
      r'(?:》|\s)by[\s:：]*[\u4e00-\u9fa5A-Za-z]',
      caseSensitive: false,
    ).hasMatch(base);
  }

  /// 把算出来的名字按「④ 输出设置」清洗一遍：非法字符 / 空格 / 长度上限。
  /// 这组设置现在对三种命名方式全局生效（以前只在模板重写里起作用）。
  /// 清洗完变成空名时保守回退原名，不会把文件改成“.”这类危险名字。
  String _sanitizeFinalName(String name, {required bool isDir}) {
    if (isDir) {
      final clean = RenameTemplateEngine.sanitizeBaseName(name, _preset);
      return clean.isEmpty ? name : clean;
    }
    final dot = name.lastIndexOf('.');
    final hasExt = dot > 0 && dot < name.length - 1;
    final base = hasExt ? name.substring(0, dot) : name;
    final ext = hasExt ? name.substring(dot + 1) : '';
    final clean = RenameTemplateEngine.sanitizeBaseName(base, _preset);
    if (clean.isEmpty) return name;
    return ext.isEmpty ? clean : '$clean.$ext';
  }

  /// 预览：每条 (旧路径, 旧名, 新名, 冲突原因?, 抓到的内容, 是否待确认)。
  List<_RenamePreviewEntry> get _preview {
    final out = <_RenamePreviewEntry>[];

    final ordered = _orderedItems;
    // 从文件内容取值：按命名模板从文件内容算出这一行的基础名字；
    // 挖不到时的兜底也只在这条链路上做。
    final useContent = _cfg.insertContentVars;

    for (var i = 0; i < ordered.length; i++) {
      final it = ordered[i];
      var inputName = it.oldName;
      String? note;
      var pending = false;
      var keepOriginal = false;

      // 内置变量表：命名格式的变量替换、插入内容取值都要用。
      final vars = _variablesFor(it, i);
      // 插入内容 → 从文件内容取值：把挖到的变量值按顺序用 _ 连起来。
      // 没挖到任何值就不插，不标黄（标黄兜底只在模板重写模式下做）。
      final String? contentInsert;
      if (_cfg.insertContentVars) {
        final joined = _contentVariableNames
            .map((n) => vars[n] ?? '')
            .where((v) => v.isNotEmpty)
            .join('_');
        contentInsert = joined.isEmpty ? null : joined;
      } else {
        contentInsert = null;
      }

      if (useContent) {
        final vars = _variablesFor(it, i);
        // 原名已经带过作者信息：这次只保留原名，不再套模板追加，
        // 避免二次执行变成「… 作者：张三 作者：张三」。
        final alreadyTagged = _nameAlreadyTagged(vars['原名'] ?? '');
        final effective = <String, String>{...vars};
        if (_preset.fallback == 'defaultValue' &&
            _preset.defaultValue.isNotEmpty) {
          for (final n in _contentVariableNames) {
            if ((effective[n] ?? '').isEmpty) {
              effective[n] = _preset.defaultValue;
            }
          }
        }
        final rendered = RenameTemplateEngine.render(
          template: alreadyTagged ? '{原名}' : _preset.template,
          variables: effective,
          preset: _preset,
          contentVariableNames: _contentVariableNames,
        );

        final parts = <String>[];
        for (final n in _contentVariableNames) {
          final v = vars[n] ?? '';
          if (v.isNotEmpty) parts.add('$n：$v');
        }
        if (parts.isNotEmpty) note = parts.join(' · ');
        if (alreadyTagged) {
          const tag = '原名已带作者信息，未重复追加';
          note = (note == null || note.isEmpty) ? tag : '$note · $tag';
        }

        final missingContent = rendered.missing
            .where((n) => !kBuiltinVariables.contains(n))
            .toSet();
        // 还缺字段（或模板没产出名字）时才保持原名，绝不拿半截名字去改名。
        // keep = 静默保持原名；skip = 标黄待确认可手填；
        // defaultValue = 上面已把默认值填进 effective，这里不会再缺。
        // 之前 fallback == 'keep' 是无条件进 pending，导致启用内容取名后
        // 一个文件都改不了，这里改成只在「真的缺」时生效。
        final hasMissing =
            rendered.baseName.isEmpty || missingContent.isNotEmpty;
        if (hasMissing) {
          keepOriginal = true;
          pending = _preset.fallback != 'keep';
        } else {
          inputName = RenameTemplateEngine.withExtension(
              rendered.baseName, vars['扩展名'] ?? '');
        }
      }

      // 挖不到字段时 keepOriginal：保持原名，绝不拿半截名字去改名。
      final String newName;
      if (keepOriginal) {
        newName = it.oldName;
      } else if (_cfg.renameMode == 'fullName') {
        // 命名格式：{序号} {日期} 等变量已在渲染时替换（{序号} 不写就不编号，
        // 不再自动追加序号）；该模式下 ② 加工被隐藏，直接做输出设置清洗。
        final renderedBase = _renderFullNameBase(_cfg.fullNameBase, vars);
        var computed = _applyFullNameRules(inputName, i, _cfg,
            isDir: it.isDir, useSequence: false, baseOverride: renderedBase);
        computed = _sanitizeFinalName(computed, isDir: it.isDir);
        newName = computed;
      } else {
        // 保留原名：② 加工（含插入内容）→ ④ 输出设置清洗。
        var computed = _applyRenameRules(inputName, i, _cfg,
            isDir: it.isDir, contentInsert: contentInsert);
        computed = _sanitizeFinalName(computed, isDir: it.isDir);
        newName = computed;
      }

      // 第一遍只算新名字，先不判冲突：必须等所有条目都算完，
      // 才知道哪些源文件本批真的会被移走。
      // 手改的目标名在这里覆盖：必须在冲突检测【之前】，这样它也会参与
      // 重名检查，不会静默撞车；提交时读的同样是这份 _preview。
      final manualName = _manualNames[it.oldPath];
      final effectiveName =
          (manualName != null && manualName.isNotEmpty) ? manualName : newName;
      out.add((
        oldPath: it.oldPath,
        oldName: it.oldName,
        newName: effectiveName,
        conflict: null,
        note: note,
        pending: pending,
      ));
    }

    // 第二遍：冲突检测。
    // 只有「本批确实会被改名移走的源路径」才允许链式改名放行。
    // 待确认 / 保持原名的文件不会被移走，若把它当成可让位的目标，
    // 另一个文件就会 rename 到它上面并静默覆盖，造成数据丢失。
    final movingSources = <String>{
      for (final e in out)
        if (e.newName != e.oldName) e.oldPath.toLowerCase(),
    };
    final used = <String>{};
    for (var i = 0; i < out.length; i++) {
      final e = out[i];
      String? conflict;
      if (e.newName == e.oldName) {
        conflict = null; // 未变，灰显
      } else if (e.newName.isEmpty ||
          e.newName.contains('/') ||
          e.newName == '.' ||
          e.newName == '..') {
        conflict = '名称非法';
      } else {
        final parent =
            e.oldPath.substring(0, e.oldPath.lastIndexOf('/'));
        final newFull = '$parent/${e.newName}';
        final exists = FileSystemEntity.typeSync(newFull) !=
            FileSystemEntityType.notFound;
        if (exists &&
            newFull != e.oldPath &&
            !movingSources.contains(newFull.toLowerCase())) {
          conflict = '目标已存在';
        }
        if (used.contains(newFull.toLowerCase())) conflict = '与本批重名';
        used.add(newFull.toLowerCase());
      }
      if (conflict != null) {
        out[i] = (
          oldPath: e.oldPath,
          oldName: e.oldName,
          newName: e.newName,
          conflict: conflict,
          note: e.note,
          pending: e.pending,
        );
      }
    }

    // 重名策略 = 自动加后缀：按「后缀格式」在扩展名前插序号，直到本批不冲突。
    // 输出设置全局生效，不再只在模板重写模式下可用。
    if (_preset.conflictPolicy == 'sequence') {
      // 后缀格式只规范化一次，避免在 while 里反复跑。
      final suffixFormat = RenamePreset.normalizeConflictSuffixFormat(
          _preset.conflictSuffixFormat);
      // 复用第二遍算出的 movingSources：只放行本批真正会移走的源，
      // 避免链式 a→b、b→c 被错误地一路加到 _9。
      for (var i = 0; i < out.length; i++) {
        final e = out[i];
        if (e.conflict != '与本批重名' && e.conflict != '目标已存在') continue;
        // 手改的名字优先：不自动给它加后缀，避免把用户填的名字又改掉；
        // 冲突保持标红跳过，由用户自己再改。
        if (_manualNames.containsKey(e.oldPath)) continue;
        final parent =
            e.oldPath.substring(0, e.oldPath.lastIndexOf('/'));
        bool occupied(String name) {
          final full = '$parent/$name';
          if (used.contains(full.toLowerCase())) return true;
          final exists = FileSystemEntity.typeSync(full) !=
              FileSystemEntityType.notFound;
          return exists && !movingSources.contains(full.toLowerCase());
        }
        var k = 2;
        var candidate = RenameTemplateEngine.withSeqSuffix(
            e.newName, k, format: suffixFormat);
        while (k < 1000 && occupied(candidate)) {
          k++;
          candidate = RenameTemplateEngine.withSeqSuffix(
              e.newName, k, format: suffixFormat);
        }
        used.add('$parent/$candidate'.toLowerCase());
        out[i] = (
          oldPath: e.oldPath,
          oldName: e.oldName,
          newName: candidate,
          conflict: null,
          note: e.note,
          pending: e.pending,
        );
      }
    }
    return out;
  }

  /// 传 build 里已经算好的预览，避免每帧把 _preview（内含同步磁盘 IO）再算一遍。
  bool _canSubmit(List<_RenamePreviewEntry> preview) {
    // 扫描没跑完不能执行，否则会拿半截数据改名。
    if (_extractionActive && _scanning) return false;
    // 命名格式必须先输入格式串。
    if (_cfg.renameMode == 'fullName' && _cfg.fullNameBase.trim().isEmpty) {
      return false;
    }
    // 冲突行允许跳过，不再要求「全部无冲突」才放行。
    // 否则几千个文件里只要有一处重名，整批一个都改不了。
    return preview.any((e) => e.newName != e.oldName && e.conflict == null);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final preview = _preview;
    final conflictCount = preview.where((e) => e.conflict != null).length;

    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: Row(
        children: [
          Expanded(
            child: Text('批量重命名（${_items.length} 项）'),
          ),
          Tooltip(
            message: '清空所有规则，恢复默认；本次和下次打开都是空白规则',
            child: TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              onPressed: _resetConfig,
              child: const Text('重置', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.80,
        child: Column(
          children: [
            // 规则区：可滚动，占 70%
            Expanded(
              flex: 65,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ① 命名方式：二选一，互斥。
                    _sectionMode(),
                    // ② 文件名加工：只在「保留原名」模式显示。
                    // 「从文件内容取值」的方案 / 模板 / 变量 / 扫描范围 / 清洗
                    // 不再平铺在本页，已收进 _sectionInsert 第 5 张来源卡（与品红原型一致）。
                    if (_cfg.renameMode == 'rules') ...<Widget>[
                      _processingHeader(),
                      _sectionFindReplace(),
                      _sectionDelete(),
                      _sectionInsert(),
                      _sectionCase(),
                    ],
                    // 扩展名 / 输出设置：两种模式都显示，编号随模式变。
                    _sectionExt(),
                    _sectionOutput(),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),

            // 预览区：固定，约占 30%（比原来缩小约 1/5，给规则区腾空间）
            Expanded(
              flex: 27,
              child: _sectionPreview(preview, conflictCount, cs),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canSubmit(preview) ? () => _submit() : null,
          child: const Text('执行'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final result = <String, String>{};
    var skipped = 0;
    for (final e in _preview) {
      if (e.newName == e.oldName || e.conflict != null) {
        skipped++;
        continue;
      }
      // 直接从路径取父目录；firstWhere 找不着会抛异常，改名弹窗不该崩。
      final parent =
          e.oldPath.substring(0, e.oldPath.lastIndexOf('/'));
      result[e.oldPath] = '$parent/${e.newName}';
    }
    // 只有勾了「记住上次规则」才落盘；默认不保存，下次打开是空白规则。
    // 等写完盘再关弹窗，否则 SharedPreferences 可能还没落盘。
    if (_rememberConfig) await _saveRenameConfig(_cfg);
    // 方案本身的修改要保留，否则下次打开又丢回默认。等写完盘再关弹窗。
    await _persistPreset();
    if (!mounted) return;
    Navigator.pop(context, (renames: result, skipped: skipped));
  }

  /// 一键回到默认规则，同时关掉「记住上次规则」并清掉已存规则，
  /// 点一次重置，本次和下次打开都是干净的（以前重置只改界面、下次又读回来）。
  void _resetConfig() {
    setState(() {
      _touched = true; // 防止正在进行的异步读取把刚重置的界面覆盖回去
      _cfg = _RenameConfig();
      _manualOrder = const [];
      _rememberConfig = false;
      _manualValues.clear();
      _manualNames.clear();
      _varsByPath.clear();
      _errorsByPath.clear();
      _charCountByPath.clear();
      _rescanTimer?.cancel();
      _scanGeneration++;
      _scanning = false;
      _scanned = 0;
      _scanTotal = 0;
      _preset = RenamePreset.starter();
      _templateCtrl.text = _preset.template;
      _syncControllersFromConfig();
      _syncContentCtrls();
    });
    _saveRenameRemember(false);
    _clearSavedRenameConfig();
  }

  // ---------- 规则区：① 命名方式 → ② 加工 → ③ 扩展名 → ④ 输出设置 ----------

  static const String _helpModeText = '决定新名字从哪来，二选一，互斥，一次只能用一种。\n'
      '• 保留原名（默认）：保留原文件名，再用下面的「文件名加工」改。最常用。\n'
      '• 命名格式：自己写一个格式（类似 Windows 里选中一批文件重命名），保留原扩展名。想保留原文件名就写 {原名}；想加序号就在格式里写 {序号}——不写就不加，所以名字里可以只有 {日期} 或 {大小可读}。\n'
      '• 带齿轮的变量可自定义：{日期} 设日期格式，{序号} 设起始 / 步长 / 位数，{大小可读} 设单位和小数位。变量点下面的标签插入。\n'
      '• 选「保留原名」时会显示「文件名加工」；选「命名格式」时为免干扰先隐藏加工，只留扩展名和输出设置。';

  static const String _helpProcessingText = '对名字做加工的动作，只在「保留原名」模式下显示，可同时开多个。\n'
      '• 展开哪一组就启用哪一组，收起即关闭。\n'
      '• 处理顺序固定：查找替换 → 删除指定位置的字符 → 插入内容 → 统一大小写。\n'
      '• 扩展名单独一步（③），始终最后处理。\n'
      '• 插入内容可同时选多个来源：固定文字 / 日期 / 序号 / 从文件内容取值 / 前缀后缀。';

  static const String _helpInsertText = '往名字里插东西。下面有 5 张来源卡，点开一张单独设置，可以同时启用多张。\n'
      '• 固定文字 / 前缀后缀：填上内容就生效，留空 = 不启用，没有开关。\n'
      '• 日期 / 序号 / 从文件内容取值：点「＋ 添加」启用，点「移除」停用。\n'
      '• 固定文字、日期、从文件内容取值各有自己的「插到」：名称前面 / 名称后面 / 第 N 位前（选第 N 位前会多出一个数字框，1 = 名字第一个字前，扩展名不算位）。\n'
      '• 序号：给每个文件编号；位数 2 会变成 01、02；按预览区上方的「序号顺序」排。这套与「命名格式」里的 {序号} 各自独立、互不影响。\n'
      '• 前缀 / 后缀固定在名字两端，没有「插到」；后缀在扩展名之前。\n'
      '• 从文件内容取值：按命名模板把从文件里挖到的变量拼进名字；展开这张卡，里面有「插到」和整套设置（方案 / 插入模板 / 变量 / 扫描范围 / 清洗），启用后会读文件扫描。';

  /// 切换命名方式。切到会读文件的模式时立即扫描。
  void _setMode(String m) {
    final wasActive = _extractionActive;
    _edit(() {
      _cfg.renameMode = m;
      // 命名格式模式下「从文件内容取值」跟着关闭：加工区已隐藏，取值没处挂。
      if (m == 'fullName') _cfg.insertContentVars = false;
    });
    if (_extractionActive && !wasActive) _rescan();
  }

  String get _modeHintText {
    switch (_cfg.renameMode) {
      case 'fullName':
        return '按你写的格式生成新名字：{原名} 保留原名、{序号} 编号、{日期}/{大小可读} 加时间大小（带齿轮可设格式）；还有 {目录名} {大小} {字数} 可用；加工已隐藏。';
      default:
        return '保留原文件名，用下面的加工改。最常用。';
    }
  }

  /// ① 命名方式：二选一选项卡 + 提示行；选「命名格式」时附带它的配置区。
  Widget _sectionMode() {
    final cs = Theme.of(context).colorScheme;
    Widget tab(String mode, String title, String sub) {
      final on = _cfg.renameMode == mode;
      return Expanded(
        child: GestureDetector(
          onTap: () => _setMode(mode),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            decoration: BoxDecoration(
              color: on ? cs.primaryContainer : cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: on ? _headerAccent(cs) : Colors.transparent),
            ),
            child: Column(
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: on ? _headerAccent(cs) : Colors.black)),
                const SizedBox(height: 2),
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10,
                        color: on ? _headerAccent(cs) : cs.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      );
    }

    // 卡片自带左右外边距 8，这里只补顶部间距，与其它分区卡对齐。
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: _card(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: <Widget>[
                Text('① 命名方式（二选一）',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _headerAccent(cs))),
                _helpIcon('命名方式', _helpModeText),
              ]),
              const SizedBox(height: 6),
              Row(children: <Widget>[
                tab('rules', '保留原名', '用下面的加工改'),
                const SizedBox(width: 6),
                tab('fullName', '命名格式', '自己写格式'),
              ]),
              const SizedBox(height: 4),
              Text(_modeHintText,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              if (_cfg.renameMode == 'fullName') _fullNameCfg(),
            ],
          ),
        ),
      ),
    );
  }

  /// 命名格式的配置：格式框 + 内置变量标签（带齿轮可设格式）+ 实时预览 +
  /// 序号摘要（点「序号设置」打开全局序号浮层）。
  Widget _fullNameCfg() {
    final cs = Theme.of(context).colorScheme;
    final hint = cs.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 120,
                child: Text('命名格式（不含扩展名）',
                    style: const TextStyle(fontSize: 11, color: Colors.black),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _fullNameCtrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '例如：旅行_{日期}_{序号}，想保留原名就写 {原名}',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                  ),
                  style: const TextStyle(fontSize: 12),
                  onChanged: (v) => _edit(() => _cfg.fullNameBase = v),
                ),
              ),
              _helpIcon('命名格式', '命名格式里写普通文字和变量标签，变量会被替换成实际值：\n'
                  '• {原名} = 原文件名（不含扩展名）；{目录名} = 文件所在文件夹名\n'
                  '• {日期} = 当前日期，点 {日期} 旁的齿轮选格式（如 2026-11-14、20261114）\n'
                  '• {序号} = 递增编号；格式里不写 {序号} 就不会编号。起始 / 步长 / 位数点 {序号} 旁的齿轮设置，这套只管命名格式，与「插入内容 → 序号」各自独立、互不影响\n'
                  '• {大小} = 文件字节数（纯数字，无单位）；{大小可读} = 带单位的大小（如 12.3MB，点齿轮设单位 / 小数位）；{字数} = 正文字符数（约数，如 2.4千字）\n'
                  '• 想保留原名就只写 {原名}；留空则用原名\n'
                  '• 例：旅行_{日期}_{序号} → 旅行_20261114_01.txt\n'
                  '• 选这个模式时「文件名加工」会隐藏；扩展名与输出设置仍然生效。'),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text('点一下插入', style: TextStyle(fontSize: 11, color: hint)),
              for (final v in const <String>[
                '{原名}',
                '{目录名}',
                '{大小}',
                '{字数}',
              ])
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(v, style: const TextStyle(fontSize: 11)),
                  onPressed: () => _insertFullNameVar(v),
                ),
              _varWithGear('{日期}', '设置日期格式', _showDateFormatDialog),
              _varWithGear('{序号}', '设置序号', _showSeqDialog),
              _varWithGear('{大小可读}', '设置大小格式', _showSizeFormatDialog),
            ],
          ),
          const SizedBox(height: 4),
          Text(_fullNameSampleLine(),
              style: TextStyle(fontSize: 11, color: hint)),
          // 序号摘要 / 加序号说明 / 大小相关说明这三行灰字已全部收进
          // 输入框右侧的圆圈问号；与品红原型一致，这里只留「预览：」一行。
        ],
      ),
    );
  }

  /// 在新名字输入框光标处插入变量标签。
  void _insertFullNameVar(String v) {
    final t = _fullNameCtrl.text;
    var pos = _fullNameCtrl.selection.baseOffset;
    if (pos < 0 || pos > t.length) pos = t.length;
    _edit(
        () => _cfg.fullNameBase = t.substring(0, pos) + v + t.substring(pos));
    _fullNameCtrl.text = _cfg.fullNameBase;
    _fullNameCtrl.selection = TextSelection.collapsed(offset: pos + v.length);
  }

  /// 在模板输入框光标处插入 {变量}。
  void _insertTemplateVar(String name) {
    final v = '{$name}';
    final t = _templateCtrl.text;
    var pos = _templateCtrl.selection.baseOffset;
    if (pos < 0 || pos > t.length) pos = t.length;
    _edit(() => _preset.template = t.substring(0, pos) + v + t.substring(pos));
    _templateCtrl.text = _preset.template;
    _templateCtrl.selection =
        TextSelection.collapsed(offset: pos + v.length);
  }

  String _fullNameSampleLine() {
    if (_items.isEmpty) return '预览：—';
    final it = _orderedItems.first;
    final vars = _variablesFor(it, 0);
    final base = _renderFullNameBase(_cfg.fullNameBase, vars);
    final dot = it.oldName.lastIndexOf('.');
    final ext = (!it.isDir && dot > 0 && dot < it.oldName.length - 1)
        ? it.oldName.substring(dot)
        : '';
    return '预览：${base.isEmpty ? '（还没输入格式）' : '$base$ext'}';
  }

  /// 变量标签 + 齿轮按钮：点标签插入，点齿轮打开该变量的格式设置。
  Widget _varWithGear(String v, String tip, VoidCallback onGear) {
    final cs = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
      ActionChip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        label: Text(v, style: const TextStyle(fontSize: 11)),
        onPressed: () => _insertFullNameVar(v),
      ),
      SizedBox(
        width: 22,
        height: 22,
        child: IconButton(
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          iconSize: 14,
          tooltip: tip,
          icon: Icon(Icons.settings_outlined, color: cs.onSurfaceVariant),
          onPressed: onGear,
        ),
      ),
    ]);
  }

  /// {日期} 的格式设置：常用格式点选 + 自定义 + 实时预览。
  Future<void> _showDateFormatDialog() async {
    String fmt = _cfg.varDateFormat;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
          title: const Text('日期格式', style: TextStyle(fontSize: 15)),
          content: SingleChildScrollView(
            child: SizedBox(
              width: double.maxFinite,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('可用符号：yyyy 年 · MM 月 · dd 日 · HH 时 · mm 分 · ss 秒',
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final f in const <String>[
                          'yyyyMMdd',
                          'yyyy-MM-dd',
                          'yyyyMMdd_HHmm',
                          'yyyyMMdd_HHmmss',
                          'yyyy年MM月dd日',
                        ])
                          ChoiceChip(
                            label: Text(_formatDate(DateTime.now(), f),
                                style: const TextStyle(fontSize: 11)),
                            selected: fmt == f,
                            onSelected: (_) => setD(() => fmt = f),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: TextEditingController(text: fmt),
                      decoration: const InputDecoration(
                          labelText: '自定义格式',
                          isDense: true,
                          border: OutlineInputBorder()),
                      onChanged: (v) => fmt = v,
                    ),
                    const SizedBox(height: 6),
                    Text('预览：${_formatDate(DateTime.now(), fmt)}',
                        style: const TextStyle(fontSize: 12)),
                  ]),
            ),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                _edit(() => _cfg.varDateFormat =
                    fmt.trim().isEmpty ? 'yyyyMMdd' : fmt.trim());
                Navigator.pop(ctx);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  /// {大小可读} 的格式设置：单位 + 小数位 + 实时预览。
  Future<void> _showSizeFormatDialog() async {
    String unit = _cfg.varSizeUnit;
    int dec = _cfg.varSizeDec;
    final demo = _items.isEmpty
        ? 13527040
        : _statFor(_items.first.oldPath).size;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
          title: const Text('大小格式', style: TextStyle(fontSize: 15)),
          content: SingleChildScrollView(
            child: SizedBox(
              width: double.maxFinite,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('单位（示例文件 ${_humanSizeEx(demo, 'auto', 1)}）',
                        style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final u in const <String>['auto', 'KB', 'MB', 'GB', 'B'])
                          ChoiceChip(
                            label: Text(
                                u == 'auto'
                                    ? '自适应'
                                    : (u == 'B' ? '字节' : u),
                                style: const TextStyle(fontSize: 11)),
                            selected: unit == u,
                            onSelected: (_) => setD(() => unit = u),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('小数位', style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: <Widget>[
                        for (final d in const <int>[0, 1, 2])
                          ChoiceChip(
                            label: Text('$d', style: const TextStyle(fontSize: 11)),
                            selected: dec == d,
                            onSelected: (_) => setD(() => dec = d),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('预览：${_humanSizeEx(demo, unit, dec)}',
                        style: const TextStyle(fontSize: 12)),
                  ]),
            ),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                _edit(() {
                  _cfg.varSizeUnit = unit;
                  _cfg.varSizeDec = dec;
                });
                Navigator.pop(ctx);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  /// 命名格式 {序号} 的齿轮设置浮层：格式 / 起始 / 步长 / 位数 / 顺序。
  /// 只管 A 这一套；「插入内容 → 序号」（B）在自己卡里配，互不影响。
  Future<void> _showSeqDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setD) {
            void upd(void Function() fn) {
              _touched = true;
              fn();
              setD(() {});
            }

            return AlertDialog(
              title: const Text('序号设置'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '这里只管「命名格式」里的 {序号}。「插入内容 → 序号」是另一套独立配置，在它自己的来源卡里设，两边互不影响。',
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Text('序号格式（{n} 会替换成序号）',
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(ctx).colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final fmt in const <String>[
                          '({n})',
                          '-{n}',
                          '_{n}',
                          '（{n}）',
                          '{n}',
                        ])
                          ChoiceChip(
                            label: Text(fmt.replaceAll('{n}', '1'),
                                style: const TextStyle(fontSize: 12)),
                            selected: _cfg.fullNameSeqFormat == fmt,
                            onSelected: (_) => upd(() {
                              _cfg.fullNameSeqFormat = fmt;
                              _fullNameFormatCtrl.text = fmt;
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _formRow('自定义格式',
                      TextField(
                        controller: _fullNameFormatCtrl,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '({n})',
                          border: OutlineInputBorder(),
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                        ),
                        style: const TextStyle(fontSize: 12),
                        onChanged: (v) => upd(() => _cfg.fullNameSeqFormat = v),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _formRow('起始 / 步长 / 位数',
                      Row(children: <Widget>[
                        Expanded(
                          child: _numField(_seqStartCtrl,
                              (v) => upd(() => _cfg.sequenceStart = v)),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: _numField(_seqStepCtrl,
                              (v) => upd(() => _cfg.sequenceStep = v)),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: _numField(_seqWidthCtrl,
                              (v) => upd(() => _cfg.sequenceWidth = v)),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    _formRow('顺序（序号按什么排）',
                      DropdownButtonFormField<String>(
                        value: _kRenameOrderModes.contains(_cfg.orderMode)
                            ? _cfg.orderMode
                            : 'browser',
                        isExpanded: true,
                        isDense: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        items: <DropdownMenuItem<String>>[
                          for (final o in _kRenameOrderOptions)
                            DropdownMenuItem<String>(
                                value: o.$1,
                                child: Text(o.$2,
                                    style: const TextStyle(fontSize: 12))),
                        ],
                        onChanged: (v) => upd(() {
                          if (v == null) return;
                          if (v == 'custom') {
                            _manualOrder =
                                _orderedItems.map((e) => e.oldPath).toList();
                          }
                          _cfg.orderMode = v;
                        }),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() {});
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 规则区卡片容器：白底圆角 + 统一阴影（与原型一致，所有分区卡共用）。
  Widget _card(Widget child) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 9),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
        boxShadow: _kCardShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: child,
      ),
    );
  }

  /// ② 加工区标题行。
  Widget _processingHeader() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      // 卡片化后与卡片内标题对齐：卡外边距 8 + 内边距 12 = 20。
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
      child: Row(children: <Widget>[
        Text('② 文件名加工（可叠加）',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _headerAccent(cs))),
        _helpIcon('文件名加工', _helpProcessingText),
      ]),
    );
  }

  // —— 通用小控件：模板设置与加工区共用 ——
  // 原来是 _sectionContent 里的局部闭包，现在提取设置在模板模式和
  // 「插入内容 → 从文件内容取值」两处都要用，所以提成 State 方法。

  Widget _subHead(String s, {String? help}) {
    final cs = Theme.of(context).colorScheme;
    final title = Text(s,
        style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600, color: _headerAccent(cs)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: help == null
          ? title
          : Row(children: <Widget>[Flexible(child: title), _helpIcon(s, help)]),
    );
  }

  Widget _formRow(String label, Widget child, {String? help}) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 120,
              child: help == null
                  ? Text(label,
                      style: const TextStyle(fontSize: 11, color: Colors.black),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis)
                  : Row(children: <Widget>[
                      Flexible(
                        child: Text(label,
                            style: const TextStyle(fontSize: 11, color: Colors.black),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                      ),
                      _helpIcon(label, help),
                    ]),
            ),
            const SizedBox(width: 8),
            Expanded(child: child),
          ],
        ),
      );

  Widget _textRow(
    String label,
    String key,
    String value,
    ValueChanged<String> on, {
    String? tip,
    String? help,
    bool number = false,
  }) =>
      _formRow(
        label,
        TextField(
          controller: _ctrl(key, value),
          decoration: InputDecoration(
            isDense: true,
            hintText: tip,
            border: const OutlineInputBorder(),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          ),
          style: const TextStyle(fontSize: 12),
          keyboardType: number ? TextInputType.number : null,
          onChanged: on,
        ),
        help: help,
      );

  Widget _dropRow(
    String label,
    String value,
    List<String> values,
    List<String> labels,
    ValueChanged<String?> on, {
    String? help,
  }) =>
      _formRow(
        label,
        DropdownButtonFormField<String>(
          value: values.contains(value) ? value : values.first,
          isExpanded: true,
          isDense: true,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          ),
          items: <DropdownMenuItem<String>>[
            for (var i = 0; i < values.length; i++)
              DropdownMenuItem<String>(
                value: values[i],
                child: Text(labels[i], style: const TextStyle(fontSize: 12)),
              ),
          ],
          onChanged: on,
        ),
        help: help,
      );

  // 关闭态圆点：比纯白只暗一点点（#F7F7F7）。
  // 只作用于批量重命名弹窗：本文件所有开关都经过 _formToggle，而它的调用点
  // 全在 _BatchRenameDialogState 内；不碰 app_theme.dart、不改全局主题，
  // 所以换任何皮肤 / 全局开关主题怎么配，弹窗里都是这一颗灰一点点的小圆点。
  static const Color _kOffSwitchThumb = Color(0xFFF7F7F7);

  /// 以当前全局开关主题为底，只覆盖「关闭态圆点」。
  /// 用 copyWith 保留父主题的轨道色 / 描边 / 打开态圆点 / 按压态等全部设置。
  SwitchThemeData _localSwitchTheme(BuildContext context) {
    final parent = SwitchTheme.of(context);
    return parent.copyWith(
      thumbColor: WidgetStateProperty.resolveWith<Color?>((states) {
        // 打开态、禁用态照旧用全局主题解析出来的颜色，一律不动。
        if (states.contains(WidgetState.selected) ||
            states.contains(WidgetState.disabled)) {
          return parent.thumbColor?.resolve(states);
        }
        return _kOffSwitchThumb;
      }),
    );
  }

  Widget _formToggle(String label, bool v, ValueChanged<bool> on) => SwitchTheme(
        data: _localSwitchTheme(context),
        child: SizedBox(
          width: double.infinity,
          child: SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: Text(label, style: const TextStyle(fontSize: 12)),
            value: v,
            onChanged: on,
          ),
        ),
      );

  Widget _iconBtn(IconData icon, String tip, VoidCallback on) => SizedBox(
        width: 30,
        height: 30,
        child: IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          iconSize: 16,
          tooltip: tip,
          icon: Icon(icon),
          onPressed: on,
        ),
      );

  Widget _fieldRowWidget(ContentField f) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
        child: Row(children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('{${f.name}}', style: const TextStyle(fontSize: 11)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: GestureDetector(
              onTap: () => _addOrEditField(f),
              child: Text(
                f.pattern.trim().isEmpty
                    ? '规则留空，点此填正则'
                    : '${locatorLabel(f.locator)} · ${f.pattern}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          _iconBtn(Icons.edit, '编辑变量', () => _addOrEditField(f)),
          _iconBtn(Icons.delete_outline, '删除变量', () => _confirmRemoveField(f)),
        ]),
      );

  String get _activePresetName => _presets.any((p) => p.name == _preset.name)
      ? _preset.name
      : (_presets.isEmpty ? '' : _presets.first.name);

  /// 变量 + 扫描范围 + 清洗 + 挖不到时 + 扫描状态。
  /// 变量 / 扫描范围 / 清洗等设置在「从文件内容取值」展开区共用同一份（同一个 State）。
  List<Widget> _buildExtractBlocks() => <Widget>[
        _subHead('变量（挖什么 / 怎么找）', help:
            '一行 = 一个变量；变量名会变成模板 / 插入内容里的 {变量名}。默认给好了「书名 / 作者 / 主角」三行。\n'
            '• 点正则文字，或点右边的编辑按钮：打开编辑框，设置「变量叫什么、用什么方式找」。\n'
            '• 找法可在编辑框里选：正则 / 关键词行 / 行号 / 起止标记 / 书名号等。\n'
            '• 规则留空 = 这个变量不自动挖，适合「主角」这类没有固定写法的字段；之后在预览里点「待确认」手填。\n'
            '• 同名变量可以加多条规则，按顺序兜底：第一条没挖到就试下一条。\n'
            '• 添加变量：新增一行（如 {出版社}），模板和插入内容里就能用 {这个名} 引用。\n'
            '• 右边删除按钮：删掉这一行变量，会先弹确认框，确认后才删。'),
        for (final f in _preset.fields) _fieldRowWidget(f),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: OutlinedButton.icon(
            onPressed: () => _addOrEditField(),
            icon: const Icon(Icons.add, size: 14),
            label: const Text('添加变量', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black,
              side: const BorderSide(color: Colors.black),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            ),
          ),
        ),

        _subHead('扫描范围', help:
            '决定「从每个文件的哪一段、用什么编码、哪些文件」去挖变量。默认只读开头一小段，不读整本，最省时。\n'
            '• 范围：开头 / 结尾 / 开头+结尾 / 全文。选哪种，下方就只显示相关的输入框。\n'
            '• 按大小 / 按行数（开头和结尾各一组）：二选一，选中哪个就只显示对应的一个框，永远只有一个生效。\n'
            '   - 按大小：读开头（或结尾）多少 KB，1~2048，填太大自动收成 2048。\n'
            '   - 按行数：只在最前（或最后）N 行里找。\n'
            '• 全文读取上限 MB：只有范围选「全文」才出现；防止超大文件整本读进来卡死。\n'
            '• 编码：默认自动识别；出现乱码时手动指定 UTF-8 / GBK / Big5 等。\n'
            '• 扩展名：只处理这些后缀（默认 .txt），其他文件直接跳过。切勿填 .mp3/.zip/.pdf 等，会把二进制当文本读、可能乱码甚至卡死。\n'
            '• 同时扫描文件数：一次并行读几个文件（1~8，默认 3），数字越大越快但越吃资源。\n'
            '• 递归展开选中的子文件夹：勾上后连子文件夹里的文件一起处理。'),
        _dropRow('范围', _preset.scan.scope,
            const <String>['head', 'tail', 'both', 'full'],
            const <String>['开头', '结尾', '开头+结尾', '全文'],
            (v) => _editScan(() => _preset.scan.scope = v ?? 'head')),
        // —— 开头：二选一（按大小 / 按行数）——
        if (_preset.scan.scope == 'head' || _preset.scan.scope == 'both')
          ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Row(
                children: <Widget>[
                  ChoiceChip(
                    label: const Text('按大小', style: TextStyle(fontSize: 12)),
                    selected: _preset.scan.headMode == 'bytes',
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) =>
                        _editScan(() => _preset.scan.headMode = 'bytes'),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('按行数', style: TextStyle(fontSize: 12)),
                    selected: _preset.scan.headMode == 'lines',
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) =>
                        _editScan(() => _preset.scan.headMode = 'lines'),
                  ),
                ],
              ),
            ),
            if (_preset.scan.headMode == 'bytes')
              _textRow('开头 KB', 'headKB',
                  '${(_preset.scan.headBytes / 1024).round()}', (v) {
                final n = int.tryParse(v);
                if (n == null) return;
                // 兜底：开头/结尾读取窗口封顶 2MB(2048KB)，避免误填几万KB把整段读爆。
                final clamped = n.clamp(1, 2048);
                _editScan(() => _preset.scan.headBytes = clamped * 1024);
                if (clamped != n) {
                  final c = _contentCtrls['headKB'];
                  if (c != null) c.text = '$clamped';
                }
              }, number: true)
            else
              _textRow('开头前 N 行', 'headLines', '${_preset.scan.headLines}',
                  (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 0) {
                  _editScan(() => _preset.scan.headLines = n);
                }
              }, number: true),
          ],
        // —— 结尾：二选一（按大小 / 按行数）——
        if (_preset.scan.scope == 'tail' || _preset.scan.scope == 'both')
          ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Row(
                children: <Widget>[
                  ChoiceChip(
                    label: const Text('按大小', style: TextStyle(fontSize: 12)),
                    selected: _preset.scan.tailMode == 'bytes',
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) =>
                        _editScan(() => _preset.scan.tailMode = 'bytes'),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('按行数', style: TextStyle(fontSize: 12)),
                    selected: _preset.scan.tailMode == 'lines',
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) =>
                        _editScan(() => _preset.scan.tailMode = 'lines'),
                  ),
                ],
              ),
            ),
            if (_preset.scan.tailMode == 'bytes')
              _textRow('结尾 KB', 'tailKB',
                  '${(_preset.scan.tailBytes / 1024).round()}', (v) {
                final n = int.tryParse(v);
                if (n == null) return;
                final clamped = n.clamp(1, 2048);
                _editScan(() => _preset.scan.tailBytes = clamped * 1024);
                if (clamped != n) {
                  final c = _contentCtrls['tailKB'];
                  if (c != null) c.text = '$clamped';
                }
              }, number: true)
            else
              _textRow('结尾前 N 行', 'tailLines', '${_preset.scan.tailLines}',
                  (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 0) {
                  _editScan(() => _preset.scan.tailLines = n);
                }
              }, number: true),
          ],
        if (_preset.scan.scope == 'full')
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text('全文：读取整个文件（上限 8 MB），下方裁切参数不生效。',
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          )
        else if (_preset.scan.scope == 'head')
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text('只读开头，『结尾』参数不生效。',
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          )
        else if (_preset.scan.scope == 'tail')
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text('只读结尾，『开头』参数不生效。',
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text('开头与结尾都读，以上参数均生效。',
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        _dropRow('编码', _preset.scan.encoding, const <String>[
          'auto', 'utf8', 'utf8bom', 'utf16le', 'utf16be',
          'gbk', 'gb18030', 'big5',
        ], const <String>[
          '自动识别', 'UTF-8', 'UTF-8 (BOM)', 'UTF-16 LE', 'UTF-16 BE',
          'GBK', 'GB18030', 'Big5',
        ], (v) => _editScan(() => _preset.scan.encoding = v ?? 'auto')),
        _textRow('扩展名', 'exts', _preset.scan.extensions.join(','), (v) {
          _editScan(() => _preset.scan.extensions = <String>[
                for (final e in v.split(','))
                  if (e.trim().isNotEmpty) e.trim(),
              ]);
        }, tip: '.txt,.md'),
        if (_scanExtHasBinary())
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text(
              '注意：含非文本扩展名（如 .mp3/.zip/.pdf）。扫描时会按文本读取其内容，可能乱码甚至卡死，建议只保留纯文本扩展名。',
              style: TextStyle(
                  fontSize: 11, color: Colors.orange.shade800),
            ),
          ),
        if (_preset.scan.scope == 'full')
          _textRow(
              '全文读取上限 MB',
              'fullCapMB',
              '${(_preset.scan.fullReadCapBytes / (1024 * 1024)).round()}',
              (v) {
            final n = int.tryParse(v);
            if (n != null && n >= 1) {
              _editScan(
                  () => _preset.scan.fullReadCapBytes = n * 1024 * 1024);
            }
          },
              tip: '全文模式最多读取多少 MB（防整本读入卡死），默认 8',
              number: true),
        _textRow('同时扫描文件数', 'concurrency', '${_preset.scan.concurrency}',
            (v) {
          final n = int.tryParse(v);
          if (n != null && n >= 1) {
            _editScan(
                () => _preset.scan.concurrency = n.clamp(1, 8).toInt());
          }
        }, tip: '1~8，默认 3', number: true),
        _formToggle('递归展开选中的子文件夹', _preset.scan.includeSubfolders,
            (v) => _setRecursive(v)),

        _subHead('提取后清洗', help:
            '从文件里挖到的每个值，拼进文件名之前先按下面这些规则「洗干净」。改这些会自动重新扫描。\n'
            '• 黑名单：挖到的值里含有这些词（逗号分隔）就当作没挖到，例如「本站整理,佚名,http」。\n'
            '• 变量最长字数(字)：每个值最多保留多少个字（默认 24），超出从尾部截断；填 0 = 不限。\n'
            '• 去掉结尾的「著 / 编 / 作品」：把「张三著」清成「张三」，避免作者名带尾巴。\n'
            '• 只保留中英文和数字：丢掉标点等符号，防止文件名里混入非法字符。\n'
            '• 全角转半角：把 ＡＢＣ１２３ 这类全角字符转成 ABC123。\n'
            '• 合并连续空白：把连续多个空格压成一个。'),
        _textRow('黑名单', 'blacklist', _preset.clean.blacklist.join(','), (v) {
          _editScan(() => _preset.clean.blacklist = <String>[
                for (final e in v.split(','))
                  if (e.trim().isNotEmpty) e.trim(),
              ]);
        }, tip: '本站整理,佚名,http'),
        _textRow('变量最长字数(字)', 'valueMax', '${_preset.clean.maxLength}',
            (v) {
          final n = int.tryParse(v);
          if (n != null && n >= 0) {
            _editScan(() => _preset.clean.maxLength = n);
          }
        },
            tip: '每个挖到的字段最多保留多少字，超出从尾部截断（默认 24，最大 200）。',
            number: true),
        _formToggle('去掉结尾的「著 / 编 / 作品」', _preset.clean.stripTrailingWords,
            (v) => _editScan(() => _preset.clean.stripTrailingWords = v)),
        _formToggle('只保留中英文和数字', _preset.clean.removePunctuation,
            (v) => _editScan(() => _preset.clean.removePunctuation = v)),
        _formToggle('全角转半角', _preset.clean.toHalfWidth,
            (v) => _editScan(() => _preset.clean.toHalfWidth = v)),
        _formToggle('合并连续空白', _preset.clean.collapseWhitespace,
            (v) => _editScan(() => _preset.clean.collapseWhitespace = v)),

        _subHead('挖不到时', help:
            '变量在文件内容里没找到值怎么办（文件名的合法性、长度、重名在「输出设置」，对三种命名方式都通用）。\n'
            '• 跳过并标黄待确认：这行先不改名，预览里标黄，点一下可手填。\n'
            '• 填默认值：用下面「默认值」框里的内容顶上。\n'
            '• 保持原名：文件名原样不动。'),
        _dropRow('挖不到时', _preset.fallback,
            const <String>['skip', 'defaultValue', 'keep'],
            const <String>['跳过并标黄待确认', '填默认值', '保持原名'],
            (v) => _edit(() => _preset.fallback = v ?? 'skip'),
            help: '变量在文件里没找到值时这行怎么办：\n'
                '• 跳过并标黄待确认：预览里标黄，点一下手动填，适合个别文件特殊处理。\n'
                '• 填默认值：用下面的「默认值」顶上，适合批量统一。\n'
                '• 保持原名：这一行不改名，跟没设一样。'),
        if (_preset.fallback == 'defaultValue')
          _textRow('默认值', 'defaultValue', _preset.defaultValue,
              (v) => _edit(() => _preset.defaultValue = v),
              tip: '没挖到变量的文件用这个内容顶上，如 未知作者'),

        _subHead('扫描状态', help:
            '这里显示读取文件的进度和结果概况，一般不需要手动操作。\n'
            '• 「正在扫描 X / Y」：正在逐个读文件；「已扫描 Y 项 · 识别 Z 项」：有多少文件成功挖到了变量、多少读取失败。\n'
            '• 改动「变量 / 扫描范围 / 编码 / 清洗」后会自动重新扫描，预览会跟着更新。\n'
            '• 重新扫描：不改设置、手动再扫一遍（比如文件内容刚被改动过）。\n'
            '• 保存方案：把当前这套设置存下来，下次可从上方下拉框直接切换。'),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
          child: Row(children: <Widget>[
            Expanded(
              child: Text(
                _scanning
                    ? '正在扫描 $_scanned / $_scanTotal …'
                    : '已扫描 $_scanTotal 项 · 识别 ${_varsByPath.length} 项'
                        '${_errorsByPath.isEmpty ? '' : ' · ${_errorsByPath.length} 项读取失败'}',
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            TextButton(
              onPressed: _scanning ? null : () => _rescan(),
              child: const Text('重新扫描', style: TextStyle(fontSize: 11)),
            ),
            TextButton(
              onPressed: () => _persistPreset(),
              child: const Text('保存方案', style: TextStyle(fontSize: 11)),
            ),
          ]),
        ),
      ];

  /// 「从文件内容取值」的全部设置，平铺一页：方案 → 命名模板 → 内容变量 →
  /// 变量 / 扫描范围 / 清洗 / 挖不到时 / 扫描状态。
  List<Widget> _buildTemplateBlocks() => <Widget>[
        _subHead('方案（可切换 / 导入导出）', help:
            '一套「方案」= 命名模板 + 变量 + 扫描范围 + 清洗规则等全部设置，切换方案就是整页设置一起换。\n'
            '• 下拉框：在已保存的方案之间切换，切换后立即按新方案重新扫描。\n'
            '• 右侧 ⋮ 菜单：\n'
            '   - 另存为方案（新建）：把当前这套设置起个名字存起来。\n'
            '   - 删除方案：删掉当前选中的方案。\n'
            '   - 复制方案 JSON：把当前设置复制成一段文字，可备份或发给别人。\n'
            '   - 从剪贴板导入：把别人给的 JSON 粘进来，一键还原整套设置。\n'
            '• 记住上次选的方案：勾上后下次打开自动用这次的方案。'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _activePresetName.isEmpty ? null : _activePresetName,
                isDense: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final p in _presets)
                    DropdownMenuItem<String>(
                      value: p.name,
                      child: Text(p.name,
                          style: const TextStyle(fontSize: 12)),
                    ),
                ],
                onChanged: (v) {
                  if (v == null || v.isEmpty) return;
                  RenamePreset chosen = _preset;
                  for (final p in _presets) {
                    if (p.name == v) {
                      chosen = p;
                      break;
                    }
                  }
                  _edit(() {
                    _preset = chosen.copy();
                    _templateCtrl.text = _preset.template;
                  });
                  _syncContentCtrls();
                  RenamePresetStore.instance.saveActiveName(v);
                  if (_extractionActive) _rescan();
                },
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: '方案操作（新建 / 删除 / 复制 / 导入）',
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(minWidth: 180),
              onSelected: (action) {
                switch (action) {
                  case 'new':
                    _saveAsPreset();
                    break;
                  case 'delete':
                    _deletePreset();
                    break;
                  case 'copy':
                    _copyPresets();
                    break;
                  case 'import':
                    _pastePresets();
                    break;
                }
              },
              itemBuilder: (ctx) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                    value: 'new', child: Text('另存为方案（新建）')),
                PopupMenuItem<String>(
                    value: 'delete', child: Text('删除方案')),
                PopupMenuItem<String>(
                    value: 'copy', child: Text('复制方案 JSON')),
                PopupMenuItem<String>(
                    value: 'import', child: Text('从剪贴板导入')),
              ],
            ),
          ]),
        ),
        _formToggle('记住上次选的方案', _rememberPreset, (v) {
          _edit(() => _rememberPreset = v);
          RenamePresetStore.instance.saveRememberPreset(v);
          if (v) RenamePresetStore.instance.saveActiveName(_preset.name);
        }),

        _subHead('命名模板', help:
            '用「{变量}」把从文件内容里挖到的值拼成新文件名；输入框里可以直接改，改完预览立刻更新。\n'
            '• {变量}：大括号里写变量名，程序就把它的值填进来。如 {作者} 填从 txt 挖到的作者名。\n'
            '• {变量|默认值}：竖线后是「备胎」，挖到了用挖到的，挖不到就用默认值。如 {作者|佚名} 没挖到就显示「佚名」。\n'
            '• [可选片段]：方括号包起来的一段可有可无；里面若含空变量，整段连分隔符一起消失，不留难看尾巴。如 {原名}[ - {作者}] 没作者就只剩原名。\n'
            '• \\[ 和 \\{ ：想真在文件名里显示 [ 或 { 就加反斜杠。\n'
            '• 内置变量（不用读内容，程序直接知道，点下方标签插入）：\n'
            '   - {原名} 原文件名（不含扩展名）\n'
            '   - {扩展名} 原扩展名（不含点）\n'
            '   - {目录名} 文件所在文件夹名\n'
            '   - {序号} 按「序号设置」生成的编号（不写 {序号} 就不编号）\n'
            '   - {日期} 今天日期，点齿轮设格式\n'
            '   - {大小} 文件字节数（纯数字，无单位）\n'
            '   - {大小可读} 带单位的大小（如 12.3MB），点齿轮设单位/小数位\n'
            '   - {字数} 文件正文字符数（约数，如 2.4千字）\n'
            '• 下方快捷模板：点一下直接套用常用写法，套用后还能继续改。'),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
          child: TextField(
            controller: _templateCtrl,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '{原名} 作者：{作者}',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            ),
            style: const TextStyle(fontSize: 12),
            onChanged: (v) => _edit(() => _preset.template = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          child: Wrap(
            spacing: 8,
            runSpacing: 2,
            children: <Widget>[
              for (final t in const <String>[
                '{原名} 作者：{作者}',
                '《{原名}》作者：{作者}',
                '《{原名}》by{作者}',
                '{原名}[ - {作者}]',
                '《{原名}》[{作者}]',
              ])
                ChoiceChip(
                  label: Text(t, style: const TextStyle(fontSize: 11)),
                  selected: _preset.template == t,
                  onSelected: (_) => _edit(() {
                    _preset.template = t;
                    _templateCtrl.text = t;
                  }),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Text(
            _contentVariableNames.isEmpty
                ? '还没有内容变量；在下面的「变量」里添加后，点上面的 {变量} 标签插入模板。'
                : '内容变量（点一下插入模板）：',
            style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        if (_contentVariableNames.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
            child: Wrap(
              spacing: 6,
              runSpacing: 2,
              children: <Widget>[
                for (final n in _contentVariableNames)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    label: Text('{$n}', style: const TextStyle(fontSize: 11)),
                    onPressed: () => _insertTemplateVar(n),
                  ),
              ],
            ),
          ),

        ..._buildExtractBlocks(),
      ];

  /// ② 查找替换。
  Widget _sectionFindReplace() {
    return _ExpandableSection(
      title: '查找替换（不改扩展名）',
      helpTitle: '查找替换（不改扩展名）',
      carded: true,
      enabled: _cfg.findText.trim().isNotEmpty,
      helpText: '• 把文件名里的一部分文字换成另一段文字；扩展名（.txt、.jpg 等）保持原样。\n'
          '• 「查找」填要被替换掉的文字，「替换为」填新文字，命中的部分会全部替换。\n'
          '• 「替换为」留空并执行，就等于删掉查找到的内容。\n'
          '• 勾选「使用正则」后，「查找」按正则表达式匹配，'
          '「替换为」里可用 \$1 \$2 引用第 1、2 个捕获组。\n'
          '• 例：查找 (\\d+) 替换为 第\$1张，IMG2026.jpg → 第2026张.jpg。',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            children: [
              _formRow('查找',
                TextField(
                  controller: _findCtrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                  ),
                  style: const TextStyle(fontSize: 12),
                  onChanged: (v) => _edit(() => _cfg.findText = v),
                ),
                help: '要被换掉的文字；扩展名不受影响',
              ),
              const SizedBox(height: 8),
              _formRow('替换为',
                TextField(
                  controller: _replaceCtrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '正则可用 \$1',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                  ),
                  style: const TextStyle(fontSize: 12),
                  onChanged: (v) => _edit(() => _cfg.replaceText = v),
                ),
                help: '留空 = 删掉查找到的内容',
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('使用正则（替换值可用 \$1 \$2）',
                    style: TextStyle(fontSize: 12)),
                value: _cfg.useRegex,
                onChanged: (v) => _edit(() => _cfg.useRegex = v ?? false),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// ② 删除指定位置的字符。
  Widget _sectionDelete() {
    return _ExpandableSection(
      title: '删除指定位置的字符',
      helpTitle: '删除指定位置的字符',
      carded: true,
      enabled: _cfg.deleteEnabled,
      helpText: '• 展开并勾选后，把文件名里指定位置的一段字删掉；扩展名不受影响。\n'
          '• 「从第几位」从 1 开始数，第 1 位就是文件名的第一个字。\n'
          '• 「删几位」填 0 或不填等于不删。\n'
          '• 例：文件名 报告-终稿，从第 1 位删 2 位 → -终稿。',
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('删除指定位置的字符', style: TextStyle(fontSize: 13)),
          value: _cfg.deleteEnabled,
          onChanged: (v) => _edit(() => _cfg.deleteEnabled = v ?? false),
        ),
        if (_cfg.deleteEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _numRow('从第几位', _deleteStartCtrl,
                    (v) => _edit(() => _cfg.deleteStart = v),
                    helper: '从 1 开始数，1 = 名字第一个字'),
                const SizedBox(height: 6),
                _numRow('删几位', _deleteLenCtrl,
                    (v) => _edit(() => _cfg.deleteLength = v),
                    helper: '删多长；0 = 不删'),
              ],
            ),
          ),
      ],
    );
  }

  /// 「插到」：下拉选名称前 / 名称后 / 第 N 位前，选第 N 位前时多一个数字框。
  List<Widget> _insertPositionRow({
    required String value,
    required ValueChanged<String?> onChanged,
    required TextEditingController posCtrl,
    required ValueChanged<int> onPos,
  }) =>
      <Widget>[
        _dropRow(
          '插到',
          value,
          const ['prefix', 'suffix', 'insert'],
          const ['名称前面', '名称后面', '第 N 位前'],
          onChanged,
          help: '把这段内容插到名字的最前面 / 最后面 / 第 N 位前；扩展名不算位',
        ),
        if (value == 'insert') ...<Widget>[
          const SizedBox(height: 6),
          _numRow('第几位前', posCtrl, onPos,
              helper: '1 = 插在名字第一个字前；扩展名不算位'),
        ],
      ];

  /// 「插入内容」里的一张二级来源卡。
  /// alwaysOn = 固定文字 / 前后缀（填内容即启用，无添加移除按钮）；
  /// 其余来源靠「＋ 添加 / 移除」切换启用，未启用时卡内只显示添加按钮。
  Widget _srcCard({
    GlobalKey<_ExpandableSectionState>? cardKey,
    required String title,
    required bool enabled,
    required String helpText,
    required List<Widget> body,
    bool alwaysOn = false,
    String? addLabel,
    String? removeLabel,
    VoidCallback? onAdd,
    VoidCallback? onRemove,
  }) {
    return _ExpandableSection(
      key: cardKey,
      title: title,
      helpTitle: title,
      helpText: helpText,
      carded: true,
      nested: true,
      enabled: enabled,
      initiallyExpanded: false,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (alwaysOn || enabled) ...body,
              if (!alwaysOn)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: enabled
                        ? OutlinedButton.icon(
                            onPressed: onRemove,
                            icon: const Icon(Icons.delete_outline, size: 15),
                            label: Text(removeLabel ?? '移除',
                                style: const TextStyle(fontSize: 12)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.black,
                              side: const BorderSide(color: Colors.black),
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                            ),
                          )
                        : OutlinedButton.icon(
                            onPressed: onAdd,
                            icon: const Icon(Icons.add, size: 15),
                            label: Text(addLabel ?? '＋ 添加',
                                style: const TextStyle(fontSize: 12)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.black,
                              side: const BorderSide(color: Colors.black),
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                            ),
                          ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// ② 插入内容：五个来源各一张二级卡，可叠加。
  Widget _sectionInsert() {
    final cs = Theme.of(context).colorScheme;
    final hint = cs.onSurfaceVariant;
    final anyOn = _cfg.insertText.trim().isNotEmpty ||
        _cfg.dateEnabled ||
        _cfg.sequenceEnabled ||
        _cfg.insertContentVars ||
        _cfg.prefix.isNotEmpty ||
        _cfg.suffix.isNotEmpty;
    return _ExpandableSection(
      title: '插入内容',
      initiallyExpanded: false,
      helpTitle: '插入内容',
      helpText: _helpInsertText,
      carded: true,
      enabled: anyOn,
      children: <Widget>[
        // ① 固定文字：填内容即启用，无添加 / 移除。
        _srcCard(
          title: '固定文字',
          enabled: _cfg.insertText.trim().isNotEmpty,
          helpText: '往每个文件名里插一段你写的固定文字，比如「已归档_」。\n'
              '• 「插到」：名称前面 / 名称后面 / 第 N 位前（选第 N 位前会多出一个数字框）。\n'
              '• 「插入内容」：填文字，留空 = 这项不生效。',
          alwaysOn: true,
          body: <Widget>[
            ..._insertPositionRow(
              value: _cfg.insertTextPosition,
              onChanged: (v) =>
                  _edit(() => _cfg.insertTextPosition = v ?? 'suffix'),
              posCtrl: _insertPosCtrl,
              onPos: (v) => _edit(() => _cfg.insertPos = v),
            ),
            const SizedBox(height: 6),
            _formRow('插入内容',
                TextField(
                  controller: _insertTextCtrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                  ),
                  style: const TextStyle(fontSize: 12),
                  onChanged: (v) => _edit(() => _cfg.insertText = v),
                ),
                help: '留空 = 这项不生效'),
          ],
        ),

        // ② 日期
        _srcCard(
          cardKey: _dateCardKey,
          title: '日期',
          enabled: _cfg.dateEnabled,
          helpText: '把今天日期按格式插进名字。点「＋ 添加日期」启用。\n'
              '• 「插到」：名称前面 / 名称后面 / 第 N 位前。\n'
              '• 格式可直接选，也能自己写：yyyy 年 / MM 月 / dd 日 / HH 时 / mm 分 / ss 秒。',
          addLabel: '＋ 添加日期',
          removeLabel: '移除日期',
          onAdd: () {
            _edit(() => _cfg.dateEnabled = true);
            _dateCardKey.currentState?.expand();
          },
          onRemove: () => _edit(() => _cfg.dateEnabled = false),
          body: <Widget>[
            ..._insertPositionRow(
              value: _cfg.datePosition,
              onChanged: (v) =>
                  _edit(() => _cfg.datePosition = v ?? 'suffix'),
              posCtrl: _datePosCtrl,
              onPos: (v) => _edit(() => _cfg.dateInsertPos = v),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: <Widget>[
                  for (final f in const [
                    'yyyyMMdd',
                    'yyyy-MM-dd',
                    'yyyy年MM月dd日',
                    '_yyyyMMdd',
                    'yyyyMMdd_HHmmss',
                  ])
                    ChoiceChip(
                      label: Text(f,
                          style: TextStyle(
                              fontSize: 12,
                              color: _cfg.dateFormat == f
                                  ? _headerAccent(cs)
                                  : Colors.black)),
                      selected: _cfg.dateFormat == f,
                      selectedColor: cs.primaryContainer,
                      backgroundColor: cs.surfaceContainerHighest,
                      side: BorderSide.none,
                      showCheckmark: false,
                      onSelected: (_) => _edit(() {
                        _cfg.dateFormat = f;
                        _dateFmtCtrl.text = f;
                      }),
                    ),
                ],
              ),
            ),
            _formRow('日期格式',
              TextField(
                controller: _dateFmtCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'yyyyMMdd',
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                ),
                style: const TextStyle(fontSize: 12),
                onChanged: (v) => _edit(() => _cfg.dateFormat = v),
              ),
              help: 'yyyy 年 / MM 月 / dd 日 / HH 时 / mm 分 / ss 秒，'
                  '其它字符原样保留',
            ),
          ],
        ),

        // ③ 序号
        _srcCard(
          cardKey: _seqCardKey,
          title: '序号',
          enabled: _cfg.sequenceEnabled,
          helpText: '给每个文件按顺序编号。点「＋ 添加序号」启用。\n'
              '• 「位置」：编号放名字前面还是后面。\n'
              '• 起始 / 步长 / 位数：第一个号、每次加几、编号占几位（不足补 0）。\n'
              '• 分隔符：编号和原名之间的连接符，可留空。\n'
              '• 这里是「插入内容」自己的序号，起始 / 步长 / 位数与「命名格式」里的 {序号} 各自独立、互不影响（那边点 {序号} 旁的齿轮设）。',
          addLabel: '＋ 添加序号',
          removeLabel: '移除序号',
          onAdd: () {
            _edit(() => _cfg.sequenceEnabled = true);
            _seqCardKey.currentState?.expand();
          },
          onRemove: () => _edit(() => _cfg.sequenceEnabled = false),
          body: <Widget>[
            _dropRow('位置', _cfg.sequenceAtPrefix ? 'prefix' : 'suffix',
                const ['suffix', 'prefix'],
                const ['名称后面', '名称前面'],
                (v) => _edit(() => _cfg.sequenceAtPrefix = v == 'prefix'),
                help: '编号放名字前还是后'),
            const SizedBox(height: 8),
            _formRow('起始 / 步长 / 位数',
              Row(
                children: <Widget>[
                  Expanded(
                    child: _numField(_insertSeqStartCtrl,
                        (v) => _edit(() => _cfg.insertSeqStart = v)),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _numField(_insertSeqStepCtrl,
                        (v) => _edit(() => _cfg.insertSeqStep = v)),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _numField(_insertSeqWidthCtrl,
                        (v) => _edit(() => _cfg.insertSeqWidth = v)),
                  ),
                ],
              ),
              help: '起始=第一个文件用几号；步长=每下一个加几；位数=编号占几位不足补 0。这三个只管本卡，与命名格式 {序号} 无关',
            ),
            const SizedBox(height: 8),
            _formRow('分隔符',
              TextField(
                controller: _seqSepCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                ),
                style: const TextStyle(fontSize: 12),
                onChanged: (v) =>
                    _edit(() => _cfg.sequenceSeparator = v),
              ),
              help: '编号与原名之间的连接符，如 _ → 三体_01；可留空',
            ),
          ],
        ),

        // ④ 前缀 / 后缀：填内容即启用，固定在两端，无「插到」。
        _srcCard(
          title: '前缀 / 后缀',
          enabled: _cfg.prefix.isNotEmpty || _cfg.suffix.isNotEmpty,
          helpText: '前缀加在名字最前面，后缀加在扩展名之前。固定在两端，没有「插到」。\n'
              '• 前缀：如「已整理_」。\n'
              '• 后缀：如「_终稿」→ 三体_终稿.txt。',
          alwaysOn: true,
          body: <Widget>[
            _formRow('前缀',
              TextField(
                controller: _prefixCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                ),
                style: const TextStyle(fontSize: 12),
                onChanged: (v) => _edit(() => _cfg.prefix = v),
              ),
              help: '加在名字最前面',
            ),
            const SizedBox(height: 6),
            _formRow('后缀（扩展名前）',
              TextField(
                controller: _suffixCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                ),
                style: const TextStyle(fontSize: 12),
                onChanged: (v) => _edit(() => _cfg.suffix = v),
              ),
              help: '如 _终稿 → 三体_终稿.txt',
            ),
          ],
        ),

        // ⑤ 从文件内容取值
        _srcCard(
          cardKey: _contentCardKey,
          title: '从文件内容取值',
          enabled: _cfg.insertContentVars,
          helpText: '按命名模板把从文件里挖到的变量拼进名字。点「＋ 添加内容提取」启用。\n'
              '• 「插到」：挖到的值插到名称前 / 后 / 第 N 位前。\n'
              '• 下方白卡里是整套设置：方案 / 插入模板 / 内容变量 / 变量规则 / 扫描范围 / 清洗，改完立即生效；启用后会读文件扫描。',
          addLabel: '＋ 添加内容提取',
          removeLabel: '移除内容提取',
          onAdd: () {
            final was = _extractionActive;
            _edit(() => _cfg.insertContentVars = true);
            _contentCardKey.currentState?.expand();
            if (_extractionActive && !was) _rescan();
          },
          onRemove: () => _edit(() => _cfg.insertContentVars = false),
          body: <Widget>[
            ..._insertPositionRow(
              value: _cfg.contentInsertPosition,
              onChanged: (v) =>
                  _edit(() => _cfg.contentInsertPosition = v ?? 'suffix'),
              posCtrl: _contentInsertPosCtrl,
              onPos: (v) => _edit(() => _cfg.contentInsertPos = v),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: Text(
                _contentVariableNames.isEmpty
                    ? '还没有内容变量；在下方「变量」里添加后，挖到的值会按顺序用 _ 连接插进名字。'
                    : '插的是下方那些变量挖到的值（多个用 _ 连接）；整套设置就在下方白卡里，共用同一份。',
                style: TextStyle(fontSize: 11, color: hint),
              ),
            ),
            const SizedBox(height: 8),
            // 与品红原型一致：方案 / 插入模板 / 变量 / 扫描范围 / 清洗
            // 整套装进一张内嵌白卡，收在这张来源卡内部，不再平铺到弹窗上方。
            _card(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _buildTemplateBlocks(),
            )),
          ],
        ),
      ],
    );
  }

  /// ② 大小写。
  Widget _sectionCase() {
    final cs = Theme.of(context).colorScheme;
    return _ExpandableSection(
      title: '统一大小写',
      helpTitle: '大小写',
      carded: true,
      enabled: _cfg.caseMode != 'none',
      helpText: '• 只统一文件名里的英文大小写，扩展名不受影响。\n'
          '• 全小写：REPORT.TXT → report.TXT\n'
          '• 全大写：report.txt → REPORT.txt\n'
          '• 首字母大写：首字母变大写，其余字母变小写。\n'
          '• 例：REPORT-2026.TXT → Report-2026.TXT\n'
          '• 中文名不受影响。',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final m in const [
                ('none', '不变'),
                ('lower', '全小写'),
                ('upper', '全大写'),
                ('capitalize', '首字母大写'),
              ])
                ChoiceChip(
                  label: Text(m.$2,
                      style: TextStyle(
                          fontSize: 12,
                          color: _cfg.caseMode == m.$1
                              ? _headerAccent(cs)
                              : Colors.black)),
                  selected: _cfg.caseMode == m.$1,
                  selectedColor: cs.primaryContainer,
                  backgroundColor: cs.surfaceContainerHighest,
                  side: BorderSide.none,
                  showCheckmark: false,
                  onSelected: (_) => _edit(() => _cfg.caseMode = m.$1),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// ③ 扩展名：独立一步，带改错警告。
  Widget _sectionExt() {
    final anyDir = _items.any((e) => e.isDir);
    return _ExpandableSection(
      title: _cfg.renameMode == 'rules' ? '③ 扩展名' : '② 扩展名',
      helpTitle: '扩展名',
      carded: true,
      enabled: _cfg.changeExt,
      helpText: '• 勾选后，所有文件统一改成这里填的扩展名（只填后缀，不用写点）。\n'
          '• 原名没有扩展名的文件也会加上这个扩展名。\n'
          '• 文件夹不改扩展名。\n'
          '• 例：填 mp4，报告.docx → 报告.mp4。\n'
          '• 注意：扩展名是系统判断「用什么程序打开文件」的依据，改错会导致文件打不开。',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            children: [
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  anyDir ? '改扩展名（文件夹不生效）' : '改扩展名',
                  style: const TextStyle(fontSize: 12),
                ),
                value: _cfg.changeExt,
                onChanged: (v) => _edit(() => _cfg.changeExt = v ?? false),
              ),
              if (_cfg.changeExt)
                _formRow('新扩展名',
                  TextField(
                    controller: _extCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'txt',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                    ),
                    style: const TextStyle(fontSize: 12),
                    onChanged: (v) => _edit(
                        () => _cfg.newExt = v.trim().replaceAll('.', '')),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [
              Icon(Icons.info_outline,
                  size: 13, color: Colors.orange.shade800),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '扩展名改错会导致文件打不开（如把 .txt 改成 .mp3，系统就不知道用什么打开它了）。',
                  style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// ④ 输出设置：全局一份，三种命名方式共用。
  Widget _sectionOutput() {
    return _ExpandableSection(
      title: _cfg.renameMode == 'rules'
          ? '④ 输出设置（全局一份）'
          : '③ 输出设置（全局一份）',
      helpTitle: '输出设置',
      carded: true,
      helpText: '这一组对所有命名方式都生效，全局只有一份。\n'
          '• 重名时：两个文件想改成同名——标冲突不执行（标红、先不改），或自动加序号。\n'
          '• 后缀格式：自动加序号时的格式，必须含 {n}，如 _{n} → 三体_2.txt。\n'
          '• 非法字符：文件名里不能用的字符（\\ / : * ? " < > |）——直接删掉，或换成指定字符。\n'
          '• 空格换成下划线：名字里的空格改成 _。\n'
          '• 最终文件名最长(字)：新文件名（不含扩展名）最多多少个字（默认 120），超出截断。',
      children: [
        _dropRow('重名时', _preset.conflictPolicy,
            const <String>['skip', 'sequence'],
            const <String>['标冲突不执行', '自动加序号'],
            (v) => _edit(() => _preset.conflictPolicy = v ?? 'skip'),
            help: '两个文件要改成同一个名字时怎么办：\n'
                '• 标冲突不执行：预览里标红，这几行不改名，执行后保留原文件。\n'
                '• 自动加序号：自动在名字后面加后缀区分，如 三体_2.txt；'
                '后缀格式在下面「后缀格式」里配（默认 _{n}）。'),
        if (_preset.conflictPolicy == 'sequence')
          _textRow(
              '后缀格式',
              'conflictSuffix',
              _preset.conflictSuffixFormat,
              (v) => _edit(() => _preset.conflictSuffixFormat = v),
              tip: '必含 {n}',
              help: '重名时按这个格式给文件名加后缀，后缀插在扩展名前面。\n'
                  '• {n} 代表序号，从 2 开始（不冲突的第一个保留原名）。\n'
                  '• 例：_{n} → 三体_2.txt；_副本{n} → 三体_副本2.txt；({n}) → 三体(2).txt。\n'
                  '• 必须写 {n}，否则每个冲突文件会得到同一个名字、还是重名；'
                  '不合规时自动回退成 _{n}。\n'
                  '• 不能带 \\ / : * ? " < > |，这些字符会被自动去掉。'),
        _dropRow('非法字符', _preset.illegalCharMode,
            const <String>['delete', 'replace'],
            const <String>['直接删掉', '换成指定字符'],
            (v) => _edit(() => _preset.illegalCharMode = v ?? 'delete'),
            help: '文件名里不能用的字符：\\ / : * ? " < > |。'
                '直接删掉 = 遇到就删；换成指定字符 = 统一替换成下面填的那个字符（常用 - 或 _）。'),
        if (_preset.illegalCharMode == 'replace')
          _textRow('替换成', 'illegalRep', _preset.illegalReplacement,
              (v) => _edit(() => _preset.illegalReplacement = v)),
        _formToggle('空格换成下划线', _preset.spaceToUnderscore,
            (v) => _edit(() => _preset.spaceToUnderscore = v)),
        _textRow('最终文件名最长(字)', 'nameMax', '${_preset.maxNameLength}',
            (v) {
          final n = int.tryParse(v);
          if (n != null && n >= 0) {
            _edit(() => _preset.maxNameLength = n);
          }
        },
            tip: '最终文件名（不含扩展名）最长多少字，超出截断（默认 120，最大 240）。',
            number: true),
      ],
    );
  }

  /// 预览表头用的主题色：默认蓝走 textAccentOf 给深蓝；
  /// 浅主色（黄/琥珀主题）白底文字对比不足，自动混黑加深一档；
  /// 其余深/中色调主题直接用各自 primary。
  Color _headerAccent(ColorScheme cs) {
    final p = cs.primary;
    if (p.computeLuminance() > 0.5) {
      return Color.lerp(p, Colors.black, 0.4) ?? p;
    }
    return AppColors.textAccentOf(cs);
  }

  /// 预览行「⋯」菜单的统一动作分发：小预览和完整预览共用一套，
  /// 保证两边文案、行为完全一致。返回 true 表示预览内容变了。
  Future<bool> _performPreviewAction(
      String action, _RenamePreviewEntry e) async {
    switch (action) {
      case 'rename':
        return _editTargetName(e.oldPath, e.newName, e.oldName);
      case 'variables':
        return _editManual(e.oldPath, _contentVariableNames);
      case 'keep':
        // 保持原名 = 把目标名锁成原名；预览会显示「（不变）」，
        // 提交时按现有的 newName != oldName 判断自动跳过，不用新状态。
        _edit(() => _manualNames[e.oldPath] = e.oldName);
        _snack('这一行已保持原名，不参与本次改名');
        return true;
      case 'reset':
        _resetTargetName(e.oldPath);
        return true;
      case 'copyOld':
        Clipboard.setData(ClipboardData(text: e.oldName));
        _snack('已复制原名');
        return false;
      case 'copyNew':
        Clipboard.setData(ClipboardData(text: e.newName));
        _snack('已复制新名字');
        return false;
    }
    return false;
  }

  /// 打开「完整预览」大弹窗。传入当前最新预览和统一动作回调。
  void _openPreviewPopup() {
    final preview = _preview;
    final cs = Theme.of(context).colorScheme;
    final showOrder =
        _cfg.renameMode == 'fullName' || _cfg.sequenceEnabled;
    showDialog(
      context: context,
      builder: (_) {
        // 同主弹窗：仅本弹窗子树把 onSurface 压成纯黑，使继承文字也统一纯黑。
        final t = Theme.of(_);
        return Theme(
          data: t.copyWith(
            colorScheme: t.colorScheme.copyWith(onSurface: Colors.black),
            textTheme: t.textTheme.apply(
                bodyColor: Colors.black, displayColor: Colors.black),
            dialogTheme: t.dialogTheme.copyWith(
              contentTextStyle:
                  const TextStyle(color: Colors.black, fontSize: 14),
              titleTextStyle: const TextStyle(
                  color: Colors.black, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(foregroundColor: Colors.black),
            ),
          ),
          child: _RenamePreviewPopup(
            entries: preview,
            colorScheme: cs,
            showOrder: showOrder,
            canEdit: _canEditVariables,
            manualPaths: _manualNames.keys.toSet(),
            onAction: _onPreviewPopupAction,
          ),
        );
      },
    );
  }

  /// 弹窗拿到的是打开时的快照，动作改了状态就关掉重开刷新。
  Future<void> _onPreviewPopupAction(
      String action, _RenamePreviewEntry e) async {
    final changed = await _performPreviewAction(action, e);
    if (changed && mounted) _reopenPreviewPopup();
  }

  /// 弹窗拿到的是打开时的快照，改完必须关掉重开才能看到最新预览。
  void _reopenPreviewPopup() {
    Navigator.of(context).pop();
    _openPreviewPopup();
  }

  // ---------- 预览区 ----------

  Widget _sectionPreview(
    List<_RenamePreviewEntry> preview,
    int conflictCount,
    ColorScheme cs,
  ) {
    final changed = preview
        .where((e) => e.newName != e.oldName && e.conflict == null)
        .length;
    // 冲突行单独用红字计数，这里只数「待确认 / 规则没命中」的未改名行。
    final skippedCount = preview
        .where((e) => e.conflict == null &&
            (e.pending || e.newName == e.oldName))
        .length;
    // 启用内容取名后，全部「待确认」时 changed 为 0；
    // 这时也必须把列表画出来，否则用户根本点不到「点此手填」。
    final hasPending = preview.any((e) => e.pending);
    // 只有「全名+序号」或「添加序号」开启时，先后顺序才影响结果，
    // 这时才显示序号和 ↑↓ 微调，避免误导。
    final showOrder = _cfg.renameMode == 'fullName' || _cfg.sequenceEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Row(
            children: [
              Text('预览',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _headerAccent(cs))),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '在大窗口查看完整预览',
                icon: const Icon(Icons.open_in_new, size: 18),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 30, height: 30),
                visualDensity: VisualDensity.compact,
                onPressed: _openPreviewPopup,
              ),
              const Spacer(),
              if (changed > 0)
                Text('$changed 项将改名',
                    style: TextStyle(
                        fontSize: 12, color: _headerAccent(cs))),
              if (skippedCount > 0) ...<Widget>[
                const SizedBox(width: 8),
                Text('$skippedCount 项跳过',
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurfaceVariant)),
              ],
              if (conflictCount > 0) ...<Widget>[
                const SizedBox(width: 6),
                Text('$conflictCount 处冲突',
                    style: TextStyle(fontSize: 11, color: cs.error)),
              ],
            ],
          ),
        ),
        // 序号顺序：默认按文件浏览器里的显示顺序。
        // 只有顺序会影响结果时才显示（全名+序号 / 规则里开了序号）。
        if (showOrder)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Row(
              children: [
                Text('序号顺序',
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurfaceVariant)),
                const SizedBox(width: 6),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _cfg.orderMode,
                    isDense: true,
                    borderRadius: BorderRadius.circular(8),
                    // ▼ 与文字之间留一点点间距，不贴死。
                    icon: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: const Icon(Icons.arrow_drop_down),
                    ),
                    style: TextStyle(fontSize: 12, color: Colors.black),
                      items: [
                        for (final o in _kRenameOrderOptions)
                          DropdownMenuItem<String>(
                            value: o.$1,
                            child: Text(o.$2,
                                style: const TextStyle(fontSize: 12)),
                          ),
                      ],
                      onChanged: _setOrderMode,
                    ),
                ),
                // Spacer 把帮助按钮顶到最右边、并固定位置（下拉框宽度变化时它不左右挪）。
                const Spacer(),
                // 帮助图标：点一下弹出排序说明（不再长按才出提示）。
                // 图标用 help_outline，与上方「从文件里提取内容」区一致。
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 28),
                  icon: Icon(Icons.help_outline,
                      size: 16, color: cs.onSurfaceVariant),
                  onPressed: () => _snack(
                        '先在这里选排序方式，再点预览里的 ↑↓ 微调（会自动切到手动顺序）',
                        duration: const Duration(seconds: 4)),
                ),
              ],
            ),
          ),
        Expanded(
          // 启用内容取名时即使一个都不改，也要把列表画出来，
          // 否则「保持原名（静默跳过）」这种兜底会让用户看不到抓到了什么。
          child: (changed == 0 && !hasPending && !_extractionActive)
              ? Center(
                  child: Text(
                    _cfg.renameMode == 'fullName' &&
                            _cfg.fullNameBase.trim().isEmpty
                        ? '请输入新名字'
                        : '当前规则不会改变任何文件名',
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  itemCount: preview.length,
                  itemBuilder: (_, i) {
                    final e = preview[i];
                    final unchanged = e.newName == e.oldName;
                    final hasConflict = e.conflict != null;
                    final isPending = e.pending;
                    final isManual = _manualNames.containsKey(e.oldPath);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (showOrder) ...[
                            SizedBox(
                              width: 18,
                              child: Text(
                                '${i + 1}',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.oldName,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  unchanged ? '（不变）' : e.newName,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: hasConflict
                                        ? cs.error
                                        : (unchanged
                                            ? cs.onSurfaceVariant
                                            : Colors.black),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (hasConflict)
                                  Text(
                                    e.conflict!,
                                    style: TextStyle(
                                        fontSize: 11, color: cs.error),
                                  ),
                                if (e.note != null)
                                  Text(
                                    e.note!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: cs.onSurfaceVariant),
                                  ),
                                if (isPending && !isManual)
                                  Text(
                                    '待确认 · 点右侧 ⋯ 手填',
                                    style: TextStyle(
                                        fontSize: 11, color: cs.tertiary),
                                  ),
                              ],
                            ),
                          ),
                          if (showOrder && preview.length > 1) ...[
                            _previewMoveButton(
                              e.oldPath,
                              -1,
                              enabled: i > 0,
                            ),
                            _previewMoveButton(
                              e.oldPath,
                              1,
                              enabled: i < preview.length - 1,
                            ),
                          ],
                          PopupMenuButton<String>(
                            tooltip: '这一行的操作',
                            icon: Icon(Icons.more_vert,
                                size: 20, color: cs.onSurfaceVariant),
                            padding: const EdgeInsets.all(6),
                            constraints: const BoxConstraints(minWidth: 180),
                            onSelected: (action) =>
                                _performPreviewAction(action, e),
                            itemBuilder: (_) => _previewRowMenuItems(
                              canEditVariables: _canEditVariables,
                              isManual: isManual,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _previewMoveButton(
    String oldPath,
    int delta, {
    required bool enabled,
  }) {
    return SizedBox(
      width: 26,
      height: 26,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints:
            const BoxConstraints.tightFor(width: 26, height: 26),
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        tooltip: delta < 0 ? '上移' : '下移',
        icon: Icon(
          delta < 0 ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
        ),
        onPressed: enabled ? () => _moveOrderedItem(oldPath, delta) : null,
      ),
    );
  }

  // ---------- 小工具 ----------

  /// 纯数值输入框（无标签），供 _numRow / 序号组合行复用。
  Widget _numField(TextEditingController ctrl, ValueChanged<int> onChanged) =>
      TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        ),
        style: const TextStyle(fontSize: 12),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null) onChanged(n);
        },
      );

  /// 左侧文字标签 + 数值输入框（与 _formRow 一致的 B 区画法）。
  Widget _numRow(String label, TextEditingController ctrl, ValueChanged<int> onChanged,
          {String? helper}) =>
      _formRow(label, _numField(ctrl, onChanged), help: helper);
}

// ==================== 预览：大窗口查看全部条目 ====================

/// 在独立弹窗里查看完整预览列表，方便几千个文件时逐个核对。
/// 每行右侧一个「⋯」菜单：改动通过回调交给主弹窗的覆盖表保存，
/// 确认后主弹窗会用最新预览重新打开本弹窗（本弹窗自身不持有状态）。

/// 预览行「⋯」菜单项：小预览和完整预览共用，保证文案与行为一致。
/// 变量项只在开了「从文件里提取内容」时出现，还原项只在手改过时出现。
List<PopupMenuEntry<String>> _previewRowMenuItems({
  required bool canEditVariables,
  required bool isManual,
}) {
  PopupMenuItem<String> item(String value, String label) =>
      PopupMenuItem<String>(
        value: value,
        height: 38,
        child: Text(label, style: const TextStyle(fontSize: 13)),
      );
  return <PopupMenuEntry<String>>[
    item('rename', '手动改这一行的文件名'),
    if (canEditVariables)
      item('variables', '改抓出来的内容（作者 / 书名 / 主角）'),
    const PopupMenuDivider(),
    item('keep', '保持原名，不参与本次改名'),
    item('copyOld', '复制原名'),
    item('copyNew', '复制新名字'),
    if (isManual) ...<PopupMenuEntry<String>>[
      const PopupMenuDivider(),
      item('reset', '还原成规则算出来的名字'),
    ],
  ];
}

class _RenamePreviewPopup extends StatefulWidget {
  const _RenamePreviewPopup({
    required this.entries,
    required this.colorScheme,
    required this.onAction,
    this.showOrder = false,
    this.canEdit = false,
    this.manualPaths = const <String>{},
  });

  final List<_RenamePreviewEntry> entries;
  final ColorScheme colorScheme;
  final bool showOrder;
  /// 「⋯」菜单选中某一项：统一交给主弹窗分发（覆盖表在主 State）。
  final void Function(String action, _RenamePreviewEntry entry) onAction;
  /// 是否有可编辑的内容变量（内容提取开启且有变量时才有意义）。
  final bool canEdit;
  /// 已被手动改名的路径，用来显示标记和还原菜单项。
  final Set<String> manualPaths;

  @override
  State<_RenamePreviewPopup> createState() => _RenamePreviewPopupState();
}

class _RenamePreviewPopupState extends State<_RenamePreviewPopup> {
  final TextEditingController _queryCtrl = TextEditingController();
  String _filter = 'all';

  List<_RenamePreviewEntry> get _filtered {
    final q = _queryCtrl.text.trim().toLowerCase();
    final out = <_RenamePreviewEntry>[];
    for (final e in widget.entries) {
      final changed = e.newName != e.oldName;
      if (_filter == 'changed' && !changed) continue;
      if (_filter == 'conflict' && e.conflict == null) continue;
      if (_filter == 'pending' && !e.pending) continue;
      if (q.isNotEmpty &&
          !e.oldName.toLowerCase().contains(q) &&
          !e.newName.toLowerCase().contains(q)) continue;
      out.add(e);
    }
    return out;
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Widget _row(_RenamePreviewEntry e, int i, ColorScheme cs) {
    final unchanged = e.newName == e.oldName;
    final hasConflict = e.conflict != null;
    final isPending = e.pending;
    final isManual = widget.manualPaths.contains(e.oldPath);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showOrder) ...[
            SizedBox(
              width: 22,
              child: Text('${i + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.oldName,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Row(
                  children: [
                    const Icon(Icons.arrow_right, size: 13),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        unchanged ? '（不变）' : e.newName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: hasConflict
                              ? cs.error
                              : (unchanged
                                  ? cs.onSurfaceVariant
                                  : Colors.black),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (hasConflict)
                  Padding(
                    padding: const EdgeInsets.only(left: 21),
                    child: Text(e.conflict!,
                        style: TextStyle(fontSize: 11, color: cs.error)),
                  ),
                if (e.note != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 21),
                    child: Text(e.note!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
                  ),
                if (isManual)
                  Padding(
                    padding: const EdgeInsets.only(left: 21),
                    child: Text('已手动改名 · 点右侧 ⋯ 还原',
                        style: TextStyle(fontSize: 11, color: cs.tertiary)),
                  ),
                if (isPending && !isManual)
                  Padding(
                    padding: const EdgeInsets.only(left: 21),
                    child: Text('待确认 · 点右侧 ⋯ 手填',
                        style: TextStyle(fontSize: 11, color: cs.tertiary)),
                  ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '这一行的操作',
            icon: Icon(Icons.more_vert, size: 20, color: cs.onSurfaceVariant),
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(minWidth: 180),
            onSelected: (action) => widget.onAction(action, e),
            itemBuilder: (_) => _previewRowMenuItems(
              canEditVariables: widget.canEdit,
              isManual: isManual,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.colorScheme;
    final total = widget.entries.length;
    final changed =
        widget.entries.where((e) => e.newName != e.oldName).length;
    final conflicts =
        widget.entries.where((e) => e.conflict != null).length;
    final pending = widget.entries.where((e) => e.pending).length;
    final shown = _filtered.length;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '完整预览（共 $total 项 · $changed 项将改名）',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _queryCtrl,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索文件名…',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        border: const OutlineInputBorder(),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _filterChip(cs, '全部', 'all', total),
                  _filterChip(cs, '将改名', 'changed', changed),
                  _filterChip(cs, '冲突', 'conflict', conflicts),
                  _filterChip(cs, '待确认', 'pending', pending),
                ],
              ),
            ),
            Expanded(
              child: shown == 0
                  ? Center(
                      child: Text('没有匹配项',
                          style: TextStyle(
                              fontSize: 13, color: cs.onSurfaceVariant)))
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: shown,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _row(_filtered[i], i, cs),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(
      ColorScheme cs, String label, String value, int count) {
    final active = _filter == value;
    return FilterChip(
      label: Text('$label $count', style: const TextStyle(fontSize: 11)),
      selected: active,
      onSelected: (_) => setState(() => _filter = value),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

// ==================== 内容取名：变量编辑 / 手填对话框 ====================

/// 新增或编辑一条变量规则。返回 null 表示取消。
class _FieldEditorDialog extends StatefulWidget {
  const _FieldEditorDialog({this.initial});

  final ContentField? initial;

  @override
  State<_FieldEditorDialog> createState() => _FieldEditorDialogState();
}

class _FieldEditorDialogState extends State<_FieldEditorDialog> {
  late final ContentField _f;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _patternCtrl;
  late final TextEditingController _endCtrl;
  late final TextEditingController _groupCtrl;
  late final TextEditingController _occCtrl;
  late final TextEditingController _joinCtrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _f = (widget.initial ?? ContentField()).copy();
    _nameCtrl = TextEditingController(text: _f.name);
    _patternCtrl = TextEditingController(text: _f.pattern);
    _endCtrl = TextEditingController(text: _f.endPattern);
    _groupCtrl = TextEditingController(text: '${_f.captureGroup}');
    _occCtrl = TextEditingController(text: '${_f.occurrence}');
    _joinCtrl = TextEditingController(text: _f.joiner);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _patternCtrl.dispose();
    _endCtrl.dispose();
    _groupCtrl.dispose();
    _occCtrl.dispose();
    _joinCtrl.dispose();
    super.dispose();
  }

  Widget _field(
    String label,
    TextEditingController ctrl, {
    String? hint,
    int maxLines = 1,
    bool number = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: ctrl,
        maxLines: maxLines,
        keyboardType: number ? TextInputType.number : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isBetween = _f.locator == FieldLocator.between;
    return AlertDialog(
      title: Text(widget.initial == null ? '添加变量' : '编辑变量',
          style: const TextStyle(fontSize: 15)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _field('变量名（不含花括号）', _nameCtrl, hint: '例如：作者 / 主角 / 系列'),
            DropdownButtonFormField<String>(
              value: locatorToString(_f.locator),
              isDense: true,
              decoration: const InputDecoration(
                labelText: '定位方式',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: <DropdownMenuItem<String>>[
                for (var i = 0; i < kLocatorValues.length; i++)
                  DropdownMenuItem<String>(
                    value: kLocatorValues[i],
                    child: Text(kLocatorLabels[i],
                        style: const TextStyle(fontSize: 12)),
                  ),
              ],
              onChanged: (v) => setState(
                  () => _f.locator = locatorFromString(v)),
            ),
            const SizedBox(height: 8),
            _field(
              _f.locator == FieldLocator.lineNumber
                  ? '行号（1 起）'
                  : (_f.locator == FieldLocator.keywordLine
                      ? '关键词'
                      : (_f.locator == FieldLocator.between
                          ? '起始标记'
                          : '正则表达式')),
              _patternCtrl,
              hint: _f.locator == FieldLocator.regex
                  ? r'作\s*者\s*[：:]\s*(.+)'
                  : null,
              maxLines: 2,
            ),
            if (isBetween)
              _field('结束标记', _endCtrl, hint: '留空 = 一直到文件末尾'),
            if (_f.locator == FieldLocator.regex)
              _field('取第几个捕获组（0 = 整段匹配）', _groupCtrl, number: true),
            _field('命中第几次（1 首个 / -1 末个 / 0 全部）', _occCtrl,
                number: true),
            _field('多个结果的连接符', _joinCtrl),
            Text(
              '说明：正则可以用行首行尾锚点；同名变量可添加多条规则，按顺序兜底。'
              '规则留空表示不启用，适合主角这类没有固定写法的字段。',
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) {
              setState(() => _error = '变量名不能为空');
              return;
            }
            if (name.contains('{') ||
                name.contains('}') ||
                name.contains('|') ||
                name.contains('[') ||
                name.contains(']')) {
              setState(() => _error = '变量名不能包含 { } | [ ]');
              return;
            }
            if (kBuiltinVariables.contains(name)) {
              setState(() => _error = '这个名字是内置变量，请换一个');
              return;
            }
            if (_patternCtrl.text.trim().isNotEmpty &&
                _f.locator == FieldLocator.regex) {
              try {
                RegExp(_patternCtrl.text.trim());
              } catch (e) {
                setState(() => _error = '正则写错了：$e');
                return;
              }
            }
            _f.name = name;
            _f.pattern = _patternCtrl.text;
            _f.endPattern = _endCtrl.text;
            _f.captureGroup = int.tryParse(_groupCtrl.text.trim()) ?? 1;
            _f.occurrence = int.tryParse(_occCtrl.text.trim()) ?? 1;
            _f.joiner = _joinCtrl.text;
            Navigator.pop(context, _f);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 预览里点「待确认」后手填变量值。返回 null 表示取消。
/// 手动改某一行的最终文件名。返回 null = 取消，'' = 清空还原，
/// 其它字符串 = 用户填的名字（清洗交给调用方按方案规则处理）。
class _ManualNameDialog extends StatefulWidget {
  const _ManualNameDialog({
    required this.initialValue,
    required this.oldName,
  });

  final String initialValue;
  final String oldName;

  @override
  State<_ManualNameDialog> createState() => _ManualNameDialogState();
}

class _ManualNameDialogState extends State<_ManualNameDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
    // 打开就全选，方便直接整名重打；只想微调时点一下即可取消选中。
    _ctrl.selection = TextSelection(
        baseOffset: 0, extentOffset: widget.initialValue.length);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dot = widget.oldName.lastIndexOf('.');
    final ext = dot > 0 && dot < widget.oldName.length - 1
        ? widget.oldName.substring(dot)
        : '';
    return AlertDialog(
      title: const Text('手动改这一行的文件名',
          style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('原名：${widget.oldName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            const SizedBox(height: 10),
            TextField(
              controller: _ctrl,
              autofocus: true,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                isDense: true,
                labelText: '新文件名（含扩展名）',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              onSubmitted: (_) => Navigator.of(context).pop(_ctrl.text),
            ),
            const SizedBox(height: 8),
            Text(
              ext.isEmpty
                  ? '不写扩展名就按你填的用；留空 = 还原成规则算出来的名字。'
                  : '不写 $ext 会自动补上；写了别的扩展名就按你填的来。\n'
                      '留空 = 还原成规则算出来的名字。',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Text('改完仍会重新检查重名；冲突的名字会标红并跳过执行。',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _ManualValuesDialog extends StatefulWidget {
  const _ManualValuesDialog({
    required this.names,
    required this.initial,
    this.notice,
  });

  final List<String> names;
  final Map<String, String> initial;
  /// 非空时顶部显示「改了也不影响本行名字」的说明。
  final String? notice;

  @override
  State<_ManualValuesDialog> createState() => _ManualValuesDialogState();
}

class _ManualValuesDialogState extends State<_ManualValuesDialog> {
  late final Map<String, TextEditingController> _ctrls;

  @override
  void initState() {
    super.initState();
    _ctrls = <String, TextEditingController>{
      for (final n in widget.names)
        n: TextEditingController(text: widget.initial[n] ?? ''),
    };
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('改抓出来的内容', style: TextStyle(fontSize: 15)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.notice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.info_outline,
                        size: 15,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.notice!,
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.5,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            for (final n in widget.names)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: _ctrls[n],
                  decoration: InputDecoration(
                    labelText: n,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            Text(
                '只有命名模板里写到的变量才会影响文件名；留空的字段仍然当作没找到；只影响这一行。',
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            <String, String>{
              for (final e in _ctrls.entries) e.key: e.value.text,
            },
          ),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

// ==================== 批量重命名：可折叠分组（带帮助入口） ====================

/// 批量重命名弹窗里的分组：标题行右侧是「？ + 展开箭头」。
/// 点 ？ 弹出该分组的用法说明，箭头随展开状态旋转。
class _ExpandableSection extends StatefulWidget {
  const _ExpandableSection({
    super.key,
    required this.title,
    required this.children,
    required this.helpTitle,
    required this.helpText,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
    this.carded = false,
    this.enabled,
    this.nested = false,
  });

  final String title;
  final List<Widget> children;
  final String helpTitle;
  final String helpText;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;

  /// 卡片式外观：白底圆角 + 统一阴影 + 展开体浅灰底（批量重命名弹窗用）。
  /// 其它弹窗共用本组件时不传，保持原有扁平外观，互不影响。
  final bool carded;

  /// 非 null 时在标题右侧显示「未启用 / 已启用」徽章（true = 已启用）。
  /// 仅供展示；真正的启用判定仍由各分区自己的逻辑负责。
  final bool? enabled;

  /// 二级来源卡（嵌在「插入内容」卡内）：阴影更淡、标题略小、间距更紧。
  final bool nested;

  @override
  State<_ExpandableSection> createState() => _ExpandableSectionState();
}

class _ExpandableSectionState extends State<_ExpandableSection> {
  late bool _expanded = widget.initiallyExpanded;
  int _expandTick = 0;

  /// 供外部（如来源卡的「＋ 添加」）强制展开本卡。
  /// ExpansionTile 的展开状态只在它自己的 initState 读一次，所以换 key
  /// 让它重建，再用 initiallyExpanded: true 开局。
  void expand() {
    // 不做「已经展开就返回」的短路：整页 rebuild 后 ExpansionTile 有可能
    // 被重建回折叠态，而卡内的「＋ 添加」按钮点下去必须保证能看到配置。
    // 每次都换 key 让 ExpansionTile 以 initiallyExpanded: true 重新初始化，
    // 它 initState 直接把动画值设到 1.0，不会播展开动画、也不会闪。
    setState(() {
      _expanded = true;
      _expandTick++;
    });
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        // 帮助弹窗加大：占满左右留白宽度 + 最多 65% 屏高，长解释完整显示。
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
        title: Text(widget.helpTitle,
            style: const TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: SizedBox(
            width: double.maxFinite,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.6),
              child: Text(widget.helpText,
                  style: const TextStyle(fontSize: 13, height: 1.65)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tile = ExpansionTile(
      // key 只在 expand() 时变化，用于强制展开；平时保持不变以维持手动折叠状态。
      key: ValueKey<int>(_expandTick),
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      initiallyExpanded: _expandTick > 0 || widget.initiallyExpanded,
      onExpansionChanged: (v) {
        setState(() => _expanded = v);
        widget.onExpansionChanged?.call(v);
      },
      title: Text(widget.title,
          style: TextStyle(
              fontSize: widget.nested ? 12 : 13,
              fontWeight: widget.carded ? FontWeight.w600 : null,
              color: Colors.black)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 启用状态徽章：随各分区传入的 enabled 实时变化。
          // 文字用分区标题色，背景保持不动（primaryContainer / 灰）。
          if (widget.enabled != null)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: widget.enabled!
                    ? cs.primaryContainer
                    : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                widget.enabled! ? '已启用' : '未启用',
                style: TextStyle(
                    fontSize: 10,
                    color: widget.enabled!
                        ? _sectionAccentOf(cs)
                        : cs.onSurfaceVariant),
              ),
            ),
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints.tightFor(width: 28, height: 28),
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              tooltip: '使用说明',
              icon: Icon(Icons.help_outline, color: cs.onSurfaceVariant),
              onPressed: _showHelp,
            ),
          ),
          const SizedBox(width: 2),
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(Icons.expand_more, color: cs.onSurfaceVariant),
          ),
        ],
      ),
      children: <Widget>[
        // 卡片式：展开体铺一层浅灰底，和折叠头区分开（对齐原型 fold-body）。
        Container(
          width: double.infinity,
          color: widget.carded ? cs.surfaceContainerLowest : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: widget.children,
          ),
        ),
      ],
    );
    if (!widget.carded) return tile;
    // 卡片式：白底圆角 + 统一（已减小的）阴影；展开体铺一层浅灰底与原型一致。
    // nested 二级来源卡：阴影更淡、margin 更紧，避免层层叠影。
    return Container(
      margin: widget.nested
          ? const EdgeInsets.fromLTRB(8, 0, 8, 6)
          : const EdgeInsets.fromLTRB(8, 0, 8, 9),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
        boxShadow: widget.nested
            ? const <BoxShadow>[
                BoxShadow(
                    color: Color(0x0F000000),
                    blurRadius: 2,
                    offset: Offset(0, 1)),
              ]
            : _kCardShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Theme(
          data: Theme.of(context)
              .copyWith(dividerColor: Colors.transparent),
          child: tile,
        ),
      ),
    );
  }
}

class _SearchFolderPickerDialog extends StatefulWidget {
  const _SearchFolderPickerDialog({
    required this.rootPath,
    required this.initialPath,
    required this.initialSelected,
    this.titleText,
    this.showGuide = false,
  });

  final String rootPath;
  final String initialPath;
  final List<String> initialSelected;

  /// 顶部标题。不传就用勾选文件夹的默认文案。
  /// 查重范围选择器会传自己的，说明这次勾选是给谁用的。
  final String? titleText;

  /// 是否叠一层首次引导：高亮「勾选区」和「进入区」，其余变暗。
  final bool showGuide;

  @override
  State<_SearchFolderPickerDialog> createState() =>
      _SearchFolderPickerDialogState();
}

class _SearchFolderPickerDialogState extends State<_SearchFolderPickerDialog> {
  static const String _internalRoot = '/storage/emulated/0';

  // 7.4：区间高亮色改读主题 token（原为 static const 硬编码）
  Color get _rangeBlue => Theme.of(context).colorScheme.primary;
  Color get _rangeHighlight =>
      Theme.of(context).colorScheme.primary.withValues(alpha: 0.2);

  late String _path;
  late List<String> _selected;
  late final TextEditingController _jumpCtrl;
  List<Directory> _dirs = const [];
  bool _loading = true;

  bool _rangeMode = false;
  String? _rangeAnchorPath;

  // 首次引导要挖洞高亮的两个位置：第一行的勾选方框 / 进入箭头。
  final GlobalKey _guideCheckKey = GlobalKey();
  final GlobalKey _guideEnterKey = GlobalKey();
  final GlobalKey _guideRangeKey = GlobalKey();
  final GlobalKey _guideAllKey = GlobalKey();
  OverlayEntry? _guideEntry;

  bool get _isDupScope => (widget.titleText ?? '').contains('查重');

  /// 引导只弹一次：进子目录会重新 _load，不该每次都再弹一遍。
  bool _guideDone = false;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _selected = List<String>.from(widget.initialSelected);
    _jumpCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _guideEntry?.remove();
    _guideEntry = null;
    _jumpCtrl.dispose();
    super.dispose();
  }

  /// 组件的屏幕矩形。没挂上 / 已卸载时返回 null。
  Rect? _rectOf(GlobalKey key) {
    final obj = key.currentContext?.findRenderObject();
    if (obj is! RenderBox || !obj.attached) return null;
    return obj.localToGlobal(Offset.zero) & obj.size;
  }

  /// 打开操作引导（多页分页版）。
  ///
  /// 把需要讲清楚的几处功能各做成一页：勾选方框、进入箭头、区间选择、
  /// 全选，最后再讲「确定 / 记住范围」。右上角有「第 X / N · 还剩 M 页」
  /// 的计数，告诉用户后面还有几页。
  ///
  /// 入口有两处：① 首次进入时自动弹一次（看 [_guideDone]）；② 弹窗
  /// 右上角的常驻「?」按钮，随时可再打开复习。
  void _openGuide() {
    if (!mounted || _guideEntry != null) return;

    // 对话框此刻已构建完成，各目标位置在引导期间不会变（引导内不导航），
    // 所以直接量一次屏幕矩形、作为固定值传进去即可。量不到（如空目录没有
    // 第一行）的就以「无高亮」页呈现，只讲概念。
    final steps = <_GuideStep>[
      _GuideStep(
        rect: _rectOf(_guideCheckKey),
        title: '① 点方框 = 选中',
        body: _isDupScope
            ? '勾上就是要查重这个文件夹，可以多选。'
            : '勾上就是把它加进范围，可以多选。',
      ),
      _GuideStep(
        rect: _rectOf(_guideEnterKey),
        title: '② 点箭头 = 进入',
        body: '只是进去看它里面的子文件夹，不会勾选它。'
            '点错就跑到别的目录了，要回来点左上角「↑」。',
      ),
      _GuideStep(
        rect: _rectOf(_guideRangeKey),
        title: '③ 区间：一次选一串',
        body: '先点底部「区间」，再点两行内容当起点和终点，'
            '中间夹着的所有文件夹会一起被选中，省得一个一个点。',
      ),
      _GuideStep(
        rect: _rectOf(_guideAllKey),
        title: '④ 全选：本页全勾上',
        body: '一键勾选当前目录列出的全部文件夹；'
            '进入别的目录后要再点一次才生效。',
      ),
      _GuideStep(
        rect: null,
        title: '选完点「确定」',
        body: '会再问你要不要记住范围：\n'
            '记住——下次查重直接用这些目录，不用再选；'
            '不记住——只查这一次，下次重新选。',
      ),
    ];

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (c) => _PickerGuideLayer(
        steps: steps,
        onClose: () {
          entry.remove();
          if (_guideEntry == entry) _guideEntry = null;
        },
      ),
    );
    _guideEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final dirs = await listSubdirectoriesSafe(_path);
      if (!mounted) return;
      setState(() {
        _dirs = dirs;
        _loading = false;
      });
      // 引导要等列表真的画出来才能测到位置，所以放在加载完的下一帧。
      // 只自动弹这一次；之后用户可随时点弹窗右上角的「?」再看。
      if (widget.showGuide && !_guideDone) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_guideDone) {
            _guideDone = true;
            _openGuide();
          }
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _dirs = const [];
        _loading = false;
      });
    }
  }

  bool get _canGoUp => _path != widget.rootPath;

  void _goUp() {
    if (!_canGoUp) return;
    final parent = Directory(_path).parent.path;
    if (!parent.startsWith(widget.rootPath)) return;
    setState(() {
      _path = parent;
      _rangeAnchorPath = null;
    });
    _load();
  }

  String get _relPath {
    if (_path == widget.rootPath) return '~/';
    if (_path == _internalRoot || _path.startsWith('$_internalRoot/')) {
      final sub = _path.substring(_internalRoot.length);
      return sub.isEmpty ? '~' : '~$sub';
    }
    return _path;
  }

  void _jumpToPath(String path) {
  if (path.isEmpty) return;
  var target = _normalizePath(path.trim());
  if (FileSystemEntity.typeSync(target) == FileSystemEntityType.file) {
    target = File(target).parent.path;
  }
  if (!Directory(target).existsSync()) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('目录不存在')),
    );
    return;
  }
  if (!target.startsWith(widget.rootPath)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('只能跳到内部存储以内')),
    );
    return;
  }
  setState(() {
    _path = target;
    _rangeAnchorPath = null;
  });
  _load();
}

String _normalizePath(String path) {
  const prefixes = <String, String>{
    '/sdcard/': '/storage/emulated/0/',
    '/sdcard': '/storage/emulated/0',
    '/mnt/sdcard/': '/storage/emulated/0/',
    '/mnt/sdcard': '/storage/emulated/0',
    '/storage/self/primary/': '/storage/emulated/0/',
    '/storage/self/primary': '/storage/emulated/0',
    '/storage/emulated/legacy/': '/storage/emulated/0/',
    '/storage/emulated/legacy': '/storage/emulated/0',
  };
  for (final e in prefixes.entries) {
    if (path.startsWith(e.key)) {
      return e.value + path.substring(e.key.length);
    }
  }
  return path;
}

  void _toggle(String path) {
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
    });
  }

  bool get _allVisibleSelected {
    if (_dirs.isEmpty) return false;
    for (final d in _dirs) {
      if (!_selected.contains(d.path)) return false;
    }
    return true;
  }

  void _toggleSelectAll() {
    setState(() {
      if (_allVisibleSelected) {
        for (final d in _dirs) {
          _selected.remove(d.path);
        }
      } else {
        for (final d in _dirs) {
          if (!_selected.contains(d.path)) _selected.add(d.path);
        }
      }
    });
  }

  void _toggleRangeMode() {
    setState(() {
      _rangeMode = !_rangeMode;
      _rangeAnchorPath = null;
    });
  }

  void _handleRangeTap(String path) {
    final anchor = _rangeAnchorPath;
    if (anchor == null) {
      setState(() => _rangeAnchorPath = path);
      return;
    }

    final visible = _dirs.map((d) => d.path).toList();
    final from = visible.indexOf(anchor);
    final to = visible.indexOf(path);
    if (from < 0 || to < 0) {
      setState(() => _rangeAnchorPath = path);
      return;
    }
    final lo = from < to ? from : to;
    final hi = from < to ? to : from;

    setState(() {
      for (var i = lo; i <= hi; i++) {
        _selected.add(visible[i]);
      }
      _rangeMode = false;
      _rangeAnchorPath = null;
    });
  }

  Future<void> _showSelected() async {
    await showDialog<void>(
      context: context,
      builder: (outerContext) => StatefulBuilder(
        builder: (innerContext, setInnerState) => AlertDialog(
          insetPadding: _dlgInsetG,
          titlePadding: _dlgTitlePadG,
          contentPadding: _dlgContentPadG,
          actionsPadding: _dlgActionsPadG,
          title: const Text('已勾选文件夹'),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(innerContext).size.height * 0.85,
            child: _selected.isEmpty
                ? const Text('还没有勾选任何文件夹')
                : ListView.builder(
                    itemCount: _selected.length,
                    itemBuilder: (ctx, i) {
                      final p = _selected[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(p.split('/').last),
                        subtitle: Text(
                          p,
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: '移除',
                          onPressed: () {
                            setInnerState(() => _selected.removeAt(i));
                            setState(() {});
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(innerContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  String get _titleText {
    if (_rangeMode) {
      return _rangeAnchorPath == null ? '点一行内容为起点' : '再点一行内容为终点';
    }
    return widget.titleText ?? '点击左侧方框勾选对应文件夹';
  }

  double get _titleSize => _rangeMode ? 14.0 : 16.0;

  Color? get _titleColor => _rangeMode ? _rangeBlue : null;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: _dlgInsetG,
      titlePadding: _dlgTitlePadG,
      contentPadding: EdgeInsets.zero,
      actionsPadding: _dlgActionsPadG,
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              _titleText,
              style: TextStyle(
                fontSize: _titleSize,
                fontWeight: FontWeight.bold,
                color: _titleColor,
              ),
            ),
          ),
          // 常驻操作引导入口：弹窗右上角，随时可点开复习。
          IconButton(
            icon: const Icon(Icons.help_outline, size: 20),
            tooltip: '操作引导',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: _openGuide,
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _jumpCtrl,
                      cursorColor: Theme.of(context).colorScheme.primary,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '粘贴路径跳转',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      onSubmitted: (v) => _jumpToPath(v.trim()),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    color: Theme.of(context).colorScheme.primary,
                    tooltip: '跳转',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _jumpToPath(_jumpCtrl.text.trim()),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: _canGoUp ? _goUp : null,
                    tooltip: '上一级',
                    visualDensity: VisualDensity.compact,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        _relPath,
                        style: Theme.of(context).textTheme.labelSmall,
                        maxLines: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _dirs.isEmpty
                      ? const Center(child: Text('（无子目录）'))
                      : ListView.builder(
                          itemCount: _dirs.length,
                          itemBuilder: (ctx, i) {
                            final d = _dirs[i];
                            final name = d.path.split('/').last;
                            final selected = _selected.contains(d.path);
                            final isAnchor = d.path == _rangeAnchorPath;

                            return Container(
                              color: isAnchor ? _rangeHighlight : null,
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 4),
                                leading: SizedBox(
                                  width: 68,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // 第一行挂引导用的 key：这里是「勾选」。
                                      InkWell(
                                        key: i == 0 ? _guideCheckKey : null,
                                        onTap: () => _toggle(d.path),
                                        child: Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: Icon(
                                            selected
                                                ? Icons.check_box
                                                : Icons
                                                    .check_box_outline_blank,
                                            color: _rangeMode
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant
                                                    .withValues(alpha: 0.3)
                                                : (selected
                                                    ? Theme.of(context)
                                                        .colorScheme
                                                        .primary
                                                    : null),
                                          ),
                                        ),
                                      ),
                                      InkWell(
                                        onTap: () => _toggle(d.path),
                                        child: Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: const AppFileIcon(isDir: true),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                title: Text(name),
                                // 第一行挂引导用的 key：这里是「进入」。
                                trailing: InkWell(
                                  key: i == 0 ? _guideEnterKey : null,
                                  onTap: () {
                                    setState(() {
                                      _path = d.path;
                                      _rangeMode = false;
                                      _rangeAnchorPath = null;
                                    });
                                    _load();
                                  },
                                  child: const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Icon(Icons.chevron_right),
                                  ),
                                ),
                                onTap: () {
                                  if (_rangeMode) {
                                    _handleRangeTap(d.path);
                                    return;
                                  }
                                  setState(() {
                                    _path = d.path;
                                    _rangeAnchorPath = null;
                                  });
                                  _load();
                                },
                              ),
                            );
                          },
                        ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
              child: Row(
                children: [
                  FilterChip(
                    key: _guideAllKey,
                    label: const Text('全选'),
                    selected: _allVisibleSelected,
                    onSelected: (_) => _toggleSelectAll(),
                    backgroundColor:
                        Theme.of(context).colorScheme.surface,
                    selectedColor: Theme.of(context).colorScheme.surface,
                    surfaceTintColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    checkmarkColor: Theme.of(context).colorScheme.primary,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: _allVisibleSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 24),
                  FilterChip(
                    key: _guideRangeKey,
                    label: const Text('区间'),
                    selected: _rangeMode,
                    onSelected: (_) => _toggleRangeMode(),
                    backgroundColor:
                        Theme.of(context).colorScheme.surface,
                    selectedColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    surfaceTintColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    checkmarkColor: _rangeBlue,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: _rangeMode
                          ? _rangeBlue
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),
                  const Spacer(),
                  Text(
                    '已勾选 ${_selected.length} 个',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: _selected.isEmpty ? null : _showSelected,
                    child: const Text('查看'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

// ==================== 文件夹勾选器的操作引导 ====================

/// 弹窗右上角常驻的「?」按钮，以及首次进入时自动弹一次的分步引导。
///
/// 参考主流 App 的做法：一屏放不下就一页只讲一个功能，整屏压暗、只在
/// 当前要讲的元素处挖亮洞；右上角有「第 X / N · 还剩 M 页」计数，告诉
/// 用户后面还有几页。翻完即止，关掉后随时可点「?」再看一遍。

/// 引导的一页：要突出的元素屏幕矩形（为 null 时整屏轻压暗、只讲概念）+ 文案。
class _GuideStep {
  const _GuideStep({this.rect, required this.title, required this.body});
  final Rect? rect;
  final String title;
  final String body;
}

class _PickerGuideLayer extends StatefulWidget {
  const _PickerGuideLayer({
    super.key,
    required this.steps,
    required this.onClose,
  });

  final List<_GuideStep> steps;
  final VoidCallback onClose;

  @override
  State<_PickerGuideLayer> createState() => _PickerGuideLayerState();
}

class _PickerGuideLayerState extends State<_PickerGuideLayer> {
  int _page = 0;
  int get _total => widget.steps.length;

  void _next() {
    if (_page < _total - 1) {
      setState(() => _page++);
    } else {
      widget.onClose();
    }
  }

  void _prev() {
    if (_page > 0) setState(() => _page--);
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    final step = widget.steps[_page];
    final remaining = _total - _page - 1;
    final hasHole = step.rect != null;

    // 卡片放哪一侧：目标在屏幕下半（如底部「区间 / 全选」）就放到上面，
    // 否则放下面。高亮洞和卡片永不叠在一起——这正是之前那个 bug 的根因。
    final putTop = hasHole && step.rect!.center.dy > size.height * 0.55;

    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          // 压暗层：有洞时只挖当前这一页的洞；无洞时整屏轻压暗。
          Positioned.fill(
            child: CustomPaint(
              painter: _GuideHolePainter(
                holes: hasHole ? [step.rect!] : const [],
                dimColor: Colors.black.withValues(
                  alpha: hasHole ? 0.62 : 0.5,
                ),
                ringColor: Colors.white,
              ),
            ),
          ),

          // 右上角：计数 + 关闭。常驻提示「还有几页」。
          Positioned(
            top: 14,
            right: 14,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '第 ${_page + 1} / $_total',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        remaining > 0 ? '还剩 $remaining 页' : '最后一步',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: Colors.black.withValues(alpha: 0.62),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: widget.onClose,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.close, color: Colors.white, size: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 说明卡片：根据目标位置自动贴在上或下，避免挡住高亮。
          Positioned(
            left: 16,
            right: 16,
            top: putTop ? 64 : null,
            bottom: putTop ? null : 24,
            child: _guideCard(s, step),
          ),
        ],
      ),
    );
  }

  Widget _guideCard(ColorScheme s, _GuideStep step) {
    return Material(
      color: s.surface,
      borderRadius: BorderRadius.circular(12),
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              step.title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: s.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              step.body,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: s.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (_page > 0)
                  TextButton(
                    onPressed: _prev,
                    child: const Text('上一步'),
                  )
                else
                  const SizedBox.shrink(),
                const Spacer(),
                FilledButton(
                  onPressed: _next,
                  child: Text(_page < _total - 1 ? '下一步' : '完成'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 压暗整屏 + 挖洞。
///
/// 用 difference 填充路径：外圈是整个屏幕，内圈是每个要突出的元素
/// 对应的圆角矩形，相减后洞自然就空出来了。holes 为空时整屏被压暗
/// （用于没有具体可高亮目标的「纯讲解」页）。
class _GuideHolePainter extends CustomPainter {
  const _GuideHolePainter({
    required this.holes,
    required this.dimColor,
    required this.ringColor,
  });

  final List<Rect> holes;
  final Color dimColor;
  final Color ringColor;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Path()..addRect(Offset.zero & size);
    final cut = Path();
    for (final r in holes) {
      // 洞比原件大一圈，留出呼吸空间，也让高亮更明显。
      final pad = r.inflate(6);
      cut.addRRect(RRect.fromRectAndRadius(pad, const Radius.circular(10)));
    }
    final dimmed = Path.combine(PathOperation.difference, full, cut);

    canvas.drawPath(dimmed, Paint()..color = dimColor);

    // 洞边描一圈亮线，提示"看这里"。
    final ring = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final r in holes) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(r.inflate(6), const Radius.circular(10)),
        ring,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GuideHolePainter oldDelegate) =>
      oldDelegate.holes != holes ||
      oldDelegate.dimColor != dimColor ||
      oldDelegate.ringColor != ringColor;
}

// ==================== 属性弹窗（含手动计算 MD5） ====================

/// 多选属性弹窗里的一行明细（名称 / 大小 / 修改时间 / 路径）。
class _PropDetail {
  const _PropDetail({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modified,
  });

  final String name;
  final String? path;
  final bool isDir;
  final int? size;
  final DateTime? modified;
}

class _PropertiesDialog extends StatefulWidget {
  const _PropertiesDialog({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modified,
    required this.accessed,
  });

  final String name;
  final String path;
  final bool isDir;
  final int? size;
  final DateTime? modified;
  final DateTime? accessed;

  @override
  State<_PropertiesDialog> createState() => _PropertiesDialogState();
}

class _PropertiesDialogState extends State<_PropertiesDialog> {
  String? _md5;
  bool _md5Loading = false;
  String? _md5Error;

  Future<void> _computeMd5() async {
    if (widget.isDir) return;
    setState(() {
      _md5Loading = true;
      _md5Error = null;
    });
    try {
      final hash = await compute(_md5FileOfPath, widget.path);
      if (!mounted) return;
      setState(() {
        _md5 = hash;
        _md5Loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _md5Error = e.toString();
        _md5Loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 2),
              SelectableText(value),
            ],
          ),
        );

    return AlertDialog(
      insetPadding: const EdgeInsets.all(16),
      title: const Text('属性'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row('名称', widget.name),
                row('路径', widget.path),
                row('类型', widget.isDir ? '文件夹' : '文件'),
                row(
                  '大小',
                  widget.isDir
                      ? '—'
                      : (widget.size == null
                          ? '—'
                          : _FileBrowserScreenState._formatSize(widget.size)),
                ),
                if (widget.modified != null)
                  row(
                    '修改时间',
                    _FileBrowserScreenState._formatTimeFull(widget.modified!),
                  ),
                if (widget.accessed != null)
                  row(
                    '访问时间',
                    _FileBrowserScreenState._formatTimeFull(widget.accessed!),
                  ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'MD5',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const SizedBox(height: 4),
                      _buildMd5Area(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildMd5Area() {
    if (widget.isDir) {
      return Text(
        '文件夹不支持计算 MD5',
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }

    if (_md5Loading) {
      return const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('计算中…', style: TextStyle(fontSize: 13)),
        ],
      );
    }

    if (_md5 != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  _md5!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: '重新计算',
                visualDensity: VisualDensity.compact,
                onPressed: _computeMd5,
              ),
            ],
          ),
          if (_md5Error != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '计算失败：$_md5Error',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      );
    }

    return OutlinedButton.icon(
      onPressed: _computeMd5,
      icon: const Icon(Icons.fingerprint, size: 16),
      label: const Text('点击计算 MD5'),
    );
  }
}

// ==================== 删除确认弹窗（异步统计） ====================

typedef _PathStat = ({int files, int bytes, bool truncated, bool done});

class _DeleteConfirmDialog extends StatefulWidget {
  const _DeleteConfirmDialog({required this.paths});
  final List<String> paths;

  @override
  State<_DeleteConfirmDialog> createState() => _DeleteConfirmDialogState();
}

class _DeleteConfirmDialogState extends State<_DeleteConfirmDialog> {
  static const int _limit = 10000;

  final Map<String, _PathStat> _stats = {};
  final Map<String, bool> _isDir = {};
  bool _allDone = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
  for (final p in widget.paths) {
    try {
      if (!Directory(p).existsSync()) {
        _isDir[p] = false;
        final st = File(p).statSync();
        _stats[p] = (files: 1, bytes: st.size, truncated: false, done: true);
      }
    } catch (_) {
      _stats[p] = (files: 0, bytes: 0, truncated: true, done: true);
    }
  }
  if (mounted) setState(() {});

  for (final p in widget.paths) {
    if (!mounted) return;
    if (_stats.containsKey(p)) continue;
    try {
      if (Directory(p).existsSync()) {
        _isDir[p] = true;
        if (mounted) setState(() {});
        final r = await _scanDir(p);
        if (!mounted) return;
        _stats[p] = r;
      }
    } catch (_) {
      _stats[p] = (files: 0, bytes: 0, truncated: true, done: true);
    }
    if (mounted) setState(() {});
  }
  if (mounted) setState(() => _allDone = true);
}

  Future<_PathStat> _scanDir(String rootPath) async {
    var fileCount = 0;
    var dirCount = 0;
    var bytes = 0;
    final stack = <String>[rootPath];
    var lastYield = DateTime.now();
    while (stack.isNotEmpty) {
      if (fileCount + dirCount > _limit) {
        return (files: fileCount, bytes: bytes, truncated: true, done: true);
      }
      final p = stack.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = Directory(p).listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final e in entries) {
        if (e is File) {
          fileCount++;
          try {
            bytes += e.statSync().size;
          } catch (_) {}
        } else if (e is Directory) {
          dirCount++;
          stack.add(e.path);
        }
      }
      final now = DateTime.now();
      if (now.difference(lastYield).inMilliseconds > 30) {
        lastYield = now;
        if (mounted) setState(() {});
        await Future<void>.delayed(Duration.zero);
      }
    }
    return (files: fileCount, bytes: bytes, truncated: false, done: true);
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.paths.length;

    final totalFiles = _stats.values.fold<int>(0, (s, e) => s + e.files);
    final totalBytes = _stats.values.fold<int>(0, (s, e) => s + e.bytes);
    final anyTruncated = _stats.values.any((e) => e.truncated);

    final lines = <Widget>[];
    for (final p in widget.paths) {
      final name = p.split('/').last;
      final stat = _stats[p];
      final isDir = _isDir[p] ?? false;

      String text;
      if (stat == null) {
        text = '· ${isDir ? "$name/" : name} —— 正在统计…';
      } else if (stat.truncated) {
        text = '· $name/ —— 文件超过 $_limit 个，未完全统计';
      } else if (isDir) {
        text = '· $name/ —— ${stat.files} 个文件，${_fmt(stat.bytes)}';
      } else {
        text = '· $name —— ${_fmt(stat.bytes)}';
      }

      lines.add(Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
      ));
    }

    String totalStr;
    if (!_allDone) {
      totalStr = '正在统计…';
    } else if (anyTruncated) {
      totalStr = '总计约 ${_fmt(totalBytes)}（部分未统计）';
    } else {
      totalStr = '共 $totalFiles 个文件，${_fmt(totalBytes)}';
    }

    // 按选中项类型说明删除去向：文件→回收站，文件夹→直接删除。
    final statCount = _isDir.length; // 已统计出类型的项数
    final dirCount = _isDir.values.where((d) => d).length;
    final fileCount = statCount - dirCount;
    final unknownCount = n - statCount;

    final String fateText;
    if (unknownCount > 0) {
      fateText = '文件将先移入回收站（可在「⋯ → 回收站」恢复）；'
          '文件夹将被直接删除，无法恢复。';
    } else if (fileCount > 0 && dirCount == 0) {
      fateText = '选中的 $fileCount 个文件将先移入回收站，'
          '可在「⋯ → 回收站」中恢复，不会直接物理删除。';
    } else if (fileCount == 0 && dirCount > 0) {
      fateText = '选中的 $dirCount 个文件夹（含其全部内容）将被直接删除，无法恢复。';
    } else {
      fateText = '$fileCount 个文件将先移入回收站（可恢复）；'
          '$dirCount 个文件夹将被直接删除，无法恢复。';
    }

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      title: Text('删除 $n 项？'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ...lines,
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Text(
                totalStr,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                fateText,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

// ==================== 加载骨架屏（Shimmer 流光） ====================

class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform(this.slidePercent);
  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(
      bounds.width * (slidePercent * 2 - 1),
      0,
      0,
    );
  }
}

class _LoadingSkeleton extends StatefulWidget {
  const _LoadingSkeleton({super.key, this.rows = 16});
  final int rows;

  @override
  State<_LoadingSkeleton> createState() => _LoadingSkeletonState();
}

class _LoadingSkeletonState extends State<_LoadingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, _) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final cs = Theme.of(context).colorScheme;
            return LinearGradient(
              colors: [
                cs.surfaceVariant,
                cs.surfaceVariant.withValues(alpha: 0.4),
                cs.surfaceVariant,
              ],
              stops: const [0.35, 0.5, 0.65],
              transform: _SlidingGradientTransform(_ctrl.value),
            ).createShader(bounds);
          },
          child: _buildStatic(),
        );
      },
    );
  }

  Widget _buildStatic() {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: widget.rows,
      itemBuilder: (ctx, i) {
        // 每行宽度略有变化，看起来不像机器排的
        final nameW = 120.0 + (i * 37) % 80;
        final metaW = 70.0 + (i * 23) % 60;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: nameW,
                      height: 11,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: metaW,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ==================== 可拖动滚动条（外包在列表之上） ====================

/// ScrollablePositionedList 不暴露 ScrollController，
/// 所以用 ItemPositionsListener 的可见项信息推算滚动位置，
/// 拖动时换算成目标条目索引再 jumpTo。
class _BrowserScrollbar extends StatefulWidget {
  const _BrowserScrollbar({
    required this.positions,
    required this.itemCount,
    required this.thumbWidth,
    required this.trackColor,
    required this.thumbColor,
    required this.onJump,
  });

  final ValueListenable<Iterable<ItemPosition>> positions;
  final int Function() itemCount;
  final double thumbWidth;
  final Color trackColor;
  final Color thumbColor;
  final void Function(int index) onJump;

  @override
  State<_BrowserScrollbar> createState() => _BrowserScrollbarState();
}

class _BrowserScrollbarState extends State<_BrowserScrollbar> {
  static const double _minThumb = 36;

  /// 拖动中的拇指顶部位置；null 表示跟随列表实际位置。
  double? _dragTop;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final h = c.maxHeight;
        return ValueListenableBuilder<Iterable<ItemPosition>>(
          valueListenable: widget.positions,
          builder: (ctx, positions, _) {
            final m = _metrics(h, positions);
            final top =
                (_dragTop ?? m.top).clamp(0.0, m.maxTop).toDouble();

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                // 点轨道直接跳到对应位置（拖动时不会误触发）。
                final t = (d.localPosition.dy - m.thumbH / 2)
                    .clamp(0.0, m.maxTop)
                    .toDouble();
                _apply(m, t);
              },
              onVerticalDragStart: (d) {
                final inThumb = d.localPosition.dy >= top &&
                    d.localPosition.dy <= top + m.thumbH;
                if (inThumb) {
                  setState(() => _dragTop = top);
                } else {
                  final t = (d.localPosition.dy - m.thumbH / 2)
                      .clamp(0.0, m.maxTop)
                      .toDouble();
                  setState(() => _dragTop = t);
                  _apply(m, t);
                }
              },
              onVerticalDragUpdate: (d) {
                final t = ((_dragTop ?? top) + d.delta.dy)
                    .clamp(0.0, m.maxTop)
                    .toDouble();
                setState(() => _dragTop = t);
                _apply(m, t);
              },
              onVerticalDragEnd: (_) => setState(() => _dragTop = null),
              onVerticalDragCancel: () => setState(() => _dragTop = null),
              child: CustomPaint(
                size: Size(c.maxWidth, h),
                painter: _BrowserScrollbarPainter(
                  top: top,
                  thumbHeight: m.thumbH,
                  thumbWidth: widget.thumbWidth,
                  trackColor: widget.trackColor,
                  thumbColor: widget.thumbColor,
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _apply(_ScrollMetrics m, double top) {
    if (m.maxTop <= 0) return;
    final f = top / m.maxTop;
    widget.onJump((f * m.maxScroll).round());
  }

  _ScrollMetrics _metrics(
    double h,
    Iterable<ItemPosition> positions,
  ) {
    final count = widget.itemCount();
    var visible = 0;
    var first = 0;
    var leading = 0.0;
    var found = false;

    for (final p in positions) {
      if (p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1) {
        visible++;
        if (!found || p.index < first) {
          found = true;
          first = p.index;
          leading = p.itemLeadingEdge;
        }
      }
    }

    if (!found || count <= 0) {
      return _ScrollMetrics(thumbH: h, top: 0, maxTop: 0, maxScroll: 1);
    }

    final thumbH = math.min(h, math.max(_minThumb, h * visible / count));
    final maxTop = math.max(0.0, h - thumbH);
    final maxScroll = math.max(1, count - visible);
    final raw = first + leading.clamp(-1.0, 0.0).toDouble();
    final top =
        (raw / maxScroll).clamp(0.0, 1.0).toDouble() * maxTop;
    return _ScrollMetrics(
      thumbH: thumbH,
      top: top,
      maxTop: maxTop,
      maxScroll: maxScroll,
    );
  }
}

class _ScrollMetrics {
  const _ScrollMetrics({
    required this.thumbH,
    required this.top,
    required this.maxTop,
    required this.maxScroll,
  });

  final double thumbH;
  final double top;
  final double maxTop;
  final int maxScroll;
}

class _BrowserScrollbarPainter extends CustomPainter {
  const _BrowserScrollbarPainter({
    required this.top,
    required this.thumbHeight,
    required this.thumbWidth,
    required this.trackColor,
    required this.thumbColor,
  });

  final double top;
  final double thumbHeight;
  final double thumbWidth;
  final Color trackColor;
  final Color thumbColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0 || size.width <= 0) return;
    final w = thumbWidth.clamp(2.0, size.width).toDouble();
    final left = size.width - w;

    // 轨道
    final trackRect = Rect.fromLTWH(left, 0, w, size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, Radius.circular(w / 2)),
      Paint()..color = trackColor,
    );

    // 拖动块
    final thumbRect = Rect.fromLTWH(left, top, w, thumbHeight);
    canvas.drawRRect(
      RRect.fromRectAndRadius(thumbRect, Radius.circular(w / 2)),
      Paint()..color = thumbColor,
    );
  }

  @override
  bool shouldRepaint(covariant _BrowserScrollbarPainter old) =>
      old.top != top ||
      old.thumbHeight != thumbHeight ||
      old.thumbWidth != thumbWidth ||
      old.trackColor != trackColor ||
      old.thumbColor != thumbColor;
}

// ==================== 悬浮翻页按钮 ====================

class _BrowserFloatingPageButton extends StatelessWidget {
  const _BrowserFloatingPageButton({
    required this.size,
    required this.color,
    required this.up,
    required this.onTap,
  });

  final double size;
  final Color color;
  final bool up;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg =
        color.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;
    return Material(
      color: color,
      shape: const CircleBorder(),
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Icon(
          up ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
          size: size * 0.62,
          color: fg,
        ),
      ),
    );
  }
}

class _VisibleRange {
  const _VisibleRange({
    required this.first,
    required this.last,
    required this.visible,
  });

  final int first;
  final int last;
  final int visible;
}

/// 以流式方式读取文件计算 MD5，避免把整个大文件读进内存。
/// 使用 crypto 包自带的 Hash.bind，按文件原生分块流式转换（无需 AccumulatorSink，
/// 该符号并不属于 crypto 的公开 API，用它会导致编译失败）。
Future<String> _md5FileOfPath(String path) async {
  final digest = await md5.bind(File(path).openRead()).single;
  return digest.toString();
}
