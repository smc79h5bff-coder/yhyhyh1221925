import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'crash_trace.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../diff/application/diff_cache.dart';
import '../../file_browser/presentation/dialogs/directory_picker_dialog.dart';
import '../../share_intake/application/share_intake_service.dart';
import '../../diff/domain/diff_entry.dart';
import '../../diff/domain/diff_operation.dart';
import '../../diff/domain/diff_result.dart';
import '../../edit/presentation/edit_screen.dart';
import '../../file_browser/presentation/comparison_settings_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/application/preprocessing_service.dart';
import '../../preprocessing/application/watermark_service.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';


import '../../preprocessing/application/aho_corasick.dart';
import '../../../core/storage/pref_keys.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/debug/crash_logger.dart';
import 'diagnostic_screen.dart';
import 'diff_text_index.dart';
import 'grouped_diff_view.dart';
import 'line_list_page.dart';
import 'loading_palette.dart';
import 'step_ring.dart';
import 'line_height_cache.dart';
import 'line_height_calculator.dart';
import 'line_display.dart';
import 'providers/diff_viewer_providers.dart';
import 'providers/toolbar_rules_provider.dart';
import 'regex_help_screen.dart';
import 'viewer_widgets.dart';
import 'widgets/diff_only_plain_view.dart';
import 'widgets/diff_only_view.dart';
import 'widgets/merged_view.dart';
import 'widgets/side_by_side_view.dart';
import 'widgets/low_similarity_dialogs.dart';
import 'widgets/source_mini_editor.dart';
import '../../parser/application/document_parser.dart';

class DiffViewerScreen extends ConsumerStatefulWidget {
  const DiffViewerScreen({super.key});

  @override
  ConsumerState<DiffViewerScreen> createState() => _DiffViewerScreenState();
}

class _SwitchChoice {
  const _SwitchChoice.top()
      : targetEntry = null,
        isTop = true;
  const _SwitchChoice.entry(int this.targetEntry) : isTop = false;

  final int? targetEntry;
  final bool isTop;
}

class _HeightBundle {
  const _HeightBundle({
    this.merged,
    this.sbsSync,
    this.sbsLeft,
    this.sbsRight,
    this.diffOnly,
    this.diffOnlyPlain,
  });

  final LineHeightTable? merged;
  final LineHeightTable? sbsSync;
  final LineHeightTable? sbsLeft;
  final LineHeightTable? sbsRight;
  final LineHeightTable? diffOnly;
  final LineHeightTable? diffOnlyPlain;
}

/// 视图切换 tab 的横向几何（相对 tab 条内容区，不随横向滚动改变）。
class _TabGeom {
  const _TabGeom(this.left, this.width);

  final double left;
  final double width;
}

