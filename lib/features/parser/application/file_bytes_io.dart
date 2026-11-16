import 'dart:io';
import 'dart:typed_data';

/// 把整份文件读进内存（异步）。
Future<Uint8List> readFileBytes(String path) => File(path).readAsBytes();

/// 同步读取，供后台 isolate 使用。
///
/// 必须放在 isolate 里调用：这样字节只在后台线程里存在一份，
/// 主线程不必先读一遍再复制过去。
Uint8List readFileBytesSync(String path) => File(path).readAsBytesSync();
