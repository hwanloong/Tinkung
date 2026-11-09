// 跨聊天记忆：只读检索其他对话。
//
// 这里钉住四件事：
//  1. 搜索能跨对话命中，并**排除当前对话**；
//  2. 按 id / 标题都能定位到对话，按消息下标能只读一段；
//  3. 提示词里的索引只放"最近几条 + 最后一句话"，不塞全文；
//  4. 工具层的输出带得上 id 和下标，模型能据此继续 read。
import 'dart:convert';
import 'dart:io';

import 'package:dsh_agent/core/chat_recall.dart';
import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/productivity.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:dsh_agent/shizuku/shizuku_service.dart';
import 'package:dsh_agent/tools/chat_recall_tool.dart';
import 'package:dsh_agent/tools/tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_plugins.dart';

ChatMessage _msg(String id, Role role, String text) =>
    ChatMessage(id: id, role: role, content: text);

Conversation _conv(
  String id,
  String title,
  DateTime at,
  List<ChatMessage> messages,
) => Conversation(id: id, title: title, messages: messages, updatedAt: at);

ToolContext _ctx(Settings s, String convId) => ToolContext(
  settings: s,
  shizuku: ShizukuService(),
  conversation: Conversation(id: convId, title: '当前对话'),
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
  notes: NoteStore(File('${Directory.systemTemp.path}/cr_notes.json')),
  tasks: TaskStore(File('${Directory.systemTemp.path}/cr_tasks.json')),
  plugins: testPluginStore(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File file;

  final Conversation deploy = _conv(
    'c1',
    '部署方案讨论',
    DateTime(2026, 11, 5, 10, 30),
    <ChatMessage>[
      _msg('a1', Role.user, '我们上次说的那个部署方案，用 Docker 还是直接跑二进制？'),
      _msg('a2', Role.assistant, '建议先用 Docker Compose，回滚和日志都好处理。'),
      _msg('a3', Role.user, '那就定 Docker，端口 8080。'),
    ],
  );

  final Conversation cooking = _conv(
    'c2',
    '今晚吃什么',
    DateTime(2026, 11, 6, 9, 0),
    <ChatMessage>[
      _msg('b1', Role.user, '今晚想吃面。'),
      _msg('b2', Role.assistant, '那就做番茄鸡蛋面。'),
    ],
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = await Directory.systemTemp.createTemp('chat_recall_test');
    file = File('${dir.path}/conversations.json');
    await file.writeAsString(
      jsonEncode(<Map<String, dynamic>>[deploy.toJson(), cooking.toJson()]),
    );
    await ChatArchive.configure(file);
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('搜索跨对话命中，排除当前对话', () async {
    final ChatArchive archive = ChatArchive.instance;
    final List<ChatRecallHit> hits = await archive.search(
      '部署',
      excludeId: 'c2',
    );
    expect(hits, isNotEmpty);
    expect(hits.first.conversationId, 'c1');
    expect(hits.first.messageIndex, 0);
    expect(hits.first.snippet, contains('部署'));
    // 当前对话（c2）里没有"部署"，排除逻辑本身不会误伤。
    final List<ChatRecallHit> none = await archive.search(
      '番茄',
      excludeId: 'c2',
    );
    expect(none, isEmpty, reason: '当前对话不参与跨聊天检索');
  });

  test('按 id / 标题找对话，按范围读一段', () async {
    final ChatArchive archive = ChatArchive.instance;

    final Conversation? byId = await archive.find('c1');
    expect(byId?.title, '部署方案讨论');

    final Conversation? byTitle = await archive.find('部署');
    expect(byTitle?.id, 'c1');

    final String all = archive.render(byId!);
    expect(all, contains('用户：'));
    expect(all, contains('Docker'));
    expect(all, contains('共 3 条'));

    final String one = archive.render(byId, from: 1, to: 1);
    expect(one, contains('建议先用 Docker Compose'));
    expect(one, isNot(contains('今晚想吃面')));
    expect(one, contains('本次显示第 1–1 条'));
  });

  test('提示词索引：最近几条 + 最后一句话，不塞全文', () async {
    final ChatArchive archive = ChatArchive.instance;
    final String section = await archive.promptSection(excludeId: 'c2');

    expect(section, contains('跨聊天记忆'));
    expect(section, contains('部署方案讨论'));
    expect(section, contains('id=c1'));
    expect(section, contains('用户说：'));
    expect(section, isNot(contains('今晚吃什么')));
    // 只有最后一句，不是整段对话。
    expect(section, isNot(contains('回滚和日志都好处理')));

    expect(
      await archive.promptSection(excludeId: 'c2', enabled: false),
      isEmpty,
    );
  });

  test('recall 工具：search 给出 id 和下标，read 能接着读', () async {
    final Settings settings = await Settings.load();
    final ToolContext ctx = _ctx(settings, 'c2');
    const ChatRecallTool tool = ChatRecallTool();

    final String searched = await tool.run(ctx, <String, dynamic>{
      'action': 'search',
      'query': 'Docker',
    });
    expect(searched, contains('部署方案讨论'));
    expect(searched, contains('id=c1'));
    expect(searched, contains('第 1 条'));

    final String read = await tool.run(ctx, <String, dynamic>{
      'action': 'read',
      'id': 'c1',
      'from': 0,
      'to': 1,
    });
    expect(read, contains('我们上次说的那个部署方案'));
    expect(read, contains('建议先用 Docker Compose'));
    expect(read, isNot(contains('今晚想吃面')));

    final String listed = await tool.run(ctx, <String, dynamic>{
      'action': 'list',
    });
    expect(listed, contains('部署方案讨论'));
    expect(listed, isNot(contains('「当前对话」')));
  });

  test('没有初始化时工具给出可读提示，不抛异常', () async {
    ChatArchive.resetForTest();
    final Settings settings = await Settings.load();
    final ToolContext ctx = _ctx(settings, 'c2');

    final String out = await const ChatRecallTool().run(ctx, <String, dynamic>{
      'action': 'list',
    });
    expect(out, contains('还没有初始化'));
  });
}