class _DiffViewerScreenState extends ConsumerState<DiffViewerScreen>
    with TickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _hScrollController = ScrollController();

  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();

  bool _showFind = false;
  String _findQuery = '';

  // ===== 迷你源文件编辑器（默认关闭，设置里主动开启才可用）=====
  // 默认：单击=无操作、长按=编辑此行；迷你编辑器默认不出现在任何手势上，
  // 只有用户在「更多 → 显示设置 → 行手势」里主动设为 mini 才可用。
  // _miniEditorOpen 为 true 时，整屏手势屏障会吞掉「轻触」，但「长按」会穿透到
  // 下层行，从而把当前编辑器切换成那一行对应的文件（单窗切换，不叠加新窗）。
  // _onRowTap / _onRowLongPress 哪个绑「点」、哪个绑「长按」由
  // rowTapActionProvider / rowLongPressActionProvider（显示设置里可自定义）决定；
  // 两者开头都有短路判断，小窗开着时点下层行不会弹编辑框。
  bool _miniEditorOpen = false;
  bool _rowEditDialogOpen = false;
  String? _miniEditorPath;
  String? _miniEditorAnchor;

  /// 长按那行在「规范化文件」里的行号（0 基）。配合行映射表精确跳源文件行；
  /// 取不到（如右栏独有行在左侧无对应）时为 null，迷你编辑器回退锚文本匹配。
  int? _miniEditorAnchorLine;

  /// 长按那行在「规范化文本」里的上下文（前后各 2 行，共 5 行）。
  /// 只用来给候选位置按「邻居像不像」排序（2026-11-15 上下文校验），
  /// 不参与否决——规则本来就会改字，文字不像绝不是错位信号。
  List<String>? _miniEditorAnchorContext;
  bool _miniEditorIsOriginal = true;

  /// 小窗本体的 GlobalKey：用于读取「是否有未保存改动」与触发保存，
  /// 以支持「切换文件前先询问丢弃还是保存」。
  final _miniFrameKey = GlobalKey<MiniWindowFrameState>();

  List<int> _matchEntries = const <int>[];
  int _matchPos = -1;

  String _scannedQuery = '';
  String? _noResultHint;

  String? _findWarning;
  String? _replaceHint;
  String? _regexErrorHint;

  bool _regexEnable = false;
  bool _caseInsensitive = false;
  bool _wholeWord = false;
  bool _searchLeft = true;
  bool _searchRight = true;

  final Map<int, String> _pendingOrigChanges = <int, String>{};
  final Map<int, String> _pendingModChanges = <int, String>{};

  bool _landscape = false;
  bool _originalDeleted = false;
  bool _modifiedDeleted = false;

  /// 正在删除确认弹窗中的一侧：null = 没有，true = 左侧，false = 右侧。
  /// 只在弹窗存活期间给对应那一栏盖红色遮罩，确认或取消后立即清空。
  bool? _pendingDeleteOriginal;

  List<int>? _cachedDiffIndices;
  DiffResult? _cachedDiffIndicesFor;

  Map<int, int>? _entryToRowMap;
  DiffResult? _entryToRowMapFor;
  ViewMode? _entryToRowMapMode;

  // 后台精确高度表
  final Map<ViewMode, Future<_HeightBundle>> _heightFutures = {};
  final Map<ViewMode, _HeightBundle> _heightExactResults = {};
  // 已完成精确计算的模式（用于切视图"就绪即走"判断）。
  final Set<ViewMode> _completedHeightModes = {};
  DiffResult? _heightFuturesFor;
  String? _heightFuturesConfigKey;

  static final Future<_HeightBundle> _emptyHeightFuture =
      Future.value(const _HeightBundle());
  int? _jumpedToEntry;

  double? _pendingGroupedRestoreOffset;

  _HeightBundle? _activeHeights;
  // 是否已经成功显示过一次正文。首次进入 = false，切视图 = true。
  bool _hasShownContentOnce = false;

  double? _cachedContentWidth;
  DiffResult? _cachedContentWidthFor;
  String? _cachedContentWidthConfig;

  int? _pendingJumpEntry;
  int? _pendingJumpOrigLine;
  bool _pendingJumpQueued = false;

  // 首次对比的「要不要自动去掉水印」询问弹窗：按需求暂时隐藏，不再弹出。
  // 原逻辑保留在下方 _showWatermarkOnboard() 内，需要恢复时把 initState 里
  // 那段被注释的 addPostFrameCallback 取消注释即可。
  OverlayEntry? _floatEntry;
  Timer? _floatTimer;

  bool _jumping = false;
  JumpDirection _jumpDirection = JumpDirection.down;
  Timer? _findDebounce;
  bool _processing = false;
  String _processingText = '';

  DiffResult? _lastDiagDiff;
  final GlobalKey _groupedKey = GlobalKey();

  final ScrollController _tabScrollController = ScrollController();
  bool _tabAtEnd = false;

  final Map<ViewMode, GlobalKey> _tabKeys = {
    for (final m in ViewMode.values) m: GlobalKey(),
  };

  // 切视图遮罩：截止时间。非 null 且未到期时显示加载动画；
  // 目标高度表已就绪时为 null，瞬时切换不遮罩。
  DateTime? _switchOverlayUntil;
  Timer? _switchOverlayTimer;

  /// 全文快筛判定相似度过低时，弹窗只弹一次所用的标记。
  /// 每次 diffResultProvider 产出新的 DiffResult 会重置，避免切视图/重建时反复弹。
  SimilarityGate? _lowSimilarityPromptedFor;

  // ── 加载过久的软提示（只问一次，不替用户停）──────────────────
  static const int _slowWarnSeconds = 15;
  Timer? _slowWarnTimer;
  bool _slowWarnShown = false;
  bool _riskDialogOpen = false; // 防止相似度提示和超时提示叠成两层窗

  // T7 视图 tab 动效：指示条滑动回弹 + 文字 Q 弹 + 文字颜色渐变。
  // 只驱动 40px 高的 tab 条，不参与正文列表与切视图遮罩的重建。
  late AnimationController _tabAnimController;
  Map<ViewMode, _TabGeom>? _tabGeometry;
  ViewMode? _tabFromMode;
  ViewMode? _tabToMode;
  double? _tabFromLeft;
  double? _tabFromWidth;
  double? _tabDisplayLeft;
  double? _tabDisplayWidth;

  @override
  void initState() {
  super.initState();
  _tabAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  // 首次进入对比页的「要不要自动去掉水印」询问弹窗：按需求暂时隐藏，不再弹出。
  // 原触发逻辑：
  // WidgetsBinding.instance.addPostFrameCallback((_) {
  //   if (!mounted) return;
  //   if (ref.read(watermarkOnboardProvider)) return;
  //   _showWatermarkOnboard();
  // });
  // 每次进入对比页，清空行列表（一次性会话）。
  ref.read(lineListTextProvider.notifier).state = '';
  WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(viewModeProvider.notifier).state =
          ref.read(defaultViewModeProvider);
    });
  _tabScrollController.addListener(_onTabScroll);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final mode = ref.read(viewModeProvider);
    final ctx = _tabKeys[mode]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: Duration.zero, alignment: 0.5);
    }
  });
  // 从对比页出现开始计时：15 秒还没出结果就问一次「还等吗」。
  _restartSlowWarnTimer();
  }

  @override
  void dispose() {

    _findDebounce?.cancel();
_floatTimer?.cancel();
_floatEntry?.remove();
    _switchOverlayTimer?.cancel();
    _slowWarnTimer?.cancel();
    _tabAnimController.dispose();
    _findController.dispose();
    _replaceController.dispose();
    _tabScrollController.removeListener(_onTabScroll);
    _tabScrollController.dispose();
    _scrollController.dispose();
    _hScrollController.dispose();
    super.dispose();
  }

  DiffResult? get _diff => ref.read(diffResultProvider).value;

  int? get _currentMatchEntry {
    if (_matchEntries.isEmpty) return null;
    if (_matchPos < 0 || _matchPos >= _matchEntries.length) return null;
    return _matchEntries[_matchPos];
  }

  bool _isDiffOnlyMode(ViewMode m) =>
      m == ViewMode.diffOnly || m == ViewMode.diffOnlyPlain;

  bool get _isLargeFile {
    final diff = _diff;
    return diff != null && diff.entries.length > 2000;
  }

  void _log(String msg) {
    // 以前由诊断页的「历史」开关控制；现在统一跟随诊断总开关，
    // 判断在 DiagHistory.record 里，关闭时直接 return。
    DiagHistory.record(msg);
  }

  /// 首次进入对比页时弹出的「要不要自动去掉水印」询问。
  ///
  /// 文案尽量说人话：不提"正则""字面匹配""预处理"这些词，直接告诉用户
  /// 水印是什么、两种选择分别会怎样、以后去哪改。问过一次写标记，不再弹。
  Future<void> _showWatermarkOnboard() async {
    // 标记已询问（持久化），无论用户怎么选都不再弹。
    ref.read(watermarkOnboardProvider.notifier).update(true);

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false, // 强制二选一，避免随手关掉后功能一直没配
      builder: (c) => AlertDialog(
        title: const Text('对比时是否过滤水印？（不改源文件）'),
content: const SingleChildScrollView(
  child: Text(
    '下面两个选择，挑一个：\n\n'
    '① 过滤水印\n'
    'App 内置了一份「水印词表」，对比时会自动跳过表里的词，'
    '只显示正文的差异。\n'
    '水印样式太多，表里难免有漏。漏掉的可以自己加：'
    '打开「对比规则设置 → 水印表」，把没被过滤掉的词填进去。\n\n'
    '② 保留水印\n'
    '所有文字原样对比，水印也一起显示。'
    '适合你想看看文里有哪些修改。\n\n'
    '以后随时能改：打开「对比规则设置 → 水印表」，'
    '可以开关过滤功能，也能自己增删词。',
    style: TextStyle(fontSize: 13.5, height: 1.65),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'keep'),
            child: const Text('保留水印'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'filter'),
            child: const Text('去掉水印'),
          ),
        ],
      ),
    );

    if (result == 'filter') {
      ref.read(watermarkEnabledProvider.notifier).update(true);
    }
    // 'keep' 或关闭：保持默认关，不处理。
  }

  /// 全文快筛拦下后只弹一道黄色提示（原来两道、第二道红色的已合并）。
  ///
  /// 取消对比 = 退出对比页；继续对比 = 打开强制开关、让 diffResultProvider
  /// 重算（这次跳过快筛，仍走原来的 Myers 算法，一行算法都没改）。
  Future<void> _handleLowSimilarity(SimilarityGate gate) async {
    // 万一超时询问正开着，等它关掉再弹，别叠成两层窗。
    while (_riskDialogOpen && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    _riskDialogOpen = true;
    final choice =
        await showLowSimilarityPrompt(context, percent: gate.percent);
    _riskDialogOpen = false;
    if (!mounted) return;
    if (choice != CompareRiskChoice.proceed) {
      Navigator.of(context).maybePop();
      return;
    }
    ref.read(forceCompareProvider.notifier).state = true;
    ref.invalidate(diffResultProvider);
    // 强行对比相当于重新开跑，超时询问也重新计一次。
    _restartSlowWarnTimer();
  }

  void _restartSlowWarnTimer() {
    _slowWarnTimer?.cancel();
    _slowWarnShown = false;
    _slowWarnTimer = Timer(
      const Duration(seconds: _slowWarnSeconds),
      () {
        _showSlowCompareWarning();
      },
    );
  }

  /// 加载超过 15 秒还没出结果：象征性地问一次，用户说了算。
  /// 继续等待 = 什么都不做；取消对比 = 真停掉后台 isolate 再退出页面。
  Future<void> _showSlowCompareWarning() async {
    if (!mounted || _slowWarnShown || _riskDialogOpen) return;
    // 相似度提示正在等用户决定时先不问；用户点「继续对比」会重开这个计时器。
    if (ref.read(lowSimilarityProvider) != null || _diff != null) return;
    // 已经出结果（或压根没内容可比）且没有加载阶段文案 → 没有在跑，不用问。
    // 读盘/预处理阶段 stage 非 null、算 diff 阶段 provider 是 AsyncLoading，
    // 这两种才是真正「等了 15 秒」。
    final stage = ref.read(compareLoadStageProvider);
    if (stage == null && ref.read(diffResultProvider).hasValue) return;
    _slowWarnShown = true;
    _riskDialogOpen = true;
    final choice = await showSlowCompareWarning(
      context,
      seconds: _slowWarnSeconds,
    );
    _riskDialogOpen = false;
    if (!mounted) return;
    if (choice == CompareRiskChoice.proceed) return; // 继续等，本次不再重复问
    diffWorkerHandle.cancel();
    // 退出前把加载页留着，别闪一下"请先导入两份文档"。
    ref.read(compareLoadStageProvider.notifier).state = '正在取消对比…';
    Navigator.of(context).maybePop();
  }

  // ==================== 查找 / 替换基础逻辑 ====================

  Pattern _buildFindPattern() {
    final q = _findQuery;
    if (q.isEmpty) return RegExp(r'(?!)');
    var src = _regexEnable ? q : RegExp.escape(q);
    if (_wholeWord) src = r'\b' + src + r'\b';
    try {
      return RegExp(src, caseSensitive: !_caseInsensitive, multiLine: true);
    } catch (_) {
      return RegExp(r'(?!)');
    }
  }

  ({String name, String detail}) _translateRegexError(Object e) {
    var msg = e.toString();
    for (final p in const ['FormatException: ', 'Exception: ']) {
      if (msg.startsWith(p)) {
        msg = msg.substring(p.length);
        break;
      }
    }
    const table = <String, (String, String)>{
      'Unterminated character class': (
        '字符类 [ 没有闭合',
        '正则里每个 [ 都要有一个 ] 配对。\n'
            '比如 [abc 应改成 [abc]，[0-9 应改成 [0-9]。',
      ),
      'Unterminated group': (
        '括号 ( 没有闭合',
        '每个 ( 都要有一个 ) 配对。\n'
            '比如 (abc 应改成 (abc)，((a)(b) 应改成 ((a)(b))。',
      ),
      'Nothing to repeat': (
        '量词前面没有可重复的内容',
        '*、+、?、{n} 这些符号前面必须有东西让它们重复。\n'
            '比如 *abc 应改成 a*bc；想匹配任意字符，应改成 .*abc。',
      ),
      'Lone quantifier brackets': (
        '出现了单独的 { 或 }',
        '{ 和 } 在正则里是量词符号（如 {2,5} 表示重复 2 到 5 次）。\n'
            '如果只是想要字面的花括号，请写成 \\{ 和 \\}。',
      ),
      'Range out of order': (
        '字符类的范围顺序反了',
        '比如 [z-a] 里 z 比 a 大，是无效的。\n'
            '范围要从小到大写，比如 [a-z]。',
      ),
      'Invalid range': (
        '量词范围写法不对',
        '{n,m} 里 n 必须小于等于 m，且都是非负整数。\n'
            '比如 {5,2} 应改成 {2,5}。',
      ),
      'Invalid escape': (
        '含非法的转义字符',
        '反斜杠只能转义有限的字符：\\d \\w \\s \\. \\* \\\\ 等。\n'
            '如果你想搜字面的反斜杠，请写两个反斜杠 \\\\。',
      ),
      'Invalid Unicode escape': (
        'Unicode 转义写法不对',
        '\\u 后面必须跟 4 位十六进制数字，比如 \\u4e2d 表示"中"。',
      ),
      'Invalid decimal escape': (
        '十进制转义写法不对',
        '\\1 \\2 在正则里表示反向引用（引用前面捕获到的内容），\n'
            '但引用的组必须已经存在。',
      ),
      'Invalid group': (
        '分组写法不对',
        '常见错误：\n'
            '· (?:abc) 非捕获组，? 后面必须是 : 或 = 或 ! 或 <\n'
            '· (?<name>...) 命名组，name 只能用字母、数字、下划线',
      ),
      'Invalid capture group name': (
        '捕获组名字不合法',
        '(?<名字>...) 里的名字只能用字母、数字、下划线，不能有空格或中文。',
      ),
      'Duplicate capture group name': (
        '捕获组名字重复',
        '同一个正则里 (?<name>...) 的 name 不能重复出现。',
      ),
      'Invalid named reference': (
        '引用了不存在的命名组',
        '\\k<name> 里的 name 必须在前面的 (?<name>...) 里定义过。',
      ),
      'Trailing': (
        '末尾是反斜杠 \\，后面缺字符',
        '反斜杠必须后跟一个字符才有效。\n'
            '如果只想搜字面的反斜杠，请写两个反斜杠 \\\\。',
      ),
    };
    for (final entry in table.entries) {
      if (msg.contains(entry.key)) {
        return (name: entry.value.$1, detail: entry.value.$2);
      }
    }
    return (
      name: '语法有误',
      detail: 'Dart 返回的原始错误：$msg\n'
          '常见排查：\n'
          '· 方括号 [ ] 是否配对\n'
          '· 圆括号 ( ) 是否配对\n'
          '· 反斜杠 \\ 后面是否有字符\n'
          '· { n,m } 里的数字是否从小到大',
    );
  }

  int _countCaptureGroups(String pattern) {
    var count = 0;
    var i = 0;
    var inClass = false;
    while (i < pattern.length) {
      final c = pattern.codeUnitAt(i);
      if (c == 0x5C) { i += 2; continue; }
      if (inClass) {
        if (c == 0x5D) inClass = false;
        i++;
        continue;
      }
      if (c == 0x5B) { inClass = true; i++; continue; }
      if (c == 0x28) {
        if (i + 1 < pattern.length && pattern.codeUnitAt(i + 1) == 0x3F) {
          if (i + 2 < pattern.length) {
            final c3 = pattern.codeUnitAt(i + 2);
            if (c3 == 0x3A || c3 == 0x21 || c3 == 0x3D) {
              i += 3;
              continue;
            }
            if (c3 == 0x3C && i + 3 < pattern.length) {
              final c4 = pattern.codeUnitAt(i + 3);
              if (c4 == 0x3D || c4 == 0x21) {
                i += 4;
                continue;
              }
              count++;
              i += 3;
              continue;
            }
          }
          i += 2;
          continue;
        }
        count++;
      }
      i++;
    }
    return count;
  }

  int? _captureGroupCount() {
    if (!_regexEnable) return null;
    var src = _findQuery;
    if (src.isEmpty) return null;
    if (_wholeWord) src = r'\b' + src + r'\b';
    try {
      RegExp(src);
    } catch (_) {
      return null;
    }
    return _countCaptureGroups(src);
  }

  String? _diagnoseFind(String q) {
    if (q.isEmpty) return null;
    if (_regexEnable) {
      var src = q;
      if (_wholeWord) src = r'\b' + src + r'\b';
      try {
        RegExp(src, caseSensitive: !_caseInsensitive, multiLine: true);
      } catch (e) {
        final info = _translateRegexError(e);
        throw _RegexError(name: info.name, detail: info.detail);
      }
    }
    if (_wholeWord && RegExp(r'[\u4e00-\u9fff]').hasMatch(q)) {
      return '「整词」对中文无效\n'
          '「整词」的原理是在搜索词前后加 \\b（单词边界标记），\n'
          '但 \\b 只认英文字母、数字、下划线，中文字符不算单词，\n'
          '所以搜"北京"这类纯中文时，开着「整词」多半搜不到任何结果。\n'
          '建议：搜中文时把「整词」关掉。';
    }
    return null;
  }

  String? _diagnoseReplace() {
    final repl = _replaceController.text;
    if (repl.isEmpty) return null;
    if (!_regexEnable) return null;
    final bslash = RegExp(r'\\[1-9]').firstMatch(repl);
    if (bslash != null) {
      final n = bslash.group(0)![1];
      return '替换文本里的 ${bslash.group(0)} 不会生效\n'
          '本功能引用捕获组要用 \$ 符号，不是反斜杠。\n'
          '第 1 个捕获组写 \$1，第 2 个写 \$2，以此类推。\n'
          '请把 ${bslash.group(0)} 改成 \$$n。';
    }
    final groups = _captureGroupCount();
    if (groups != null) {
      for (final m in RegExp(r'\$(\d+)').allMatches(repl)) {
        final n = int.parse(m.group(1)!);
        if (n > groups) {
          final groupWord = groups == 0 ? '没有捕获组' : '只有 $groups 个捕获组';
          return '替换文本里的 \$$n 超出范围\n'
              '当前正则有 $groupWord，\n'
              '\$$n 会被替换成空字符串（不是你想的内容）。\n'
              '请检查是不是想用 \$1、\$2、\$3；\n'
              '如果需要更多捕获组，请在正则里多加括号 ()。';
        }
      }
    }
    if (RegExp(r'\$(?!\d)').hasMatch(repl)) {
      return '替换文本里的 \$ 用法提示\n'
          '本功能里 \$ 后面必须紧跟数字（如 \$1、\$2）才表示捕获组。\n'
          '现在这个 \$ 后面是别的字符，会被当成字面的 \$ 输出。\n'
          '· 如果想引用捕获组：改成 \$1、\$2 之类；\n'
          '· 如果想输出字面的 \$ 字符：目前暂不支持转义，请改用其他符号。';
    }
    return null;
  }

  void _onReplaceInput(String _) {
    final hint = _diagnoseReplace();
    if (hint == _replaceHint) return;
    setState(() => _replaceHint = hint);
  }

  String _expandReplacement(String tpl, Match m) {
    final out = StringBuffer();
    final re = RegExp(r'\$(\d+)');
    var last = 0;
    for (final match in re.allMatches(tpl)) {
      out.write(tpl.substring(last, match.start));
      final idx = int.parse(match.group(1)!);
      out.write(m.group(idx) ?? '');
      last = match.end;
    }
    out.write(tpl.substring(last));
    return out.toString();
  }

  String _applyReplace(String text, String replacement) {
    final p = _buildFindPattern();
    if (_regexEnable) {
      return text.replaceAllMapped(p, (m) => _expandReplacement(replacement, m));
    }
    return text.replaceAll(p, replacement);
  }

  bool _entryMatchesOnLeft(DiffEntry e) {
    if (!_searchLeft) return false;
    if (e.operation == DiffOperation.insert) return false;
    return true;
  }

  bool _entryMatchesOnRight(DiffEntry e) {
    if (!_searchRight) return false;
    if (e.operation == DiffOperation.delete) return false;
    return true;
  }

  String _entryLeftText(DiffEntry e) {
    if (e.operation == DiffOperation.replace && e.oldText.isNotEmpty) {
      return e.oldText;
    }
    return e.text;
  }

  String _entryRightText(DiffEntry e) {
    if (e.operation == DiffOperation.replace && e.newText.isNotEmpty) {
      return e.newText;
    }
    return e.text;
  }

  Set<int> _visibleEntriesFor(ViewMode mode, DiffResult diff) {
    final s = <int>{};
    switch (mode) {
      case ViewMode.diffOnly:
        for (final spec in cachedDiffOnlyRows(diff)) {
          if (spec.del != null) s.add(spec.del!);
          if (spec.ins != null) s.add(spec.ins!);
        }
        break;
      case ViewMode.diffOnlyPlain:
        for (final spec in cachedDiffOnlyPlainRows(diff)) {
          if (spec.del != null) s.add(spec.del!);
          if (spec.ins != null) s.add(spec.ins!);
        }
        break;
      case ViewMode.sideBySide:
        for (final spec in cachedAlignedRows(diff)) {
          if (spec.del != null) s.add(spec.del!);
          if (spec.ins != null) s.add(spec.ins!);
        }
        break;
      case ViewMode.merged:
        for (final ei in cachedMergedOrder(diff)) {
          s.add(ei);
        }
        break;
      case ViewMode.grouped:
        break;
    }
    return s;
  }

  void _onFindInput(String q) {
    _findDebounce?.cancel();
    setState(() => _findQuery = q);
    final delay = _isLargeFile
        ? const Duration(milliseconds: 600)
        : const Duration(milliseconds: 250);
    _findDebounce = Timer(delay, () {
      if (!mounted) return;
      _findChanged(q);
    });
  }

  void _findChanged(String q, {bool autoScroll = true}) {
    _findWarning = null;
    try {
      final warn = _diagnoseFind(q);
      _findWarning = warn;
    } on _RegexError catch (e) {
      _findQuery = q;
      _scannedQuery = q;
      setState(() {
        _matchEntries = const [];
        _matchPos = -1;
        _regexErrorHint = '正则语法错误：${e.name}\n${e.detail}';
      });
      (_groupedKey.currentState as dynamic)?.updateFindQuery('');
      return;
    }
    if (_regexErrorHint != null) {
      setState(() => _regexErrorHint = null);
    }

    if (ref.read(viewModeProvider) == ViewMode.grouped) {
      _findQuery = q;
      _scannedQuery = q;

      final diff = _diff;
      final matches = <int>[];
      if (q.isNotEmpty && diff != null) {
        final p = _buildFindPattern();
        for (var i = 0; i < diff.entries.length; i++) {
          final e = diff.entries[i];
          var hit = false;
          if (_entryMatchesOnLeft(e) &&
              p.allMatches(_entryLeftText(e)).isNotEmpty) {
            hit = true;
          }
          if (!hit &&
              _entryMatchesOnRight(e) &&
              p.allMatches(_entryRightText(e)).isNotEmpty) {
            hit = true;
          }
          if (hit) matches.add(i);
        }
      }
      final isLiteral = !_regexEnable && !_caseInsensitive && !_wholeWord;
      setState(() {
        _matchEntries = matches;
        _matchPos = matches.isEmpty ? -1 : 0;
        if (_findWarning != null) {
          _noResultHint = _findWarning;
        } else if (q.isNotEmpty && matches.isEmpty) {
          _noResultHint = '没找到「$q」';
        } else if (q.isNotEmpty && !isLiteral) {
          _noResultHint = '高级搜索已开，搜索结果暂不支持显示高亮';
        } else {
          _noResultHint = null;
        }
      });
      if (isLiteral) {
        (_groupedKey.currentState as dynamic)?.updateFindQuery(q);
      } else {
        (_groupedKey.currentState as dynamic)?.updateFindQuery('');
      }

      if (autoScroll && matches.isNotEmpty) {
        (_groupedKey.currentState as dynamic)?.scrollToEntry(matches[0]);
      }
      return;
    }

    _findQuery = q;
    _scannedQuery = q;
    final diff = _diff;
    final matches = <int>[];
    var hasGlobalHits = false;
    String? hint;

    if (q.isNotEmpty && diff != null) {
      final p = _buildFindPattern();
      final mode = ref.read(viewModeProvider);
      final visible = _visibleEntriesFor(mode, diff);
      for (var i = 0; i < diff.entries.length; i++) {
        if (!visible.contains(i)) continue;
        final e = diff.entries[i];
        var hit = false;
        if (_entryMatchesOnLeft(e) &&
            p.allMatches(_entryLeftText(e)).isNotEmpty) {
          hit = true;
        }
        if (!hit &&
            _entryMatchesOnRight(e) &&
            p.allMatches(_entryRightText(e)).isNotEmpty) {
          hit = true;
        }
        if (hit) matches.add(i);
      }

      // 屏幕行序 ≠ diff.entries 顺序：merged / 并排 / 仅差异都会把
      // delete 与 insert 交错配对显示（见 _mergedOrder、computeAlignedRows），
      // 而上面是按 entry 下标升序遍历的。若不重排，点「下一个」会在屏幕上
      // 往下跳一行又往回跳一行，看起来就是"跳转不准"。
      // 这里统一按当前视图的实际行序排序，导航与屏幕方向保持一致。
      final rowMap = _entryToRowMapOf(diff, mode);
      matches.sort((a, b) {
        final ra = rowMap[a];
        final rb = rowMap[b];
        if (ra == rb) return a.compareTo(b);
        if (ra == null) return 1;
        if (rb == null) return -1;
        return ra.compareTo(rb);
      });

      if (matches.isEmpty && _isDiffOnlyMode(mode)) {
        for (var i = 0; i < diff.entries.length; i++) {
          final e = diff.entries[i];
          if (p.allMatches(_entryLeftText(e)).isNotEmpty ||
              p.allMatches(_entryRightText(e)).isNotEmpty) {
            hasGlobalHits = true;
            break;
          }
        }
        if (hasGlobalHits) {
          hint = '本视图搜不到，切视图试试';
        }
      }
    }
    if (q.isNotEmpty && (_regexEnable || _caseInsensitive || _wholeWord)) {
      const warn = '高级搜索已开，搜索结果暂不支持显示高亮';
      hint = hint == null ? warn : '$hint\n$warn';
    }
    int newPos = 0;
    if (matches.isNotEmpty && diff != null) {
      final mode = ref.read(viewModeProvider);
      final topRow = _currentTopRow();
      if (topRow != null) {
        final map = _entryToRowMapOf(diff, mode);
        for (var i = 0; i < matches.length; i++) {
          final r = map[matches[i]];
          if (r != null && r >= topRow) {
            newPos = i;
            break;
          }
        }
      }
    }

    setState(() {
      _matchEntries = matches;
      _matchPos = matches.isEmpty ? -1 : newPos;
      _noResultHint = _findWarning ?? hint;
if (_noResultHint == null &&
    q.isNotEmpty &&
    (_regexEnable || _caseInsensitive || _wholeWord)) {
  _noResultHint = '高级搜索已开，搜索结果暂不支持显示高亮';
}
    });
    if (autoScroll && matches.isNotEmpty) {
      _scrollToEntry(matches[newPos]);
    }
  }

  void _ensureFindApplied() {
    _findDebounce?.cancel();
    if (_scannedQuery != _findController.text) {
      _findChanged(_findController.text, autoScroll: false);
    }
  }

  void _recordFindHistory() {
    final q = _findController.text;
    if (q.trim().isEmpty) return;
    ref.read(findHistoryProvider.notifier).add(q);
  }

  Future<void> _showFindHistory() async {
    await showDialog<void>(
      context: context,
      builder: (_) => FindHistoryDialog(
        onPick: (q) {
          _findController.text = q;
          setState(() => _findQuery = q);
        },
      ),
    );
  }

  // ==================== 替换 ====================

  void _replaceCurrentInline() {
    _ensureFindApplied();
    _recordFindHistory();
    if (_findQuery.isEmpty) {
      _toast('请先输入查找内容');
      return;
    }
    final hint = _diagnoseReplace();
    if (hint != null) {
      setState(() => _replaceHint = hint);
      _toast(hint);
      return;
    }
    if (_matchEntries.isEmpty || _matchPos < 0) {
      _toast('没有可替换的内容');
      return;
    }
    _doReplace(replacement: _replaceController.text, all: false);
  }

  void _replaceAllInline() {
    _ensureFindApplied();
    _recordFindHistory();
    if (_findQuery.isEmpty) {
      _toast('请先输入查找内容');
      return;
    }
    final hint = _diagnoseReplace();
    if (hint != null) {
      setState(() => _replaceHint = hint);
      _toast(hint);
      return;
    }
    if (_matchEntries.isEmpty) {
      _toast('没有可替换的内容');
      return;
    }
    _doReplace(replacement: _replaceController.text, all: true);
  }

  void _doReplace({required String replacement, required bool all}) {
    final diff = _diff;
    if (diff == null) return;

    final targets = all
        ? _matchEntries
        : (_matchPos >= 0 && _matchPos < _matchEntries.length
            ? <int>[_matchEntries[_matchPos]]
            : const <int>[]);
    if (targets.isEmpty) {
      _toast('没有可替换的内容');
      return;
    }

    final meta = _computeLineMeta(diff);
    final p = _buildFindPattern();
    var count = 0;

    for (final ei in targets) {
      final e = diff.entries[ei];

      if (_entryMatchesOnLeft(e) && meta[ei].orig >= 0) {
        final origLine = meta[ei].orig;
        final current = _pendingOrigChanges[origLine] ?? _entryLeftText(e);
        if (p.allMatches(current).isNotEmpty) {
          _pendingOrigChanges[origLine] = _applyReplace(current, replacement);
          count++;
        }
      }

      if (_entryMatchesOnRight(e) && meta[ei].mod >= 0) {
        final modLine = meta[ei].mod;
        final current = _pendingModChanges[modLine] ?? _entryRightText(e);
        if (p.allMatches(current).isNotEmpty) {
          _pendingModChanges[modLine] = _applyReplace(current, replacement);
          count++;
        }
      }
    }

    if (count == 0) {
      _toast('没有可替换的内容');
      return;
    }

    setState(() {});
    _toast('已加入待应用队列（$count 处）· 点"应用并刷新"生效');
  }

  void _applyPendingChanges() {
    if (_pendingOrigChanges.isEmpty && _pendingModChanges.isEmpty) return;

    _applyRawChanges(isOriginal: true, changes: _pendingOrigChanges);
    _applyRawChanges(isOriginal: false, changes: _pendingModChanges);
    _pendingOrigChanges.clear();
    _pendingModChanges.clear();
    _rememberCurrentRowForReset();
    _log('应用替换（重算中）');
    ref.read(importRevisionProvider.notifier).state++;
    _resetViewAfterEdit();
    _toast('已应用替换');
  }

  void _applyRawChanges({
    required bool isOriginal,
    required Map<int, String> changes,
  }) {
    if (changes.isEmpty) return;

    final current = ref.read(
      isOriginal ? preprocessedOriginalProvider : preprocessedModifiedProvider,
    );
    if (current.isEmpty) return;

    final lines = current.split('\n');
    for (final entry in changes.entries) {
      final lineNo = entry.key;
      if (lineNo < 0 || lineNo >= lines.length) continue;
      lines[lineNo] = entry.value;
    }
    final newProcessed = lines.join('\n');

    if (isOriginal) {
      ref.read(editedOriginalProvider.notifier).state = newProcessed;
    } else {
      ref.read(editedModifiedProvider.notifier).state = newProcessed;
    }
  }

  Future<void> _closeFindBar() async {
    if (_pendingOrigChanges.isNotEmpty || _pendingModChanges.isNotEmpty) {
      if (!mounted) return;
      final n = _pendingOrigChanges.length + _pendingModChanges.length;
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('有未应用的替换'),
          content: Text('有 $n 处修改还没应用，怎么处理？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, 'cancel'),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, 'discard'),
              child: const Text('放弃'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, 'apply'),
              child: const Text('应用并关闭'),
            ),
          ],
        ),
      );
      if (choice == 'cancel' || choice == null) return;
      if (choice == 'apply') {
        _applyPendingChanges();
      } else {
        _pendingOrigChanges.clear();
        _pendingModChanges.clear();
      }
    }

    if (!mounted) return;
    if (ref.read(viewModeProvider) == ViewMode.grouped) {
      (_groupedKey.currentState as dynamic)?.clearFind();
    }
    _findDebounce?.cancel();
    _findController.clear();
    _replaceController.clear();
    setState(() {
      _showFind = false;
      _findQuery = '';
      _scannedQuery = '';
      _matchEntries = const [];
      _matchPos = -1;
      _noResultHint = null;
      _findWarning = null;
      _replaceHint = null;
      _regexErrorHint = null;
    });
  }

  // ==================== 行数 / 行映射 ====================

  Map<int, int> _entryToRowMapOf(DiffResult diff, ViewMode mode) {
    if (identical(_entryToRowMapFor, diff) &&
        _entryToRowMapMode == mode &&
        _entryToRowMap != null) {
      return _entryToRowMap!;
    }
    final map = <int, int>{};
    if (mode == ViewMode.merged) {
      final order = cachedMergedOrder(diff);
      for (var r = 0; r < order.length; r++) {
        map[order[r]] = r;
      }
    } else if (mode == ViewMode.sideBySide) {
      final rows = cachedAlignedRows(diff);
      for (var r = 0; r < rows.length; r++) {
        final spec = rows[r];
        if (spec.del != null) map.putIfAbsent(spec.del!, () => r);
        if (spec.ins != null) map.putIfAbsent(spec.ins!, () => r);
      }
    } else if (mode == ViewMode.diffOnlyPlain) {
      final rows = cachedDiffOnlyPlainRows(diff);
      for (var r = 0; r < rows.length; r++) {
        final spec = rows[r];
        if (spec.del != null) map.putIfAbsent(spec.del!, () => r);
        if (spec.ins != null) map.putIfAbsent(spec.ins!, () => r);
      }
    } else if (mode == ViewMode.diffOnly) {
      final rows = cachedDiffOnlyRows(diff);
      for (var r = 0; r < rows.length; r++) {
        final spec = rows[r];
        if (spec.del != null) map.putIfAbsent(spec.del!, () => r);
        if (spec.ins != null) map.putIfAbsent(spec.ins!, () => r);
      }
    }
    _entryToRowMap = map;
    _entryToRowMapFor = diff;
    _entryToRowMapMode = mode;
    return map;
  }

  // ==================== 高度表：懒加载 + 后台补精确 ====================

