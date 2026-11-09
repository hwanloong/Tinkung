import 'dart:convert';

import 'file_diff.dart';
import 'text_marks.dart';
import 'think_tags.dart';

/// 风险等级。
///
/// 这是整个 app 的安全基线：**只有白名单内的只读命令才是 [safe]**，
/// 认不出来的一律落到 [caution]，宁可多问一次，也不静默执行。
enum RiskLevel {
  /// 明确的只读命令，直接执行
  safe,

  /// 无法确认安全，或会改变可逆状态 —— 需要确认
  caution,

  /// 破坏性、不可撤销 —— 需要确认，且默认按钮是「拒绝」
  dangerous,
}

extension RiskLevelX on RiskLevel {
  String get label => switch (this) {
    RiskLevel.safe => '只读',
    RiskLevel.caution => '需确认',
    RiskLevel.dangerous => '危险',
  };

  /// 是否需要弹窗确认
  bool get needsConfirm => this != RiskLevel.safe;
}

/// 风险判定结果：等级 + 人话解释「为什么危险」。
/// 把理由展示给用户是这套机制的关键——只弹「是否继续」等于没提示。
class RiskAssessment {
  const RiskAssessment(this.level, this.reasons);

  final RiskLevel level;
  final List<String> reasons;

  static const RiskAssessment safe = RiskAssessment(RiskLevel.safe, <String>[]);

  bool get isDangerous => level == RiskLevel.dangerous;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'level': level.name,
    'reasons': reasons,
  };

  static RiskAssessment fromJson(Map<String, dynamic> j) => RiskAssessment(
    RiskLevel.values.firstWhere(
      (RiskLevel e) => e.name == j['level'],
      orElse: () => RiskLevel.caution,
    ),
    (j['reasons'] as List<dynamic>? ?? <dynamic>[])
        .map((dynamic e) => e.toString())
        .toList(),
  );
}

/// 一次工具调用的状态
enum InvocationStatus {
  /// 等待用户确认
  awaitingConfirm,
  running,
  success,
  failed,

  /// 用户点了拒绝
  rejected,
}

/// 用户在工具确认框里的选择。
///
/// 为什么不是 `bool`：确认框上现在有**三个**出路 —— 拒绝、执行这一次、
/// 以及「全部运行」（之后不再问）。压成布尔的话，「全部运行」只能由
/// UI 自己去改设置，而 agent 侧那份 `autoApproveAll` 判断会和它错开：
/// "这次算不算放行"要绕一圈才回到执行处。
///
/// 放在 models.dart（而不是 agent.dart）是为了让 UI 能直接用 ——
/// `widgets.dart` 本来就 import 这个文件，不必让一个纯 UI 工具反过来
/// 依赖 agent 主循环。
enum ConfirmDecision {
  /// 拒绝这次调用
  deny,

  /// 只放行这一次
  allow,

  /// 放行，并且**之后不再询问**（用户点了「全部运行」）
  allowAll,
}

/// 一次具体的工具调用
class ToolInvocation {
  ToolInvocation({
    required this.id,
    required this.name,
    required this.argumentsJson,
    required this.args,
    required this.risk,
    this.title = '',
    this.summary = '',
    this.status = InvocationStatus.awaitingConfirm,
    this.output,
    this.changes = const <FileChange>[],
    this.startedAt,
    this.finishedAt,
  });

  /// 对应 API 的 tool_call id
  final String id;
  final String name;

  /// **调用当时**工具自己报的中文名（`AgentTool.title`）。
  ///
  /// 为什么存下来而不是渲染时再查注册表：
  ///  · 注册表是**每一轮对话开头**按当前档案/权限/插件状态构建的，
  ///    历史消息渲染时再重建一次，既贵又可能查出**另一个**工具
  ///    （插件被删、MCP 断线、档案被切换都会让同一个名字指向别处）；
  ///  · 确认框和工具行要在这里显示"这是什么工具"，答案应该是
  ///    "模型当时调的那个"，不是"现在注册表里碰巧还叫这个名字的"。
  ///
  /// 空串 = 老存档没有这个字段，UI 退回显示 [name]。
  final String title;

  /// **调用当时**工具给出的一行摘要（`AgentTool.summarize(args)`）。
  ///
  /// 确认框和工具行都用它来回答"它到底要做什么"。同样在创建时落定：
  /// 摘要依赖参数和工具定义，事后再算既需要注册表、又可能和当时不一致。
  /// 空串 = 没有摘要，UI 退回原始参数 JSON。
  final String summary;

