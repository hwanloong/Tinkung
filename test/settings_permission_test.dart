// 「全部放行」和「工具调用不设限」的落盘往返。
//
// 这两个都是**安全相关**的开关，坏掉的方向有两个，而且都不显眼：
//  1. 放行状态没存下来 → 用户点过「全部运行」，下一次调用又开始弹框
//     （只是烦，但用户会以为那个按钮坏了）；
//  2. 不设限的 `0` 在读取时被当成"没配过"、回退成默认的 100 →
//     用户明明打开了不设限，复杂任务还是会被拦腰停住，
//     而模型不会说自己被限制了，只会含糊收尾。
import 'package:dsh_agent/core/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('全部放行默认是关的', () async {
    final Settings s = await Settings.load();
    expect(s.autoApproveAll, isFalse, reason: '默认不能是放行 —— 那等于替用户把确认框全关了');
  });

  test('全部放行能存下来，重启后仍然有效', () async {
    final Settings s = await Settings.load();
    await s.update(() => s.autoApproveAll = true);

    final Settings again = await Settings.load();
    expect(again.autoApproveAll, isTrue, reason: '"永久权限"重启后就失效的话，就别叫永久');

    await again.update(() => again.autoApproveAll = false);
    expect((await Settings.load()).autoApproveAll, isFalse, reason: '也要能关掉');
  });

  test('工具调用次数：0 表示不设限，不能被当成"没配过"回退成 100', () async {
    final Settings s = await Settings.load();
    expect(s.maxToolRounds, Settings.maxToolRoundsCeiling);

    await s.update(() => s.maxToolRounds = 0);
    final Settings again = await Settings.load();
    expect(again.maxToolRounds, 0);
    // 这条断言是这次改动的核心：`<= 0` 必须被读成"不设限"。
    expect(again.maxToolRounds <= 0, isTrue);
  });

  test('老存档里的 8 仍然会被升到新默认（那是旧默认值，不是用户的选择）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'maxToolRounds': 8,
    });
    expect(
      (await Settings.load()).maxToolRounds,
      Settings.maxToolRoundsCeiling,
    );

    // 但用户自己调过的值要留着 —— 覆盖他的选择比不改更糟。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'maxToolRounds': 20,
    });
    expect((await Settings.load()).maxToolRounds, 20);
  });

  test('描述改进的档位/模型/自定义要求都能存下来', () async {
    final Settings s = await Settings.load();
    expect(s.promptImproveLevel, 'medium', reason: '默认档位是中等');

    await s.update(() {
      s.promptImproveLevel = 'high';
      s.promptImproveModel = 'gpt-4o-mini';
      s.promptImproveInstruction = '把所有代词换成具体的名字';
    });

    final Settings again = await Settings.load();
    expect(again.promptImproveLevel, 'high');
    expect(again.promptImproveModel, 'gpt-4o-mini');
    expect(again.promptImproveInstruction, '把所有代词换成具体的名字');
  });

  test('横屏字号单独保存，不改竖屏字号', () async {
    final Settings s = await Settings.load();
    await s.update(() {
      s.fontScale = 1.05;
      s.landscapeFontScale = 0.9;
    });

    final Settings again = await Settings.load();
    expect(again.fontScale, 1.05);
    expect(again.landscapeFontScale, 0.9);
  });
}
