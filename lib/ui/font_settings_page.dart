import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/custom_font.dart';
import '../core/store.dart';
import '../theme/app_theme.dart';
import '../theme/font_options.dart';
import '../theme/glass.dart';
import 'home_shell.dart';

/// **字体设置页**。
///
/// ## 为什么单独一页
///
/// 三组字体 × 每组五六个选项，再加上字号滑杆，直接摊在外观小节里会变成
/// 一堵墙 —— 用户进设置只是改个颜色，却要划过几十行字体选项。
/// 所以外观里只留**一个入口**（显示当前组合），点进来才是完整选项。
///
/// ## 选项从哪来
///
/// 见 `theme/font_options.dart`：只有 Inter 是打进 APK 的，其余是系统族名
/// （`serif` / `monospace` / `sans-serif-condensed`…）。这样不增加包体，
/// 也仍然给得出"衬线 / 等宽 / 窄体"这些真实存在的差别。
/// 想要**任意**字体就导入 `.ttf` / `.otf` —— 运行时加载，不进仓库。
class FontSettingsPage extends StatefulWidget {
  const FontSettingsPage({super.key, required this.settings});

  final Settings settings;

  @override
  State<FontSettingsPage> createState() => _FontSettingsPageState();
}

class _FontSettingsPageState extends State<FontSettingsPage> {
  Settings get _s => widget.settings;

  /// 当前生效的三组选项（含"自定义"那一项，导入过才有）。
  FontOption get _latin =>
      resolveFont(withCustom(kLatinFonts, CustomFont.latin), _s.fontLatin);
  FontOption get _cjk =>
      resolveFont(withCustom(kCjkFonts, CustomFont.cjk), _s.fontCjk);
  FontOption get _code =>
      resolveFont(withCustom(kCodeFonts, CustomFont.code), _s.fontCode);

  Future<void> _select(
    String id,
    void Function(String) write,
  ) async {
    await _s.update(() => write(id));
    if (mounted) setState(() {});
  }

  /// 导入一个字体文件到某个槽位。
  ///
  /// **先复制进应用目录，再加载**：
  ///  · `file_selector` 在 Android 上给的是临时缓存路径（甚至可能是内容
  ///    URI 的副本），系统清理缓存后字体就没了；
  ///  · 复制到 `docs/fonts/` 之后，路径是稳定的，重启应用仍指向同一个文件。
  ///
  /// **先加载、再落盘设置**：加载失败时不该把用户原来能用的字体也换掉。
  Future<void> _importFont(
    String slot, {
    required void Function(String) writePath,
    required void Function(String) writeId,
  }) async {
    const XTypeGroup group = XTypeGroup(
      label: '字体文件',
      extensions: <String>['ttf', 'otf'],
    );
    final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[group]);
    if (file == null) return;

