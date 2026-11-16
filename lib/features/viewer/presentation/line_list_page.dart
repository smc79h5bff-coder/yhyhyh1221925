import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/application/aho_corasick.dart';

// ==================== Provider ====================

final lineListTextProvider = StateProvider<String>((ref) => '');
final lineListMinLenProvider = StateProvider<int>((ref) => 7);

// ==================== 常量 ====================

const double _kFontSize = 14.0;
const double _kLineHeight = 22.0;
const double _kEditorVPad = 9.0;

const double _kBlockSize = 36.0;
const double _kBlockOffset = 37.0;
const double _kBlockAreaWidth = 76.0;

const double _kGutterWidth = 45.0;

const Color _kSelectedBg = Color(0xFFDCFFFF);
const Color _kCheckColor = Color(0xFF00ABFF);
const Color _kLineNumSelected = Color(0xFF007DFF);
const Color _kLineNumNormal = Color(0xFF9E9E9E);
const Color _kBlockBgNormal = Color(0xFFEDEDED);
const Color _kBlockBorderNormal = Color(0xFFBDBDBD);
const Color _kBlockTextNormal = Color(0xFF424242);
const Color _kConnectorColor = Color(0xFFBDBDBD);

// ==================== 页面 ====================

class LineListPage extends ConsumerStatefulWidget {
  const LineListPage({super.key});

  @override
  ConsumerState<LineListPage> createState() => _LineListPageState();
}

class _LineListPageState extends ConsumerState<LineListPage> {
  late final TextEditingController _textCtrl;
  late final ScrollController _vertCtrl;
  final Set<int> _selectedLines = <int>{};
  int? _anchorLine;
  String _lastText = '';

  // ★ 宽度缓存：文本没变就不重新测量
  double? _cachedMaxLineWidth;
  String? _cachedMaxLineWidthForText;
  String? _measureScheduledFor;

  // ★ 行数 / 行数组缓存：只在文本变化时重算。
  // 原先 _lineCount 是 getter，被直接写在 for 循环条件里，每一轮都要执行
  // '\n'.allMatches(text) 全文扫一遍——N 行就是 O(N²)。两万行一次 build 要扫
  // 上亿字符，滚动时每帧一次 build，必然卡死。现在 O(N) 只在文本变化时付一次。
  int _cachedLineCount = 1;
  List<String> _cachedLines = const <String>[''];

