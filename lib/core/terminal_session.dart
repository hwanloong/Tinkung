import 'package:flutter/foundation.dart';

import 'linux.dart';

/// 一条命令跑在哪条通道上。
///
/// 现在只剩应用自带的 Alpine（proot）一条。保留这个枚举是为了让
/// 终端流水/UI 的形状不变，以后若要接别的通道也不必改动数据结构。
enum ShellBackend {
  /// **自带的 Alpine**（proot）。零配置、支持 stdin。
  builtin,
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

/// 命令执行结果。
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
/// 所有命令都跑在应用自带的 Alpine 里（见 [LinuxService]）：
/// 用户零配置，支持 stdin，用自带的静态 `apk` 装包。
///
/// ## 输出为什么不是"流式"的
///
/// 命令结束后拿到完整输出，不是逐行滚动。对绝大多数命令足够；
/// 真要看长任务的实时输出时再把 stdout 做成 EventChannel。
class TerminalSession extends ChangeNotifier {
  TerminalSession._();

  static final TerminalSession instance = TerminalSession._();

  /// 实际会用哪条。现在恒为自带的 Alpine。
  ShellBackend get active => ShellBackend.builtin;

  final List<TerminalEntry> _entries = <TerminalEntry>[];
  List<TerminalEntry> get entries => List<TerminalEntry>.unmodifiable(_entries);

  TerminalEntry? _current;
  TerminalEntry? get current => _current;
  bool get busy => _current != null;

  /// 当前命令的简短描述，给聊天页显示 `Alpine Running xxx`。
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
  /// 由 Linux 工具调用 —— 这样**模型跑的命令**和**用户手敲的命令**
  /// 会进同一条流水，用户在一个地方就能看全。
  Future<ShellResult> run(
    String command, {
    String? workdir,
    bool background = false,
    Duration timeout = const Duration(seconds: 60),
    String? stdin,
    List<String> extraBinds = const <String>[],
  }) async {
    final TerminalEntry entry = TerminalEntry(
      command: command,
      startedAt: DateTime.now(),
      backend: ShellBackend.builtin,
    );
    _entries.insert(0, entry);
    // 别让流水无限长：终端页会一直开着，几百条之后渲染吃力，
    // 而且旧输出对用户也没用了。
    if (_entries.length > 200) _entries.removeRange(200, _entries.length);
    _current = entry;
    notifyListeners();

    final ShellResult r = await _runBuiltin(
      command,
      workdir,
      timeout,
      stdin,
      background: background,
      extraBinds: extraBinds,
    );

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
    // `background: true` 统一成"nohup + 日志"：立刻返回 PID，
    // 进程交给 proot 保留（见 keepAlive）。
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

  /// 清空流水（"清屏"）。
  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
