import 'dart:convert';
import 'dart:io';

import '../core/models.dart';
import 'tool.dart';

/// 计划树里的一个节点。
class PlanNode {
  PlanNode({
    required this.id,
    required this.title,
    required this.task,
    this.after = const <String>[],
    this.status = 'todo',
    this.note = '',
  });

  final String id;
  String title;
  String task;

  /// 依赖：这些节点都 `done` 之后，本节点才就绪。
  List<String> after;

  /// `todo` / `doing` / `done` / `blocked`。
  String status;

  /// 结果或卡住的原因。模型自己回填，人看的是这一段。
  String note;

  bool get done => status == 'done';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'task': task,
    'after': after,
    'status': status,
    'note': note,
  };

  static PlanNode fromJson(Map<String, dynamic> j) => PlanNode(
    id: j['id']?.toString() ?? '',
    title: j['title']?.toString() ?? '',
    task: j['task']?.toString() ?? '',
    after: <String>[
      for (final dynamic e in (j['after'] as List?) ?? const <dynamic>[])
        if (e != null) e.toString(),
    ],
    status: j['status']?.toString() ?? 'todo',
    note: j['note']?.toString() ?? '',
  );
}

/// **计划树**：把一件大活拆成带依赖的节点，按"就绪即跑"的顺序推进。
///
/// ## 为什么不是"一键自动执行"
///
/// 参考实现里有一个子 runner 替模型跑每一段。这个应用没有那层东西 ——
/// 而**也不需要**：agent 每一轮本来就能并行调用多个工具（见
/// `AgentRunner._executeAll`）。所以这里只做**记账**：
///
///  1. `set` 把计划写下来（节点 + 依赖）；
///  2. 系统提示词每轮都会带上当前计划，模型看到"哪些节点此刻就绪"；
///  3. 模型**直接用手上的工具**把就绪节点做完（同一轮里可以并行）；
///  4. `update` 回填状态和结论，下一轮的提示词里就少了一个待办。
///
/// 这样计划和执行是同一套循环，不会出现"计划在跑、我却在等"的两层状态。
///
/// ## 状态存在哪
///
/// `<workDir>/plans/<convId>.json`。**按会话隔离**：同一个应用里两条对话
/// 各有各的计划，互不覆盖。删对话时那份文件留在磁盘上 —— 不主动删，
/// 因为"误删找不回来"比"多占几 KB"严重得多。
class PlanStore {
  PlanStore._();

  static final PlanStore instance = PlanStore._();

  /// 内存缓存，避免每轮都读盘。
  final Map<String, List<PlanNode>> _cache = <String, List<PlanNode>>{};

  /// 从磁盘补一次（工具第一次碰到某个会话时调）。
  Future<List<PlanNode>> nodesOf(String convId, String workDir) async {
    final List<PlanNode>? cached = _cache[convId];
    if (cached != null) return cached;
    final List<PlanNode> loaded = <PlanNode>[];
    try {
      final File f = _file(convId, workDir);
      if (await f.exists()) {
        final dynamic data = jsonDecode(await f.readAsString());
        if (data is List) {
          for (final dynamic e in data) {
            if (e is Map) {
              loaded.add(PlanNode.fromJson(Map<String, dynamic>.from(e)));
            }
          }
        }
      }
    } catch (_) {
      // 文件坏了就当没有计划；不要让一个坏 JSON 挡住整场对话。
    }
    _cache[convId] = loaded;
    return loaded;
  }

  Future<void> save(String convId, String workDir, List<PlanNode> nodes) async {
    _cache[convId] = nodes;
    try {
      final File f = _file(convId, workDir);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode(nodes.map((PlanNode n) => n.toJson()).toList()),
      );
    } catch (_) {}
  }

  void forget(String convId) => _cache.remove(convId);

  File _file(String convId, String workDir) =>
      File('$workDir/plans/$convId.json');

  /// 拼成注入系统提示词的一段。
  ///
  /// 只列**未完成**的节点 + 每个节点的状态：已经做完的那些，结论早就
  /// 在对话里了，再列一遍只是把上下文撑长。
  Future<String> promptSection(String convId, String workDir) async {
    final List<PlanNode> nodes = await nodesOf(convId, workDir);
    if (nodes.isEmpty) return '';
    final List<PlanNode> open = nodes.where((PlanNode n) => !n.done).toList();
    if (open.isEmpty) {
      return '\n## 计划树\n所有节点都已完成。用户如果要继续，用 `plan` 的 '
          'action=set 重新规划（旧计划会被覆盖）。\n';
    }
    final Set<String> doneIds = nodes
        .where((PlanNode n) => n.done)
        .map((PlanNode n) => n.id)
        .toSet();
    final StringBuffer sb = StringBuffer();
    sb.writeln();
    sb.writeln('## 计划树（共 ${nodes.length} 个节点，'
        '${doneIds.length} 个已完成）');
    for (final PlanNode n in open) {
      final List<String> waiting = n.after
          .where((String a) => !doneIds.contains(a))
          .toList();
      final String state = waiting.isEmpty ? '**就绪**' : '等待 ${waiting.join('、')}';
      sb.writeln('- `$n.id` ${n.title} · 状态 ${n.status} · $state');
      if (n.task.trim().isNotEmpty) {
        sb.writeln('  任务：${_short(n.task)}');
      }
      if (n.note.trim().isNotEmpty) {
        sb.writeln('  备注：${_short(n.note)}');
      }
    }
    sb.writeln(
      '就绪的节点**现在就可以做**（同一轮里彼此独立的可以一起调工具）。'
      '做完用 `plan` 的 action=update 回填 status=done 和结论；'
      '卡住了也回填 status=blocked 并写清原因，不要闷着。',
    );
    return sb.toString();
  }

  static String _short(String s) {
    final String t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= 160 ? t : '${t.substring(0, 159)}…';
  }
}

