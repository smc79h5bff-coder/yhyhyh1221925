import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/storage/pref_keys.dart';

import '../../../preprocessing/application/encoding_detector.dart';
import '../../../preprocessing/domain/encoding_type.dart';

/// 对比页长按某行后弹出的「整份源文件迷你编辑器」浮层。
///
/// 设计约束（用户逐轮确认后的定稿）：
/// - 小窗里放的是**磁盘上真实源文件全文**（原编码解码），不是对比页里
///   规范化之后的文本；每次打开都读原文件，保存只写 `.bak` 副本（能原样写回
///   的编码按原编码，UTF-16 / Big5 / Shift-JIS 降级用 UTF-8），原文件永远不动（方向2）。
/// - 窗口形状（图 5 定稿）：一整条 CustomClipper 闭合轮廓，顶部是 B 形标签条
///   （左直右斜、上短下长、四角圆、右端比主体短一截），左下 / 右下为直角
///   ——右下角要贴 ⤡ 缩放把手。标签条 34px 放颜色竖条 / ⋮⋮ 拖动 / 文件名，
///   下面 32px 一整行放按钮。没有行号、没有底栏、没有编码显示。
/// - 标签条显示**真实文件名**（含扩展名，如 `书名.txt`）：这里装的是原文件，
///   不写副本名；书名中间省略保留首尾、扩展名恒显示，窄窗自动降字号
///   (11→10→9)。副本名 `书名 - 副本.txt.bak` 由保存提示与关闭确认框告知用户。
/// - Material 的阴影改用 `_MiniWindowShape`（与裁剪器共用同一条 Path），
///   斜边与底部直角都贴合；颜色竖条给固定高度撑满标签条。
/// - 6 个等高(24px)按钮，顺序固定：帮助(说明) / 设置(字号/窗口宽高/透明度) /
///   搜索(查找替换) / 多行操作 / 保存副本 / 关闭。放不下时这一排可横滑，
///   只留左边缘一个 ← 浮层。
/// - 小窗支持整体透明度调节（设置面板），默认不透明，调低后能透出后面的对比页。
/// - 隐藏系统滚动条，右侧只留一个可拖动滑块；拖标签条移动，右下角 ⤡ 缩放。
/// - 查找替换：两行分组，输入框与按钮统一 28px 高、底线齐平；按钮是带边框的
///   独立小块，宽度不够时整排自动换行（不裁切、不横滑）；面板开着时顶栏的
///   放大镜变成文字「关闭查找」。面板是**浮层**（同设置面板），不占正文高度，
///   限高约 6 成 + 内部竖滚，矮窗时正文也不被挤没；不加全屏遮罩，正文可点可滚。
/// - 有未保存改动时点 ×，由用户决定「保存并关闭 / 放弃并关闭 / 取消」，
///   不再强制只能保存。原文件编码无法原样写回时，.bak 降级用 UTF-8 保存
///   （原文件永不动）并挂一条说明；写盘失败时确认框不收起，可重试 / 复制全文。
/// - **定位疑问（2026-11-15 定稿，图 11 + 图 12 甲）**：标签条**最外面**
///   （斜边右侧那片轮廓外空白）浮一个橙色大 ?，上下浮动；只有「本次定位
///   不是唯一确定」才出现。点它展开候选位置浮层（不显示行号、点一行即跳、
///   收起 / 本次隐藏 / 显示更多）。宽松核对只微调、永不否决跳转；
///   文字一个字不改、也不写盘。详情见 _buildDoubtPanel / _miniSplitAndTarget。
/// - **模态 + 单窗切换**：浮层打开后，只有点「×」才能关闭；单击对比页其它行
///   不会关闭、也不会再弹编辑框。但**长按对比页某行会切换**当前编辑器到那一行
///   对应的文件（保留窗口位置/大小/字号，不叠加新窗，符合「不要叠加」规矩）。
/// - **屏障只盖「内容区」**：屏障从「顶部工具栏 + 文件名栏」之下开始，只在对比
///   左右栏的内容区上做手势拦截。因此顶部的工具栏按钮、文件名栏（含右侧圈圈
///   叹号）仍可点击；它们的弹窗走导航器 Overlay，会自动盖在迷你编辑器之上。
///   点内容区（小窗外）→ 悬浮提示「请先关闭迷你编辑器」；长按内容区某行 →
///   穿透到下层行触发单窗切换。
///   这里用「半透明手势屏障(仅内容区) + 上层小窗」实现，绝不用 showDialog
///   （showDialog 自带点遮罩关闭 / 返回键关闭，正是不要的行为）。
class SourceMiniEditorOverlay extends StatefulWidget {
  const SourceMiniEditorOverlay({
    super.key,
    required this.filePath,
    required this.anchorText,
    this.anchorLine,
    this.lineMap,
    this.lineMapExact,
    this.anchorContext,
    required this.onClose,
    required this.isOriginal,
    required this.onMessage,
    required this.frameKey,
  });

  final String filePath;

  /// 对比页被长按那一行的文本（规范化后）。仅用于在小窗里定位目标行，
  /// 通过「全角↔半角 + 忽略空白」的容错匹配找磁盘原文里对应的那一行。
  final String anchorText;

  /// 长按那行在「规范化文件」里的行号（0 基）。配合 [lineMap] 精确定位；
  /// 为 null 或映射不到时回退 [anchorText] 模糊匹配。
  final int? anchorLine;

  /// 「规范化行号 → 源文件行号」映射表（与 anchorLine 等长使用）。
  /// 由对比页传入（懒加载 provider，首次打开小窗时才计算）。
  final List<int>? lineMap;

  /// 上面那张表每格的可信度：true = 内容精确命中的锚点，false = 插值估出来的行。
  /// 只用来判断「这次定位有没有疑问」，不参与跳转计算本身。
  final List<bool>? lineMapExact;

  /// 长按那行在「规范化文本」里的上下文（±2 行）。只用来给候选位置
  /// 按「邻居像不像」排序，不否决、不写盘。
  final List<String>? anchorContext;

  /// 长按的是左栏（源文件=true）还是右栏（修改文件=false）。
  /// 用于顶栏画红/绿竖条，与对比页文件标题栏保持一致。
  final bool isOriginal;

  /// 真正关闭浮层（移除整屏屏障）。由对比页控制。
  final VoidCallback onClose;

  final void Function(String msg) onMessage;

  /// 小窗本体的 GlobalKey。由对比页持有，用于读取「是否有未保存改动」、
  /// 以及触发「保存」——切换文件前，若当前文件有改动要先存盘或丢弃；
  /// 关闭确认框里的「保存并关闭」也从这里触发写盘。
  final GlobalKey<MiniWindowFrameState>? frameKey;

  @override
  State<SourceMiniEditorOverlay> createState() =>
      _SourceMiniEditorOverlayState();
}

class _SourceMiniEditorOverlayState extends State<SourceMiniEditorOverlay> {
  double _left = 64;
  double _top = 130;
  double _width = 470;
  double _height = 390;

  // 记住上次的窗口大小（SharedPreferences）。字号/透明度/正则开关由
  // MiniWindowFrameState 各自持久化。位置（_left/_top）不记，每次回默认。
  SharedPreferences? _prefs;
  Timer? _sizeSaveTimer;
  double? _pendingSaveW;
  double? _pendingSaveH;

  @override
  void initState() {
    super.initState();
    _loadSavedSize();
  }

  Future<void> _loadSavedSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      if (!mounted) return;
      setState(() {
        _width = prefs.getDouble(PrefKeys.miniEditorWidth) ?? _width;
        _height = prefs.getDouble(PrefKeys.miniEditorHeight) ?? _height;
      });
    } catch (_) {
      // 读不到就沿用默认尺寸，不影响使用。
    }
  }

  /// 防抖保存窗口大小：拖拽/滑块会高频触发，不能每次都写盘。
  void _scheduleSizeSave(double w, double h) {
    _pendingSaveW = w;
    _pendingSaveH = h;
    _sizeSaveTimer?.cancel();
    _sizeSaveTimer = Timer(const Duration(milliseconds: 400), () {
      _prefs?.setDouble(PrefKeys.miniEditorWidth, w);
      _prefs?.setDouble(PrefKeys.miniEditorHeight, h);
    });
  }

  // 轻触内容区时的悬浮提示（替代「静默吞掉」）：提醒先关闭迷你编辑器。
  bool _hintVisible = false;
  String _hintText = '';
  Timer? _hintTimer;

  // 关闭确认框：仅在小窗有未保存改动时弹出，三个按钮由用户决定
  // 「保存并关闭 / 放弃并关闭 / 取消」。
  bool _confirmOpen = false;
  // 「保存并关闭」正在写盘时挡住重复点击。
  bool _confirmBusy = false;
  // 保存失败的原因。非空时确认框不收起，改为显示原因 + 重试 / 复制全文。
  String? _confirmError;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final maxW = c.maxWidth;
      final maxH = c.maxHeight;

      // 顶部保留区：状态栏 + 主工具栏(48) + 文件名栏(34)。屏障从它之下开始，
      // 小窗上边界也钳制在它之下，保证顶部栏始终可见、可点。
      final reserve = MediaQuery.of(context).padding.top + 48 + 34;

      final w = _width.clamp(160.0, math.max(160.0, maxW - 16)).toDouble();
      // 最小高度统一用 _kMiniMinHeight（原 120 + 新增标签条 34）。
      final h = _height
          .clamp(_kMiniMinHeight, math.max(_kMiniMinHeight, maxH - 16))
          .toDouble();
      final tMax = math.max(reserve, maxH - h);
      final l = _left.clamp(0.0, math.max(0.0, maxW - w)).toDouble();
      final t = _top.clamp(reserve, tMax).toDouble();

      final children = <Widget>[
        // ★ 模态屏障（半透明，仅内容区）：从「工具栏 + 文件名栏」之下开始，
        // 只拦截对比左右栏的内容区手势，顶部栏不在屏障内，仍可点击。
        // - 轻触内容区 → onTap 弹「请先关闭迷你编辑器」悬浮提示。
        // - 长按内容区某行 → 这里没有 LongPressRecognizer，手势穿透到下层行，
        //   由行自己的长按处理去「切换」当前编辑器（单窗切换，不叠加）。
        // - 顶部工具栏 / 文件名栏（在屏障之上）仍可点击；它们的弹窗走导航器
        //   Overlay，会自动盖在迷你编辑器之上。
        // 屏障放在小窗下层：点小窗时小窗先命中；点内容区时屏障命中。
        Positioned(
          top: reserve,
          left: 0,
          right: 0,
          bottom: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => _showHint('请先关闭迷你编辑器，再操作对比页'),
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: l,
          top: t,
          child: SizedBox(
            width: w,
            height: h,
            child: _MiniWindowFrame(
              key: widget.frameKey,
              filePath: widget.filePath,
              anchorText: widget.anchorText,
              anchorLine: widget.anchorLine,
              lineMap: widget.lineMap,
              lineMapExact: widget.lineMapExact,
              anchorContext: widget.anchorContext,
              isOriginal: widget.isOriginal,
              onClose: widget.onClose,
              // 内部回调：× 被按下且有未保存改动时，由本浮层自己弹确认框。
              onCloseRequested: () {
                if (!mounted) return;
                setState(() {
                  _confirmOpen = true;
                  _confirmError = null;
                });
              },
              onMessage: widget.onMessage,
              currentWidth: w,
              currentHeight: h,
              maxW: maxW,
              maxH: maxH,
              onDrag: (dx, dy) => setState(() {
                _left += dx;
                _top = (_top + dy).clamp(reserve, tMax);
              }),
              onResize: (dw, dh) => setState(() {
                _width =
                    (_width + dw).clamp(160.0, math.max(160.0, maxW - 16));
                _height = (_height + dh).clamp(
                    _kMiniMinHeight, math.max(_kMiniMinHeight, maxH - 16));
                _scheduleSizeSave(_width, _height);
              }),
              onSetSize: (nw, nh) => setState(() {
                _width = nw;
                _height = nh;
                _scheduleSizeSave(_width, _height);
              }),
            ),
          ),
        ),
      ];

      // 轻触内容区时的悬浮提示（替代「静默吞掉」）。
      if (_hintVisible) {
        children.add(_buildHint());
      }

      // 关闭确认框盖在最上层（含半透明背景），且背景点不动——必须选按钮。
      if (_confirmOpen) {
        children.add(_buildCloseConfirm());
      }

      return Stack(children: children);
    });
  }

  /// 关闭确认框：有未保存改动时把选择权交给用户——
  /// 保存并关闭（写 .bak 成功后关窗）/ 放弃并关闭（直接关）/ 取消（回编辑）。
  /// 保存失败时弹窗不收起：显示原因，并多出「复制全文 / 重试保存」，
  /// 保证改动不会因为一次写盘失败就白白丢掉。
  Widget _buildCloseConfirm() {
    final s = Theme.of(context).colorScheme;
    final failed = _confirmError != null;
    // 三个按钮到底「保存了什么」要说清楚：标签条只显示原文件名，
    // 副本名只有保存提示和这里会告诉用户。
    final srcName = _fileNameOf(widget.filePath);
    final bakName = _bakFileNameOf(widget.filePath);
    final body = '小窗里有未保存的改动。\n'
        '「保存并关闭」= 把当前内容写成副本「${_shortName(bakName)}」，'
        '原文件「${_shortName(srcName)}」一个字都不动；\n'
        '「放弃并关闭」= 丢弃改动，什么都不写，直接关窗；\n'
        '「取消」= 回到编辑，改动还在。';
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {}, // 点背景不关闭，必须选按钮
        child: Container(
          color: Colors.black.withValues(alpha: 0.35),
          child: Center(
            child: Material(
              elevation: 10,
              borderRadius: BorderRadius.circular(10),
              color: s.surface,
              child: SizedBox(
                width: 304,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('关闭迷你编辑器',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: s.onSurface)),
                      const SizedBox(height: 10),
                      Text(body,
                          style: TextStyle(fontSize: 13, color: s.onSurface)),
                      if (failed) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: s.errorContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '保存没成功：$_confirmError\n改动还在小窗里，没有丢失。',
                            style: TextStyle(
                                fontSize: 12, color: s.onErrorContainer),
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      // Wrap：按钮放不下时自动换行，绝不横向溢出。
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 2,
                        runSpacing: 2,
                        children: [
                          TextButton(
                            onPressed: _confirmBusy
                                ? null
                                : () => setState(() {
                                      _confirmOpen = false;
                                      _confirmError = null;
                                    }),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed:
                                _confirmBusy ? null : () => widget.onClose(),
                            child: const Text('放弃并关闭'),
                          ),
                          if (failed)
                            TextButton(
                              onPressed:
                                  _confirmBusy ? null : _confirmCopyAll,
                              child: const Text('复制全文'),
                            ),
                          if (failed)
                            FilledButton(
                              onPressed:
                                  _confirmBusy ? null : _confirmSaveAndClose,
                              child: Text(
                                  _confirmBusy ? '保存中…' : '重试保存'),
                            ),
                          if (!failed)
                            FilledButton(
                              onPressed:
                                  _confirmBusy ? null : _confirmSaveAndClose,
                              child: Text(
                                  _confirmBusy ? '保存中…' : '保存并关闭'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 「保存并关闭」：先写 .bak，只有写成功了才真的关窗。
  /// 失败时**不收起确认框**：留在框里显示原因，给「重试保存 / 复制全文」，
  /// 改动始终还在屏幕上，绝不会「提示失败却把人踢出去」或逼用户放弃。
  Future<void> _confirmSaveAndClose() async {
    if (_confirmBusy) return;
    setState(() {
      _confirmBusy = true;
      _confirmError = null;
    });
    final frame = widget.frameKey?.currentState;
    bool ok = false;
    if (frame != null) ok = await frame.saveExternal();
    if (!mounted) return;
    if (ok) {
      setState(() {
        _confirmBusy = false;
        _confirmOpen = false;
        _confirmError = null;
      });
      widget.onClose();
      return;
    }
    setState(() {
      _confirmBusy = false;
      _confirmError = frame?.lastSaveError ?? '保存未完成，请重试';
    });
  }

  /// 保存彻底失败时的兜底：把当前全文复制到剪贴板，改动至少能带走。
  Future<void> _confirmCopyAll() async {
    if (_confirmBusy) return;
    final frame = widget.frameKey?.currentState;
    if (frame == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: frame.allText));
      widget.onMessage('全文已复制，可粘贴到别处保存');
    } catch (e) {
      widget.onMessage('复制失败：$e（改动仍在，可再试一次或先取消）');
    }
  }

  /// 轻触内容区（小窗外）时的悬浮提示：提醒先关闭迷你编辑器。
  /// 不阻塞、1.6s 后自动消失；点小窗本身不受影响。
  Widget _buildHint() {
    final s = Theme.of(context).colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 28,
      child: IgnorePointer(
        child: Center(
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            color: s.inverseSurface,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Text(_hintText,
                  style: TextStyle(fontSize: 12, color: s.onInverseSurface)),
            ),
          ),
        ),
      ),
    );
  }

  void _showHint(String msg) {
    _hintTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _hintText = msg;
      _hintVisible = true;
    });
    _hintTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _hintVisible = false);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    // 关闭瞬间把最后一次尺寸补写进去（防抖可能还没触发）。
    final pw = _pendingSaveW;
    final ph = _pendingSaveH;
    if (pw != null && ph != null) {
      _prefs?.setDouble(PrefKeys.miniEditorWidth, pw);
      _prefs?.setDouble(PrefKeys.miniEditorHeight, ph);
    }
    _sizeSaveTimer?.cancel();
    super.dispose();
  }
}

