import '../core/linux.dart';
import '../core/models.dart';
import '../core/sandbox_plugin.dart';
import '../core/termux.dart';
import '../core/terminal_session.dart';
import 'risk.dart';
import 'tool.dart';

/// Termux 工具：在手机上执行真正的 Linux 命令。
///
/// 和 `run_shell`（Shizuku）的区别：
/// · `run_shell` 拿到的是 Android 的 shell（adb 权限），命令是 `pm` / `settings` 这类
/// · `termux` 拿到的是**一套完整的 Linux 用户空间** —— 有 python、node、git、
///   clang、ffmpeg，而且 `pkg install` 能装两千多个包
///
/// **真正的分水岭在于"能验证"**：agent 可以写一段脚本、真的跑起来、看懂报错、
/// 改完再跑。没有它的时候，agent 只能把代码写给你，你自己去跑。
class TermuxTool extends AgentTool {
  const TermuxTool();

  @override
  String get name => 'termux';

  @override
  String get title => 'Linux';

  @override
  String get description =>
      '在当前选择的 Linux 环境里执行命令（自带 Alpine / Termux / 独立 Ubuntu 沙箱）。'
      '这是完整的 Linux，'
      '不是 Android 的简版 shell。\n'
      '· 自带 Alpine 用 **`apk`**，独立 Ubuntu 沙箱用 **`apt`**，'
      'Termux 用 `pkg`；装过的东西会留着\n'
      '· 里面能跑 shell 脚本、git、编译、ffmpeg 等真正的 Linux 工具\n'
      '· Python 请优先用 `python` 工具（那个是常驻会话），'
      '在 Linux 里跑 python 适合"要和其它命令串起来"的场景\n'
      '什么时候用它：需要标准 GNU 工具（`grep -P`、`sed -i` 扩展、'
      '完整 `tar`/`find`）、要编译、要装 Linux 程序、'
      '或者需要一个干净的 Linux 来复现问题。\n'
      '**文件位置**（很重要）：\n'
      '· 要产出给用户的东西 → 写到 **`/shared`**（应用和外面的交换目录，'
      '用户能一键打开、也能发给别的应用）。写在 `/root`、`/tmp` 里的文件'
      '用户在文件管理器里**找不到** —— 那是应用私有目录；\n'
      '· 用户的文件在 `/sdcard` 下，**已经挂进来了**，可以直接读；\n'
      '注意：\n'
      '· 不需要用户装 Termux —— 环境就在应用内部，和手机系统是隔离的\n'
      '· 若返回"环境还没安装"，让用户去「设置 → 终端」点一下安装，'
      '**不要反复重试**\n'
      '· 前台模式有超时（默认 60 秒）；长任务用 background=true：'
      '内置 Alpine 会自动 nohup 并写日志，返回里会给 PID 和日志路径\n'
      '· 这台设备**没有 crond**；需要定时/定期的事用 `plan` 工具建计划树，'
      '不要写 crontab，也不要让脚本自己 `sleep 900` 常驻';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'command': <String, dynamic>{
        'type': 'string',
        'description':
            '要执行的命令。可以是一长串（用 && 串联），'
            '也可以先写个脚本再让它跑。',
      },
      'workdir': <String, dynamic>{
        'type': 'string',
        'description':
            '工作目录。默认 /root。要让产出能被用户拿到，'
            '用 /shared（详见工具说明里的"文件位置"）。',
      },
      'background': <String, dynamic>{
        'type': 'boolean',
        'description':
            'true 时立即返回、不等结果（长任务用）。'
            '内置 Alpine 会自动 nohup 并给出日志路径；Termux 通道仍建议'
            '自行重定向到文件。',
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
    return TermuxRisk.classify(args.str('command'));
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

    // 先说清"当前实际会用哪条通道"，再决定说什么话。
    //
    // 这里原来是个**错位的判断**：只查 Termux 应用装没装，没装就直接返回
    // "Termux 未安装，请去 F-Droid 装"。但这个应用**自带**一套 Alpine，
    // 根本不需要 Termux —— 于是内置环境装好了、系统提示词里也写着
    // "Linux 可用"，模型一调这个工具却被告知"去装 Termux"，
    // 用户照着装完还是没用。判断必须跟着**实际通道**走。
    final ShellBackend backend = TerminalSession.instance.active;

    if (backend == ShellBackend.builtin && !LinuxService.instance.installed) {
      return '内置 Linux 环境还没安装（解压一次，几秒钟）。\n\n'
          '请让用户去「设置 → 终端」点一下「安装并启用」，装完再重试。\n'
          '**不要反复重试这个工具**，也不要建议用户装 Termux —— '
          '这个应用自带 Linux，不需要 Termux。';
    }

    if (backend == ShellBackend.termux &&
        TermuxService.instance.status == TermuxStatus.notInstalled) {
      return '当前运行的通道是外接 Termux，但用户没装 Termux。\n\n'
          '可以改走自带的那条：让用户去「设置 → 终端」点「安装并启用」，'
          '或者在终端页把「运行环境」切成「自带 Alpine」。\n'
          '注意：Play 商店那版 Termux 已废弃，要装得从 F-Droid 装，'
          '装完还得在 Termux 里开一次 allow-external-apps。';
    }

    if (backend == ShellBackend.sandbox) {
      final SandboxPluginStatus s = await SandboxPluginService.instance
          .status();
      if (!s.installed) {
        return '当前运行环境是独立 Ubuntu 沙箱，但插件还没安装。\n\n'
            '让用户去「设置 → 终端 → 独立 Ubuntu 沙箱」点「安装插件」，'
            '装完在「运行环境」里选「独立沙箱」。';
      }
    }

    if (backend == ShellBackend.systemLinux) {
      return '当前运行环境是 Android 16 系统 Linux。它由系统 Terminal 的 AVF '
          '虚拟机管理，没有公开的跨应用命令接口，Zeus 无法代跑命令。\n\n'
          '请让用户打开「设置 → 终端」，在运行环境里选「系统 Linux」，'
          '再点「打开系统终端」手动操作；需要 agent 执行命令时改用'
          '「自带 Alpine」「独立沙箱」或「Termux」。';
    }

    final bool background = args.boolVal('background', fallback: false);
    final int timeoutSec = args
        .intVal('timeout_sec', fallback: 60)
        .clamp(5, 300);

    // 走 **TerminalSession** 而不是直接调 TermuxService：
    // 这样模型跑的命令会进终端页的流水，和用户手敲的命令**排在一起**。
    //
    // 这是"agent 动了我的系统，我想知道它干了什么"的关键 ——
    // 如果模型跑的命令不进流水，终端页就只是个玩具，
    // 用户仍然看不到 agent 真正执行过什么。
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
            '例如：`$command > /sdcard/dsh/job.log 2>&1`，'
            '然后用 `file_op` 的 read 去读它。';
      }
      return '已在后台启动。\n'
          '$extra\n'
          '之后用 `file_op` 的 read 读日志看进度；'
          '进程是否还能活着取决于应用有没有被系统回收。';
    }

    final String out = clampOutput(r.combined, max: 8000);
    // 退出码非 0 时明确标出来：模型需要知道"它失败了"，
    // 否则会把报错当成正常输出继续往下推理
    final String head = r.exitCode == 0
        ? ''
        : '（退出码 ${r.exitCode} —— 命令没有成功执行）\n';
    return '$head$out';
  }
}

