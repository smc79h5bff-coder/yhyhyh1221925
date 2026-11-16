import 'dart:typed_data';

/// web 上没有本地文件路径（文件通过选择器交上来，字节已在内存）。
/// 调用方应改用按字节解析的 [DocumentParser.parse] 入口。
Future<Uint8List> readFileBytes(String path) async =>
    throw UnsupportedError('当前平台不支持按路径读取本地文件。');

/// 同 [readFileBytes]，同步版本。
Uint8List readFileBytesSync(String path) =>
    throw UnsupportedError('当前平台不支持按路径读取本地文件。');