/// 让 agent 维护自己的**计划树**。
class PlanTool extends AgentTool {
  const PlanTool();

  @override
  String get name => 'plan';

  @override
  String get title => '计划树';

  @override
  String get description =>
      '把一件多步骤的事拆成**带依赖的节点**，并逐节点推进。\n'
      '\n'
      '**什么时候用**：用户给了需要 3 步以上的活（调研 + 写稿 + 核对、'
      '批量处理多个文件、一个功能拆成设计/实现/验证），而且中间有先后依赖。'
      '两三步能一口气做完的**不要**建计划树 —— 那只是多写了一层账。\n'
      '\n'
      '动作：\n'
      '· `set` —— 参数 `nodes`（数组，每项 `{id, title, task, after?}`）。'
      '`after` 是它依赖的节点 id 数组，没有依赖就省略。**覆盖**已有计划。\n'
      '· `update` —— 参数 `id` + `status`（doing/done/blocked）+ 可选 `note`。'
      '做完一个节点就立刻回填，不要攒到最后。\n'
      '· `list` —— 看当前计划（通常不用，提示词里每轮都带着）。\n'
      '· `clear` —— 清空。\n'
      '\n'
      '节点粒度：**一个节点 = 一次能做完、且能说清做完没做完的事**。'
      '不要切成"第一步思考、第二步打字"这种；也不要一个节点塞三件事。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>['set', 'update', 'list', 'clear'],
      },
      'nodes': <String, dynamic>{
        'type': 'array',
        'description': 'set 时的节点列表',
        'items': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{
              'type': 'string',
              'description': '短 id，如 s1、s2；同一棵树里唯一',
            },
            'title': <String, dynamic>{
              'type': 'string',
              'description': '一句话标题',
            },
            'task': <String, dynamic>{
              'type': 'string',
              'description': '这一步具体要做什么、产出是什么',
            },
            'after': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'description': '依赖的节点 id；没有就省略',
            },
          },
          'required': <String>['id', 'title'],
        },
      },
      'id': <String, dynamic>{
        'type': 'string',
        'description': 'update 时改哪个节点',
      },
      'status': <String, dynamic>{
        'type': 'string',
        'enum': <String>['doing', 'done', 'blocked'],
        'description': 'update 时的新状态',
      },
      'note': <String, dynamic>{
        'type': 'string',
        'description': 'update 时的结论 / 卡住的原因',
      },
    },
    'required': <String>['action'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) =>
      const RiskAssessment(RiskLevel.safe, <String>[]);

  @override
  String summarize(Map<String, dynamic> args) {
    switch (args.str('action')) {
      case 'set':
        final int n = (args['nodes'] is List)
            ? (args['nodes'] as List).length
            : 0;
        return '制定计划：$n 个节点';
      case 'update':
        return '更新节点 ${args.str('id')} → ${args.str('status')}';
      case 'clear':
        return '清空计划';
      default:
        return '查看计划';
    }
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String convId = ctx.conversation.id;
    final String action = args.str('action');

    switch (action) {
      case 'set':
        return _set(ctx, convId, args);
      case 'update':
        return _update(ctx, convId, args);
      case 'clear':
        await PlanStore.instance.save(convId, ctx.workDir, <PlanNode>[]);
        return '计划已清空。';
      case 'list':
        return _list(ctx, convId);
      default:
        return '错误：未知 action「$action」（支持 set / update / list / clear）';
    }
  }

  Future<String> _set(
    ToolContext ctx,
    String convId,
    Map<String, dynamic> args,
  ) async {
    final dynamic raw = args['nodes'];
    if (raw is! List || raw.isEmpty) {
      return '错误：set 需要非空的 nodes 数组。';
    }
    final List<PlanNode> nodes = <PlanNode>[];
    final Set<String> ids = <String>{};
    for (final dynamic e in raw) {
      if (e is! Map) continue;
      final Map<String, dynamic> j = Map<String, dynamic>.from(e);
      final String id = (j['id']?.toString() ?? '').trim();
      if (id.isEmpty) continue;
      if (!ids.add(id)) {
        return '错误：节点 id「$id」重复了。每个节点要有唯一的短 id。';
      }
      nodes.add(
        PlanNode(
          id: id,
          title: (j['title']?.toString() ?? '').trim(),
          task: (j['task']?.toString() ?? '').trim(),
          after: <String>[
            for (final dynamic a in (j['after'] as List?) ?? const <dynamic>[])
              if (a != null && a.toString().trim().isNotEmpty)
                a.toString().trim(),
          ],
        ),
      );
    }
    if (nodes.isEmpty) return '错误：nodes 里没有一个带 id 的合法节点。';

    // 依赖必须指向**存在**的节点，否则这棵树永远跑不完 ——
    // 提前拦下来，而不是让模型在第三轮发现"等待 s9"却从没定义过 s9。
    for (final PlanNode n in nodes) {
      for (final String a in n.after) {
        if (!ids.contains(a)) {
          return '错误：节点「${n.id}」依赖了不存在的「$a」。'
              '现有节点：${ids.join('、')}';
        }
        if (a == n.id) {
          return '错误：节点「${n.id}」依赖了自己。';
        }
      }
    }

    await PlanStore.instance.save(convId, ctx.workDir, nodes);

    // 算出此刻就绪的节点，直接告诉模型"现在做这些"，
    // 免得它再调一次 list 来算。
    final Set<String> done = <String>{};
    final List<PlanNode> ready = _readyOf(nodes, done);
    final StringBuffer sb = StringBuffer();
    sb.writeln('计划已建立：${nodes.length} 个节点。');
    for (final PlanNode n in nodes) {
      sb.writeln(
        '- `$n.id` ${n.title}'
        '${n.after.isEmpty ? '' : '（等待 ${n.after.join('、')}）'}',
      );
    }
    sb.writeln();
    if (ready.isEmpty) {
      sb.writeln(
        '⚠ 没有任何节点就绪 —— 依赖关系可能有环。请检查后重新 set。',
      );
    } else {
      sb.writeln(
        '现在就绪：${ready.map((PlanNode n) => '`${n.id}`').join('、')}。'
        '可以直接开始做（彼此独立的话同一轮一起做），做完立刻 update。',
      );
    }
    return sb.toString();
  }

  Future<String> _update(
    ToolContext ctx,
    String convId,
    Map<String, dynamic> args,
  ) async {
    final String id = args.str('id').trim();
    if (id.isEmpty) return '错误：update 需要 id。';
    final String status = args.str('status').trim();
    if (!<String>{'doing', 'done', 'blocked'}.contains(status)) {
      return '错误：status 只能是 doing / done / blocked。';
    }

    final List<PlanNode> nodes = await PlanStore.instance.nodesOf(
      convId,
      ctx.workDir,
    );
    final int i = nodes.indexWhere((PlanNode n) => n.id == id);
    if (i < 0) {
      return '找不到节点「$id」。当前计划：'
          '${nodes.map((PlanNode n) => n.id).join('、')}';
    }
    nodes[i].status = status;
    final String note = args.str('note').trim();
    if (note.isNotEmpty) nodes[i].note = note;
    await PlanStore.instance.save(convId, ctx.workDir, nodes);

    final Set<String> done = nodes
        .where((PlanNode n) => n.done)
        .map((PlanNode n) => n.id)
        .toSet();
    final List<PlanNode> ready = _readyOf(nodes, done);

    final StringBuffer sb = StringBuffer();
    sb.writeln('已更新 `$id` → $status。');
    sb.writeln(
      '进度：${done.length}/${nodes.length} 完成。',
    );
    if (ready.isNotEmpty) {
      sb.writeln(
        '现在就绪：${ready.map((PlanNode n) => '`${n.id}`（${n.title}）').join('、')}。',
      );
    } else if (done.length < nodes.length) {
      final List<PlanNode> blocked = nodes
          .where((PlanNode n) => n.status == 'blocked')
          .toList();
      if (blocked.isNotEmpty) {
        sb.writeln(
          '还有 ${blocked.length} 个节点卡住了（'
          '${blocked.map((PlanNode n) => n.id).join('、')}）—— '
          '把它们的原因说给用户听，或者换一种做法。',
        );
      }
    } else {
      sb.writeln('所有节点都完成了。给用户一份简要的总结（做了什么、结果在哪）。');
    }
    return sb.toString();
  }

  Future<String> _list(ToolContext ctx, String convId) async {
    final List<PlanNode> nodes = await PlanStore.instance.nodesOf(
      convId,
      ctx.workDir,
    );
    if (nodes.isEmpty) return '还没有计划。要拆多步任务时用 action=set。';
    final Set<String> done = nodes
        .where((PlanNode n) => n.done)
        .map((PlanNode n) => n.id)
        .toSet();
    final StringBuffer sb = StringBuffer();
    sb.writeln('计划（${done.length}/${nodes.length} 完成）：');
    for (final PlanNode n in nodes) {
      sb.writeln('- `$n.id` [${n.status}] ${n.title}');
    }
    return sb.toString();
  }

  /// 所有依赖都完成的节点。
  List<PlanNode> _readyOf(List<PlanNode> nodes, Set<String> done) {
    return nodes
        .where((PlanNode n) => !n.done && n.status != 'blocked')
        .where((PlanNode n) => n.after.every(done.contains))
        .toList();
  }
}