  /// 原始 JSON 字符串（回传给模型时必须原样带上）
  final String argumentsJson;
  final Map<String, dynamic> args;
  final RiskAssessment risk;

  InvocationStatus status;
  String? output;

  /// 这次调用实际改动了哪些文件、逐行差异是什么。
  ///
  /// 只在可能写文件的工具执行前后自动记录（见 [FileChangeTracker]）。
  /// 老存档没有这个字段时是空列表，文件卡片照常能打开文件，只是没有
  /// “查看修改”入口。
  List<FileChange> changes;

  /// 什么时候开始跑 / 跑完。性能面板要按时间列出"调用过什么、结果如何"，
  /// 这两项就是那行时间戳和耗时的来源。
  ///
  /// 可空而不是给默认值：老存档里没有这两个字段，硬塞一个 `DateTime.now()`
  /// 会让所有历史调用看起来都发生在"打开应用的那一刻"。UI 上显示"—"，
  /// 那是诚实的。
  DateTime? startedAt;
  DateTime? finishedAt;

  /// 这次调用花了多久；没有起止时间时返回 null。
  Duration? get elapsed => (startedAt == null || finishedAt == null)
      ? null
      : finishedAt!.difference(startedAt!);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    if (title.isNotEmpty) 'title': title,
    if (summary.isNotEmpty) 'summary': summary,
    'argumentsJson': argumentsJson,
    'args': args,
    'risk': risk.toJson(),
    'status': status.name,
    'output': output,
    if (changes.isNotEmpty)
      'changes': <Map<String, dynamic>>[
        for (final FileChange c in changes) c.toJson(),
      ],
    'startedAt': startedAt?.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
  };

  static ToolInvocation fromJson(Map<String, dynamic> j) => ToolInvocation(
    id: j['id']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    title: j['title']?.toString() ?? '',
    summary: j['summary']?.toString() ?? '',
    argumentsJson: j['argumentsJson']?.toString() ?? '{}',
    args: Map<String, dynamic>.from((j['args'] as Map?) ?? <String, dynamic>{}),
    risk: RiskAssessment.fromJson(
      Map<String, dynamic>.from((j['risk'] as Map?) ?? <String, dynamic>{}),
    ),
    status: InvocationStatus.values.firstWhere(
      (InvocationStatus e) => e.name == j['status'],
      orElse: () => InvocationStatus.success,
    ),
    output: j['output']?.toString(),
    changes: <FileChange>[
      for (final dynamic e in (j['changes'] as List?) ?? const <dynamic>[])
        if (e is Map) FileChange.fromJson(Map<String, dynamic>.from(e)),
    ],
    startedAt: DateTime.tryParse(j['startedAt']?.toString() ?? ''),
    finishedAt: DateTime.tryParse(j['finishedAt']?.toString() ?? ''),
  );
}

/// 附件类型
enum AttachmentKind {
  /// 图片：交给模型的图像理解
  image,

  /// 本地文件：文本类会读出内容拼进消息
  file,

  /// 网页 / 接口：插入时抓取内容并随消息一起发给模型
  web,
}

/// 随消息一起发出的附件。
///
/// 图片会作为 image 内容块交给支持图像理解的模型；
/// 文本类文件则把内容读出来拼进文本里；
/// 网页/接口在**插入时就抓取**并把内容存下来——
/// 这样历史记录不需要重新联网，也不会因为原页面改版而对不上。
class Attachment {
  Attachment({
    required this.kind,
    required this.path,
    required this.name,
    this.mime = '',
    this.size = 0,
    this.content = '',
  });

  final AttachmentKind kind;

  /// 本地绝对路径；[AttachmentKind.web] 时存的是原始网址。
  /// 图片会被复制到应用私有目录，避免系统清理缓存后历史记录里的图失效。
  String path;
  String name;
  String mime;
  int size;

  /// 仅 [AttachmentKind.web] 使用：抓取到的正文/JSON（已截断）
  String content;