// ==================== 小窗本体 ====================

/// 能「原样往返」的编码按原编码写；UTF-16 / Big5 / Shift-JIS 没有可靠的
/// 对称编码器，标成 unsupported，保存时 .bak 降级用 UTF-8 写（原文件永不动，
/// .bak 只是快照、打开也永远读原文件，所以不会造成回读错乱）。
enum _MiniSaveEncoding { utf8, utf8bom, gbk, unsupported }

/// 从完整路径取真实文件名（含扩展名）。标签条、保存提示、关闭确认框共用，
/// 保证三处说的是同一个名字，不会出现「标签说副本、提示说原名」的错位。
String _fileNameOf(String path) =>
    path.replaceAll('\\', '/').split('/').last;

/// 悬浮提示 / 弹窗里用的短名字：太长时省略中间，避免把一句话撑出屏幕。
/// 尾巴一定要留，这样 `书名 - 副本.txt.bak` 这类后缀永远看得见。
String _shortName(String name) {
  if (name.length <= 22) return name;
  return '${name.substring(0, 10)}…${name.substring(name.length - 10)}';
}

/// 副本文件名（用户定稿）：`书名.txt` → `书名 - 副本.txt.bak`。
/// 「 - 副本」插在扩展名之前，末尾仍保留 `.bak`，一眼能看出是快照文件。
/// 没有扩展名的文件（如 `README`）→ `README - 副本.bak`。
/// 保存提示、关闭确认框、帮助说明、实际写盘路径全部走这里，保证四处一致。
String _bakFileNameOf(String path) {
  final name = _fileNameOf(path);
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return '$name - 副本.bak';
  return '${name.substring(0, dot)} - 副本${name.substring(dot)}.bak';
}

/// 副本完整路径：和原文件同一个目录，只把文件名换成副本名。
String _bakPathOf(String path) {
  final name = _fileNameOf(path);
  final prefix = path.substring(0, path.length - name.length);
  return '$prefix${_bakFileNameOf(path)}';
}

// ==================== 窗口形状（图 5 定稿） ====================

/// 顶部标签条 34 + 按钮行 32 = 66；查找 / 设置浮层都从这下面开始。
const double _kTabH = 34.0;
const double _kBtnBarH = 32.0;
const double _kTabCorner = 10.0;

/// 斜边的水平投影、标签条右端比主体短的一截。
const double _kTabSlant = 26.0;
const double _kTabShortBy = 56.0;

/// 窗口最小高度：原 120 + 新增标签条 34，保证正文可用高度不比原来少。
/// 所有「最小高度」口径（外层钳制、缩放钳制、设置滑块下限）共用这一个值。
const double _kMiniMinHeight = 154.0;

/// 整块窗口轮廓：顶部是 B 形圆角标签条（左直、右斜、上短下长、右端比
/// 主体短一截），与主体是**同一条闭合 Path**，没有拼接缝（图 4-③）。
/// 顶部各角（含斜边两端）与主体右上角全圆角；**左下 / 右下是直角**——
/// 右下角要贴 ⤡ 缩放把手，圆角会把它裁掉、也不好按。
class _MiniWindowClipper extends CustomClipper<Path> {
  const _MiniWindowClipper({
    required this.tabH,
    required this.corner,
    required this.slant,
    required this.shortBy,
  });

  final double tabH;
  final double corner;
  final double slant;
  final double shortBy;

  Path build(Rect r) {
    final double w = r.width;
    // 极窄窗口时按比例收一点，避免斜边起点跑到左边圆角之外。
    final double c = math.min(corner, w * 0.08);
    final double sb = math.min(shortBy, w * 0.28);
    final double sl = math.min(slant, w * 0.16);
    final double sx = r.right - sb - sl; // 斜边上端 x
    final double ex = r.right - sb; // 斜边下端 = 标签条右端 x
    final p = Path();
    // 左边缘：标签条左下与主体左上是一段连续的直线。
    p.moveTo(r.left, r.top + tabH + c);
    p.lineTo(r.left, r.top + c);
    p.quadraticBezierTo(r.left, r.top, r.left + c, r.top); // 标签左上圆角
    p.lineTo(sx - c, r.top);
    p.quadraticBezierTo(sx, r.top, sx + c * 0.7, r.top + c * 0.7);
    p.lineTo(ex - c * 0.6, r.top + tabH - c * 0.6);
    p.quadraticBezierTo(
        ex, r.top + tabH, ex + c * 0.5, r.top + tabH); // 斜边下端圆滑接主体顶边
    p.lineTo(r.right - c, r.top + tabH);
    p.quadraticBezierTo(
        r.right, r.top + tabH, r.right, r.top + tabH + c); // 主体右上圆角
    p.lineTo(r.right, r.bottom); // 右下：直角
    p.lineTo(r.left, r.bottom); // 左下：直角
    p.close();
    return p;
  }

  @override
  Path getClip(Size size) => build(Rect.fromLTWH(0, 0, size.width, size.height));

  @override
  bool shouldReclip(covariant _MiniWindowClipper old) =>
      old.tabH != tabH ||
      old.corner != corner ||
      old.slant != slant ||
      old.shortBy != shortBy;
}

/// 与 _MiniWindowClipper **完全同一条轮廓**的 ShapeBorder。Material 的阴影是
/// 按 shape.getOuterPath 画的，换成它之后标签条右上斜切那块不再露出矩形方影。
/// 直接持有同一个 clipper 实例：形状参数只写一份，永远不会对不上。
class _MiniWindowShape extends ShapeBorder {
  const _MiniWindowShape(this.clipper);

  final _MiniWindowClipper clipper;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      clipper.build(rect);

  // 描边仍由 _MiniOutlinePainter 负责（要放在 ClipPath 外才不会被裁半根线），
  // 这里留空，避免画两遍。
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;

  // 形状不跟别的形状做插值；但 a / b 为 null 时要沿用基类的语义
  // （从「无形状」过渡时返回 scale(t)），否则首次构建阴影会短暂消失。
  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) =>
      a == null ? scale(t) : null;

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) =>
      b == null ? scale(1.0 - t) : null;
}

/// 沿同一条轮廓画一圈细边框。放在 ClipPath **外面**，否则描边会被裁掉一半。
class _MiniOutlinePainter extends CustomPainter {
  const _MiniOutlinePainter({required this.clipper, required this.color});

  final _MiniWindowClipper clipper;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      clipper.build(Rect.fromLTWH(0, 0, size.width, size.height)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniOutlinePainter old) =>
      old.color != color ||
      old.clipper.tabH != clipper.tabH ||
      old.clipper.corner != clipper.corner ||
      old.clipper.slant != clipper.slant ||
      old.clipper.shortBy != clipper.shortBy;
}

class _MiniWindowFrame extends StatefulWidget {
  const _MiniWindowFrame({
    super.key,
    required this.filePath,
    required this.anchorText,
    this.anchorLine,
    this.lineMap,
    this.lineMapExact,
    this.anchorContext,
    required this.onClose,
    required this.isOriginal,
    required this.onCloseRequested,
    required this.onMessage,
    required this.currentWidth,
    required this.currentHeight,
    required this.maxW,
    required this.maxH,
    required this.onDrag,
    required this.onResize,
    required this.onSetSize,
  });

  final String filePath;
  final String anchorText;

  /// 长按那行在「规范化文件」里的行号（0 基）。
  final int? anchorLine;

  /// 「规范化行号 → 源文件行号」映射表。优先用它精确定位。
  final List<int>? lineMap;

  /// 每格是否为精确锚点（false = 插值估计格 → 本次定位有疑问）。
  final List<bool>? lineMapExact;

  /// 长按那行在规范化文本里的上下文（±2 行）。给候选位置排序用。
  final List<String>? anchorContext;

  /// 长按的是左栏（源文件=true）还是右栏（修改文件=false）。
  final bool isOriginal;

  final VoidCallback onClose;

  /// 顶栏 × 被按下、且小窗里有未保存改动时，由外层弹三按钮确认框。
  final VoidCallback onCloseRequested;

  final void Function(String msg) onMessage;
  final double currentWidth;
  final double currentHeight;
  final double maxW;
  final double maxH;
  final void Function(double dx, double dy) onDrag;
  final void Function(double dw, double dh) onResize;
  final void Function(double w, double h) onSetSize;

  @override
  State<_MiniWindowFrame> createState() => MiniWindowFrameState();
}

class MiniWindowFrameState extends State<_MiniWindowFrame> {
  // ---- 行虚拟化编辑区（机制参照文件浏览器的行编辑器） ----
  /// 事实来源：每行文本（不含行尾换行符），空字符串元素 = 空行。
  /// 大文件不再整篇塞进一个 TextField（全文排版正是卡顿白屏的根源），
  /// 只构建可见行，900KB / 3MB 都秒开、丝滑。
  List<String> _lines = const <String>[];
  final ItemScrollController _itemScroll = ItemScrollController();
  final ItemPositionsListener _itemPositions = ItemPositionsListener.create();

  /// 行号 → 当前活着的行 controller / 焦点节点登记表。
  /// controller 和焦点节点由每行自己创建/销毁，这里只登记引用，
  /// 供「替换当前命中」直接改可见行文本、跳行后补高亮/焦点。
  final Map<int, _MiniTextController> _ctrls = {};
  final Map<int, FocusNode> _focusMap = {};
  int? _rangeLine;

  /// 原文件换行风格（CRLF / LF）：保存时按原样拼回，一个字节不多不少。
  bool _crlf = false;

  /// 目标行（0-based）：长按对比行定位到的行，整行黄底。
  int? _targetLine;

  final TextEditingController _find = TextEditingController();
  final TextEditingController _replace = TextEditingController();

  bool _loading = true;
  String? _loadError;
  bool _saving = false;
  bool _dirty = false;

  /// 装载代数：每次 _load() 自增。连续快速切换文件时，前一次的 compute
  /// 可能晚于后一次完成，完成后先比对代数、不等就直接丢弃结果，
  /// 防止「小窗显示 A 文件的内容、锚点却是 C 行」的串台。
  int _loadSeq = 0;

  /// 给文本框程序化赋值时临时置位，避免「ctrl.text = …」同步触发 onChanged
  /// 把刚加载的文件误判成「有未保存改动」（Flutter 的 TextField 在控件已挂载时，
  /// 程序化改 controller.text 会触发 onChanged）。首次打开时文本框尚未挂载、
  /// onChanged 还没监听所以没事；但「长按切换文件」复用同一状态时会中招。
  bool _suppressDirty = false;

  bool _showFindReplace = false;
  bool _showSettings = false;
  bool _regexOn = false;

  // ---- 定位疑问：橙色 ? 与候选位置面板（2026-11-15 定稿，图 11 + 图 12 甲） ----
  /// 本次定位是否有疑问：映射表标「估计格」、宽松核对命中 ≠ 1 行，
  /// 或映射根本不可用。精确锚点 + 唯一命中时保持完全静默。
  bool _doubtActive = false;
  /// 「本次隐藏」或选中候选后淡出，只对本次打开有效；重新打开 / 切换行会重置。
  bool _doubtHidden = false;
  /// 候选位置面板是否展开（与查找 / 设置面板互斥）。
  bool _showDoubtPanel = false;
  /// 面板默认显示 8 条，点「显示更多」展开全部。
  bool _doubtShowAll = false;
  /// 候选行号，已排序：当前定位 → 宽松命中 → 邻近行。**界面不显示行号**，
  /// 这些数字只留在程序内部用来跳转。
  List<int> _doubtCandidates = const <int>[];
  /// 宽松核对命中的行（按相像程度降序），用于面板里的「最像 / 包含」标记。
  List<int> _doubtHits = const <int>[];
  double _fontSize = 13;
  double _opacity = 1.0;

  /// 上次的小窗设置（字号/透明度/正则开关），initState 里异步恢复。
  SharedPreferences? _prefs;
  _MiniSaveEncoding _saveEncoding = _MiniSaveEncoding.utf8;
  String _encodingLabel = '';

  /// 最近一次保存失败的原因（成功时清空）。关闭确认框据此显示重试 / 复制全文。
  String? get lastSaveError => _lastSaveError;
  String? _lastSaveError;

  /// 当前编辑中的全文，供「复制全文」兜底用。
  String get allText => _lines.join(_crlf ? '\r\n' : '\n');

