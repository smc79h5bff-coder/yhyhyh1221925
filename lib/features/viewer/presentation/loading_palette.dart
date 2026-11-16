// loading_palette.dart
//
// 对比页加载动画（跳格圆环）的配色表。
//
// 一次对比会话只抽一次色：加载页会重建好几次（阶段文案 → loading → 等高度表），
// 还有切视图遮罩，如果每次 initState 都重新抽色，同一次对比里圆环会突然变色。
// 所以由文件浏览器在 _startCompare 起点写一次 provider，这里只读不算。
//
// 颜色是常量查表，不增加 Timer、不增加重绘次数。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 一套配色的 5 个颜色，下标固定：
/// 0 跳动块 / 1 拖尾近 / 2 拖尾远 / 3 八段底环 / 4 阶段文字。
class LoadingPalette {
  const LoadingPalette({required this.light, required this.dark});

  final List<Color> light;
  final List<Color> dark;

  List<Color> of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// 7 套档位：从历轮候选中点名保留的 7 套。
/// 薰衣豆沙（粉紫③偏紫）/ 蜜桃奶霜（粉橙①偏粉）/ A 偏粉·明快（粉棕 A）/
/// 青柠绿（跳动 #7DBE3E，奶油黄底环 #E4D7B4）/ 灰紫 × 青柠（Lavender + lime）/
/// 蓝和紫（雾蓝 + 薰衣草紫）/ 天蓝 × 苹果绿（Tailwind Sky × Lime 高饱和交叉）。
///
/// 浅色、深色两组色值都沿用当时给出的成套值，未重新调色。
/// 下标含义见 LoadingPalette 注释。
const List<LoadingPalette> kLoadingPalettes = [
  // 薰衣豆沙 · 偏紫（粉紫③，替换原樱花丁香偏粉档）
  LoadingPalette(
    light: [
      Color(0xFFCF9CC2),
      Color(0xFFCFB7D8),
      Color(0xFFCDC7DF),
      Color(0xFFE4E0EC),
      Color(0xFF4C4459),
    ],
    dark: [
      Color(0xFFF0A9D0),
      Color(0xFFB486B0),
      Color(0xFF796A91),
      Color(0xFF3F3749),
      Color(0xFFE6DEEA),
    ],
  ),
  // 蜜桃奶霜 · 偏粉（粉橙①）
  LoadingPalette(
    light: [
      Color(0xFFF295A6),
      Color(0xFFF7B9A6),
      Color(0xFFF2D2B6),
      Color(0xFFF3E4D2),
      Color(0xFF6B4A36),
    ],
    dark: [
      Color(0xFFF7AFA2),
      Color(0xFFC98A6E),
      Color(0xFF8C6A50),
      Color(0xFF4A3A2E),
      Color(0xFFEADFD3),
    ],
  ),
  // A 偏粉 · 明快（粉棕 A，跳动块 #F08FA8）
  LoadingPalette(
    light: [
      Color(0xFFF08FA8),
      Color(0xFFF6BCC7),
      Color(0xFFEBD3CE),
      Color(0xFFEADFD9),
      Color(0xFF5B463C),
    ],
    dark: [
      Color(0xFFF2A6B4),
      Color(0xFFA8736F),
      Color(0xFF6B5149),
      Color(0xFF4A3B33),
      Color(0xFFE8DCD5),
    ],
  ),
  // 青柠绿（跳动 #7DBE3E / 奶油黄底环 #E4D7B4）
  LoadingPalette(
    light: [
      Color(0xFF7DBE3E),
      Color(0xFFA8D77C),
      Color(0xFFD8E7B4),
      Color(0xFFE4D7B4),
      Color(0xFF4A5222),
    ],
    dark: [
      Color(0xFFA8DE63),
      Color(0xFF6E9440),
      Color(0xFF4A632C),
      Color(0xFF4A4227),
      Color(0xFFE9F5D4),
    ],
  ),
  // 灰紫 × 青柠 / Lavender + lime
  LoadingPalette(
    light: [
      Color(0xFF8C7480),
      Color(0xFFCDC3DC),
      Color(0xFF9CAF88),
      Color(0xFFF4F1EC),
      Color(0xFF3C3C40),
    ],
    dark: [
      Color(0xFFCDC3DC),
      Color(0xFF8C7480),
      Color(0xFFD4E09B),
      Color(0xFF37474F),
      Color(0xFFE6E6DD),
    ],
  ),
  // 蓝和紫（雾蓝 + 薰衣草紫）：第 3 格起换成紫、底环也是紫的浅版
  LoadingPalette(
    light: [
      Color(0xFF6A86B8),
      Color(0xFFC5D6E3),
      Color(0xFFCDC3DC),
      Color(0xFFF0ECF8),
      Color(0xFF3C3C40),
    ],
    dark: [
      Color(0xFFC5D6E3),
      Color(0xFF6A86B8),
      Color(0xFFCDC3DC),
      Color(0xFF37474F),
      Color(0xFFF0ECF8),
    ],
  ),
  // 天蓝 × 苹果绿（Δ116° · S167 · L103）：第 3 格起换成苹果绿，底环是 Lime 浅阶
  LoadingPalette(
    light: [
      Color(0xFF0EA5E9),
      Color(0xFF7DD3FC),
      Color(0xFFA3E635),
      Color(0xFFECFCCB),
      Color(0xFF0C4A6E),
    ],
    dark: [
      Color(0xFF7DD3FC),
      Color(0xFF0EA5E9),
      Color(0xFFD9F99D),
      Color(0xFF37474F),
      Color(0xFFE0F2FE),
    ],
  ),
];

/// 本次对比选中的配色下标（默认 0，不持久化、重启从粉棕开始）。
final loadingPaletteIndexProvider = StateProvider<int>((ref) => 0);

/// 本次对比的开始时刻。加载页会重建多次，超时提示不能按「组件存活时间」算，
/// 否则每次重建都重新从 0 计时，大文件反而永远看不到提示。
DateTime? _compareStartedAt;
DateTime? get compareStartedAt => _compareStartedAt;

/// 每次点「对比 / 简洁对比」时调用一次；之后整次会话都读同一个值。
void pickLoadingPalette(WidgetRef ref) {
  _compareStartedAt = DateTime.now();
  ref.read(loadingPaletteIndexProvider.notifier).state =
      math.Random().nextInt(kLoadingPalettes.length);
}

LoadingPalette paletteOf(int index) =>
    kLoadingPalettes[index % kLoadingPalettes.length];
