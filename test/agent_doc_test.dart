import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_agent/core/agent_doc.dart';

/// Agent.md 的纯逻辑测试（不碰磁盘）。
void main() {
  setUp(AgentDocStore.resetForTest);

  test('空文档不产生提示词段落', () {
    expect(AgentDocStore.instance.toPromptSection(), '');
    expect(AgentDocStore.instance.isEmpty, isTrue);
  });

  test('写入后注入，并标明最高优先级', () {
    final AgentDocStore s = AgentDocStore.instance;
    expect(s.setText('- 代码写进文件，不要贴在聊天里'), isNull);
    final String section = s.toPromptSection();
    expect(section, contains('最高优先级'));
    expect(section, contains('- 代码写进文件，不要贴在聊天里'));
    // 边界必须写清楚：否则用户会试图用它关掉安全确认
    expect(section, contains('安全机制'));
  });

  test('超过上限被拒绝，原内容不变', () {
    final AgentDocStore s = AgentDocStore.instance;
    s.setText('原文');
    final String tooLong = 'a' * (AgentDocStore.maxChars + 1);
    expect(s.setText(tooLong), isNotNull);
    expect(s.text, '原文');
  });

  test('清空后不再注入', () {
    final AgentDocStore s = AgentDocStore.instance;
    s.setText('x');
    s.setText('');
    expect(s.toPromptSection(), '');
  });
}
