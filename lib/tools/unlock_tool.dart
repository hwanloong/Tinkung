import 'package:flutter/material.dart';

import '../core/app_nav.dart';
import '../core/models.dart';
import '../ui/lock_ui.dart';
import 'tool.dart';

/// **密码工具**：模型在执行危险操作前，请求用户亲自验证一次。
///
/// ## 为什么让模型自己决定要不要用
///
/// "危险"这件事应用判断不准：删一个临时文件不危险，但 `rm -rf ~` 是；
/// 读一次剪贴板不危险，但转账是。工具的**参数含义**只有模型知道，
/// 所以由它来判断"这一步该不该让人点头"，应用只负责**把门守住**。
///
/// ## 边界说明（重要）
///
/// 这是个**协作式**保险，不是强制闸门：
///  · 模型可以**不调用**它（提示里要求了危险操作必须先用，但那是约定不是机制）；
///  · 真正的强制在权限系统（见 `autoApproveAll` 与风险确认），
///    那一条不依赖模型是否老实。
///
/// 所以别把"安全"完全指望在这上面 —— 它的价值是"让用户看见模型想干什么"。
class UnlockTool extends AgentTool {
  const UnlockTool();

  @override
  String get name => 'request_unlock';

  @override
  String get title => '请求验证';

  @override
  String get description =>
      '在执行**危险或不可逆**的操作前，请用户亲自验证一次（密码 / 指纹 / 面部）。\n'
      '必须先用它、再动手的场景：删除或覆盖用户文件、清空数据、'
      '修改系统设置、发起支付或提交表单、批量发送消息、执行 '
      '`rm -rf` / `dd` / 格式化这类命令、读取剪贴板或隐私内容。\n'
      '参数 `reason` 要写清"要做什么、为什么"，它会原样显示给用户 —— '
      '写成技术黑话用户没法判断。\n'
      '返回「已通过」才继续；返回「用户拒绝」必须**立即停止**，不要再试别的路径绕过。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'reason': <String, dynamic>{
        'type': 'string',
        'description': '给用户看的一句话：要做什么、为什么',
      },
    },
    'required': <String>['reason'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) => '请求验证：${args.str('reason')}';

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String reason = args.str('reason').trim();
    if (reason.isEmpty) return '失败：reason 不能为空';

    final NavigatorState? nav = appNavigatorKey.currentState;
    final BuildContext? context = nav?.overlay?.context;
    if (context == null) {
      // 没有界面（后台任务、无头运行）—— 不能弹窗就别假装验证过。
      return '无法验证：当前没有可用界面（后台运行）。'
          '请改用非破坏性的做法，或提示用户手动确认。';
    }

    final bool? ok = await requestVerify(context, reason);
    if (ok == null) {
      // 没设密码 = 没有可验证的门。**这不是拒绝**。
      // 告诉模型"继续"，但说清楚为什么 —— 换台设了密码的设备上，
      // 同一个操作会被真的拦住，模型不该以为"验证形同虚设"。
      return '已放行：用户还没有设置应用密码，这里没有可验证的凭据。'
          '请继续，并在结果里如实说明这一步没有经过密码验证。';
    }
    return ok
        ? '已通过验证，可以继续。'
        : '用户拒绝或取消了验证。请立即停止，不要再尝试其它方式。';
  }
}
