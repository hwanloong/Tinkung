import '../core/models.dart';
import '../core/python.dart';
import 'tool.dart';

/// Python 工具（跑在内置 Alpine 里）。
///
/// **这是整个应用能力最强的一个工具**：它让 agent 能写代码并**立刻运行验证**。
///
/// 没有它的时候，agent 只能把代码写给你，你自己去跑、自己看报错、自己回来告诉它；
/// 有了它，agent 能自己发现代码跑不通、自己改、再跑 —— 从"给建议"变成"交付"。
///
/// 和 `linux` 的分工：
/// · `python` 只管"跑一段 Python"：省掉 `cd /shared && python3 -` 的样板，
///   默认工作目录是 `/shared`，返回结构化的 traceback
/// · `linux` 是**完整的 shell**：装包、跑别的语言、串管道都用它
///
/// 两者共用同一个 Alpine 环境（同一个 `python3`），所以这里装过的包
/// 在 `linux` 里也看得见。
class PythonTool extends AgentTool {
  const PythonTool();

  @override
  String get name => 'python';

  @override
  String get title => 'Python';

  @override
  String get description =>
      '执行 Python 代码并拿到输出。解释器在内置 Alpine 里，'
      '**第一次运行会自动 `apk add python3`，不需要用户配置。**\n'
      '什么时候用：\n'
      '· 需要精确计算（大数、浮点、循环、统计）—— 别自己心算，写代码跑\n'
      '· 文本处理、正则、编码转换、JSON/CSV 整理\n'
      '· 写一段脚本验证某个想法对不对\n'
      '注意：\n'
      '· 默认工作目录是 `/shared`（手机文件管理器能看到这个目录）\n'
      '· **每次运行都是独立进程**：上一次定义的变量不会保留，'
      '所有代码要写成完整脚本（import 也每次都要写）\n'
      '· 需要第三方库时先用 `linux` 跑 `apk add py3-numpy py3-matplotlib` 之类，'
      '再回到这里 import；也可以用 `linux` 直接跑\n'
      '· 返回的是 print 出来的内容；末尾表达式不会自动回显，要打印它\n'
      '· 报错会带上完整的 traceback —— **仔细看它，它能告诉你哪一行错了**';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'code': <String, dynamic>{
        'type': 'string',
        'description': '要执行的 Python 代码。可以多行；每次都是独立进程。',
      },
    },
    'required': <String>['code'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    return PythonRisk.classify(args.str('code'));
  }

  /// **Python 不自动放行。**
  ///
  /// 以前它是自动执行的：那时解释器跑在应用进程里，碰不到系统级能力。
  /// 现在代码交给内置 Alpine 的 `python3`，能读写 `/shared`、联网、
  /// 起子进程 —— 和终端里敲命令是同一档风险，所以必须和 `linux` 一样
  /// 走确认流程。风险等级也照实报（见 [PythonRisk]）。
  @override
  bool get autoApprove => false;

  @override
  String summarize(Map<String, dynamic> args) {
    final String c = args.str('code').trim().replaceAll(RegExp(r'\s+'), ' ');
    return c.length > 140 ? '${c.substring(0, 140)}…' : c;
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final PythonService py = PythonService.instance;

    // 不可用时**也要给出可诊断的信息**，而不是一句"用不了"。
    if (!py.available && py.lastError != null) {
      return 'Python 暂时不可用：${py.lastError}\n\n'
          '它是内置 Alpine 里的 `python3`，首次使用会自动安装，'
          '所以常见原因只有两类：\n'
          '· Alpine 环境还没解压完 → 稍等几秒重试\n'
          '· 安装 python3 时没网 → 连上网后重试，'
          '或用 `linux` 手动跑 `apk add --no-cache python3`\n'
          '打开「设置 → Python 控制台」能看到最近一次的真实报错。';
    }

    final String code = args.str('code');
    if (code.trim().isEmpty) return '错误：缺少 code';

    final PyResult r = await py.run(code);

    if (r.ok) {
      final String out = r.output.trim();
      if (out.isEmpty) {
        // 空输出很常见（比如只做了赋值），但直接说"无输出"模型会以为出错了
        return '（执行成功，没有输出。如果想让结果可见，用 print(...) 打印它。）';
      }
      return clampOutput(out, max: 8000);
    }

    // 失败时把 traceback 原样给出去 —— 模型要靠它定位问题。
    // 前面加一行醒目的标记，避免它把报错当成正常输出继续往下推理。
    final StringBuffer sb = StringBuffer();
    sb.writeln('执行失败（${r.errorType ?? 'Exception'}）');
    if (r.output.trim().isNotEmpty) {
      sb.writeln('在报错前已产生的输出：');
      sb.writeln(r.output.trim());
      sb.writeln();
    }
    sb.write(clampOutput(r.error ?? '（没有错误详情）', max: 4000));
    return sb.toString();
  }
}

