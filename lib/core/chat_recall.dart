import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'models.dart';
import 'store.dart';

/// 跨对话检索的一条命中。
///
/// 只带"够定位、够判断要不要继续读"的信息：对话 id / 标题 / 时间，
/// 命中的是第几条消息、谁说的、以及一小段原文。正文不在这里重复存 ——
/// 要细节就让模型再调一次 `read`，这样一次搜索不会把上下文撑爆。
class ChatRecallHit {
  const ChatRecallHit({
    required this.conversationId,
    required this.title,
    required this.updatedAt,
    required this.messageIndex,
    required this.role,
    required this.snippet,
  });

  final String conversationId;
  final String title;
  final DateTime updatedAt;

  /// 消息在这条对话里的下标（`read` 的 `from` / `to` 用的就是它）。
  final int messageIndex;

  /// 说话人：`user` / `assistant` / `tool`，群聊时带成员名。
  final String role;

  final String snippet;
}

/// 跨对话记忆的**只读**视图。
///
/// ## 它解决的是什么
///
/// 用户开了很多条对话，但它们彼此是孤岛：在 B 里说"上次那个方案"，
/// 模型完全不知道 A 里聊过什么。长期记忆（`MemoryStore`）只装一句话的
/// 事实，装不下"我们上周讨论过的那个接口设计"。
///
/// 所以这里给模型两个能力：
///  · **摘要自动注入**：每轮提示词里带上最近几条**其他对话**的标题和
///    最后一句话，模型至少知道"还有这些事"；
///  · **按需检索**：`recall` 工具可以按关键词搜原文、按范围读整条对话。
///
/// ## 为什么是只读
///
/// 会话内容属于用户。模型可以看、可以引用，但**不能改**别的对话 ——
/// 一旦允许写，一次误操作就会把用户的历史改掉，而且没有撤销。
/// 要往长期记忆里写东西，走 `memory` 工具（那是另一套、有上限、可删）。
///
/// ## 数据来源
///
/// 优先用**内存里的 `ConversationStore`**（`bind` 之后），这样不用读盘、
/// 也不会看到写盘延迟；没绑定时退回到 `conversations.json`（测试、
/// 后台任务）。两条路都只做读，不改文件。
class ChatArchive {
  ChatArchive._(this._file);

  static ChatArchive? _instance;

  /// 没初始化时返回 null —— 提示词构建和工具都可以据此**静默跳过**，
  /// 而不是抛异常。测试里大量构造 `buildApiMessages`，不该被迫先配这个。
  static ChatArchive? get maybeInstance => _instance;

  static ChatArchive get instance {
    final ChatArchive? s = _instance;
    if (s == null) {
      throw StateError(
        'ChatArchive 还没初始化。应该在 main() 里调用 ChatArchive.configure()。',
      );
    }
    return s;
  }

  static Future<ChatArchive> configure(File file) async {
    final ChatArchive s = ChatArchive._(file);
    _instance = s;
    return s;
  }

  /// 测试用：把单例清掉，验证"没初始化"时的降级路径。
  @visibleForTesting
  static void resetForTest() => _instance = null;

  final File _file;

  ConversationStore? _live;

  /// 绑定内存里的会话仓库。传 null 解除绑定（回到读文件）。
  void bind(ConversationStore? store) => _live = store;

  // ---- 文件模式的缓存 ----
  //
  // 每轮请求都会取一次摘要。不缓存的话，对话一多就是每轮都 JSON 解码
  // 一个可能几 MB 的文件 —— 纯属白烧 CPU 和电量。
  //
  // 用 mtime + size 判断"变没变"，比设一个固定 TTL 更准：刚聊完的
  // 那条必须马上能看到，而长时间没动时又不会反复读。
  List<Conversation>? _cache;
  int _cacheSize = -1;
  int _cacheModified = -1;

  /// 所有**非空白**对话（只读副本的引用，调用方不要修改）。
  Future<List<Conversation>> all() async {
    final ConversationStore? live = _live;
    if (live != null) {
      return live.conversations.where((Conversation c) => !c.isBlank).toList();
    }

    FileStat st;
    try {
      st = await _file.stat();
    } catch (_) {
      return const <Conversation>[];
    }
    if (st.type == FileSystemEntityType.notFound) {
      return const <Conversation>[];
    }
    final int modified = st.modified.millisecondsSinceEpoch;
    if (_cache != null && _cacheSize == st.size && _cacheModified == modified) {
      return _cache!;
    }

    final List<Conversation> out = <Conversation>[];
    try {
      final dynamic data = jsonDecode(await _file.readAsString());
      if (data is List) {
        for (final dynamic e in data) {
          try {
            final Conversation c = Conversation.fromJson(
              Map<String, dynamic>.from(e as Map),
            );
            if (!c.isBlank) out.add(c);
          } catch (_) {
            // 单条坏掉不该让整次检索失败。
          }
        }
      }
    } catch (_) {
      // 文件损坏时按"没有历史"处理；不要抛给模型。
      return const <Conversation>[];
    }
    _cache = out;
    _cacheSize = st.size;
    _cacheModified = modified;
    return out;
  }

