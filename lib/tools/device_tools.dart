import 'dart:io';

import '../core/models.dart' show RiskAssessment;
import '../core/platform_files.dart';
import 'tool.dart';

/// 用系统默认应用打开一个文件。
///
/// ## 为什么这是个工具而不是纯 UI 行为
///
/// 用户在聊天里说"打开刚才那张图"、"把这个视频放一下"时，模型需要
/// **真的打开它**。如果只是把路径回给用户，他还得自己去文件管理器里
/// 一层层翻 —— 而那个路径在应用私有目录里，**文件管理器根本看不到**。
///
/// 所以这个工具的价值不只是省一次点击：它是这类文件**唯一**能被用户
/// 看到的途径。
class OpenFileTool extends AgentTool {
  const OpenFileTool();

  @override
  String get name => 'open_file';

  @override
  String get title => '打开文件';

  @override
  String get description =>
      '用系统里合适的应用打开一个文件（图片、视频、音频、PDF、文本等）。'
      '用户说"打开/看看/播放刚才那个文件"时用它。'
      '路径必须是真实存在的文件；生成出来的图片视频就在工作目录下。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'path': <String, dynamic>{
        'type': 'string',
        'description': '要打开的文件的**完整路径**',
      },
    },
    'required': <String>['path'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) =>
      '打开 ${clampOutput(args.str('path'), max: 60)}';

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String path = args.str('path').trim();
    if (path.isEmpty) return '打开失败：路径为空';

    // 先自己确认文件在不在。原生那边也会查一遍，但在这里拦掉能给出
    // 更准确的建议（比如"路径写错了，工作目录在 …"）。
    final File f = File(path);
    if (!await f.exists()) {
      return '打开失败：文件不存在 —— $path\n'
          '（工作目录是 ${ctx.workDir}，生成的图片在 images/ 下、'
          '视频在 videos/ 下。也可以先用 list_dir 看一下有什么。）';
    }

    final String? err = await PlatformFiles.open(path);
    if (err != null) return '打开失败：$err';
    return '已用系统默认应用打开：$path';
  }
}

/// 取当前定位。
///
/// ## 为什么先申请权限再取
///
/// 没有权限时原生侧只能返回"没有定位权限"，模型于是只能对用户说
/// "我拿不到位置" —— 而用户根本不知道差一步授权。
/// 这个工具在**第一次调用时就把系统权限对话框弹出来**，
/// 用户点一下就能继续，省掉一整轮"为什么不行 / 我该怎么弄"。
class LocationTool extends AgentTool {
  const LocationTool();

  @override
  String get name => 'get_location';

  @override
  String get title => '定位';

  @override
  String get description =>
      '获取设备当前所在位置的经纬度。'
      '用户问"我在哪""附近有什么""这附近哪家…"这类问题时用它，'
      '然后再配合联网搜索去查具体地点。'
      '第一次使用会弹出系统定位授权，需要用户同意。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{},
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) => '获取当前位置';

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    if (!await PlatformFiles.hasLocationPermission()) {
      final bool granted = await PlatformFiles.requestLocationPermission();
      if (!granted) {
        return '取定位失败：用户没有授予定位权限。\n'
            '（可以告诉用户到「系统设置 → 应用 → Zeus → 权限」里'
            '打开位置权限，然后重试。）';
      }
    }

    final LocationFix fix = await PlatformFiles.location();
    if (!fix.ok) return '取定位失败：${fix.error}';

    return '当前位置：${fix.describe()}\n\n'
        '接下来可以用 web_search 查"这附近…"来拿到具体地点。'
        '注意：只知道坐标是查不到店名的，必须联网搜。';
  }
}
