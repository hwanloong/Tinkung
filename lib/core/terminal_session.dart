import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'linux.dart';
import 'sandbox_plugin.dart';
import 'termux.dart';

/// 一条命令在哪条通道上跑。
enum ShellBackend {
  /// **自带的 Alpine**（proot）。零配置、支持 stdin —— 默认走它。
  builtin,

  /// 用户装的 Termux。他可能在里面配好了自己的工具链。
  termux,

  /// 独立沙箱插件（Ubuntu + proot）。装好后由 Zeus 直接调用。
  sandbox,

  /// Android 16 系统 Linux Terminal（AVF）。只能打开系统界面，
  /// 没有跨 APK 命令接口。
  systemLinux,
}

/// 一次终端会话里的一条记录。
class TerminalEntry {
  TerminalEntry({
    required this.command,
    required this.startedAt,
    required this.backend,
    this.output = '',
    this.exitCode,
    this.error,
    this.running = true,
  });

  final String command;
  final DateTime startedAt;
  final ShellBackend backend;

  String output;
  DateTime? finishedAt;
  int? exitCode;
  String? error;
  bool running;

  Duration get elapsed => (finishedAt ?? DateTime.now()).difference(startedAt);

  bool get ok =>
      !running && error == null && (exitCode == 0 || exitCode == null);
}

/// 两条通道统一的结果形状 —— 终端页不用关心命令跑在哪。
class ShellResult {
  const ShellResult({
    required this.ok,
    required this.combined,
    this.exitCode = -1,
    this.error,
  });

  final bool ok;
  final String combined;
  final int exitCode;
  final String? error;
}

/// **终端会话**：记住谁在跑、跑过什么、输出是什么。
///
/// ## 两条通道，默认用自带的那条
///
/// | | 自带的 Alpine | Termux |
/// |---|---|---|
/// | 用户要做什么 | **什么都不用** | 装 Termux + 开 `allow-external-apps` |
/// | stdin | 支持 | 不支持 |
/// | 环境 | 空白 Alpine，用自带 `apk` 装包 | 用户自己配好的 |
///
/// 所以自动模式下：**自带环境装好了就用它**（前提条件已全部满足），
/// 否则落到 Termux。用户也能手动指定（见 [preferred]）。
///
/// ## 输出为什么不是"流式"的
///
/// 两条通道都是**命令结束后拿到完整输出**，不是逐行滚动。
/// 自带通道理论上能做流式（进程是我们起的），但那要把 stdout 做成
/// EventChannel 持续推送；等真需要看长任务的实时输出时再做，
/// 现在"跑完给结果"对绝大多数命令足够。
class TerminalSession extends ChangeNotifier {
  TerminalSession._();

  static final TerminalSession instance = TerminalSession._();

  /// 用户手动指定的通道。`null` = 自动。
  ShellBackend? _preferred;
  ShellBackend? get preferred => _preferred;

  set preferred(ShellBackend? b) {
    _preferred = b;
    SharedPreferences.getInstance().then((SharedPreferences p) {
      if (b == null) {
        p.remove('terminalBackend');
      } else {
        p.setString('terminalBackend', b.name);
      }
    });
    notifyListeners();
  }

