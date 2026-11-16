import 'rename_models.dart';

/// 模板渲染结果。
class TemplateResult {
  const TemplateResult({
    required this.baseName,
    required this.missing,
    required this.usedContentVariable,
  });

  /// 生成的文件名（不含扩展名）。空串表示模板没产出可用名字。
  final String baseName;

  /// 没有值的变量名（内置变量不算）。用于预览里标黄「待确认」。
  final Set<String> missing;

  /// 是否真的用到了从正文提取的变量。
  final bool usedContentVariable;
}

/// 命名模板引擎。
///
/// 语法：
///   {变量}            取变量值，取不到就是空
///   {变量|默认值}      取不到时用默认值
///   [可选片段]         片段里任一变量为空时，整段（含分隔符）一起消失
///   \[  \]  \{  \}    输出字面量括号
///
/// 设计要点：可选片段是必须的。若模板写死 "{原名} - {作者}"，
/// 没作者的书会变成 "三体 - .txt"；写成 "{原名}[ - {作者}]" 才是 "三体.txt"。
class RenameTemplateEngine {
  const RenameTemplateEngine._();

  static const String _escOpenBracket = '\u0001';
  static const String _escCloseBracket = '\u0002';
  static const String _escOpenBrace = '\u0003';
  static const String _escCloseBrace = '\u0004';

  static final RegExp _varPattern = RegExp(r'\{([^{}]+)\}');
  static final RegExp _illegalPattern =
      RegExp(r'[<>/\\:*?"|\x00-\x1F\x7F]');

  /// 模板里出现了哪些变量名（去掉默认值部分），供 UI 提示用。
  static Set<String> variableNames(String template) {
    final out = <String>{};
    for (final m in _varPattern.allMatches(template)) {
      final raw = m.group(1) ?? '';
      final name = raw.split('|').first.trim();
      if (name.isNotEmpty) out.add(name);
    }
    return out;
  }

  static TemplateResult render({
    required String template,
    required Map<String, String> variables,
    required RenamePreset preset,
    required Set<String> contentVariableNames,
  }) {
    final missing = <String>{};
    var usedContent = false;

    // 0. 先按「原始模板」记录没取到值的内容变量。
    // 可选片段会把整段（连同里面的变量）一起丢掉，光看第 3 步的替换是发现不了的；
    // 不补这一步，预览就不会标黄「待确认」，用户会以为每本都抓到了作者。
    // 有默认值语法 {变量|x} 的不算缺失；内置变量不参与。
    for (final m in _varPattern.allMatches(template)) {
      final raw = m.group(1) ?? '';
      final parts = raw.split('|');
      final name = parts.first.trim();
      if (name.isEmpty || parts.length > 1) continue;
      if (contentVariableNames.contains(name) &&
          (variables[name] ?? '').isEmpty) {
        missing.add(name);
      }
    }

    // 1. 转义字符先藏起来，避免被当成语法符号。
    var s = template
        .replaceAll(r'\[', _escOpenBracket)
        .replaceAll(r'\]', _escCloseBracket)
        .replaceAll(r'\{', _escOpenBrace)
        .replaceAll(r'\}', _escCloseBrace);

    // 2. 可选片段：没值的变量所在片段整段消失。
    s = _resolveOptionals(s, variables);

    // 3. 变量替换。
    s = s.replaceAllMapped(_varPattern, (m) {
      final raw = m.group(1) ?? '';
      final parts = raw.split('|');
      final name = parts.first.trim();
      final hasDefault = parts.length > 1;
      final fallback = hasDefault ? parts.sublist(1).join('|').trim() : '';

      var value = variables[name] ?? '';
      if (value.isEmpty && hasDefault) value = fallback;
      if (value.isEmpty) {
        missing.add(name);
        return '';
      }
      if (contentVariableNames.contains(name)) usedContent = true;
      return value;
    });

    // 4. 还原转义字符。
    s = s
        .replaceAll(_escOpenBracket, '[')
        .replaceAll(_escCloseBracket, ']')
        .replaceAll(_escOpenBrace, '{')
        .replaceAll(_escCloseBrace, '}');

    // 5. 清洗成合法文件名。
    s = _sanitize(s, preset);

    return TemplateResult(
      baseName: s,
      missing: missing,
      usedContentVariable: usedContent,
    );
  }

