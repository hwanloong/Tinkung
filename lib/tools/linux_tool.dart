import '../core/linux.dart';
import '../core/models.dart';
import '../core/terminal_session.dart';
import 'risk.dart';
import 'tool.dart';

/// Linux 工具：在应用自带的 Alpine 环境里执行命令。
///
/// 这是**完整的 Linux 用户空间**（busybox + apk 包管理），不是 Android
/// 的简版 toybox shell。agent 可以写脚本、真的跑起来、看懂报错、改完再跑。
class LinuxTool extends AgentTool {
  const LinuxTool();

  @override
  String get name => 'linux';

  @override
  String get title => 'Shell';

  @override
  String get description =>
      '在应用自带的 Alpine Linux 环境里执行命令。\n'
      '· 包管理用 **`apk`**（`apk add git curl ffmpeg …`），装过的东西会留着\n'
      '· 里面能跑 shell 脚本、git、编译、ffmpeg 等真正的 Linux 工具\n'
      '· 环境随应用自动安装，不需要用户额外装任何应用\n'
      '什么时候用它：需要标准 GNU 工具（`grep -P`、`sed -i` 扩展、'
      '完整 `tar`/`find`）、要编译、要装 Linux 程序，'
      '或者需要一个干净的 Linux 来复现问题。\n'
      '**文件位置**（很重要）：\n'
      '· 要产出给用户的东西一律写到 **`/shared`**（应用和外面的交换目录，'
      '用户能一键打开、也能发给别的应用）。写在 `/root`、`/tmp` 里的文件'
      '用户在文件管理器里**找不到** —— 那是应用私有目录；\n'
      '· 用户的文件在 `/sdcard` 下，**已经挂进来了**，可以直接读；\n'
      '注意：\n'
      '· 前台模式有超时（默认 60 秒）；长任务用 `background=true`，'
      '会自动 nohup 并写日志，返回里给 PID 和日志路径\n'
      '· 这台设备**没有 crond**；需要定时/定期的事用 `plan` 工具建计划树，'
      '不要写 crontab，也不要让脚本自己 `sleep 900` 常驻';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'command': <String, dynamic>{
        'type': 'string',
        'description': '要执行的命令。可以是一长串（用 && 串联），也可以先写个脚本再让它跑。',
      },
      'workdir': <String, dynamic>{
        'type': 'string',
        'description': '工作目录。默认 /root。要让产出能被用户拿到，写 /shared。',
      },
      'background': <String, dynamic>{
        'type': 'boolean',
        'description': 'true 时立即返回、不等结果（长任务用）。会自动 nohup 并给出日志路径。',
      },
      'timeout_sec': <String, dynamic>{
        'type': 'integer',
        'description': '前台模式等待秒数，默认 60，上限 300',
      },
    },
    'required': <String>['command'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    return LinuxRisk.classify(args.str('command'));
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String c = args.str('command').trim().replaceAll(RegExp(r'\s+'), ' ');
    final String short = c.length > 120 ? '${c.substring(0, 120)}…' : c;
    return args.boolVal('background', fallback: false) ? '[后台] $short' : short;
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String command = args.str('command');
    if (command.trim().isEmpty) return '错误：缺少 command';

    if (!LinuxService.instance.installed) {
      // 启动时已经在后台自动装；这里给它一次机会，装不上再让用户看终端页。
      final bool ok = await LinuxService.instance.ensureInstalled();
      if (!ok) {
        return '内置 Linux 环境还没装好（解压一次，几秒钟）。\n\n'
            '应用启动时会自动安装；如果一直失败，请到「设置 → 终端」查看原因。\n'
            '**不要反复重试这个工具**。';
      }
    }

    final bool background = args.boolVal('background', fallback: false);
    final int timeoutSec = args
        .intVal('timeout_sec', fallback: 60)
        .clamp(5, 300);

    // 走 **TerminalSession**：模型跑的命令会进终端页的流水，
    // 和用户手敲的命令排在一起。
    final ShellResult r = await TerminalSession.instance.run(
      command,
      workdir: args.str('workdir').trim().isEmpty
          ? null
          : args.str('workdir').trim(),
      background: background,
      timeout: Duration(seconds: timeoutSec),
    );

    if (!r.ok) {
      return '执行失败：${r.error ?? '未知原因'}\n'
          '${r.combined.trim().isEmpty ? '' : '\n输出：\n${clampOutput(r.combined, max: 3000)}'}';
    }

    if (background) {
      final String extra = r.combined.trim();
      if (extra.isEmpty) {
        return '已在后台启动。\n'
            '输出不会回传 —— 请把命令改成重定向到文件的形式，'
            '例如：`$command > /shared/job.log 2>&1`。\n'
            '然后用 `file_op` 的 read 去读它。';
      }
      return '已在后台启动。\n'
          '$extra\n'
          '之后用 `file_op` 的 read 读日志看进度。\n'
          '进程是否还能活着取决于应用有没有被系统回收。';
    }

    final String out = clampOutput(r.combined, max: 8000);
    final String head = r.exitCode == 0
        ? ''
        : '（退出码 ${r.exitCode} —— 命令没有成功执行）\n';
    return '$head$out';
  }
}

