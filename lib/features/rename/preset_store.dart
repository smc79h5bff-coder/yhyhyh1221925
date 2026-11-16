import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'rename_models.dart';

/// 多套命名方案的持久化、文本导入导出、以及「撤销上次批量改名」记录。
///
/// 导入导出走剪贴板文本而不是文件选择器：零权限、零平台差异，
/// 微信/备忘录里发一段 JSON 就能换设备恢复。
class RenamePresetStore {
  const RenamePresetStore._();

  static const RenamePresetStore instance = RenamePresetStore._();

  static const String _kPresets = 'content_rename_presets_v1';
  static const String _kActive = 'content_rename_active_v1';
  static const String _kRemember = 'content_rename_remember_preset_v1';
  static const String _kUndo = 'content_rename_undo_v1';

  static const int _exportVersion = 1;

  /// 读所有方案；没有或坏了就给一套默认方案。
  Future<List<RenamePreset>> loadPresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPresets);
      if (raw == null || raw.isEmpty) {
        return <RenamePreset>[RenamePreset.starter()];
      }
      final v = jsonDecode(raw);
      if (v is List) {
        final out = <RenamePreset>[];
        for (final e in v) {
          if (e is Map) {
            final p = RenamePreset.fromJson(Map<String, dynamic>.from(e));
            if (p.name.trim().isNotEmpty) out.add(p);
          }
        }
        if (out.isNotEmpty) return out;
      }
    } catch (_) {}
    return <RenamePreset>[RenamePreset.starter()];
  }

  Future<void> savePresets(List<RenamePreset> presets) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kPresets,
        jsonEncode(<dynamic>[for (final p in presets) p.toJson()]),
      );
    } catch (_) {}
  }

  Future<String?> loadActiveName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kActive);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveActiveName(String? name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (name == null || name.isEmpty) {
        await prefs.remove(_kActive);
      } else {
        await prefs.setString(_kActive, name);
      }
    } catch (_) {}
  }

  /// 是否记住上次选的方案。默认 false，与「记住上次规则」开关保持一致。
  Future<bool> loadRememberPreset() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kRemember) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveRememberPreset(bool v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kRemember, v);
    } catch (_) {}
  }

  /// 导出成可读 JSON 文本。
  static String exportToText(List<RenamePreset> presets) {
    return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'version': _exportVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'presets': <dynamic>[for (final p in presets) p.toJson()],
    });
  }

  /// 解析导入文本；格式不对返回 null，永不抛异常。
  static List<RenamePreset>? parseImport(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return null;
      final version = v['version'];
      if (version is int && version > _exportVersion) return null;
      final list = v['presets'];
      if (list is! List) return null;
      final out = <RenamePreset>[];
      for (final e in list) {
        if (e is Map) {
          final p = RenamePreset.fromJson(Map<String, dynamic>.from(e));
          if (p.name.trim().isNotEmpty) out.add(p);
        }
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// 记下撤销映射：「改名后路径 → 改名前的原路径」。
  /// 方向必须是反的——撤销时 key 是当前磁盘上存在的文件，value 是要改回去的名字。
  Future<void> saveUndo(Map<String, String> renameMap) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kUndo,
        jsonEncode(<String, dynamic>{
          'at': DateTime.now().toIso8601String(),
          'map': renameMap,
        }),
      );
    } catch (_) {}
  }

  Future<Map<String, String>?> loadUndo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kUndo);
      if (raw == null || raw.isEmpty) return null;
      final v = jsonDecode(raw);
      if (v is! Map) return null;
      final m = v['map'];
      if (m is! Map) return null;
      final out = <String, String>{};
      for (final e in m.entries) {
        out[e.key.toString()] = e.value.toString();
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearUndo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kUndo);
    } catch (_) {}
  }
}