  /// 递归解析方括号片段，支持嵌套。片段内任一变量为空则整段丢弃。
  static String _resolveOptionals(String src, Map<String, String> variables) {
    final out = StringBuffer();
    var i = 0;
    while (i < src.length) {
      if (src[i] != '[') {
        out.write(src[i]);
        i++;
        continue;
      }

      // 找配对的右括号。
      var depth = 1;
      var j = i + 1;
      while (j < src.length && depth > 0) {
        if (src[j] == '[') {
          depth++;
        } else if (src[j] == ']') {
          depth--;
          if (depth == 0) break;
        }
        j++;
      }
      if (depth != 0) {
        // 没有闭合，当普通字符处理，避免吞掉后面的内容。
        out.write('[');
        i++;
        continue;
      }

      final inner = src.substring(i + 1, j);
      if (_hasEmptyVariable(inner, variables)) {
        // 整段丢弃（含片名里的固定分隔符）。
      } else {
        out.write(_resolveOptionals(inner, variables));
      }
      i = j + 1;
    }
    return out.toString();
  }

  /// 片段内是否存在「取不到值且没有默认值」的变量。
  static bool _hasEmptyVariable(String fragment, Map<String, String> variables) {
    for (final m in _varPattern.allMatches(fragment)) {
      final raw = m.group(1) ?? '';
      final parts = raw.split('|');
      final name = parts.first.trim();
      if (name.isEmpty) continue;
      final value = variables[name] ?? '';
      if (value.isEmpty && parts.length <= 1) return true;
    }
    return false;
  }

  /// 非法字符、空格、长度、结尾点。扩展名由调用方另行保留。
  static String _sanitize(String src, RenamePreset preset) {
    var s = src;
    if (preset.illegalCharMode == 'replace') {
      final rep = preset.illegalReplacement.isEmpty
          ? '-'
          : preset.illegalReplacement;
      s = s.replaceAllMapped(_illegalPattern, (_) => rep);
    } else {
      s = s.replaceAll(_illegalPattern, '');
    }
    if (preset.spaceToUnderscore) {
      s = s.replaceAll(RegExp(r'[\s\u3000]+'), '_');
    } else {
      s = s.replaceAll(RegExp(r'[\s\u3000]+'), ' ');
    }
    s = s.trim();
    // Windows / Android 都不允许以点或空格结尾。
    while (s.endsWith('.') || s.endsWith(' ')) {
      s = s.substring(0, s.length - 1);
    }
    final max = preset.maxNameLength;
    if (max > 0 && s.length > max) s = s.substring(0, max).trim();
    if (s == '.' || s == '..') s = '';
    return s;
  }

  /// 把模板结果和扩展名拼起来。基础名为空时不拼，
  /// 否则会生成 ".txt" 这种隐藏文件；调用方会把空名当「待确认」处理。
  static String withExtension(String baseName, String ext) {
    if (baseName.isEmpty) return '';
    return ext.isEmpty ? baseName : '$baseName.$ext';
  }

  /// 输出设置对三种命名方式全局生效：对「基础名」（不含扩展名）按
  /// 非法字符 / 空格换下划线 / 长度上限清洗。规则组合、命名格式、
  /// 模板重写算出名字后都过这一道，保证 ④ 输出设置一处配置全局生效。
  static String sanitizeBaseName(String base, RenamePreset preset) {
    return _sanitize(base, preset);
  }

  /// 手改某一行的目标文件名时做清洗：复用模板那套非法字符 / 空格 / 长度规则，
  /// 并保证用户忘写扩展名时自动补回原扩展名。
  /// 返回空串表示这个名字不可用（全被删光），调用方应提示重填。
  /// 用户自己写了带点的名字就完全按他填的来（允许改扩展名）。
  static String sanitizeManualName(
    String raw,
    RenamePreset preset,
    String oldName,
  ) {
    var s = _sanitize(raw, preset);
    if (s.isEmpty) return '';
    final dot = s.lastIndexOf('.');
    final hasExt = dot > 0 && dot < s.length - 1;
    if (!hasExt) {
      final oldDot = oldName.lastIndexOf('.');
      if (oldDot > 0 && oldDot < oldName.length - 1) {
        s = s + oldName.substring(oldDot);
      }
    }
    return s;
  }

  /// 重名自动加后缀：把 [format] 里的 {n} 换成序号 k，插在扩展名之前；
  /// 文件夹或没扩展名的直接追加在末尾。
  /// [format] 缺省为 '_{n}'（兼容旧调用 → "三体_2.txt"）。
  /// 格式不含 {n} / 含非法字符 / 过长时一律回退默认，避免所有冲突行
  /// 生成同一个名字、循环到 999 还解决不了重名。
  /// 抽成纯函数方便单测，界面里的冲突处理直接调它。
  static String withSeqSuffix(
    String name,
    int k, {
    String format = RenamePreset.defaultConflictSuffixFormat,
  }) {
    final suffix = RenamePreset.normalizeConflictSuffixFormat(format)
        .replaceAll('{n}', '$k');
    final dot = name.lastIndexOf('.');
    if (dot > 0 && dot < name.length - 1) {
      return '${name.substring(0, dot)}$suffix${name.substring(dot)}';
    }
    return '$name$suffix';
  }
}
