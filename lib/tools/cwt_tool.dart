import 'dart:io';

import '../core/models.dart';
import '../cwt/cwt_hub.dart';
import 'tool.dart';

/// ChangeWhatYouThink：让用户**在被修改的文件上直接框选**再描述要求。
///
/// ## 为什么需要它
///
/// "把第二段改短一点""把这页右下角那张图换成我们自己的"这类要求，
/// 用文字描述位置极容易错位。让用户拖一个框，位置就是确定的：
/// 归一化坐标 + 选中文字 + 局部截图，AI 拿到的是可核对的范围。
///
/// ## 流程
///
///  1. AI 调 `open`，传文件路径和一句目标；
///  2. App 打开预览与框选页；
///  3. 用户框多处、每处写要求；完成后这些要求变成输入框上方的
///     「修改请求」气泡；
///  4. **用户发送后**，修改请求才进对话，AI 再真正改文件。
///
/// 所以这个工具只负责"打开"，不负责"改"。不要在一个回合里反复调用它。
class ChangeWhatYouThinkTool extends AgentTool {
  const ChangeWhatYouThinkTool();

  @override
  String get name => 'change_think';

  @override
  String get title => 'ChangeWhatYouThink';

  @override
  String get description =>
      '让用户直接在文件上框选，再描述要改什么。\n'
      '**什么时候用**：用户要求修改 PPT / Word / Excel / PDF / 图片，'
      '且要改的是"某一块"而不是整篇重写时。\n'
      '用 `open` 传文件路径 + 一句目标；App 会打开预览和选框。\n'
      '用户框选并完成后，修改要求会出现在输入框上方，**等用户发送后**'
      '你才会收到具体的框选内容。所以调用后请停下等待，不要反复调用、'
      '也不要先猜着改。\n'
      '整篇重写、格式转换这类不需要精确位置的，直接按普通文件操作处理。\n'
      '**用户看到的预览**：PDF 逐页渲染；PPT 按幻灯片还原文字位置、图片、'
      '形状和表格；Word 保留标题/粗斜体/颜色/图片/表格；Excel 还原行列、'
      '列宽、底色、合并和数字格式。选框会附带页码/幻灯片/工作表位置和'
      '框内原文，按这些定位即可。\n'
      '**改 Office 的提示**：Word/Excel/PPT 本质是 zip + XML，用 python 的 '
      '`zipfile` 只改对应 XML 部件、保留其它内容，不要重新生成整份文件；'
      '图片修改用 `generate_image` 的 `edit_from`。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>['open'],
      },
      'path': <String, dynamic>{
        'type': 'string',
        'description': '要修改的本地文件绝对路径',
      },
      'brief': <String, dynamic>{
        'type': 'string',
        'description': '一句话目标（显示在选框页顶部），例如"把标题改短"',
      },
    },
    'required': <String>['action', 'path'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) =>
      const RiskAssessment(RiskLevel.safe, <String>[]);

  @override
  String summarize(Map<String, dynamic> args) => '打开修改选框：${args.str('path')}';

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String action = args.str('action');
    if (action != 'open') return '错误：只支持 action=open';
    final String path = args.str('path').trim();
    if (path.isEmpty) return '错误：需要文件路径';
    if (!await File(path).exists()) {
      return '文件不存在：$path';
    }
    final String convId = ctx.conversation.id.trim();
    if (convId.isEmpty) return '错误：当前对话没有 id，无法打开选框。';

    CwtHub.instance.open(
      CwtRequest(convId: convId, path: path, brief: args.str('brief').trim()),
    );
    return '已打开 ChangeWhatYouThink 选框页。\n'
        '等用户框选并发送修改请求；在收到那条消息之前不要改文件，也不要重复调用本工具。';
  }
}
