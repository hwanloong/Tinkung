// 模型列表的显示规则。
//
// 测这两件事：
//  1. **备注**要出现在选择列表里（用户加备注就是为了在选择时看见它）；
//  2. 没有备注时回退到技术信息（模型名 + 主机），而不是留一行空白。
//
// 为什么要测"显示"这种看起来显然的东西：模型条目的副标题有**三种形态**
// （有备注 / 无备注 / 仅生图），而它们是在同一次改动里加进模板字符串的。
// 拼接出错的表现是"列表看起来正常但少了关键提示"——比如"仅生图"
// 那行没了，用户就会拿生图模型去聊天然后撞上服务端报错。
import 'package:dsh_agent/core/model_profile.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_fonts.dart';

import 'package:dsh_agent/ui/models_sheet.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadPreviewFonts();
  });

  Future<Settings> seeded(List<ModelProfile> profiles) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final Settings s = await Settings.load();
    await s.update(() {
      for (final ModelProfile p in profiles) {
        s.addProfile(p, activate: p == profiles.first);
      }
    });
    return s;
  }

  testWidgets('选择模型列表里显示备注', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final Settings s = await seeded(<ModelProfile>[
      ModelProfile(
        id: 'a',
        name: '日常主力',
        note: '便宜，日常问答用',
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-x',
        model: 'deepseek-flash',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModelPicker(ctx, settings: s),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 选择器现在是**一屏**：强度卡在上，模型列表直接可见。
    expect(
      find.text('日常主力'),
      findsOneWidget,
      reason:
          '列表里的模型名必须显示当前模型 —— '
          '不显示的话用户不知道自己在跟谁说话',
    );

    // 备注在列表行里**直接可见**，不用再点一层。
    expect(find.text('便宜，日常问答用'), findsOneWidget, reason: '备注必须出现在选择列表里');
  });

  testWidgets('没有备注时回退到模型名 + 主机，并且标出「仅生图」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final Settings s = await seeded(<ModelProfile>[
      ModelProfile(
        id: 'b',
        name: '',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-x',
        model: 'gpt-image-2',
        chat: false,
        vision: false,
        // 生图现在是工具能力，不再是单独的开关
        tools: <String>[kImageGenTool],
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModelPicker(ctx, settings: s),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 没起名时用模型名当标题，行里直接可见（不再需要点开第二层）
    expect(find.text('gpt-image-2'), findsWidgets);
    // 「仅生图」必须说出来 —— 否则用户会拿它去聊天
    expect(
      find.textContaining('仅生图'),
      findsWidgets,
      reason: '不能对话的模型必须在选择列表里标出来',
    );
  });
}