  bool get isImage => kind == AttachmentKind.image;
  bool get isWeb => kind == AttachmentKind.web;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    'path': path,
    'name': name,
    'mime': mime,
    'size': size,
    'content': content,
  };

  static Attachment fromJson(Map<String, dynamic> j) {
    final String? kindName = j['kind']?.toString();
    final AttachmentKind kind = kindName == null
        // 兼容早期只存了 isImage 布尔值的记录
        ? (j['isImage'] == true ? AttachmentKind.image : AttachmentKind.file)
        : AttachmentKind.values.firstWhere(
            (AttachmentKind e) => e.name == kindName,
            orElse: () => AttachmentKind.file,
          );

    return Attachment(
      kind: kind,
      path: j['path']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      mime: j['mime']?.toString() ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      content: j['content']?.toString() ?? '',
    );
  }
}

enum Role { user, assistant, system, tool }

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    this.content = '',
    this.reasoning = '',
    this.reasoningMs = 0,
    this.reasoningLevel = '',
    List<TextMark>? marks,
    this.quote,
    this.improvedPrompt,
    this.mentionContext,
    List<ToolInvocation>? tools,
    List<Attachment>? attachments,
    List<String>? sources,
    DateTime? createdAt,
    this.pending = false,
    this.error,
    this.speaker,
    this.hidden = false,
    List<String>? varRefs,
  }) : marks = marks ?? <TextMark>[],
       tools = tools ?? <ToolInvocation>[],
       attachments = attachments ?? <Attachment>[],
       sources = sources ?? <String>[],
       varRefs = varRefs ?? <String>[],
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final Role role;
  String content;

  /// **`@` 引用展开后的上下文**（工具全文 / 插件提示）。
  ///
  /// ## 为什么不直接拼进 `content`
  ///
  /// `content` 是**给用户看**的（气泡里显示的就是它）。把一整套工具说明
  /// 拼进去，用户会看到自己那条消息变成十几行 —— 他只是打了个 `@`。
  ///
  /// 所以拆成两个字段：
  ///  · `content` = 用户打的原文（含 `@tool:xxx` 标记，那是他的意图记录）；
  ///  · `mentionContext` = 展开后的正文，只在**发请求**时附上
  ///    （见 `buildApiMessages`）。
  ///
  /// 它仍然要持久化：否则重开应用后，同一条消息发出去的内容会变
  /// —— 那会让"为什么昨天它是那么答的"变得无法解释。
  String? mentionContext;

  /// 这条消息上的**文字标记**和**引用锚点**（长按选中产生的）。
  ///
  /// 是本机笔记的性质，不过 API —— 但**要跟着会话持久化**，
  /// 否则重启一次自己标的高亮就全没了。见 [TextMark]。
  final List<TextMark> marks;

  /// 这条消息**引用了哪段原文**（引用回复）。
  ///
  /// 只有用户消息会有（AI 不会主动引用），但类型上不限制 ——
  /// 以后想让 AI 也带引用不用改模型。
  MessageQuote? quote;

  /// **改进后的提示词**（「描述改进」功能）。
  ///
  /// ## 语义
  ///
  /// [content] 永远存**用户原话**（界面显示的就是它）；
  /// 这里存模型改写出来的那一版，而**发给模型的是这一版**。
  ///
  /// ## 为什么不直接覆盖 content
  ///
  /// 两个理由：
  ///  · 用户要看得出"我的原话被改成了什么" —— 覆盖了就无从对照，
  ///    而这正是不信任自动改写的人最需要看到的；
  ///  · 历史里保留原话，重新发送时还能再改一次；覆盖之后原话永久丢了。
  String? improvedPrompt;

  /// 这条用户消息的正文**被存进变量库**时，变量叫什么名字。
  ///
  /// ## 为什么需要它
  ///
  /// 用户粘一大段内容（规格、日志、整篇文档）时，把那几万字原样塞进
  /// 上下文既贵又挤。所以输入框里超过阈值的长文本会**自动存进变量库**，
  /// 发给模型的是 `{{名字}}` 这个引用（见 `buildApiMessages`），
  /// 模型需要时自己展开或按范围取。
  ///
  /// [content] 仍然保留**用户原文** —— 界面显示的就是它（折叠成
  /// "已存入变量库 / 点击查看"），用户随时能核对"我到底存了什么"。
  ///
  /// 空列表 = 这条消息没有走变量库（普通短消息）。
  List<String> varRefs;

  /// 思维链（`reasoning_content`）。
  ///
  /// **必须在多轮里原样回传**：DeepSeek 文档明确规定，请求一旦携带 `tools`，
  /// 历史轮次的 reasoning_content 都要回传，否则 API 返回 400。
  /// 所以它不能只当展示用的临时数据，得跟着会话一起持久化。
  String reasoning;

  final List<ToolInvocation> tools;
  final List<Attachment> attachments;

  /// 这条回复**参考过的网页**（消息底部那行「来源」小字）。
  ///
  /// 由 agent 在执行完 `web` / `browser` 工具之后从它们的输出里挑出来，
  /// 最多 6 条、按出现顺序（搜索结果本来就是按相关度排的）。
  ///
  /// 为什么挂在**消息**上而不是全局日志：来源是"这条回答的依据"，
  /// 隔天回看时要能和那段结论对上号。
  List<String> sources;
  final DateTime createdAt;

  /// 正在流式输出
  bool pending;
  String? error;

  /// **这条回复是群聊里哪位参与者说的**（存的是成员当时的展示名）。
  ///
  /// ## 为什么是名字，不是成员 id
  ///
  /// 署名要回答的是"这句话当时是谁说的"—— 那是个**既成事实**。
  /// 成员后来被改名或删掉之后，id 指不到任何东西，历史里就会出现
  /// 一堆没有署名的旧回复；而名字仍然读得通。
  ///
  /// 代价是改过名之后，旧回复显示的是旧名字。那是诚实的：当时确实是
  /// 那个名字在说话。
  ///
  /// 单人对话为 null（绝大多数消息都是），老存档里没有这个字段也是 null，
  /// 所以不需要任何迁移。
  String? speaker;

  /// **后台/实时回合**：消息参与模型上下文，但**不画在聊天记录里**。
  ///
  /// 互动面板的每次点击都要让 AI 立刻做一步（落子、更新状态），
  /// 但那些事件是"工作流里的一拍"，不是用户发的消息 —— 显示出来会
  /// 把聊天刷满「【互动面板事件】…」，用户也就看不清真正的对话了。
  ///
  /// 所以：隐藏消息照常进 [buildApiMessages]（AI 才能接上上一手棋），
  /// UI 渲染、工具汇总和会话预览都跳过它。
  final bool hidden;

  /// **思考用了多久**（毫秒）。0 = 没有思考 / 还没测出来。
  ///
  /// 为什么值得单独存一个数：思维链本身可能几千字，用户真正想看的是
  /// "它想了多久"这个**代价指标** —— 用来决定下次要不要把思考深度调低、
  /// 或者干脆关掉。原来完全看不到。
  ///
  /// 口径：从**收到第一个 reasoning 分片**到**收到第一个正文分片**
  /// （或流结束）。不从请求发出算起 —— 那里面还含建连和排队的时间，
  /// 那不是"思考"。
  int reasoningMs = 0;

  /// 思考深度标签（"深（默认）"这类）。空 = 不显示。
  ///
  /// 存下来是因为**深度是这次回答发生的条件之一**：隔天回头看一个
  /// 很好的回答，想知道"当时是不是开了最深"，没有这个就只能猜。
  String reasoningLevel = '';

  bool get isEmptyAssistant =>
      role == Role.assistant && content.trim().isEmpty && tools.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'role': role.name,
    'content': content,
    'reasoning': reasoning,
    'reasoningMs': reasoningMs,
    'reasoningLevel': reasoningLevel,
    'marks': TextMark.encodeList(marks),
    'quote': quote?.toJson(),
    'improvedPrompt': improvedPrompt,
    'mentionContext': mentionContext,
    'varRefs': varRefs,
    'tools': tools.map((ToolInvocation t) => t.toJson()).toList(),
    'attachments': attachments.map((Attachment a) => a.toJson()).toList(),
    'sources': sources,
    'createdAt': createdAt.toIso8601String(),
    'error': error,
    'speaker': speaker,
    'hidden': hidden,
  };

  static ChatMessage fromJson(Map<String, dynamic> j) {
    // 老消息里的 `think…` 在**读入时**就拆开：那些回复是在修这个 bug
    // 之前存的，正文里混着整段思考。不修的话只能靠"让用户重新问一遍"。
    final ThinkSplit ts = splitThinkTags(j['content']?.toString() ?? '');
    final String oldReasoning = j['reasoning']?.toString() ?? '';
    return ChatMessage(
      id:
          j['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      role: Role.values.firstWhere(
        (Role e) => e.name == j['role'],
        orElse: () => Role.assistant,
      ),
      content: ts.content,
      reasoning: <String>[
        oldReasoning,
        ts.reasoning,
      ].where((String s) => s.trim().isNotEmpty).join('\n\n'),
      reasoningMs: (j['reasoningMs'] as num?)?.toInt() ?? 0,
      reasoningLevel: j['reasoningLevel']?.toString() ?? '',
      marks: TextMark.decodeList(j['marks']),
      quote: MessageQuote.fromJson(j['quote']),
      improvedPrompt: j['improvedPrompt']?.toString(),
      mentionContext: j['mentionContext']?.toString(),
      varRefs: ((j['varRefs'] as List<dynamic>?) ?? <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(),
      tools: ((j['tools'] as List<dynamic>?) ?? <dynamic>[])
          .map(
            (dynamic e) =>
                ToolInvocation.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
      attachments: ((j['attachments'] as List<dynamic>?) ?? <dynamic>[])
          .map(
            (dynamic e) =>
                Attachment.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
      sources: ((j['sources'] as List<dynamic>?) ?? <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(),
      createdAt:
          DateTime.tryParse(j['createdAt']?.toString() ?? '') ?? DateTime.now(),
      error: j['error']?.toString(),
      // 空串按"没有署名"处理：手改过的存档 / 别处写进来的半截数据
      // 会留下 `""`，而 UI 判断的是"有没有名字"，空串会渲染成一个空格子。
      speaker: (j['speaker']?.toString().trim().isEmpty ?? true)
          ? null
          : j['speaker']!.toString(),
      hidden: j['hidden'] == true,
    );
  }
}

/// 一个会话（历史记录持久化的单位）
class Conversation {
  Conversation({
    required this.id,
    required this.title,
    List<ChatMessage>? messages,
    DateTime? updatedAt,
    this.pinned = false,
  }) : messages = messages ?? <ChatMessage>[],
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String title;
  final List<ChatMessage> messages;
  DateTime updatedAt;

  /// **置顶**：这条会话永远排在历史列表最前面，不参与"按最近更新"的排序。
  ///
  /// 为什么需要它：历史会越积越长，而其中有那么两三条是**常用**的
  /// （正在跟进的那件事、长期在用的那个）。没有置顶的话，它们每天被
  /// 新对话往下挤，用户只能靠翻。
  bool pinned;

  /// 这一条是不是**还没写过东西的空白页**。
  ///
  /// 「空白页不参与历史记录」这条规矩只认这一个判断，所以它必须在
  /// 所有地方一致：
  ///  · 一条消息都没有（`messages` 空）；
  ///  · 名字还是占位名「新对话」（改过名 = 用户**故意**留着它，算数）；
  ///  · 没被置顶（置顶是明确的"我要它在这儿"）。
  /// 三者缺一不可 —— 只看 `messages.isEmpty` 的话，用户改过名/置顶过的
  /// 空会话会连名字一起消失，那是丢数据。
  /// 空白页 = 没有**可见**消息。静默的互动回合不算：开一局棋、
  /// 还没打字就关掉，不该在历史里留下一条「新对话」。
  bool get isBlank =>
      messages.every((ChatMessage m) => m.hidden) &&
      !pinned &&
      title.trim() == defaultTitle;

  /// 占位名。新建的会话都用它，改过名之后就不再相等（见 [isBlank]）。
  static const String defaultTitle = '新对话';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'messages': messages.map((ChatMessage m) => m.toJson()).toList(),
    'updatedAt': updatedAt.toIso8601String(),
    'pinned': pinned,
  };

  static Conversation fromJson(Map<String, dynamic> j) => Conversation(
    id: j['id']?.toString() ?? '',
    title: j['title']?.toString() ?? defaultTitle,
    messages: ((j['messages'] as List<dynamic>?) ?? <dynamic>[])
        .map(
          (dynamic e) =>
              ChatMessage.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList(),
    updatedAt:
        DateTime.tryParse(j['updatedAt']?.toString() ?? '') ?? DateTime.now(),
    // 老存档没有这个字段 → false。默认 false 是对的：置顶是用户
    // 明确做过的动作，不该由一次升级替他"猜"出来。
    pinned: j['pinned'] as bool? ?? false,
  );

  String encode() => jsonEncode(toJson());
}
