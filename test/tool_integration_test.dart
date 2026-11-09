// 文件夹工具与插件这两个工具的**边界行为**。
//
// 它们的共同点是：失败时**不会报错**，只会静默地什么都不做 ——
//  · 建了个 `point` 任务 → 永远不自动跑，用户以为功能坏了；
//  · 插件模板引用了不存在的参数 → 运行时报一个和真正原因无关的错；
//  · 重名插件 → 运行时两个同名工具，模型选哪个全看运气。
//
// 所以这些校验必须在**建的时候就挡掉**，而不是留给运行时。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_agent/core/folder_tool.dart';
import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/productivity.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:dsh_agent/shizuku/shizuku_service.dart';
import 'package:dsh_agent/tools/folder_tool_tool.dart';
import 'package:dsh_agent/tools/plugin_tool.dart';
import 'package:dsh_agent/tools/tool.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_plugins.dart';

ToolContext _ctx(Settings settings) => ToolContext(
  settings: settings,
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
  webSearchMode: 'builtin',
  selfHostedSearchUrl: '',
  notes: NoteStore(File('${Directory.systemTemp.path}/n_ti_test.json')),
  tasks: TaskStore(File('${Directory.systemTemp.path}/t_ti_test.json')),
  plugins: testPluginStore(),
);

