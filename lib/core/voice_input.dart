import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 语音输入：把系统识别器的结果（边说边出的部分结果 + 最终结果）转成文字。
///
/// ## 为什么自己接 MethodChannel
///
/// 原生侧是 `SpeechRecognizer`（见 `SpeechBridge.kt`），这里只做三件事：
///  · 把 `start / stop / cancel` 发过去；
///  · 把 `onPartial / onFinal / onError` 收回来；
///  · 用 [listening] 给界面一个"现在正在听"的单一真相。
///
/// 不用第三方插件：这个项目对带原生代码的依赖一直很克制（构建链踩过坑），
/// 而这里需要的功能只有一百多行。
class VoiceInput {
  VoiceInput._();

  static const MethodChannel _channel = MethodChannel('dsh/speech');

  /// 正在识别。界面上的麦克风按钮只有读这一个值才不会和原生状态打架。
  static final ValueNotifier<bool> listening = ValueNotifier<bool>(false);

  /// 部分结果（边说边出字）。识别结束时由调用方决定要不要并进正文。
  static final ValueNotifier<String> partial = ValueNotifier<String>('');

  /// 最近一次错误（给界面弹提示用）。null = 没有错误。
  static final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  static void Function(String text)? _onFinal;
  static void Function(String text)? _onPartial;
  static void Function(String message)? _onError;
  static bool _bound = false;

  /// 原生 → Dart 的回调只装一次。
  static void _bind() {
    if (_bound) return;
    _bound = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'onStart':
        case 'onReady':
          listening.value = true;
        case 'onPartial':
          final String t = (call.arguments as String?) ?? '';
          if (t.isEmpty) return;
          partial.value = t;
          _onPartial?.call(t);
        case 'onFinal':
          final String t = ((call.arguments as String?) ?? '').trim();
          if (t.isNotEmpty) _onFinal?.call(t);
        case 'onError':
          final String msg = (call.arguments as String?) ?? '识别失败';
          error.value = msg;
          _onError?.call(msg);
        case 'onCancel':
          // 用户在系统识别界面点了取消：不是错误，安静收回按钮。
          listening.value = false;
        case 'onEnd':
          // 原生已经结束（出错、超时、用户松手都会走到这里）。
          // 让界面的"正在识别"一定收回去，不能靠 Dart 侧的 stop 回调。
          listening.value = false;
      }
    });
  }

  /// 这台设备有没有可用的识别引擎。
  static Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 开始识别。
  ///
  /// [onPartial] 拿到的是"这句话到目前为止"的完整文本（不是增量），
  /// 直接替换输入框里的草稿就行。
  static Future<bool> start({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function(String message) onError,
  }) async {
    _bind();
    _onPartial = onPartial;
    _onFinal = onFinal;
    _onError = onError;
    partial.value = '';
    error.value = null;
    try {
      final bool ok =
          await _channel.invokeMethod<bool>('start') ?? false;
      listening.value = ok;
      return ok;
    } on PlatformException catch (e) {
      // 没权限 / 没引擎都从这里出来。文案已经在原生侧翻成人话了。
      final String msg = e.message ?? '无法开始语音输入';
      error.value = msg;
      onError(msg);
      listening.value = false;
      return false;
    } catch (_) {
      error.value = '无法开始语音输入';
      listening.value = false;
      return false;
    }
  }

  /// 请识别器收尾并给出最终结果。不会立刻把 [listening] 置 false ——
  /// 要等原生的 `onEnd`，否则按钮会先翻回黑色、字却还在出来。
  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {
      listening.value = false;
    }
  }

  /// 直接放弃这次识别（离开页面 / 发送消息时用）。
  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod<bool>('cancel');
    } catch (_) {
      // 忽略
    }
    listening.value = false;
    partial.value = '';
  }

  /// 打开本应用的系统权限页。
  ///
  /// 给"系统里明明允许了、应用还是说没权限"的情况留一个出口 ——
  /// 有些 ROM 的授权回调不可靠，只能让用户去系统页确认一次。
  static Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<bool>('openSettings');
    } catch (_) {
      // 忽略
    }
  }
}
