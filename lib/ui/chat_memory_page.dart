import 'dart:async';

import 'package:flutter/material.dart';

import '../core/chat_recall.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';

/// 「可回忆的对话」：让用户看到 AI 到底能读到哪些**其他对话**。
///
/// ## 为什么值得单独做一页
///
/// 跨聊天记忆是"在后台悄悄发生"的能力：提示词里多了几行索引、模型偶尔
/// 调一次 `recall`。用户看不见，就很难信任它 —— 也不知道该不该关掉。
///
/// 这一页把"AI 能看到的"原样列出来：哪些对话、什么时候、最后一句话。
/// 点开还能看正文。**只读**：这里没有任何编辑入口，避免用户以为
/// 能在这里改历史（那应该去聊天页改）。
class ChatMemoryPage extends StatefulWidget {
  const ChatMemoryPage({super.key, required this.currentId});

  /// 当前正在聊的那条，不列出来（它本来就在上下文里）。
  final String currentId;

  @override
  State<ChatMemoryPage> createState() => _ChatMemoryPageState();
}

class _ChatMemoryPageState extends State<ChatMemoryPage> {
  final TextEditingController _query = TextEditingController();

  List<Conversation> _recent = <Conversation>[];
  List<ChatRecallHit> _hits = <ChatRecallHit>[];
  bool _searching = false;
  bool _loading = true;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  ChatArchive? get _archive => ChatArchive.maybeInstance;

  Future<void> _loadRecent() async {
    final ChatArchive? a = _archive;
    if (a == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final List<Conversation> list = await a.recent(
      excludeId: widget.currentId,
      limit: 50,
    );
    if (!mounted) return;
    setState(() {
      _recent = list;
      _hits = <ChatRecallHit>[];
      _searching = false;
      _loading = false;
    });
  }

  void _onQuery(String raw) {
    _debounce?.cancel();
    final String q = raw.trim();
    if (q.isEmpty) {
      _loadRecent();
      return;
    }
    // 每敲一个字都搜一遍历史文件没必要；停 250ms 再搜。
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final ChatArchive? a = _archive;
      if (a == null) return;
      final List<ChatRecallHit> hits = await a.search(
        q,
        excludeId: widget.currentId,
        limit: 50,
      );
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _searching = true;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final int count = _searching ? _hits.length : _recent.length;

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: '跨聊天记忆',
            subtitle: _loading
                ? '正在读取…'
                : (_searching ? '找到 $count 条' : 'AI 能读到 $count 条其他对话 · 只读'),
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: TextField(
              controller: _query,
              onChanged: _onQuery,
              style: AppFonts.body(size: 14, color: s.text),
              decoration: InputDecoration(
                hintText: '搜一个关键词，比如"部署"',
                hintStyle: AppFonts.body(size: 14, color: s.muted),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: s.muted,
                ),
                isDense: true,
                filled: true,
                fillColor: s.surface,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.field),
                  borderSide: BorderSide(color: s.border, width: 0.9),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.field),
                  borderSide: BorderSide(color: s.border, width: 0.9),
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const SizedBox.shrink()
                : (_searching ? _hitList(s) : _recentList(s)),
          ),
        ],
      ),
    );
  }

  Widget _recentList(AppSurface s) {
    if (_recent.isEmpty) {
      return const EmptyHint(
        icon: Icons.forum_outlined,
        title: '还没有其他对话',
        desc:
            '等你多聊几条之后，AI 才能在这里看到"上次那个"指的是什么。\n'
            '它只读，不会修改任何一条对话。',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
      itemCount: _recent.length,
      itemBuilder: (BuildContext context, int i) {
        final Conversation c = _recent[i];
        return _card(
          s,
          title: c.title.trim().isEmpty ? '未命名' : c.title.trim(),
          meta: '${_ago(c.updatedAt)} · ${c.messages.length} 条',
          body: _lastLine(c),
          onTap: () => _open(c, from: 0, to: -1),
        );
      },
    );
  }

  Widget _hitList(AppSurface s) {
    if (_hits.isEmpty) {
      return const EmptyHint(
        icon: Icons.search_off_rounded,
        title: '没有找到',
        desc: '换个关键词试试。只搜其他对话，当前这条不算。',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
      itemCount: _hits.length,
      itemBuilder: (BuildContext context, int i) {
        final ChatRecallHit h = _hits[i];
        return _card(
          s,
          title: h.title,
          meta: '${_ago(h.updatedAt)} · 第 ${h.messageIndex} 条 · ${h.role}',
          body: h.snippet,
          onTap: () => _openHit(h),
        );
      },
    );
  }

  Widget _card(
    AppSurface s, {
    required String title,
    required String meta,
    required String body,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 13.5,
                    color: s.text,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(meta, style: AppFonts.body(size: 11.5, color: s.muted)),
                if (body.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.read(
                      size: 12.5,
                      color: s.text.withValues(alpha: 0.78),
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openHit(ChatRecallHit h) async {
    final ChatArchive? a = _archive;
    if (a == null) return;
    final Conversation? c = await a.find(h.conversationId);
    if (c == null || !mounted) return;
    await _open(
      c,
      from: (h.messageIndex - 3).clamp(0, c.messages.length - 1),
      to: (h.messageIndex + 5).clamp(0, c.messages.length - 1),
    );
  }

  Future<void> _open(
    Conversation c, {
    required int from,
    required int to,
  }) async {
    final ChatArchive? a = _archive;
    if (a == null) return;
    final String text = a.render(c, from: from, to: to, maxChars: 16000);
    if (!mounted) return;
    final AppSurface s = AppSurface.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: s.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        c.title.trim().isEmpty ? '未命名' : c.title.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.body(
                          size: 15,
                          color: s.text,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '只读',
                      style: AppFonts.body(size: 11.5, color: s.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      text,
                      style: AppFonts.read(
                        size: 13,
                        color: s.text,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _lastLine(Conversation c) {
    for (int i = c.messages.length - 1; i >= 0; i--) {
      final ChatMessage m = c.messages[i];
      if (m.hidden) continue;
      final String t = m.content.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isEmpty) continue;
      final String who = m.role == Role.user ? '用户' : '你';
      return '$who说：$t';
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
