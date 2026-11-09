import 'package:flutter/material.dart';

import '../mcp/mcp_client.dart';
import '../mcp/mcp_store.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';

/// MCP 服务器管理页。
///
/// ## 这一页解决什么问题
///
/// MCP（Model Context Protocol）让外部服务把自己的工具**声明**出来，
/// 客户端照着声明注册即可，不需要为每个服务写死一个工具。对用户来说，
/// 这里是"贴一个地址（可能需要 Token）→ 发现工具 → AI 立刻能用"。
///
/// ## 设计取舍
///
/// · **只支持远程 Streamable HTTP**：stdio 要在手机上跑子进程，
///   和本应用的沙箱模型冲突；旧 HTTP+SSE 已废弃。
/// · **工具会缓存**：上一次成功发现的结果落盘，离线/服务器暂时挂了
///   也还能用（调用时再报错）。所以"刷新"是手动动作，不是每次启动都发网络请求。
/// · **写操作默认要确认**：只有服务器自己声明 `readOnlyHint` 的工具
///   会直接执行；其余走现有的确认框（用户开「全部放行」才跳过）。
class McpPage extends StatefulWidget {
  const McpPage({super.key});

  @override
  State<McpPage> createState() => _McpPageState();
}

class _McpPageState extends State<McpPage> {
  final Set<String> _busy = <String>{};