/// Alpine 命令的风险分级。
///
/// fail-safe：认不出来就要确认；`curl | sh` 这类从网上直接执行代码的
/// 一律按危险处理。
class LinuxRisk {
  const LinuxRisk._();

  /// 明确的只读命令 —— 只有这些能自动执行。
  static final List<RegExp> _safe = <RegExp>[
    RegExp(r'^\s*(ls|pwd|whoami|id|uname|date|which|type|env)\b'),
    RegExp(r'^\s*(cat|head|tail|wc|file|stat|du|df)\b'),
    RegExp(r'^\s*(grep|rg|find|fd|sort|uniq|cut|tr)\b'),
    RegExp(r'^\s*git\s+(status|log|diff|show|branch|remote|describe)\b'),
    RegExp(r'^\s*(python3?|node)\s+(-V|--version|-c\s+[\x27"]print)'),
    RegExp(r'^\s*apk\s+(list|info|search|policy)\b'),
    RegExp(r'^\s*(pip|npm|go|cargo)\s+(list|show|--version|-V)\b'),
    RegExp(r'^\s*echo\b'),
  ];

  /// 破坏性、不可撤销。
  static final List<RegExp> _dangerous = <RegExp>[
    // 从网上直接拉代码执行 —— 这是最危险的一类。
    RegExp(r'\b(curl|wget)\b[^|;]*\|\s*(sudo\s+)?(ba|z|d)?sh\b'),
    RegExp(r'\b(base64|eval|source)\b.*\|\s*(ba|z|d)?sh\b'),
    RegExp(r'\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+/'),
    RegExp(
      r'\brm\s+-[a-zA-Z]*[rf][a-zA-Z]*\s+(/sdcard|/storage|/data|\$HOME|~)\s*$',
    ),
    RegExp(r'\bmkfs|\bdd\s+if=|\bshred\b'),
    RegExp(r'\bchmod\s+(-R\s+)?777\s+/'),
    RegExp(r'\bsudo\b'),
    RegExp(r'>\s*/dev/block/'),
    RegExp(r'\b(reboot|poweroff|halt)\b'),
    RegExp(r':\(\)\s*\{.*\};\s*:'), // fork bomb
  ];

  /// 会改变状态但可逆 —— 需要确认。
  static final List<RegExp> _caution = <RegExp>[
    RegExp(r'\bapk\s+(add|del|update|upgrade|fix|fetch)\b'),
    RegExp(r'\b(pip|npm|yarn|pnpm)\s+(install|add|remove|uninstall)\b'),
    RegExp(r'\b(go|cargo)\s+(get|install|add|build|run)\b'),
    RegExp(r'\bgit\s+(clone|pull|push|fetch|checkout|reset|clean|commit)\b'),
    RegExp(r'\b(rm|mv|cp|mkdir|rmdir|touch|ln)\b'),
    RegExp(r'\b(make|cmake|ninja|gcc|clang|javac)\b'),
    RegExp(r'\bffmpeg\b|\bconvert\b|\bmagick\b'),
    RegExp(r'>\s*\S'), // 任何重定向写盘
    RegExp(r'\|\s*(tee|dd)\b'),
  ];

  static RiskAssessment classify(String rawCommand) {
    final String cmd = rawCommand.trim();
    if (cmd.isEmpty) {
      return const RiskAssessment(RiskLevel.caution, <String>['空命令']);
    }

    final List<String> segments = RiskClassifier.splitSegments(cmd);

    RiskLevel worst = RiskLevel.safe;
    final List<String> reasons = <String>[];

    for (final String seg in segments) {
      final String s = seg.trim();
      if (s.isEmpty) continue;

      for (final RegExp re in _dangerous) {
        if (re.hasMatch(s)) {
          return RiskAssessment(RiskLevel.dangerous, <String>[
            '危险命令：${_short(s)}',
          ]);
        }
      }

      if (worst == RiskLevel.safe) {
        bool cautionHit = false;
        for (final RegExp re in _caution) {
          if (re.hasMatch(s)) {
            cautionHit = true;
            break;
          }
        }
        if (cautionHit) {
          worst = RiskLevel.caution;
          reasons.add('会改变状态：${_short(s)}');
        }
      }

      // 白名单只在**单段**生效：命令被拆成多段时，
      // 只要有一段不匹配白名单，就整体不信任。
      if (worst == RiskLevel.safe) {
        bool safeHit = false;
        for (final RegExp re in _safe) {
          if (re.hasMatch(s)) {
            safeHit = true;
            break;
          }
        }
        if (!safeHit) {
          worst = RiskLevel.caution;
          reasons.add('无法确认为只读：${_short(s)}');
        }
      }
    }

    if (worst == RiskLevel.safe) {
      return RiskAssessment.safe;
    }
    if (reasons.isEmpty) {
      reasons.add('包含无法确认为只读的操作，请自行核对命令内容');
    }
    return RiskAssessment(worst, reasons);
  }

  static String _short(String s) =>
      s.length > 60 ? '${s.substring(0, 60)}…' : s;
}