  /// 最近更新的对话（默认排除当前这条）。
  Future<List<Conversation>> recent({
    String excludeId = '',
    int limit = 6,
  }) async {
    final List<Conversation> list =
        (await all())
            .where(
              (Conversation c) => c.id != excludeId && c.messages.isNotEmpty,
            )
            .toList()
          ..sort((Conversation a, Conversation b) {
            return b.updatedAt.compareTo(a.updatedAt);
          });
    if (limit > 0 && list.length > limit) {
      return list.sublist(0, limit);
    }
    return list;
  }

  /// 拼进系统提示词的一段。
  ///
  /// 只放**标题 + 时间 + 最后一句**：这是"提醒模型还有这些事"的索引，
  /// 不是内容本身。真需要细节时模型会调 `recall`，那时才付读全文的代价。
  ///
  /// 返回空串 = 没有其他对话，或用户关掉了跨聊天记忆 —— 调用方据此
  /// 不插入任何标题（空标题既费 token 又会让模型困惑）。
  Future<String> promptSection({
    String excludeId = '',
    bool enabled = true,
    int limit = 6,
  }) async {
    if (!enabled) return '';
    final List<Conversation> list = await recent(
      excludeId: excludeId,
      limit: limit,
    );
    if (list.isEmpty) return '';

    final StringBuffer sb = StringBuffer();
    sb.writeln();
    sb.writeln('## 跨聊天记忆');
    sb.writeln('下面是用户**其他对话**的索引（内容不在当前上下文里）。');
    sb.writeln(
      '需要细节时用 `recall`：`search` 按关键词找原文，`read` 读某条对话，'
      '`list` 看最近的对话。**不要编造其他对话的内容**；没查过就说不确定。',
    );
    for (final Conversation c in list) {
      final String title = _clamp(_oneLine(c.title), 40);
      final String last = _lastLine(c);
      sb.writeln('- 「$title」 · ${_ago(c.updatedAt)} · id=${c.id}');
      if (last.isNotEmpty) sb.writeln('  $last');
    }
    return sb.toString();
  }

  /// 按关键词搜其他对话的正文。
  ///
  /// 从**最新**的对话、最新的消息往前找：用户说"上次那个"时，十有八九
  /// 指最近的那次，而不是三个月前的。
  Future<List<ChatRecallHit>> search(
    String query, {
    String excludeId = '',
    int limit = 20,
    int sinceDays = 0,
  }) async {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) return const <ChatRecallHit>[];

    final DateTime? cutoff = sinceDays > 0
        ? DateTime.now().subtract(Duration(days: sinceDays))
        : null;
    final List<Conversation> convs =
        (await all())
            .where(
              (Conversation c) =>
                  c.id != excludeId &&
                  (cutoff == null || !c.updatedAt.isBefore(cutoff)),
            )
            .toList()
          ..sort((Conversation a, Conversation b) {
            return b.updatedAt.compareTo(a.updatedAt);
          });

