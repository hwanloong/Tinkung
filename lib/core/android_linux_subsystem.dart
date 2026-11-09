import 'dart:io';

import 'package:flutter/services.dart';

/// Android 16 系统 Linux Terminal（AVF 虚拟机）的可用性。
class AndroidLinuxSubsystemStatus {
  const AndroidLinuxSubsystemStatus({
    this.installed = false,
    this.launchable = false,
    this.sdkInt = 0,
  });

  final bool installed;
  final bool launchable;
  final int sdkInt;
}

/// 只负责检测和打开系统 Terminal，**不伪装成命令后端**。
class AndroidLinuxSubsystemService {
  AndroidLinuxSubsystemService._();

  static final AndroidLinuxSubsystemService instance =
      AndroidLinuxSubsystemService._();

  static const MethodChannel _ch = MethodChannel('dsh/android_linux_subsystem');

  bool get supported => Platform.isAndroid;

  Future<AndroidLinuxSubsystemStatus> status() async {
    if (!supported) return const AndroidLinuxSubsystemStatus();
    try {
      final Map<dynamic, dynamic>? m = await _ch
          .invokeMethod<Map<dynamic, dynamic>>('status');
      return AndroidLinuxSubsystemStatus(
        installed: m?['installed'] == true,
        launchable: m?['launchable'] == true,
        sdkInt: (m?['sdkInt'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return const AndroidLinuxSubsystemStatus();
    }
  }

  Future<Map<dynamic, dynamic>?> launch() async {
    if (!supported) return null;
    return _ch.invokeMethod<Map<dynamic, dynamic>>('launch');
  }
}
