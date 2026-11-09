import 'dart:io';

import 'package:flutter/services.dart';

/// 独立沙箱插件（Ubuntu + proot）的状态。
class SandboxPluginStatus {
  const SandboxPluginStatus({this.installed = false, this.canInstall = true});

  final bool installed;
  final bool canInstall;
}

/// 和原生 `SandboxPluginBridge` 通信。
///
/// 插件 APK 在 `assets/plugins/privtasker-sandbox.apk`，安装后包名是
/// `com.dsh.privtasker.sandbox`。它没有 launcher activity，所以桌面
/// 不会多一个图标，只能从这里打开。
class SandboxPluginService {
  SandboxPluginService._();

  static final SandboxPluginService instance = SandboxPluginService._();

  static const MethodChannel _ch = MethodChannel('dsh/sandbox_plugin');

  bool get supported => Platform.isAndroid;

  Future<SandboxPluginStatus> status() async {
    if (!supported) return const SandboxPluginStatus();
    try {
      final Map<dynamic, dynamic>? m = await _ch
          .invokeMethod<Map<dynamic, dynamic>>('status');
      return SandboxPluginStatus(
        installed: m?['installed'] == true,
        canInstall: m?['canInstall'] != false,
      );
    } catch (_) {
      return const SandboxPluginStatus();
    }
  }

  Future<Map<dynamic, dynamic>?> install() async {
    if (!supported) return null;
    return _ch.invokeMethod<Map<dynamic, dynamic>>('install');
  }

  Future<Map<dynamic, dynamic>?> launch() async {
    if (!supported) return null;
    return _ch.invokeMethod<Map<dynamic, dynamic>>('launch');
  }

  Future<Map<dynamic, dynamic>?> uninstall() async {
    if (!supported) return null;
    return _ch.invokeMethod<Map<dynamic, dynamic>>('uninstall');
  }

  Future<Map<dynamic, dynamic>?> exec({
    required String command,
    String? workdir,
    Duration timeout = const Duration(seconds: 120),
    String? stdin,
  }) async {
    if (!supported) return null;
    return _ch.invokeMethod<Map<dynamic, dynamic>>('exec', <String, dynamic>{
      'command': command,
      if (workdir != null && workdir.trim().isNotEmpty) 'workdir': workdir,
      'timeoutMs': timeout.inMilliseconds,
      if (stdin != null && stdin.isNotEmpty) 'stdin': stdin,
    });
  }

  Future<void> openInstallSettings() async {
    if (!supported) return;
    await _ch.invokeMethod<void>('openInstallSettings');
  }
}
