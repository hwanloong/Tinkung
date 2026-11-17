import 'dart:io';

import 'package:flutter/services.dart';

/// 用户自己选的字体文件（`.ttf` / `.otf`）。
///
/// ## 为什么是"运行时加载"而不是打进 assets
///
/// 用户可能想用苹方、思源、系统里某个好看的黑体 —— 这些都是**有版权的
/// 第三方字体**，不能随仓库分发；而且 Flutter 不支持"可选字体资源"，
/// 声明了却找不到文件就是构建错误，等于让每个克隆仓库的人自己准备一份。
///
/// 所以改成运行时从文件加载：
///  · 字体文件永远不进仓库，没有许可问题；
///  · 想换成任何别的字体都不用改代码、不用重新构建；
///  · 仓库里没有它，别人照样能构建。
///
/// 代价是：字体只对**本机这一份安装**生效，换设备要重新选一次。
/// 那个路径记在 `SharedPreferences` 里，所以同一台设备升级应用不会丢。
///
/// ## 三个槽位
///
/// 英文（界面/正文）、中文、代码各有一个独立槽位。家族名是固定的
/// （[latinFamily] / [cjkFamily] / [codeFamily]），所以设置里换文件时
/// 全项目几十处 `TextStyle` 引用的家族名不用跟着变。
class CustomFont {
  CustomFont._();

  /// 三个槽位。字符串是存入 `Settings` 的稳定 key。
  static const String latin = 'latin';
  static const String cjk = 'cjk';
  static const String code = 'code';

  static const List<String> slots = <String>[latin, cjk, code];

  /// 每个槽位注册到引擎时用的家族名。
  static const Map<String, String> families = <String, String>{
    latin: 'UserFontLatin',
    cjk: 'UserFontCjk',
    code: 'UserFontCode',
  };

  static String familyOf(String slot) => families[slot] ?? families[latin]!;

  static final Map<String, String> _paths = <String, String>{};
  static final Map<String, String> _names = <String, String>{};
  static final Map<String, String> _errors = <String, String>{};

  /// 当前生效的字体文件路径；空 = 该槽位没加载
  static String pathOf(String slot) => _paths[slot] ?? '';

  /// 文件名（设置页显示"当前用的是哪个文件"）
  static String nameOf(String slot) => _names[slot] ?? '';

  /// 上一次加载失败的原因；空 = 没失败过
  static String errorOf(String slot) => _errors[slot] ?? '';

  static bool loaded(String slot) => _paths.containsKey(slot);

  /// 从文件加载并注册。
  ///
  /// 返回 null 表示成功；否则返回一句给用户看的错误说明
  /// （直接显示在设置里，不写日志 —— 用户看不到日志）。
  static Future<String?> loadFrom(String slot, String filePath) async {
    _errors.remove(slot);
    final String path = filePath.trim();
    if (path.isEmpty) {
      clear(slot);
      return null;
    }
    try {
      final File f = File(path);
      if (!await f.exists()) {
        return _errors[slot] = '文件不存在：$path';
      }

      final Uint8List bytes = await f.readAsBytes();
      if (bytes.length < 4) {
        return _errors[slot] = '文件太小，不像字体';
      }

      // 校验 sfnt 魔数。
      //
      // 挡住最常见的错误：**选错了文件**（选到字体文件夹里的 README、
      // 选到压缩包）。不挡的话 FontLoader 会抛一个底层异常，
      // 用户看到的是"加载失败"却说不出为什么。
      if (!_looksLikeFont(bytes)) {
        return _errors[slot] = '这不像是字体文件（文件头不对）。要选 .ttf / .otf';
      }

      final String family = familyOf(slot);
      final FontLoader loader = FontLoader(family);
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();

      _paths[slot] = path;
      _names[slot] = path.split(RegExp(r'[/\\]')).last;
      return null;
    } catch (e) {
      // .ttc 是"字体集合"（一个文件装多个字重），Flutter 对它的支持不确定。
      // 把原文带出来，用户才知道下一步该干什么。
      return _errors[slot] =
          '加载失败：$e\n'
          '如果这是 .ttc 集合文件，请先抽成单个 .ttf 再导入';
    }
  }

  static void clear(String slot) {
    _paths.remove(slot);
    _names.remove(slot);
    _errors.remove(slot);
  }

  /// sfnt 魔数：`0x00010000`（TrueType）、`OTTO`（CFF/OpenType）、
  /// `true`、`ttcf`（TrueType 集合，也就是 .ttc）。
  static bool _looksLikeFont(Uint8List b) {
    if (b.length < 4) return false;
    if (b[0] == 0x00 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00) {
      return true;
    }
    final String tag = String.fromCharCodes(<int>[b[0], b[1], b[2], b[3]]);
    return tag == 'OTTO' || tag == 'true' || tag == 'ttcf';
  }
}
