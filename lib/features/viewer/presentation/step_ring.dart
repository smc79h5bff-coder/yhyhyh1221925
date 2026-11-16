// step_ring.dart
//
// 对比相关所有「等待中」指示器的公共实现：一个离散跳格圆环。
//
// 三个场景共用同一份圆环，避免各写一套、颜色/节奏跑偏：
//   · StepRingLoading         首次进对比页的整页加载、切视图遮罩、简洁对比页加载
//   · StepRingJumpIndicator   长按上/下按钮跳到文首/文末时的遮罩
//
// 抗卡要点：不用 AnimationController.repeat()，不每帧重画 canvas。
// 只有 Timer.periodic 每 300ms 把索引往前推一格，重绘是 8 条实色短弧；
// 主线程被读盘、解码、建高度表、分帧滚动占住时，Timer 只是晚跳一拍。
// 配色来自 loadingPaletteIndexProvider：一次对比抽一次，整次会话不变。
//
// 注意：StepRingLoading 的「超过 3 秒」提示按 compareStartedAt 算，
// 而跳转发生在对比页打开之后，所以 StepRingJumpIndicator 刻意不复用它，
// 只显示固定短文案，不轮播、不带超时提示。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'crash_trace.dart';
import 'loading_palette.dart';

/// 长按上 / 下按钮跳到文首 / 文末时的方向。
enum JumpDirection { up, down }

// ==================== 纯圆环 ====================

/// 8 段短弧组成的圆环：当前格 + 两级拖尾，整组按 index 跳。
/// 只有 1 个 Timer、1 个整数状态，重绘被 RepaintBoundary 隔离成独立 layer。
class StepRing extends ConsumerStatefulWidget {
  const StepRing({super.key, this.size = 72});

  /// 直径。整页加载用 72，跳转遮罩用 64。
  final double size;

  @override
  ConsumerState<StepRing> createState() => _StepRingState();
}

class _StepRingState extends ConsumerState<StepRing> {
  static const int _segmentCount = 8;
  static const Duration _step = Duration(milliseconds: 300);

  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_step, (_) {
      if (!mounted) return;
      setState(() => _index = (_index + 1) % _segmentCount);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final colors =
        paletteOf(ref.watch(loadingPaletteIndexProvider)).of(brightness);
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: StepRingPainter(
            index: _index,
            active: colors[0],
            trailNear: colors[1],
            trailFar: colors[2],
            base: colors[3],
          ),
        ),
      ),
    );
  }
}

/// 每次只画 8 条实色弧，shouldRepaint 只比 index 和 4 个颜色。
/// 没有 SweepGradient / MaskFilter.blur / saveLayer。
class StepRingPainter extends CustomPainter {
  const StepRingPainter({
    required this.index,
    required this.active,
    required this.trailNear,
    required this.trailFar,
    required this.base,
  });

  final int index;
  final Color active;
  final Color trailNear;
  final Color trailFar;
  final Color base;

  static const int _count = 8;
  static const double _gapRatio = 0.18;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 5;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    const stepAngle = 2 * math.pi / _count;
    final sweep = stepAngle * (1 - _gapRatio);
    for (var i = 0; i < _count; i++) {
      final start = -math.pi / 2 + i * stepAngle + stepAngle * _gapRatio / 2;
      final back = (index - i + _count) % _count;
      final color = back == 0
          ? active
          : back == 1
              ? trailNear
              : back == 2
                  ? trailFar
                  : base;
      paint.color = color;
      canvas.drawArc(rect, start, sweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(StepRingPainter old) =>
      old.index != index ||
      old.active != active ||
      old.trailNear != trailNear ||
      old.trailFar != trailFar ||
      old.base != base;
}

// ==================== 整页加载 ====================

/// 首次进对比页 / 切视图遮罩 / 简洁对比页加载。
/// text 非空时显示真实阶段（正在读取 xx.txt…），为空时轮播三条通用提示。
class StepRingLoading extends ConsumerStatefulWidget {
  const StepRingLoading({super.key, this.text});

  final String? text;

  @override
  ConsumerState<StepRingLoading> createState() => _StepRingLoadingState();
}

class _StepRingLoadingState extends ConsumerState<StepRingLoading>
    with SingleTickerProviderStateMixin {
  static const List<String> _stages = [
    '正在比较…',
    '正在排版…',
    '马上就绪…',
  ];

  int _stageIndex = 0;
  bool _slow = false;
  late final AnimationController _intro;
  late final DateTime _createdAt;
  Timer? _stageTimer;
  Timer? _slowTimer;

  @override
  void initState() {
    super.initState();
    _createdAt = DateTime.now();
    CrashTrace.mark('进入加载页');
    // 只播一次、不循环：长帧时按时间直接跳到终点，不会持续占用主线程。
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..forward();
    _stageTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!mounted || widget.text != null) return;
      setState(() => _stageIndex = (_stageIndex + 1) % _stages.length);
    });
    // 一次性 Timer，到点只重建一次。按「本次对比开始时刻」算，
    // 加载页重建多次也不会重新计时，大文件才看得到这行提示。
    final started = compareStartedAt ?? _createdAt;
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    if (elapsed >= 3000) {
      _slow = true;
    } else {
      _slowTimer = Timer(Duration(milliseconds: 3000 - elapsed), () {
        if (!mounted) return;
        setState(() => _slow = true);
      });
    }
  }

  @override
  void dispose() {
    _stageTimer?.cancel();
    _slowTimer?.cancel();
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final colors =
        paletteOf(ref.watch(loadingPaletteIndexProvider)).of(brightness);
    final text = widget.text ?? _stages[_stageIndex];
    final textColor = colors[4];

    return Center(
      child: FadeTransition(
        opacity: _intro,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const StepRing(size: 72),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Text(
                text,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: textColor,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            if (_slow) ...[
              const SizedBox(height: 8),
              Text(
                '文件较大，正在计算…',
                style: TextStyle(
                  fontSize: 12,
                  color: textColor.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ==================== 长按跳转遮罩 ====================

/// 长按上 / 下按钮跳到文首 / 文末时的遮罩指示器。
/// 跟加载页共用 StepRing，但只显示固定短文案，不轮播、不带超时提示。
/// 圆环中心留空（不再叠双箭头），方向全靠下方文字表达。
class StepRingJumpIndicator extends ConsumerStatefulWidget {
  const StepRingJumpIndicator({
    super.key,
    required this.direction,
    this.size = 64,
  });

  final JumpDirection direction;
  final double size;

  @override
  ConsumerState<StepRingJumpIndicator> createState() =>
      _StepRingJumpIndicatorState();
}

class _StepRingJumpIndicatorState
    extends ConsumerState<StepRingJumpIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _intro;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..forward();
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final colors =
        paletteOf(ref.watch(loadingPaletteIndexProvider)).of(brightness);
    final text =
        widget.direction == JumpDirection.up ? '跳到开头' : '跳到结尾';

    return Center(
      child: FadeTransition(
        opacity: _intro,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StepRing(size: widget.size),
            const SizedBox(height: 24),
            Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: colors[4],
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
