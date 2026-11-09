// 使用模式（学生 / 日常 / 程序员）要真的改变系统提示词。
//
// 为什么值得单独测：模式选择页只是**写一个字符串**，真正让它生效的是
// `buildSystemPrompt` 里那一段。如果那段的 switch 写错（比如 student
// 落进 default），用户选完会觉得"选了个寂寞" —— 而界面上看不出任何异常。
import 'dart:io';

import 'package:dsh_agent/ai/agent.dart';
import 'package:dsh_agent/core/folder_tool.dart';
import 'package:dsh_agent/core/learning.dart';
import 'package:dsh_agent/core/memory.dart';
import 'package:dsh_agent/core/rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('dsh_mode');
    await MemoryStore.configure(File('${tmp.path}/memory.json'));
    await RuleStore.configure(File('${tmp.path}/rules.json'));
    await LearningStore.configure(File('${tmp.path}/learning.json'));
    await FolderToolStore.instance.configure(Directory('${tmp.path}/tools'));
  });

  tearDownAll(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('学生模式：要求先解释、分步、用图', () {
    final String p = buildSystemPrompt(
      shizukuReady: true,
      assistantMode: 'student',
    );
    expect(p, contains('学生模式'));
    expect(p, contains('分步'));
    expect(p, contains('mermaid'), reason: '学生模式要偏好可视化');
  });

  test('程序员模式：代码优先、直接动手', () {
    final String p = buildSystemPrompt(
      shizukuReady: true,
      assistantMode: 'programmer',
    );
    expect(p, contains('程序员模式'));
    expect(p, contains('代码'));
    expect(p, contains('直接动手'));
  });

  test('日常模式与未知值都是简洁优先（未知回退到日常）', () {
    final String daily = buildSystemPrompt(
      shizukuReady: true,
      assistantMode: 'daily',
    );
    final String unknown = buildSystemPrompt(
      shizukuReady: true,
      assistantMode: 'whatever',
    );
    expect(daily, contains('日常模式'));
    expect(unknown, contains('日常模式'));
  });

  test('三种模式产出的提示词互不相同', () {
    final Set<String> seen = <String>{
      buildSystemPrompt(shizukuReady: true, assistantMode: 'student'),
      buildSystemPrompt(shizukuReady: true, assistantMode: 'daily'),
      buildSystemPrompt(shizukuReady: true, assistantMode: 'programmer'),
    };
    expect(seen.length, 3);
  });

  test('文件硬规则始终在提示词里（不随模式消失）', () {
    for (final String mode in <String>['student', 'daily', 'programmer']) {
      final String p = buildSystemPrompt(
        shizukuReady: true,
        assistantMode: mode,
      );
      expect(p, contains('改文件之前，必须先读过它'), reason: mode);
      expect(p, contains('old` 必须是原文逐字'), reason: mode);
    }
  });
}
