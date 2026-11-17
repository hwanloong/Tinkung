import '../core/garmin.dart';
import '../core/models.dart';
import 'tool.dart';

class GarminPushTool extends AgentTool {
  const GarminPushTool();

  static const int maxLength = 160;

  @override
  String get name => 'garmin_push';

  @override
  String get title => '推送到已绑定设备';

  @override
  String get description =>
      '把一条简短的纯文本消息推送到当前设备专属对话绑定的佳明设备。'
      '仅在用户明确要求发到手表，或回复手表发来的问题时调用。'
      '内容不超过 160 字，不要使用 Markdown。参数 text 为要显示在手表上的内容。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'text': <String, dynamic>{
        'type': 'string',
        'description': '简短、纯文本、不超过 160 字的手表消息',
      },
    },
    'required': <String>['text'],
    'additionalProperties': false,
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) =>
      const RiskAssessment(RiskLevel.caution, <String>['向当前对话对应的已绑定设备推送消息']);

  @override
  bool get autoApprove => true;

  @override
  String summarize(Map<String, dynamic> args) => '推送消息到当前绑定设备';

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final int? deviceId = int.tryParse(ctx.conversation.deviceId ?? '');
    if (deviceId == null) return '错误：此工具只能在设备专属对话中使用';
    final String text = plainText(args['text']?.toString() ?? '');
    if (text.isEmpty) return '错误：推送内容不能为空';
    if (text.length > maxLength) {
      return '错误：内容清理后有 ${text.length} 字，请精简到 $maxLength 字以内再调用';
    }
    try {
      final bool sent = await GarminBridge.instance.push(
        deviceId: deviceId,
        deviceName: ctx.conversation.title,
        text: text,
      );
      if (!sent) return '推送失败：手表未确认接收';
      return '${ctx.conversation.title} 已接收纯文本消息（${text.length} 字）';
    } catch (e) {
      return '推送失败：$e';
    }
  }

  /// 自动回推给手表用的文本：清理 Markdown，并截到手表适合显示的长度。
  ///
  /// 工具调用那一路限制 160 字，是让模型主动写短；自动回推的是模型
  /// 已经生成的完整回答，太短会丢信息，太长手表要翻很多页、BLE 也慢。
  static String watchText(String input, {int maxLength = 1200}) {
    final String text = plainText(input);
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength - 1)}…';
  }

  static String plainText(String input) {
    String text = input
        .replaceAll(RegExp(r'```[^\n]*\n?'), '')
        .replaceAll('```', '')
        .replaceAll(RegExp(r'!?\[([^\]]+)\]\([^)]+\)'), r'$1')
        .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '')
        .replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*\d+[.)]\s+', multiLine: true), '')
        .replaceAll(
          RegExp(
            r'^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$',
            multiLine: true,
          ),
          '',
        )
        .replaceAll(
          RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$', multiLine: true),
          '',
        )
        .replaceAll(RegExp(r'\*\*(.*?)\*\*|__(.*?)__'), r'$1$2')
        .replaceAll(RegExp(r'(?<!\*)\*(?!\*)(.*?)\*(?!\*)'), r'$1')
        .replaceAll(RegExp(r'(?<!_)_(?!_)(.*?)_(?!_)'), r'$1')
        .replaceAll(RegExp(r'~~(.*?)~~'), r'$1')
        .replaceAll(RegExp(r'`([^`]+)`'), r'$1')
        .replaceAll('|', '，')
        .replaceAll(RegExp(r'[ \t\r\n]+'), ' ')
        .trim();
    return text;
  }
}
