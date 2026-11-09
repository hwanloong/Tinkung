// 测试用的 PluginStore。
//
// ## 为什么要有这个文件
//
// `ToolContext` 现在带一个 `plugins`（给 `plugin` 工具读写自定义插件用），
// 于是每个构造 ToolContext 的测试都得给一个值。
//
// 每个测试各写一个 `PluginStore(File(...))` 会有两个问题：
//  1. 路径各写各的，容易撞到同一个临时文件（并行跑测试时互相覆盖）；
//  2. 忘了加 `dart:io` / `plugin.dart` 的 import。
//
// 所以集中在这里：一个函数，路径带随机后缀，谁用谁调。
import 'dart:io';

import 'package:dsh_agent/plugins/plugin.dart';

/// 一个**独立的、空的**插件仓库，落在系统临时目录。
///
/// 不真的 `load()`：测试里关心的只是"能构造出来、能读写内存里的列表"，
/// 落盘行为由插件自己的测试覆盖。
PluginStore testPluginStore() {
  final String tag = DateTime.now().microsecondsSinceEpoch.toString();
  return PluginStore(
    File('${Directory.systemTemp.path}/dsh_test_plugins_$tag.json'),
  );
}