void _startHeightComputation(DiffResult diff, ViewMode mode) {
  if (mode == ViewMode.grouped) return;
  CrashLogger.instance.mark('启动高度计算: ${mode.name}');
  CrashTrace.mark('启动高度计算: ${mode.name}');
  // 预热点一次，正式 build 时会命中同一个 Future 对象。
  _getHeightFuture(diff, mode);
}

  Future<_HeightBundle> _getHeightFuture(DiffResult diff, ViewMode mode) {
    if (mode == ViewMode.grouped) return _emptyHeightFuture;

    final mq = MediaQuery.of(context);
    final configKey = '${mq.size.width}|'
        '${ref.read(bodyFontSizeProvider)}|'
        '${ref.read(contextFontSizeProvider)}|'
        '${ref.read(gutterFontSizeProvider)}|'
        '${ref.read(noWrapProvider)}|'
        '${ref.read(showLineNumbersProvider)}|'
        '${ref.read(importRevisionProvider)}';

    if (!identical(_heightFuturesFor, diff) ||
        _heightFuturesConfigKey != configKey) {
      _heightFutures.clear();
      _heightExactResults.clear();
      _completedHeightModes.clear();
      _heightFuturesFor = diff;
      _heightFuturesConfigKey = configKey;
    }

    // ★ 关键：命中的是同一个 Future 对象，FutureBuilder 不会认为它变了。
    // 不在这里再包 catchError，否则每次返回新 Future，视图反复重建。
    final existing = _heightFutures[mode];
    if (existing != null) return existing;

    // 首次计算：catchError 只包一次，把降级后的 Future 存起来。
    final f = _computeHeightBundle(diff, mode)
        .catchError((Object e, StackTrace st) {
      debugPrint('高度表计算失败(降级估算): $e\n$st');
      return _getQuickBundle(diff, mode);
    });

    f.then((exact) {
      if (!mounted) return;
      if (!identical(_heightFuturesFor, diff)) return;
      _completedHeightModes.add(mode);
      _heightExactResults[mode] = exact;
      // 内存保护：本会话最多驻留最近 2 个模式的精确表。
      // 旧的丢掉也没关系——全局 LineHeightCache 里还有，重进秒取。
      while (_heightExactResults.length > 2) {
        _heightExactResults.remove(_heightExactResults.keys.first);
      }
      if (ref.read(viewModeProvider) == mode && _activeHeights != exact) {
        ViewerDiag.mark('精确高度表就绪 (${mode.name})');
        _log('精确高度表就绪: ${mode.name}');
        setState(() => _activeHeights = exact);
      }
    });

    _heightFutures[mode] = f;
    return f;
  }

  _HeightBundle _getQuickBundle(DiffResult diff, ViewMode mode) {
    if (mode == ViewMode.grouped) return const _HeightBundle();

    final cached = _heightExactResults[mode];
    if (cached != null) return cached;

    final fs = ref.read(bodyFontSizeProvider);
    final h = fs * 1.5 * 1.5 + 10;

    int rows;
    switch (mode) {
      case ViewMode.merged:
        rows = cachedMergedOrder(diff).length;
      case ViewMode.sideBySide:
        rows = cachedAlignedRows(diff).length;
      case ViewMode.diffOnly:
        rows = cachedDiffOnlyRows(diff).length;
      case ViewMode.diffOnlyPlain:
        rows = cachedDiffOnlyPlainRows(diff).length;
      case ViewMode.grouped:
        return const _HeightBundle();
    }

    final table = LineHeightTable.fromHeights(List<double>.filled(rows, h));
    return switch (mode) {
      ViewMode.merged => _HeightBundle(merged: table),
      ViewMode.sideBySide => _HeightBundle(sbsSync: table),
      ViewMode.diffOnly => _HeightBundle(diffOnly: table),
      ViewMode.diffOnlyPlain => _HeightBundle(diffOnlyPlain: table),
      ViewMode.grouped => const _HeightBundle(),
    };
  }

 Future<_HeightBundle> _computeHeightBundle(
  DiffResult diff,
  ViewMode mode,
) async {
  CrashLogger.instance.mark('开始算高度表: ${mode.name}');
  CrashTrace.mark('开始算高度表: ${mode.name}');
  ViewerDiag.mark('高度: 开始 (${mode.name})');
  _log('开始计算高度: ${mode.name}');

  final mq = MediaQuery.of(context);
  final viewportW = mq.size.width;
  final dpr = mq.devicePixelRatio;
  final scaler = mq.textScaler;

  final noWrap = ref.read(noWrapProvider);
  final showLine = ref.read(showLineNumbersProvider);
  final bodySize = ref.read(bodyFontSizeProvider);
  final style = TextStyle(fontSize: bodySize, height: 1.5);

  final fp = contentFingerprint(
    ref.read(originalRawTextProvider) ?? '',
    ref.read(modifiedRawTextProvider) ?? '',
  );
  final rev = ref.read(importRevisionProvider);

  String cacheKey(String name) {
    final base = buildLineHeightCacheKey(
      contentFingerprint: fp,
      importRevision: rev,
      viewModeName: name,
      viewportWidth: viewportW,
      bodyFontSize: bodySize,
      showLineNumbers: showLine,
      noWrap: noWrap,
      devicePixelRatio: dpr,
      textScaleFactor: scaler.scale(16.0),
    );
    final ctxFs = ref.read(contextFontSizeProvider);
    final gutterFs = ref.read(gutterFontSizeProvider);
    return '$base|ctx:$ctxFs|gut:$gutterFs';
  }

  if (mode == ViewMode.merged) {
    final order = cachedMergedOrder(diff);
    final rowW = showLine ? viewportW - 50.0 : viewportW - 16.0;
    final k = cacheKey('merged');
    final cached = LineHeightCache.instance.get(k);
    if (cached != null && cached.length == order.length) {
      CrashLogger.instance.mark('高度表命中缓存: merged');
      CrashTrace.mark('高度表命中缓存: merged');
      ViewerDiag.mark('高度: 完成(命中缓存) (${mode.name})');
      _log('高度完成(缓存): ${mode.name}');
      return _HeightBundle(merged: cached);
    }
    final table = await computeLineHeights(
      itemCount: order.length,
      widthForItem: (_) => rowW,
      textForItem: (i) {
        final e = diff.entries[order[i]];
        if (e.operation == DiffOperation.replace) {
          final a = clipLineForDisplay(e.oldText.isEmpty ? e.text : e.oldText);
          final b = clipLineForDisplay(e.newText.isEmpty ? e.text : e.newText);
          return a.length >= b.length ? a : b;
        }
        return clipLineForDisplay(e.text);
      },
      style: style,
      textScaler: scaler,
      noWrap: noWrap,
      extraVerticalPadding: 12, // 原 10，加 2px 缓冲，绝对不裁
    );
    LineHeightCache.instance.put(k, table);
    CrashLogger.instance.mark('高度表完成: merged (${order.length}行)');
    CrashTrace.mark('高度表完成: merged (${order.length}行)');
    ViewerDiag.mark('高度: 完成 (${mode.name})');
    _log('高度完成: ${mode.name}');
    return _HeightBundle(merged: table);
  }

  if (mode == ViewMode.sideBySide) {
    final rows = cachedAlignedRows(diff);
    final panelW = (viewportW - 1) / 2;
    final contentW = panelW - 52.0;
    final k = cacheKey('sbs_sync');
    final cached = LineHeightCache.instance.get(k);
    if (cached != null && cached.length == rows.length) {
      CrashLogger.instance.mark('高度表命中缓存: sbs');
      CrashTrace.mark('高度表命中缓存: sbs');
      ViewerDiag.mark('高度: 完成(命中缓存) (${mode.name})');
      _log('高度完成(缓存): ${mode.name}');
      return _HeightBundle(sbsSync: cached);
    }
    final table = await computeLineHeightsForTwoPane(
      itemCount: rows.length,
      leftWidth: contentW,
      rightWidth: contentW,
      leftTextForItem: (i) {
        final spec = rows[i];
        if (spec.del != null) {
          return clipLineForDisplay(diff.entries[spec.del!].text);
        }
        return '';
      },
      rightTextForItem: (i) {
        final spec = rows[i];
        if (spec.ins != null) {
          return clipLineForDisplay(diff.entries[spec.ins!].text);
        }
        return '';
      },
      style: style,
      textScaler: scaler,
      noWrap: noWrap,
      extraVerticalPadding: 14, // 原 12，加 2px 缓冲
    );
    LineHeightCache.instance.put(k, table);
    CrashLogger.instance.mark('高度表完成: sbs (${rows.length}行)');
    CrashTrace.mark('高度表完成: sbs (${rows.length}行)');
    ViewerDiag.mark('高度: 完成 (${mode.name})');
    _log('高度完成: ${mode.name}');
    return _HeightBundle(sbsSync: table);
  }

  final isPlain = mode == ViewMode.diffOnlyPlain;
  final rows =
      isPlain ? cachedDiffOnlyPlainRows(diff) : cachedDiffOnlyRows(diff);
  final panelW = (viewportW - 1) / 2;
  final contentW = panelW - 44.0;
  final k = cacheKey(isPlain ? 'diff_only_plain' : 'diff_only');
  final cached = LineHeightCache.instance.get(k);
  if (cached != null && cached.length == rows.length) {
    CrashLogger.instance.mark('高度表命中缓存: diffOnly');
    CrashTrace.mark('高度表命中缓存: diffOnly');
    ViewerDiag.mark('高度: 完成(命中缓存) (${mode.name})');
    _log('高度完成(缓存): ${mode.name}');
    return isPlain
        ? _HeightBundle(diffOnlyPlain: cached)
        : _HeightBundle(diffOnly: cached);
  }

  final bool needContextOverride = !isPlain;

  bool isContextRow(int i) {
    if (i < 0 || i >= rows.length) return false;
    final spec = rows[i];
    return spec.ins == null &&
        spec.del != null &&
        diff.entries[spec.del!].operation == DiffOperation.equal;
  }

  final ctxSize = ref.read(contextFontSizeProvider);
  final contextStyle = TextStyle(
    fontSize: ctxSize,
    height: 1.5,
  );

  final table = await computeLineHeightsForTwoPane(
    itemCount: rows.length,
    leftWidth: contentW,
    rightWidth: contentW,
    leftTextForItem: (i) {
      final spec = rows[i];
      if (spec.del != null) {
        final e = diff.entries[spec.del!];
        if (e.operation == DiffOperation.replace && e.oldText.isNotEmpty) {
          return clipLineForDisplay(e.oldText);
        }
        return clipLineForDisplay(e.text);
      }
      return '';
    },
    rightTextForItem: (i) {
      final spec = rows[i];
      if (spec.ins != null) {
        final e = diff.entries[spec.ins!];
        if (e.operation == DiffOperation.replace && e.newText.isNotEmpty) {
          return clipLineForDisplay(e.newText);
        }
        return clipLineForDisplay(e.text);
      }
      return '';
    },
    style: style,
    textScaler: scaler,
    noWrap: noWrap,
    extraVerticalPadding: 8,
    styleForItem: needContextOverride
        ? (i) => isContextRow(i) ? contextStyle : null
        : null,
    noWrapForItem: needContextOverride
        ? (i) => isContextRow(i) ? true : noWrap
        : null,
  );
  LineHeightCache.instance.put(k, table);
  CrashLogger.instance.mark(
      '高度表完成: ${isPlain ? "diffOnlyPlain" : "diffOnly"} (${rows.length}行)');
  CrashTrace.mark(
      '高度表完成: ${isPlain ? "diffOnlyPlain" : "diffOnly"} (${rows.length}行)');
  ViewerDiag.mark('高度: 完成 (${mode.name})');
  _log('高度完成: ${mode.name}');
  return isPlain
      ? _HeightBundle(diffOnlyPlain: table)
      : _HeightBundle(diffOnly: table);
}

  LineHeightTable? _activeTableFor(ViewMode mode) {
    final h = _activeHeights;
    if (h == null) return null;
    switch (mode) {
      case ViewMode.merged:
        return h.merged;
      case ViewMode.sideBySide:
        return h.sbsSync ?? h.sbsLeft;
      case ViewMode.diffOnly:
        return h.diffOnly;
      case ViewMode.diffOnlyPlain:
        return h.diffOnlyPlain;
      case ViewMode.grouped:
        return null;
    }
  }

  LineHeightTable? _tableOf(_HeightBundle? h, ViewMode mode) {
    if (h == null) return null;
    switch (mode) {
      case ViewMode.merged:
        return h.merged;
      case ViewMode.sideBySide:
        return h.sbsSync ?? h.sbsLeft;
      case ViewMode.diffOnly:
        return h.diffOnly;
      case ViewMode.diffOnlyPlain:
        return h.diffOnlyPlain;
      case ViewMode.grouped:
        return null;
    }
  }

  // ==================== 滚动 / 跳转 ====================

  int? _findEntryByOrigLine(DiffResult diff, int origLine) {
    final mode = ref.read(viewModeProvider);
    final visible = _visibleEntriesFor(mode, diff);
    final meta = _computeLineMeta(diff);
    int? best;
    var bestDist = 1 << 30;
    for (final i in visible) {
      final o = meta[i].orig;
      if (o < 0) continue;
      final d = (o - origLine).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  void _scrollToEntry(int entryIndex) {
    final diff = _diff;
    if (diff == null) {
      _log('_scrollToEntry($entryIndex): 中断 diff==null');
      return;
    }
    final mode = ref.read(viewModeProvider);
    final table = _activeTableFor(mode);
    if (table == null) {
      _log('_scrollToEntry($entryIndex): 中断 table==null');
      return;
    }
    if (!_scrollController.hasClients) {
      _log('_scrollToEntry($entryIndex): 中断 noClients');
      return;
    }

    final map = _entryToRowMapOf(diff, mode);
    final row = map[entryIndex];
    if (row == null) {
      _log('_scrollToEntry($entryIndex): 中断 row==null');
      return;
    }

    final pos = _scrollController.position;
    final offset = table.offsetOf(row);
    final max = pos.maxScrollExtent;
    final viewport = pos.viewportDimension;
    final current = pos.pixels;
    final rowHeight = table.heightOf(row);

    // 目标行已经完整可见时不要再滚：否则明明就在眼前，点一下整页翻走，
    // 用户会以为「跳错地方」。不可见时把它放到视口上方约 1/4 处，
    // 比贴在屏幕最顶端更容易看清。
    final alreadyVisible = offset >= current - 0.5 &&
        offset + rowHeight <= current + viewport + 0.5;
    if (!alreadyVisible) {
      final target =
          (offset - viewport * 0.25).clamp(0.0, max).toDouble();
      _log('_scrollToEntry($entryIndex): row=$row offset=$offset max=$max target=$target');
      _scrollController.jumpTo(target);
    } else {
      _log('_scrollToEntry($entryIndex): row=$row 已在视口内，不滚动');
    }

    if (_jumpedToEntry != entryIndex) {
      setState(() => _jumpedToEntry = entryIndex);
    }
  }

  void _nextMatch() {
    _ensureFindApplied();
    _recordFindHistory();
    if (_findQuery.isEmpty) {
      _toast('请先输入查找内容');
      return;
    }
    if (_matchEntries.isEmpty) {
      _toast('没有找到「$_findQuery」');
      return;
    }
   final next = (_matchPos + 1) % _matchEntries.length;
setState(() => _matchPos = next);

bool jumped = true;
if (ref.read(viewModeProvider) == ViewMode.grouped) {
  jumped = (_groupedKey.currentState as dynamic)
          ?.scrollToEntry(_matchEntries[next]) as bool? ??
      false;
} else {
  _scrollToEntry(_matchEntries[next]);
}

if (!jumped) {
  _toast('这处在折叠的相同行里，点下一个继续');
} else if (_matchEntries.length > 1 &&
    next == _matchEntries.length - 1) {
  _toast('已经是最后一个结果，再点回到第一个');
}
    }

  void _prevMatch() {
    _ensureFindApplied();
    _recordFindHistory();
    if (_findQuery.isEmpty) {
      _toast('请先输入查找内容');
      return;
    }
    if (_matchEntries.isEmpty) {
      _toast('没有找到「$_findQuery」');
      return;
    }
    final prev = (_matchPos - 1 + _matchEntries.length) % _matchEntries.length;
setState(() => _matchPos = prev);

bool jumped = true;
if (ref.read(viewModeProvider) == ViewMode.grouped) {
  jumped = (_groupedKey.currentState as dynamic)
          ?.scrollToEntry(_matchEntries[prev]) as bool? ??
      false;
} else {
  _scrollToEntry(_matchEntries[prev]);
}

if (!jumped) {
  _toast('这处在折叠的相同行里，点上一个继续');
} else if (_matchEntries.length > 1 && prev == 0) {
  _toast('已经是第一个结果，再点回到最后一个');
}
  }

  void _openEdit() {
    // 迷你编辑器开着时，先拦截：避免「两个编辑器同时改同一份文件」的混乱。
    if (_miniEditorOpen) {
      _toast('请先关闭迷你编辑器，再打开编辑');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const EditScreen()),
    );
  }

  void _openRegexHelp() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RegexHelpScreen()),
    );
  }

  void _openDiagnostic() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DiagnosticScreen()),
    );
  }

  List<int> _diffIndices() {
    final diff = _diff;
    if (diff == null) return const <int>[];
    if (identical(_cachedDiffIndicesFor, diff) && _cachedDiffIndices != null) {
      return _cachedDiffIndices!;
    }
    final list = <int>[];
    var inBlock = false;
    for (var i = 0; i < diff.entries.length; i++) {
      final isDiff = diff.entries[i].operation != DiffOperation.equal;
      if (isDiff && !inBlock) {
        list.add(i);
        inBlock = true;
      } else if (!isDiff) {
        inBlock = false;
      }
    }
    _cachedDiffIndices = list;
    _cachedDiffIndicesFor = diff;
    return list;
  }

  int _diffBlockCount(DiffResult diff) {
    var count = 0;
    var inBlock = false;
    for (final e in diff.entries) {
      final isDiff = e.operation != DiffOperation.equal;
      if (isDiff && !inBlock) {
        count++;
        inBlock = true;
      } else if (!isDiff) {
        inBlock = false;
      }
    }
    return count;
  }

  int? _currentTopRow() {
    final diff = _diff;
    if (diff == null) return null;
    final mode = ref.read(viewModeProvider);
    final table = _activeTableFor(mode);
    if (table == null) return null;
    if (!_scrollController.hasClients) return null;
    return table.indexAt(_scrollController.position.pixels);
  }

  Future<void> _jumpToDocTop() async {
  CrashLogger.instance.mark('跳到文首');
  if (!_scrollController.hasClients) return;
  if (_jumping) return;

  setState(() {
    _jumping = true;
    _jumpDirection = JumpDirection.up;
  });
  await WidgetsBinding.instance.endOfFrame;

  var stableFrames = 0;
  for (var step = 0; step < 3000; step++) {
    if (!mounted || !_scrollController.hasClients) break;
    final p = _scrollController.position;

    if (p.pixels <= 0.5) {
      stableFrames++;
      if (stableFrames >= 3) break;
    } else {
      stableFrames = 0;
      final next = (p.pixels - p.viewportDimension * 30)
          .clamp(0.0, p.maxScrollExtent);
      if ((p.pixels - next).abs() < 0.5) {
        _scrollController.jumpTo(0);
      } else {
        _scrollController.jumpTo(next);
      }
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  if (mounted && _scrollController.hasClients) {
    if (_scrollController.position.pixels > 0.5) {
      _scrollController.jumpTo(0);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  if (!mounted) return;
  setState(() => _jumping = false);
}

  Future<void> _jumpToDocBottom() async {
  CrashLogger.instance.mark('跳到文末');
  if (!_scrollController.hasClients) return;
  if (_jumping) return;

  setState(() {
    _jumping = true;
    _jumpDirection = JumpDirection.down;
  });
  await WidgetsBinding.instance.endOfFrame;

  var stableFrames = 0;
  for (var step = 0; step < 3000; step++) {
    if (!mounted || !_scrollController.hasClients) break;
    final p = _scrollController.position;

    if (p.pixels >= p.maxScrollExtent - 0.5) {
      stableFrames++;
      if (stableFrames >= 3) break;
    } else {
      stableFrames = 0;
      final next = (p.pixels + p.viewportDimension * 30)
          .clamp(0.0, p.maxScrollExtent);
      if ((next - p.pixels).abs() < 0.5) {
        _scrollController.jumpTo(p.maxScrollExtent);
      } else {
        _scrollController.jumpTo(next);
      }
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  if (mounted && _scrollController.hasClients) {
    final p = _scrollController.position;
    if (p.pixels < p.maxScrollExtent - 0.5) {
      _scrollController.jumpTo(p.maxScrollExtent);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  if (!mounted) return;
  setState(() => _jumping = false);
}

  void _onTabScroll() {
    if (!mounted) return;
    if (!_tabScrollController.hasClients) return;
    final pos = _tabScrollController.position;
    final atEnd = pos.pixels >= pos.maxScrollExtent - 1;
    if (atEnd != _tabAtEnd) {
      setState(() => _tabAtEnd = atEnd);
    }
  }

  void _scrollTabsToEnd() {
    if (!_tabScrollController.hasClients) return;
    _tabScrollController.animateTo(
      _tabScrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _pageDown() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final target = (pos.pixels + pos.viewportDimension * 0.95)
        .clamp(0.0, pos.maxScrollExtent);
    if ((target - pos.pixels).abs() < 0.5) return;
    _scrollController.jumpTo(target);
  }

  void _pageUp() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final target = (pos.pixels - pos.viewportDimension * 0.95)
        .clamp(0.0, pos.maxScrollExtent);
    if ((target - pos.pixels).abs() < 0.5) return;
    _scrollController.jumpTo(target);
  }

 void _jumpToNextDiff() {
  CrashLogger.instance.mark('跳到下一处差异');
  final diff = _diff;
  if (diff == null) return;
    final mode = ref.read(viewModeProvider);
    final map = _entryToRowMapOf(diff, mode);
    final currentRow = _currentTopRow();
    if (currentRow == null) return;

    final indices = _diffIndices();
    if (indices.isEmpty) return;

    for (final ei in indices) {
      final r = map[ei];
      if (r != null && r > currentRow) {
        _log('跳转: 下一处差异');
        _scrollToEntry(ei);
        return;
      }
    }
    _toast('到底了');
  }

 void _jumpToPrevDiff() {
  CrashLogger.instance.mark('跳到上一处差异');
  final diff = _diff;
  if (diff == null) return;
    final mode = ref.read(viewModeProvider);
    final map = _entryToRowMapOf(diff, mode);
    final currentRow = _currentTopRow();
    if (currentRow == null) return;

    final indices = _diffIndices();
    if (indices.isEmpty) return;

    for (var i = indices.length - 1; i >= 0; i--) {
      final ei = indices[i];
      final r = map[ei];
      if (r != null && r < currentRow) {
        _log('跳转: 上一处差异');
        _scrollToEntry(ei);
        return;
      }
    }
    _toast('到顶了');
  }

  // ==================== 切视图 ====================

  // ── T7：视图 tab 动效 ──────────────────────────────────────
  // 三条曲线共用同一个 700ms controller：前 60% 指示条滑到位并轻过冲，
  // 前 35% 文字颜色完成渐变，整段文字做三次衰减余震。
  // 只重绘 40px 高的 tab 条，不参与正文列表与切视图遮罩的重建。

  /// 指示条位移：easeOutBack，过冲约 5% 后收住；0.60 之后恒为 1。
  static double _tabSlideCurve(double t) {
    var u = t / 0.60;
    if (u < 0.0) u = 0.0;
    if (u > 1.0) u = 1.0;
    const c1 = 1.2;
    const c3 = c1 + 1.0;
    final x = u - 1.0;
    return 1.0 + c3 * x * x * x + c1 * x * x;
  }

  /// 文字颜色渐变进度：前 35% 完成。
  static double _tabFadeCurve(double t) {
    final v = t / 0.35;
    return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
  }

  /// 文字 Q 弹：先缩一下，再鼓-缩-鼓三次衰减（J1 弹簧手感）。
  static double _tabJellyScale(double t) {
    if (t <= 0.0 || t >= 1.0) return 1.0;
    final env = (1.0 - math.exp(-38.0 * t)) * math.exp(-3.0 * t);
    return 1.0 - 0.12 * math.cos(t * 3.2 * math.pi) * env;
  }

  /// 在「真正切换」那一刻启动动效；选择对话框确认前不启动。
  void _startTabAnimation(ViewMode from, ViewMode to) {
    final geom = _tabGeometry;
    if (from == to || geom == null) return;
    final a = geom[from];
    final b = geom[to];
    if (a == null || b == null) return;
    final wasAnimating = _tabAnimController.isAnimating;
    _tabFromMode = from;
    _tabToMode = to;
    // 连点时从当前显示位置接着滑；静止时从准确几何起点出发，
    // 避免屏幕旋转 / 宽度变化后残留旧坐标系的数值。
    _tabFromLeft = (wasAnimating ? _tabDisplayLeft : null) ?? a.left;
    _tabFromWidth = (wasAnimating ? _tabDisplayWidth : null) ?? a.width;
    _tabDisplayLeft = null;
    _tabDisplayWidth = null;
    _tabAnimController
      ..reset()
      ..forward();
  }

  /// 5 个 tab + 一根独立指示条。宽度由 unitW × flex 直接算出，
  /// 指示条和 Row 在同一坐标系里，横向滚动时会一起滚，不用测量。
  Widget _buildAnimatedTabStrip({
    required List<ViewMode> order,
    required Map<ViewMode, double> tabFlex,
    required double unitW,
    required ViewMode current,
  }) {
    final s = Theme.of(context).colorScheme;
    final t = _tabAnimController.value;

    final geom = <ViewMode, _TabGeom>{};
    var x = 0.0;
    for (final m in order) {
      final w = unitW * (tabFlex[m] ?? 1.0);
      geom[m] = _TabGeom(x, w);
      x += w;
    }
    _tabGeometry = geom;

    final target = geom[current] ?? const _TabGeom(0.0, 0.0);
    final fromLeft = _tabFromLeft ?? target.left;
    final fromWidth = _tabFromWidth ?? target.width;
    final slide = _tabSlideCurve(t);
    final left = fromLeft + (target.left - fromLeft) * slide;
    final width = fromWidth + (target.width - fromWidth) * slide;
    _tabDisplayLeft = left;
    _tabDisplayWidth = width;

    final animating = _tabAnimController.isAnimating;
    final fade = _tabFadeCurve(t);
    final jelly = _tabJellyScale(t);

    double selectProgress(ViewMode m) {
      if (!animating) return m == current ? 1.0 : 0.0;
      if (m == _tabFromMode && m == _tabToMode) return 1.0;
      if (m == _tabFromMode) return 1.0 - fade;
      if (m == _tabToMode) return fade;
      return 0.0;
    }

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Row(
          children: [
            for (final m in order)
              SizedBox(
                key: _tabKeys[m], // 用于自动滚到高亮
                width: unitW * (tabFlex[m] ?? 1.0),
                child: _viewChip(
                  label: _tabLabel(m),
                  value: m,
                  current: current,
                  selectProgress: selectProgress(m),
                  jellyScale: m == current ? jelly : 1.0,
                  onLongPress: m == ViewMode.grouped
                      ? _showGroupedContextMenu
                      : null,
                  trailingIcon: m == ViewMode.grouped
                      ? Icons.settings_outlined
                      : null,
                  onTrailingTap: m == ViewMode.grouped
                      ? _showGroupedContextMenu
                      : null,
                ),
              ),
          ],
        ),
        Positioned(
          left: left,
          bottom: 1,
          width: width < 0.0 ? 0.0 : width,
          height: 4,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: s.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
    );
  }

 Future<void> _switchView(ViewMode newMode) async {
  CrashLogger.instance.mark('切视图 -> ${_viewModeName(newMode)}');
  CrashTrace.mark('切视图 -> ${_viewModeName(newMode)}');
  final current = ref.read(viewModeProvider);
  if (current == newMode) return;

    if (newMode == ViewMode.grouped || current == ViewMode.grouped) {
      _log('切视图: ${_viewModeName(newMode)}');
      // 跨行块 ↔ 其它视图是直接切，不弹选择框，动效从这一刻开始。
      _startTabAnimation(current, newMode);
      ref.read(viewModeProvider.notifier).state = newMode;
      setState(() {});
      _ensureTabVisible(newMode);
      return;
    }

    // 注意：高度计算挪到对话框确认之后才启动。
    // 以前是弹对话框前就开算，大文件计算会把主线程塞满，
    // 对话框和旧画面一起冻住，用户以为死机。
    final searchEntry = _currentMatchEntry;
    final hasSearch = _findQuery.isNotEmpty && _matchEntries.isNotEmpty;

    final choice = await _showSwitchChoiceDialog(
      newMode: newMode,
      hasSearch: hasSearch,
      searchEntry: searchEntry,
    );
    if (!mounted || choice == null) return;

    final diff = _diff;
    if (diff != null) {
      _startHeightComputation(diff, newMode);
    }

    _log('切视图: ${_viewModeName(newMode)}');
    // 非跨行块视图之间切换会先弹选择对话框；动效挂在确认后真正切换这一刻，
    // 而不是点击那一刻，避免模态框把 tab 盖住时白播一遍。
    _startTabAnimation(ref.read(viewModeProvider), newMode);
    ref.read(viewModeProvider.notifier).state = newMode;
    // 就绪即走：目标高度表已算完则瞬时切换不遮罩；
    // 未就绪才遮罩，保底 600ms 跳格圆环加载动画。
    _switchOverlayUntil = _completedHeightModes.contains(newMode)
        ? null
        : DateTime.now().add(const Duration(milliseconds: 600));
    _switchOverlayTimer?.cancel();

    final target = choice.isTop ? -1 : (choice.targetEntry ?? -1);
    _pendingJumpEntry = target;
    _pendingJumpOrigLine = null;
    _pendingJumpQueued = false;
    setState(() {});
    _ensureTabVisible(newMode);
  }

  void _ensureTabVisible(ViewMode mode, {bool instant = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _tabKeys[mode]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration:
              instant ? Duration.zero : const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _tabLabel(ViewMode m) {
    switch (m) {
      case ViewMode.diffOnly:
        return '差异行+上下2行';
      case ViewMode.diffOnlyPlain:
        return '仅显示差异行';
      case ViewMode.grouped:
        return '跨行块';
      case ViewMode.merged:
        return '全文上下';
      case ViewMode.sideBySide:
        return '全文并排';
    }
  }

  String _viewModeName(ViewMode m) {
    switch (m) {
      case ViewMode.merged:
        return '全文上下合并';
      case ViewMode.sideBySide:
        return '全文左右并排';
      case ViewMode.diffOnly:
        return '差异行+上下2行';
      case ViewMode.diffOnlyPlain:
        return '仅显示差异行';
      case ViewMode.grouped:
        return '跨行块';
    }
  }

  Future<_SwitchChoice?> _showSwitchChoiceDialog({
    required ViewMode newMode,
    required bool hasSearch,
    required int? searchEntry,
  }) async {
    final modeName = _viewModeName(newMode);

    final diff = _diff;
    final mode = ref.read(viewModeProvider);
    final map = diff == null ? <int, int>{} : _entryToRowMapOf(diff, mode);
    final topRow = _currentTopRow();

    int? entryAtRowDelta(int delta) {
      if (diff == null || topRow == null || map.isEmpty) return null;
      var target = topRow + delta;
      if (target < 0) target = 0;
      int? best;
      var bestDist = 1 << 30;
      for (final e in map.entries) {
        final d = (e.value - target).abs();
        if (d < bestDist) {
          bestDist = d;
          best = e.key;
        }
      }
      return best;
    }

    final entry0 = entryAtRowDelta(0);
    final entry1 = entryAtRowDelta(1);
    final entry2 = entryAtRowDelta(2);
    final entryNeg = entryAtRowDelta(-1);

    String preview(int? entryIndex) {
      if (diff == null || entryIndex == null) return '';
      final e = diff.entries[entryIndex];
      final raw =
          (e.operation == DiffOperation.replace && e.newText.isNotEmpty)
              ? e.newText
              : e.text;
      if (raw.isEmpty) return '（空行）';
      return raw.length > 20 ? '${raw.substring(0, 20)}…' : raw;
    }

    Widget choiceTile({
      required IconData icon,
      required String title,
      required String? subtitle,
      required VoidCallback onTap,
    }) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null || subtitle.isEmpty
            ? null
            : Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
        onTap: onTap,
      );
    }

    return showDialog<_SwitchChoice>(
      context: context,
      builder: (c) {
        final children = <Widget>[];

        if (hasSearch && searchEntry != null) {
          children.add(choiceTile(
            icon: Icons.search,
            title: '跳到我搜的那个词',
            subtitle: preview(searchEntry),
            onTap: () => Navigator.pop(c, _SwitchChoice.entry(searchEntry)),
          ));
        } else {
          if (entry0 != null) {
            children.add(choiceTile(
              icon: Icons.looks_one,
              title: '停在我现在看的地方（屏幕第 1 行）',
              subtitle: preview(entry0),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entry0)),
            ));
          }
          if (entry1 != null) {
            children.add(choiceTile(
              icon: Icons.looks_two,
              title: '停在我现在看的地方（屏幕第 2 行）',
              subtitle: preview(entry1),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entry1)),
            ));
          }
          if (entry2 != null) {
            children.add(choiceTile(
              icon: Icons.looks_3,
              title: '停在我现在看的地方（屏幕第 3 行）',
              subtitle: preview(entry2),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entry2)),
            ));
          }
          if (entryNeg != null) {
            children.add(choiceTile(
              icon: Icons.expand_less,
              title: '屏幕顶部再往上一点',
              subtitle: preview(entryNeg),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entryNeg)),
            ));
          }
        }

        children.add(const Divider(height: 1));
        children.add(choiceTile(
          icon: Icons.vertical_align_top,
          title: '跳到文件最开头',
          subtitle: null,
          onTap: () => Navigator.pop(c, const _SwitchChoice.top()),
        ));

        return SimpleDialog(
          title: Text('切换到$modeName视图'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                '切换后请选择要跳转到的位置：',
                style: Theme.of(c).textTheme.bodySmall,
              ),
            ),
            ...children,
          ],
        );
      },
    );
  }

  Future<void> _showGroupedContextMenu() async {
    final current = ref.read(groupedContextLinesProvider).round();
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '跨行块视图 · 上下文行数',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            for (final n in const <int>[0, 1, 2, 3, 5, 8, 10])
              ListTile(
                leading: Icon(
                  n == 0 ? Icons.crop_square : Icons.view_agenda_outlined,
                  size: 20,
                ),
                title: Text(
                  n == 0 ? '仅显示差异块' : '上下各 $n 行相同内容',
                ),
                trailing: current == n
                    ? Icon(Icons.check,
                        color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(c, n),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(c),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    ref.read(groupedContextLinesProvider.notifier).update(picked.toDouble());
  }

  Future<void> _pickDefaultViewMode() async {
    final currentDefault = ref.read(defaultViewModeProvider);
    final currentOrder = List<ViewMode>.from(ref.read(viewModeOrderProvider));

    await showDialog<void>(
      context: context,
      builder: (c) {
        var order = currentOrder;
        var selected = currentDefault;
        return StatefulBuilder(
          builder: (c, setDialogState) => AlertDialog(
            title: const Text('默认打开视图'),
            contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(c).size.height * 0.6,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      '点选设为默认；拖右侧手柄可调整 tab 显示顺序。',
                      style: Theme.of(c).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: order.length,
                      onReorder: (oldIndex, newIndex) {
                        if (newIndex > oldIndex) newIndex--;
                        final next = List<ViewMode>.from(order);
                        final item = next.removeAt(oldIndex);
                        next.insert(newIndex, item);
                        setDialogState(() => order = next);
                      },
                      itemBuilder: (ctx, i) {
                        final m = order[i];
                        return RadioListTile<ViewMode>(
                          key: ValueKey(m.name),
                          value: m,
                          groupValue: selected,
                          title: Text(_viewModeName(m)),
                          onChanged: (v) {
                            if (v == null) return;
                            setDialogState(() => selected = v);
                          },
                          secondary: ReorderableDragStartListener(
                            index: i,
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(Icons.drag_handle),
                            ),
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
                onPressed: () {
                  setDialogState(() => order = ViewMode.values.toList());
                },
                child: const Text('恢复默认顺序'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  ref
                      .read(defaultViewModeProvider.notifier)
                      .update(selected);
                  ref.read(viewModeOrderProvider.notifier).setAll(order);
                  Navigator.pop(c);
                },
                child: const Text('保存'),
              ),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    _toast('已保存');
  }

  Future<void> _toggleOrientation() async {
    setState(() => _landscape = !_landscape);
    await SystemChrome.setPreferredOrientations(_landscape
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [DeviceOrientation.portraitUp]);
  }

  void _openDisplaySettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const DisplaySettingsSheet(),
    );
  }

  /// 手势设置：单击/长按各自选动作，并详细解释两种编辑方式的区别。
  void _openRowGestureSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const RowGestureSettingsSheet(),
    );
  }

  Future<void> _openComparisonSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const ComparisonSettingsScreen(
          confirmOnExit: true,
        ),
      ),
    );
    if (!mounted) return;
    if (changed != true) {
      _log('比较设置返回，规则未变，跳过重算');
      return;
    }
    _rememberCurrentRowForReset();

    _log('比较设置返回，规则已变，重算');
    ref.read(importRevisionProvider.notifier).state++;
    _resetViewAfterEdit();
  }

  // ==================== 导出差异 ====================

  ({List<String> left, List<String> right}) _collectDiffParts(
      DiffResult diff) {
    final leftParts = <String>[];
    final rightParts = <String>[];

    final entries = diff.entries;
    var i = 0;
    while (i < entries.length) {
      if (entries[i].operation == DiffOperation.equal) {
        i++;
        continue;
      }
      final delLines = <String>[];
      while (i < entries.length &&
          entries[i].operation == DiffOperation.delete) {
        delLines.add(entries[i].text);
        i++;
      }
      final insLines = <String>[];
      while (i < entries.length &&
          entries[i].operation == DiffOperation.insert) {
        insLines.add(entries[i].text);
        i++;
      }

      final pairs = delLines.length < insLines.length
          ? delLines.length
          : insLines.length;

      for (var k = 0; k < pairs; k++) {
        final segs =
            DiffCache.instance.charSegments(delLines[k], insLines[k]);
        for (final (op, text) in segs) {
          if (text.isEmpty) continue;
          if (op == -1) {
            leftParts.add(text);
          } else if (op == 1) {
            rightParts.add(text);
          }
        }
      }

      for (var k = pairs; k < delLines.length; k++) {
        leftParts.add(delLines[k]);
      }
      for (var k = pairs; k < insLines.length; k++) {
        rightParts.add(insLines[k]);
      }
    }

    return (left: leftParts, right: rightParts);
  }

  /// 按差异块收集整行，用于导出：连续的 delete/insert 归为一组。
  /// type: 'mod' 修改（成对）、'del' 删除（仅左侧有）、'ins' 新增（仅右侧有）。
  List<({String type, List<String> left, List<String> right})>
      _collectDiffGroups(DiffResult diff) {
    final groups =
        <({String type, List<String> left, List<String> right})>[];

    final entries = diff.entries;
    var i = 0;
    while (i < entries.length) {
      if (entries[i].operation == DiffOperation.equal) {
        i++;
        continue;
      }
      final delLines = <String>[];
      while (i < entries.length &&
          entries[i].operation == DiffOperation.delete) {
        delLines.add(entries[i].text);
        i++;
      }
      final insLines = <String>[];
      while (i < entries.length &&
          entries[i].operation == DiffOperation.insert) {
        insLines.add(entries[i].text);
        i++;
      }

      if (delLines.isEmpty && insLines.isEmpty) continue;
      groups.add((
        type: delLines.isEmpty
            ? 'ins'
            : insLines.isEmpty
                ? 'del'
                : 'mod',
        left: delLines,
        right: insLines,
      ));
    }
    return groups;
  }
