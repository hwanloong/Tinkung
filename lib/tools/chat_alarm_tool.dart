import '../core/models.dart';
import 'tool.dart';

/// **风险告示**：在回复正文下面挂一条警告。
///
/// ## 它解决的是哪一类问题
///
/// 模型有能力说"这只是参考，请咨询医生"，但它倾向于把这句话写进正文
/// 的**最后一段** —— 而正文可能很长，用户读到操作步骤就开始动手了。
/// 见过太多"AI 说了一天三次，用户照做了"的案例，问题不在内容错，
/// 而在**警告和内容在同一个视觉层级**：一段和正文一样字号的灰字，
/// 扫过去就是半行。
///
/// 这个工具把警告从"正文里的半句话"变成**正文外面的一条独立色块**：
/// 带图标、带底边、在正文下面单独占一段。它不是内容的一部分，
/// 是内容之上的一层提示 —— 视觉上分得开，读的时候就不会漏。
///
/// ## 什么时候该调
///
/// 用户的风险来自"照着做会出问题"：
///  · **医疗**：用药剂量、症状判断、"我这样正常吗"；
///  · **法律**：合同条款、纠纷处理；
///  · **财务**：投资、借贷、税务；
///  · **安全**：拆装电器、高处作业、不明化学品；
///  · **自伤 / 心理危机**：这一类必须调，而且要 `danger`。
///
/// 反过来，**不要滥用**：查天气、写代码、翻译都不需要它。
/// 每条回复都挂一条"仅供参考"，用户就会当它不存在 ——
/// 那样等于没有。
class ChatAlarmTool extends AgentTool {
  const ChatAlarmTool();

  /// 工具名。**静态常量**，因为界面那边要按名字从 `message.tools`
  /// 里挑出告示调用 —— 那里没有工具实例，只有一个名字。
  static const String toolName = 'chat_alarm';

  @override
  String get name => toolName;

  @override
  String get title => '风险告示';

  @override
  String get description =>
      '在回复正文**下面**挂一条醒目的警告条。用于"用户照做可能出问题"的场景：\n'
      '· 医疗：用药、剂量、症状判断、"我这样正常吗"；\n'
      '· 法律：合同、纠纷、维权；\n'
      '· 财务：投资、借贷、税务；\n'
      '· 安全：拆装、高处、化学品、野外；\n'
      '· 心理 / 自伤风险 —— 必须用 `level: "danger"`。\n'
      '\n'
      '**警告条的作用是"别让用户漏看"**，所以它必须说人话、具体：\n'
      '· 好：「布洛芬成人每次 200~400mg，间隔不少于 6 小时；'
      '胃溃疡、孕晚期、肾功能不全者禁用。持续疼痛请就医。」\n'
      '· 差：「用药请遵医嘱」（说了等于没说）\n'
      '\n'
      '## 不要滥用\n'
      '\n'
      '查天气、写代码、翻译、闲聊**都不要调**。每条回复都挂警告，'
      '用户就会当它是背景噪声 —— 那样真正危险的那次也会被忽略。\n'
      '\n'
      '## 调用时机\n'
      '\n'
      '在**写正文之前**调（一次就够了）。正文里那句"建议咨询医生"'
      '可以写、也可以省掉 —— 这条告示已经说了。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'text': <String, dynamic>{
        'type': 'string',
        'description':
            '警告正文，一到三句。说清"风险是什么 + 应该怎么办"，'
            '不要写"仅供参考"这种空话。',
      },
      'level': <String, dynamic>{
        'type': 'string',
        'enum': <String>['info', 'warning', 'danger'],
        'description':
            '严重程度。info = 提醒（灰色），warning = 需要注意（橙色），'
            'danger = 有明确危险 / 涉及自伤（红色）。默认 warning。',
      },
      'title': <String, dynamic>{
        'type': 'string',
        'description': '标题行，默认按 level 取（"提示" / "注意" / "危险"）。',
      },
    },
    'required': <String>['text'],
  };

  /// 只是往界面上挂一条字，不动任何东西。
  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) {
    final String text = args.str('text').trim();
    return text.length <= 24 ? '风险告示：$text' : '风险告示：${text.substring(0, 24)}…';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String text = args.str('text').trim();
    if (text.isEmpty) return '失败：`text` 不能为空';

    // 这里**不往任何地方写** —— 告示是从 `ToolInvocation.args` 渲染的
    // （见 `MessageView._alarmCard`）。工具只负责"确认模型确实调了"，
    // 界面自己会去这条消息的 `tools` 里找 `chat_alarm`。
    //
    // 为什么不在工具里改消息：`run()` 拿到的是 `ctx.conversation`，
    // 而"这条回复"在调用时还没写完；把告示塞进消息会让它和正文的
    // 生命周期纠缠在一起（重试、重生成、编辑都要跟着清理）。
    // 挂在调用记录上就没这个问题：调用是从哪条消息发起的，
    // 告示就显示在哪条消息下面，天然跟着消息走。
    return '已挂上风险告示（用户会在你这段回复下面看到它）。'
        '正文里不必再重复一遍。';
  }
}
