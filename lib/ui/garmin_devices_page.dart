import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/garmin.dart';
import '../core/models.dart';
import '../core/productivity.dart';
import '../core/store.dart';
import '../plugins/plugin.dart';
import '../theme/app_theme.dart';
import 'chat_page.dart';
import 'home_shell.dart';

class GarminDevicesPage extends StatefulWidget {
  const GarminDevicesPage({
    super.key,
    required this.settings,
    required this.conversations,
    required this.plugins,
    required this.workDir,
    required this.notes,
    required this.tasks,
  });

  final Settings settings;
  final ConversationStore conversations;
  final PluginStore plugins;
  final String workDir;
  final NoteStore notes;
  final TaskStore tasks;

  @override
  State<GarminDevicesPage> createState() => _GarminDevicesPageState();
}

class _GarminDevicesPageState extends State<GarminDevicesPage> {
  StreamSubscription<Map<String, dynamic>>? _events;
  List<Map<String, dynamic>> _devices = <Map<String, dynamic>>[];
  final Map<String, Map<String, dynamic>> _statuses =
      <String, Map<String, dynamic>>{};
  String? _error;
  final Set<String> _addedIds = <String>{};
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    for (final conversation in widget.conversations.conversations) {
      if (conversation.deviceId != null) _addedIds.add(conversation.deviceId!);
    }
    if (Platform.isAndroid) {
      _events = GarminBridge.instance.events.listen(
        _onEvent,
        onError: (Object e) {
          if (mounted) setState(() => _error = e.toString());
        },
      );
      _startScan();
    } else {
      // Garmin 通道只有 Android 原生实现；桌面/测试环境不要把
      // MissingPluginException 抛到界面上。
      _scanning = false;
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final String? deviceId = event['deviceId']?.toString();
    if (event['type'] == 'clear' && deviceId != null) {
      final Conversation? conversation = widget.conversations.conversations
          .where((Conversation item) => item.deviceId == deviceId)
          .firstOrNull;
      if (conversation != null) {
        widget.conversations.clearConversation(conversation.id);
      }
    }
    setState(() {
      switch (event['type']) {
        case 'devices':
          _devices = (event['devices'] as List<dynamic>? ?? <dynamic>[])
              .whereType<Map>()
              .map((Map value) => Map<String, dynamic>.from(value))
              .toList();
          _scanning = false;
          unawaited(_restoreBindings());
          break;
        case 'status':
          if (deviceId != null && deviceId != '-1') {
            _statuses[deviceId] = event;
          }
          _error = event['error']?.toString();
          break;
        case 'error':
          _error = event['message']?.toString();
          break;
      }
    });
  }

  Future<void> _restoreBindings() async {
    for (final Conversation conversation
        in widget.conversations.conversations) {
      final int? id = int.tryParse(conversation.deviceId ?? '');
      if (id == null) continue;
      final String display = conversation.title.toLowerCase().contains('instinct')
          ? '佳明设备'
          : conversation.title;
      try {
        await GarminBridge.instance.select(id: id, name: display);
      } catch (_) {
        // Device status events will report failures without blocking the list.
      }
    }
  }

  Future<void> _startScan() async {
    setState(() => _scanning = true);
    try {
      await GarminBridge.instance.start();
      await GarminBridge.instance.refresh();
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message ?? 'Garmin Connect IQ 不可用';
          _scanning = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _scanning = false;
        });
      }
    }
  }

  Future<void> _add(Map<String, dynamic> device) async {
    final int? id = (device['id'] as num?)?.toInt();
    if (id == null) return;
    final String name = device['name']?.toString() ?? '佳明设备';
    try {
      await GarminBridge.instance.select(id: id, name: name);
      final conversation = widget.conversations.conversationForDevice(
        '$id',
        name,
        select: false,
      );
      if (conversation.title != name &&
          conversation.title.toLowerCase().contains('instinct')) {
        widget.conversations.rename(conversation.id, name);
      }
      if (mounted) setState(() => _addedIds.add(conversation.deviceId!));
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  void _openChat({required String deviceId}) {
    final currentId = widget.conversations.currentId;
    final conversation = widget.conversations.conversations.firstWhere(
      (c) => c.deviceId == deviceId,
    );
    widget.conversations.select(conversation.id);
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ChatPage(
              settings: widget.settings,
              conversations: widget.conversations,
              plugins: widget.plugins,
              workDir: widget.workDir,
              notes: widget.notes,
              tasks: widget.tasks,
            ),
          ),
        )
        .whenComplete(() {
          if (currentId != null) widget.conversations.select(currentId);
        });
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: '第三方设备',
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: '返回',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            actions: <Widget>[
              IconButton(
                onPressed: _scanning ? null : _startScan,
                icon: _scanning
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
                tooltip: '刷新设备',
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: <Widget>[
                Text(
                  '支持设备',
                  style: AppFonts.body(
                    size: 12,
                    weight: FontWeight.w600,
                    color: s.muted,
                  ),
                ),
                const SizedBox(height: 10),
                if (_devices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: Column(
                      children: <Widget>[
                        Icon(Icons.watch_outlined, size: 34, color: s.muted),
                        const SizedBox(height: 12),
                        Text(
                          _scanning ? '正在查找已配对设备' : '没有可添加的佳明设备',
                          style: AppFonts.body(size: 14, color: s.text),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '先在 Garmin Connect 中配对手表，再刷新设备列表。',
                          textAlign: TextAlign.center,
                          style: AppFonts.body(size: 12, color: s.muted),
                        ),
                      ],
                    ),
                  )
                else
                  for (final device in _devices) ...<Widget>[
                    Builder(
                      builder: (BuildContext context) {
                        final String id = device['id']?.toString() ?? '';
                        final String name =
                            device['name']?.toString() ?? '佳明设备';
                        final bool added = _addedIds.contains(id);
                        final Map<String, dynamic> status =
                            _statuses[id] ?? <String, dynamic>{};
                        final bool connected =
                            status['connected'] == true ||
                            device['status'] == 'CONNECTED';
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            _deviceRow(s, name, connected, false),
                            if (status['appInstalled'] == false && added)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  '手表尚未安装对应的 Connect IQ 应用。',
                                  style: AppFonts.body(
                                    size: 12,
                                    color: s.muted,
                                  ),
                                ),
                              ),
                            if (added)
                              OutlinedButton.icon(
                                onPressed: () => _openChat(deviceId: id),
                                icon: const Icon(
                                  Icons.chat_bubble_outline_rounded,
                                ),
                                label: Text('打开$name 对话'),
                              )
                            else
                              FilledButton.icon(
                                onPressed: () => _add(device),
                                icon: const Icon(Icons.add_rounded),
                                label: Text('绑定$name'),
                              ),
                            const SizedBox(height: 12),
                          ],
                        );
                      },
                    ),
                  ],
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: AppFonts.body(size: 12, color: AppColors.accent),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _deviceRow(AppSurface s, String name, bool connected, bool waiting) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: <Widget>[
            Icon(Icons.watch_rounded, size: 22, color: s.text),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    style: AppFonts.body(
                      size: 14,
                      weight: FontWeight.w600,
                      color: s.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    waiting
                        ? '已添加 · 正在连接'
                        : connected
                        ? '已连接'
                        : '已添加 · 未连接',
                    style: AppFonts.body(
                      size: 12,
                      color: connected ? AppColors.accent : s.muted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              connected ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 18,
              color: connected ? AppColors.accent : s.muted,
            ),
          ],
        ),
      );
}
