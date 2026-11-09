import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/ids.dart';

/// 一次互动面板会话。
///
/// ## 它解决什么
///
/// 普通确认框只能问"是/否"；而"教我下围棋"这种活动需要一个**可交互的
/// 小页面**：棋盘、按钮、拖拽、计时器。AI 写 HTML，用户在里面操作，
/// 操作事件通过 [events] 回到 AI，AI 再用 `act` 改页面。
///
/// 面板关闭后事件不会丢：AI 下一次 `read` 或收到自动消息时仍能拿到。
class InteractionSession {
  InteractionSession({
    required this.id,
    required this.convId,
    required this.title,
    required this.html,
    this.kind = 'open',
    this.autoReact = true,
    this.autoCloseOnChoice = false,
  });

  final String id;
  final String convId;
  final String title;
  final String html;

  /// `ask` / `open` / `play`。
  ///
  /// 选择类（ask）在用户选完后可以**自动关**；游戏/自定义页面默认保持
  /// 打开，除非用户明确说结束。
  final String kind;

  /// 选择类面板：收到 `choice` 后自动关闭。
  final bool autoCloseOnChoice;

  /// 用户每次操作是否自动触发一个短的 AI 回合（实时轮流互动）。
  ///
  /// 关掉后只能靠 AI 主动 `read` 或用户关闭面板时拿到摘要 —— 适合一次性
  /// 表单，不适合"我点一下、它回一步"的活动。
  final bool autoReact;

  /// 页面发回来的事件（`App.send(...)` 的内容）。
  final List<Map<String, dynamic>> events = <Map<String, dynamic>>[];

  /// AI 发下去的 JS 命令；面板监听这个列表并执行。
  final List<InteractionCommand> commands = <InteractionCommand>[];

  bool closed = false;
  bool closedByUser = false;
  DateTime? closedAt;

  /// 已经实时处理过多少次用户操作。
  ///
  /// 关闭时用它决定"要不要再发一遍完整摘要"：过程已经实时给过 AI 了，
  /// 只在**一次实时回合都没有**时才补发完整摘要。
  int reactedEvents = 0;

  Map<String, dynamic> toReadPayload() => <String, dynamic>{
    'id': id,
    'title': title,
    'closed': closed,
    'closed_by_user': closedByUser,
    'kind': kind,
    'auto_react': autoReact,
    'events': events,
  };
}

class InteractionCommand {
  InteractionCommand(this.id, this.js);

  final int id;
  final String js;
}

/// 互动面板的全局协调器。
///
/// 和 `ChatRequestHub` 同一套思路：工具在 `AgentRunner` 深处执行，
/// 没法直接拿到某个 `ChatPage` 的 `BuildContext`；用 hub 把"打开面板"
/// 这个请求交给当前对话页。
class InteractionHub extends ChangeNotifier {
  InteractionHub._();

  static final InteractionHub instance = InteractionHub._();

  final Map<String, InteractionSession> _sessions =
      <String, InteractionSession>{};

  /// 新面板请求（ChatPage 监听后弹层）。
  final StreamController<InteractionSession> _opens =
      StreamController<InteractionSession>.broadcast();

  Stream<InteractionSession> get opens => _opens.stream;

  InteractionSession? byId(String id) => _sessions[id];

  /// 某条聊天当前**未关闭**的面板。
  InteractionSession? forConv(String convId) {
    InteractionSession? found;
    for (final InteractionSession s in _sessions.values) {
      if (s.convId == convId && !s.closed) found = s;
    }
    return found;
  }

  /// 用户操作时的实时回调（ChatPage 注册）。
  ///
  /// 接口就落在这里：页面 `App.send(...)` → `recordEvent` → `onEvent`。
  /// ChatPage 收到后开一个**很短的 AI 回合**，AI 用 `interact act` 回应，
  /// 面板无需关闭。
  void Function(InteractionSession session, Map<String, dynamic> event)?
  onEvent;

  InteractionSession open({
    required String convId,
    required String title,
    required String html,
    String kind = 'open',
    bool autoReact = true,
    bool autoCloseOnChoice = false,
  }) {
    final String cleanTitle = title.trim().isEmpty ? '互动面板' : title.trim();

    // ---- 同一张页面再 open 一次 = 不做事 ----
    //
    // 模型有时会把"更新一下棋盘"也写成 open（重新生成整页 HTML）。
    // 那样会新建 session → 面板换个 id → WebView 重新加载，
    // 用户刚落的子就没了。只要页面内容一模一样，就把旧 session 原样还给它。
    final InteractionSession? old = forConv(convId);
    if (old != null) {
      if (old.html == html && old.kind == kind && old.title == cleanTitle) {
        return old;
      }
      // 同一聊天只保留一个面板：旧的先关掉，避免两个 WebView 抢输入。
      close(old.id, byUser: false);
    }
    final InteractionSession s = InteractionSession(
      id: newId(),
      convId: convId,
      title: cleanTitle,
      html: html,
      kind: kind,
      autoReact: autoReact,
      autoCloseOnChoice: autoCloseOnChoice,
    );
    _sessions[s.id] = s;
    _opens.add(s);
    notifyListeners();
    return s;
  }

  void recordEvent(String id, Map<String, dynamic> event) {
    final InteractionSession? s = _sessions[id];
    if (s == null) return;
    s.events.add(<String, dynamic>{
      'at': DateTime.now().toIso8601String(),
      ...event,
    });
    // 只保留最近 100 条：长活动（比如打一整盘棋）不把内存吃光。
    if (s.events.length > 100) {
      s.events.removeRange(0, s.events.length - 100);
    }
    notifyListeners();
    // 实时接口：用户点一下，AI 就能收到一次。
    if (s.autoReact && !s.closed) {
      onEvent?.call(s, Map<String, dynamic>.from(event));
    }
  }

  void command(String id, String js) {
    final InteractionSession? s = _sessions[id];
    if (s == null || s.closed) return;
    s.commands.add(InteractionCommand(s.commands.length + 1, js));
    notifyListeners();
  }

  void close(String id, {bool byUser = false}) {
    final InteractionSession? s = _sessions[id];
    if (s == null || s.closed) return;
    s.closed = true;
    s.closedByUser = byUser;
    s.closedAt = DateTime.now();
    notifyListeners();
  }

  /// 给 AI 的关闭摘要：用户做了什么、最后停在哪。
  String summary(String id) {
    final InteractionSession? s = _sessions[id];
    if (s == null) return '';
    final StringBuffer sb = StringBuffer();
    sb.writeln('面板「${s.title}」已关闭。');
    if (s.events.isEmpty) {
      sb.writeln('用户没有产生任何操作。');
    } else {
      sb.writeln('用户的操作（最近 ${s.events.length} 条）：');
      for (final Map<String, dynamic> e
          in s.events.reversed.take(12).toList().reversed) {
        final Map<String, dynamic> copy = Map<String, dynamic>.from(e)
          ..remove('at');
        sb.writeln('- ${copy.toString()}');
      }
    }
    sb.writeln('请根据这些操作继续下一步；不要再重复问已经确定过的信息。');
    return sb.toString();
  }
}