/// Termux 命令的风险分级。
///
/// 和 Android shell 的分级**共用同一套思路**（fail-safe：认不出来就要确认），
/// 但白名单必须单独写 —— 两边的命令集合几乎不重叠。
///
/// 这条尤其重要：**Termux 能装包、能跑任意脚本**，
/// 所以 `curl … | bash` 这类必须按危险处理，不能让 agent 自动执行
/// 一段从网上拉下来的代码。
class TermuxRisk {
  const TermuxRisk._();

  /// 明确的只读命令 —— 只有这些能自动执行
  static final List<RegExp> _safe = <RegExp>[
    RegExp(r'^\s*(ls|pwd|whoami|id|uname|date|which|type|env)\b'),
    RegExp(r'^\s*(cat|head|tail|wc|file|stat|du|df)\b'),
    RegExp(r'^\s*(grep|rg|find|fd|sort|uniq|cut|tr)\b'),
    RegExp(r'^\s*git\s+(status|log|diff|show|branch|remote|describe)\b'),
    RegExp(r'^\s*(python3?|node)\s+(-V|--version|-c\s+[\x27"]print)'),
    RegExp(r'^\s*(pkg|apt)\s+(list|show|search)\b'),
    RegExp(r'^\s*(pip|npm|go|cargo)\s+(list|show|--version|-V)\b'),
    RegExp(r'^\s*echo\b'),
    RegExp(r'^\s*termux-\w+\s*$'),
  ];

  /// 破坏性、不可撤销
  static final List<RegExp> _dangerous = <RegExp>[
    // 从网上直接拉代码执行 —— Termux 场景下这是最危险的一类
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

  /// 会改变状态但可逆 —— 需要确认
  static final List<RegExp> _caution = <RegExp>[
    RegExp(r'\b(pkg|apt|apt-get)\s+(install|remove|upgrade|update|purge)\b'),
    RegExp(r'\b(pip|npm|yarn|pnpm)\s+(install|add|remove|uninstall)\b'),
    RegExp(r'\b(go|cargo)\s+(get|install|add|build|run)\b'),
    RegExp(r'\bgit\s+(clone|pull|push|fetch|checkout|reset|clean|commit)\b'),
    RegExp(r'\b(rm|mv|cp|mkdir|rmdir|touch|ln)\b'),
    RegExp(r'\b(make|cmake|ninja|gcc|clang|javac)\b'),
    RegExp(r'\bffmpeg\b|\bconvert\b|\bmagick\b'),
    RegExp(r'>\s*\S'), // 任何重定向写入
    RegExp(r'\|\s*(tee|dd)\b'),
  ];

  static RiskAssessment classify(String rawCommand) {
    final String cmd = rawCommand.trim();
    if (cmd.isEmpty) {
      return const RiskAssessment(RiskLevel.caution, <String>['空命令']);
    }

    // 引号感知切分 —— **直接复用 Android 那边的实现**，不另写一份。
    // 两边各写一份迟早会不一致，而这是安全相关的逻辑，
    // 不一致就意味着某一边能绕过。
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

      // 白名单只对**单段**生效：命令被拆成多段时，
      // 只要有一段不匹配白名单，就整体不信任
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
          reasons.add('无法确认只读：${_short(s)}');
        }
      }
    }

    if (worst == RiskLevel.safe) return RiskAssessment.safe;
    return RiskAssessment(worst, reasons.isEmpty ? <String>['需要确认'] : reasons);
  }

  static String _short(String s) =>
      s.length > 60 ? '${s.substring(0, 60)}…' : s;
}
