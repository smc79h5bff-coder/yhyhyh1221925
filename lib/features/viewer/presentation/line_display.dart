import 'package:flutter/material.dart';

/// 单行显示的硬上限。超过后只渲染前 [kMaxDisplayLineChars] 个字符，
/// 防止一行几十万字把排版引擎撑爆（卡死 → 原生内存耗尽 → 闪退）。
///
/// 只影响显示：对比、查找、导出仍使用完整文本。
const int kMaxDisplayLineChars = 2000;

/// 把一行裁到可安全渲染的长度；未超限时原样返回（不复制字符串）。
String clipLineForDisplay(String line, {int max = kMaxDisplayLineChars}) {
  if (line.length <= max) return line;
  var cut = max;
  // 不要把代理对（emoji 等）切成两半
  if (cut > 0) {
    final unit = line.codeUnitAt(cut - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) cut -= 1;
  }
  return '${line.substring(0, cut)}…（本行共 ${line.length} 字符）';
}

/// 超长行的只读预览：不把整行塞进 TextField，避免编辑框再次卡死。
Future<void> showLongLinePreview(
  BuildContext context, {
  required String title,
  required String text,
}) {
  return showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      insetPadding: const EdgeInsets.all(16),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: SelectableText(clipLineForDisplay(text)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
