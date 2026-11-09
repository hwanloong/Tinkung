import 'dart:io';

import 'package:flutter/services.dart';

/// Android 的「所有文件访问」权限。
///
/// ## 为什么需要它
///
/// 工作空间可以切到 `/sdcard/Download/...` 这类公共目录。Android 11+
/// 的分区存储不允许应用直接用 `dart:io` 往那里写，会抛：
///
/// ```text
/// OS Error: Operation not permitted, errno = 1
/// ```
///
/// 这不是路径拼错了，是系统拒绝。唯一的办法是让用户在系统设置里授予
/// 「所有文件访问」（`MANAGE_EXTERNAL_STORAGE`）。本应用是自用工具，
/// 不上架 Play，所以直接申请这个权限。
///
/// 应用专属目录（`/data/...`、`/sdcard/Android/data/<包名>/...`）本来
/// 就能写，不需要这个权限。
class FileAccess {
  FileAccess._();

  static const MethodChannel _channel = MethodChannel('dsh/fileopen');

  /// 当前是否已经能写公共目录。
  static Future<bool> hasAllFiles() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool? ok = await _channel.invokeMethod<bool>('hasAllFilesAccess');
      return ok ?? false;
    } catch (_) {
      // 通道不可用（比如测试环境）按"没有"处理，让上层给出提示，
      // 而不是假装成功、到写入时才炸。
      return false;
    }
  }

  /// 打开系统授权页。**结果不在这个 Future 里**：用户可能去设置里点很久，
  /// 所以调用方应在 `AppLifecycleState.resumed` 时重新 [hasAllFiles]。
  static Future<void> requestAllFiles() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestAllFilesAccess');
    } catch (_) {
      // 个别 ROM 没有这个设置页；用户仍可手动去系统设置里找。
    }
  }

  /// 这个目录是否属于"应用自己就能写"的位置。
  static bool isAppPrivate(String path) {
    final String p = path.replaceAll('\\', '/');
    return p.startsWith('/data/') ||
        p.contains('/Android/data/') ||
        p.contains('/Android/obb/') ||
        p.contains('/Android/media/');
  }
}
