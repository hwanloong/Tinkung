import '../core/chat_recall.dart';
import '../core/models.dart';
import 'tool.dart';

/// 跨对话记忆工具：让模型能**检索其他聊天**里发生过的事。
///
/// ## 为什么单独做一个工具，而不是把历史全塞进提示词
///
/// 用户的历史可能有一年、几百条对话。全塞进去等于每轮都重新读一遍
/// 整个聊天记录：贵、慢，而且大部分内容和当前问题无关。
///
/// 所以分成两层：
///  · 提示词里只放**最近几条对话的索引**（标题 + 最后一句，见
///    `ChatArchive.promptSection`）—— 让模型知道"还有这些事"；
///  · 真需要细节时，模型自己调这个工具去搜、去读 —— 按需付费。
///
/// ## 只读
///
/// 这个工具不提供任何写操作。会话内容属于用户，模型只能看和引用；
/// 要长期记住一条事实，用 `memory` 工具。
class ChatRecallTool extends AgentTool {
  const ChatRecallTool();

  @override
  String get name => 'recall';

  @override
  String get title => '回忆其他对话';

  @override
  String get description =>
      '检索用户**其他对话**里的内容（跨聊天记忆）。只读，不会修改任何对话。\n'
      'action：\n'
      '· list —— 看最近聊过哪些对话（标题、时间、最后一句话）。'
      '用户说"上次那个""之前聊过的"时先看这个。\n'
      '· search —— 按关键词搜所有对话的正文和工具输出，返回命中的片段、'
      '对话 id 和消息下标。\n'
      '· read —— 读某条对话的内容。给 id（list/search 返回的那个）或标题，'
      '可以用 from / to 只看一段。\n'
      '**不要编造其他对话里的内容**：没查过就说不确定，或者先查。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>['list', 'search', 'read'],
        'description': '要做的操作',
      },
      'query': <String, dynamic>{
        'type': 'string',
        'description': 'search 的关键词；read 时也可以用它按标题找对话',
      },
      'id': <String, dynamic>{
        'type': 'string',
        'description': 'read 时的对话 id（list/search 返回的那个）',
      },
      'from': <String, dynamic>{
        'type': 'integer',
        'description': 'read 的起始消息下标（从 0 开始，默认 0）',
      },
      'to': <String, dynamic>{
        'type': 'integer',
        'description': 'read 的结束消息下标（含，默认到最后一条）',
      },
      'limit': <String, dynamic>{
        'type': 'integer',
        'description': 'list / search 最多返回几条（默认 10 / 20）',
      },
      'since_days': <String, dynamic>{
        'type': 'integer',
        'description': 'search 只搜最近 N 天（0 = 不限）',
      },
    },
    'required': <String>['action'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    // 纯读：不改任何对话、不碰文件、不联网。
    return RiskAssessment.safe;
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String a = args.str('action');
    switch (a) {
      case 'search':
        return '搜索其他对话：${args.str('query')}';
      case 'read':
        final String id = args.str('id').trim();
        final String q = args.str('query').trim();
        return '读对话：${id.isNotEmpty ? id : q}';
      default:
        return '看最近的对话';
    }
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final ChatArchive? archive = ChatArchive.maybeInstance;
    if (archive == null) {
      return '跨聊天记忆还没有初始化，暂时读不到其他对话。';
    }
    final String current = ctx.conversation.id;

    switch (args.str('action')) {
      case 'list':
        return _list(archive, current, args);
      case 'search':
        return _search(archive, current, args);
      case 'read':
        return _read(archive, args);
      default:
        return 'BAD_ARG — action 只能是 list / search / read。';
    }
  }

  Future<String> _list(
    ChatArchive archive,
    String current,
    Map<String, dynamic> args,
  ) async {
    final int limit = args.intVal('limit', fallback: 10).clamp(1, 30);
    final List<Conversation> list = await archive.recent(
      excludeId: current,
      limit: limit,
    );
    if (list.isEmpty) return '没有其他对话（当前对话不算）。';

    final StringBuffer sb = StringBuffer();
    sb.writeln('最近的对话（${list.length} 条，当前对话不算）：');
    for (final Conversation c in list) {
      final String title = c.title.trim().isEmpty ? '未命名' : c.title.trim();
      sb.writeln(
        '- 「$title」 · id=${c.id} · ${_ago(c.updatedAt)} · '
        '${c.messages.length} 条',
      );
      final String last = _lastLine(c);
      if (last.isNotEmpty) sb.writeln('  最后：$last');
    }
    sb.writeln('要看某条的内容：action=read id=<那个 id>。');
    return sb.toString();
  }

  Future<String> _search(
    ChatArchive archive,
    String current,
    Map<String, dynamic> args,
  ) async {
    final String q = args.str('query').trim();
    if (q.isEmpty) return 'BAD_ARG — search 需要 query（要搜的关键词）。';
    final int limit = args.intVal('limit', fallback: 20).clamp(1, 50);
    final int days = args.intVal('since_days').clamp(0, 3650);
    final List<ChatRecallHit> hits = await archive.search(
      q,
      excludeId: current,
      limit: limit,
      sinceDays: days,
    );
    if (hits.isEmpty) {
      return '其他对话里没有找到「$q」。可以换个关键词，或先用 list 看有哪些对话。';
    }

    final StringBuffer sb = StringBuffer();
    sb.writeln('在其他对话里找到 ${hits.length} 条「$q」：');
    for (int i = 0; i < hits.length; i++) {
      final ChatRecallHit h = hits[i];
      sb.writeln(
        '${i + 1}. 「${h.title}」 · ${_ago(h.updatedAt)} · '
        'id=${h.conversationId} · 第 ${h.messageIndex} 条 · ${h.role}',
      );
      sb.writeln('   ${h.snippet}');
    }
    sb.writeln('要上下文：action=read id=<id> from=<下标-3> to=<下标+3>。');
    return sb.toString();
  }

  Future<String> _read(ChatArchive archive, Map<String, dynamic> args) async {
    final String id = args.str('id').trim();
    final String q = args.str('query').trim();
    final String key = id.isNotEmpty ? id : q;
    if (key.isEmpty) return 'BAD_ARG — read 需要 id（或 query 按标题找）。';

    final Conversation? c = await archive.find(key);
    if (c == null) {
      return '没有找到对话「$key」。先用 action=list 看可用的 id 和标题。';
    }
    return archive.render(
      c,
      from: args.intVal('from'),
      to: args.containsKey('to') ? args.intVal('to') : -1,
    );
  }

  static String _lastLine(Conversation c) {
    for (int i = c.messages.length - 1; i >= 0; i--) {
      final ChatMessage m = c.messages[i];
      if (m.hidden) continue;
      final String text = m.content.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      final String who = m.role == Role.user ? '用户' : '你';
      final String body = text.length > 90 ? '${text.substring(0, 90)}…' : text;
      return '$who说：$body';
    }
    return '';
  }

  static String _ago(DateTime t) {
    final Duration d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }
}