Future<void> _openLineListFromDiff({required bool isLeft}) async {
  final diff = _diff;
  if (diff == null) {
    _toast('还没有差异可列出');
    return;
  }
  final parts = _collectDiffParts(diff);
  final list = isLeft ? parts.left : parts.right;
  if (list.isEmpty) {
    _toast(isLeft ? '左侧没有差异' : '右侧没有差异');
    return;
  }
  await _openLineList(appendLines: list);
}

Future<void> _openLineList({List<String>? appendLines}) async {
  if (appendLines != null && appendLines.isNotEmpty) {
    final cur = ref.read(lineListTextProvider);
    final existing = cur.isEmpty ? <String>[] : cur.split('\n');
    final existingSet = existing.where((l) => l.isNotEmpty).toSet();
    final added = <String>[];
    for (final l in appendLines) {
      if (l.isEmpty) continue;
      if (existingSet.contains(l)) continue;
      existingSet.add(l);
      added.add(l);
    }
    final merged = [...existing, ...added].join('\n');
    ref.read(lineListTextProvider.notifier).state = merged;
  }
   if (!mounted) return;
  await Navigator.of(context).push(
    PageRouteBuilder(
      pageBuilder: (_, __, ___) => const LineListPage(),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ),
  );
}
  Future<void> _exportDiff() async {
    final diff = _diff;
    if (diff == null) return;

    final groups = _collectDiffGroups(diff);
    if (groups.isEmpty) {
      _toast('没有差异可导出');
      return;
    }

    final leftName = ref.read(originalFileNameProvider);
    final rightName = ref.read(modifiedFileNameProvider);

    final buf = StringBuffer();
    buf.writeln('- ${leftName ?? "原文件"}');
    buf.writeln('+ ${rightName ?? "修改版"}');
    buf.writeln();

    for (final g in groups) {
      for (final l in g.left) {
        buf.writeln('- $l');
      }
      for (final r in g.right) {
        buf.writeln('+ $r');
      }
      buf.writeln();
    }

    final bytes = Uint8List.fromList(utf8.encode(buf.toString()));

    final out = await FilePicker.saveFile(
      fileName: 'docdiff-${DateTime.now().millisecondsSinceEpoch}.txt',
      bytes: bytes,
      mimeType: 'text/plain',
      dialogTitle: '导出差异',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (out != null && mounted) {
      _toast('差异已导出');
    }
  }

  // ==================== 长按：直接编辑 ====================

  List<({int orig, int mod})> _computeLineMeta(DiffResult result) {
    final meta = <({int orig, int mod})>[];
    var o = 0, m = 0;
    for (final e in result.entries) {
      final usesOrig = e.operation == DiffOperation.equal ||
          e.operation == DiffOperation.delete ||
          e.operation == DiffOperation.replace;
      final usesMod = e.operation == DiffOperation.equal ||
          e.operation == DiffOperation.insert ||
          e.operation == DiffOperation.replace;
      meta.add((orig: usesOrig ? o : -1, mod: usesMod ? m : -1));
      if (usesOrig) o++;
      if (usesMod) m++;
    }
    return meta;
  }

  void _replaceRawLine({
    required bool isOriginal,
    required int normalizedLine,
    required String newText,
  }) {
    final current = ref.read(
      isOriginal ? preprocessedOriginalProvider : preprocessedModifiedProvider,
    );
    if (current.isEmpty) return;

    final lines = current.split('\n');
    if (normalizedLine < 0 || normalizedLine >= lines.length) return;
    lines[normalizedLine] = newText;
    final newProcessed = lines.join('\n');

    if (isOriginal) {
      ref.read(editedOriginalProvider.notifier).state = newProcessed;
    } else {
      ref.read(editedModifiedProvider.notifier).state = newProcessed;
    }
  }

  /// 取出某条差异行在左/右两侧的文本与规范化行号。
  /// 单击（对比页内编辑）和长按（打开源文件迷你编辑器）共用这份解析。
  ({String? origText, String? modText, int? origLine, int? modLine})?
      _rowTextsOf(List<int> entryIndices) {
    final diff = _diff;
    if (diff == null || entryIndices.isEmpty) return null;

    int? origEntryIdx;
    int? modEntryIdx;
    for (final i in entryIndices) {
      final op = diff.entries[i].operation;
      if (op == DiffOperation.equal) {
        origEntryIdx ??= i;
        modEntryIdx ??= i;
      } else if (op == DiffOperation.delete ||
          op == DiffOperation.replace) {
        origEntryIdx ??= i;
      } else if (op == DiffOperation.insert) {
        modEntryIdx ??= i;
      }
    }
    if (origEntryIdx == null && modEntryIdx == null) return null;

    final meta = _computeLineMeta(diff);

    String? origText;
    String? modText;
    int? origLine;
    int? modLine;

    if (origEntryIdx != null) {
      final e = diff.entries[origEntryIdx];
      origText =
          (e.operation == DiffOperation.replace && e.oldText.isNotEmpty)
              ? e.oldText
              : e.text;
      final m = meta[origEntryIdx].orig;
      if (m >= 0) origLine = m;
    }
    if (modEntryIdx != null) {
      final e = diff.entries[modEntryIdx];
      modText =
          (e.operation == DiffOperation.replace && e.newText.isNotEmpty)
              ? e.newText
              : e.text;
      final m = meta[modEntryIdx].mod;
      if (m >= 0) modLine = m;
    }
    return (
      origText: origText,
      modText: modText,
      origLine: origLine,
      modLine: modLine,
    );
  }

  /// 单击：只在对比页里就地编辑这一行（仅改内存视图，不写磁盘）。
  Future<void> _onRowTap(List<int> entryIndices) async {
    // ★ 小窗打开时，单击下层任何行都不再弹对比页编辑框，
    //   杜绝「对比页编辑框和迷你小窗叠在一起」。
    if (_miniEditorOpen || _rowEditDialogOpen) return;
    final info = _rowTextsOf(entryIndices);
    if (info == null) return;

    _rowEditDialogOpen = true;
    try {
      final edited = await _showRowEditDialog(
        origText: info.origText,
        modText: info.modText,
      );
      if (edited == null) return;

      if (info.origLine != null && info.origText != null) {
        _replaceRawLine(
          isOriginal: true,
          normalizedLine: info.origLine!,
          newText: edited.orig,
        );
      }
      if (info.modLine != null && info.modText != null) {
        _replaceRawLine(
          isOriginal: false,
          normalizedLine: info.modLine!,
          newText: edited.mod,
        );
      }

      _log('编辑行（重算中）');
      ref.read(importRevisionProvider.notifier).state++;
      _pendingJumpEntry = null;
      _pendingJumpOrigLine = info.origLine ?? info.modLine;
      _pendingJumpQueued = false;
      _resetViewAfterEdit();
    } finally {
      _rowEditDialogOpen = false;
    }
  }

  // ---- 迷你编辑器纯文本闸门 ----
  // 小窗直接 File.readAsBytes 按文本编码读原文件；doc / docx / epub 本质是
  // 二进制压缩包，读出来是乱码，还会把乱码写进 .bak。长按入口先拦一道。

  /// 已知纯文本后缀：直接放行，不嗅探。
  static const _miniTxtAllowExts = <String>{'.txt', '.text', '.log', '.md'};

  /// 已知二进制后缀：直接拦，不嗅探。
  static const _miniTxtDenyExts = <String>{
    '.doc', '.docx', '.epub', '.pdf', '.zip', '.rar', '.7z', '.azw3', '.mobi',
    '.azw', '.fb2', '.cbz', '.cbr', '.jar', '.apk', '.png', '.jpg', '.jpeg',
    '.gif', '.mp3', '.mp4',
  };

  /// 长按打开 / 切换迷你编辑器前的格式闸门。返回 false = 已弹提示拦截。
  /// 读不到文件 / 判定不出来时按放行处理——小窗自己有加载报错兜底，
  /// 不让一个读不出的文件堵死入口。
  Future<bool> _ensureMiniEditorTxt(String path) async {
    final ext = p.extension(path).toLowerCase();
    if (_miniTxtAllowExts.contains(ext)) return true;
    if (_miniTxtDenyExts.contains(ext)) {
      _toast('${ext.substring(1)} 不是纯文本格式，迷你编辑器只支持 txt（可先转成 txt 再对比）');
      return false;
    }
    // 陌生后缀（.1 / .bak / .dat / 无后缀……）：内容嗅探，只读开头 8KB。
    try {
      final f = File(path);
      if (!await f.exists()) return true;
      final head = <int>[];
      await for (final chunk in f.openRead(0, 8192)) {
        head.addAll(chunk);
        if (head.length >= 8192) break;
      }
      if (head.isEmpty) return true;
      if (_miniHeadLooksBinary(head)) {
        _toast('这个文件不是纯文本（可能是 docx / epub 或其它二进制改了后缀），迷你编辑器只支持 txt');
        return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  /// 文件头二进制判定：只看开头一段，不做全量扫描。
  /// 顺序很重要：先放 BOM（UTF-8 / UTF-16 小窗都能认，是文本），再放
  /// 大量 0 字节（多半是无 BOM 的 UTF-16，小窗也能认），最后数控制字节。
  bool _miniHeadLooksBinary(List<int> head) {
    if (head.length < 4) return false;
    // zip 魔数 PK\x03\x04（docx / epub / zip 本体）与空 zip / 分卷变体。
    if (head[0] == 0x50 && head[1] == 0x4B) {
      final c = head.length > 2 ? head[2] : -1;
      if (c == 0x03 || c == 0x05 || c == 0x07) return true;
    }
    // OLE 复合文档魔数（老 .doc / .xls）。
    if (head[0] == 0xD0 &&
        head[1] == 0xCF &&
        head[2] == 0x11 &&
        head[3] == 0xE0) {
      return true;
    }
    // PDF 魔数 %PDF。
    if (head[0] == 0x25 && head[1] == 0x50 && head[2] == 0x44 && head[3] == 0x46) {
      return true;
    }
    // UTF-8 / UTF-16 BOM：小窗支持的文本编码，放行。
    if (head[0] == 0xEF && head[1] == 0xBB && head[2] == 0xBF) return false;
    if ((head[0] == 0xFF && head[1] == 0xFE) ||
        (head[0] == 0xFE && head[1] == 0xFF)) {
      return false;
    }
    var control = 0;
    var nul = 0;
    for (final b in head) {
      if (b == 0) nul++;
      if (b < 0x09 || (b > 0x0D && b < 0x20)) control++;
    }
    // 0 字节占三成以上：多半是无 BOM 的 UTF-16 文本，小窗能认，放行。
    if (nul / head.length > 0.3) return false;
    // 其余控制字节（不含 \t \n \r）占比超两成：二进制。
    return control / head.length > 0.20;
  }

  /// 长按：小窗未开 → 打开「整份源文件迷你编辑器」；小窗已开 → 单窗切换到
  /// 该长按行对应的文件（保留窗口位置/大小/字号，不叠加新窗）。
  Future<void> _onRowLongPress(List<int> entryIndices) async {
    if (_rowEditDialogOpen) return;
    final info = _rowTextsOf(entryIndices);
    if (info == null) return;

    // 优先编辑左栏（源文件）；右栏独有的行就编辑右栏那份文件。
    final isOriginal = info.origText != null;
    final path = ref.read(isOriginal
            ? originalFilePathProvider
            : modifiedFilePathProvider) ??
        ref.read(isOriginal
            ? originalSharedTempPathProvider
            : modifiedSharedTempPathProvider);
    if (path == null || path.isEmpty) {
      _toast('没有可用的源文件路径，无法打开迷你编辑器');
      return;
    }
    // 纯文本闸门：doc / docx / epub 等二进制格式拦在小窗外（含 .1 / .bak
    // 这类陌生后缀的内容嗅探）。
    if (!await _ensureMiniEditorTxt(path)) return;
    if (_miniEditorOpen) {
      _switchMiniEditor(path,
          isOriginal ? info.origText : info.modText, isOriginal,
          anchorLine: isOriginal ? info.origLine : info.modLine);
      return;
    }
    setState(() {
      _miniEditorPath = path;
      _miniEditorAnchor = isOriginal ? info.origText : info.modText;
      _miniEditorAnchorLine = isOriginal ? info.origLine : info.modLine;
      _miniEditorAnchorContext =
          _miniAnchorContextFor(isOriginal, _miniEditorAnchorLine);
      _miniEditorIsOriginal = isOriginal;
      _miniEditorOpen = true;
    });
  }

  /// 单窗切换：把当前迷你编辑器换到另一份文件并重新定位目标行。
  /// 若当前文件有未保存（未写 .bak）的改动，先弹「保存并切换 / 丢弃并切换 / 取消」。
  void _switchMiniEditor(String path, String? anchor, bool isOriginal,
      {int? anchorLine}) {
    if (_miniFrameKey.currentState?.isDirty ?? false) {
      _showMiniSwitchConfirm(path, anchor, isOriginal, anchorLine: anchorLine);
      return;
    }
    _doMiniSwitch(path, anchor, isOriginal, anchorLine: anchorLine);
  }

  Future<void> _showMiniSwitchConfirm(
      String path, String? anchor, bool isOriginal,
      {int? anchorLine}) async {
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false, // 只能点按钮，点背景不关
      builder: (ctx) => AlertDialog(
        title: const Text('切换到另一侧文件'),
        content: const Text('当前文件有未保存的改动，切换会丢失这些改动。\n'
            '要先把改动写入 .bak 再切换，还是直接丢弃？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存并切换'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text('丢弃并切换'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (choice == 'save') {
      // 只有写成功才切换：写失败还硬切，等于把没存上的改动直接丢掉
      // （与关闭确认框「失败不关窗、留框里重试」同一套规矩）。
      final ok = await _miniFrameKey.currentState?.saveExternal() ?? false;
      if (!mounted) return;
      if (!ok) {
        _toast('保存副本失败，先留在当前文件：'
            '${_miniFrameKey.currentState?.lastSaveError ?? '未知原因'}');
        return;
      }
      _doMiniSwitch(path, anchor, isOriginal, anchorLine: anchorLine);
    } else if (choice == 'discard') {
      _doMiniSwitch(path, anchor, isOriginal, anchorLine: anchorLine);
    }
    // 'cancel' / null → 不切换，继续在当前文件编辑
  }


  void _doMiniSwitch(String path, String? anchor, bool isOriginal,
      {int? anchorLine}) {
    if (!mounted) return;
    setState(() {
      _miniEditorPath = path;
      _miniEditorAnchor = anchor;
      _miniEditorAnchorLine = anchorLine;
      _miniEditorAnchorContext = _miniAnchorContextFor(isOriginal, anchorLine);
      _miniEditorIsOriginal = isOriginal;
    });
  }

  /// 取长按行在规范化文本里的上下文。⚠️ 规范化文本里也可能留有空行，
  /// 固定 ±2 会取到一串空行把比对架空——所以**跳过空行向外扩窗**：
  /// 向上/向下各取最多 2 条非空行（最多扩到 ±8 行，与小窗里的
  /// ctxScoreAt 同一套口径）。
  List<String>? _miniAnchorContextFor(bool isOriginal, int? line) {
    if (line == null || line < 0) return null;
    final normalized = ref.read(isOriginal
        ? preprocessedOriginalProvider
        : preprocessedModifiedProvider);
    if (normalized.isEmpty) return null;
    final lines = normalized.split('\n');
    if (line >= lines.length) return null;
    final out = <String>[lines[line]];
    for (final dir in <int>[-1, 1]) {
      var taken = 0;
      for (var d = dir; d.abs() <= 8 && taken < 2; d += dir) {
        final t = line + d;
        if (t < 0 || t >= lines.length) break;
        if (lines[t].trim().isEmpty) continue; // 空行跳过，继续向外找
        taken++;
        out.add(lines[t]);
      }
    }
    return out;
  }

  /// 只有小窗顶栏的 × 会调用这里。点背景、按返回键都不关闭。
  void _closeMiniEditor() {
    if (!mounted) return;
    setState(() {
      _miniEditorOpen = false;
      _miniEditorPath = null;
      _miniEditorAnchor = null;
      _miniEditorAnchorLine = null;
      _miniEditorAnchorContext = null;
    });
  }

  /// 已按用户要求停用：对比页比的是两份原文件，迷你编辑器改 .bak 不碰原文件，
  /// 对比页无需刷新。保留此方法仅作参考，当前不再被调用。
  Future<void> _refreshAfterMiniSave() async {
    final path = _miniEditorPath;
    final isOriginal = _miniEditorIsOriginal;
    if (path == null) return;
    try {
      final bytes = await File(path).readAsBytes();
      final parsed = await DocumentParser.parse(
        fileName: p.basename(path),
        bytes: bytes,
      );
      if (isOriginal) {
        ref.read(originalRawTextProvider.notifier).state = parsed.plainText;
        ref.read(editedOriginalProvider.notifier).state = null;
      } else {
        ref.read(modifiedRawTextProvider.notifier).state = parsed.plainText;
        ref.read(editedModifiedProvider.notifier).state = null;
      }
      ref.read(importRevisionProvider.notifier).state++;
      _toast('源文件已保存，对比内容已刷新');
    } catch (e) {
      _toast('源文件已保存，但刷新对比失败：$e');
    }
  }

  void _copyRowLine(String text) {
    if (text.isEmpty) {
      _toast('本行为空，无可复制内容');
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    _toast('已复制此行');
  }

  /// 分组视图：单击 → 对比页内行编辑（仅视图，带「复制此行」）。
  Future<void> _onGroupedLineTap(int lineIdx, bool isLeft) async {
    if (_miniEditorOpen || _rowEditDialogOpen) return;
    final current = ref.read(isLeft
        ? preprocessedOriginalProvider
        : preprocessedModifiedProvider);
    if (current.isEmpty) return;
    final lines = current.split('\n');
    if (lineIdx < 0 || lineIdx >= lines.length) return;
    final lineText = lines[lineIdx];
    if (lineText.length > kMaxDisplayLineChars) {
      await showLongLinePreview(
        context,
        title: '第 ${lineIdx + 1} 行过长，仅支持预览',
        text: lineText,
      );
      return;
    }
    _rowEditDialogOpen = true;
    try {
      final edited = await _showRowEditDialog(
        origText: isLeft ? lineText : null,
        modText: isLeft ? null : lineText,
      );
      if (edited == null) return;
      _replaceRawLine(
        isOriginal: isLeft,
        normalizedLine: lineIdx,
        newText: isLeft ? edited.orig : edited.mod,
      );
      ref.read(importRevisionProvider.notifier).state++;
      _resetViewAfterEdit();
    } finally {
      _rowEditDialogOpen = false;
    }
  }

  /// 分组视图：长按 → 打开或单窗切换整份源文件迷你编辑器。
  Future<void> _onGroupedLineLongPress(int lineIdx, bool isLeft) async {
    if (_rowEditDialogOpen) return;
    final current = ref.read(isLeft
        ? preprocessedOriginalProvider
        : preprocessedModifiedProvider);
    if (current.isEmpty) return;
    final lines = current.split('\n');
    if (lineIdx < 0 || lineIdx >= lines.length) return;
    final path = ref.read(isLeft
            ? originalFilePathProvider
            : modifiedFilePathProvider) ??
        ref.read(isLeft
            ? originalSharedTempPathProvider
            : modifiedSharedTempPathProvider);
    if (path == null || path.isEmpty) {
      _toast('没有可用的源文件路径，无法打开迷你编辑器');
      return;
    }
    // 纯文本闸门：与分组外视图同一套判断。
    if (!await _ensureMiniEditorTxt(path)) return;
    if (_miniEditorOpen) {
      _switchMiniEditor(path, lines[lineIdx], isLeft, anchorLine: lineIdx);
      return;
    }
    setState(() {
      _miniEditorPath = path;
      _miniEditorAnchor = lines[lineIdx];
      _miniEditorAnchorLine = lineIdx;
      _miniEditorAnchorContext = _miniAnchorContextFor(isLeft, lineIdx);
      _miniEditorIsOriginal = isLeft;
      _miniEditorOpen = true;
    });
  }

  Future<({String orig, String mod})?> _showRowEditDialog({
    required String? origText,
    required String? modText,
  }) async {
    final longText = (origText != null && origText.length > kMaxDisplayLineChars)
        ? origText
        : (modText != null && modText.length > kMaxDisplayLineChars)
            ? modText
            : null;
    if (longText != null) {
      await showLongLinePreview(
        context,
        title: '本行过长，仅支持预览',
        text: longText,
      );
      return null;
    }
    final origCtrl = TextEditingController(text: origText ?? '');
    final modCtrl = TextEditingController(text: modText ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => Dialog(
        // 不再全屏：占屏幕约 80% 高，更像一个编辑弹窗。
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.8,
          child: Scaffold(
          appBar: AppBar(
            title: const Text('编辑此行'),
            leading: IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消',
              onPressed: () => Navigator.pop(c, false),
            ),
            actions: [
              // 「复制此行」：复制的是当前编辑框里的内容（含刚改动的字）。
              // 左右两栏都有时给个小菜单选复制哪一边，只有一栏就直接复制。
              // 带文字，不能只留图标（用户要求）。
              if (origText != null && modText != null)
                PopupMenuButton<bool>(
                  tooltip: '复制此行',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(mainAxisSize: MainAxisSize.min, children: const [
                      Icon(Icons.copy, size: 18),
                      SizedBox(width: 4),
                      Text('复制'),
                    ]),
                  ),
                  onSelected: (isLeft) => _copyRowLine(
                    isLeft ? origCtrl.text : modCtrl.text,
                  ),
                  itemBuilder: (_) => <PopupMenuEntry<bool>>[
                    const PopupMenuItem<bool>(
                        value: true, child: Text('复制左边')),
                    const PopupMenuItem<bool>(
                        value: false, child: Text('复制右边')),
                  ],
                )
              else
                TextButton.icon(
                  onPressed: () => _copyRowLine(
                    origText != null ? origCtrl.text : modCtrl.text,
                  ),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('确定'),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (origText != null) ...[
                  const Text('左边'),
                  const SizedBox(height: 4),
                  Expanded(
                    child: TextField(
                      controller: origCtrl,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        height: 1.4,
                      ),
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: Theme.of(c).colorScheme.primary,
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  ),
                ],
                if (origText != null && modText != null)
                  const SizedBox(height: 12),
                if (modText != null) ...[
                  const Text('右边'),
                  const SizedBox(height: 4),
                  Expanded(
                    child: TextField(
                      controller: modCtrl,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        height: 1.4,
                      ),
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: Theme.of(c).colorScheme.primary,
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        ),
      ),
    );
    if (ok != true) return null;
    return (orig: origCtrl.text, mod: modCtrl.text);
  }

  void _rememberCurrentRowForReset() {
    final diff = _diff;
    if (diff == null) return;

    if (ref.read(viewModeProvider) == ViewMode.grouped) {
  final state = _groupedKey.currentState;
  final off = (state as dynamic)?.currentScrollOffset as double?;
  CrashLogger.instance.mark('[restore] 主screen 记位置 off=$off');
  if (off != null) {
    ref.read(groupedRestoreOffsetProvider.notifier).state = off;
  }
  return;
}

    final topRow = _currentTopRow();
    if (topRow == null) return;
    final mode = ref.read(viewModeProvider);
    final map = _entryToRowMapOf(diff, mode);
    int? bestEntry;
    var bestDist = 1 << 30;
    for (final e in map.entries) {
      final d = (e.value - topRow).abs();
      if (d < bestDist) {
        bestDist = d;
        bestEntry = e.key;
      }
    }
    if (bestEntry != null) {
      final meta = _computeLineMeta(diff);
      final o = meta[bestEntry].orig;
      final m = meta[bestEntry].mod;
      _pendingJumpEntry = null;
      _pendingJumpOrigLine = o >= 0 ? o : (m >= 0 ? m : null);
      _pendingJumpQueued = false;
    }
  }

  void _resetViewAfterEdit() {
    _matchEntries = const <int>[];
    _matchPos = -1;
    _noResultHint = null;
    _scannedQuery = '';
    _cachedDiffIndices = null;
    _cachedDiffIndicesFor = null;
    _entryToRowMap = null;
    _entryToRowMapFor = null;
    _entryToRowMapMode = null;
    _heightFutures.clear();
    _heightExactResults.clear();
    _completedHeightModes.clear();
    _heightFuturesFor = null;
    _heightFuturesConfigKey = null;
    _cachedContentWidth = null;
    _cachedContentWidthFor = null;
    _cachedContentWidthConfig = null;

    DiffTextIndex.invalidate();
    setState(() {});



    if (ref.read(viewModeProvider) == ViewMode.grouped) {
  // 位置已经通过 groupedRestoreOffsetProvider 传给 GroupedDiffView，
  // 它在收到新 diff 时自己恢复，不依赖 State 存活。
  _pendingGroupedRestoreOffset = null;
  _pendingJumpEntry = null;
  _pendingJumpOrigLine = null;
  _pendingJumpQueued = false;
  CrashLogger.instance.mark('[restore] 主screen reset');
  return;
}




    

    if (_pendingJumpEntry == null && _pendingJumpOrigLine == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
        if (_hScrollController.hasClients) _hScrollController.jumpTo(0);
      });
    }
  }

  void _showFloatHint(String msg) {
  if (!mounted) return;
  _floatTimer?.cancel();
  _floatEntry?.remove();
  _floatEntry = null;

  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned(
      left: 0,
      right: 0,
      top: MediaQuery.of(context).size.height * 0.35,
      child: IgnorePointer(
        child: Center(
          child: Material(
            // 固定黑底白字悬浮弹窗：不要随主题反色。
            // 原先用 inverseSurface，深色主题下会变成白底黑字；
            // 查找提示（含「这处在折叠的相同行里」）需要一致的观感。
            color: const Color(0xEE000000),
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              child: Text(
                msg,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  _floatEntry = entry;
  _floatTimer = Timer(const Duration(milliseconds: 1800), () {
    if (identical(_floatEntry, entry)) {
      entry.remove();
      _floatEntry = null;
    }
  });
}

void _toast(String msg) {
  _showFloatHint(msg);
}

  // ---------- 删除文件 ----------

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String _fmtTime(DateTime t) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<bool> _confirmDelete(String label, String? path) async {
    if (path == null) return false;
    int? size;
    DateTime? modified;
    try {
      final st = await File(path).stat();
      size = st.size;
      modified = st.modified;
    } catch (_) {}

    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除$label？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请确认以下信息，防止删错：'),
            const SizedBox(height: 8),
            Text('路径：$path', style: Theme.of(c).textTheme.bodySmall),
            if (size != null)
              Text('大小：${_fmtSize(size)}',
                  style: Theme.of(c).textTheme.bodySmall),
            if (modified != null)
              Text('修改时间：${_fmtTime(modified)}',
                  style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 12),
            Text(
              ref.read(fromDupeBoxProvider)
                  ? '将先移入与 DupeBox 共用的回收站，不会直接物理删除。'
                      '可在 DupeBox 或 docdiff 的回收站中恢复。'
                  : '将先移入回收站，不会直接物理删除。'
                      '可在 docdiff 的回收站中恢复。',
              style: TextStyle(
                color: Theme.of(c).colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteSide({required bool isOriginal}) async {
    // 迷你编辑器开着时，先拦截：删除会移除小窗正在编辑的那一侧源文件，
    // 导致内存里的 .bak 改动指向已删除文件、再次保存失败。顶栏按钮与更多菜单共用此入口，一处拦截即可。
    if (_miniEditorOpen) {
      _toast('请先关闭迷你编辑器，再删除文件');
      return;
    }
    final path = ref.read(
      isOriginal ? originalFilePathProvider : modifiedFilePathProvider,
    );
    final label = isOriginal ? '左边文件' : '右边文件';
    // 弹窗打开期间，给即将被删的那一栏盖红色遮罩。
    setState(() => _pendingDeleteOriginal = isOriginal);
    final ok = await _confirmDelete(label, path);
    if (mounted) {
      setState(() => _pendingDeleteOriginal = null);
    }
    if (!ok || !mounted) return;

    try {
      await ShareIntakeCoordinator.moveToSharedTrash(
        path!,
        fromDupeBox: ref.read(fromDupeBoxProvider),
      );
      await ShareIntakeCoordinator.notifyDupeBox(path, 'delete');
      if (!mounted) return;
      setState(() {
        if (isOriginal) {
          _originalDeleted = true;
        } else {
          _modifiedDeleted = true;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ref.read(fromDupeBoxProvider)
                ? '$label 已移入回收站（可在 DupeBox 或 docdiff 回收站恢复）'
                : '$label 已移入回收站（可在 docdiff 回收站恢复）',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败：$e')),
      );
    }
  }

  // ---------- 移动文件 ----------
  Future<void> _moveSide({required bool isOriginal}) async {
    // 迷你编辑器开着时，先拦截：移动会让小窗持有的路径失效，保存写不进去。
    if (_miniEditorOpen) {
      _toast('请先关闭迷你编辑器，再移动文件');
      return;
    }
    final path = ref.read(
      isOriginal ? originalFilePathProvider : modifiedFilePathProvider,
    );
    final label = isOriginal ? '左边文件' : '右边文件';
    if (path == null || !mounted) return;
    final target = await showDialog<String>(
      context: context,
      builder: (_) => DirectoryPickerDialog(
        title: '移动$label',
        rootPath: '/storage/emulated/0',
        initialPath: '/storage/emulated/0',
        pickedPaths: [path],
      ),
    );
    if (target == null || target.isEmpty) return;
    if (!mounted) return;
    final dest = p.join(target, p.basename(path));
    if (await File(dest).exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目标目录已存在同名文件')),
      );
      return;
    }
    try {
      await File(path).rename(dest);
      await ShareIntakeCoordinator.notifyDupeBox(path, 'move');
      if (!mounted) return;
      setState(() {
        if (isOriginal) {
          _originalDeleted = true;
        } else {
          _modifiedDeleted = true;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label 已移动到 $target')),
      );
    } on FileSystemException {
      // 跨存储卷 rename 会失败，退化为复制 + 删除。
      try {
        await File(path).copy(dest);
        await File(path).delete();
        await ShareIntakeCoordinator.notifyDupeBox(path, 'move');
        if (!mounted) return;
        setState(() {
          if (isOriginal) {
            _originalDeleted = true;
          } else {
            _modifiedDeleted = true;
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label 已移动到 $target')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移动失败：$e')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('移动失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // ────────── 阶段 0：文件浏览器那边正在读盘 / 解析 ──────────
    // 此时还没进入 diff 计算，也要显示跳格圆环加载动画，避免出现两个加载页。
    // 注意：这里必须在 watch(diffResultProvider) 之前 return，
    // 否则一进页面就会同步跑预处理规则，把动画卡住。
    final loadError = ref.watch(compareLoadErrorProvider);
    if (loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('对比结果')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(loadError, textAlign: TextAlign.center),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('返回'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final loadStage = ref.watch(compareLoadStageProvider);
    if (loadStage != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('对比结果')),
        body: StepRingLoading(text: loadStage),
      );
    }

    final diffAsync = ref.watch(diffResultProvider);
    final viewMode = ref.watch(viewModeProvider);

    return diffAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('对比结果')),
        body: const StepRingLoading(),
      ),
      error: (e, st) => Scaffold(
        appBar: AppBar(title: const Text('对比结果')),
        body: Center(child: Text('计算差异失败：$e')),
      ),
      data: (diff) {
        final origName = ref.watch(originalFileNameProvider);
        final modName = ref.watch(modifiedFileNameProvider);
        if (diff == null) {
          // diffResultProvider 提前 return null 有两种原因：
          //   ① 预处理后有一侧为空 → 落"请先导入"；
          //   ② 全文相似度过低     → lowSimilarity 非 null，弹一道黄色提示。
          //   ③ 用户取消对比       → 页面已经在退出，这里不会再停留。
          final gate = ref.watch(lowSimilarityProvider);
          if (gate != null) {
            if (!identical(_lowSimilarityPromptedFor, gate)) {
              _lowSimilarityPromptedFor = gate;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _handleLowSimilarity(gate);
              });
            }
            return Scaffold(
              appBar: AppBar(title: const Text('对比结果')),
              body: const StepRingLoading(text: '正在检查两份内容…'),
            );
          }

          return Scaffold(
            appBar: AppBar(title: const Text('对比结果')),
            body: const Center(child: Text('请先导入两份文档')),
          );
        }
        // 结果出来了：撤掉超时询问，清掉拦截标记，下一份文件重新判断。
        _slowWarnTimer?.cancel();
        _lowSimilarityPromptedFor = null;
        return _buildWithHeights(diff, viewMode, origName, modName);
      },
    );
  }

  Widget _buildWithHeights(
    DiffResult diff,
    ViewMode viewMode,
    String? origName,
    String? modName,
  ) {
    if (!identical(_lastDiagDiff, diff)) {
      _lastDiagDiff = diff;
      ViewerDiag.reset();
      ViewerDiag.mark('diff 计算完成，进入渲染');
      _log('diff 已就绪，准备渲染');
    }

    final future = _getHeightFuture(diff, viewMode);
    return FutureBuilder<_HeightBundle>(
      future: future,
      builder: (context, snapshot) {
        // ────────── 场景 1：首次进入（还没成功显示过正文）──────────
        // 保留原来的整页 Scaffold + 跳格圆环加载动画
        if (!_hasShownContentOnce) {
          if (snapshot.hasError) {
            return Scaffold(
              appBar: AppBar(title: const Text('对比结果')),
              body: Center(child: Text('加载失败：${snapshot.error}')),
            );
          }
          if (!snapshot.hasData) {
            return Scaffold(
              appBar: AppBar(title: const Text('对比结果')),
              body: const StepRingLoading(),
            );
          }
          // 高度表首次就绪，从这里开始进入「已显示过正文」的状态
          _hasShownContentOnce = true;
        }

        // ────────── 从这里开始，_hasShownContentOnce == true ──────────
        final now = DateTime.now();
        final overlayActive =
            _switchOverlayUntil != null && now.isBefore(_switchOverlayUntil!);

        final heights = snapshot.data;
        final tableForCurrent = _tableOf(heights, viewMode);
        final tableReady = viewMode == ViewMode.grouped ||
            (tableForCurrent != null && tableForCurrent.length > 0);

        // ────────── 场景 2：切视图遮罩 / 表还没就绪 ──────────
        // 保留 AppBar、tab、工具栏，只遮内容区
        if (overlayActive || !tableReady) {
          if (overlayActive) {
            _switchOverlayTimer?.cancel();
            _switchOverlayTimer = Timer(const Duration(milliseconds: 60), () {
              if (mounted) setState(() {});
            });
          }
          return _buildDiffScaffold(
            diff,
            viewMode,
            origName,
            modName,
            heights ?? const _HeightBundle(),
            showLoadingOverlay: true,
          );
        }

        // ────────── 场景 3：表就绪，正常渲染 ──────────
        _switchOverlayUntil = null;
        ViewerDiag.mark('视图就绪');
        _activeHeights = heights!;

        if ((_pendingJumpEntry != null || _pendingJumpOrigLine != null) &&
            !_pendingJumpQueued) {
          _pendingJumpQueued = true;

          int? targetEntry = _pendingJumpEntry;
          if (targetEntry == null && _pendingJumpOrigLine != null) {
            targetEntry = _findEntryByOrigLine(diff, _pendingJumpOrigLine!);
            _log('按 origLine=${_pendingJumpOrigLine} 反查到 entry=$targetEntry');
          }
          final target = targetEntry ?? -1;
          _pendingJumpEntry = null;
          _pendingJumpOrigLine = null;
          _log('准备跳转: target=$target mode=${viewMode.name}');

          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted) return;
            _pendingJumpEntry = null;
            _pendingJumpOrigLine = null;
            _pendingJumpQueued = false;

            for (var attempt = 0; attempt < 5; attempt++) {
              if (!mounted) return;
              if (!_scrollController.hasClients) {
                await WidgetsBinding.instance.endOfFrame;
                continue;
              }
              if (_scrollController.position.maxScrollExtent > 0 ||
                  attempt >= 4) {
                break;
              }
              await WidgetsBinding.instance.endOfFrame;
            }
            if (!mounted) return;

            if (target < 0) {
              _log('跳转: 走 target<0 分支 → 跳到开头');
              if (_scrollController.hasClients) {
                _scrollController.jumpTo(0);
              }
            } else {
              _log('跳转: 走 _scrollToEntry($target)');
              _scrollToEntry(target);
            }
          });
        }

        return _buildDiffScaffold(diff, viewMode, origName, modName, heights);
      },
    );
  }

  // ==================== 内容宽度 ====================

  double _getContentWidth(DiffResult diff, ViewMode mode, double viewportW) {
    final noWrap = ref.read(noWrapProvider);
    if (!noWrap) return viewportW;

    final bodySize = ref.read(bodyFontSizeProvider);
    final showLine = ref.read(showLineNumbersProvider);
    final rev = ref.read(importRevisionProvider);
    final configKey =
        '${viewportW.round()}|${bodySize.round()}|$showLine|${mode.name}|$rev';

    if (identical(_cachedContentWidthFor, diff) &&
        _cachedContentWidthConfig == configKey &&
        _cachedContentWidth != null) {
      return _cachedContentWidth!;
    }

    final charWidth = bodySize * 0.75;
    final numW = showLine ? 44.0 : 16.0;
    final pad = 30.0;

    double computed;

    if (mode == ViewMode.merged) {
      var maxChars = 0;
      for (final ei in cachedMergedOrder(diff)) {
        final e = diff.entries[ei];
        var n = clipLineForDisplay(e.text).length;
        if (e.operation == DiffOperation.replace) {
          final oldN =
              clipLineForDisplay(e.oldText.isEmpty ? e.text : e.oldText).length;
          final newN =
              clipLineForDisplay(e.newText.isEmpty ? e.text : e.newText).length;
          if (oldN > n) n = oldN;
          if (newN > n) n = newN;
        }
        if (n > maxChars) maxChars = n;
      }
      computed = numW + maxChars * charWidth + pad;
    } else {
      computed = viewportW;
    }

    if (computed < viewportW) computed = viewportW;

    _cachedContentWidth = computed;
    _cachedContentWidthFor = diff;
    _cachedContentWidthConfig = configKey;
    return computed;
  }

  // ==================== 视图 ====================

  Widget _buildActiveView(
    DiffResult diff,
    ViewMode viewMode,
    String? origName,
    String? modName,
    _HeightBundle heights,
    bool noWrap,
  ) {
    // 行手势自定义（显示设置里可改，持久化）：单击/长按各自可设为
    // 无操作(none) / 编辑此行(edit) / 迷你编辑器(mini)。默认与旧版一致。
    final tapAction = ref.watch(rowTapActionProvider);
    final longPressAction = ref.watch(rowLongPressActionProvider);

    void runRowAction(String action, List<int> i) {
      if (action == 'edit') {
        _onRowTap(i);
      } else if (action == 'mini') {
        _onRowLongPress(i);
      }
      // 'none'：无操作
    }

    void runGroupedAction(String action, int idx, bool isLeft) {
      if (action == 'edit') {
        _onGroupedLineTap(idx, isLeft);
      } else if (action == 'mini') {
        _onGroupedLineLongPress(idx, isLeft);
      }
    }

    final Widget inner = switch (viewMode) {
      ViewMode.merged => MergedView(
          result: diff,
          heightTable: heights.merged ?? LineHeightTable.empty,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          noWrap: noWrap,
          // 手势可自定义（设置见「显示设置」）：默认点=无操作、长按=编辑此行；
          // 迷你编辑器默认关闭，需主动设置才可用。
          onTapEntry: (i) => runRowAction(tapAction, [i]),
          onLongPressEntry: (i) => runRowAction(longPressAction, [i]),
        ),
      ViewMode.sideBySide => SideBySideView(
          result: diff,
          syncHeightTable: heights.sbsSync ?? LineHeightTable.empty,
          leftHeightTable: heights.sbsLeft ?? LineHeightTable.empty,
          rightHeightTable: heights.sbsRight ?? LineHeightTable.empty,
          originalFileName: origName,
          modifiedFileName: modName,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          syncScroll: true,
          noWrap: noWrap,
          onTapEntry: (i) => runRowAction(tapAction, i),
          onLongPressEntry: (i) => runRowAction(longPressAction, i),
          onDeleteFile: _deleteSide,
          onMoveFile: _moveSide,
          deletedLeft: _pendingDeleteOriginal == true,
          deletedRight: _pendingDeleteOriginal == false,
        ),
      ViewMode.diffOnly => DiffOnlyView(
          result: diff,
          heightTable: heights.diffOnly ?? LineHeightTable.empty,
          originalFileName: origName,
          modifiedFileName: modName,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          contextFontSize: ref.watch(contextFontSizeProvider),
          noWrap: noWrap,
          onTapEntry: (i) => runRowAction(tapAction, i),
          onLongPressEntry: (i) => runRowAction(longPressAction, i),
          onDeleteFile: _deleteSide,
          onMoveFile: _moveSide,
          deletedLeft: _pendingDeleteOriginal == true,
          deletedRight: _pendingDeleteOriginal == false,
        ),
      ViewMode.diffOnlyPlain => DiffOnlyPlainView(
          result: diff,
          heightTable: heights.diffOnlyPlain ?? LineHeightTable.empty,
          originalFileName: origName,
          modifiedFileName: modName,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          noWrap: noWrap,
          onTapEntry: (i) => runRowAction(tapAction, i),
          onLongPressEntry: (i) => runRowAction(longPressAction, i),
          onDeleteFile: _deleteSide,
          onMoveFile: _moveSide,
          deletedLeft: _pendingDeleteOriginal == true,
          deletedRight: _pendingDeleteOriginal == false,
        ),
      ViewMode.grouped => GroupedDiffView(
          key: _groupedKey,
          deletedLeft: _pendingDeleteOriginal == true,
          deletedRight: _pendingDeleteOriginal == false,
          onDeleteFile: _deleteSide,
          onMoveFile: _moveSide,
          onLineTapRequest: (lineIdx, isLeft) async {
            runGroupedAction(tapAction, lineIdx, isLeft);
          },
          onLongPressMiniRequest: (lineIdx, isLeft) =>
              runGroupedAction(longPressAction, lineIdx, isLeft),
        ),
    };

    if (!noWrap) return inner;

    if (viewMode == ViewMode.merged) {
      final screenW = MediaQuery.of(context).size.width;
      final contentW = _getContentWidth(diff, viewMode, screenW);
      if (contentW <= screenW + 1) return inner;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        controller: _hScrollController,
        child: SizedBox(
          width: contentW,
          child: inner,
        ),
      );
    }

    return inner;
  }

  // ==================== 顶栏按钮（返回 / 更多 固定，中间可按设置排序） ====================

  Widget _buildTopBarBack() {
    return SizedBox(
      height: 48,
      child: Tooltip(
        message: '返回',
        child: InkWell(
          onTap: () {
            // 迷你编辑器开着时，先拦截：避免连带关掉小窗、丢失未保存的 .bak 改动。
            if (_miniEditorOpen) {
              _toast('请先关闭迷你编辑器，再返回');
              return;
            }
            // 从 DupeBox 跳进来对比的：返回应当回到 DupeBox，而不是 docdiff 文件浏览器。
            if (ref.read(fromDupeBoxProvider)) {
              _returnToDupeBox();
            } else {
              Navigator.of(context).maybePop();
            }
          },
          child: const Center(
            child: Icon(Icons.arrow_back, size: 24),
          ),
        ),
      ),
    );
  }

  /// 从 DupeBox 进入对比页时，把 DupeBox 重新带到前台（而非退回 docdiff 文件浏览器）。
  /// 若 DupeBox 未安装，回退为普通返回。
  Future<void> _returnToDupeBox() async {
    try {
      await const MethodChannel('docdiff/dupebox_launcher')
          .invokeMethod<bool>('returnToDupeBox');
    } on PlatformException {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  Widget _buildTopBarAction(TopBarButton b, ViewMode viewMode) {
    switch (b) {
      case TopBarButton.pageUp:
        return _buildTopBarPageButton(viewMode: viewMode, up: true);
      case TopBarButton.pageDown:
        return _buildTopBarPageButton(viewMode: viewMode, up: false);
      case TopBarButton.prevDiff:
        return _buildTopBarDiffJump(viewMode: viewMode, prev: true);
      case TopBarButton.nextDiff:
        return _buildTopBarDiffJump(viewMode: viewMode, prev: false);
      case TopBarButton.find:
        return _buildTopBarFind();
      case TopBarButton.deleteLeft:
        return _buildTopBarDelete(isOriginal: true);
      case TopBarButton.deleteRight:
        return _buildTopBarDelete(isOriginal: false);
      case TopBarButton.moveLeft:
        return _buildTopBarMove(isOriginal: true);
      case TopBarButton.moveRight:
        return _buildTopBarMove(isOriginal: false);
    }
  }

  Widget _buildTopBarPageButton({
    required ViewMode viewMode,
    required bool up,
  }) {
    return SizedBox(
      height: 48,
      child: Builder(builder: (ctx) {
        final iconColor =
            IconTheme.of(ctx).color ?? Theme.of(ctx).colorScheme.onSurface;
        return InkWell(
          key: Key(up ? 'page-up' : 'page-down'),
          onTap: () {
            if (viewMode == ViewMode.grouped) {
              final s = _groupedKey.currentState as dynamic;
              if (up) {
                s?.pageUp();
              } else {
                s?.pageDown();
              }
            } else {
              if (up) {
                _pageUp();
              } else {
                _pageDown();
              }
            }
          },
          onLongPress: () {
            if (viewMode == ViewMode.grouped) {
              final s = _groupedKey.currentState as dynamic;
              if (up) {
                s?.jumpToTop();
              } else {
                s?.jumpToBottom();
              }
            } else {
              if (up) {
                _jumpToDocTop();
              } else {
                _jumpToDocBottom();
              }
            }
          },
          child: Center(
            child: CustomPaint(
              size: const Size.square(24),
              painter: up
                  ? PageUpIconPainter(color: iconColor)
                  : PageDownIconPainter(color: iconColor),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildTopBarDiffJump({
    required ViewMode viewMode,
    required bool prev,
  }) {
    return SizedBox(
      height: 48,
      child: InkWell(
        key: Key(prev ? 'prev-diff' : 'next-diff'),
        onTap: () {
          if (viewMode == ViewMode.grouped) {
            final s = _groupedKey.currentState as dynamic;
            if (prev) {
              s?.jumpToPrevDiff();
            } else {
              s?.jumpToNextDiff();
            }
          } else {
            if (prev) {
              _jumpToPrevDiff();
            } else {
              _jumpToNextDiff();
            }
          }
        },
        onLongPress: () {
          if (viewMode == ViewMode.grouped) {
            final s = _groupedKey.currentState as dynamic;
            if (prev) {
              s?.jumpToTop();
            } else {
              s?.jumpToBottom();
            }
          } else {
            if (prev) {
              _jumpToDocTop();
            } else {
              _jumpToDocBottom();
            }
          }
        },
        child: Center(
          child: Icon(
            prev ? Icons.arrow_upward : Icons.arrow_downward,
            size: 24,
          ),
        ),
      ),
    );
  }

  Widget _buildTopBarFind() {
    return SizedBox(
      height: 48,
      child: Tooltip(
        message: '查找 / 替换',
        child: InkWell(
          onTap: () => setState(() => _showFind = !_showFind),
          child: const Center(
            child: Icon(Icons.find_in_page, size: 24),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBarDelete({required bool isOriginal}) {
    final deleted = isOriginal ? _originalDeleted : _modifiedDeleted;
    final path = ref.watch(
      isOriginal ? originalFilePathProvider : modifiedFilePathProvider,
    );
    final enabled = !deleted && path != null;
    final s = Theme.of(context).colorScheme;
    final base = enabled
        ? (IconTheme.of(context).color ?? s.onSurface)
        : s.onSurfaceVariant.withValues(alpha: 0.4);
    final label = isOriginal ? '左边文件' : '右边文件';

    return SizedBox(
      height: 48,
      child: Tooltip(
        message: deleted ? '$label已删除' : '删除$label',
        child: InkWell(
          key: Key(isOriginal ? 'topbar-del-left' : 'topbar-del-right'),
          onTap: enabled ? () => _deleteSide(isOriginal: isOriginal) : null,
          child: Center(
            child: CustomPaint(
              size: const Size.square(22),
              painter: DeleteSideIconPainter(
                color: base,
                accent: enabled ? s.error : base,
                isLeft: isOriginal,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 顶栏「移动左/右边文件」按钮：有真实路径且该侧未删除时可用。
  Widget _buildTopBarMove({required bool isOriginal}) {
    final deleted = isOriginal ? _originalDeleted : _modifiedDeleted;
    final path = ref.watch(
      isOriginal ? originalFilePathProvider : modifiedFilePathProvider,
    );
    final enabled = !deleted && path != null;
    final s = Theme.of(context).colorScheme;
    final base = enabled
        ? (IconTheme.of(context).color ?? s.onSurface)
        : s.onSurfaceVariant.withValues(alpha: 0.4);
    final label = isOriginal ? '左边文件' : '右边文件';

    return SizedBox(
      height: 48,
      child: Tooltip(
        message: '移动$label',
        child: InkWell(
          key: Key(isOriginal ? 'topbar-move-left' : 'topbar-move-right'),
          onTap: enabled ? () => _moveSide(isOriginal: isOriginal) : null,
          child: Center(
            child: CustomPaint(
              size: const Size.square(22),
              painter: MoveSideIconPainter(
                color: base,
                isLeft: isOriginal,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDiffScaffold(
    DiffResult diff,
    ViewMode viewMode,
    String? origName,
    String? modName,
    _HeightBundle heights, {
    bool showLoadingOverlay = false,
  }) {
    final noWrap = ref.watch(noWrapProvider);
    final diffBlocks = _diffBlockCount(diff);
    // 从 DupeBox 进入时，把返回键交给自定义逻辑（回到 DupeBox），而不是退回 docdiff。
    final fromDupeBox = ref.watch(fromDupeBoxProvider);

  return PopScope(
  canPop: !_showFind && !fromDupeBox && !_miniEditorOpen,
  onPopInvokedWithResult: (didPop, result) {
    if (didPop) return;
    // ★ 迷你小窗打开时，系统返回键与顶栏返回箭头保持一致：提示先关闭，
    // 而不是静默吞掉（否则按返回毫无反应，体验割裂）。
    if (_miniEditorOpen) {
      _toast('请先关闭迷你编辑器，再返回');
      return;
    }
    if (_showFind) {
      _closeFindBar();
      return;
    }
    if (fromDupeBox) {
      _returnToDupeBox();
      return;
    }
  },
  // 外层整屏 Stack：把迷你小窗（含内部的内容区屏障 / 悬浮提示 / 关闭确认框）
  // 浮在 Scaffold 之上。注意：内部屏障只盖「对比内容区」，顶部的工具栏与文件名栏
  // 不在屏障内，仍可点击；它们的弹窗走导航器 Overlay，会自动盖在迷你编辑器之上。
  child: Stack(
  children: [
    Positioned.fill(
      child: Scaffold(
  appBar: AppBar(
  backgroundColor: Theme.of(context).brightness == Brightness.dark
      ? Theme.of(context).colorScheme.surfaceContainerLow
      : const Color(0xFFF7F7F8),
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  toolbarHeight: 48,
  automaticallyImplyLeading: false,
  leadingWidth: 0,
  titleSpacing: 0,
  title: Row(
    children: [
      // 固定：返回
      Expanded(child: _buildTopBarBack()),
      // 可排序：按用户设置的顺序
      for (final b in ref.watch(topBarOrderProvider).where((e) => e.visible).map((e) => e.button))
        Expanded(child: _buildTopBarAction(b, viewMode)),
      // 固定：更多
      Expanded(
        child: PopupMenuButton<String>(
          tooltip: '更多操作',
          padding: EdgeInsets.zero,
          child: const SizedBox(
            height: 48,
            child: Center(child: Icon(Icons.more_vert)),
          ),
          onSelected: (v) {
              final toolbarVisible = ref.read(toolbarVisibleProvider);
              if (v == 'edit') {
                _openEdit();
              } else if (v == 'exportDiff') {
                _exportDiff();
              } else if (v == 'delOriginal') {
                _deleteSide(isOriginal: true);
              } else if (v == 'delModified') {
                _deleteSide(isOriginal: false);
              } else if (v == 'moveOriginal') {
                _moveSide(isOriginal: true);
              } else if (v == 'moveModified') {
                _moveSide(isOriginal: false);
              } else if (v == 'orientation') {
                _toggleOrientation();
              } else if (v == 'noWrap') {
                final cur = ref.read(noWrapProvider);
                ref.read(noWrapProvider.notifier).state = !cur;
                if (_hScrollController.hasClients) {
                  _hScrollController.jumpTo(0);
                }
              } else if (v == 'toggleToolbar') {
                ref.read(toolbarVisibleProvider.notifier).state =
                    !toolbarVisible;
              } else if (v == 'listLeftDiff') {
                _openLineListFromDiff(isLeft: true);
              } else if (v == 'listRightDiff') {
                _openLineListFromDiff(isLeft: false);
              } else if (v == 'displaySettings') {
                _openDisplaySettings();
              } else if (v == 'gestureSettings') {
                _openRowGestureSettings();
              } else if (v == 'comparisonSettings') {
                _openComparisonSettings();
              } else if (v == 'diagnostic') {
                _openDiagnostic();
              } else if (v == 'defaultView') {
                _pickDefaultViewMode();
              }
            },
            itemBuilder: (context) {
              final canDeleteOriginal = !_originalDeleted &&
                  ref.read(originalFilePathProvider) != null;
              final canDeleteModified = !_modifiedDeleted &&
                  ref.read(modifiedFilePathProvider) != null;
              final toolbarVisible = ref.read(toolbarVisibleProvider);
              return [
              const PopupMenuItem<String>(
                value: 'exportDiff',
                child: Row(
                  children: [
                    Icon(Icons.ios_share),
                    SizedBox(width: 10),
                    Text('导出差异为 txt'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'delOriginal',
                enabled: canDeleteOriginal,
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline,
                      color: canDeleteOriginal
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _originalDeleted ? '左边文件已删除' : '删除左边文件',
                      style: TextStyle(
                        color: canDeleteOriginal
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'delModified',
                enabled: canDeleteModified,
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline,
                      color: canDeleteModified
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _modifiedDeleted ? '右边文件已删除' : '删除右边文件',
                      style: TextStyle(
                        color: canDeleteModified
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'moveOriginal',
                enabled: canDeleteOriginal,
                child: Row(
                  children: [
                    CustomPaint(
                      size: const Size.square(20),
                      painter: MoveSideIconPainter(
                        color: Theme.of(context).colorScheme.onSurface,
                        isLeft: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text('移动左边文件'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'moveModified',
                enabled: canDeleteModified,
                child: Row(
                  children: [
                    CustomPaint(
                      size: const Size.square(20),
                      painter: MoveSideIconPainter(
                        color: Theme.of(context).colorScheme.onSurface,
                        isLeft: false,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text('移动右边文件'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'displaySettings',
                child: Row(
                  children: [
                    Icon(Icons.format_size),
                    SizedBox(width: 10),
                    Text('显示设置'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'gestureSettings',
                child: Row(
                  children: [
                    Icon(Icons.touch_app),
                    SizedBox(width: 10),
                    Text('手势设置'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'comparisonSettings',
                child: Row(
                  children: [
                    Icon(Icons.rule),
                    SizedBox(width: 10),
                    Text('对比规则设置'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'toggleToolbar',
                child: Row(
                  children: [
                    Icon(
                      toolbarVisible
                          ? Icons.dashboard_customize
                          : Icons.dashboard_customize_outlined,
                    ),
                    const SizedBox(width: 10),
                    Text(toolbarVisible ? '隐藏工具栏' : '显示工具栏'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'noWrap',
                enabled: viewMode != ViewMode.grouped,
                child: Row(
                  children: [
                    Icon(
                      viewMode == ViewMode.grouped
                          ? Icons.block
                          : (noWrap ? Icons.wrap_text : Icons.notes),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      viewMode == ViewMode.grouped
                          ? '跨行块视图不支持不换行'
                          : (noWrap ? '关闭不换行' : '开启不换行'),
                    ),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'defaultView',
                child: Row(
                  children: [
                    Icon(Icons.visibility),
                    SizedBox(width: 10),
                    Text('默认打开视图'),
                  ],
                ),
              ),
               PopupMenuItem<String>(
                value: 'orientation',
                child: Row(
                  children: [
                    Icon(
                      _landscape
                          ? Icons.screen_rotation
                          : Icons.rotate_left,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Text(_landscape ? '切换到竖屏' : '切换到横屏'),
                  ],
                ),
              ),

              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'diagnostic',
                child: Row(
                  children: [
                    Icon(Icons.bug_report),
                    SizedBox(width: 10),
                    Text('诊断'),
                  ],
                ),
              ),
            ];
          },
        ),
      ),
    ],
  ),
  actions: const [],
),
  body: Stack(
  children: [
    Column(
      children: [
          if (_originalDeleted || _modifiedDeleted) _buildDeletedBanner(),
          _buildEncodingBanner(),
          if (diffBlocks < 6) _buildFewDiffsBanner(diffBlocks),
          // 查找面板展开动画（P4 分层下拉）：_showFind 语义一字未改，
          // 仍由顶栏开关 / 返回键拦截 / 关闭清空逻辑控制；这里只加展开与收起的外壳。
          ClipRect(
            child: AnimatedSize(
              duration: MediaQuery.of(context).disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _showFind
                  ? _buildFindBar()
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ),

          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Theme.of(context).colorScheme.surfaceContainerLow
                  : const Color(0xFFF7F7F8),
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.5,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final order = ref.watch(viewModeOrderProvider);
                  final Map<ViewMode, double> tabFlex = {
                    ViewMode.diffOnly: 2.4,
                    ViewMode.diffOnlyPlain: 2.4,
                    ViewMode.grouped: 2.4,
                    ViewMode.merged: 2.0,
                    ViewMode.sideBySide: 2.0,
                  };
                  const totalFlex = 11.2;

                  const double unitMin = 52.0;
                  final unitW = (constraints.maxWidth / totalFlex)
                      .clamp(unitMin, double.infinity);
                  final totalW = unitW * totalFlex;
                  final needsScroll = totalW > constraints.maxWidth + 0.5;
                  final cs = Theme.of(context).colorScheme;

                  final tabsRow = SizedBox(
                    width: totalW,
                    height: 40,
                    // T7：只有这 40px 的 tab 条随动画逐帧重建；
                    // RepaintBoundary 隔离重绘，不影响下方正文与切视图遮罩。
                    child: RepaintBoundary(
                      child: AnimatedBuilder(
                        animation: _tabAnimController,
                        builder: (context, _) => _buildAnimatedTabStrip(
                          order: order,
                          tabFlex: tabFlex,
                          unitW: unitW,
                          current: viewMode,
                        ),
                      ),
                    ),
                  );

                  if (!needsScroll) return SizedBox(height: 40, child: tabsRow);

                  return Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: SingleChildScrollView(
                            controller: _tabScrollController,
                            scrollDirection: Axis.horizontal,
                            child: tabsRow,
                          ),
                        ),
                      ),
                      if (!_tabAtEnd)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _scrollTabsToEnd,
                          child: Container(
                            width: 24,
                            height: 40,
                            alignment: Alignment.center,
                            color: cs.brightness == Brightness.dark
                                ? cs.surfaceContainerLow
                                : const Color(0xFFF7F7F8),
                            child: Icon(
                              Icons.chevron_right,
                              size: 20,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),

          if (ref.watch(toolbarVisibleProvider)) _buildToolbar(),
          if (_processing) _buildProcessingBanner(),
                   Expanded(
              child: showLoadingOverlay
                  ? ColoredBox(
                      color: Theme.of(context).colorScheme.surface,
                      child: const Center(child: StepRingLoading()),
                    )
                  : _buildActiveView(
                      diff,
                      viewMode,
                      origName,
                      modName,
                      heights,
                      noWrap,
                    ),
            ),
          ],
        ),
               if (ref.watch(floatingPageDownEnabledProvider))
          _buildFloatingButton(
            size: ref.watch(floatingPageDownSizeProvider),
            x: ref.watch(floatingPageDownXProvider),
            y: ref.watch(floatingPageDownYProvider),
            opacity: ref.watch(floatingPageDownOpacityProvider),
            borderWidth: ref.watch(floatingPageDownBorderWidthProvider),
            color: ref.watch(floatingPageDownColorProvider),
            up: false,
            onTap: _onFloatingPageDownTap,
          ),
        if (ref.watch(floatingPageUpEnabledProvider))
          _buildFloatingButton(
            size: ref.watch(floatingPageUpSizeProvider),
            x: ref.watch(floatingPageUpXProvider),
            y: ref.watch(floatingPageUpYProvider),
            opacity: ref.watch(floatingPageUpOpacityProvider),
            borderWidth: ref.watch(floatingPageUpBorderWidthProvider),
            color: ref.watch(floatingPageUpColorProvider),
            up: true,
            onTap: _onFloatingPageUpTap,
          ),
        if (_jumping)
          Positioned.fill(
            child: AbsorbPointer(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: StepRingJumpIndicator(
                  direction: _jumpDirection,
                ),
              ),
            ),
          ),

      ],
    ),
  ),
    ),
    // ★ 迷你源文件编辑器浮层：盖住整个页面（含 AppBar）。
    // 它自带整屏手势屏障，会吞掉小窗之外的一切点击；
    // 加上 _onRowTap / _onRowLongPress 开头的短路判断，
    // 保证小窗打开时点对比页其它行不会再弹编辑框、两者不会叠加。
    // 只有浮层顶栏的 ×（_closeMiniEditor）能关闭它。
    if (_miniEditorOpen && _miniEditorPath != null)
      Positioned.fill(
        child: SourceMiniEditorOverlay(
          filePath: _miniEditorPath!,
          anchorText: _miniEditorAnchor ?? '',
          anchorLine: _miniEditorAnchorLine,
          lineMap: ref.watch(_miniEditorIsOriginal
              ? preprocessedOriginalLineMapProvider
              : preprocessedModifiedLineMapProvider),
          // 新增：同一张映射表每格的「精确锚点 / 插值估计」标记，
          // 只给小窗判断要不要亮橙色 ?；定位算法本身一行不改。
          lineMapExact: ref.watch(_miniEditorIsOriginal
              ? preprocessedOriginalLineMapExactProvider
              : preprocessedModifiedLineMapExactProvider),
          // 长按行的上下文（±2 行）：给候选位置按「邻居像不像」排序用，
          // 不否决、不写盘。
          anchorContext: _miniEditorAnchorContext,
          isOriginal: _miniEditorIsOriginal,
          onClose: _closeMiniEditor,
          onMessage: _toast,
          frameKey: _miniFrameKey,
        ),
      ),
  ],
  ),
  );
}



Widget _buildFloatingButton({
  required double size,
  required double x,
  required double y,
  required double opacity,
  required double borderWidth,
  required Color color,
  required bool up,
  required VoidCallback onTap,
}) {
  final mq = MediaQuery.of(context);
  final screenW = mq.size.width;
  final screenH = mq.size.height;

  final left = screenW * (x / 100) - size / 2;
  final top = screenH * (y / 100) - size / 2;

  // 图标色按底色亮度自动取深/浅：浅灰底上是深色图标，深色底上翻白。
  // 和文件浏览器那颗悬浮按钮同一套算法，两边观感一致。
  final fg = color.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

  return Positioned(
    left: left,
    top: top,
    child: SizedBox(
      width: size,
      height: size,
      child: Material(
        color: color.withValues(alpha: opacity / 100),
        // borderWidth 保留下来做圆的描边：原来是空心方框的边框粗细，
        // 改成实心圆之后这个设置不该突然失灵。
        shape: CircleBorder(
          side: BorderSide(
            color: fg.withValues(alpha: 0.35),
            width: borderWidth,
          ),
        ),
        elevation: 2,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Center(
            // 用顶栏翻页按钮那两个自绘图标，不用 keyboard_arrow：
            // 顶栏和悬浮按钮是同一个功能的两处入口，画法必须一致。
            // painter 内部按 size/24 缩放，传多大都能正确铺满。
            child: CustomPaint(
              size: Size.square(size * 0.5),
              painter: up
                  ? PageUpIconPainter(color: fg)
                  : PageDownIconPainter(color: fg),
            ),
          ),
        ),
      ),
    ),
  );
}

void _onFloatingPageDownTap() {
  final mode = ref.read(viewModeProvider);
  if (mode == ViewMode.grouped) {
    (_groupedKey.currentState as dynamic)?.pageDown();
  } else {
    _pageDown();
  }
}

void _onFloatingPageUpTap() {
  final mode = ref.read(viewModeProvider);
  if (mode == ViewMode.grouped) {
    (_groupedKey.currentState as dynamic)?.pageUp();
  } else {
    _pageUp();
  }
}



  
  // ==================== 按钮栏 ====================

  Widget _buildToolbar() {
    final rules = ref.watch(toolbarRulesOrderedProvider);
    final colors = ref.watch(toolbarButtonColorsProvider);
    final s = Theme.of(context).colorScheme;

    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: s.brightness == Brightness.dark
            ? s.surfaceContainerLow
            : const Color(0xFFF7F7F8),
        border: Border(
          bottom: BorderSide(
            color: s.outlineVariant,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: rules.isEmpty
                ? Center(
                    child: Text(
                      '点 + 添加快捷操作按钮（长按编辑）',
                      style: TextStyle(
                        fontSize: 10,
                        color: s.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    itemCount: rules.length,
                    itemBuilder: (ctx, i) {
                      final r = rules[i];
                      final c = colors[r.id];
                      final bg = c?.bg ?? s.surface;
                      final fg = c?.fg ?? s.onSurface;
                      final border = c?.border ?? s.outline;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 1,
                          vertical: 3,
                        ),
                        child: GestureDetector(
                          onTap: () => _onToolbarButtonTap(r),
                          onLongPress: () => _editToolbarRule(r),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 2,
                            ),
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: border),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: fg,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SizedBox(
            width: 28,
            child: IconButton(
              icon: const Icon(Icons.add, size: 16),
              padding: EdgeInsets.zero,
              tooltip: '新建快捷操作按钮',
              visualDensity: VisualDensity.compact,
              onPressed: _addToolbarRule,
            ),
          ),
          SizedBox(
            width: 28,
            child: IconButton(
              icon: const Icon(Icons.sort, size: 16),
              padding: EdgeInsets.zero,
              tooltip: '按钮排序、样式更改、删除',
              visualDensity: VisualDensity.compact,
              onPressed: _showToolbarOrderDialog,
            ),
          ),
          TextButton(
            onPressed: () =>
                ref.read(toolbarVisibleProvider.notifier).update(false),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              '折叠',
              style: TextStyle(fontSize: 11, color: s.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewChip({
    required String label,
    required ViewMode value,
    required ViewMode current,
    bool compact = false,
    VoidCallback? onLongPress,
    IconData? trailingIcon,
    VoidCallback? onTrailingTap,
    // T7：0 = 未选中、1 = 选中，可插值；文字 Q 弹缩放。
    double selectProgress = 1.0,
    double jellyScale = 1.0,
  }) {
    final s = Theme.of(context).colorScheme;
    final progress = selectProgress < 0.0
        ? 0.0
        : (selectProgress > 1.0 ? 1.0 : selectProgress);
    return GestureDetector(
      onTap: () => _switchView(value),
      onLongPress: onLongPress,
      child: Container(
        height: 38,
        alignment: Alignment.center,
        // 原来底部有 4px 内边框，去掉后补同样的占位，文字垂直位置不变。
        padding: const EdgeInsets.only(bottom: 4),
        // T7：底部 4px 指示条改成 tab 条里唯一的一根独立 Positioned 条，
        // 这样它才能从旧 tab 滑到新 tab 并带回弹。
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Transform.scale(
                scale: jellyScale,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: progress >= 0.5
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: Color.lerp(
                      s.onSurfaceVariant,
                      AppColors.textAccentOf(s),
                      progress,
                    ),
                  ),
                ),
              ),
            ),
            if (trailingIcon != null) ...[
              const SizedBox(width: 2),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTrailingTap,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    trailingIcon,
                    size: 14,
                    color: s.onSurfaceVariant
                        .withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingBanner() {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(
        _processingText,
        style: TextStyle(
          fontSize: 13,
          color: s.onTertiaryContainer,
        ),
      ),
    );
  }

  Future<void> _onToolbarButtonTap(PreprocessingRule rule) async {
    final side = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '「${rule.name}」应用到：',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.arrow_back),
              title: const Text('只改左侧文件'),
              onTap: () => Navigator.pop(c, 'left'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_forward),
              title: const Text('只改右侧文件'),
              onTap: () => Navigator.pop(c, 'right'),
            ),
            ListTile(
              leading: const Icon(Icons.compare_arrows),
              title: const Text('两侧都改'),
              onTap: () => Navigator.pop(c, 'both'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(c),
            ),
          ],
        ),
      ),
    );
    if (side == null || !mounted) return;
    await _applyToolbarRule(rule, side);
  }

  Future<void> _applyToolbarRule(PreprocessingRule rule, String side) async {
    setState(() {
      _processing = true;
      _processingText = '正在执行「${rule.name}」…';
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    try {
      final currentOrig = ref.read(preprocessedOriginalProvider);
      final currentMod = ref.read(preprocessedModifiedProvider);

      if (side == 'left' || side == 'both') {
        if (currentOrig.isNotEmpty) {
          final next = applyOneRule(currentOrig, rule);
          ref.read(editedOriginalProvider.notifier).state = next;
        }
      }
      if (side == 'right' || side == 'both') {
        if (currentMod.isNotEmpty) {
          final next = applyOneRule(currentMod, rule);
          ref.read(editedModifiedProvider.notifier).state = next;
        }
      }
      _rememberCurrentRowForReset();

      _log('按钮规则: ${rule.name} → $side');
      ref.read(importRevisionProvider.notifier).state++;
      _resetViewAfterEdit();

      if (!mounted) return;
      _toast('已应用「${rule.name}」');
    } catch (e) {
      if (mounted) _toast('执行失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _processingText = '';
        });
      }
    }
  }

  Future<void> _addToolbarRule() async {
    final rule = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => const RuleEditorDialog(
        showCopyToPreprocess: false,
      ),
    );
    if (rule == null || !mounted) return;
    ref.read(toolbarRulesProvider.notifier).add(rule);
    _toast('已添加按钮「${rule.name}」');
  }

  Future<void> _editToolbarRule(PreprocessingRule rule) async {
    final updated = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => RuleEditorDialog(
        initial: rule,
        showCopyToPreprocess: true,
        onCopyToPreprocess: (copied) {
          _toast('「${copied.name}」已复制到对比规则设置里');
        },
      ),
    );
    if (updated == null || !mounted) return;
    ref.read(toolbarRulesProvider.notifier).updateRule(updated);
  }

  Future<void> _showToolbarOrderDialog() async {
    final rules = ref.read(toolbarRulesOrderedProvider);
    if (rules.isEmpty) {
      _toast('还没有按钮');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => ToolbarOrderDialog(rules: rules),
    );
  }

  Widget _buildDeletedBanner() {
    final parts = <String>[];
    if (_originalDeleted) parts.add('左边文件');
    if (_modifiedDeleted) parts.add('右边文件');
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.error,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.warning_amber, size: 16, color: s.onError),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${parts.join(" / ")} 已从磁盘删除（下方内容仅内存保留）',
              style: TextStyle(
                fontSize: 13,
                color: s.onError,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEncodingBanner() {
    final origEnc = ref.watch(originalEncodingProvider);
    final modEnc = ref.watch(modifiedEncodingProvider);
    if (origEnc == modEnc) return const SizedBox.shrink();
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: s.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '两份文件编码不同（$origEnc / $modEnc），已分别解码后对比',
              style: TextStyle(
                fontSize: 13,
                color: s.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFewDiffsBanner(int blocks) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 16,
            color: s.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              blocks == 0
                  ? '两份文档完全相同'
                  : '共 $blocks 处差异，已全部显示',
              style: TextStyle(
                fontSize: 13,
                color: s.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 查找栏 UI ====================

  Widget _buildFindBar() {
    final total = _matchEntries.length;
    final pendingCount =
        _pendingOrigChanges.length + _pendingModChanges.length;
    final s = Theme.of(context).colorScheme;


    // ── U1 统一动效：范围三选一 / 高级开关共用同一套「边框 + 文字」渐变。
    // 只动边框颜色与文字颜色/字重，不引入背景块、对勾或滑块；静态外观与原来一致。
    Widget _findChip({
      required String label,
      required bool selected,
      required double fontSize,
      required EdgeInsetsGeometry padding,
      required BorderRadius radius,
    }) {
      final dur = MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 220);
      return AnimatedContainer(
        duration: dur,
        curve: Curves.easeOutCubic,
        height: 32,
        alignment: Alignment.center,
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: selected ? s.primary : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: AnimatedDefaultTextStyle(
          duration: dur,
          curve: Curves.easeOutCubic,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? AppColors.textAccentOf(s) : s.onSurfaceVariant,
          ),
          child: Text(label),
        ),
      );
    }

    // ── P4 分层错开：面板内四行依次淡入下移。固定 key 保证输入文字重建面板时不重播。
    Widget _enterRow(int order, Widget child) {
      if (MediaQuery.of(context).disableAnimations) return child;
      return TweenAnimationBuilder<double>(
        key: ValueKey('find_enter_$order'),
        tween: Tween<double>(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 420),
        curve: Interval(order * 0.13, order * 0.13 + 0.5,
            curve: Curves.easeOutCubic),
        builder: (ctx, v, c) => Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, (1 - v) * 10),
            child: c,
          ),
        ),
        child: child,
      );
    }

    Widget toggle({
      required String label,
      required bool value,
      required VoidCallback onTap,
      VoidCallback? onLongPress,
    }) {
      final s = Theme.of(context).colorScheme;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(6),
          splashColor: s.primary.withValues(alpha: 0.18),
          highlightColor: s.primary.withValues(alpha: 0.08),
          child: _findChip(
            label: label,
            selected: value,
            fontSize: 13,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            radius: BorderRadius.circular(6),
          ),
        ),
      );
    }

    // 三选一胶囊（左侧 / 右侧 / 两侧）
    Widget sidePill({
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      final s = Theme.of(context).colorScheme;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          splashColor: s.primary.withValues(alpha: 0.18),
          highlightColor: s.primary.withValues(alpha: 0.08),
          child: _findChip(
            label: label,
            selected: selected,
            fontSize: 13,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            radius: BorderRadius.circular(6),
          ),
        ),
      );
    }

    return Material(
      color: s.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _enterRow(
              0,
              Row(
                children: [
                 const SizedBox(width: 6),
      Expanded(
    child: SizedBox(
    height: 38,
    child: TextField(
      controller: _findController,
                      autofocus: true,
                      cursorColor: s.primary,
                      decoration: const InputDecoration(
                        hintText: '查找',
                        isDense: true,
                        border: InputBorder.none,
                      ),
                      onChanged: _onFindInput,
                      onSubmitted: (_) => _nextMatch(),
                    ),
                  ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    color: s.primary,
                    tooltip: '立即搜索',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
    if (_findQuery.isEmpty) {
      _toast('请先输入查找内容');
      return;
    }
    _findDebounce?.cancel();
    _findChanged(_findController.text);
    if (_matchEntries.isEmpty) {
      _toast('没有找到「$_findQuery」');
    }
  },
                  ),
                  IconButton(
                    icon: const Icon(Icons.history),
                    tooltip: '查找历史',
                    visualDensity: VisualDensity.compact,
                    onPressed: _showFindHistory,
                  ),
                ],
              ),
            ),
            if (_noResultHint != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4, bottom: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: s.tertiaryContainer.withValues(alpha: 0.5),
                  border: Border.all(color: s.tertiary),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 15, color: s.onTertiaryContainer),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _noResultHint!,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: s.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            _enterRow(
              1,
              Row(
                children: [
                  const SizedBox(width: 6),
         Expanded(
    child: SizedBox(
  height: 38,
  child: TextField(
    controller: _replaceController,
                      cursorColor: s.primary,
                      decoration: const InputDecoration(
                        hintText: '替换为（留空 = 删掉）',
                        isDense: true,
                        border: InputBorder.none,
                      ),
                      onChanged: _onReplaceInput,
                    ),
                  ),
      ),
                  
                 TextButton(
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      foregroundColor: s.primary,
    ),
    onPressed: _matchEntries.isEmpty ? null : _replaceCurrentInline,
    child: const Text('替换当前'),
  ),
  TextButton(
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      foregroundColor: s.primary,
    ),
    onPressed: _matchEntries.isEmpty ? null : _replaceAllInline,
    child: const Text('全部替换'),
  ),
  
  
  
                  
                ],
              ),
            ),
            if (_replaceHint != null || _regexErrorHint != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4, bottom: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: s.errorContainer.withValues(alpha: 0.5),
                  border: Border.all(color: s.error),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(Icons.warning_amber,
                          size: 15, color: s.error),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        [
                          if (_regexErrorHint != null)
                            '查找框：$_regexErrorHint',
                          if (_replaceHint != null)
                            '替换框：$_replaceHint',
                        ].join('\n\n'),
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          fontWeight: FontWeight.bold,
                          color: s.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            _enterRow(
              2,
       SizedBox(
    height: 40,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
      children: [
        const SizedBox(width: 8),
        const Text(
          '查找/替换范围：',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(width: 6),
        sidePill(
          label: '左侧',
          selected: _searchLeft && !_searchRight,
          onTap: () {
            if (_searchLeft && !_searchRight) return;
            setState(() {
              _searchLeft = true;
              _searchRight = false;
            });
            _findChanged(_findController.text);
          },
        ),
        const SizedBox(width: 4),
        sidePill(
          label: '右侧',
          selected: !_searchLeft && _searchRight,
          onTap: () {
            if (!_searchLeft && _searchRight) return;
            setState(() {
              _searchLeft = false;
              _searchRight = true;
            });
            _findChanged(_findController.text);
          },
        ),
        const SizedBox(width: 4),
        sidePill(
          label: '两侧',
          selected: _searchLeft && _searchRight,
          onTap: () {
            if (_searchLeft && _searchRight) return;
            setState(() {
              _searchLeft = true;
              _searchRight = true;
            });
            _findChanged(_findController.text);
          },
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.arrow_upward),
          iconSize: 28,
          color: s.primary,
          tooltip: '上一个',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
          onPressed: _matchEntries.isEmpty ? null : _prevMatch,
        ),
        IconButton(
          icon: const Icon(Icons.arrow_downward),
          iconSize: 28,
          color: s.primary,
          tooltip: '下一个',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
          onPressed: _matchEntries.isEmpty ? null : _nextMatch,
        ),
      ],
      ),
    ),
  ),
            ),
            _enterRow(
              3,
              SizedBox(
    height: 40,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
      children: [
        const SizedBox(width: 8),
        const Text(
          '高级搜索：',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(width: 4),
        toggle(
          label: '正则',
          value: _regexEnable,
          onTap: () => setState(() {
            _regexEnable = !_regexEnable;
            _findChanged(_findController.text);
          }),
          onLongPress: _openRegexHelp,
        ),
        toggle(
          label: '忽略大小写',
          value: _caseInsensitive,
          onTap: () => setState(() {
            _caseInsensitive = !_caseInsensitive;
            _findChanged(_findController.text);
          }),
          onLongPress: () => _toast('开启后 A 和 a 视为相同'),
        ),
        toggle(
          label: '整词',
          value: _wholeWord,
          onTap: () => setState(() {
            _wholeWord = !_wholeWord;
            _findChanged(_findController.text);
          }),
          onLongPress: () => _toast('只匹配完整单词，对中文无效'),
        ),
        if (pendingCount > 0) ...[
          const SizedBox(width: 8),
          Text(
            '待应用 $pendingCount',
            style: TextStyle(
              fontSize: 12,
              color: s.tertiary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
        const Spacer(),
        TextButton.icon(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: pendingCount > 0 ? s.tertiary : null,
          ),
          onPressed: pendingCount > 0 ? _applyPendingChanges : null,
          icon: const Icon(Icons.done_all, size: 16),
          label: const Text('应用并刷新'),
        ),
      ],
      ),
    ),
  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RegexError implements Exception {
  const _RegexError({required this.name, required this.detail});
  final String name;
  final String detail;
}