  /// 滚动偏移。用 ValueNotifier 而不是 setState：滚动时只重建方块区、行号栏、
  /// 高亮层这三块，TextField 和工具条不跟着重建。
  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: ref.read(lineListTextProvider));
    _lastText = _textCtrl.text;
    _refreshTextCache();
    _vertCtrl = ScrollController();
    _textCtrl.addListener(_onControllerChanged);
    _vertCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _textCtrl.removeListener(_onControllerChanged);
    _vertCtrl.removeListener(_onScroll);
    _textCtrl.dispose();
    _vertCtrl.dispose();
    _scrollOffset.dispose();
    super.dispose();
  }

  /// 文本变了才调用：一次性把「行数组 + 行数」算好存起来。
  void _refreshTextCache() {
    final t = _textCtrl.text;
    _cachedLines = t.split('\n');
    _cachedLineCount = _cachedLines.isEmpty ? 1 : _cachedLines.length;
    if (_cachedLineCount < 1) _cachedLineCount = 1;
  }

  void _onControllerChanged() {
    final newText = _textCtrl.text;
    var needRebuild = false;

    if (newText != _lastText) {
      _lastText = newText;
      _refreshTextCache();
      ref.read(lineListTextProvider.notifier).state = newText;
      final count = _lineCount;
      final before = _selectedLines.length;
      _selectedLines.removeWhere((i) => i >= count);
      if (_selectedLines.length != before) needRebuild = true;
      if (_anchorLine != null && _anchorLine! >= count) {
        _anchorLine = null;
        needRebuild = true;
      }
      needRebuild = true;
    } else {
      if (_selectedLines.isNotEmpty) {
        _selectedLines.clear();
        _anchorLine = null;
        needRebuild = true;
      }
    }

    if (needRebuild && mounted) setState(() {});
  }

  void _onScroll() {
    if (!mounted || !_vertCtrl.hasClients) return;
    final v = _vertCtrl.offset;
    if (v != _scrollOffset.value) _scrollOffset.value = v;
  }

  /// 行数：读缓存，不再每次全文扫 '\n'。
  int get _lineCount => _cachedLineCount;

  /// 行数组：读缓存，不再每次 split 整篇。
  List<String> get _lines => _cachedLines;

  bool get _hasContent => _textCtrl.text.isNotEmpty;

  // ---------- 可见区间（虚拟化用） ----------

  /// 第一行可见行（多留 2 行余量，避免快速滚动时露白）。
  int _firstVisibleLine(double offset) {
    final i = ((offset - _kEditorVPad) / _kLineHeight).floor() - 2;
    return i < 0 ? 0 : i;
  }

  /// 最后一行可见行（同样多留 2 行）。
  int _lastVisibleLine(double offset, double viewportH, int count) {
    final last = count - 1;
    if (last < 0) return 0;
    if (!viewportH.isFinite) return last;
    final i = ((offset - _kEditorVPad + viewportH) / _kLineHeight).ceil() + 2;
    return i > last ? last : (i < 0 ? 0 : i);
  }

  // ==================== 行选择 ====================

  void _toggleLine(int i) {
    setState(() {
      if (_selectedLines.contains(i)) {
        _selectedLines.remove(i);
      } else {
        _selectedLines.add(i);
      }
      _anchorLine = i;
    });
  }

  void _rangeSelect(int i) {
    if (_selectedLines.isEmpty) {
      setState(() {
        _selectedLines.add(i);
        _anchorLine = i;
      });
      return;
    }
    final minSel = _selectedLines.reduce((a, b) => a < b ? a : b);
    final maxSel = _selectedLines.reduce((a, b) => a > b ? a : b);

    int lo;
    int hi;
    if (i > maxSel) {
      lo = minSel;
      hi = i;
    } else if (i < minSel) {
      lo = i;
      hi = maxSel;
    } else {
      return;
    }

    setState(() {
      for (var k = lo; k <= hi; k++) {
        _selectedLines.add(k);
      }
      _anchorLine = i;
    });
  }

  void _selectAll() {
    setState(() {
      _selectedLines.clear();
      for (var i = 0; i < _lineCount; i++) {
        _selectedLines.add(i);
      }
      _anchorLine = 0;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectedLines.clear();
      _anchorLine = null;
    });
  }

  void _selectLongLines(int minLen) {
    final lines = _lines;
    setState(() {
      _selectedLines.clear();
      _anchorLine = null;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].runes.length > minLen) {
          _selectedLines.add(i);
        }
      }
    });
  }

  Future<void> _promptMinLen() async {
    final ctrl = TextEditingController(
      text: ref.read(lineListMinLenProvider).toString(),
    );
    final result = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(24),
        title: const Text('字数阈值', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: '选大于多少字的行',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) {
            final n = int.tryParse(v.trim());
            if (n != null && n >= 0) Navigator.pop(c, n);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              if (n != null && n >= 0) Navigator.pop(c, n);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    ref.read(lineListMinLenProvider.notifier).state = result;
    _selectLongLines(result);
  }

  // ==================== 工具条操作 ====================

  Future<void> _copySelected() async {
    if (_selectedLines.isEmpty) return;
    final sorted = _selectedLines.toList()..sort();
    final lines = _lines;
    final text = sorted
        .where((i) => i >= 0 && i < lines.length)
        .map((i) => lines[i])
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${sorted.length} 行')),
    );
  }

  void _deleteSelected() {
    if (_selectedLines.isEmpty) return;
    final remove = _selectedLines.toSet();
    final lines = _lines;
    final remaining = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (!remove.contains(i)) remaining.add(lines[i]);
    }
    _selectedLines.clear();
    _anchorLine = null;
    _textCtrl.text = remaining.join('\n');
    setState(() {});
    // ★ 内容变短后把滚动位置夹回合法范围，否则视口会停在越界位置
    _clampVerticalScroll();
  }

  // ★ 把竖向滚动夹回合法范围（内容变短时用）
  void _clampVerticalScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _doClampScroll();
      // 第二帧再夹一次，防止 TextField 内部布局还没更新完
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _doClampScroll();
      });
    });
  }

  void _doClampScroll() {
    if (!_vertCtrl.hasClients) return;
    final max = _vertCtrl.position.maxScrollExtent;
    if (_vertCtrl.offset > max) {
      _vertCtrl.jumpTo(max);
    }
  }

  // ==================== 应用 ====================

  void _apply(String side) {
    final entries = _lines.where((l) => l.isNotEmpty).toList();
    if (entries.isEmpty) {
      _toast('列表里没有可删除的内容');
      return;
    }

    var totalHits = 0;

    if (side == 'left' || side == 'both') {
      final cur = ref.read(preprocessedOriginalProvider);
      if (cur.isNotEmpty) {
        final result = _removeAll(cur, entries);
        totalHits += result.hits;
        if (result.hits > 0) {
          ref.read(editedOriginalProvider.notifier).state = result.text;
        }
      }
    }
    if (side == 'right' || side == 'both') {
      final cur = ref.read(preprocessedModifiedProvider);
      if (cur.isNotEmpty) {
        final result = _removeAll(cur, entries);
        totalHits += result.hits;
        if (result.hits > 0) {
          ref.read(editedModifiedProvider.notifier).state = result.text;
        }
      }
    }

    if (totalHits == 0) {
      _toast('文本里没有出现这些字符串');
      return;
    }

    ref.read(importRevisionProvider.notifier).state++;

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  ({String text, int hits}) _removeAll(String text, List<String> entries) {
    if (text.isEmpty || entries.isEmpty) {
      return (text: text, hits: 0);
    }

    final cleaned = entries.where((e) => e.isNotEmpty).toList();
    if (cleaned.isEmpty) return (text: text, hits: 0);

    cleaned.sort((a, b) => b.length.compareTo(a.length));

    final ac = AhoCorasick(
      patterns: cleaned,
      replacements: List<String>.filled(cleaned.length, ''),
      priorities: List<int>.generate(cleaned.length, (i) => i),
    );

    var hits = 0;
    ac.findAllMatches(text, (_, __, ___) {
      hits++;
    });

    return (text: ac.replaceAll(text), hits: hits);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildEditorArea()),
            _buildToolbar(),
          ],
        ),
      ),
    );
  }

  Widget _buildEditorArea() {
    return Container(
      margin: const EdgeInsets.fromLTRB(1, 6, 1, 0),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildBlockArea(),
          _buildGutter(),
          Container(width: 1, color: Colors.grey.shade300),
          Expanded(child: _buildTextField()),
        ],
      ),
    );
  }

  // ---------- 方块区 ----------

  Widget _buildBlockArea() {
    return SizedBox(
      width: _kBlockAreaWidth,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return ValueListenableBuilder<double>(
              valueListenable: _scrollOffset,
              builder: (context, offset, _) {
                final count = _lineCount;
                final first = _firstVisibleLine(offset);
                final last = _lastVisibleLine(offset, constraints.maxHeight, count);
                // ★ 只建可见区间：原先 for (i < _lineCount) 是全量建再丢弃，
                // 两万行每帧要建两万个 widget；现在固定 40 个上下。
                final children = <Widget>[
                  CustomPaint(
                    size: Size(
                      _kBlockAreaWidth,
                      constraints.maxHeight,
                    ),
                    painter: _ConnectorLinePainter(
                      lineCount: count,
                      firstLine: first,
                      lastLine: last,
                      scrollOffset: offset,
                      selectedLines: _selectedLines,
                    ),
                  ),
                ];
                for (var i = first; i <= last; i++) {
                  children.add(_buildBlock(i, constraints.maxHeight, offset));
                }
                return Stack(
                  clipBehavior: Clip.none,
                  children: children,
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildBlock(int i, double maxHeight, double scrollOffset) {
    final centerY = _kEditorVPad +
        i * _kLineHeight +
        _kLineHeight / 2 -
        scrollOffset;
    final top = centerY - _kBlockSize / 2;
    if (top + _kBlockSize < 0 || top > maxHeight) {
      return const SizedBox.shrink();
    }

    final left = i.isEven ? 0.0 : _kBlockOffset;
    final selected = _selectedLines.contains(i);

    return Positioned(
      left: left,
      top: top,
      width: _kBlockSize,
      height: _kBlockSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggleLine(i),
        onLongPress: () => _rangeSelect(i),
        child: Container(
          decoration: BoxDecoration(
            color: selected ? _kCheckColor : _kBlockBgNormal,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: selected ? _kCheckColor : _kBlockBorderNormal,
              width: selected ? 2 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            '${i + 1}',
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              color: selected ? Colors.white : _kBlockTextNormal,
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 原行号栏 ----------

  Widget _buildGutter() {
    return SizedBox(
      width: _kGutterWidth,
      child: ColoredBox(
        color: Colors.grey.shade50,
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return ValueListenableBuilder<double>(
                valueListenable: _scrollOffset,
                builder: (context, offset, _) {
                  // ★ 同方块区：只建可见区间，不再全量建后丢弃。
                  final count = _lineCount;
                  final first = _firstVisibleLine(offset);
                  final last =
                      _lastVisibleLine(offset, constraints.maxHeight, count);
                  final children = <Widget>[];
                  for (var i = first; i <= last; i++) {
                    children.add(
                        _buildGutterRow(i, constraints.maxHeight, offset));
                  }
                  return Stack(
                    clipBehavior: Clip.none,
                    children: children,
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildGutterRow(int i, double maxHeight, double scrollOffset) {
    final top = _kEditorVPad + i * _kLineHeight - scrollOffset;
    if (top + _kLineHeight < 0 || top > maxHeight) {
      return const SizedBox.shrink();
    }
    final selected = _selectedLines.contains(i);
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      height: _kLineHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggleLine(i),
        onLongPress: () => _rangeSelect(i),
        child: ColoredBox(
          color: selected ? _kSelectedBg : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.only(left: 0, right: 1),
            child: Row(
              children: [
                _buildCheckbox(selected),
                const SizedBox(width: 1),
                Expanded(
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: selected
                          ? _kLineNumSelected
                          : _kLineNumNormal,
                      fontWeight: selected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCheckbox(bool selected) {
    return SizedBox(
      width: 14,
      height: 14,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? _kCheckColor : Colors.transparent,
          border: Border.all(
            color: selected ? _kCheckColor : Colors.grey.shade400,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(2),
        ),
        child: selected
            ? const Icon(Icons.check, size: 10, color: Colors.white)
            : null,
      ),
    );
  }

  // ---------- 编辑区 ----------

  Widget _buildTextField() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = const TextStyle(
          fontSize: _kFontSize,
          fontFamily: 'monospace',
        );

        // ★ 只在文本变化时用 TextPainter 精确测量最宽行，其余时间用缓存。
        // 超长列表（>3000 行）不再同步测量：逐行 layout 每次按键都要几百毫秒，
        // 改成下一帧再测，当帧先用上一次的宽度（差一个字符，肉眼看不出来）。
        final text = _textCtrl.text;
        if (_cachedMaxLineWidthForText != text) {
          final scaler = MediaQuery.textScalerOf(context);
          final bool canDefer = _cachedMaxLineWidth != null && _lines.length > 3000;
          if (canDefer) {
            _scheduleMeasure(text, style, scaler);
          } else {
            _cachedMaxLineWidth =
                _measureMaxLineWidth(_lines, style, scaler);
            _cachedMaxLineWidthForText = text;
          }
        }
        final maxW = _cachedMaxLineWidth ?? 0.0;
        // +16 给 TextField 内部留一点余量，保证一定不折行。
        final needW = maxW + 16;
        final width =
            needW > constraints.maxWidth ? needW : constraints.maxWidth;

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            height: constraints.maxHeight,
            child: Stack(
              children: [
                // ★ 高亮层单独跟着滚动偏移重建，TextField 不被牵动。
                Positioned.fill(
                  child: IgnorePointer(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _scrollOffset,
                      builder: (context, offset, _) => Stack(
                        clipBehavior: Clip.none,
                        children:
                            _buildHighlightLayer(constraints.maxHeight, offset),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(
                    left: 1,
                    right: 4,
                    top: _kEditorVPad,
                  ),
                  child: TextField(
                    controller: _textCtrl,
                    scrollController: _vertCtrl,
                    maxLines: null,
                    expands: true,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    style: style,
                    strutStyle: const StrutStyle(
                      fontSize: _kFontSize,
                      height: _kLineHeight / _kFontSize,
                      forceStrutHeight: true,
                    ),
                    cursorColor: Colors.blue,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 超长列表的测量延后到下一帧做，避免按键时同步量几千行。
  void _scheduleMeasure(String text, TextStyle style, TextScaler scaler) {
    if (_measureScheduledFor == text) return;
    _measureScheduledFor = text;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _textCtrl.text != text) return;
      final w = _measureMaxLineWidth(_lines, style, scaler);
      if (!mounted) return;
      setState(() {
        _cachedMaxLineWidth = w;
        _cachedMaxLineWidthForText = text;
      });
    });
  }

  // ★ 用 TextPainter 精确测量最宽行，返回像素宽度。
  // 行数很多时（>3000）只精测「显示宽度」最大的 24 行——等宽字体下
  // 最宽那行必在其中（CJK 按 2 个字符宽算），结果与全量测量一致，
  // 但省掉几千次 layout。TextPainter 用完必须 dispose（原生段落内存）。
  double _measureMaxLineWidth(
    List<String> lines,
    TextStyle style,
    TextScaler scaler,
  ) {
    if (lines.isEmpty) return 0.0;
    const int exactLimit = 3000;
    const int topK = 24;

    Iterable<String> candidates;
    if (lines.length <= exactLimit) {
      candidates = lines;
    } else {
      final widths = List<int>.filled(lines.length, 0);
      for (var i = 0; i < lines.length; i++) {
        final s = lines[i];
        var w = 0;
        for (final r in s.runes) {
          w += r >= 0x1100 ? 2 : 1;
        }
        widths[i] = w;
      }
      final idx = List<int>.generate(lines.length, (i) => i)
        ..sort((a, b) => widths[b].compareTo(widths[a]));
      candidates = idx.take(topK).map((i) => lines[i]);
    }

    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
    );
    var maxW = 0.0;
    try {
      for (final line in candidates) {
        if (line.isEmpty) continue;
        tp.text = TextSpan(text: line, style: style);
        tp.textScaler = scaler;
        tp.layout();
        if (tp.width > maxW) maxW = tp.width;
      }
    } finally {
      tp.dispose();
    }
    return maxW;
  }

  List<Widget> _buildHighlightLayer(double maxHeight, double offset) {
    if (_selectedLines.isEmpty) return const <Widget>[];
    // ★ 按可见区间遍历（全选两万行时只走 40 行），不再遍历整个选中集合。
    final count = _lineCount;
    final first = _firstVisibleLine(offset);
    final last = _lastVisibleLine(offset, maxHeight, count);
    final out = <Widget>[];
    for (var i = first; i <= last; i++) {
      if (!_selectedLines.contains(i)) continue;
      final top = _kEditorVPad + i * _kLineHeight - offset;
      out.add(Positioned(
        top: top,
        left: 0,
        right: 0,
        height: _kLineHeight,
        child: const IgnorePointer(
          child: ColoredBox(color: _kSelectedBg),
        ),
      ));
    }
    return out;
  }

  // ---------- 工具条 ----------

  Widget _buildToolbar() {
    final hasContent = _hasContent;
    final hasSelection = _selectedLines.isNotEmpty;
    final minLen = ref.watch(lineListMinLenProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: _toolBtn(
                icon: Icons.copy,
                label: '复制行',
                onTap: hasSelection ? _copySelected : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.delete_outline,
                label: '删除行',
                onTap: hasSelection ? _deleteSelected : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.select_all,
                label: '全选',
                onTap: hasContent ? _selectAll : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.deselect,
                label: '退出选择',
                onTap: hasSelection ? _exitSelection : null,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _toolBtn(
                icon: Icons.west,
                label: '删除左侧',
                onTap: hasContent ? () => _apply('left') : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.east,
                label: '删除右侧',
                onTap: hasContent ? () => _apply('right') : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.compare_arrows,
                label: '两侧都删',
                onTap: hasContent ? () => _apply('both') : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.straighten,
                label: '选>$minLen字的行',
                onTap: hasContent ? () => _selectLongLines(minLen) : null,
                onLongPress: hasContent ? _promptMinLen : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _toolBtn({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    final enabled = onTap != null || onLongPress != null;
    final s = Theme.of(context).colorScheme;
    final color = enabled ? s.onSurface : s.onSurface.withOpacity(0.3);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== 连接线 ====================

class _ConnectorLinePainter extends CustomPainter {
  _ConnectorLinePainter({
    required this.lineCount,
    required this.firstLine,
    required this.lastLine,
    required this.scrollOffset,
    required this.selectedLines,
  });

  final int lineCount;
  final int firstLine;
  final int lastLine;
  final double scrollOffset;
  final Set<int> selectedLines;

  @override
  void paint(Canvas canvas, Size size) {
    final paintNormal = Paint()
      ..color = _kConnectorColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final paintSelected = Paint()
      ..color = _kCheckColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    // ★ 只画可见区间的连接线（原先按 lineCount 全跑，两万行每帧两万次）。
    final from = firstLine < 0 ? 0 : firstLine;
    final to = lastLine > lineCount - 1 ? lineCount - 1 : lastLine;
    for (var i = from; i <= to; i++) {
      final centerY = _kEditorVPad +
          i * _kLineHeight +
          _kLineHeight / 2 -
          scrollOffset;
      if (centerY < -20 || centerY > size.height + 20) continue;

      final blockLeft = i.isEven ? 0.0 : _kBlockOffset;
      final blockCenterX = blockLeft + _kBlockSize / 2;
      final selected = selectedLines.contains(i);

      canvas.drawLine(
        Offset(blockCenterX, centerY),
        Offset(size.width, centerY),
        selected ? paintSelected : paintNormal,
      );
    }
  }

  @override
  bool shouldRepaint(_ConnectorLinePainter old) {
    if (old.lineCount != lineCount) return true;
    if (old.firstLine != firstLine) return true;
    if (old.lastLine != lastLine) return true;
    if (old.scrollOffset != scrollOffset) return true;
    if (old.selectedLines.length != selectedLines.length) return true;
    for (final i in selectedLines) {
      if (!old.selectedLines.contains(i)) return true;
    }
    return false;
  }
}
