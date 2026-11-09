import 'dart:convert';

import '../core/models.dart';
import '../interaction/interaction_hub.dart';
import '../interaction/templates.dart';
import 'tool.dart';

/// 互动面板：需要问清楚、让用户选择、或者一起做一个活动时用。
///
/// ## 为什么不是普通的确认框
///
/// 确认框只能问"是/否"，也不能承载"教我下围棋"这种持续交互。
/// 这里给 AI 一整页 HTML：用户点击、拖拽、输入都通过 `App.send(...)`
/// 回到会话；AI 可以用 `act` 把 JS 命令发回页面（更新棋盘、换题、计时）。
///
/// ## 生命周期
///
/// · `open` 打开一个自定义 HTML 面板；
/// · `ask` 是快捷方式：问题 + 选项，自动生成按钮页面；
/// · `read` 读回用户的操作（面板关掉也会保留）；
/// · `act` 执行一段 JS；
/// · `close` 由用户点关闭或 AI 主动关。
///
/// ## 实时回合是**静默**的
///
/// 用户每点一下，聊天页会开一个**不进聊天记录**的短回合：事件只出现在
/// AI 的工作流里，AI 用 `act` 把结果写回页面。聊天区不会多出
/// 「【互动面板·实时】…」这种消息，用户也只会看到棋盘变化。
/// 关闭面板同样不发消息 —— 关闭就是关闭。
class InteractionTool extends AgentTool {
  const InteractionTool();

  @override
  String get name => 'interact';

  @override
  String get title => '互动面板';