  /// 不支持原样写回的编码才挂说明条；常规文件不占这 22px 高度。
  double get _noticeH =>
      _saveEncoding == _MiniSaveEncoding.unsupported ? 22.0 : 0.0;

  final List<_LineHit> _hits = <_LineHit>[];
  int _hitIndex = -1;

  // ---- 多选行（复制/删除连续多行），入口在顶栏「多选」按钮 ----
  bool _multiSelectMode = false;
  bool _pickingRange = false;
  final Set<int> _multiSelected = <int>{};
  int? _rangeStart;
  final Map<int, String> _pendingSplits = <int, String>{};

  // 顶栏 / 底部多选操作栏的横向滚动：左边缘浮层只在「左边还有被挤没的按钮」
  // 时出现。直接用 AnimatedBuilder 监听 controller.pixels，滚动中实时刷新、
  // 只重建浮层这一小块，不 setState 整个小窗。
  // 注意 reverse:true 的方向：pixels==0 时内容右对齐，末尾按钮（× / 保存副本）
  // 贴右可见、开头按钮（? / 设置）被挤在左边屏幕外；pixels 变大才把左边按钮
  // 露出来，pixels==maxScrollExtent 时到「最左端」、已经没有可露的了。
  // 所以判据是 pixels < maxScrollExtent，点浮层做 pixels+80（旧版写反过）。
  // 右边（× 一侧）不放浮层：× 是唯一关闭方式，永远不能被压住。
  final ScrollController _topBarScroll = ScrollController();
  final ScrollController _multiBarScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _find.addListener(_onFindChanged);
    _loadPrefs();
    _load();
  }

  /// 恢复上次的小窗设置：字号 / 透明度 / 正则开关。
  /// 窗口宽高在外层浮层（_SourceMiniEditorOverlayState）里恢复，分工不同。
  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _prefs = prefs;
        _fontSize = prefs.getDouble(PrefKeys.miniEditorFontSize) ?? _fontSize;
        _opacity = prefs.getDouble(PrefKeys.miniEditorOpacity) ?? _opacity;
        _regexOn = prefs.getBool(PrefKeys.miniEditorRegexOn) ?? _regexOn;
      });
    } catch (_) {
      // 读不到就用默认值。
    }
  }

  void _onFindChanged() {
    _refreshHits();
  }

  @override
  void dispose() {
    _find.removeListener(_onFindChanged);
    _find.dispose();
    _replace.dispose();
    // 行 controller / 焦点节点由各行自己销毁；此时行已全部卸载，兜底清一次。
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _ctrls.clear();
    for (final n in _focusMap.values) {
      n.dispose();
    }
    _focusMap.clear();
    _topBarScroll.dispose();
    _multiBarScroll.dispose();
    super.dispose();
  }

  /// 对比页长按「另一行」触发单窗切换：filePath / anchorText 变化时分两步走——
  /// 保留窗口位置/大小/字号/透明度等外观状态，只把内容换成新文件并重新定位目标行。
  @override
  void didUpdateWidget(covariant _MiniWindowFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath ||
        widget.anchorText != oldWidget.anchorText ||
        widget.anchorLine != oldWidget.anchorLine) {
      _showFindReplace = false;
      _showSettings = false;
      // 每次从对比页重新跳进来都重新判定一次：橙色 ? 不写设置、
      // 不记住「永久关掉」，长按另一行切换时也会重置。
      _showDoubtPanel = false;
      _doubtActive = false;
      _doubtHidden = false;
      _doubtShowAll = false;
      _doubtCandidates = const <int>[];
      _doubtHits = const <int>[];
      _targetLine = null;
      _hits.clear();
      _hitIndex = -1;
      _rangeLine = null;
      // 旧文件还排在帧末的拆行回调不能带进新文件，直接清掉。
      _pendingSplits.clear();
      _exitMultiSelect();
      _crlf = false;
      _dirty = false;
      _saving = false;
      _load();
    }
  }

  /// 供对比页读取：当前小窗里的改动是否已写进 .bak。切换文件前据此决定是否先询问。
  bool get isDirty => _dirty;

  /// 供对比页 / 关闭确认框调用：把当前内容写入 .bak（原文件不动）；
  /// 不支持原样写回的编码自动降级 UTF-8。
  /// 用于「保存并切换」与「保存并关闭」；返回是否写成功，失败时不要关窗，
  /// 失败原因可从 lastSaveError 读到。
  Future<bool> saveExternal() => _save();

  // -------------------- 行虚拟化：行登记 / 行变化 / 多选行 --------------------

  void _attachCtrl(int i, _MiniTextController c) => _ctrls[i] = c;

  void _detachCtrl(int i, _MiniTextController c) {
    if (identical(_ctrls[i], c)) _ctrls.remove(i);
  }

  void _attachFocus(int i, FocusNode n) => _focusMap[i] = n;

  void _detachFocus(int i, FocusNode n) {
    if (identical(_focusMap[i], n)) _focusMap.remove(i);
  }

  void _onLineChanged(int i, String v) {
    if (i < 0 || i >= _lines.length) return;
    // 内容没变的回调不算改动：程序化改 controller 也会触发 onChanged
    // （行重挂/切换文件后同步文本、setRanges 高亮、设光标都会 notify），
    // 不拦的话刚打开文件就会被误标成「有未保存改动」，点 × 误弹确认框。
    if (_lines[i] == v) return;
    _lines[i] = v;
    if (!_suppressDirty && !_dirty) setState(() => _dirty = true);
  }

  /// 拆行回调：当前行只留首段（head 经 onChanged 写回 _lines），
  /// 其余段落排队到帧末统一插入——TextField 从头到尾只排一行的版。
  void _onLineBreak(int index, String head, String rest) {
    if (index < 0 || index >= _lines.length) return;
    _pendingSplits[index] = rest;
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushSplits());
  }

  void _flushSplits() {
    if (!mounted || _pendingSplits.isEmpty) return;
    final entries = _pendingSplits.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    _pendingSplits.clear();

    var before = -1;
    if (_itemScroll.isAttached &&
        _itemPositions.itemPositions.value.isNotEmpty) {
      before = _itemPositions.itemPositions.value
          .map((p) => p.index)
          .reduce(math.min);
    }

    var delta = 0;
    var shift = 0;
    for (final e in entries) {
      final i = e.key + delta;
      if (i >= _lines.length) continue;
      final segs = e.value.split('\n');
      _lines.insertAll(i + 1, segs);
      delta += segs.length;
      if (before >= 0 && e.key < before) shift += segs.length;
    }
    if (delta == 0) return;
    _clearHitRanges();
    _targetLine = null;
    _dirty = true;
    setState(() {});
    if (before >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _itemScroll.isAttached && _lines.isNotEmpty) {
          _itemScroll.jumpTo(
            index: (before + shift).clamp(0, _lines.length - 1).toInt(),
          );
        }
      });
    }
  }

  /// 聚焦第 idx 行并把光标放到 caretOffset。行是懒构建的，
  /// jump 之后那一帧行才注册焦点节点，所以带重试。
  void _focusLine(int idx, {int? caretOffset}) {
    void attempt(int round) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || round > 6) return;
        final node = _focusMap[idx];
        if (node == null) {
          attempt(round + 1);
          return;
        }
        node.requestFocus();
        final ctrl = _ctrls[idx];
        if (ctrl != null) {
          final len = ctrl.text.length;
          ctrl.selection = TextSelection.collapsed(
              offset: (caretOffset ?? 0).clamp(0, len).toInt());
        }
        _applyHitRange();
      });
    }
    attempt(0);
  }

  // -------------------- 多选行 --------------------

  void _toggleMultiSelect() {
    final entering = !_multiSelectMode;
    setState(() {
      if (_multiSelectMode) {
        _exitMultiSelect();
        return;
      }
      // 进入多选后整行变热区、正文不能再编辑，先收键盘
      // （行为对齐文件浏览器的行编辑器）。
      FocusScope.of(context).unfocus();
      _multiSelectMode = true;
      _pickingRange = false;
      _multiSelected.clear();
      _rangeStart = null;
    });
    // 进入多选时给一次引导：说明「点行选中」和「操作栏可横滑」。
    // 沿用对比页现有的一次性悬浮提示（约 1.8s 自动消失），不打断操作。
    if (entering) {
      widget.onMessage('点一行即可选中；下方操作栏可左右滑动查看更多操作');
    }
  }

  void _exitMultiSelect() {
    _multiSelectMode = false;
    _pickingRange = false;
    _multiSelected.clear();
    _rangeStart = null;
  }

  void _onRowTapInMulti(int idx) {
    if (_pickingRange) {
      // 区间选择：第一下点起点，第二下点终点，[lo, hi] 整段自动勾选。
      if (_rangeStart == null) {
        setState(() => _rangeStart = idx);
        return;
      }
      final s0 = _rangeStart!;
      final lo = math.min(s0, idx);
      final hi = math.max(s0, idx);
      setState(() {
        for (var n = lo; n <= hi; n++) {
          _multiSelected.add(n);
        }
        _rangeStart = null;
        _pickingRange = false;
      });
      widget.onMessage('已勾选第 ${lo + 1}~${hi + 1} 行，共 ${hi - lo + 1} 行');
      return;
    }
    setState(() {
      if (!_multiSelected.remove(idx)) _multiSelected.add(idx);
    });
  }

  Future<void> _copySelected() async {
    if (_multiSelected.isEmpty) {
      widget.onMessage('还没有勾选任何行');
      return;
    }
    final sorted = _multiSelected.toList()..sort();
    final buf = StringBuffer();
    for (var k = 0; k < sorted.length; k++) {
      final i = sorted[k];
      if (i < _lines.length) buf.write(_lines[i]);
      if (k != sorted.length - 1) buf.write('\n');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    widget.onMessage('已复制 ${sorted.length} 行');
  }

  void _deleteSelected() {
    if (_multiSelected.isEmpty) {
      widget.onMessage('还没有勾选任何行');
      return;
    }
    final count = _multiSelected.length;
    final sorted = _multiSelected.toList()..sort();
    for (var k = sorted.length - 1; k >= 0; k--) {
      if (sorted[k] < _lines.length) _lines.removeAt(sorted[k]);
    }
    _multiSelected.clear();
    _rangeStart = null;
    _pickingRange = false;
    _clearHitRanges();
    _targetLine = null;
    _dirty = true;
    setState(() {});
    widget.onMessage('已删除 $count 行（还未保存，保存副本后写入 .bak）');
  }

  void _mergeSelectedWithNext() {
    if (_multiSelected.length != 1) return;
    final i = _multiSelected.first;
    if (i + 1 >= _lines.length) {
      widget.onMessage('已经是最后一行了');
      return;
    }
    _lines[i] = _lines[i] + _lines[i + 1];
    _lines.removeAt(i + 1);
    _exitMultiSelect();
    _clearHitRanges();
    _targetLine = null;
    _dirty = true;
    setState(() {});
    widget.onMessage('已与下一行合并（还未保存）');
  }

  /// 多选操作条：贴小窗内部底部，宽度随窗口；窄时左侧操作横滑，
  /// 右侧「退出多选」恒可见。
  /// 与顶栏共用 _buildLeftOverflowHint：只放左边缘一个浮层，右边不加
  /// （右边是固定的「退出多选」，浮层会压住它）。
  Widget _buildMultiSelectBar(ColorScheme s) {
    final bg = s.surfaceContainerLow;
    return Container(
      height: 30,
      decoration: BoxDecoration(
        color: bg,
        border: Border(top: BorderSide(color: s.outlineVariant, width: 0.5)),
      ),
      child: Row(children: [
        Expanded(
          child: Stack(children: [
            SingleChildScrollView(
              controller: _multiBarScroll,
              scrollDirection: Axis.horizontal,
              reverse: true,
              padding: const EdgeInsets.only(left: 2),
              child: Row(children: [
                _barAction(
                    _pickingRange ? '取消区间' : '区间选择',
                    () => setState(() => _pickingRange = !_pickingRange),
                    s),
                _barAction('复制所选', _copySelected, s),
                _barAction('删除所选', _deleteSelected, s),
                if (_multiSelected.length == 1)
                  _barAction('与下一行合并', _mergeSelectedWithNext, s),
                if (_multiSelected.isNotEmpty)
                  _barAction(
                      '清空勾选',
                      () => setState(() {
                            _multiSelected.clear();
                            _rangeStart = null;
                          }),
                      s),
              ]),
            ),
            _buildLeftOverflowHint(_multiBarScroll, bg, _nudgeMultiBar),
          ]),
        ),
        _barAction('退出多选', _toggleMultiSelect, s),
      ]),
    );
  }

  Widget _barAction(String label, VoidCallback onTap, ColorScheme s) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(label, style: TextStyle(fontSize: 12, color: s.onSurface)),
      ),
    );
  }

  // -------------------- 读取磁盘真实源文件 --------------------

  Future<void> _load() async {
    final seq = ++_loadSeq;
    try {
      // 方向2（2026-11-14 用户定稿）：每次打开都读原文件，基线跟对比页完全一致；
      // .bak 只是「最近一次编辑的快照」，保存时覆盖写，旧副本会被新快照覆盖。
      // 这样不会出现 bak 越滚越偏、和对比页对不上的情况。
      final origFile = File(widget.filePath);
      final file = origFile;
      if (!await file.exists()) {
        throw StateError('源文件不存在：${widget.filePath}');
      }
      final len = await file.length();
      // 2026-11-14 用户改定：不再硬拦大文件，改为软警告（与对比页黄窗同一哲学）。
      // 内存是整个 App 共享的，崩就是全崩，所以警告文案要说明白后果，但不拦死。
      if (len > 20 * 1024 * 1024 && mounted) {
        final mb = (len / (1024 * 1024)).toStringAsFixed(1);
        final go = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (c) => AlertDialog(
            title: const Text('文件较大'),
            content: Text(
              '这个文件有 $mb MB。\n\n'
              '迷你编辑器会把整份文件装载进内存，而对比页本身已经占用了'
              '大量内存——继续打开可能等待较久、明显卡顿，甚至导致整个 '
              'App 闪退（内存不足时系统会杀掉整个 App，不是只关编辑器）。\n\n'
              '更稳妥的做法：退出对比页，在文件浏览器的行编辑器里打开该文件'
              '（那边在空内存里运行，多大文件都能开）。',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('仍要打开'),
              ),
            ],
          ),
        );
        if (go != true) {
          // 用户取消：直接关掉小窗（没装载任何东西，安全退出）。
          if (mounted) widget.onClose();
          return;
        }
        if (!mounted || seq != _loadSeq) return;
      }
      final bytes = await file.readAsBytes();
      final enc = EncodingDetector.detect(bytes);
      final decoded = await EncodingDetector.decodeChunkedAsync(bytes, enc);
      if (!mounted || seq != _loadSeq) return;

      // 不能写死 UTF-8：GBK 家族按 UTF-8 写回会整篇乱码；
      // UTF-8 BOM 要在写回时把 3 字节头补回去；
      // UTF-16 / Big5 / Shift-JIS 标成 unsupported → 保存时 .bak 降级 UTF-8，
      // 并在顶栏下挂一条说明条，改动不会因为编码问题白改。
      final e = decoded.encoding;
      if (e == EncodingType.utf8bom) {
        _saveEncoding = _MiniSaveEncoding.utf8bom;
      } else if (e == EncodingType.gbk ||
          e == EncodingType.gb2312 ||
          e == EncodingType.gb18030) {
        _saveEncoding = _MiniSaveEncoding.gbk;
      } else if (e == EncodingType.utf8 ||
          e == EncodingType.ascii ||
          e == EncodingType.unknown) {
        _saveEncoding = _MiniSaveEncoding.utf8;
      } else {
        _saveEncoding = _MiniSaveEncoding.unsupported;
        _encodingLabel = e.label;
      }

      final text = decoded.text;
      _crlf = text.contains('\r\n');
      // 优先用「规范化行→源文件行」映射表精确定位（对比页传来的 anchorLine），
      // 不再靠内容猜；映射不可用时回退锚文本模糊匹配。
      int? mapped;
      final lm = widget.lineMap;
      final al = widget.anchorLine;
      if (lm != null && al != null && al >= 0 && al < lm.length) {
        final v = lm[al];
        if (v >= 0) mapped = v;
      }
      // 映射表这一格是「内容精确命中的锚点」还是「插值估出来的行」？
      // 估计格 / 映射不可用 / 标记越界 → 本次定位有疑问，亮橙色 ?。
      var estimated = true;
      final lmx = widget.lineMapExact;
      if (lmx != null && al != null && al >= 0 && al < lmx.length) {
        estimated = !lmx[al];
      }
      // ④ 会话内记住纠正：用户之前在候选面板里给同一段文本选过正确的行，
      // 本次直接落到那行（并把 estimated 关掉，不再做 ±8 微调——用户的
      // 选择优先）。只存内存、不写盘，重启 App 后自然清空。
      final memoKey =
          '${widget.filePath}\u0000${_doubtMemoKey(widget.anchorText)}';
      final memoHit = _doubtCorrectionMemo[memoKey];
      if (memoHit != null && memoHit >= 0) {
        mapped = memoHit;
        estimated = false;
      }
      // 拆行 + 目标行定位 + 宽松核对 + 候选位置全丢进后台 isolate
      // （大文件主线程拆行会卡几秒）。isolate 调度失败时回退到主线程同步拆，
      // 功能不丢，只是保守当作「有疑问」。
      try {
        final r = await compute(
            _miniSplitAndTarget, <Object?>[
          text,
          _crlf,
          widget.anchorText,
          mapped,
          estimated,
          widget.anchorContext ?? const <String>[],
        ]);
        if (!mounted || seq != _loadSeq) return;
        _lines = (r[0] as List).cast<String>();
        _targetLine = r[1] as int?;
        _doubtCandidates = (r[2] as List).cast<int>();
        _doubtHits = (r[3] as List).cast<int>();
        // 唯一确定 = 精确锚点 且 全文只宽松命中 1 行。
        // ⚠️「文字不像」绝不是错位信号：规则删广告 / 去水印本来就会改字，
        // 所以哪怕 0 命中也只提示、不否决、不回顶部（广告反例不能误杀）。
        _doubtActive = estimated || _doubtHits.length != 1;
        _doubtHidden = false;
        _doubtShowAll = false;
      } catch (_) {
        if (!mounted || seq != _loadSeq) return;
        _lines = _splitLines(text);
        if (mapped != null) {
          _targetLine = mapped.clamp(0, _lines.length - 1).toInt();
        } else {
          _computeTargetLine();
        }
        // 没走核对 → 保守当「有疑问」；候选只给当前行 + 前后 ±8 行。
        _doubtHits = const <int>[];
        _doubtCandidates =
            _nearbyCandidates(_targetLine ?? 0, _lines.length);
        _doubtActive = true;
        _doubtHidden = false;
        _doubtShowAll = false;
      }
      setState(() {
        _loading = false;
        _loadError = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealTarget());
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  /// 全角转半角 + 去掉所有空白，用来把「对比页规范化后的行」和
  /// 「磁盘原文的行」对上。不依赖行号（去空行已经让行号错位了）。
  static String _norm(String s) {
    final sb = StringBuffer();
    for (final r in s.runes) {
      var c = r;
      if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
      if (c == 0x3000) c = 0x20;
      if (c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A) continue;
      sb.writeCharCode(c);
    }
    return sb.toString();
  }

  /// 按换行符拆行（保留空行；行尾 \r 去掉，保存时按 _crlf 拼回）。
  List<String> _splitLines(String text) {
    if (text.isEmpty) return <String>[''];
    final parts = text.split('\n');
    if (_crlf) {
      for (var i = 0; i < parts.length; i++) {
        final p = parts[i];
        if (p.isNotEmpty && p.endsWith('\r')) {
          parts[i] = p.substring(0, p.length - 1);
        }
      }
    }
    return parts;
  }

  void _computeTargetLine() {
    final anchor = _norm(widget.anchorText);
    if (anchor.isEmpty || _lines.isEmpty) return;
    // 短锚（一个逗号、一个标点等）禁用「包含」匹配：否则会命中文件里所有
    // 含该字符的行，定位漂到错误的行（通常是第一行）。短锚只允许精确相等。
    final allowContains = anchor.length >= 4;
    final key = anchor.length > 16 ? anchor.substring(0, 16) : anchor;

    var best = -1;
    var bestScore = -1;
    for (var i = 0; i < _lines.length; i++) {
      final nl = _norm(_lines[i]);
      var score = -1;
      if (nl.isEmpty) {
        // 空行不匹配
      } else if (nl == anchor) {
        score = 1000000;
      } else if (allowContains && nl.contains(anchor)) {
        score = 100000 + anchor.length;
      } else if (anchor.contains(nl) && nl.length >= 8) {
        score = 10000 + nl.length;
      } else if (allowContains && key.length >= 6 && nl.contains(key)) {
        score = 1000 + key.length;
      }
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }

    if (best < 0 || bestScore < 0) return;
    _targetLine = best;
  }

  void _revealTarget() {
    if (!mounted || _lines.isEmpty) return;
    // 定位失败（映射不到 / 匹配不到）→ 按用户要求静默回顶部，不弹任何提示。
    final idx = (_targetLine ?? 0).clamp(0, _lines.length - 1).toInt();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_itemScroll.isAttached) {
        _itemScroll.jumpTo(index: idx);
      }
      _focusLine(idx, caretOffset: 0);
      _applyHitRange();
      if (mounted) setState(() {});
    });
  }

  // -------------------- 定位疑问：橙色 ? 与候选面板（图 11 + 图 12 甲） --------------------

  /// isolate 调度失败时的兜底候选：当前定位行 + 前后 ±8 行，去重。
  List<int> _nearbyCandidates(int center, int total) {
    if (total <= 0) return const <int>[];
    final c = center.clamp(0, total - 1).toInt();
    final out = <int>[c];
    final seen = <int>{c};
    for (var d = 1; d <= 8; d++) {
      for (final k in <int>[c - d, c + d]) {
        if (k >= 0 && k < total && seen.add(k)) out.add(k);
      }
    }
    return out;
  }

  /// 点标签最外面的橙色 ?：展开候选面板，与查找 / 设置面板互斥。
  void _toggleDoubtPanel() {
    setState(() {
      _showDoubtPanel = !_showDoubtPanel;
      if (_showDoubtPanel) {
        _showFindReplace = false;
        _showSettings = false;
        _doubtShowAll = false;
      }
    });
  }

  /// 点候选某一行：只把黄底高亮 / 光标挪过去，**文字一个字不改、不写盘**；
  /// 随后橙色 ? 淡出（本次隐藏）。「收起 ✕」不走这里，位置保持不变。
  void _pickDoubtCandidate(int line) {
    if (line < 0 || line >= _lines.length) return;
    // ④ 记住用户的纠正：同会话内再长按同一段文本，直接落到用户选过的行。
    // 上限 200 条，超过就丢最早的，避免内存无限涨。
    if (line != _targetLine) {
      final key =
          '${widget.filePath}\u0000${_doubtMemoKey(widget.anchorText)}';
      if (_doubtCorrectionMemo.length >= 200) {
        _doubtCorrectionMemo.remove(_doubtCorrectionMemo.keys.first);
      }
      _doubtCorrectionMemo[key] = line;
    }
    setState(() {
      _targetLine = line;
      _showDoubtPanel = false;
      _doubtHidden = true;
    });
    _revealTarget();
  }

  Widget _doubtAction(ColorScheme s, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(label,
            style: TextStyle(fontSize: 11, color: s.primary)),
      ),
    );
  }

  /// 图 12 甲：候选位置列表浮层。**不显示行号**，只给「磁盘原文 + 标记」。
  /// 列表里摆的是磁盘原文全文（长行自动中间省略），广告 / 水印被删的那半句
  /// 一眼就能认出属于哪一行，不需要程序去算相似度。
  Widget _buildDoubtPanel(ColorScheme s) {
    final all = _doubtCandidates;
    final shownCount = _doubtShowAll ? all.length : math.min(8, all.length);
    final shown = all.take(shownCount).toList();
    final target = _targetLine ?? (all.isEmpty ? -1 : all.first);
    // 除「当前定位」外最贴合的那一条标「最像」，其余命中行标「包含」。
    var bestHit = -1;
    for (final h in _doubtHits) {
      if (h != target) {
        bestHit = h;
        break;
      }
    }
    return Container(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: s.surfaceContainerLow,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(6)),
            ),
            child: Row(children: [
              const Expanded(
                child: Text(
                  '这行没找到唯一位置 · 点一行跳过去（不改字、不写盘）',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11),
                ),
              ),
              _doubtAction(s, '收起 ✕',
                  () => setState(() => _showDoubtPanel = false)),
              const SizedBox(width: 6),
              _doubtAction(s, '本次隐藏', () => setState(() {
                    _showDoubtPanel = false;
                    _doubtHidden = true;
                  })),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Row(children: [
              Expanded(
                child: Text('该行磁盘原文',
                    style: TextStyle(
                        fontSize: 10,
                        color: s.onSurface.withValues(alpha: 0.6)))),
              Text('标记',
                  style: TextStyle(
                      fontSize: 10,
                      color: s.onSurface.withValues(alpha: 0.6))),
            ]),
          ),
          ...shown.map((line) => _doubtRow(s, line, target, bestHit)),
          if (all.length > 8)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
              child: _doubtAction(
                  s,
                  _doubtShowAll
                      ? '收起列表'
                      : '显示更多（共 ${all.length} 处）',
                  () => setState(() => _doubtShowAll = !_doubtShowAll)),
            ),
        ],
      ),
    );
  }

  Widget _doubtRow(ColorScheme s, int line, int target, int bestHit) {
    if (line < 0 || line >= _lines.length) return const SizedBox.shrink();
    final isCurrent = line == target;
    final String tag;
    if (isCurrent) {
      tag = '当前定位';
    } else if (_doubtHits.contains(line)) {
      tag = line == bestHit ? '最像' : '包含';
    } else {
      tag = '邻近';
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: () => _pickDoubtCandidate(line),
      child: Container(
        width: double.infinity,
        color: isCurrent
            ? (isDark
                ? const Color(0xFF4A3A10)
                : const Color(0xFFFFF8E1))
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(children: [
          Expanded(
            child: Text(
              _lines[line].isEmpty ? '（空行）' : _lines[line],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: s.onSurface),
            ),
          ),
          const SizedBox(width: 8),
          Text(tag,
              style: TextStyle(
                  fontSize: 11,
                  color: isCurrent
                      ? const Color(0xFFB26A00)
                      : s.primary)),
        ]),
      ),
    );
  }

  // -------------------- 高亮 --------------------

  void _clearHitRanges() {
    final old = _rangeLine;
    if (old != null) {
      _ctrls[old]?.setRanges(const <_HighlightRange>[]);
      _rangeLine = null;
    }
  }

  void _applyHitRange() {
    _clearHitRanges();
    if (_hitIndex >= 0 && _hitIndex < _hits.length) {
      final h = _hits[_hitIndex];
      _ctrls[h.line]?.setRanges(<_HighlightRange>[
        _HighlightRange(h.start, h.end, const Color(0x99FFAB40), 0),
      ]);
      _rangeLine = h.line;
    }
  }

  // -------------------- 查找替换 --------------------

  void _refreshHits({int? keepLine, int? keepStart}) {
    final q = _find.text;
    _hits.clear();
    _hitIndex = -1;

    if (q.isNotEmpty) {
      try {
        final reg = _regexOn ? RegExp(q) : null;
        for (var i = 0; i < _lines.length && _hits.length < 20000; i++) {
          final t = _lines[i];
          if (t.isEmpty) continue;
          if (reg != null) {
            for (final m in reg.allMatches(t)) {
              _hits.add(_LineHit(i, m.start, m.end));
              if (_hits.length >= 20000) break;
            }
          } else {
            var from = 0;
            while (from <= t.length) {
              final idx = t.indexOf(q, from);
              if (idx < 0) break;
              _hits.add(_LineHit(i, idx, idx + q.length));
              from = idx + q.length;
              if (_hits.length >= 20000) break;
            }
          }
        }
      } catch (_) {
        _hits.clear();
      }
      if (_hits.isNotEmpty) {
        if (keepLine == null) {
          _hitIndex = 0;
        } else {
          // 替换当前后：优先接着同一行里后面的匹配，找不到再找后面的行。
          _hitIndex = _hits.indexWhere(
              (h) => h.line == keepLine && h.start >= (keepStart ?? 0));
          if (_hitIndex < 0) {
            _hitIndex = _hits.indexWhere((h) => h.line >= keepLine);
          }
          if (_hitIndex < 0) _hitIndex = _hits.length - 1;
        }
      }
    }

    _applyHitRange();
    if (mounted) setState(() {});
    if (keepLine == null) _scrollToCurrentHit();
  }

  /// 默认**不抢焦点**：在查找框里打字会触发 _refreshHits，
  /// 若这里每次都 requestFocus，光标会被抢回编辑器，查找框就没法连续输入。
  /// 只有用户显式点 ↑/↓ 跳匹配时才把焦点交给编辑器并精确定位光标。
  void _scrollToCurrentHit({bool focusEditor = false}) {
    if (_hitIndex < 0 || _hitIndex >= _hits.length) return;
    final h = _hits[_hitIndex];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_itemScroll.isAttached) {
        _itemScroll.jumpTo(index: h.line);
      }
      _applyHitRange();
      if (mounted) setState(() {});
      if (focusEditor) {
        _focusLine(h.line, caretOffset: h.start);
      }
    });
  }

  void _moveHit(int delta) {
    if (_hits.isEmpty) {
      widget.onMessage('没有匹配内容');
      return;
    }
    _hitIndex = (_hitIndex + delta + _hits.length) % _hits.length;
    _applyHitRange();
    if (mounted) setState(() {});
    _scrollToCurrentHit(focusEditor: true);
  }

  void _replaceCurrent() {
    if (_hitIndex < 0 || _hitIndex >= _hits.length) {
      widget.onMessage('没有选中的匹配');
      return;
    }
    final h = _hits[_hitIndex];
    if (h.line >= _lines.length) {
      _refreshHits();
      return;
    }
    final t = _lines[h.line];
    if (h.start < 0 || h.end > t.length || h.end < h.start) {
      _refreshHits();
      return;
    }
    final rep = _replace.text;
    final next = t.substring(0, h.start) + rep + t.substring(h.end);
    _lines[h.line] = next;
    // 可见行的 controller 同步一下（不可见行滚到时自然从 _lines 构建）。
    _suppressDirty = true;
    _ctrls[h.line]?.text = next;
    _suppressDirty = false;
    _dirty = true;
    // 文本变了，初始目标行已失效。
    _targetLine = null;
    _refreshHits(keepLine: h.line, keepStart: h.start + rep.length);
    widget.onMessage('已替换当前');
  }

  void _replaceAll() {
    final q = _find.text;
    if (q.isEmpty) {
      widget.onMessage('请先输入查找内容');
      return;
    }
    final rep = _replace.text;
    var count = 0;
    try {
      final reg = _regexOn ? RegExp(q) : null;
      for (var i = 0; i < _lines.length; i++) {
        final t = _lines[i];
        if (t.isEmpty) continue;
        String next;
        if (reg != null) {
          next = t.replaceAllMapped(reg, (_) => rep);
        } else {
          next = t.replaceAll(q, rep);
        }
        if (next == t) continue;
        if (reg != null) {
          count += reg.allMatches(t).length;
        } else {
          var from = 0;
          while (from <= t.length) {
            final idx = t.indexOf(q, from);
            if (idx < 0) break;
            count++;
            from = idx + q.length;
          }
        }
        _lines[i] = next;
      }
    } catch (e) {
      widget.onMessage('正则有误：$e');
      return;
    }
    // 可见行的 controller 全部同步成新内容（不可见行滚到时自然重建）。
    _suppressDirty = true;
    _ctrls.forEach((i, c) {
      if (i < _lines.length) c.text = _lines[i];
    });
    _suppressDirty = false;
    _dirty = true;
    _targetLine = null;
    _refreshHits();
    widget.onMessage('已替换 $count 处');
  }

  // -------------------- 写回磁盘 --------------------

  /// 返回 true 仅代表 .bak 写成功；所有早退 / 失败路径一律 false，
  /// 失败原因写进 lastSaveError，供关闭确认框显示重试 / 复制全文。
  Future<bool> _save() async {
    if (_loading || _saving) {
      _lastSaveError = '文件还在读取或上一次保存尚未结束，请稍后重试';
      return false;
    }
    // 原文件编码没有对称编码器（UTF-16 / Big5 / Shift-JIS）时，.bak 改用
    // UTF-8 写。.bak 只是「最近一次编辑快照」、原文件永不动，打开时也永远
    // 读原文件，所以副本与原文件编码不同不会造成任何回读错乱；改动不白改。
    final bool forceUtf8 =
        _saveEncoding == _MiniSaveEncoding.unsupported;
    _lastSaveError = null;
    setState(() => _saving = true);
    try {
      // 流式编码：逐行编码直接写入字节缓冲，不再先拼出整篇大字符串。
      // 之前“先 join 全文再 encode”那一刻内存里同时有三份（行数组+大字符串+
      // 字节列表），10MB 文件保存瞬间峰值~70MB；现在同一时刻只多一份字节。
      final nl = _crlf ? '\r\n' : '\n';
      final bool isGbk =
          !forceUtf8 && _saveEncoding == _MiniSaveEncoding.gbk;
      final List<int> nlBytes = isGbk ? gbk.encode(nl) : utf8.encode(nl);
      final builder = BytesBuilder(copy: false);
      if (!forceUtf8 && _saveEncoding == _MiniSaveEncoding.utf8bom) {
        builder.add(const <int>[0xEF, 0xBB, 0xBF]);
      }
      for (var i = 0; i < _lines.length; i++) {
        final line = _lines[i];
        builder.add(isGbk ? gbk.encode(line) : utf8.encode(line));
        if (i != _lines.length - 1) builder.add(nlBytes);
      }
      final Uint8List bytes = builder.takeBytes();
      // 写回「备份」(.bak)，原文件永远不动；对比页比的是两份原文件，
      // 因此源文件不被改动、对比页也就无需刷新。
      final bak = File(_bakPathOf(widget.filePath));
      await bak.writeAsBytes(bytes, flush: true);
      if (!mounted) return false;
      _dirty = false;
      _saving = false;
      _lastSaveError = null;
      setState(() {});
      // 悬浮提示必须说出「保存成了哪个文件」：标签条只显示原文件名，
      // 副本名只有这里和关闭确认框会告诉用户。
      final bakName = _bakFileNameOf(widget.filePath);
      widget.onMessage(forceUtf8
          ? '已按 UTF-8 保存副本「${_shortName(bakName)}」，原文件未改动'
          : '已保存副本「${_shortName(bakName)}」，原文件未改动');
      return true;
    } catch (e) {
      if (!mounted) return false;
      _saving = false;
      _lastSaveError = '写入 .bak 失败：$e';
      setState(() {});
      widget.onMessage('保存失败：$e（改动仍在，可重试或复制全文）');
      return false;
    }
  }

  // -------------------- 关闭逻辑 --------------------

  /// 顶栏 × 的唯一入口。行为：
  /// 1) 有未保存的改动 → 交给外层弹三按钮确认框（保存并关闭 / 放弃并关闭 / 取消）。
  /// 2) 什么都没改 → 直接关闭。
  /// 注：对比页比的是两份原文件，迷你编辑器只改 .bak、不碰原文件，故无需刷新对比页。
  void _onCloseTap() {
    if (_dirty) {
      widget.onCloseRequested();
      return;
    }
    widget.onClose();
  }

  // -------------------- UI --------------------

  /// 圆圈问号：把迷你编辑器的全部操作按分组列全（内容较长，内部可滚动）。
  void _showHelpDialog() {
    final s = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('迷你编辑器说明'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _helpBlock('这里装的是什么', const [
                  '磁盘上真实源文件的全文（按原编码解码），不是对比页里规范化后的文本。',
                  '打开时自动滚到你在对比页长按的那一行，整行黄底高亮。',
                  '没有行号、没有编码显示、没有底栏；文件名在顶部标签条里。',
                ], s),
                _helpBlock('窗口本身', const [
                  '顶部是一条 B 形圆角标签条（斜边在右、右端比窗口短一截），'
                      '和下面的窗口是同一整块、没有拼接缝；左下 / 右下是直角，'
                      '因为右下角要放 ⤡ 缩放把手。',
                  '整窗阴影也按这条轮廓绘制（自定义 ShapeBorder），斜边处不会露出矩形方影。',
                  '拖顶部标签条任意处可移动窗口；拖右下角 ⤡ 可缩放。',
                  '右侧只有一根可拖动的滑块用来滚全文，没有系统滚动条。',
                  '齿轮「设置」里可调字号(10~22px)、窗口宽度、窗口高度、透明度(40%~100%)；'
                      '面板能上下滑，点面板外任意处即可收起，与查找替换面板互斥。',
                ], s),
                _helpBlock('顶部标签条', const [
                  '最左的红 / 绿竖条对应对比页左栏(红) / 右栏(绿)，撑满标签条高度。',
                  '「⋮⋮」只是拖动标记，整条标签都能拖；文字不吃点击。',
                  '显示磁盘上真实的文件名（如「书名.txt」）：这里装的就是原文件，'
                      '不是副本；点「保存副本」才会另外生成「书名 - 副本.txt.bak」。',
                  '书名太长时省略中间、保留开头和结尾（…）；扩展名永远完整保留，'
                      '不会被省略、也不会被裁掉半个字。',
                  '最窄窗口只有 160px，标签条里留给文字的不到 44px，那一档'
                      '字号会自动从 11 缩到 9；实在放不下时只显示扩展名。',
                ], s),
                _helpBlock('按钮行（从左到右）', const [
                  '? 使用说明：就是本页。',
                  '齿轮 设置：字号 / 窗口宽 / 窗口高 / 透明度，四个滑块。',
                  '放大镜 查找替换（面板打开时这个按钮会变成文字「关闭查找」）：'
                      '第一行查找框 + 正则开关（蓝色胶囊=开）+ ↑/↓ 跳命中；'
                      '第二行替换为框 + 替换当前 / 替换全部。窗口太窄时按钮自动换到下一行，不会只露一半。',
                  '查找面板浮在正文上方，不占正文高度；窗口很矮时面板内部可上下滑，'
                      '想看完整正文点「关闭查找」即可（面板外的正文仍可点、可滚）。',
                  '多行操作：进入勾选模式，见下面「多行操作」一段。',
                  '保存副本：写入「书名 - 副本.txt.bak」这种名字（书名换成你的真实文件名）；保存成功会浮出提示，'
                      '直接告诉你生成了哪个文件。能原样写回时按原编码，'
                      '特殊编码自动改用 UTF-8（按钮行下会有说明条）。',
                  '× 关闭：唯一的关闭方式。',
                  '按钮放不下时这一排可以左右滑动；左边缘出现 ← 箭头表示左边还有被挤没的按钮，'
                      '点它就把左边按钮露出来一点，全部露出后箭头自动消失'
                      '（右边不放箭头，× 永远可点）。',
                ], s),
                _helpBlock('编辑正文', const [
                  '点任意行光标落进去改这一行；长按选字，复制 / 剪切 / 粘贴和普通输入框一样。',
                  '粘贴或回车带进多行内容时自动拆成多行，不会卡。',
                ], s),
                _helpBlock('多行操作', const [
                  '进入后正文变只读，点整行即可勾选 / 取消；再点「多行操作」或「退出多选」退出。',
                  '区间选择：先点一下起点、再点一下终点，中间整段自动勾选。',
                  '底部操作栏：复制所选 / 删除所选 / 清空勾选 / 与下一行合并（只勾选一行时才有）'
                      ' / 退出多选；操作栏窄时可左右滑动，左边缘 ← 箭头提示左边还有操作，'
                      '点它会露出来一点，全部露出后自动消失。',
                ], s),
                _helpBlock('保存与关闭', const [
                  '「保存副本」永远只写入「书名 - 副本.txt.bak」，原文件不会被改动；'
                      '成功后悬浮提示会报出具体的副本文件名。'
                      '每次打开都以原文件为准，这个副本只是最近一次编辑的快照（再保存会覆盖同一个文件）。',
                  '只放行 UTF-8 / UTF-8 BOM / GBK 原样写回；UTF-16 / Big5 / Shift-JIS '
                      '没有对称编码器，此时顶栏下会有一条说明，保存自动改成 UTF-8 写入 .bak'
                      '（原文件不动），改动不会白改。',
                  '保存失败时关闭弹窗不会消失：会显示失败原因，并多出「复制全文」和「重试保存」，'
                      '改动始终留在小窗里。',
                  '文件大于 20MB 时先弹一次软警告，可选「仍要打开」或取消；'
                      '大文件可能卡顿甚至整个 App 闪退。',
                  '有未保存改动时点 × 会问一句，并把副本名和原文件名都写出来：'
                      '「保存并关闭」把改动写成副本后关窗、「放弃并关闭」什么都不写直接关窗、'
                      '「取消」回到编辑。',
                  '对比页比的是两份原文件，本窗口只改 .bak，所以关闭后对比结果不变、无需刷新。',
                ], s),
                _helpBlock('橙色 ? 与定位核对', const [
                  '标签条最外面（斜边右侧那片空白）出现一个橙色大 ?，带上下浮动动效，'
                      '意思是「这次跳到的行没十足把握」。它是纯字形，不是圆圈徽标，'
                      '不占标签条宽度，⋮⋮ 拖动把柄和文件名都不变。',
                  '只有映射表标成「估计格」、或宽松核对命中不止一行 / 一行都没命中时才出现；'
                      '精确命中且唯一确定时完全静默，跟以前一模一样。',
                  '点 ? 展开候选位置面板：列的是这一行在磁盘原文里可能对应的几处，'
                      '每条只显示原文和一个标记（当前定位 / 最像 / 包含 / 邻近），不显示行号。',
                  '点其中一条 = 把黄底高亮和光标挪过去，文字一个字不改、也不写盘；'
                      '「收起 ✕」只关面板、位置不变、问号还在；「本次隐藏」让问号本次淡出。',
                  '隐藏只管这一次：下次再从对比页跳进来（重新打开，或长按另一行切换）'
                      '会重新判定，又有多个可能位置时问号会带上下动效重新出现；不写设置、不会永久关掉。',
                  '面板里摆的是磁盘原文全文：哪怕规则把广告 / 水印删得只剩半句，'
                      '也能一眼认出它属于哪一行，不需要程序去算相似度。'
                      '规则本来就会改字，所以「文字不像」绝不会被当成跳错行。',
                  '面板与查找 / 设置面板互斥，浮在正文上方不占正文高度，窗口很矮时内部可上下滑；'
                      '窗口形状、斜边、直角与贴合轮廓的阴影都不变。',
                ], s),
                _helpBlock('与对比页的关系', const [
                  '本窗口是模态的：只有 × 能关。点小窗外的对比页内容区会提示「请先关闭迷你编辑器」；'
                      '顶部工具栏和文件名栏仍可点击。',
                  '长按对比页的另一行，会把当前窗口切到那一行对应的文件，'
                      '保留窗口位置 / 大小 / 字号 / 透明度，不会叠加新窗口。',
                  '切换前若本窗口有未保存改动，会先问「保存并切换 / 丢弃并切换 / 取消」。',
                ], s),
                _helpBlock('做不到的事', const [
                  '不能从一行中间拖选到另一行中间（每行是独立输入框）。'
                      '想删两行的中间部分：先「与下一行合并」并成一行，再在行内正常选字删除。',
                ], s),
              ],
            ),
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

  /// 帮助说明里的一个分组：标题加粗 + 逐条列点。
  Widget _helpBlock(String title, List<String> lines, ColorScheme s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: s.onSurface)),
          const SizedBox(height: 4),
          ...lines.map((l) => Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Text('· $l',
                    style: TextStyle(
                        fontSize: 12, height: 1.45, color: s.onSurface)),
              )),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    const clipper = _MiniWindowClipper(
      tabH: _kTabH,
      corner: _kTabCorner,
      slant: _kTabSlant,
      shortBy: _kTabShortBy,
    );
    // 也要 const：Material 每次 rebuild 若拿到不同实例，会把它当成
    // 「形状变了」跑一次 150ms 的过渡动画，阴影会轻微闪一下。
    const shape = _MiniWindowShape(clipper);
    return Opacity(
      opacity: _opacity,
      // 外面多包一层 Stack：橙色 ? 必须放在 Material **之外**——带自定义
      // shape 的 Material 走 PhysicalShape，命中测试按 shape 轮廓裁剪，
      // 问号悬在「标签最外面」（轮廓外那片空白），留在 Material 子树里
      // 很可能整个点不到。放到外层 Stack 后窗口内点击不受影响。
      child: Stack(fit: StackFit.expand, children: [
        Material(
        elevation: 10,
        // 背景必须透明：形状完全由 ClipPath 决定；Material 若自己铺矩形底色，
        // 会把「标签条右端短一截」那块空白补上，梯形就没了。
        color: Colors.transparent,
        // 阴影按同一条轮廓画（自定义 ShapeBorder 与 ClipPath 共用 clipper.build），
        // 斜边与底部直角都贴合，不再有矩形方影。
        shape: shape,
        // expand：透明 Material 下必须给紧约束，否则 ClipPath 会 shrink-wrap，
        // 正文的 Expanded 拿不到高度、窗口撑不满设定的宽高。
        child: Stack(fit: StackFit.expand, children: [
          ClipPath(
            clipper: clipper,
            clipBehavior: Clip.antiAlias,
            child: Container(
              color: s.surface,
              child: Stack(fit: StackFit.expand, children: [
                Column(children: [
                  // 这一项自带两层：34px 标签条（会被裁成 B 形梯形）
                  // + 32px 按钮行。
                  _buildTitleBar(s),
                  if (_noticeH > 0) _buildEncodingNotice(s),
                  Expanded(
                    // 查找面板是浮层，不占这一列高度；正文始终占满顶栏以下
                    // 的全部空间。minHeight 只是极端小窗下的兜底。
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 24),
                      child: Row(children: [
                        Expanded(child: _buildEditorField(s)),
                        // 右侧唯一的滚动滑块，没有系统滚动条。
                        SizedBox(
                          width: 10,
                          child: AnimatedBuilder(
                            animation: _itemPositions.itemPositions,
                            builder: (_, __) => _buildThumbTrack(s),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  if (_multiSelectMode) _buildMultiSelectBar(s),
                ]),
                // 查找替换面板：浮层，不占 Column 高度；刻意不加全屏遮罩，
                // 那样会吃掉正文的点击与滚动，无法边查边编辑。
                if (_showFindReplace)
                  Positioned(
                    top: _kTabH + _kBtnBarH + _noticeH,
                    left: 8,
                    right: 8,
                    child: Material(
                      elevation: 6,
                      borderRadius: BorderRadius.circular(6),
                      color: s.surface,
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(maxHeight: _findPanelMaxHeight()),
                        child: SingleChildScrollView(
                            child: _buildFindReplace(s)),
                      ),
                    ),
                  ),
                // 定位候选面板（图 12 甲）：和查找面板同一套规矩——浮层、
                // 不占正文高度、限高约 6 成且内部竖滚、不加全屏遮罩，
                // 与查找 / 设置面板互斥，不会叠在一起。
                if (_showDoubtPanel)
                  Positioned(
                    top: _kTabH + _kBtnBarH + _noticeH,
                    left: 8,
                    right: 8,
                    child: Material(
                      elevation: 6,
                      borderRadius: BorderRadius.circular(6),
                      color: s.surface,
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(maxHeight: _findPanelMaxHeight()),
                        child: SingleChildScrollView(
                            child: _buildDoubtPanel(s)),
                      ),
                    ),
                  ),
                // 设置面板开着时，点面板以外任何地方都先关面板。
                if (_showSettings)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _showSettings = false),
                    ),
                  ),
                if (_showSettings)
                  Positioned(
                      top: _kTabH + _kBtnBarH + 2 + _noticeH,
                      left: 8,
                      child: _buildSettingsPanel(s)),
                Positioned(
                    right: 0, bottom: 0, child: _buildResizeHandle()),
              ]),
            ),
          ),
          // 沿同一条轮廓画一圈细边框。放在 ClipPath 外面，否则描边被裁半根线。
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _MiniOutlinePainter(
                    clipper: clipper, color: s.outlineVariant),
              ),
            ),
          ),
          // 橙色大 ? 已挪到外层 Stack（见 build 末尾）：与 Material 平级，
          // 不被 ClipPath 裁掉、也不受 PhysicalShape 命中裁剪的影响。
        ]),
        ),
        // 橙色大 ? 放在「标签最外面」——斜边右侧那片轮廓外的空白。
        // 在外层 Stack 与 Material 平级：既不会被 ClipPath 裁掉，也不受
        // Material（PhysicalShape）按轮廓裁剪命中测试的影响，轮廓外也能点到。
        // 不占标签条 Row 的任何宽度，文件名 / ⋮⋮ / 6 个按钮、窗口形状
        // 与贴合轮廓的阴影全不受影响。它也不在标签条的拖动手势区内。
        Positioned(
          top: 0,
          right: 4,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.45),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: (_doubtActive && !_doubtHidden && !_loading)
                ? _DoubtMark(
                    key: const ValueKey('doubt-mark'),
                    size: widget.currentWidth < 200
                        ? 20.0
                        : (widget.currentWidth < 320 ? 24.0 : 28.0),
                    onTap: _toggleDoubtPanel,
                  )
                : const SizedBox.shrink(key: ValueKey<String>('doubt-none')),
          ),
        ),
      ]),
    );
  }

  /// 顶栏 = 34px 标签条（颜色竖条 / ⋮⋮ 拖动 / 文件名）+ 32px 按钮行。
  /// 标签条整块都是拖动命中区，内部文字全部不吃手势；
  /// 按钮行独占一整行，不再和拖动区抢宽度。
  Widget _buildTitleBar(ColorScheme s) {
    // 浅灰标签条 + 白色按钮行；左侧红/绿竖条对齐对比页（左栏红、右栏绿）。
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final barColor = widget.isOriginal
        ? (isDark ? const Color(0xFFE57373) : const Color(0xFFD9534F))
        : (isDark ? const Color(0xFF81C784) : const Color(0xFF4CAF50));
    final bg = isDark ? s.surfaceContainerLow : const Color(0xFFF7F7F8);
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      // 与 _MiniWindowClipper 完全一致的收缩规则：标签条右端比主体短一截，
      // 文字不能越过斜边，所以右侧要留出这段空白。
      final sb = math.min(_kTabShortBy, w * 0.28);
      final sl = math.min(_kTabSlant, w * 0.16);
      final rightInset = sb + sl + 6;
      const leftUsed = 6.0 + 6.0 + 16.0 + 8.0; // 竖条 + 间距 + ⋮⋮ + 间距
      final textAvail = math.max(0.0, w - rightInset - leftUsed - 4);
      return Column(mainAxisSize: MainAxisSize.min, children: [
        // ── 标签条 34px：整块都是拖动命中区，内部文字不吃手势 ──
        SizedBox(
          height: _kTabH,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => widget.onDrag(d.delta.dx, d.delta.dy),
            child: Container(
              color: bg,
              padding: EdgeInsets.only(right: rightInset),
              child: Row(children: [
                // 必须给高度：只写 width 的 Container 在 Row 里是「无 child」，
                // 垂直方向会塌成 0，红/绿竖条就显示不出来或只有矮矮一截。
                Container(width: 6, height: _kTabH, color: barColor),
                const SizedBox(width: 6),
                const IgnorePointer(
                  child: Text('⋮⋮',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                ),
                const SizedBox(width: 8),
                Expanded(child: _buildFileName(s, textAvail)),
              ]),
            ),
          ),
        ),
        // ── 按钮行 32px：独占一整行，不再和拖动区抢宽度 ──
        SizedBox(
          height: _kBtnBarH,
          child: Container(
            color: s.surface,
            child: Stack(children: [
              SingleChildScrollView(
                controller: _topBarScroll,
                scrollDirection: Axis.horizontal,
                reverse: true,
                padding: const EdgeInsets.only(right: 2),
                child: Row(children: [
                  _topBtn(
                      icon: Icons.help_outline,
                      tooltip: '使用说明',
                      onTap: _showHelpDialog),
                  const SizedBox(width: 8),
                  _topBtn(
                      icon: Icons.settings,
                      tooltip: '设置（字号 / 窗口大小 / 透明度）',
                      onTap: () => setState(() {
                            _showSettings = !_showSettings;
                            if (_showSettings) {
                              _showFindReplace = false;
                              _showDoubtPanel = false;
                            }
                          })),
                  const SizedBox(width: 8),
                  _topBtn(
                      // 面板开着时改成文字，关着时保留放大镜图标。
                      icon: _showFindReplace ? null : Icons.search,
                      label: _showFindReplace ? '关闭查找' : null,
                      tooltip:
                          _showFindReplace ? '关闭查找替换面板' : '查找替换',
                      onTap: () {
                        final closing = _showFindReplace;
                        setState(() {
                          _showFindReplace = !_showFindReplace;
                          if (!closing) {
                            _showSettings = false;
                            _showDoubtPanel = false;
                          }
                        });
                        if (closing) {
                          _find.clear();
                          _replace.clear();
                        }
                      }),
                  const SizedBox(width: 8),
                  _topBtn(
                      label: '多行操作',
                      tooltip: _multiSelectMode
                          ? '退出多行操作'
                          : '勾选多行后复制 / 删除 / 合并（可区间选择）',
                      onTap: _toggleMultiSelect),
                  const SizedBox(width: 8),
                  _topBtn(
                      label: '保存副本',
                      tooltip: '写入 .bak 备份（原文件不会被改动；特殊编码自动改用 UTF-8）',
                      onTap: () {
                        if (!_saving) _save();
                      }),
                  const SizedBox(width: 8),
                  _topBtn(
                      icon: Icons.close,
                      tooltip: '关闭（唯一关闭方式）',
                      onTap: _onCloseTap),
                ]),
              ),
              _buildLeftOverflowHint(_topBarScroll, s.surface, _nudgeTopBar),
            ]),
          ),
        ),
      ]);
    });
  }

  /// 标签条里的文件名：显示**磁盘上真实的文件名**（含扩展名）。
  /// 小窗里装的就是原文件，写成副本名会让人误以为当前看的是副本；
  /// 副本名改由保存提示与关闭确认框明确告诉用户。
  /// - 书名太长时省略中间、保留开头和结尾；**扩展名永远完整保留**；
  /// - 窗口很窄时自动降字号（11 → 10 → 9），最窄 160px 也放得下；
  /// - 书名区不足 2 个字就只留扩展名，不露零碎的单个字。
  Widget _buildFileName(ColorScheme s, double avail) {
    final name = _fileNameOf(widget.filePath);
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot) : '';
    final book = dot > 0 ? name.substring(0, dot) : name;

    // 最窄窗口(160px)的标签条文字区只剩约 43.6px，字号跟着宽度降；
    // 宽窗仍是 11px，只有挤的时候才逐级缩小。
    final fs = avail < 52 ? 9.0 : (avail < 64 ? 10.0 : 11.0);

    final extW = _miniTextWidth(ext, fs);
    final titleW = math.max(0.0, avail - extW - 2);
    final maxChars = (titleW / fs).floor();
    final shown = maxChars < 2 ? '' : _ellipsizeMiddle(book, maxChars);
    return Row(children: [
      if (shown.isNotEmpty)
        Flexible(
          child: Text(shown,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: fs, color: s.onSurface)),
        ),
      // 扩展名永远完整显示，不参与中间省略。
      Text(ext,
          maxLines: 1,
          style: TextStyle(fontSize: fs, color: s.onSurface)),
    ]);
  }

  /// 粗略估算一行文字宽度：CJK 按 1 个字宽，ASCII 按 0.58 个字宽。
  /// 只用来算「能放几个字」，不参与绘制，差几像素由 Flexible + ellipsis 兜底。
  static double _miniTextWidth(String t, double fs) {
    var w = 0.0;
    for (final r in t.runes) {
      w += r < 0x2E80 ? fs * 0.58 : fs;
    }
    return w;
  }

  /// 中间省略：保留开头和结尾，中间换成一个「…」。
  static String _ellipsizeMiddle(String s, int maxChars) {
    if (maxChars <= 0 || s.isEmpty) return '';
    if (s.length <= maxChars) return s;
    if (maxChars <= 3) return s.substring(0, maxChars);
    final head = (maxChars - 1) ~/ 2;
    final tail = maxChars - 1 - head;
    return '${s.substring(0, head)}…${s.substring(s.length - tail)}';
  }

  /// 横向滚动按钮组的左边缘浮层：只在「左边还有被挤没的按钮」时出现。
  /// 用 AnimatedBuilder 监听 controller.pixels，滚动中实时刷新、只重建这一小块，
  /// 不 setState 整个小窗。淡入淡出；隐藏时 IgnorePointer，不吃任何点击。
  /// reverse:true 下 pixels==0 是右对齐（末尾按钮可见、开头按钮藏在左侧屏幕外），
  /// pixels 变大才逐个露出左边按钮；到 maxScrollExtent 时左端已全部露出，
  /// 没有可点的了，浮层淡出。判据与 _nudgeHorizontal（pixels+80）一致。
  /// 右边（× 一侧）刻意不放浮层，两处按钮组共用本组件，逻辑只写一份。
  Widget _buildLeftOverflowHint(
    ScrollController controller,
    Color bg,
    VoidCallback onTap,
  ) {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final show = controller.hasClients &&
              controller.position.maxScrollExtent > 0.5 &&
              controller.position.pixels <
                  controller.position.maxScrollExtent - 0.5;
          return IgnorePointer(
            ignoring: !show,
            child: AnimatedOpacity(
              opacity: show ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: Tooltip(
                message: '点这里或左右滑动，查看更多按钮',
                child: GestureDetector(
                  onTap: onTap,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 20,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          bg.withOpacity(0.95),
                          bg.withOpacity(0.0),
                        ],
                      ),
                    ),
                    child: const Center(
                      child: Icon(Icons.chevron_left,
                          size: 16, color: Colors.grey),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 点左边缘箭头：reverse:true 里 pixels 变大 = 内容整体往右移，
  /// 左边被挤没的按钮从视口左缘进来看见（pixels 越大越靠左端）。
  void _nudgeTopBar() => _nudgeHorizontal(_topBarScroll);

  void _nudgeMultiBar() => _nudgeHorizontal(_multiBarScroll);

  void _nudgeHorizontal(ScrollController controller) {
    if (!controller.hasClients) return;
    final p = controller.position;
    final next = (p.pixels + 80).clamp(0.0, p.maxScrollExtent);
    controller.animateTo(next,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  Widget _topBtn({
    String? label,
    IconData? icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final s = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        height: 24,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          hoverColor: s.onSurface.withValues(alpha: 0.10),
          splashColor: s.onSurface.withValues(alpha: 0.16),
          highlightColor: s.onSurface.withValues(alpha: 0.10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: label != null
                  ? Text(label,
                      style: TextStyle(fontSize: 12, color: s.onSurface))
                  : Icon(icon ?? Icons.help_outline,
                      size: 15, color: s.onSurface),
            ),
          ),
        ),
      ),
    );
  }

  /// 设置面板：字号 / 窗口宽 / 窗口高 / 透明度 收进一个面板。
  /// 窗口宽高直接驱动外层 SourceMiniEditorOverlay 的尺寸（经 onSetSize 夹紧）。
  Widget _buildSettingsPanel(ColorScheme s) {
    final wMax = math.max(160.0, widget.maxW - 16);
    final hMax = math.max(_kMiniMinHeight, widget.maxH - 16);
    final wVal = widget.currentWidth.clamp(160.0, wMax);
    final hVal = widget.currentHeight.clamp(_kMiniMinHeight, hMax);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(6),
      color: s.surface,
      child: ConstrainedBox(
        // 面板高度不超过小窗可用区（标签条 34 + 按钮行 32 + 上下留白），
        // 放不下时内部滚动，不再被小窗截断后看不到下半部分。
        constraints: BoxConstraints(
            maxHeight: math.min(
                220.0,
                math.max(
                    64.0, widget.currentHeight - _kTabH - _kBtnBarH - 10))),
        child: SizedBox(
          width: 208,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Text('设置',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: s.onSurface)),
                const Spacer(),
                InkWell(
                  onTap: () => setState(() => _showSettings = false),
                  child: const Icon(Icons.close, size: 15),
                ),
              ]),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    _sliderRow('字号', _fontSize, 10, 22, 12,
                        (v) {
                          setState(() => _fontSize = v);
                          _prefs?.setDouble(PrefKeys.miniEditorFontSize, v);
                        },
                        '${_fontSize.toStringAsFixed(0)} px', s),
                    _sliderRow(
                        '宽度',
                        wVal,
                        160,
                        wMax,
                        null,
                        (v) => widget.onSetSize(v, widget.currentHeight),
                        '${wVal.toStringAsFixed(0)}', s),
                    _sliderRow(
                        '高度',
                        hVal,
                        _kMiniMinHeight,
                        hMax,
                        null,
                        (v) => widget.onSetSize(widget.currentWidth, v),
                        '${hVal.toStringAsFixed(0)}', s),
                    _sliderRow(
                        '透明度',
                        _opacity,
                        0.4,
                        1.0,
                        12,
                        (v) {
                          setState(() => _opacity = v);
                          _prefs?.setDouble(PrefKeys.miniEditorOpacity, v);
                        },
                        '${(_opacity * 100).toStringAsFixed(0)}%', s),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _sliderRow(
    String label,
    double value,
    double min,
    double max,
    int? divisions,
    ValueChanged<double> onChanged,
    String display,
    ColorScheme s,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(label, style: TextStyle(fontSize: 12, color: s.onSurface)),
            const Spacer(),
            Text(display,
                style: TextStyle(
                    fontSize: 12, color: s.onSurface.withValues(alpha: 0.7))),
          ]),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  /// 原文件编码不支持原样写回时，顶栏下挂一条细说明，告诉用户改动不会白改。
  /// 只在 UTF-16 / Big5 / Shift-JIS 等编码出现，常规文件不占高度。
  Widget _buildEncodingNotice(ColorScheme s) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      color: s.tertiaryContainer,
      child: Text(
        '此文件为 $_encodingLabel 编码，保存会写成 UTF-8 副本（.bak）；原文件不动',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: s.onTertiaryContainer),
      ),
    );
  }

  /// 查找面板浮层的最多高度：只盖住「顶栏以下可用高度」的约 6 成，
  /// 剩下的留给正文，矮窗时正文才不会被整块盖住。内容超出由外层
  /// SingleChildScrollView 竖滚；两套面板（查找 / 设置）互斥，不会叠在一起。
  double _findPanelMaxHeight() {
    final bottomBar = _multiSelectMode ? 30.0 : 0.0;
    // 扣掉新增的标签条 34 + 按钮行 32（原来是单行顶栏 32）。
    final avail = math.max(48.0,
        widget.currentHeight - _kTabH - _kBtnBarH - _noticeH - bottomBar - 8);
    return math.max(48.0, math.min(160.0, avail * 0.62));
  }

  /// 查找替换面板：输入框与按钮统一 28px 高、底线齐平；按钮是带边框的独立
  /// 小块、彼此留 6px，不再和输入框挤成一团。宽度不够时按钮整排换到输入框
  /// 下面一行（不是裁掉、也不是横滑），窄窗也能看到全部操作。
  /// 查找组与替换组之间留 8px。
  Widget _buildFindReplace(ColorScheme s) {
    return LayoutBuilder(builder: (context, c) {
      final avail = math.max(0.0, c.maxWidth - 16); // 左右各 8 的 padding
      // 各组按钮固定宽度（含按钮之间的 6px），据此判断能否与输入框同行。
      const findActionsW = 48.0 + 28.0 + 28.0 + 6.0 * 3; // 正则 + ↑ + ↓
      const replaceActionsW = 88.0 + 88.0 + 6.0 * 2; // 替换当前 + 替换全部
      const minFieldW = 92.0;
      final findInline = avail - findActionsW - 8 >= minFieldW;
      final replaceInline = avail - replaceActionsW - 8 >= minFieldW;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: s.surfaceContainerLow,
          border: Border.all(color: s.outlineVariant, width: 0.5),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _frGroup(
              field: _underlineField(_find, '查找', s),
              actions: [
                _regexSwitch(s),
                _frAction(
                    label: '↑', width: 28, onTap: () => _moveHit(-1), s: s),
                _frAction(
                    label: '↓', width: 28, onTap: () => _moveHit(1), s: s),
              ],
              inline: findInline,
            ),
            const SizedBox(height: 8),
            _frGroup(
              field: _underlineField(_replace, '替换为', s),
              actions: [
                _frAction(
                    label: '替换当前',
                    width: 88,
                    onTap: _replaceCurrent,
                    s: s),
                _frAction(
                    label: '替换全部', width: 88, onTap: _replaceAll, s: s),
              ],
              inline: replaceInline,
            ),
          ],
        ),
      );
    });
  }

  /// 一组「输入框 + 按钮」；inline=false 时按钮整排落到输入框下一行、右对齐。
  Widget _frGroup({
    required Widget field,
    required List<Widget> actions,
    required bool inline,
  }) {
    // 用 Wrap 而不是 Row：窗口最窄 160px 时「替换当前 + 替换全部」共
    // 182px，Row 会把按钮挤出窗口；Wrap 会继续自动换行，永不横向溢出。
    final buttons = Wrap(
      spacing: 6,
      runSpacing: 5,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: actions,
    );
    if (inline) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: field),
          const SizedBox(width: 8),
          buttons,
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        const SizedBox(height: 5),
        Align(alignment: Alignment.centerRight, child: buttons),
      ],
    );
  }

  Widget _underlineField(TextEditingController c, String hint, ColorScheme s) {
    return SizedBox(
      height: 28,
      child: TextField(
        controller: c,
        style: TextStyle(fontSize: 12, color: s.onSurface),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(
              fontSize: 12, color: s.onSurface.withValues(alpha: 0.4)),
          border: UnderlineInputBorder(
              borderSide: BorderSide(color: s.outlineVariant)),
          enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: s.outlineVariant)),
          focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: s.primary, width: 1.5)),
          contentPadding: const EdgeInsets.only(bottom: 4, left: 2, right: 2),
        ),
      ),
    );
  }

  /// 正则开关：圆角胶囊，开=浅色底+主题色字+主题色边，关=灰字灰边。
  /// 不再是「裸文字 + 下划线」，避免和输入框下划线打架、也不再像普通按钮。
  Widget _regexSwitch(ColorScheme s) {
    final on = _regexOn;
    return SizedBox(
      width: 48,
      height: 28,
      child: InkWell(
        onTap: () {
          setState(() => _regexOn = !_regexOn);
          _prefs?.setBool(PrefKeys.miniEditorRegexOn, _regexOn);
          _refreshHits();
        },
        borderRadius: BorderRadius.circular(5),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? s.primary.withValues(alpha: 0.12) : Colors.transparent,
            border:
                Border.all(color: on ? s.primary : s.outlineVariant, width: 0.5),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text('正则',
              style: TextStyle(
                  fontSize: 12,
                  color: on
                      ? s.primary
                      : s.onSurface.withValues(alpha: 0.6))),
        ),
      ),
    );
  }

  /// 统一的小操作按钮：固定宽高 + 圆角边框，点击区域明确、彼此不贴。
  Widget _frAction({
    required String label,
    required double width,
    required VoidCallback onTap,
    required ColorScheme s,
  }) {
    return SizedBox(
      width: width,
      height: 28,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        hoverColor: s.onSurface.withValues(alpha: 0.06),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: s.outlineVariant, width: 0.5),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 12, color: s.onSurface)),
        ),
      ),
    );
  }

  Widget _buildEditorField(ColorScheme s) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(_loadError!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: s.error)),
        ),
      );
    }
    // 桌面端 Scrollable 默认会画系统滚动条；设计要求「只留一个滑块」，
    // 这里把系统滚动条彻底去掉，滚动全交给右侧那个可拖动方块。
    // 行虚拟化：只构建可见行，每行一个独立小 TextField。
    return ScrollConfiguration(
      behavior: const _NoScrollbarBehavior(),
      child: ScrollablePositionedList.builder(
        itemScrollController: _itemScroll,
        itemPositionsListener: _itemPositions,
        itemCount: _lines.length,
        itemBuilder: (context, i) {
          return _MiniLineRow(
            index: i,
            text: _lines[i],
            fontSize: _fontSize,
            isTarget: _targetLine == i,
            isMultiSelected: _multiSelected.contains(i),
            isRangeStart: _pickingRange && _rangeStart == i,
            readOnly: _multiSelectMode,
            onChanged: (v) => _onLineChanged(i, v),
            onLineBreak: _onLineBreak,
            onTap: _multiSelectMode ? () => _onRowTapInMulti(i) : null,
            onAttachCtrl: _attachCtrl,
            onDetachCtrl: _detachCtrl,
            onAttachFocus: _attachFocus,
            onDetachFocus: _detachFocus,
            onFocus: (_) {},
          );
        },
      ),
    );
  }

  /// 只留一个可拖动的方块，不画系统滚动条。
  /// 行虚拟化后没有连续的像素 offset，用「首个可见行号 / 总行数」估比例，
  /// 拖动 = 按比例换算成目标行号直接 jumpTo（O(1)，不逐帧构建）。
  Widget _buildThumbTrack(ColorScheme s) {
    return LayoutBuilder(builder: (context, c) {
      final trackH = c.maxHeight;
      final total = _lines.length;
      final positions = _itemPositions.itemPositions.value;
      var firstIndex = 0;
      var visibleCount = 1;
      if (positions.isNotEmpty) {
        ItemPosition first = positions.first;
        for (final p in positions) {
          if (p.itemLeadingEdge < first.itemLeadingEdge ||
              (p.itemLeadingEdge == first.itemLeadingEdge &&
                  p.index < first.index)) {
            first = p;
          }
        }
        firstIndex = first.index;
        visibleCount = math.max(1, positions.length);
      }
      final thumbH = total <= 0
          ? trackH
          : (trackH * visibleCount / total).clamp(24.0, trackH).toDouble();
      final usable = math.max(1.0, trackH - thumbH);
      final ratio = total <= 1
          ? 0.0
          : (firstIndex / (total - 1)).clamp(0.0, 1.0).toDouble();
      final top = (ratio * usable).clamp(0.0, math.max(0.0, trackH - thumbH));

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) {
          if (total <= 0 || !_itemScroll.isAttached) return;
          final nextRatio =
              ((top + d.delta.dy) / usable).clamp(0.0, 1.0).toDouble();
          final target = (nextRatio * (total - 1)).round();
          _itemScroll.jumpTo(index: target.clamp(0, total - 1).toInt());
        },
        child: Stack(children: [
          Positioned(
            left: 2,
            right: 2,
            top: top.toDouble(),
            child: Container(
              height: thumbH,
              decoration: BoxDecoration(
                color: s.onSurface.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ]),
      );
    });
  }

  Widget _buildResizeHandle() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) => widget.onResize(d.delta.dx, d.delta.dy),
      child: const SizedBox(
        width: 18,
        height: 18,
        child: Center(
          child: Text('⤡',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
        ),
      ),
    );
  }
}

