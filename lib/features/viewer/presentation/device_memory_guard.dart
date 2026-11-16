// device_memory_guard.dart
//
// 机型内存画像与危险线计算器。
//
// 【重要 · 2026-11-13 调整】「按 RSS 主动熔断对比」已停用：
// ProcessInfo.currentRss 含 Flutter 引擎和整个界面，App 一启动就 200MB 上下，
// 拿它跟 memoryClass 的危险线比，连 3KB 的小文件都会误判「对比已暂停」。
// 现在对比流程只做「黄色风险提示 + 用户自己选继续/取消」，不再自动停。
//
// 本文件仍被以下地方使用：
//   · DocumentParser：docx / epub 解析的规模上限（ParseLimits.forDevice）；
//   · import_screen / share_intake_service / file_browser 读盘时的画像读取；
//   · AbortKind / AbortInfo 等保留类型（当前不再触发，留作诊断与后续复用）。
//
// 尺子仍是 Android 的 memoryClass（系统给单个 App 的堆上限）：
//   · 低端机 128 / 192 MB，中端 256 MB，旗舰 384 / 512 MB 甚至更高。
// 读不到原生信息（非 Android、通道异常、老系统）时降级到固定兜底值。

import 'dart:io';

import 'package:flutter/services.dart';

/// 中止原因。
enum AbortKind {
  /// 未中止，正常完成。
  none,

  /// ① 动态占比：进程 RSS 逼近本机型危险线。
  memory,

  /// ② 硬上限兜底：中间段行数超过 [kMaxMidLines]。
  lines,

  /// ② 硬上限兜底：输出差异条数超过 [kMaxDiffEntries]。
  entries,
}

/// ② 硬上限：中段参与 diff 的行数（两边合计）超过这个值就停。
/// 这是"死板但必中"的保险丝，防 ① 的 RSS 采样间隔里内存瞬间暴涨。
/// 取 60 万行：正常长篇小说（单本几十万行）够用，
/// 真正"两坨不同内容硬拼"才会撞到。
const int kMaxMidLines = 600000;

/// ② 硬上限：输出差异条数超过这个值就停。
/// 全红全绿的极端对比会生成海量条目，回传主线程前掐断。
const int kMaxDiffEntries = 120000;

/// ① 拿不到机型信息时的固定兜底危险线（进程 RSS，MB）。
/// 与 crash_logger 里"RSS > 300MB 记一笔"的经验线对齐，偏保守。
const int kFallbackDangerRssMb = 300;

/// 危险线占 memoryClass 的比例。留有余量，不贴着上限跑。
/// 例如 memoryClass=192MB × 0.72 ≈ 138MB 触发，给构造 DiffEntry 和渲染留空间。
const double _kHeapRatio = 0.72;

/// 危险线绝对封顶（MB）：再强的机子也不让它吃超过这个，
/// 因为进程 RSS 里还含 Flutter 引擎、图片缓存等，不能全给 diff。
const int _kHardCeilingMb = 512;

/// 危险线绝对地板（MB）：再弱的机子也留这么点，
/// 否则像"是/否"这种正常小对比会被误伤。
const int _kHardFloorMb = 96;

/// 系统可用内存低于这个值（MB）时，额外收紧危险线——
/// 系统整体吃紧，就算 memoryClass 高也该早停。
const int _kLowAvailMemMb = 400;
const double _kLowAvailFactor = 0.8;

/// 设备内存画像。
class DeviceMemory {
  const DeviceMemory({
    required this.memoryClassMb,
    required this.largeMemoryClassMb,
    required this.availMemMb,
    required this.totalMemMb,
    required this.lowMemory,
    required this.fromNative,
  });

  final int memoryClassMb;
  final int largeMemoryClassMb;
  final int availMemMb;
  final int totalMemMb;
  final bool lowMemory;

  /// true = 读到了真实的原生数据；false = 降级兜底值。
  final bool fromNative;

  factory DeviceMemory.fallback() => const DeviceMemory(
        memoryClassMb: 0,
        largeMemoryClassMb: 0,
        availMemMb: 0,
        totalMemMb: 0,
        lowMemory: false,
        fromNative: false,
      );

  /// 本机型进程 RSS 危险线（字节）。
  ///
  /// 以 memoryClass 为基准按比例算，夹在地板与天花板之间；
  /// 系统可用内存吃紧或已处于 lowMemory 时再乘一个收紧系数。
  /// 最终值交给后台 worker，它每处理一批就读一次 ProcessInfo.currentRss 比较。
  int get dangerRssBytes {
    if (!fromNative || memoryClassMb <= 0) {
      return kFallbackDangerRssMb * 1024 * 1024;
    }

    double mb = memoryClassMb * _kHeapRatio;
    if (mb > _kHardCeilingMb) mb = _kHardCeilingMb.toDouble();
    if (mb < _kHardFloorMb) mb = _kHardFloorMb.toDouble();

    // 系统整体吃紧：收紧，宁可早停也不冒无声闪退。
    if (lowMemory || (availMemMb > 0 && availMemMb < _kLowAvailMemMb)) {
      mb *= _kLowAvailFactor;
      if (mb < _kHardFloorMb) mb = _kHardFloorMb.toDouble();
    }
    return (mb * 1024 * 1024).round();
  }

  /// 给人看的危险线（MB），写诊断日志 / 提示用。
  int get dangerRssMb => dangerRssBytes ~/ 1024 ~/ 1024;
}

/// 读设备内存画像。必须在主 isolate 调（MethodChannel 不能跨到后台 isolate）；
/// 拿到后把 [DeviceMemory.dangerRssBytes] 作为参数随 compute 传进 worker。
///
/// 任何异常都返回 [DeviceMemory.fallback]，绝不让读内存这件事挡住对比。
Future<DeviceMemory> readDeviceMemory() async {
  // Platform.isAndroid 在 web 上会抛 UnsupportedError，连同通道调用一起
  // 放进 try，任何平台/异常都降级到固定兜底，绝不影响对比本身。
  try {
    if (!Platform.isAndroid) return DeviceMemory.fallback();
    final r = await const MethodChannel('docdiff/memory_info')
        .invokeMethod<Map<Object?, Object?>>('getMemoryInfo');
    if (r == null || r['ok'] != true) return DeviceMemory.fallback();

    int asInt(Object? v) => (v is num) ? v.round() : 0;
    return DeviceMemory(
      memoryClassMb: asInt(r['memoryClassMb']),
      largeMemoryClassMb: asInt(r['largeMemoryClassMb']),
      availMemMb: asInt(r['availMemMb']),
      totalMemMb: asInt(r['totalMemMb']),
      lowMemory: r['lowMemory'] == true,
      fromNative: true,
    );
  } catch (_) {
    return DeviceMemory.fallback();
  }
}
