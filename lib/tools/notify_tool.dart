import '../core/models.dart';
import '../core/notify_hub.dart';
import 'tool.dart';

/// **提醒用户**：模型把一件事说给"此刻可能没在看屏幕的人"。
///
/// ## 为什么需要它
///
/// 常驻 / 定时任务跑完一件事时，用户通常不在应用里。模型在会话里
/// 写一段结论 —— 没人看见。而它自己不知道"用户此刻在不在看"。
///
/// 这个工具把判断收归系统：前台就只标红点，后台额外发系统通知。
/// 模型只需要说清"要提醒什么"。
///
/// ## 固定性
///
/// 它是内置工具，和 `request_unlock` 一样：
/// · 没有文件夹、删不掉；
/// · 不进 `FolderToolStore`，所以 **@ 不出来**（@ 面板只列文件夹工具）；
/// · 在工具页里以「固定」角标出现。
class NotifyTool extends AgentTool {
  const NotifyTool();

  @override
  String get name => 'notify_user';

  @override
  String get title => '提醒用户';

  @override
  String get description =>
      '把一条**重要的**提醒推给用户。用于：定时/常驻任务跑完、'
      '长时间任务结束、发现了需要人立刻知道的事。\n'
      '参数：\n'
      '· `title` —— 一行标题（不超过 20 字）\n'
      '· `body` —— 具体内容，一到三句话，说清"发生了什么、要用户做什么"\n'
      '\n'
      '前台/后台由系统判断，不要自己猜：\n'
      '· 前台 → 内容进当前会话 + 历史列表标红点，不发系统通知；\n'
      '· 后台 → 额外发一条系统通知（用户能收到）。\n'
      '\n'
      '**不要滥用**：常规回复不需要它 —— 用户就在看着。'
      '只有"这条消息需要在他离开时也送达"时才调用。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'title': <String, dynamic>{
        'type': 'string',
        'description': '一行标题，如「抓到了 3 封新邮件」',
      },
      'body': <String, dynamic>{'type': 'string', 'description': '具体内容，1~3 句'},
    },
    'required': <String>['title', 'body'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) => '提醒用户：${args.str('title')}';

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String title = args.str('title').trim();
    final String body = args.str('body').trim();
    if (body.isEmpty) return '失败：body 不能为空';

    // 归属哪个会话：能从参数拿就从参数拿，否则用当前会话。
    // 红点必须点在**对的**那一行上，否则用户会点进去发现没事。
    final String convId = args.str('convId').trim().isNotEmpty
        ? args.str('convId').trim()
        : ctx.conversation.id;

    return NotifyHub.instance.push(
      title: title.isEmpty ? '提醒' : title,
      body: body,
      convId: convId,
    );
  }
}
