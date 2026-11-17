// 字体设置页的冒烟测试：能打开、能选中、选中值真的写回设置。
import 'package:dsh_agent/core/store.dart';
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/ui/font_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('页面打开、三组字体都在、选中写回设置', (WidgetTester tester) async {
    // 页面比默认测试窗口长：把窗口调高，让三组选项都真的被 build 出来
    // （ListView 是懒构建的，屏幕外的行根本不存在，find 也找不到）。
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final Settings settings = await Settings.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: FontSettingsPage(settings: settings),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('英文字体'), findsOneWidget);
    expect(find.text('中文字体'), findsOneWidget);
    expect(find.text('代码字体'), findsOneWidget);
    expect(find.text('字号'), findsOneWidget);
    // 默认值：Inter / 跟随系统 / 系统等宽
    expect(settings.fontLatin, 'inter');
    expect(settings.fontCjk, 'system');
    expect(settings.fontCode, 'monospace');

    await tester.tap(find.text('系统衬线').first);
    await tester.pumpAndSettle();
    expect(settings.fontLatin, 'serif');

    await tester.tap(find.text('宋体 / 衬线'));
    await tester.pumpAndSettle();
    expect(settings.fontCjk, 'serif');

    // 代码字体那一组里也有"系统衬线"，所以取最后一个
    await tester.tap(find.text('系统等宽').last);
    await tester.pumpAndSettle();
    expect(settings.fontCode, 'monospace');
  });

  testWidgets('字号滑杆写回设置', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final Settings settings = await Settings.load();
    settings.fontScale = 0.85;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: FontSettingsPage(settings: settings),
      ),
    );
    await tester.pumpAndSettle();

    final Finder slider = find.byType(Slider).first;
    await tester.drag(slider, const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(settings.fontScale, greaterThan(0.85));
  });
}
