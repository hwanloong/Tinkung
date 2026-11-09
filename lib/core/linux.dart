import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一次 Linux 命令的结果。
class LinuxResult {
  const LinuxResult({
    required this.ok,
    this.stdout = '',
    this.stderr = '',
    this.exitCode = -1,
    this.error,
    this.errorKind,
  });

  final bool ok;
  final String stdout;
  final String stderr;
  final int exitCode;
  final String? error;
  final String? errorKind;

  /// 合并输出，给用户和模型看的。
  String get combined {
    final StringBuffer sb = StringBuffer();
    if (stdout.trim().isNotEmpty) sb.write(stdout.trim());
    if (stderr.trim().isNotEmpty) {
      if (sb.isNotEmpty) sb.write('\n');
      sb.write(stderr.trim());
    }
    if (sb.isEmpty) sb.write('（无输出）');
    return sb.toString();
  }
}

/// Linux 环境的安装状态。
class LinuxInfo {
  const LinuxInfo({
    this.installed = false,
    this.rootfs = '',
    this.rootfsBytes = 0,
    this.prootExists = false,
    this.abi = '',
  });

  final bool installed;
  final String rootfs;
  final int rootfsBytes;
  final bool prootExists;
  final String abi;

  String get sizeText {
    if (rootfsBytes <= 0) return '';
    final double mb = rootfsBytes / 1024 / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }
}

/// **自带的内嵌 Linux 环境**（proot + Alpine minirootfs）。
///
/// ## 它和 [TermuxService] 的区别
///
/// | | TermuxService | 这个 |
/// |---|---|---|
/// | 依赖 | 用户**必须装 Termux**，还要手工开 `allow-external-apps` | **零依赖**，APK 自带 |
/// | 输出 | 只在命令跑完时回一次 | 同样拿完整输出，但**支持 stdin** |
/// | 交互 | 用不了（没有 stdin） | `apk add` 的 y/n、REPL 都能用 |
/// | 能装包 | 用 Termux 的 pkg | 用自带的静态 `apk` |
///
/// 所以这是**默认通道**：用户开箱即用，不需要任何配置。
/// Termux 那条路保留着，给"已经在 Termux 里配好了环境"的人用
/// （那里有他装好的工具链，比空白的 Alpine 更有用）。
///
/// ## 为什么安装要单独一步
///
/// 把 4MB 的 rootfs 解开要几秒，而且解完占约 20MB 磁盘。
/// 不在启动时做（那会让冷启动变慢、还白占用户空间），
/// 而是**第一次用终端时**触发，并且让用户看到进度。
class LinuxService extends ChangeNotifier {
  LinuxService._();

  static final LinuxService instance = LinuxService._();

  static const MethodChannel _ch = MethodChannel('dsh/linux');

  bool _installed = false;
  bool get installed => _installed;

  bool _installing = false;
  bool get installing => _installing;

  LinuxInfo _info = const LinuxInfo();
  LinuxInfo get info => _info;

  String? _lastError;
  String? get lastError => _lastError;

  /// 当前平台能不能用（只有 Android 打包了那套资源）。
  bool get supported => Platform.isAndroid;

  /// 查一下装没装。启动时调一次就够。
  Future<void> refresh() async {
    if (!supported) return;
    try {
      _installed = await _ch.invokeMethod<bool>('isInstalled') ?? false;
      final Map<dynamic, dynamic>? m = await _ch
          .invokeMethod<Map<dynamic, dynamic>>('info');
      if (m != null) {
        _info = LinuxInfo(
          installed: m['installed'] == true,
          rootfs: m['rootfs']?.toString() ?? '',
          rootfsBytes: (m['rootfsBytes'] as num?)?.toInt() ?? 0,
          prootExists: m['prootExists'] == true,
          abi: m['abi']?.toString() ?? '',
        );
        _installed = _info.installed;
      }
    } catch (e) {
      _lastError = '$e';
    }
    notifyListeners();
  }

  /// 安装（解 rootfs）。已经装过就直接返回 true。
  Future<bool> install() async {
    if (!supported) return false;
    if (_installed) return true;

    _installing = true;
    _lastError = null;
    notifyListeners();

    try {
      final Map<dynamic, dynamic>? m = await _ch
          .invokeMethod<Map<dynamic, dynamic>>('install');
      if (m == null || m['ok'] != true) {
        _lastError = m?['error']?.toString() ?? '安装失败';
        return false;
      }
      _installed = true;
      return true;
    } catch (e) {
      _lastError = '$e';
      return false;
    } finally {
      _installing = false;
      await refresh();
      notifyListeners();
    }
  }

  /// 在 Linux 环境里跑一条命令。
  Future<LinuxResult> exec(
    String command, {
    String? workdir,
    Duration timeout = const Duration(seconds: 60),
    String? stdin,
    bool keepAlive = false,
    List<String> extraBinds = const <String>[],
  }) async {
    if (!supported) {
      return const LinuxResult(ok: false, error: '当前平台不支持内置 Linux 环境');
    }
    try {
      final Map<dynamic, dynamic>? m = await _ch
          .invokeMethod<Map<dynamic, dynamic>>('exec', <String, dynamic>{
            'command': command,
            'workdir': workdir,
            'timeoutMs': timeout.inMilliseconds,
            'stdin': stdin,
            'keepAlive': keepAlive,
            'extraBinds': extraBinds,
          });
      if (m == null) {
        return const LinuxResult(ok: false, error: '没有返回结果');
      }
      return LinuxResult(
        ok: m['ok'] == true,
        stdout: m['stdout']?.toString() ?? '',
        stderr: m['stderr']?.toString() ?? '',
        exitCode: (m['exitCode'] as num?)?.toInt() ?? -1,
        error: m['error']?.toString(),
        errorKind: m['errorKind']?.toString(),
      );
    } catch (e) {
      return LinuxResult(ok: false, error: '调用失败：$e');
    }
  }
}
