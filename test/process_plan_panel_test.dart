// 过程列表 + 底部计划表。
//
// 这两块是"对话正在跑的时候，用户眼睛盯的那一屏"：
//  · `ProcessGroup` 只摊开最近几条工具调用，更早的走「更多历史」；
//  · `PlanTreePanel` 钉在底部，一眼看出哪步做完、哪步在跑、哪步还没动。
//
// 断言的都是**行为**而不是像素：条数上限、状态文案、点击去向。
import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/tools/plan_tool.dart';
import 'package:dsh_agent/ui/plan_tree_panel.dart';
import 'package:dsh_agent/ui/process_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ToolInvocation _inv({
  required String id,
  required String name,
  InvocationStatus status = InvocationStatus.success,
  Map<String, dynamic> args = const <String, dynamic>{},
}) {
  return ToolInvocation(
    id: id,
    name: name,
    argumentsJson: '{}',
    args: args,
    risk: RiskAssessment.safe,
    status: status,
    output: status == InvocationStatus.success ? 'ok' : null,
  );
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  group('过程列表', () {
    testWidgets('只摊开最近几条，其余走「更多历史」', (WidgetTester tester) async {
      int opened = 0;
      final ChatMessage turn = ChatMessage(
        id: 'a1',
        role: Role.assistant,
        content: '',
        tools: <ToolInvocation>[
          _inv(id: 't1', name: 'file_op'),
          _inv(id: 't2', name: 'writer'),
          _inv(id: 't3', name: 'python'),
          _inv(id: 't4', name: 'sheller'),
          _inv(id: 't5', name: 'linux'),
        ],
      );

      await _pump(
        tester,
        ProcessGroup(turns: <ChatMessage>[turn], onMoreHistory: () => opened++),
      );

      // 5 次调用只列 3 条（新的在上面），更早的收进历史。
      expect(find.text('Shell'), findsOneWidget);
      expect(find.text('脚本'), findsOneWidget);
      expect(find.text('python'), findsOneWidget);
      expect(find.text('文件'), findsNothing);
      expect(find.text('改文件'), findsNothing);
      expect(find.text('更多历史'), findsOneWidget);

      // **一列文字只能有一个左边缘**：标题、工具名、底部「更多历史」
      // 虽然有的有图标、有的没有，文字都必须从同一个 x 起排。
      // 用户对这里的像素差非常敏感（"没有对齐，两个文字"）。
      final double x0 = tester.getTopLeft(find.textContaining('工具调用')).dx;
      expect(tester.getTopLeft(find.text('Shell')).dx, moreOrLessEquals(x0));
      expect(tester.getTopLeft(find.text('脚本')).dx, moreOrLessEquals(x0));
      expect(tester.getTopLeft(find.text('更多历史')).dx, moreOrLessEquals(x0));

      // 工具名和参数走**代码字体**：命令、路径、正则按正文排版读起来
      // 是散的（尤其空格和标点），等宽才对得上它原本的样子。
      final Text shell = tester.widget<Text>(find.text('Shell'));
      expect(shell.style?.fontFamily, AppFonts.mono);

      await tester.tap(find.text('更多历史'));
      await tester.pump();
      expect(opened, 1, reason: '「更多历史」应该交给聊天页的弹层，而不是就地展开');
    });

    testWidgets('只有思考、还没有工具调用时不立框', (WidgetTester tester) async {
      final ChatMessage thinking = ChatMessage(
        id: 'a0',
        role: Role.assistant,
        content: '',
      )..pending = true;

      await _pump(
        tester,
        ProcessGroup(turns: <ChatMessage>[thinking], onMoreHistory: () {}),
      );

      // 只有一行"它还活着"，没有框、没有"更多历史"。
      expect(find.textContaining('思考中'), findsOneWidget);
      expect(find.text('更多历史'), findsNothing);
      expect(find.textContaining('正在运行'), findsNothing);
    });

    testWidgets('正在跑的那条进标题，不在列表里重复', (WidgetTester tester) async {
      final ChatMessage turn = ChatMessage(
        id: 'a1',
        role: Role.assistant,
        content: '',
        tools: <ToolInvocation>[
          _inv(id: 't1', name: 'file_op'),
          _inv(
            id: 't2',
            name: 'linux',
            status: InvocationStatus.running,
            args: <String, dynamic>{'command': 'apk add git'},
          ),
        ],
      );

      await _pump(tester, ProcessGroup(turns: <ChatMessage>[turn]));

      expect(find.text('正在运行：Shell'), findsOneWidget);
      // 标题已经有它了，列表里就只该剩下那条已完成的。
      expect(find.text('Shell'), findsNothing);
      expect(find.text('文件'), findsOneWidget);

      // 标题行和工具行共用 [ToolRow]：文字左边缘必须逐像素一致。
      expect(
        tester.getTopLeft(find.text('文件')).dx,
        moreOrLessEquals(tester.getTopLeft(find.text('正在运行：Shell')).dx),
      );
    });

    testWidgets('点标题可以回看完整过程', (WidgetTester tester) async {
      final ChatMessage turn = ChatMessage(
        id: 'a1',
        role: Role.assistant,
        content: '我先把文件读出来。',
        tools: <ToolInvocation>[_inv(id: 't1', name: 'file_op')],
      );

      await _pump(tester, ProcessGroup(turns: <ChatMessage>[turn]));
      expect(find.text('我先把文件读出来。'), findsNothing);

      await tester.tap(find.textContaining('工具调用'));
      await tester.pumpAndSettle();
      expect(find.text('我先把文件读出来。'), findsOneWidget);
    });
  });

  group('底部计划表', () {
    List<PlanNode> nodes() => <PlanNode>[
      PlanNode(id: 'a', title: '读需求', task: '', status: 'done'),
      PlanNode(
        id: 'b',
        title: '改代码',
        task: '',
        status: 'doing',
        after: <String>['a'],
      ),
      PlanNode(
        id: 'c',
        title: '跑测试',
        task: '',
        status: 'todo',
        after: <String>['b'],
      ),
      PlanNode(id: 'd', title: '发布', task: '', status: 'blocked', note: '缺权限'),
    ];

    testWidgets('四个状态各有自己的标签', (WidgetTester tester) async {
      await _pump(tester, PlanTreePanel(nodes: nodes()));

      expect(find.text('plantree'), findsOneWidget);
      expect(find.text('DONE'), findsOneWidget);
      expect(find.text('RUNNING'), findsOneWidget);
      expect(find.text('WAIT'), findsOneWidget);
      expect(find.text('BLOCKED'), findsOneWidget);
      // 表头那行是"做完几个 / 总共几个"。
      expect(find.textContaining('1/4'), findsOneWidget);
      // 还没做完的节点要把依赖写出来，用户才知道为什么它在等。
      expect(find.text('依赖 b'), findsOneWidget);
    });

    testWidgets('收起后只剩表头和进度', (WidgetTester tester) async {
      await _pump(tester, PlanTreePanel(nodes: nodes()));

      await tester.tap(find.text('plantree'));
      await tester.pumpAndSettle();

      expect(find.text('DONE'), findsNothing);
      expect(find.text('读需求'), findsNothing);
      // 卡住的节点即使收起来也要提醒一句。
      expect(find.text('1 个节点卡住了'), findsOneWidget);
    });
  });
}
