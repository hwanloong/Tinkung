import '../core/models.dart';
import '../core/text_marks.dart';
import '../theme/app_theme.dart' show AppSurface;
import '../ui/markdown.dart' show MarkdownView;
import 'tool.dart';

/// **标记原文**：让 agent 能给对话里的文字加荧光笔底色。
///
/// ## 为什么这件事该由 AI 做
///
/// 标记本来是"用户长按选中 → 选底色"的手动操作。但很多场景里，
/// **该被标出来的恰恰是模型自己** —— 它整理完一长段资料，最该看的是其中三行；
/// 它列出五个待办，其中两个有风险。让它顺手标出来，用户扫一眼就找到重点，
/// 不用自己在几十行里挑。
///
/// ## 定位方式与用户手动标记**完全一致**
///
/// 靠"文字 + 这是第几次出现"，而次数是在**渲染后的正文**上算的
/// （见 [MarkdownView.plainTextOf]）—— 创建和渲染必须用同一份文本，
/// 否则标记会飘到同一文字的另一处（那个坑用户报过两次）。
///
/// 找不到就**如实说找不到**，不硬标一段相近的：标错比不标更糟 ——
/// 用户会以为自己看错了。
class MarkTool extends AgentTool {
  const MarkTool();

  @override
  String get name => 'mark';

  @override
  String get title => '标记原文';

  @override
  String get description =>
      '给对话里的**原文**加荧光笔底色（也可以取消）。'
      '用来把长回答里的重点标出来 —— 用户扫一眼就能找到关键那几行。\n'
      '· 只能标**原文里真实出现过**的一段：`text` 必须逐字照抄，'
      '不能改写、也不能只给关键词\n'
      '· 同一个词出现多次时用 `occurrence` 说明是第几次（从 0 开始）\n'
      '· 默认从**最近**一条消息往前找；要标用户说过的话就传 `on: "user"`\n'
      '· 别滥用：一次回复里标 1~3 处最值得看的，满篇高亮等于没标\n'
      '· `action: "unmark"` 取消自己标过的那处';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'text': <String, dynamic>{
        'type': 'string',
        'description': '要标记的原文片段，**逐字照抄**（不改写、不省略）。',
      },
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>['mark', 'unmark'],
        'description': '默认 mark；unmark 取消同一处的标记。',
      },
      'color': <String, dynamic>{
        'type': 'string',
        'enum': <String>['yellow', 'green', 'blue', 'pink'],
        'description': '底色，默认 yellow。',
      },
      'on': <String, dynamic>{
        'type': 'string',
        'enum': <String>['auto', 'user', 'assistant'],
        'description':
            '在哪一侧找：auto（默认，从最近一条往前）、'
            'user（只在用户说的话里）、assistant（只在 AI 回复里）。',
      },
      'occurrence': <String, dynamic>{
        'type': 'integer',
        'description': '这段文字在该条消息里是第几次出现（从 0 开始），默认 0。',
      },
    },
    'required': <String>['text'],
  };

  /// 只动对话里的显示数据，不碰系统、不碰文件。
  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) =>
      '${args.str('action') == 'unmark' ? '取消标记' : '标记'} '
      '${clampOutput(args.str('text'), max: 30)}';

  /// 该标哪条消息、以及在那条消息的**渲染后正文**上是第几次出现。
  ///
  /// 返回 null = 找不到（**不猜**）。抽成静态纯函数是为了能直接跑测试：
  /// 这段逻辑全是"按文字找位置"的边界（同一条消息里出现多次、内容里带
  /// markdown 语法、只说了半句），而它在工具里没法单独跑到。
  static ({ChatMessage message, int occurrence})? locate(
    List<ChatMessage> messages,
    String text, {
    String on = 'auto',
    int occurrence = -1,
  }) {
    final String needle = text.trim();
    if (needle.isEmpty) return null;

    for (int i = messages.length - 1; i >= 0; i--) {
      final ChatMessage m = messages[i];
      if (on == 'user' && m.role != Role.user) continue;
      if (on == 'assistant' && m.role != Role.assistant) continue;
      if (m.content.trim().isEmpty) continue;

      // 计数基准 = **渲染后的正文**（和渲染器一致）。样式参数不影响取出来的
      // 文字，所以传哪一份 AppSurface 都一样。
      final String plain;
      try {
        plain = MarkdownView.plainTextOf(m.content, AppSurface.light);
      } catch (_) {
        continue;
      }

      if (occurrence >= 0) {
        // 指定了次序：那条消息里得真有这么多处，否则继续往前找
        if (!_hasOccurrence(plain, needle, occurrence)) continue;
        return (message: m, occurrence: occurrence);
      }
      final int at = plain.indexOf(needle);
      if (at < 0) continue;
      return (message: m, occurrence: _countBefore(plain, needle, at));
    }
    return null;
  }

  static bool _hasOccurrence(String plain, String needle, int occ) {
    int from = 0;
    for (int n = 0; n <= occ; n++) {
      final int k = plain.indexOf(needle, from);
      if (k < 0) return false;
      from = k + needle.length;
    }
    return true;
  }

  static int _countBefore(String plain, String needle, int at) {
    if (at < 0) return 0;
    int occ = 0;
    int from = 0;
    while (true) {
      final int k = plain.indexOf(needle, from);
      if (k < 0 || k >= at) break;
      occ++;
      from = k + needle.length;
    }
    return occ;
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String text = args.str('text').trim();
    if (text.isEmpty) return '错误：缺少 text（要标记的原文片段）。';

    final List<ChatMessage> messages = ctx.conversation.messages;
    if (messages.isEmpty) return '这场对话里还没有内容可以标记。';

    final String on = args.str('on').trim().isEmpty
        ? 'auto'
        : args.str('on').trim();
    final int occ = args.intVal('occurrence', fallback: -1);
    final ({ChatMessage message, int occurrence})? hit = locate(
      messages,
      text,
      on: on,
      occurrence: occ,
    );

    if (hit == null) {
      // 找不到就如实说，并给一条能自救的路 —— 模型多半是把话改写过了。
      return '没有找到这段原文：`${clampOutput(text, max: 60)}`\n'
          '（`text` 必须**逐字照抄**原文里的片段。'
          '如果它在更早的消息里，用 `on: "user"` 或 `on: "assistant"` 限定一侧再试。）';
    }

    final bool unmark = args.str('action') == 'unmark';
    final MarkColor color = _colorById(args.str('color'));
    final ChatMessage m = hit.message;

    final TextMark place = TextMark(
      text: text,
      kind: MarkKind.mark,
      occurrence: hit.occurrence,
    );
    m.marks.removeWhere((TextMark x) => x.samePlaceAs(place));
    if (!unmark) m.marks.add(place.copyWith(color: color));

    final String where = m.role == Role.user ? '你说的话' : '我的回复';
    return unmark
        ? '已取消这段的标记（在$where里）。'
        : '已标记（在$where里，第 ${hit.occurrence + 1} 处）——'
              '用户现在能在对话里看到这块高亮。';
  }

  /// 按模型给的名字取底色；认不出来就用黄色（默认，也最不容易误读）。
  static MarkColor _colorById(String id) {
    final String want = id.trim().toLowerCase();
    for (final MarkColor c in MarkColor.values) {
      if (c.id == want) return c;
    }
    return MarkColor.yellow;
  }
}
