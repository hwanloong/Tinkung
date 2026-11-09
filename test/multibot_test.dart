// multibot（子智能体派发）的边界行为。
//
// 真正起子 AgentRunner 要网络和模型，单测里不碰。这里只测工具自己的契约：
//  1. 没有派发回调（子智能体自己）→ 拒绝套娃，给一句能照着做的话；
//  2. 参数校验：空数组、没有 task 的项被丢弃、超过 8 个被拒；
//  3. 派发结果按**原始顺序**回填，成功/失败都写清楚；
//  4. 标签缺省时给一个可读的名字。
import 'dart:io';

import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/productivity.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:dsh_agent/plugins/plugin.dart';
import 'package:dsh_agent/shizuku/shizuku_service.dart';
import 'package:dsh_agent/tools/multibot_tool.dart';
import 'package:dsh_agent/tools/tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ToolContext _ctx({
  Future<List<SubAgentResult>> Function(List<SubAgentSpec>)? dispatch,
}) {
  return ToolContext(
    settings: _s,
    shizuku: ShizukuService(),
    conversation: Conversation(id: 'c1', title: '测试'),
    workDir: '/tmp/dsh-test',
    searchApiKey: '',
    visionBaseUrl: '',
    visionApiKey: '',
    visionModel: '',
    mainApiKey: '',
    mainBaseUrl: '',
    mainModel: '',
    modelSeesImages: false,
    modelGeneratesImages: false,
    imageGen: null,
    searchEngine: 'bing',
    webSearchMode: 'auto',
    selfHostedSearchUrl: '',
    notes: NoteStore(_fileIn('notes')),
    tasks: TaskStore(_fileIn('tasks')),
    plugins: PluginStore(_fileIn('plugins')),
    dispatchSubAgents: dispatch,
  );
}

late Settings _s;

// 只为满足构造函数；测试里不读写这些文件。
File _fileIn(String name) =>
    File('${Directory.systemTemp.path}/multibot_test_$name.json');

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _s = await Settings.load();
  });

  test('没有派发回调（子智能体自己）→ 拒绝套娃，不派任何东西', () async {
    final String r = await const MultibotTool().run(
      _ctx(),
      <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          <String, dynamic>{'task': '随便做点什么'},
        ],
      },
    );
    expect(r, startsWith('错误：子智能体不能再派子智能体'));
  });

  test('空数组被拒', () async {
    final String r = await const MultibotTool().run(
      _ctx(dispatch: (_) async => <SubAgentResult>[]),
      <String, dynamic>{'tasks': <dynamic>[]},
    );
    expect(r, startsWith('错误：tasks 需要是非空数组'));
  });

  test('没有 task 的项被丢弃；全被丢掉就报错', () async {
    final String r = await const MultibotTool().run(
      _ctx(dispatch: (_) async => <SubAgentResult>[]),
      <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          <String, dynamic>{'label': '只有名字没有任务'},
          <String, dynamic>{'task': '   '},
        ],
      },
    );
    expect(r, startsWith('错误：没有一条带 task 的合法子任务'));
  });

  test('一次超过 8 个被拒，并且不会真的派出去', () async {
    bool called = false;
    final String r = await const MultibotTool().run(
      _ctx(
        dispatch: (_) async {
          called = true;
          return <SubAgentResult>[];
        },
      ),
      <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          for (int i = 0; i < 9; i++) <String, dynamic>{'task': '事情 $i'},
        ],
      },
    );
    expect(r, contains('最多派 8 个'));
    expect(called, isFalse, reason: '超限必须在派发之前拦下');
  });

  test('结果按派出的原始顺序回填，成功与失败都写清楚', () async {
    late List<SubAgentSpec> seen;
    final String r = await const MultibotTool().run(
      _ctx(
        dispatch: (List<SubAgentSpec> specs) async {
          seen = specs;
          return <SubAgentResult>[
            const SubAgentResult(label: 'A', ok: true, answer: '价格是 10'),
            const SubAgentResult(
              label: 'B',
              ok: false,
              answer: '',
              error: '网络超时',
            ),
          ];
        },
      ),
      <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          <String, dynamic>{'label': 'A', 'task': '查 A'},
          <String, dynamic>{'label': 'B', 'task': '查 B'},
        ],
      },
    );

    expect(seen.map((SubAgentSpec s) => s.label), <String>['A', 'B']);
    expect(seen.map((SubAgentSpec s) => s.task), <String>['查 A', '查 B']);

    final int ia = r.indexOf('## ✓ A');
    final int ib = r.indexOf('## ✗ B');
    expect(ia, greaterThan(-1));
    expect(ib, greaterThan(ia), reason: '回填顺序必须和派出顺序一致');
    expect(r, contains('价格是 10'));
    expect(r, contains('网络超时'));
    expect(r, contains('完成 1 个'));
  });

  test('标签缺省时给一个可读的名字（子任务1、子任务2…）', () async {
    late List<SubAgentSpec> seen;
    await const MultibotTool().run(
      _ctx(
        dispatch: (List<SubAgentSpec> specs) async {
          seen = specs;
          return specs
              .map(
                (SubAgentSpec s) =>
                    SubAgentResult(label: s.label, ok: true, answer: 'ok'),
              )
              .toList();
        },
      ),
      <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          <String, dynamic>{'task': '第一件'},
          <String, dynamic>{'task': '第二件'},
        ],
      },
    );
    expect(seen.map((SubAgentSpec s) => s.label), <String>['子任务1', '子任务2']);
  });
}