  @override
  String get description =>
      '打开一个可交互的面板（HTML），用于问清楚、让用户选择、或一起进行活动。\n'
      '**什么时候用**：\n'
      '· 需要用户补充信息 / 在几个方案里选一个 → 用 `ask`（问题 + 选项）；\n'
      '· 需要用户实际操作（下棋、画图、拖动、打点）→ 用 `open` 写一页 HTML；\n'
      '· **围棋 / 井字棋 / 象棋 / 敲木鱼 / 抽奖** → 用 `play` + `game` 直接套模板。'
      '这些需求反复出现，模板已把界面、点击、App.send 和 AI 操作接口写好，'
      '不要每次重画。抽奖用 `game:"lottery"`：用户点一下就有结果并自动回传，'
      '不需要他再打字告诉你。\n'
      '**页面里怎么把数据给你**：调用 `App.send({...})`。**任何需要用户操作的地方'
      '都必须接上它**（点击、选择、抽奖、提交都一样），让结果自动回来；'
      '不要让用户"操作完再打字告诉你结果"。事件会进入面板记录；'
      '默认还会**实时触发一个很短的静默回合**（用户点一下，你就收到一次，'
      '但不会作为聊天消息显示），你马上用 `act` 回应 —— 这就是"你一步、我一步"的接口。\n'
      '**实时回合里只做一件事**：调用 `act`。不要输出解释文字（用户看不到也不该看到），'
      '不要 `open`/`play` 重开面板（会重新加载 WebView、清掉用户刚做的操作）。\n'
      '**你怎么操作页面**：调用 `act` 传一段 JS，**它会在页面里直接执行**，'
      '例如 `window.board.update(...)`。页面把方法挂到 `window` 上即可；'
      '不需要写 `App.onCommand`，也没有额外的命令协议。\n'
      '**你是参与者，不是旁观者**：用户每一次点击 / 落子 / 敲击，就是**你的回合**，'
      '要立刻用 `act` 操作页面，而不是只回一句"好的"。你也可以主动操作'
      '（开局先手、重开、提示、动画），不用等用户说"轮到你了"。\n'
      '**关闭策略**：`ask` 选择面板在用户选完后默认**自动关闭**（可传 '
      '`auto_close: false` 让用户多选/继续追问）；`open` / `play` 面板'
      '**默认保持打开**，只有用户明确说"结束/收起"时才调用 `close`。\n'
      '**什么时候关掉实时**：一次性问卷 / 只是收集几个字段时传 `auto_react: false`，'
      '避免每填一格都叫一次模型。\n'
      '**注意**：页面收到 `act` 后不要再用 `App.send` 回传同一次更新，否则会形成循环；'
      '用户主动操作才发事件。\n'
      '**用户关闭面板后**不会收到任何消息，也不需要你收尾：关闭就是结束。\n'
      '面板支持完整 HTML/CSS/JS，和浏览器同源能力；不要放需要登录的外部地址。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>['ask', 'open', 'play', 'read', 'act', 'close'],
      },
      'title': <String, dynamic>{
        'type': 'string',
        'description': '面板标题（open / ask）',
      },
      'question': <String, dynamic>{
        'type': 'string',
        'description': 'ask 时的问题',
      },
      'options': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{'type': 'string'},
        'description': 'ask 时的选项（2–6 个）',
      },
      'html': <String, dynamic>{
        'type': 'string',
        'description': 'open 时的整页 HTML；通过 App.send 回传事件',
      },
      'game': <String, dynamic>{
        'type': 'string',
        'enum': InteractionTemplates.games,
        'description': 'play 时的内置模板：tictactoe / go / xiangqi / muyu',
      },
      'id': <String, dynamic>{
        'type': 'string',
        'description': 'read / act / close 时的面板 id；不填用当前聊天最新的面板',
      },
      'js': <String, dynamic>{
        'type': 'string',
        'description': 'act 时要执行的 JavaScript',
      },
      'auto_react': <String, dynamic>{
        'type': 'boolean',
        'description':
            '用户每次操作是否实时触发一个短 AI 回合（默认 true）。'
            '一次性表单可设 false。',
      },
      'auto_close': <String, dynamic>{
        'type': 'boolean',
        'description':
            'ask 选择后是否自动关闭面板（默认 true）；'
            '需要多选/继续追问时设 false。open/play 不受它影响。',
      },
    },
    'required': <String>['action'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) =>
      const RiskAssessment(RiskLevel.safe, <String>[]);

  @override
  String summarize(Map<String, dynamic> args) {
    final String a = args.str('action');
    if (a == 'ask') return '互动选择：${args.str('question')}';
    if (a == 'open') return '打开互动面板：${args.str('title')}';
    return '互动面板 $a';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String action = args.str('action');
    final String convId = ctx.conversation.id.trim();
    if (convId.isEmpty) return '错误：当前对话没有 id，无法打开互动面板。';

    if (action == 'open') {
      final String html = args.str('html').trim();
      if (html.isEmpty) return '错误：open 需要 html';
      // ---- 已经开着就别重开 ----
      //
      // 重开会新建 session、WebView 从头加载：用户刚在页面上做的操作
      // （下的子、填的字）全部丢失。实时回合里只该用 act。
      final InteractionSession? live = InteractionHub.instance.forConv(convId);
      if (live != null && live.kind != 'ask') {
        if (live.html == html) {
          return '互动面板已经开着（id=${live.id}），内容一致，没有重新加载。\n'
              '要继续请用 action=act 执行 JS。';
        }
        return '当前已有互动面板（id=${live.id}）。**不要重开**——重开会重新加载页面，'
            '用户刚做的操作会丢。请用 action=act 更新它；确实要换一页，先 action=close。';
      }
      final InteractionSession s = InteractionHub.instance.open(
        convId: convId,
        title: args.str('title'),
        html: html,
        kind: 'open',
        autoReact: args.boolVal('auto_react', fallback: true),
      );
      return '已打开互动面板（id=${s.id}）。\n'
          '用户每次操作都会实时触发**你的回合**；需要时用 action=read 查看事件，'
          '用 action=act 执行 JS。你也可以在打开后立刻 act 初始化（主动先手/摆盘）。';
    }

    if (action == 'play') {
      final String game = args.str('game').trim().toLowerCase();
      if (!InteractionTemplates.games.contains(game)) {
        return '错误：game 只能是 ${InteractionTemplates.games.join(' / ')}';
      }
      final String title = switch (game) {
        'tictactoe' => '一起玩井字棋',
        'go' => '一起下围棋',
        'xiangqi' => '一起下象棋',
        'muyu' => '一起敲木鱼',
        'lottery' => '抽个奖',
        _ => '互动',
      };
      // 已经开着一局：同款模板保持原样，别的模板也先别换 ——
      // 换页 = WebView 重新加载 = 棋盘清零。实时回合里只该用 act。
      final InteractionSession? live = InteractionHub.instance.forConv(convId);
      if (live != null && live.kind != 'ask') {
        if (live.html == InteractionTemplates.html(game)) {
          return '「$title」已经开着（id=${live.id}），没有重新加载。\n'
              '${InteractionTemplates.apiHint(game)}\n'
              '直接用 action=act 走下一步；不要 open / play 重开。';
        }
        return '当前已有互动面板（id=${live.id}，${live.title}）。**不要重开**——'
            '重开会重新加载页面，棋盘会清零。请用 action=act；'
            '确实要换玩法，先 action=close 再 play。';
      }
      final bool react = InteractionTemplates.defaultAutoReact(game)
          ? args.boolVal('auto_react', fallback: true)
          : false;
      final InteractionSession s = InteractionHub.instance.open(
        convId: convId,
        title: args.str('title').isEmpty ? title : args.str('title'),
        html: InteractionTemplates.html(game),
        kind: 'play',
        autoReact: react,
      );
      if (game == 'muyu') {
        return '已打开「$title」模板（id=${s.id}）。\n'
            '敲击只在本地计数，**不会每一下都触发模型**；'
            '用户关闭面板时会收到一次汇总，到那时用一两句话收尾即可。';
      }
      return '已打开「$title」模板（id=${s.id}）。\n'
          '${InteractionTemplates.apiHint(game)}\n'
          '记住：用户每点一步就是你的回合，立刻 act 操作；'
          '你也可以主动开局/调整，不要只回文字。面板默认保持打开。';
    }

    if (action == 'ask') {
      final String q = args.str('question').trim();
      final List<String> options = args.listVal('options');
      if (q.isEmpty || options.length < 2) {
        return '错误：ask 需要 question 和至少两个 options';
      }
      final InteractionSession s = InteractionHub.instance.open(
        convId: convId,
        title: args.str('title').isEmpty ? '请选择' : args.str('title'),
        html: _askHtml(q, options),
        kind: 'ask',
        autoReact: args.boolVal('auto_react', fallback: true),
        autoCloseOnChoice: args.boolVal('auto_close', fallback: true),
      );
      return '已打开选择面板（id=${s.id}）。用户选完后会自动把结果发回来；'
          '你也可以用 read 主动查看。';
    }

    if (action == 'read') {
      final InteractionSession? s = _resolve(ctx, args.str('id'));
      if (s == null) return '当前没有互动面板。';
      return const JsonEncoder.withIndent('  ').convert(s.toReadPayload());
    }

    if (action == 'act') {
      final InteractionSession? s = _resolve(ctx, args.str('id'));
      if (s == null) return '当前没有互动面板。';
      final String js = args.str('js').trim();
      if (js.isEmpty) return '错误：act 需要 js';
      InteractionHub.instance.command(s.id, js);
      return '已把 JS 命令发给面板（id=${s.id}）。';
    }

    if (action == 'close') {
      final InteractionSession? s = _resolve(ctx, args.str('id'));
      if (s == null) return '当前没有互动面板。';
      InteractionHub.instance.close(s.id);
      return '已关闭互动面板（id=${s.id}）。';
    }

    return '错误：未知 action「$action」';
  }

  static InteractionSession? _resolve(ToolContext ctx, String id) {
    final InteractionHub hub = InteractionHub.instance;
    if (id.trim().isNotEmpty) return hub.byId(id.trim());
    return hub.forConv(ctx.conversation.id);
  }

  static String _askHtml(String question, List<String> options) {
    final StringBuffer buttons = StringBuffer();
    for (final String o in options) {
      buttons.writeln(
        '<button onclick=\'App.send(${jsonEncode(<String, dynamic>{'choice': o})})\'>'
        '${_escape(o)}</button>',
      );
    }
    return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>
  :root{color-scheme:light dark}
  body{margin:0;padding:22px 18px 28px;font:16px/1.6 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
    background:transparent;color:#16211D}
  @media (prefers-color-scheme:dark){body{color:#E9F0EC}}
  h2{font-size:18px;line-height:1.5;margin:0 0 16px;font-weight:600}
  .opts{display:flex;flex-direction:column;gap:10px}
  button{appearance:none;border:1px solid rgba(120,140,130,.35);border-radius:14px;
    padding:13px 14px;font:15px/1.4 inherit;background:rgba(220,235,226,.55);color:inherit;
    text-align:left;transition:transform .12s ease,background .12s ease}
  button:active{transform:scale(.985);background:rgba(31,75,63,.16)}
</style></head>
<body>
  <h2>${_escape(question)}</h2>
  <div class="opts">$buttons</div>
  <script>
    window.App = window.App || {};
    window.App.onCommand = window.App.onCommand || function(){};
  </script>
</body></html>''';
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}
