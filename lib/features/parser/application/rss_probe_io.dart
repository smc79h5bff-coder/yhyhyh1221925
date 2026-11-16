import 'dart:io';

/// 当前进程常驻内存（字节）。Android / iOS / 桌面可用。
int? currentRssBytes() => ProcessInfo.currentRss;
