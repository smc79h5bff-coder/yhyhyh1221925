import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/pref_keys.dart';

/// 诊断总开关。
///
/// 一个开关管全部诊断写入：对比耗时日志、阅读页日志、文件统计、
/// 操作历史、崩溃日志、闪退痕迹、帧监控。
///
/// 关闭时，每个写入方法第一行就 return —— 不拼字符串、不建 Stopwatch、
/// 不写文件、不占内存，开销和"没有这套诊断代码"时一样。
///
/// 开关状态存本地，下次启动沿用。目前默认**关**：暂时不需要记录耗时。
/// 整套记录代码原样保留，简洁对比页的复制入口也跟着 [defaultEnabled] 走；
/// 以后想「显示 + 记录」一起恢复，只要把 [defaultEnabled] 改回 true 这一处。
class Diagnostics {
  Diagnostics._();

  /// 诊断的默认状态。改这一个常量就能整体恢复/停用记录功能。
  static const bool defaultEnabled = false;

  /// 监听它可以让界面跟着开关实时变化（诊断页、清单页的复制图标）。
  static final ValueNotifier<bool> enabledNotifier =
      ValueNotifier<bool>(defaultEnabled);

  static bool get enabled => enabledNotifier.value;

  static SharedPreferences? _prefs;

  /// main() 里 runApp 之前调一次。
  static void init(SharedPreferences prefs) {
    _prefs = prefs;
    enabledNotifier.value =
        prefs.getBool(PrefKeys.diagnosticsEnabled) ?? defaultEnabled;
  }

  /// 切换开关：内存立刻生效，磁盘异步保存。
  static void setEnabled(bool value) {
    if (enabledNotifier.value == value) return;
    enabledNotifier.value = value;
    final p = _prefs;
    if (p != null) {
      unawaited(p.setBool(PrefKeys.diagnosticsEnabled, value));
    }
  }
}
