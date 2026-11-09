// 内置免费档与模型管理工具。
//
// 这两件事必须钉住：
//  1. 第一次启动就应该有能直接用的模型，而不是空列表；
//  2. 免费档的**工具白名单**真的把 shell / Termux 排除在外。
import 'dart:io';

import 'package:dsh_agent/core/model_profile.dart';
import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/productivity.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:dsh_agent/shizuku/shizuku_service.dart';
import 'package:dsh_agent/tools/model_tool.dart';
import 'package:dsh_agent/tools/tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_plugins.dart';

ToolContext _ctx(Settings s) => ToolContext(
  settings: s,
  shizuku: ShizukuService(),
  conversation: Conversation(id: 'c1', title: '测试'),
  workDir: Directory.systemTemp.path,
  searchApiKey: '',
  visionBaseUrl: '',
  visionApiKey: '',
  visionModel: '',
  mainApiKey: s.apiKey,
  mainBaseUrl: s.baseUrl,
  mainModel: s.model,
  modelSeesImages: false,
  modelGeneratesImages: false,
  imageGen: null,
  searchEngine: 'bing',
  webSearchMode: 'auto',
  selfHostedSearchUrl: '',
  notes: NoteStore(File('${Directory.systemTemp.path}/mm_notes_test.json')),
  tasks: TaskStore(File('${Directory.systemTemp.path}/mm_tasks_test.json')),
  plugins: testPluginStore(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('空存档自动建一个免费模型，工具**不再有白名单**', () async {
    final Settings s = await Settings.load();
    expect(s.profiles, hasLength(1));
    final ModelProfile p = s.activeProfile!;
    expect(p.builtinFree, isTrue);
    expect(p.usable, isTrue, reason: '免费档必须有公开凭据才叫开箱即用');
    expect(s.configured, isTrue);
    expect(p.toolAllowlist, isNull, reason: 'null = 不限制；免费档和自建档在工具能力上应该一致');
    expect(s.allowsTool('web'), isTrue);
    expect(s.allowsTool('python'), isTrue);
    expect(s.allowsTool('model_manager'), isTrue);
    // 这两条原本是 false（免费档被挡在 shell/termux 之外）。
    // 现在放开 —— 该不该执行由"风险确认"那层管，不是按免费与否一刀切。
    expect(s.allowsTool('run_shell'), isTrue);
    expect(s.allowsTool('termux'), isTrue);
  });

  test('老存档里的免费档白名单会在读入时被清掉', () async {
    // 模拟"升级上来的用户"：档案已经存在，且带着旧的白名单。
    final Map<String, Object> old = <String, Object>{
      'modelProfiles': ModelProfile.encodeList(<ModelProfile>[
        ModelProfile(
          id: 'free',
          name: '免费 DeepSeek',
          baseUrl: 'https://example.test/v1',
          apiKey: 'public',
          model: 'free-chat',
          toolAllowlist: kBasicToolAllowlist,
          builtinFree: true,
        ),
      ]),
      'activeProfileId': 'free',
    };
    SharedPreferences.setMockInitialValues(old);

    final Settings s = await Settings.load();
    expect(
      s.activeProfile!.toolAllowlist,
      isNull,
      reason: '只改新建档案而不迁移，老用户升级后限制还在',
    );
    expect(s.allowsTool('run_shell'), isTrue);
  });

  test('自建档案的白名单不会被顺手抹掉', () async {
    final Map<String, Object> mine = <String, Object>{
      'modelProfiles': ModelProfile.encodeList(<ModelProfile>[
        ModelProfile(
          id: 'mine',
          name: '我自己的',
          baseUrl: 'https://example.test/v1',
          apiKey: 'sk-x',
          model: 'm',
          // 用户**主动**设的白名单
          toolAllowlist: <String>['web'],
        ),
      ]),
      'activeProfileId': 'mine',
    };
    SharedPreferences.setMockInitialValues(mine);

    final Settings s = await Settings.load();
    expect(s.activeProfile!.toolAllowlist, <String>['web']);
    expect(s.allowsTool('run_shell'), isFalse);
  });

  test('模型工具能添加、切换、调思考深度，并拒绝删除内置免费档', () async {
    final Settings s = await Settings.load();
    final ToolContext ctx = _ctx(s);
    const ModelManagerTool tool = ModelManagerTool();

    final String added = await tool.run(ctx, <String, dynamic>{
      'action': 'add',
      'name': '测试模型',
      'base_url': 'https://example.test/v1',
      'api_key': 'sk-test',
      'model': 'test-chat',
      'basic_tools': true,
      'activate': true,
    });
    expect(added, contains('OK'));
    expect(s.profiles, hasLength(2));
    expect(s.activeProfile!.name, '测试模型');
    expect(s.activeProfile!.basicToolsOnly, isTrue);

    final String switched = await tool.run(ctx, <String, dynamic>{
      'action': 'switch',
      'name': '免费 DeepSeek',
    });
    expect(switched, contains('OK'));
    expect(s.activeProfile!.builtinFree, isTrue);

    final String thinking = await tool.run(ctx, <String, dynamic>{
      'action': 'set_thinking',
      'id': s.activeProfile!.id,
      'thinking': false,
      'effort': 'low',
    });
    expect(thinking, contains('OK'));
    expect(s.activeProfile!.thinking, isFalse);
    expect(s.activeProfile!.reasoningEffort, 'low');

    final String refused = await tool.run(ctx, <String, dynamic>{
      'action': 'delete',
      'id': s.activeProfile!.id,
    });
    expect(refused, contains('不能删除'));
    expect(s.profiles, hasLength(2));
  });

  test('列表不回显 API Key', () async {
    final Settings s = await Settings.load();
    await s.update(() {
      s.addProfile(
        ModelProfile(
          id: 'secret',
          name: 'secret-model',
          baseUrl: 'https://example.test/v1',
          apiKey: 'sk-super-secret',
          model: 'm',
        ),
        activate: false,
      );
    });
    const ModelManagerTool tool = ModelManagerTool();
    final String out = await tool.run(_ctx(s), <String, dynamic>{
      'action': 'list',
    });
    expect(out, contains('secret-model'));
    expect(out, isNot(contains('sk-super-secret')));
  });
}