  /// 启动时恢复上次选择的运行环境。
  Future<void> loadPreferred() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final String raw = p.getString('terminalBackend') ?? '';
    if (raw.isEmpty) return;
    for (final ShellBackend b in ShellBackend.values) {
      if (b.name == raw) {
        _preferred = b;
        notifyListeners();
        return;
      }
    }
  }

  /// 实际会用哪条。
  ShellBackend get active {
    final ShellBackend? p = _preferred;
    if (p != null) return p;
    return LinuxService.instance.installed
        ? ShellBackend.builtin
        : ShellBackend.termux;
  }

  final List<TerminalEntry> _entries = <TerminalEntry>[];
  List<TerminalEntry> get entries => List<TerminalEntry>.unmodifiable(_entries);

  TerminalEntry? _current;
  TerminalEntry? get current => _current;
  bool get busy => _current != null;

  /// 当前命令的简短描述，给聊天页显示 `Termux Running xxx`。
  String get runningLabel {
    final TerminalEntry? e = _current;
    return e == null ? '' : _short(e.command);
  }

  static String _short(String cmd) {
    final String one = cmd.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 42 ? '${one.substring(0, 42)}…' : one;
  }

  /// 只在测试里用：塞一条"正在跑"的假流水。
  ///
  /// 为什么需要它：聊天页输入框上方那一行在"浏览器和终端**同时**在忙"
  /// 时会变成另一句话（见 ChatPage._activityRow），而那是最容易写错、
  /// 又最不容易被看见的一种状态 —— 没有这个钩子就没法出图核对。
  @visibleForTesting
  void debugSetRunning(String command) {
    _current = TerminalEntry(
      command: command,
      startedAt: DateTime.now(),
      backend: ShellBackend.builtin,
    );
    notifyListeners();
  }

  /// 清掉"正在跑"（测试里用来收场）。
  @visibleForTesting
  void debugClearRunning() {
    _current = null;
    notifyListeners();
  }

  /// 跑一条命令并记进流水。
  ///
  /// 由 `TermuxTool` / Linux 工具调用 —— 这样**模型跑的命令**和
  /// **用户手敲的命令**会进同一条流水，用户在一个地方就能看全。
  Future<ShellResult> run(
    String command, {
    String? workdir,
    bool background = false,
    Duration timeout = const Duration(seconds: 60),
    String? stdin,
    List<String> extraBinds = const <String>[],
  }) async {
    final ShellBackend b = active;
    final TerminalEntry entry = TerminalEntry(
      command: command,
      startedAt: DateTime.now(),
      backend: b,
    );
    _entries.insert(0, entry);
    // 别让流水无限长：终端页会一直开着，几百条之后渲染吃力，
    // 而且旧输出对用户也没用了。
    if (_entries.length > 200) _entries.removeRange(200, _entries.length);
    _current = entry;
    notifyListeners();

    final ShellResult r = switch (b) {
      ShellBackend.builtin => await _runBuiltin(
        command,
        workdir,
        timeout,
        stdin,
        background: background,
        extraBinds: extraBinds,
      ),
      ShellBackend.termux => await _runTermux(
        command,
        workdir,
        background,
        timeout,
      ),
      ShellBackend.sandbox => await _runSandbox(
        command,
        workdir,
        timeout,
        stdin,
      ),
      ShellBackend.systemLinux => const ShellResult(
        ok: false,
        combined: '',
        error:
            'Android 16 系统 Linux 由系统 Terminal 管理，'
            '没有公开命令接口；请点下面的「打开系统终端」手动操作。',
      ),
    };

    entry
      ..running = false
      ..finishedAt = DateTime.now()
      ..output = r.combined
      ..exitCode = r.exitCode
      ..error = r.ok ? null : (r.error ?? '执行失败');
    if (_current == entry) _current = null;
    notifyListeners();
    return r;
  }

  Future<ShellResult> _runBuiltin(
    String command,
    String? workdir,
    Duration timeout,
    String? stdin, {
    required bool background,
    required List<String> extraBinds,
  }) async {
    // `background: true` 原来只对 Termux 生效；内置 Alpine 会把命令
    // 当前台跑，直到超时才返回。这里统一成"nohup + 日志"：
    // 立刻返回 PID，进程交给 proot 保留（见 keepAlive）。
    if (background) {
      final String logDir = _backgroundLogDir(workdir);
      final String log =
          '$logDir/background-${DateTime.now().millisecondsSinceEpoch}.log';
      final String quoted = _shellQuote(command);
      final String wrapped =
          'nohup sh -c $quoted > "$log" 2>&1 & echo "PID:\$!"';
      final LinuxResult r = await LinuxService.instance.exec(
        wrapped,
        workdir: workdir,
        timeout: const Duration(seconds: 10),
        stdin: stdin,
        keepAlive: true,
        extraBinds: extraBinds,
      );
      final String out = r.stdout.trim();
      return ShellResult(
        ok: r.ok,
        combined: <String>[if (out.isNotEmpty) out, '日志：$log'].join('\n'),
        exitCode: r.exitCode,
        error: r.error,
      );
    }

    final LinuxResult r = await LinuxService.instance.exec(
      command,
      workdir: workdir,
      timeout: timeout,
      stdin: stdin,
      keepAlive: _looksLikeBackground(command),
      extraBinds: extraBinds,
    );
    return ShellResult(
      ok: r.ok,
      combined: r.combined,
      exitCode: r.exitCode,
      error: r.error,
    );
  }

  static String _backgroundLogDir(String? workdir) {
    if (workdir != null &&
        (workdir.startsWith('/storage') ||
            workdir.startsWith('/sdcard') ||
            workdir.startsWith('/data/user'))) {
      return workdir;
    }
    return '/shared';
  }

  /// 用单引号包住一整条命令，避免 `background` 包装时被外层 shell
  /// 提前展开变量/管道。
  static String _shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// 命令自己带了"后台/守护"语义时，proot 不能再用 `--kill-on-exit`
  /// 把它们一起收走（见 LinuxRuntime 的注释）。
  static bool _looksLikeBackground(String command) {
    final String c = command.trim();
    if (RegExp(r'(^|\s)nohup(\s|$)').hasMatch(c)) return true;
    if (RegExp(r'(^|\s)setsid(\s|$)').hasMatch(c)) return true;
    if (RegExp(r'(^|\s)start-stop-daemon(\s|$)').hasMatch(c)) return true;
    return RegExp(r'&\s*$').hasMatch(c);
  }

  Future<ShellResult> _runTermux(
    String command,
    String? workdir,
    bool background,
    Duration timeout,
  ) async {
    final TermuxResult r = await TermuxService.instance.run(
      command,
      workdir: workdir,
      background: background,
      timeout: timeout,
    );
    return ShellResult(
      ok: r.ok,
      combined: r.combined,
      exitCode: r.exitCode,
      error: r.error,
    );
  }

  Future<ShellResult> _runSandbox(
    String command,
    String? workdir,
    Duration timeout,
    String? stdin,
  ) async {
    final Map<dynamic, dynamic>? r = await SandboxPluginService.instance.exec(
      command: command,
      workdir: workdir,
      timeout: timeout,
      stdin: stdin,
    );
    if (r == null) {
      return const ShellResult(ok: false, combined: '', error: '独立沙箱插件还没安装');
    }
    final String out = r['stdout']?.toString().trim() ?? '';
    final String err = r['stderr']?.toString().trim() ?? '';
    final String combined = <String>[
      if (out.isNotEmpty) out,
      if (err.isNotEmpty) '[stderr]\n$err',
    ].join('\n');
    return ShellResult(
      ok: r['ok'] == true,
      combined: combined.isEmpty ? '（无输出）' : combined,
      exitCode: (r['exitCode'] as num?)?.toInt() ?? -1,
      error: r['error']?.toString(),
    );
  }

  /// 清空流水（"清屏"）。
  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
