import 'dart:io';

import 'package:flutter/foundation.dart';

import 'linux.dart';

/// 一次 Python 执行的结果。
class PyResult {
  const PyResult({
    required this.ok,
    this.output = '',
    this.error,
    this.errorType,
  });

  final bool ok;

  /// print 出来的东西（stdout + stderr 合并）。
  final String output;

  /// 完整的 traceback。失败时才有。
  final String? error;

  /// 异常类型名（ZeroDivisionError 之类），给模型一个快速判断的抓手。
  final String? errorType;
}

/// 基于自带 Alpine 的 Python 服务。
///
/// 不再内嵌 Chaquopy：代码交给 Alpine 里的 `python3` 执行，缺解释器时
/// 自动 `apk add --no-cache python3`。这样 APK 不再背一个几十 MB 的
/// CPython，Python 和终端也共用同一套环境。
///
/// 注意：每次调用都是**独立进程**，变量不会在两次调用之间保留
/// （`reset` 参数因此保留但不再有意义）。
class PythonService extends ChangeNotifier {
  PythonService._();

  static final PythonService instance = PythonService._();

  bool _available = false;
  bool get available => _available;

  /// `python3 -V` 的输出，设置页用来确认解释器真的起来了。
  String? _version;
  String? get version => _version;

  /// 最近一次失败原因。
  String? _lastError;
  String? get lastError => _lastError;

  /// 已装的 Python 相关包（懒加载）。
  List<String>? _packages;
  List<String>? get packages => _packages;

  /// 探测解释器在不在。
  ///
  /// 不会主动装包（那可能触发网络下载），只检查 Alpine 是否已安装、
  /// `python3` 是否存在。真正的安装发生在 [run] 里。
  Future<void> refresh() async {
    if (!Platform.isAndroid) {
      _available = false;
      notifyListeners();
      return;
    }
    try {
      if (!LinuxService.instance.installed) {
        await LinuxService.instance.refresh();
      }
      if (!LinuxService.instance.installed) {
        _available = false;
        _lastError = null;
        notifyListeners();
        return;
      }
      final LinuxResult r = await LinuxService.instance.exec(
        'command -v python3 >/dev/null 2>&1 && python3 -V',
      );
      final String out = r.stdout.trim();
      if (r.ok && out.isNotEmpty) {
        _version = out;
        _available = true;
        _lastError = null;
      } else {
        _available = false;
        _lastError = null;
      }
    } catch (e) {
      _available = false;
      _lastError = '$e';
    }
    notifyListeners();
  }

  Future<List<String>> loadPackages() async {
    if (!Platform.isAndroid) return <String>[];
    try {
      final LinuxResult r = await LinuxService.instance.exec(
        'apk info 2>/dev/null | grep "^py3-" || true',
        timeout: const Duration(seconds: 30),
      );
      if (!r.ok) return _packages ?? <String>[];
      _packages = r.stdout
          .split('\n')
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      notifyListeners();
      return _packages!;
    } catch (_) {
      return _packages ?? <String>[];
    }
  }

  /// 执行一段 Python 代码。
  Future<PyResult> run(String code, {bool reset = false}) async {
    if (!Platform.isAndroid) {
      return const PyResult(ok: false, error: '当前平台不支持 Python');
    }
    if (!await LinuxService.instance.ensurePython()) {
      _lastError = LinuxService.instance.lastError ?? 'Alpine 里没有 python3';
      return PyResult(
        ok: false,
        error: 'Alpine 环境不可用或安装 python3 失败：$_lastError',
        errorType: 'Environment',
      );
    }
    try {
      // `python3 -` 从 stdin 读代码，省去落盘和转义。
      final LinuxResult r = await LinuxService.instance.exec(
        'cd /shared && python3 -',
        stdin: code,
        timeout: const Duration(minutes: 2),
      );
      if (!_available) {
        _available = true;
        notifyListeners();
      }
      final String combined = r.combined;
      if (r.ok) {
        return PyResult(ok: true, output: combined);
      }
      return PyResult(
        ok: false,
        output: combined,
        error: combined,
        errorType: _errorTypeOf(r.stderr),
      );
    } catch (e) {
      _lastError = '$e';
      return PyResult(ok: false, error: '调用 Python 失败：$e');
    }
  }

  /// 从 traceback 最后一行里挤出异常类型。
  static String? _errorTypeOf(String text) {
    final List<String> lines = text
        .trim()
        .split('\n')
        .where((String l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    final String last = lines.last.trim();
    final RegExpMatch? m = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\b').firstMatch(last);
    return m?.group(1);
  }
}
