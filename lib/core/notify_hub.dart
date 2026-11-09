import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_info.dart';
import 'background.dart';

/// 「提醒」中枢：判断前台/后台，决定用什么方式让人注意到。
///
/// ## 为什么由**系统**判断，而不是让模型选
///
/// 模型不知道用户此刻在不在看屏幕：它只知道"这件事该提醒一下"。
/// 如果让它选"发通知"还是"弹窗"，它一定会选错 —— 前台时发通知
/// 用户看不到（通知栏本来就没开），后台时弹窗根本弹不出来。
///
/// 所以接口只收**内容**，前台/后台由这里判断：
///
///  · 前台 → 会话气泡 + 历史列表红点（用户正在看，够醒目了）
///  · 后台 → 上面两条 **加上** 一条系统通知（否则他永远不知道）
///
/// ## 红点为什么是"未读"而不是"有提醒"
///
/// 红点铺在历史列表的会话行上，用户点进那个会话就该消失 —— 它表达的是
/// "这里有你还没看的东西"，不是"这个会话被提醒过"。用后者的话，
/// 红点会永远挂着，很快就没人看它了。
class NotifyHub extends ChangeNotifier {
  NotifyHub._();

  static final NotifyHub instance = NotifyHub._();

  File? _file;

  /// 有未读提醒的会话 id。
  final Set<String> _unread = <String>{};

  /// 应用是否在前台。
  ///
  /// `WidgetsBinding.instance.lifecycleState` 在测试环境可能为 null，
  /// 这时按**前台**处理：宁可少发一条通知，也不要给正在用的人弹通知。
  bool get isForeground {
    final AppLifecycleState? s = WidgetsBinding.instance.lifecycleState;
    if (s == null) return true;
    return s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;
  }

  bool unread(String convId) => _unread.contains(convId);

  int get unreadCount => _unread.length;

  Future<void> load(File file) async {
    _file = file;
    try {
      if (await file.exists()) {
        final dynamic j = jsonDecode(await file.readAsString());
        if (j is List) {
          for (final dynamic e in j) {
            if (e != null) _unread.add(e.toString());
          }
        }
      }
    } catch (_) {
      // 坏档当没有：红点丢了不影响任何功能
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final File? f = _file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(_unread.toList()));
    } catch (_) {}
  }

  /// 清掉某个会话的红点（用户点进去了）。
  Future<void> markRead(String convId) async {
    if (!_unread.remove(convId)) return;
    await _save();
    notifyListeners();
  }

  /// 提醒用户。返回给模型看的一句话。
  ///
  /// `convId` 空表示不属于任何会话 —— 那种情况只发通知，不点红点。
  Future<String> push({
    required String title,
    required String body,
    String convId = '',
  }) async {
    // 后台才发系统通知；前台弹通知是噪音。
    final bool background = !isForeground;
    bool posted = false;
    if (background) {
      posted = await BackgroundService.instance.postNotice(
        title: title.trim().isEmpty ? kAppName : title.trim(),
        body: body.trim(),
      );
    }

    if (convId.isNotEmpty) {
      _unread.add(convId);
      await _save();
      notifyListeners();
    }

    if (background) {
      return posted
          ? '已提醒用户（应用在后台，已发出系统通知，对应会话标了红点）。'
          : '已提醒用户（应用在后台，但**系统通知没发出去** —— '
                '可能是没有通知权限。会话里已标红点）。';
    }
    return '已提醒用户（应用在前台，内容已显示在当前会话里，并标了红点；'
        '没有另发系统通知，避免多此一举）。';
  }
}