/// Python 代码的风险分级。
///
/// **这个工具和 `linux` 是同一档风险** —— 代码既然跑在 Alpine 里，
/// 它就能读写 /shared、能联网、能起子进程，和终端里敲命令没有本质区别。
///
/// 所以策略是**明显更保守**：
/// · 只读、纯计算 → 自动执行
/// · 任何文件写入 / 网络 / 子进程 → 需确认
/// · 删除、改系统、动态执行远程代码 → 危险
class PythonRisk {
  const PythonRisk._();

  /// 明确危险
  static final List<RegExp> _dangerous = <RegExp>[
    // 删文件、改权限
    RegExp(r'\b(os\.remove|os\.unlink|os\.rmdir|shutil\.rmtree)\b'),
    RegExp(r'\b(os\.chmod|os\.chown)\b'),
    // 动态执行外部代码 —— 和 shell 的 `curl | bash` 是同一类风险
    RegExp(r'\b(exec|eval)\s*\('),
    RegExp(r'\b__import__\s*\('),
    RegExp(r'\b(compile|globals|locals)\s*\('),
    RegExp(r'\bimportlib\b.*\bimport_module\b'),
    // 起子进程 / 系统调用
    RegExp(r'\b(subprocess|os\.system|os\.popen|os\.exec|pty\.spawn)\b'),
    RegExp(r'\b(ctypes|cffi)\b'),
    // 直接读写系统路径
    RegExp(r'open\s*\(\s*[\x27"]/(system|data|proc|sys|dev)'),
    // 起网络服务 / 反向 shell
    RegExp(r'\b(socket\.socket|bind\s*\(|listen\s*\()'),
  ];

  /// 会改变状态、需要确认
  static final List<RegExp> _caution = <RegExp>[
    // 文件写入
    RegExp(r'\bopen\s*\([^)]*[\x27"][wax]'),
    RegExp(r'\b(os\.mkdir|os\.makedirs|os\.rename|os\.replace|shutil\.)\b'),
    RegExp(r'\b(pathlib\.Path)[^\n]*\.(write_text|write_bytes|unlink|mkdir)'),
    // 网络请求
    RegExp(r'\b(requests|urllib|httpx|urlopen|urlretrieve)\b'),
    // 装包
    RegExp(r'\b(pip|subprocess\.check_call.*pip)\b'),
    // 大内存操作，可能把应用拖死
    RegExp(r'\b(numpy\.zeros|numpy\.ones|numpy\.empty)\s*\(\s*\d{7,}'),
  ];

  static RiskAssessment classify(String code) {
    final String c = code.trim();
    if (c.isEmpty) {
      return const RiskAssessment(RiskLevel.caution, <String>['空代码']);
    }

    // 危险模式先扫 —— 一旦命中直接判危险，不再往下看
    for (final RegExp re in _dangerous) {
      if (re.hasMatch(c)) {
        return RiskAssessment(RiskLevel.dangerous, <String>[
          '危险操作：${_short(c)}',
        ]);
      }
    }

    for (final RegExp re in _caution) {
      if (re.hasMatch(c)) {
        return RiskAssessment(RiskLevel.caution, <String>[
          '会改变状态或访问网络：${_short(c)}',
        ]);
      }
    }

    // 只读判定要比 shell 严得多：Python 里"没有明显副作用"不等于安全，
    // 所以只有**极窄**的纯表达式才放行，其余一律要确认。
    // 这不是保守过头 —— 这个工具能在应用进程里为所欲为，
    // 宁可多问一次，也不能让一段没看清的代码自动跑。
    final bool looksPure =
        !c.contains('import ') &&
        !c.contains('open(') &&
        !c.contains('=') && // 赋值也可能有副作用（属性 setter）
        RegExp(r'^[\s\d+\-*/%().,eE_\[\]:\x27"]+$').hasMatch(c);

    if (looksPure) return RiskAssessment.safe;

    return RiskAssessment(RiskLevel.caution, <String>['含代码执行：${_short(c)}']);
  }

  static String _short(String s) =>
      s.length > 60 ? '${s.substring(0, 60)}…' : s;
}