    String dest;
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      final Directory dir = Directory('${docs.path}/fonts');
      await dir.create(recursive: true);
      final String name = file.name;
      final int dot = name.lastIndexOf('.');
      final String ext = dot >= 0 ? name.substring(dot).toLowerCase() : '.ttf';
      dest =
          '${dir.path}/${slot}_${DateTime.now().millisecondsSinceEpoch}$ext';
      await File(dest).writeAsBytes(await file.readAsBytes(), flush: true);
    } catch (e) {
      if (mounted) _snack('读取字体文件失败：$e');
      return;
    }

    final String? error = await CustomFont.loadFrom(slot, dest);
    if (error != null) {
      // 加载失败：把刚复制进来的文件删掉，别在 docs/fonts 里留垃圾。
      try {
        await File(dest).delete();
      } catch (_) {}
      if (mounted) _snack(error);
      return;
    }

    // 换新文件时把上一份删掉，避免 docs/fonts 里越攒越多。
    final String previous = switch (slot) {
      CustomFont.latin => _s.fontLatinPath,
      CustomFont.cjk => _s.fontCjkPath,
      _ => _s.fontCodePath,
    };
    if (previous.trim().isNotEmpty && previous != dest) {
      try {
        final File old = File(previous);
        if (await old.exists() && previous.contains(RegExp(r'[/\\]fonts[/\\]'))) {
          await old.delete();
        }
      } catch (_) {
        // 删不掉就算了：不影响新字体生效。
      }
    }

    await _s.update(() {
      writePath(dest);
      writeId('custom');
    });
    if (mounted) setState(() {});
  }

  Future<void> _removeCustom(
    String slot, {
    required void Function(String) writePath,
    required void Function(String) writeId,
    required String fallbackId,
  }) async {
    final String previous = switch (slot) {
      CustomFont.latin => _s.fontLatinPath,
      CustomFont.cjk => _s.fontCjkPath,
      _ => _s.fontCodePath,
    };
    final bool wasCustom = _selectedId(slot) == 'custom';
    CustomFont.clear(slot);
    await _s.update(() {
      writePath('');
      // 当前选的就是这份自定义字体才需要退回默认；选的是别的项时
      // 删掉文件不影响当前观感。
      if (wasCustom) writeId(fallbackId);
    });
    if (previous.trim().isNotEmpty &&
        previous.contains(RegExp(r'[/\\]fonts[/\\]'))) {
      try {
        final File old = File(previous);
        if (await old.exists()) await old.delete();
      } catch (_) {
        // 删不掉不影响界面：设置里已经不再引用它了。
      }
    }
    if (mounted) setState(() {});
  }

  /// 当前某个槽位选中的 id。
  String _selectedId(String slot) => switch (slot) {
    CustomFont.latin => _s.fontLatin,
    CustomFont.cjk => _s.fontCjk,
    _ => _s.fontCode,
  };

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final FontOption latin = _latin;
    final FontOption cjk = _cjk;
    final FontOption code = _code;

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: '字体',
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
              children: <Widget>[
                _previewCard(s, latin, cjk, code),
                const SizedBox(height: 18),
                _group(
                  s,
                  title: '英文字体',
                  desc: '同时决定界面文字。中文由下一组接住。',
                  options: withCustom(kLatinFonts, CustomFont.latin),
                  selected: _s.fontLatin,
                  slot: CustomFont.latin,
                  sample: 'The quick brown fox 0123456789',
                  previewStyle: (FontOption o) => TextStyle(
                    fontFamily: o.family,
                    fontFamilyFallback: <String>[cjk.family ?? 'sans-serif'],
                    fontSize: 15,
                    height: 1.4,
                    color: s.text,
                  ),
                  onSelect: (String id) => _select(id, (String v) {
                    _s.fontLatin = v;
                  }),
                  onImport: () => _importFont(
                    CustomFont.latin,
                    writePath: (String v) => _s.fontLatinPath = v,
                    writeId: (String v) => _s.fontLatin = v,
                  ),
                  onRemove: () => _removeCustom(
                    CustomFont.latin,
                    writePath: (String v) => _s.fontLatinPath = v,
                    writeId: (String v) => _s.fontLatin = v,
                    fallbackId: 'inter',
                  ),
                ),
                const SizedBox(height: 18),
                _group(
                  s,
                  title: '中文字体',
                  desc: '只接住英文字体没有的字形（汉字、标点）。',
                  options: withCustom(kCjkFonts, CustomFont.cjk),
                  selected: _s.fontCjk,
                  slot: CustomFont.cjk,
                  sample: '汉字排版预览：永和九年，岁在癸丑',
                  previewStyle: (FontOption o) => TextStyle(
                    fontFamily: latin.family,
                    fontFamilyFallback: <String>[
                      if (o.family != null) o.family!,
                      'sans-serif',
                    ],
                    fontSize: 15,
                    height: 1.5,
                    color: s.text,
                  ),
                  onSelect: (String id) => _select(id, (String v) {
                    _s.fontCjk = v;
                  }),
                  onImport: () => _importFont(
                    CustomFont.cjk,
                    writePath: (String v) => _s.fontCjkPath = v,
                    writeId: (String v) => _s.fontCjk = v,
                  ),
                  onRemove: () => _removeCustom(
                    CustomFont.cjk,
                    writePath: (String v) => _s.fontCjkPath = v,
                    writeId: (String v) => _s.fontCjk = v,
                    fallbackId: 'system',
                  ),
                ),
                const SizedBox(height: 18),
                _group(
                  s,
                  title: '代码字体',
                  desc: '代码块、命令、路径、工具输出。等宽对齐更稳。',
                  options: withCustom(
                    kCodeFonts,
                    CustomFont.code,
                    fallback: <String>['monospace', 'sans-serif'],
                  ),
                  selected: _s.fontCode,
                  slot: CustomFont.code,
                  sample: 'const answer = 42; // 注释',
                  previewStyle: (FontOption o) => TextStyle(
                    fontFamily: o.family,
                    fontFamilyFallback: o.fallback.isEmpty
                        ? const <String>['monospace', 'sans-serif']
                        : o.fallback,
                    fontSize: 14,
                    height: 1.5,
                    color: s.text,
                  ),
                  onSelect: (String id) => _select(id, (String v) {
                    _s.fontCode = v;
                  }),
                  onImport: () => _importFont(
                    CustomFont.code,
                    writePath: (String v) => _s.fontCodePath = v,
                    writeId: (String v) => _s.fontCode = v,
                  ),
                  onRemove: () => _removeCustom(
                    CustomFont.code,
                    writePath: (String v) => _s.fontCodePath = v,
                    writeId: (String v) => _s.fontCode = v,
                    fallbackId: 'monospace',
                  ),
                ),
                const SizedBox(height: 22),
                _sizeSection(s),
                const SizedBox(height: 14),
                _note(
                  s,
                  '导入的字体只对本机这一份安装生效（文件不进仓库），'
                  '换设备要重新选一次。文件被删掉时会自动回落到内置字体。',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部实时预览：一眼看到三套字体组合在一起的效果。
  Widget _previewCard(
    AppSurface s,
    FontOption latin,
    FontOption cjk,
    FontOption code,
  ) {
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.text_fields_rounded, size: 17, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                '预览',
                style: AppFonts.body(
                  size: 13,
                  weight: FontWeight.w600,
                  color: s.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'The quick brown fox jumps over the lazy dog 0123',
            style: TextStyle(
              fontFamily: latin.family,
              fontFamilyFallback: <String>[cjk.family ?? 'sans-serif'],
              fontSize: 15.5,
              height: 1.5,
              color: s.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '永和九年，岁在癸丑，暮春之初，会于会稽山阴之兰亭。',
            style: TextStyle(
              fontFamily: latin.family,
              fontFamilyFallback: <String>[cjk.family ?? 'sans-serif'],
              fontSize: 15.5,
              height: 1.6,
              color: s.text,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              color: s.codeBg,
              borderRadius: BorderRadius.circular(AppRadius.field),
              border: Border.all(color: s.border, width: 0.6),
            ),
            child: Text(
              'const answer = 42; // 等宽字体预览',
              style: TextStyle(
                fontFamily: code.family,
                fontFamilyFallback: code.fallback,
                fontSize: 13,
                height: 1.5,
                color: s.text,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 一组字体选项。
  Widget _group(
    AppSurface s, {
    required String title,
    required String desc,
    required List<FontOption> options,
    required String selected,
    required String slot,
    required String sample,
    required TextStyle Function(FontOption) previewStyle,
    required ValueChanged<String> onSelect,
    required VoidCallback onImport,
    required VoidCallback onRemove,
  }) {
    final bool hasCustom = CustomFont.loaded(slot);
    final String error = CustomFont.errorOf(slot);
    final FontOption current = resolveFont(options, selected);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: AppFonts.body(
            size: 14.5,
            weight: FontWeight.w600,
            color: s.text,
          ),
        ),
        const SizedBox(height: 3),
        Text(desc, style: AppFonts.body(size: 12, color: s.muted)),
        const SizedBox(height: 8),
        SurfaceCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: <Widget>[
              for (final FontOption o in options)
                _optionRow(
                  s,
                  option: o,
                  active: current.id == o.id,
                  sample: sample,
                  style: previewStyle(o),
                  onTap: () => onSelect(o.id),
                ),
              Divider(color: s.border, height: 1),
              _actionRow(
                s,
                icon: Icons.file_open_outlined,
                label: hasCustom ? '更换字体文件…' : '导入字体文件…',
                onTap: onImport,
              ),
              if (hasCustom)
                _actionRow(
                  s,
                  icon: Icons.close_rounded,
                  label: '移除自定义字体',
                  danger: true,
                  onTap: onRemove,
                ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                  child: Text(
                    error,
                    style: AppFonts.body(
                      size: 11.5,
                      color: AppColors.danger,
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _optionRow(
    AppSurface s, {
    required FontOption option,
    required bool active,
    required String sample,
    required TextStyle style,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Icon(
              active
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 19,
              color: active ? AppColors.accent : s.muted,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        option.label,
                        style: AppFonts.body(
                          size: 14,
                          weight: active ? FontWeight.w600 : FontWeight.w400,
                          color: s.text,
                        ),
                      ),
                      if (option.note.isNotEmpty) ...<Widget>[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            option.note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.body(size: 11, color: s.muted),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sample,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionRow(
    AppSurface s, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final Color fg = danger ? AppColors.danger : AppColors.accent;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 11),
            Text(label, style: AppFonts.body(size: 13.5, color: fg)),
          ],
        ),
      ),
    );
  }

  /// 字号。原来在外观小节里，现在跟着字体一起进来 ——
  /// 它们回答的是同一个问题："这屏字看起来舒服吗"。
  Widget _sizeSection(AppSurface s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '字号',
          style: AppFonts.body(
            size: 14.5,
            weight: FontWeight.w600,
            color: s.text,
          ),
        ),
        const SizedBox(height: 8),
        SurfaceCard(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('整体字号', style: AppFonts.body(size: 13, color: s.text)),
                  const Spacer(),
                  Text(
                    '${(AppFonts.baseScale * _s.fontScale * 100).round()}%',
                    style: AppFonts.code(size: 12, color: AppColors.accent),
                  ),
                ],
              ),
              Slider(
                value: _s.fontScale,
                min: 0.85,
                max: 1.4,
                divisions: 11,
                label:
                    '${(AppFonts.baseScale * _s.fontScale * 100).round()}%',
                onChanged: (double v) {
                  _s.update(() => _s.fontScale = v);
                  setState(() {});
                },
              ),
              Divider(color: s.border, height: 1),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Text('横屏字号', style: AppFonts.body(size: 13, color: s.text)),
                  const Spacer(),
                  Text(
                    '${(_s.landscapeFontScale * 100).round()}%',
                    style: AppFonts.code(size: 12, color: AppColors.accent),
                  ),
                ],
              ),
              Slider(
                value: _s.landscapeFontScale,
                min: 0.85,
                max: 1.4,
                divisions: 11,
                label: '${(_s.landscapeFontScale * 100).round()}%',
                onChanged: (double v) {
                  _s.update(() => _s.landscapeFontScale = v);
                  setState(() {});
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _note(AppSurface s, String text) {
    return Text(
      text,
      style: AppFonts.body(size: 11.6, color: s.muted, height: 1.6),
    );
  }
}