late Settings _s;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _s = await Settings.load();
  });

  group('插件工具的校验', () {
    test('name 必须是合法标识符', () async {
      final String r = await const PluginManageTool().run(
        _ctx(_s),
        <String, dynamic>{
          'action': 'create',
          'name': '查天气', // 中文不是合法标识符
          'template': 'echo hi',
        },
      );
      expect(r, contains('失败'));
      expect(r, contains('标识符'));
    });

    test('重名会被拒', () async {
      final ToolContext ctx = _ctx(_s);
      await const PluginManageTool().run(ctx, <String, dynamic>{
        'action': 'create',
        'name': 'get_x',
        'template': 'echo hi',
      });
      final String r = await const PluginManageTool().run(
        ctx,
        <String, dynamic>{
          'action': 'create',
          'name': 'get_x',
          'template': 'echo hi',
        },
      );
      expect(r, contains('已经有'));
    });

    test('模板引用了不存在的参数会被拒', () async {
      // 不挡的话运行时会带着字面量 {{key}} 去执行，报错和真正原因无关
      final String r = await const PluginManageTool().run(
        _ctx(_s),
        <String, dynamic>{
          'action': 'create',
          'name': 'get_prop',
          'template': 'getprop {{key}}',
          'params': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'other'},
          ],
        },
      );
      expect(r, contains('{{key}}'));
    });

    test('模板和参数对得上就能建成，并且说明"下一轮才生效"', () async {
      final String r = await const PluginManageTool().run(
        _ctx(_s),
        <String, dynamic>{
          'action': 'create',
          'name': 'get_prop',
          'title': '读属性',
          'kind': 'shell',
          'template': 'getprop {{key}}',
          'params': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'key', 'description': '属性名'},
          ],
        },
      );
      expect(r, contains('已创建'));
      // 必须明确告诉模型"这一轮还调不了"，否则它会在同一轮里反复试
      expect(r, contains('下一轮'));
    });

    test('list 在空仓库时给出可执行的建议', () async {
      final String r = await const PluginManageTool().run(
        _ctx(_s),
        <String, dynamic>{'action': 'list'},
      );
      expect(r, contains('create'));
    });
  });

  // ------------------------------------------------------------------
  // agent 侧的 import_file
  //
  // 模型想给工具加个脚本/图片时，`write` 只能写文本，所以有了这条路。
  // 它的失败方式和别的工具不同：**写错了也不会报错**，只会得到一个
  // 内容不对的文件（比如 base64 少了一半），而模型以为自己成功了。
  // ------------------------------------------------------------------
  group('tool 工具的 import_file', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('dsh_imp_agent_');
      await FolderToolStore.instance.configure(root);
      final Directory d = Directory('${root.path}/demo')..createSync();
      File('${d.path}/tool.md').writeAsStringSync('---\ntitle: 演示\n---\n步骤\n');
      await FolderToolStore.instance.load();
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    File file(String name) => File('${root.path}/demo/$name');

    test('base64 导入成功，字节一致，回执里有大小', () async {
      final Uint8List bytes = Uint8List.fromList(<int>[
        0x23,
        0x21,
        0x2f,
        0x62,
        0x69,
        0x6e,
      ]);
      final String r = await const FolderToolTool().run(
        _ctx(_s),
        <String, dynamic>{
          'action': 'import_file',
          'name': 'demo',
          'file': 'scripts/run.sh',
          'base64': base64Encode(bytes),
        },
      );
      expect(r, contains('已导入'));
      expect(r, contains('6 B'));
      expect(file('scripts/run.sh').readAsBytesSync(), bytes);
    });

    test('data: 前缀和换行都能处理（模型常这么贴）', () async {
      final String b64 = base64Encode(utf8.encode('echo hi\n'));
      final String wrapped =
          'data:application/octet-stream;base64,${b64.substring(0, 4)}\n${b64.substring(4)}';
      final String r = await const FolderToolTool().run(
        _ctx(_s),
        <String, dynamic>{
          'action': 'import_file',
          'name': 'demo',
          'file': 'hi.sh',
          'base64': wrapped,
        },
      );
      expect(r, contains('已导入'));
      expect(file('hi.sh').readAsStringSync(), 'echo hi\n');
    });

    test('非法 base64 明确报错，不留下空文件', () async {
      final String r = await const FolderToolTool().run(
        _ctx(_s),
        <String, dynamic>{
          'action': 'import_file',
          'name': 'demo',
          'file': 'bad.bin',
          'base64': '这不是 base64',
        },
      );
      expect(r, contains('base64'));
      expect(file('bad.bin').existsSync(), isFalse);
    });

    test('同名默认被拒；显式 overwrite 才能替换', () async {
      Future<String> imp(String content, {bool? overwrite}) =>
          const FolderToolTool().run(_ctx(_s), <String, dynamic>{
            'action': 'import_file',
            'name': 'demo',
            'file': 'a.txt',
            'base64': base64Encode(utf8.encode(content)),
            'overwrite': ?overwrite,
          });

      expect(await imp('第一版'), contains('已导入'));
      final String r = await imp('第二版');
      expect(r, contains('已经有'));
      // 拒绝必须真的没覆盖
      expect(file('a.txt').readAsStringSync(), '第一版');

      expect(await imp('第二版', overwrite: true), contains('已导入'));
      expect(file('a.txt').readAsStringSync(), '第二版');
    });

    test('越界的 file 被拒 —— 模型也可能写出 ../', () async {
      final String r = await const FolderToolTool().run(
        _ctx(_s),
        <String, dynamic>{
          'action': 'import_file',
          'name': 'demo',
          'file': '../escape.bin',
          'base64': base64Encode(<int>[1, 2, 3]),
        },
      );
      expect(r, contains('失败'));
      expect(File('${root.path}/escape.bin').existsSync(), isFalse);
    });

    test('导入 tool.icon 时回执要点明"它现在是图标"', () async {
      final String r = await const FolderToolTool().run(
        _ctx(_s),
        <String, dynamic>{
          'action': 'import_file',
          'name': 'demo',
          'file': 'tool.icon',
          'base64': base64Encode(<int>[0x89, 0x50, 0x4E, 0x47]),
        },
      );
      expect(r, contains('图标'));
      expect(FolderToolStore.instance.byId('demo')!.hasIcon, isTrue);
    });

    test('read_file 对二进制给说明，而不是把乱码塞进上下文', () async {
      // 不挡的话模型会读到一屏乱码，还可能据此"修"出更离谱的东西
      file('img.png').writeAsBytesSync(<int>[0x89, 0x50, 0x00, 0xFF, 0x0D]);
      final String r = await const FolderToolTool().run(
        _ctx(_s),
        <String, dynamic>{
          'action': 'read_file',
          'name': 'demo',
          'file': 'img.png',
        },
      );
      expect(r, contains('非文本'));
      // 乱码没有进到返回值里
      expect(r.contains('\u0000'), isFalse);
    });
  });
}