// ==================== 辅助类型 ====================

/// 隐藏桌面端系统滚动条：滚动完全由右侧那个可拖动方块控制。
class _NoScrollbarBehavior extends ScrollBehavior {
  const _NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}

/// 标签最外面的橙色大 ?（图 11 定稿）：纯字形、无圆底 / 无描边 / 无角标，
/// 常驻上下 ±3px 浮动 + 轻微缩放呼吸，1.4s 循环。出现 / 消失由外层的
/// AnimatedSwitcher 负责（下方弹入淡入、淡出）；系统开了「减少动态效果」
/// 时只保留淡入淡出、不再浮动。不用 Tooltip（会抢标签条的拖动手势）。
class _DoubtMark extends StatefulWidget {
  const _DoubtMark({super.key, required this.size, required this.onTap});

  final double size;
  final VoidCallback onTap;

  @override
  State<_DoubtMark> createState() => _DoubtMarkState();
}

class _DoubtMarkState extends State<_DoubtMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    return AnimatedBuilder(
      animation: _float,
      builder: (_, __) {
        final t = reduce ? 0.5 : _float.value;
        return Transform.translate(
          offset: Offset(0, (t - 0.5) * 6.0), // ±3px
          child: Transform.scale(
            scale: reduce ? 1.0 : 1.0 + 0.05 * t,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: Text(
                '?',
                style: TextStyle(
                  fontSize: widget.size,
                  height: 1.0,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFFF59E0B),
                  // 悬在轮廓外、底下会透出对比页，给一点极淡阴影保证看清；
                  // 绝不加圆形底色（用户明确不要「圆圈问号」）。
                  shadows: <Shadow>[
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// ④ 会话内记住用户在候选面板里的纠正：「文件路径 + 锚文本键」→ 用户确认
/// 的源文件行。只存内存、不写盘、不持久化——重启 App 自然清空，上限 200
/// 条（超出丢最早的）。命中后直接落到用户选过的行，不再做 ±8 微调。
final _doubtCorrectionMemo = <String, int>{};

/// ④ 记忆表的键：锚文本做「去空白 + 全角转半角」归一化后截前 64 字，
/// 同一段文本（哪怕规则改了几个字）也能对上同一条记忆。
String _doubtMemoKey(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    var c = r;
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
    if (c == 0x3000) c = 0x20;
    if (c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A) continue;
    sb.writeCharCode(c);
    if (sb.length >= 64) break;
  }
  return sb.toString();
}

/// 后台 isolate 用：拆行 + 定位 + 宽松核对 + 候选位置（2026-11-15）。
/// 大文件在主线程拆行会卡几秒，全丢进后台，打开过程不卡界面。
/// 入参 [text, crlf, anchorText, presetTarget, estimated, anchorContext]，
/// 返回 [lines, targetLine, candidates, hits]。
///
/// ⚠️ 核心口径：**宽松核对只微调、永不否决**。规则本来就会改字
/// （删广告 / 去水印 / 全角转半角 / 正则 / JS），所以「小窗这行文字跟长按
/// 那行不像」根本不是错位信号，绝不能拿它把正确的行判成错的、更不能回顶部。
/// 这里只做三件事：
///   ① 估计格时，在映射行 ±8 内找更贴合的一行微调（找不到就保持原行）；
///   ③ 顺手收集「所有疑似位置」给橙色 ? 的候选面板，交人眼判断；
///   ③' 长按行的**上下文**（±2 行规范化文本）跟候选行周围比对，
///       单行像可能是巧合、邻居也像基本就是对——只用来**排序候选**，
///       不否决任何一行（文字不像绝不是错位信号）。
List<Object?> _miniSplitAndTarget(List<Object?> args) {
  final text = args[0] as String;
  final crlf = args[1] as bool;
  final anchor = args[2] as String;
  final presetTarget = args.length > 3 ? args[3] as int? : null;
  // true = 映射表这一格是插值估出来的；false = 精确锚点。
  final estimated = args.length > 4 ? args[4] as bool : false;
  // 长按行在规范化文本里的上下文（±2 行，可能为空表）。
  final contextIn = args.length > 5
      ? (args[5] as List?)?.cast<String>() ?? const <String>[]
      : const <String>[];

  String norm(String s) {
    final sb = StringBuffer();
    for (final r in s.runes) {
      var c = r;
      if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
      if (c == 0x3000) c = 0x20;
      if (c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A) continue;
      sb.writeCharCode(c);
    }
    return sb.toString();
  }

  List<String> split(String t) {
    if (t.isEmpty) return <String>[''];
    final parts = t.split('\n');
    if (crlf) {
      for (var i = 0; i < parts.length; i++) {
        final p = parts[i];
        if (p.isNotEmpty && p.endsWith('\r')) {
          parts[i] = p.substring(0, p.length - 1);
        }
      }
    }
    return parts;
  }

  final lines = split(text);
  final a = norm(anchor);
  // 短锚（一个逗号、一个标点等）禁用「包含」匹配，避免命中文件里所有含该
  // 字符的行、定位漂到第一行。
  final allowContains = a.length >= 4;
  final key = a.length > 16 ? a.substring(0, 16) : a;

  // 宽松核对：相等 / 双向包含 / 前 16 字命中。双向包含是广告反例的关键：
  // 源行「今日气温回升。想看全本小说吗？…」包含对比行「今日气温回升。」，
  // 直接判命中，不会因为「文字不像」被误杀。
  int score(String nl) {
    if (nl.isEmpty || a.isEmpty) return -1;
    if (nl == a) return 1000000;
    if (allowContains && nl.contains(a)) return 100000 + a.length;
    if (allowContains && a.contains(nl) && nl.length >= 4) {
      return 10000 + nl.length;
    }
    if (allowContains && key.length >= 6 && nl.contains(key)) {
      return 1000 + key.length;
    }
    return -1;
  }

  // 全文扫一遍：既得到「映射不可用时」的定位，也得到所有疑似位置。
  // 命中很多时最多留 48 条，避免大量重复行把结果撑爆。
  // ③' 上下文键：长按行 ±2 的规范化文本（非空、≥4 字），用来给候选排序。
  final ctxKeys = <String>{};
  for (final c in contextIn) {
    final ck = norm(c);
    if (ck.length >= 4) ctxKeys.add(ck);
    if (ctxKeys.length >= 8) break;
  }

  /// 候选行 k 的邻居里有几条跟上下文对得上。0 = 无信息。
  /// ⚠️ 源文件可能有一长串空行：不固定看 ±2 行，而是**跳过空行向外扩窗**
  /// （最多扩到 ±8 行，与 ±8 微调窗口一致），往两边各取最多 2 条
  /// 「非空、≥4 字」的真邻居；空行再多也取得到邻居，不会把上下文比对架空。
  int ctxScoreAt(int k) {
    if (ctxKeys.isEmpty) return 0;
    var hitCount = 0;
    // 每侧取 2 条有效邻居；为了公平，向上/向下各独立收集。
    for (final dir in <int>[-1, 1]) {
      var taken = 0;
      for (var d = dir; d.abs() <= 8 && taken < 2; d += dir) {
        final t = k + d;
        if (t < 0 || t >= lines.length) break;
        final nl = norm(lines[t]);
        if (nl.isEmpty) continue; // 空行不算邻居，继续向外找
        taken++; // 非空行（含「短到无法比对」的行）也占一个名额，
                 // 防止正文全是超短行时把窗口拉得太远错配
        if (nl.length < 4) continue;
        for (final ck in ctxKeys) {
          if (nl == ck || nl.contains(ck) || ck.contains(nl)) {
            hitCount++;
            break;
          }
        }
      }
    }
    return hitCount;
  }

  final scored = <List<int>>[]; // [行号, 文字分, 上下文分]
  var bestByScan = -1;
  var bestScore = -1;
  for (var i = 0; i < lines.length; i++) {
    final sc = score(norm(lines[i]));
    if (sc < 0) continue;
    if (scored.length < 48) {
      scored.add(<int>[i, sc, ctxScoreAt(i)]);
    }
    if (sc > bestScore) {
      bestScore = sc;
      bestByScan = i;
    }
  }
  // 排序：文字分为主、上下文分为辅（邻居像不像决胜于同分 / 近分的行）。
  scored.sort((x, y) {
    final cx = x[1] + x[2] * 500;
    final cy = y[1] + y[2] * 500;
    return cy.compareTo(cx);
  });
  final hits = scored.map((e) => e[0]).toList();

  int? target;
  if (presetTarget != null && lines.isNotEmpty) {
    final base = presetTarget.clamp(0, lines.length - 1).toInt();
    target = base;
    // ① 只微调不否决：估计格才在 base ±8 内找更贴合的一行；
    //    找不到更贴合的就保持 base，最差跟改之前完全一样。
    //    ③' 上下文分参与微调决策：邻居也对得上的一行优先。
    if (estimated) {
      var bestLocal = base;
      var bestLocalScore =
          score(norm(lines[base])) + ctxScoreAt(base) * 500;
      for (var d = 1; d <= 8; d++) {
        for (final k in <int>[base - d, base + d]) {
          if (k < 0 || k >= lines.length) continue;
          final sc =
              score(norm(lines[k])) + ctxScoreAt(k) * 500;
          if (sc > bestLocalScore) {
            bestLocalScore = sc;
            bestLocal = k;
          }
        }
      }
      target = bestLocal;
    }
  } else if (bestByScan >= 0) {
    target = bestByScan;
  }

  // ③ 候选位置：当前定位永远第一；其余 = 宽松命中（按相像程度） + 前后 ±8 行。
  // **界面不显示行号**，这些数字只留在程序内部用来跳转。
  final center = (target ?? 0).clamp(0, lines.length - 1).toInt();
  final ordered = <int>[center];
  final seen = <int>{center};
  void add(int k) {
    if (k >= 0 && k < lines.length && seen.add(k)) ordered.add(k);
  }

  for (final h in hits) {
    add(h);
  }
  for (var d = 1; d <= 8; d++) {
    add(center - d);
    add(center + d);
  }
  if (presetTarget != null) {
    add(presetTarget.clamp(0, lines.length - 1).toInt());
  }
  final candidates = ordered.length > 48 ? ordered.sublist(0, 48) : ordered;

  return <Object?>[lines, target, candidates, hits];
}

class _LineHit {
  const _LineHit(this.line, this.start, this.end);
  final int line;
  final int start;
  final int end;
}

class _HighlightRange {
  const _HighlightRange(this.start, this.end, this.color, this.priority);
  final int start;
  final int end;
  final Color color;
  final int priority;
}

/// 支持「目标行黄底 + 当前匹配橙底」两个高亮区叠加的 TextEditingController。
/// 用 background Paint 画底色，不依赖选中文本，也不会导致打字时把整行覆盖掉。
class _MiniTextController extends TextEditingController {
  List<_HighlightRange> ranges = const <_HighlightRange>[];

  void setRanges(List<_HighlightRange> value) {
    ranges = value;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    if (text.isEmpty || ranges.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final bounds = <int>{0, text.length};
    for (final r in ranges) {
      bounds.add(r.start.clamp(0, text.length).toInt());
      bounds.add(r.end.clamp(0, text.length).toInt());
    }
    final pts = bounds.toList()..sort();

    final children = <InlineSpan>[];
    for (var i = 0; i < pts.length - 1; i++) {
      final s = pts[i];
      final e = pts[i + 1];
      if (e <= s) continue;
      _HighlightRange? top;
      for (final r in ranges) {
        if (r.start <= s &&
            r.end >= e &&
            (top == null || r.priority < top.priority)) {
          top = r;
        }
      }
      if (top == null) {
        children.add(TextSpan(text: text.substring(s, e)));
      } else {
        children.add(TextSpan(
          text: text.substring(s, e),
          style: TextStyle(background: Paint()..color = top.color),
        ));
      }
    }
    return TextSpan(style: style, children: children);
  }
}

/// 迷你编辑器的单行输入框（行虚拟化的基本单元）。
/// controller / 焦点节点由本行自己创建与销毁；父级只登记引用，
/// 便于「替换当前命中」直接改可见行文本、跳行后补焦点和高亮。
/// 行内容变化（替换/拆行/增删行/切换文件）经 widget.text 传入，
/// 在 didUpdateWidget 里同步进输入框。
class _MiniLineRow extends StatefulWidget {
  const _MiniLineRow({
    super.key,
    required this.index,
    required this.text,
    required this.fontSize,
    required this.isTarget,
    required this.isMultiSelected,
    required this.isRangeStart,
    required this.readOnly,
    required this.onChanged,
    required this.onLineBreak,
    required this.onTap,
    required this.onAttachCtrl,
    required this.onDetachCtrl,
    required this.onAttachFocus,
    required this.onDetachFocus,
    required this.onFocus,
  });

  final int index;
  final String text;
  final double fontSize;

  /// 目标行（长按对比行定位到的那行）：整行黄底。
  final bool isTarget;

  /// 多选勾选行：整行蓝底。
  final bool isMultiSelected;

  /// 区间选择已点起点（等终点）：整行绿底。
  final bool isRangeStart;

  /// 多选模式下正文输入被屏蔽（整行是勾选热区）。
  final bool readOnly;
  final ValueChanged<String> onChanged;
  final void Function(int index, String head, String rest) onLineBreak;
  final VoidCallback? onTap;
  final void Function(int index, _MiniTextController c) onAttachCtrl;
  final void Function(int index, _MiniTextController c) onDetachCtrl;
  final void Function(int index, FocusNode n) onAttachFocus;
  final void Function(int index, FocusNode n) onDetachFocus;
  final void Function(int index) onFocus;

  @override
  State<_MiniLineRow> createState() => _MiniLineRowState();
}

class _MiniLineRowState extends State<_MiniLineRow> {
  late final _MiniTextController _ctrl;
  late final FocusNode _node;

  /// 复用的换行拦截器，避免每次 build 都 new 一个；
  /// 依赖的 index 在 didUpdateWidget 里同步更新。
  late final _MiniBreakSplitter _splitter;

  @override
  void initState() {
    super.initState();
    _ctrl = _MiniTextController()..text = widget.text;
    _node = FocusNode(debugLabel: 'mini-line-${widget.index}');
    _node.addListener(_handleFocus);
    _splitter = _MiniBreakSplitter(widget.index, widget.onLineBreak);
    widget.onAttachCtrl(widget.index, _ctrl);
    widget.onAttachFocus(widget.index, _node);
  }

  void _handleFocus() {
    if (_node.hasFocus) widget.onFocus(widget.index);
  }

  @override
  void didUpdateWidget(covariant _MiniLineRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      oldWidget.onDetachCtrl(oldWidget.index, _ctrl);
      oldWidget.onDetachFocus(oldWidget.index, _node);
      _splitter.index = widget.index;
      widget.onAttachCtrl(widget.index, _ctrl);
      widget.onAttachFocus(widget.index, _node);
    }
    // 外部改了这一行的内容（替换/拆行/增删行/切换文件）→ 同步进输入框。
    if (widget.text != _ctrl.text) {
      _ctrl.text = widget.text;
    }
  }

  @override
  void dispose() {
    _node.removeListener(_handleFocus);
    widget.onDetachCtrl(widget.index, _ctrl);
    widget.onDetachFocus(widget.index, _node);
    _ctrl.dispose();
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    Color? bg;
    if (widget.isMultiSelected) {
      // 多选勾选行用蓝底，区别于区间起点的绿底和目标行的黄底。
      bg = Colors.blue.withValues(alpha: 0.15);
    } else if (widget.isRangeStart) {
      bg = Colors.green.withValues(alpha: 0.15);
    } else if (widget.isTarget) {
      bg = const Color(0x66FFE082);
    }

    Widget field = TextField(
      controller: _ctrl,
      focusNode: _node,
      readOnly: widget.readOnly,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      inputFormatters: <TextInputFormatter>[_splitter],
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: widget.fontSize,
        height: 1.1,
        color: s.onSurface,
      ),
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      ),
      onChanged: widget.onChanged,
    );

    if (widget.onTap != null) {
      // 多选模式：整行是勾选热区，正文交互被屏蔽——点哪里都是选行，
      // 不会误把光标插进正文（与文件浏览器行编辑器一致）。
      field = GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AbsorbPointer(child: field),
      );
    }

    return Container(color: bg, child: field);
  }
}

// ==================== 换行拦截器（粘贴/回车自动拆行） ====================

/// 在文本「提交给 controller 之前」把换行截走。
/// maxLines: null 的输入框收到多行文本时会先把整块布局一遍（卡顿根源），
/// formatter 是唯一能在 commit 之前改值的地方：这里只留首段，
/// 其余交给 [onLineBreak] 帧末统一插入，输入框从头到尾只排一行的版。
class _MiniBreakSplitter extends TextInputFormatter {
  _MiniBreakSplitter(this.index, this.onLineBreak);

  int index;
  void Function(int index, String head, String rest) onLineBreak;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    final idx = text.indexOf('\n');
    if (idx < 0) return newValue;

    final head = text.substring(0, idx);
    final rest = text.substring(idx + 1);

    // 光标落在首段内（粘贴时通常是首段末尾）。
    final cursor = newValue.selection.baseOffset;
    final offset = cursor < 0 ? head.length : cursor.clamp(0, head.length);

    onLineBreak(index, head, rest);

    return TextEditingValue(
      text: head,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}
