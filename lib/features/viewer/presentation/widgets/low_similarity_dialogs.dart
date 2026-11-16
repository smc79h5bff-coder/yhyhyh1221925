import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 风险提示弹窗（全 App 只有这一套黄色弹窗）的选择。
///
/// cancel  = 取消对比（调用方会真正停掉后台计算并退出对比页）；
/// proceed = 继续对比 / 继续等待（什么都不改，按原流程走）。
enum CompareRiskChoice { cancel, proceed }

// 与第一道相似度弹窗演示稿一致的琥珀色。
const Color _kAmber = Color(0xFFEF9F27);
const Color _kAmberDeep = Color(0xFFBA7517);

/// 统一的风险提示窗：柔和淡入上滑 + 缓慢呼吸圆点，不抖动、不用红色。
///
/// 三种场景共用：① 内容相似度较低 ② 对比前文件较大 ③ 加载超过 15 秒。
/// 一律「象征性拦一下」——只说明风险，永远给用户继续和取消两条路，
/// 绝不替用户把对比停死，也不显示 RSS / 安全线这类看不懂的数字。
Future<CompareRiskChoice?> showCompareRiskWarning(
  BuildContext context, {
  required String title,
  required String body,
  String metric = '',
  String cancelLabel = '取消对比',
  String proceedLabel = '继续对比',
}) {
  return showDialog<CompareRiskChoice>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CompareRiskPrompt(
      title: title,
      body: body,
      metric: metric,
      cancelLabel: cancelLabel,
      proceedLabel: proceedLabel,
    ),
  );
}

/// ① 内容相似度较低（快筛 < 40% 后弹出）。
///
/// 原来第二道红色「继续对比可能让应用卡住」已合并进来：
/// 那句解释不删，但不再让用户连点两道弹窗。
Future<CompareRiskChoice?> showLowSimilarityPrompt(
  BuildContext context, {
  required int percent,
}) {
  return showCompareRiskWarning(
    context,
    title: '内容相似度较低',
    body: '这两份内容只有约 $percent% 相同。可能是修改过多、内容大幅增删、'
        '简繁体混用，或含有特殊字符、乱码。\n\n'
        '内容差异越大，逐行对齐越慢。继续对比可能要等很久，'
        '甚至让应用无响应或闪退。',
  );
}

/// ② 对比之前：文件体积偏大（只提示，不硬拦）。
Future<CompareRiskChoice?> showLargeCompareWarning(
  BuildContext context, {
  required String fileName,
  required int maxMb,
  required int totalMb,
}) {
  return showCompareRiskWarning(
    context,
    title: '这次对比可能较慢',
    metric: '较大文件「$fileName」约 $maxMb MB · 两份合计约 $totalMb MB',
    body: '文件比较大，读进来和逐行对齐都要更久。继续对比可能要等很久，'
        '甚至让应用无响应或闪退。\n\n'
        '建议拆分文件分段对比，或改用电脑处理。',
  );
}

/// ③ 对比过程中：加载超过约定时间还没出结果。
Future<CompareRiskChoice?> showSlowCompareWarning(
  BuildContext context, {
  required int seconds,
}) {
  return showCompareRiskWarning(
    context,
    title: '还在对比，要继续等吗',
    metric: '已经等了 $seconds 秒，还没算出结果',
    body: '内容差异越大，逐行对齐越慢。继续等待可能要很久，'
        '甚至让应用无响应或闪退。\n\n'
        '不想再等可以取消对比，拆分文件后重试，或改用电脑处理。',
    proceedLabel: '继续等待',
  );
}

class _CompareRiskPrompt extends StatefulWidget {
  const _CompareRiskPrompt({
    required this.title,
    required this.body,
    required this.metric,
    required this.cancelLabel,
    required this.proceedLabel,
  });

  final String title;
  final String body;
  final String metric;
  final String cancelLabel;
  final String proceedLabel;

  @override
  State<_CompareRiskPrompt> createState() => _CompareRiskPromptState();
}

class _CompareRiskPromptState extends State<_CompareRiskPrompt>
    with TickerProviderStateMixin {
  late final AnimationController _entry = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420));
  late final AnimationController _loop = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2200))
    ..repeat();

  @override
  void initState() {
    super.initState();
    _entry.forward();
  }

  @override
  void dispose() {
    _entry.dispose();
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge([_entry, _loop]),
      builder: (context, _) {
        final enterDy = (1 - Curves.easeOut.transform(_entry.value)) * 26;
        final floatDy = math.sin(_loop.value * 2 * math.pi) * 4.5;
        return Opacity(
          opacity: _entry.value,
          child: Transform.translate(
            offset: Offset(0, enterDy + floatDy),
            child: Center(child: _card(s)),
          ),
        );
      },
    );
  }

  Widget _card(ColorScheme s) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Material(
        color: s.surface,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: s.surface,
            border: Border.all(color: _kAmber, width: 1.4),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _breathingDot(_kAmber),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: s.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
              if (widget.metric.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  widget.metric,
                  style: TextStyle(
                    fontSize: 12,
                    color: s.onSurfaceVariant.withOpacity(0.75),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                widget.body,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.65,
                  color: s.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _PressButton(
                    label: widget.cancelLabel,
                    filled: false,
                    color: s.primary,
                    onPressed: () =>
                        Navigator.pop(context, CompareRiskChoice.cancel),
                  ),
                  const SizedBox(width: 10),
                  _PressButton(
                    label: widget.proceedLabel,
                    filled: true,
                    color: _kAmberDeep,
                    onPressed: () =>
                        Navigator.pop(context, CompareRiskChoice.proceed),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _breathingDot(Color color) {
    return AnimatedBuilder(
      animation: _loop,
      builder: (context, _) {
        final t = _loop.value;
        final inner = 1 + 0.18 * math.sin(t * 2 * math.pi);
        final ringScale = 1 + t * 1.5;
        final ringOpacity = (1 - t) * 0.6;
        return SizedBox(
          width: 20,
          height: 20,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: ringScale,
                child: Opacity(
                  opacity: ringOpacity,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: color, width: 1.6),
                    ),
                  ),
                ),
              ),
              Transform.scale(
                scale: inner,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 带涟漪（InkWell）+ 按压缩放的按钮。
class _PressButton extends StatefulWidget {
  const _PressButton({
    required this.label,
    required this.filled,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final bool filled;
  final Color color;
  final VoidCallback onPressed;

  @override
  State<_PressButton> createState() => _PressButtonState();
}

class _PressButtonState extends State<_PressButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 110),
        child: Material(
          color: widget.filled ? widget.color : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(10),
            splashColor: widget.filled
                ? Colors.white.withOpacity(0.35)
                : widget.color.withOpacity(0.16),
            highlightColor: Colors.transparent,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: widget.filled ? Colors.white : widget.color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