  McpStore get _store => McpStore.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChange);
  }

  @override
  void dispose() {
    _store.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    final _ServerDraft? draft = await _showServerDialog(context);
    if (draft == null || !mounted) return;
    final McpServer server = _store.addServer(
      name: draft.name,
      url: draft.url,
      headers: draft.headers,
    );
    setState(() {});
    await _refresh(server);
  }

  Future<void> _refresh(McpServer server) async {
    setState(() => _busy.add(server.id));
    final String? err = await _store.refresh(server);
    if (!mounted) return;
    setState(() => _busy.remove(server.id));
    _snack(err ?? '已连接「${server.displayName}」：发现 ${server.tools.length} 个工具');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final List<McpServer> servers = _store.servers;

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: 'MCP 服务器',
            subtitle: servers.isEmpty
                ? '接入外部工具'
                : '${servers.length} 个 · '
                      '${_store.toolCount} 个可用工具',
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            actions: <Widget>[
              GlassIconButton(
                icon: Icons.add_rounded,
                tooltip: '添加 MCP 服务器',
                size: 38,
                iconSize: 20,
                onTap: _add,
              ),
            ],
          ),
          Expanded(
            child: servers.isEmpty
                ? const EmptyHint(
                    icon: Icons.hub_outlined,
                    title: '还没有 MCP 服务器',
                    desc:
                        'MCP 是一个开放协议：服务器把自己的工具声明出来，'
                        'AI 照着声明就能直接调用。\n\n'
                        '点右上角添加：填服务器的 HTTP 地址即可；'
                        '需要鉴权的再填 Authorization 等 Headers。\n'
                        '保存后会自动连接并发现工具。',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
                    itemCount: servers.length,
                    itemBuilder: (BuildContext _, int i) =>
                        _tile(s, servers[i]),
                  ),
          ),
        ],
      ),
    );
  }

  /// 一台服务器一行：图标块 + 名称 + 地址/工具数 + 右侧开关。
  ///
  /// 和存储 / 插件页的列表行同一规格。开关单独留在卡片右侧（不在
  /// `Pressable` 里面），所以点开关不会顺带跳进详情页。
  Widget _tile(AppSurface s, McpServer server) {
    final bool busy = _busy.contains(server.id);
    final bool failed = server.lastError.isNotEmpty;
    final int n = server.tools.length;
    final String meta = failed
        ? '连接失败：${server.lastError}'
        : '${n == 0 ? '还没有发现工具' : '$n 个工具'} · ${server.url}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: SurfaceCard(
        radius: AppRadius.card,
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Pressable(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext _) => McpServerPage(server: server),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: (failed ? AppColors.danger : AppColors.accent)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppRadius.code),
                      ),
                      child: Icon(
                        Icons.hub_outlined,
                        size: 18,
                        color: failed ? AppColors.danger : AppColors.accent,
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  server.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppFonts.body(
                                    size: 14.5,
                                    weight: FontWeight.w600,
                                    color: s.text,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                              if (busy) ...<Widget>[
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.6,
                                    color: AppColors.accent,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.body(
                              size: 12.5,
                              color: failed ? AppColors.danger : s.muted,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              value: server.enabled,
              onChanged: (bool v) => _store.setEnabled(server, v),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个服务器的详情：连接状态 + 工具清单 + 编辑 / 刷新 / 删除。
class McpServerPage extends StatefulWidget {
  const McpServerPage({super.key, required this.server});

  final McpServer server;

  @override
  State<McpServerPage> createState() => _McpServerPageState();
}

class _McpServerPageState extends State<McpServerPage> {
  bool _busy = false;

  McpStore get _store => McpStore.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChange);
  }

  @override
  void dispose() {
    _store.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final String? err = await _store.refresh(widget.server);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(err ?? '已刷新：${widget.server.tools.length} 个工具')),
    );
  }

  Future<void> _edit() async {
    final _ServerDraft? draft = await _showServerDialog(
      context,
      initial: widget.server,
    );
    if (draft == null || !mounted) return;
    final bool urlChanged = draft.url != widget.server.url;
    widget.server
      ..name = draft.name
      ..url = draft.url
      ..headers = draft.headers;
    _store.updateServer(widget.server);
    setState(() {});
    // 地址 / 鉴权变了必须重新发现，否则旧工具还挂在那里。
    if (urlChanged) await _refresh();
  }

  Future<void> _delete() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除这个 MCP 服务器？'),
        content: Text(
          '「${widget.server.displayName}」的配置和缓存的工具列表会被删掉。\n'
          '不会影响服务器那边的任何东西。',
          style: AppFonts.body(size: 14, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _store.removeServer(widget.server.id);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final McpServer server = widget.server;

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: server.displayName,
            subtitle: server.serverName.isEmpty
                ? server.url
                : '${server.serverName} · ${server.url}',
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            actions: <Widget>[
              GlassIconButton(
                icon: Icons.refresh_rounded,
                tooltip: '刷新工具',
                size: 38,
                iconSize: 19,
                onTap: _busy ? null : _refresh,
              ),
              const SizedBox(width: 4),
              GlassIconButton(
                icon: Icons.edit_outlined,
                tooltip: '编辑',
                size: 38,
                iconSize: 18,
                onTap: _edit,
              ),
              const SizedBox(width: 4),
              GlassIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: '删除',
                size: 38,
                iconSize: 18,
                color: AppColors.danger,
                onTap: _delete,
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
              children: <Widget>[
                if (_busy)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      color: AppColors.accent,
                    ),
                  ),
                _statusCard(s, server),
                const SizedBox(height: 14),
                Text(
                  '工具 ${server.tools.length}',
                  style: AppFonts.body(
                    size: 11.5,
                    weight: FontWeight.w600,
                    color: s.muted,
                  ),
                ),
                const SizedBox(height: 8),
                if (server.tools.isEmpty)
                  SurfaceCard(
                    radius: AppRadius.card,
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      '还没有发现工具。点右上角的刷新按钮连接一次；'
                      '失败原因会显示在上面。',
                      style: AppFonts.body(
                        size: 12.5,
                        color: s.muted,
                        height: 1.5,
                      ),
                    ),
                  )
                else
                  ...server.tools.map((McpToolInfo t) => _toolCard(s, t)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(AppSurface s, McpServer server) {
    return SurfaceCard(
      radius: AppRadius.card,
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: (server.enabled ? AppColors.success : AppColors.neutral)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.code),
                ),
                child: Icon(
                  server.enabled
                      ? Icons.check_circle_outline_rounded
                      : Icons.pause_circle_outline_rounded,
                  size: 18,
                  color: server.enabled
                      ? AppColors.success
                      : AppColors.neutral,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      server.enabled ? '已启用' : '已停用',
                      style: AppFonts.body(
                        size: 14.5,
                        weight: FontWeight.w600,
                        color: s.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      server.enabled
                          ? '工具会出现在 AI 的可调用列表里'
                          : '不再把这些工具交给 AI（缓存保留）',
                      style: AppFonts.body(
                        size: 12.5,
                        color: s.muted,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: server.enabled,
                onChanged: (bool v) => _store.setEnabled(server, v),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            server.url,
            style: AppFonts.code(size: 11.5, color: s.muted, height: 1.4),
          ),
          if (server.headers.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              '已配置 ${server.headers.length} 个请求头'
              '（${server.headers.keys.join('、')}）',
              style: AppFonts.body(size: 11.5, color: s.muted),
            ),
          ],
          if (server.lastError.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '上次连接失败：${server.lastError}',
              style: AppFonts.body(
                size: 12,
                color: AppColors.danger,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _toolCard(AppSurface s, McpToolInfo t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        radius: AppRadius.card,
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  t.readOnly
                      ? Icons.visibility_outlined
                      : (t.destructive
                            ? Icons.warning_amber_rounded
                            : Icons.build_outlined),
                  size: 15,
                  color: t.destructive ? AppColors.danger : s.muted,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(
                      size: 14.5,
                      weight: FontWeight.w600,
                      color: s.text,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (t.readOnly)
                  _chip(s, '只读')
                else if (t.destructive)
                  _chip(s, '可能破坏数据', danger: true)
                else
                  _chip(s, '需确认'),
              ],
            ),
            if (t.description.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 3),
              Text(
                t.description.trim(),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(size: 12.5, color: s.muted, height: 1.45),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              '模型调用名：${t.exposedName}',
              style: AppFonts.code(size: 10.5, color: s.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(AppSurface s, String text, {bool danger = false}) {
    final Color c = danger ? AppColors.danger : s.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: s.chipBg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: s.border, width: 0.8),
      ),
      child: Text(
        text,
        style: AppFonts.body(
          size: 10.5,
          weight: FontWeight.w600,
          color: c,
          height: 1.2,
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 编辑弹窗

class _ServerDraft {
  const _ServerDraft(this.name, this.url, this.headers);

  final String name;
  final String url;
  final Map<String, String> headers;
}

/// 添加 / 编辑服务器。返回 null 表示取消。
Future<_ServerDraft?> _showServerDialog(
  BuildContext context, {
  McpServer? initial,
}) {
  final TextEditingController name = TextEditingController(
    text: initial?.name ?? '',
  );
  final TextEditingController url = TextEditingController(
    text: initial?.url ?? '',
  );
  final TextEditingController headers = TextEditingController(
    text: (initial?.headers ?? <String, String>{}).entries
        .map((MapEntry<String, String> e) => '${e.key}: ${e.value}')
        .join('\n'),
  );
  String error = '';

  return showDialog<_ServerDraft>(
    context: context,
    builder: (BuildContext ctx) {
      return StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setState) {
          void save() {
            final String u = url.text.trim();
            final String n = name.text.trim();
            final Map<String, String> parsed = <String, String>{};
            for (final String line in headers.text.split('\n')) {
              final String t = line.trim();
              if (t.isEmpty) continue;
              final int i = t.indexOf(':');
              if (i <= 0) {
                setState(() => error = '请求头要写成「名称: 值」：$t');
                return;
              }
              parsed[t.substring(0, i).trim()] = t.substring(i + 1).trim();
            }
            try {
              McpClient.parseEndpoint(u);
            } catch (e) {
              setState(() => error = e.toString());
              return;
            }
            Navigator.of(ctx).pop(_ServerDraft(n.isEmpty ? u : n, u, parsed));
          }

          return AlertDialog(
            title: Text(initial == null ? '添加 MCP 服务器' : '编辑 MCP 服务器'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: name,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '名称（可选）',
                      hintText: '例如：公司知识库',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      hintText: 'https://example.com/mcp',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: headers,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '请求头（可选，一行一个）',
                      hintText: 'Authorization: Bearer ',
                    ),
                  ),
                  if (error.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      error,
                      style: AppFonts.body(
                        size: 12,
                        color: AppColors.danger,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: save,
                child: Text(initial == null ? '添加并连接' : '保存'),
              ),
            ],
          );
        },
      );
    },
  ).whenComplete(() {
    name.dispose();
    url.dispose();
    headers.dispose();
  });
}
