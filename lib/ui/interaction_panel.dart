import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../interaction/interaction_hub.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';

/// 聊天页底部的互动面板。
///
/// 高度由外部控制（[height]），顶部那条把手负责"上下拖"：
/// 拖到很矮就只剩一条小条（标题 + 展开/关闭），也就是需求里的
/// "拉到最底下显示略缩小图标"。
class InteractionPanel extends StatefulWidget {
  const InteractionPanel({
    super.key,
    required this.session,
    required this.height,
    required this.onHeightChanged,
    required this.onClose,
  });

  final InteractionSession session;
  final double height;
  final ValueChanged<double> onHeightChanged;
  final VoidCallback onClose;

  @override
  State<InteractionPanel> createState() => _InteractionPanelState();
}

class _InteractionPanelState extends State<InteractionPanel> {
  InAppWebViewController? _web;
  int _seenCommands = 0;

  static const double _collapsedHeight = 44;

  bool get _collapsed => widget.height <= _collapsedHeight + 8;

  @override
  void initState() {
    super.initState();
    InteractionHub.instance.addListener(_onHub);
  }

  @override
  void dispose() {
    InteractionHub.instance.removeListener(_onHub);
    super.dispose();
  }

  void _onHub() {
    final InAppWebViewController? c = _web;
    if (c == null) return;
    final List<InteractionCommand> cmds = widget.session.commands;
    if (cmds.length <= _seenCommands) return;
    for (int i = _seenCommands; i < cmds.length; i++) {
      final String js = cmds[i].js;
      c.evaluateJavascript(source: js);
    }
    _seenCommands = cmds.length;
  }

  Future<void> _injectBridge() async {
    final InAppWebViewController? c = _web;
    if (c == null) return;
    await c.evaluateJavascript(
      source: r'''
      window.App = window.App || {};
      window.App.send = function (data) {
        try {
          window.flutter_inappwebview.callHandler('panel_event', JSON.stringify(data));
        } catch (e) {
          window.flutter_inappwebview.callHandler('panel_event', JSON.stringify({raw: String(data)}));
        }
      };
      window.App.onCommand = window.App.onCommand || function () {};
    ''',
    );
    // 连上之后把之前积压的命令补执行一次
    _seenCommands = 0;
    _onHub();
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final bool collapsed = _collapsed;

    // 浮在输入框上方的面板：用玻璃的 floating 档（更厚、带大投影），
    // 投影和边缘交给玻璃本身，这里不再自己画阴影。
    return Material(
      color: Colors.transparent,
      child: SurfaceCard(
        role: GlassRole.floating,
        radius: AppRadius.card,
        padding: EdgeInsets.zero,
        child: Column(
          children: <Widget>[
            // ---- 拖拽把手 + 标题 ----
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (DragUpdateDetails d) {
                widget.onHeightChanged(widget.height - d.delta.dy);
              },
              onVerticalDragEnd: (_) {
                // 拖到很矮就吸附成"小条"，避免停在半截像个坏窗口。
                if (widget.height < 120) {
                  widget.onHeightChanged(_collapsedHeight);
                }
              },
              child: SizedBox(
                height: collapsed ? _collapsedHeight : 44,
                child: Row(
                  children: <Widget>[
                    const SizedBox(width: 10),
                    if (collapsed)
                      IconButton(
                        icon: const Icon(Icons.expand_less_rounded, size: 19),
                        tooltip: '展开互动面板',
                        onPressed: () => widget.onHeightChanged(320),
                        visualDensity: VisualDensity.compact,
                      )
                    else
                      // 把手：稍微宽一点、厚一点 —— 这是"可以上下拖"的
                      // 唯一暗示，太细会被当成一条分割线。
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: s.border,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.body(
                          size: 13,
                          weight: FontWeight.w600,
                          color: s.text,
                          height: 1.3,
                        ),
                      ),
                    ),
                    if (!collapsed)
                      IconButton(
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 19,
                        ),
                        tooltip: '收起互动面板',
                        visualDensity: VisualDensity.compact,
                        onPressed: () =>
                            widget.onHeightChanged(_collapsedHeight),
                      ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      tooltip: '关闭互动面板',
                      color: s.muted,
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onClose,
                    ),
                    const SizedBox(width: 2),
                  ],
                ),
              ),
            ),
            if (!collapsed)
              Expanded(
                child: InAppWebView(
                  initialData: InAppWebViewInitialData(
                    data: widget.session.html,
                    baseUrl: WebUri('file:///'),
                  ),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    allowFileAccess: true,
                    allowFileAccessFromFileURLs: true,
                    allowUniversalAccessFromFileURLs: true,
                    transparentBackground: true,
                    supportZoom: false,
                    disableContextMenu: false,
                    mediaPlaybackRequiresUserGesture: false,
                  ),
                  onWebViewCreated: (InAppWebViewController c) {
                    _web = c;
                    c.addJavaScriptHandler(
                      handlerName: 'panel_event',
                      callback: (List<dynamic> args) {
                        final String raw = args.isEmpty
                            ? ''
                            : args.first.toString();
                        try {
                          final dynamic j = jsonDecode(raw);
                          if (j is Map) {
                            InteractionHub.instance.recordEvent(
                              widget.session.id,
                              Map<String, dynamic>.from(j),
                            );
                          }
                        } catch (_) {
                          InteractionHub.instance.recordEvent(
                            widget.session.id,
                            <String, dynamic>{'raw': raw},
                          );
                        }
                        return null;
                      },
                    );
                  },
                  onLoadStop: (InAppWebViewController c, WebUri? url) {
                    _web = c;
                    _injectBridge();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
