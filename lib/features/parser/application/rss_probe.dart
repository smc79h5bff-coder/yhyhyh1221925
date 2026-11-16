// 进程 RSS 探测。web 上没有 dart:io，用条件导出切换到 stub。
export 'rss_probe_stub.dart' if (dart.library.io) 'rss_probe_io.dart';
