// 工具调用纪律：默认只用联网，其它工具非必要不调。
//
// 这条规则是用户明确要求的：不要为了“探索一下环境/可能有用”就去跑
// shell、Python、文件操作或手机控制。
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
    tmp = await Directory.systemTemp.createTemp('dsh_prompt');
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

  test('system prompt 明确限制非联网工具', () {
    final String p = buildSystemPrompt(shizukuReady: true);
    expect(p, contains('默认只联网'));
    expect(p, contains('不到非用不可'));
    expect(p, contains('不要为了'));
    expect(p, contains('能直接回答或用联网解决'));
  });
}
