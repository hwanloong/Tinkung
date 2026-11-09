/// 判断一次工具调用是不是"在操作手机、并且可能把别的应用顶到前台"。
///
/// 悬浮窗只在这类任务里显示。普通任务（写代码、查资料、整理文件）
/// 即使用户切到后台，也不需要浮窗提醒 —— 那时候它只是遮挡。
bool isPhoneControlCall(String name, Map<String, dynamic> args) {
  if (name == 'ui_action' || name == 'draw_path') return true;
  if (name == 'app_manage') {
    final String action = args['action']?.toString() ?? '';
    return action == 'launch' || action == 'open';
  }
  if (name == 'run_shell') {
    final String cmd = (args['command']?.toString() ?? '').toLowerCase();
    return RegExp(r'(^|\s)(input|monkey)\s').hasMatch(cmd) ||
        RegExp(r'\bam\s+start\b').hasMatch(cmd);
  }
  return false;
}
