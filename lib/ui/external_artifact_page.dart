import 'package:flutter/material.dart';

import '../core/external_artifact.dart';
import '../core/external_artifact_bridge.dart';
import '../theme/app_theme.dart';
import 'home_shell.dart';

/// 已安装的 External Artifact 列表。
///
/// 原来这一块是设置页里的一张卡片：列表一长就把设置页撑得没边，
/// 而且它本身是"装了什么、能做什么"的浏览型内容，不是开关。
/// 拆成二级页面之后，设置页只留一个入口和数量。
class ExternalArtifactPage extends StatefulWidget {
  const ExternalArtifactPage({super.key, required this.store});

  final ExternalArtifactStore store;

  @override
  State<ExternalArtifactPage> createState() => _ExternalArtifactPageState();
}

class _ExternalArtifactPageState extends State<ExternalArtifactPage> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await ExternalArtifactBridge.instance.discover();
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    return Scaffold(
      backgroundColor: s.pageBg,
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (BuildContext context, Widget? _) {
          final List<ExternalArtifact> arts = widget.store.artifacts;
          return Column(
            children: <Widget>[
              AppHeader(
                title: 'External Artifact',
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                actions: <Widget>[
                  IconButton(
                    onPressed: _refreshing ? null : _refresh,
                    icon: _refreshing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    tooltip: '刷新',
                  ),
                ],
              ),
              Expanded(
                child: arts.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              Icons.extension_off_rounded,
                              size: 40,
                              color: s.muted.withValues(alpha: 0.5),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              '未发现已安装的 External Artifact',
                              style: AppFonts.body(size: 14, color: s.muted),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _refresh,
                              icon: const Icon(
                                Icons.refresh_rounded,
                                size: 16,
                              ),
                              label: const Text('刷新'),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                        itemCount: arts.length,
                        itemBuilder: (BuildContext context, int i) {
                          return _ArtifactTile(artifact: arts[i], s: s);
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ArtifactTile extends StatefulWidget {
  const _ArtifactTile({required this.artifact, required this.s});

  final ExternalArtifact artifact;
  final AppSurface s;

  @override
  State<_ArtifactTile> createState() => _ArtifactTileState();
}

class _ArtifactTileState extends State<_ArtifactTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ExternalArtifact art = widget.artifact;
    final AppSurface s = widget.s;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: s.border, width: 0.8),
        ),
        child: Column(
          children: <Widget>[
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        Icons.extension_rounded,
                        size: 19,
                        color: AppColors.accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            art.label,
                            style: AppFonts.body(
                              size: 14.5,
                              color: s.text,
                              height: 1.3,
                            ),
                          ),
                          Text(
                            '${art.tools.length} 个技能 · ${art.packageName}',
                            style: AppFonts.body(
                              size: 11.5,
                              color: s.muted,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: Icon(
                        Icons.expand_more_rounded,
                        size: 18,
                        color: s.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded && art.tools.isNotEmpty) ...<Widget>[
              Divider(height: 1, color: s.border),
              ...art.tools.map(
                (ArtifactToolDef t) => Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Row(
                    children: <Widget>[
                      const SizedBox(width: 48),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              t.title,
                              style: AppFonts.body(
                                size: 13.5,
                                color: s.text,
                                height: 1.3,
                              ),
                            ),
                            if (t.description.isNotEmpty)
                              Text(
                                t.description,
                                style: AppFonts.body(
                                  size: 11.5,
                                  color: s.muted,
                                  height: 1.4,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
