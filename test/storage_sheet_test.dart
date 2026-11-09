import 'dart:io';

import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/ui/storage_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 存储页「文件清单」的界面测试。
///
/// 为什么要走到点击这一层：这个功能的**全部价值**就是"我勾了几个，
/// 点一下，它们真的没了"。逻辑单测（storage_files_test.dart）只能证明
/// 底层函数对，证明不了"勾选状态跟得上、按钮真的调到了那个函数"——
/// 勾选是最容易写成"看着选中了其实没进集合"的一层。
void main() {
  /// 等真实磁盘 I/O 跑完，再把结果渲染出来。
  ///
  /// 为什么要来回搓一串 pump / runAsync，而不是一次 runAsync + 一次 pump：
  ///  `testWidgets` 的函数体跑在 fake async 时区里，磁盘回调只在
  ///  **runAsync 期间**才轮得到真实事件循环去执行，而它续上的那一段又排在
  ///  fake 时区里、要下一次 pump 才推得动。扫描本身是**多步**的
  /// （列目录 → 取大小 → 取修改时间，每一步一个 await），一次一对只往前走
  /// 一步，所以得交替推进直到界面把数据渲染出来。
  /// （这个坑 ui_preview_test.dart 里也记了一笔。）
  Future<void> io(WidgetTester tester) async {
    for (int i = 0; i < 12; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    // 顺手把 sheet 的进出场动画推完
    // （玻璃控件有常驻动画，pumpAndSettle 会一直超时）。
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> bootSheet(WidgetTester tester, String workDir) async {
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        child: MaterialApp(
          theme: AppTheme.light(),
          // 和 main.dart 一致：玻璃包是 Material-free 的，
          // 不垫这层透明 Material，文字会出现黄色下划线。
          builder: (BuildContext c, Widget? child) => Material(
            type: MaterialType.transparency,
            child: child ?? const SizedBox.shrink(),
          ),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => Center(
                child: TextButton(
                  onPressed: () => showStorageSheet(ctx, workDir: workDir),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
        brightnessResolver: Theme.maybeBrightnessOf,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await io(tester);
  }

  testWidgets('勾选后批量删除，磁盘上真的少掉那些文件', (WidgetTester tester) async {
    final Directory root = Directory.systemTemp.createTempSync('priv_sheet_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final File a = File('${root.path}${Platform.pathSeparator}shot_a.png')
      ..writeAsBytesSync(List<int>.filled(120, 0));
    File('${root.path}${Platform.pathSeparator}shot_b.png')
        .writeAsBytesSync(List<int>.filled(60, 0));

    await bootSheet(tester, root.path);

    // 存储总览里能看到"文件清单"入口，点进去。
    expect(find.text('文件清单'), findsOneWidget);
    await tester.tap(find.text('文件清单'));
    await io(tester);

    expect(find.text('shot_a.png'), findsOneWidget);
    expect(find.text('shot_b.png'), findsOneWidget);
    // 两处都会写这句话：存储总览一行，文件清单的头部一行。
    expect(find.text('共 2 个文件'), findsNWidgets(2));

    // 只勾第一个：选中栏要如实报"1 项"，不是"全选"。
    await tester.tap(find.text('shot_a.png'));
    await tester.pump();
    expect(find.textContaining('已选 1 项'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    // 确认对话框出现，且说的是 1 项。
    expect(find.textContaining('删除所选的 1 项'), findsOneWidget);

    // 选中栏和对话框里各有一个「删除」，要明确点对话框里那个。
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')),
    );
    await io(tester);

    expect(a.existsSync(), isFalse, reason: '勾选的文件必须真的从磁盘上消失');
    expect(
      File('${root.path}${Platform.pathSeparator}shot_b.png').existsSync(),
      isTrue,
      reason: '没勾的文件一个都不能碰',
    );
    // 列表刷新后只剩没勾的那个，选中状态清空。
    expect(find.text('shot_a.png'), findsNothing);
    expect(find.text('shot_b.png'), findsOneWidget);
    expect(find.textContaining('已选'), findsNothing);
  });

  testWidgets('全选后取消全选，选中栏跟着出现和消失', (WidgetTester tester) async {
    final Directory root = Directory.systemTemp.createTempSync('priv_sheet_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    for (int i = 0; i < 3; i++) {
      File('${root.path}${Platform.pathSeparator}shot_$i.png')
          .writeAsBytesSync(List<int>.filled(10, 0));
    }

    await bootSheet(tester, root.path);
    await tester.tap(find.text('文件清单'));
    await io(tester);

    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(find.textContaining('已选 3 项'), findsOneWidget);

    // 全选之后再点一次就是取消 —— 按钮文案必须跟着变，否则用户不知道
    // 自己点的是"全选"还是"反选"。
    await tester.tap(find.text('取消全选'));
    await tester.pump();
    expect(find.textContaining('已选'), findsNothing);
  });
}