    final List<ChatRecallHit> out = <ChatRecallHit>[];
    for (final Conversation c in convs) {
      for (int i = c.messages.length - 1; i >= 0; i--) {
        final ChatMessage m = c.messages[i];
        if (m.hidden) continue;
        final String text = _searchableText(m);
        if (text.isEmpty) continue;
        final int at = text.toLowerCase().indexOf(q);
        if (at < 0) continue;
        // 命中的是工具输出时，别标成"用户说" —— 模型会以为是用户的原话。
        final bool inTool = at >= m.content.length;
        out.add(
          ChatRecallHit(
            conversationId: c.id,
            title: _clamp(_oneLine(c.title), 40),
            updatedAt: c.updatedAt,
            messageIndex: i,
            role: inTool ? '工具输出' : _roleLabel(m),
            snippet: _around(text, at, q.length),
          ),
        );
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  /// 找一条对话：先按 id 精确匹配，再按标题模糊匹配。
  ///
  /// 模型手里通常只有 `list`/`search` 给它的 id；但用户也可能直接说
  /// "看看上次那个关于部署的对话"，所以标题匹配是必要的兜底。
  Future<Conversation?> find(String key) async {
    final String k = key.trim();
    if (k.isEmpty) return null;
    final List<Conversation> list = await all();
    for (final Conversation c in list) {
      if (c.id == k) return c;
    }
    // 标题模糊匹配时优先最近的那条：用户说"部署那个"，
    // 同名/近名的旧对话不该抢在新对话前面。
    final List<Conversation> byTime = List<Conversation>.from(list)
      ..sort((Conversation a, Conversation b) {
        return b.updatedAt.compareTo(a.updatedAt);
      });
    final String lower = k.toLowerCase();
    for (final Conversation c in byTime) {
      if (c.title.toLowerCase() == lower) return c;
    }
    for (final Conversation c in byTime) {
      if (c.title.toLowerCase().contains(lower)) return c;
    }
    return null;
  }

  /// 把一条对话渲染成给模型看的文本。
  ///
  /// [from] / [to] 是**消息下标**（从 0 开始，`to` 含）。负数表示不限。
  /// 单条消息和总输出都有上限：一次 `read` 把整条长对话倒进上下文，
  /// 和"不压缩历史"是同一个问题。
  String render(
    Conversation c, {
    int from = 0,
    int to = -1,
    int maxChars = 12000,
  }) {
    final StringBuffer sb = StringBuffer();
    sb.writeln(
      '对话「${_oneLine(c.title)}」 · ${_stamp(c.updatedAt)} · '
      '共 ${c.messages.length} 条',
    );
    if (c.messages.isEmpty) return sb.toString();

    final int start = from.clamp(0, c.messages.length - 1);
    final int end = (to < 0 ? c.messages.length - 1 : to).clamp(
      start,
      c.messages.length - 1,
    );
    if (start > 0 || end < c.messages.length - 1) {
      sb.writeln('（本次显示第 $start–$end 条）');
    }
    for (int i = start; i <= end; i++) {
      final ChatMessage m = c.messages[i];
      if (m.hidden) continue;
      final String who = _roleLabel(m);
      final String body = m.content.trim();
      if (body.isNotEmpty) {
        sb.writeln('[$i] $who：${_clamp(body, 2000)}');
      }
      for (final ToolInvocation t in m.tools) {
        final String out = (t.output ?? '').trim();
        if (out.isEmpty) continue;
        sb.writeln(
          '  · 工具 ${t.name}'
          '${t.summary.trim().isEmpty ? '' : '（${_clamp(_oneLine(t.summary), 60)}）'}'
          ' → ${_clamp(_oneLine(out), 300)}',
        );
      }
      if (sb.length >= maxChars) {
        sb.writeln('…（已到长度上限，剩余内容没有展开；需要就缩小范围再读）');
        break;
      }
    }
    return _clamp(sb.toString(), maxChars);
  }

  // ------------------------------------------------------------------ 小工具

  /// 搜索时参与匹配的文本：正文 + 工具输出。
  ///
  /// 工具输出很重要 —— "那个接口返回 500"往往只存在于工具结果里，
  /// 用户和模型都没在正文里复述过。
  static String _searchableText(ChatMessage m) {
    final StringBuffer sb = StringBuffer(m.content);
    for (final ToolInvocation t in m.tools) {
      final String out = t.output ?? '';
      if (out.isNotEmpty) sb.write('\n$out');
    }
    return sb.toString();
  }

  /// 对话摘要里的"最后一句"：取最后一条**有正文**的消息。
  static String _lastLine(Conversation c) {
    for (int i = c.messages.length - 1; i >= 0; i--) {
      final ChatMessage m = c.messages[i];
      if (m.hidden) continue;
      final String text = m.content.trim();
      if (text.isEmpty) continue;
      return '${_roleLabel(m)}说：${_clamp(_oneLine(text), 90)}';
    }
    return '';
  }

  static String _roleLabel(ChatMessage m) {
    final String speaker = (m.speaker ?? '').trim();
    if (speaker.isNotEmpty) return speaker;
    return switch (m.role) {
      Role.user => '用户',
      Role.assistant => '你',
      Role.tool => '工具',
      Role.system => '系统',
    };
  }

  /// 命中位置前后各取一段。用**原文**（不是小写版）截，保留大小写。
  static String _around(String text, int at, int len) {
    final int start = (at - 60).clamp(0, text.length);
    final int end = (at + len + 90).clamp(0, text.length);
    final String piece = text.substring(start, end);
    return '${start > 0 ? '…' : ''}${_oneLine(piece)}'
        '${end < text.length ? '…' : ''}';
  }

  static String _oneLine(String s) {
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _clamp(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…';
  }

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  static String _ago(DateTime t) {
    final Duration d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return _stamp(t);
  }
}
