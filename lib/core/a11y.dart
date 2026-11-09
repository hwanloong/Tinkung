import 'package:flutter/services.dart';

import 'ui_tree.dart';

/// 无障碍通道的 Dart 侧封装。
///
/// 原生没开、通道不存在（桌面/测试）、服务掉线，都统一返回
/// `ok=false + code`，调用方（工具）只负责把 `message` 转给模型。
class A11y {
  const A11y._();

  static const MethodChannel _channel = MethodChannel('dsh/a11y');

  static Future<bool> enabled() async {
    try {
      final Map<dynamic, dynamic>? r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('status');
      return r?['enabled'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<dynamic>('openSettings');
    } catch (_) {
      // 没有无障碍设置的设备也只能作罢
    }
  }

  /// 返回 null 表示原生不可用；`ok=false` 的 map 由调用方转成提示。
  static Future<UiSnapshot?> dump({int limit = 120}) async {
    try {
      final Map<dynamic, dynamic>? r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('dump', <String, dynamic>{
            'limit': limit,
          });
      if (r == null || r['ok'] != true) return null;
      return UiSnapshot.fromMap(r);
    } catch (_) {
      return null;
    }
  }

  static Future<A11yResult> action({
    required String op,
    Map<String, dynamic>? target,
    String value = '',
    bool backward = false,
  }) async {
    try {
      final Map<dynamic, dynamic>? r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('action', <String, dynamic>{
            'op': op,
            'target': target ?? <String, dynamic>{},
            'value': value,
            'backward': backward,
          });
      return A11yResult.fromMap(r);
    } catch (e) {
      return A11yResult.fail('CHANNEL_ERROR', '无障碍通道不可用：$e');
    }
  }

  static Future<A11yResult> tapAt(double x, double y) =>
      action(op: 'tap', target: <String, dynamic>{'x': x, 'y': y});

  static Future<A11yResult> gesture(
    List<List<double>> points, {
    int duration = 400,
  }) async {
    try {
      final Map<dynamic, dynamic>? r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('gesture', <String, dynamic>{
            'points': points,
            'duration': duration,
          });
      return A11yResult.fromMap(r);
    } catch (e) {
      return A11yResult.fail('CHANNEL_ERROR', '手势通道不可用：$e');
    }
  }

  static Future<A11yResult> draw(
    List<List<List<double>>> strokes, {
    List<int>? durations,
    int gap = 120,
  }) async {
    try {
      final Map<dynamic, dynamic>? r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('draw', <String, dynamic>{
            'strokes': strokes,
            'durations': durations,
            'gap': gap,
          });
      return A11yResult.fromMap(r);
    } catch (e) {
      return A11yResult.fail('CHANNEL_ERROR', '绘制通道不可用：$e');
    }
  }

  static Future<A11yResult> launch(String package) async {
    try {
      final Map<dynamic, dynamic>? r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('launch', <String, dynamic>{
            'package': package,
          });
      return A11yResult.fromMap(r);
    } catch (e) {
      return A11yResult.fail('CHANNEL_ERROR', '启动通道不可用：$e');
    }
  }

  static Future<A11yResult> openUrl(String url) async {
    try {
      final Map<dynamic, dynamic>? r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('openUrl', <String, dynamic>{
            'url': url,
          });
      return A11yResult.fromMap(r);
    } catch (e) {
      return A11yResult.fail('CHANNEL_ERROR', '打开链接失败：$e');
    }
  }
}

class A11yResult {
  const A11yResult({
    required this.ok,
    required this.code,
    required this.message,
    required this.raw,
  });

  final bool ok;
  final String code;
  final String message;
  final Map<dynamic, dynamic> raw;

  factory A11yResult.fromMap(Map<dynamic, dynamic>? m) {
    if (m == null) {
      return const A11yResult(
        ok: false,
        code: 'NO_RESULT',
        message: '无障碍没有返回结果',
        raw: <String, dynamic>{},
      );
    }
    return A11yResult(
      ok: m['ok'] == true,
      code: m['code']?.toString() ?? (m['ok'] == true ? 'OK' : 'FAILED'),
      message: m['message']?.toString() ?? '',
      raw: m,
    );
  }

  factory A11yResult.fail(String code, String message) =>
      A11yResult(ok: false, code: code, message: message, raw: const {});

  String get summary {
    final String method = raw['method']?.toString() ?? '';
    final StringBuffer sb = StringBuffer(ok ? 'OK' : code);
    if (method.isNotEmpty) sb.write(' · $method');
    if (message.isNotEmpty) sb.write('\n$message');
    return sb.toString();
  }
}
