import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/backup.dart';
import '../core/productivity.dart';
import '../core/store.dart';
import '../plugins/plugin.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';

/// 导入 / 导出备份。
///
/// 单独成文件是因为这里既有文件选择、又有覆盖确认、还要处理部分导入，
/// 塞进设置面板会让那个文件继续膨胀。
class BackupActions {
  const BackupActions._();

  /// 导出。返回给用户看的提示，null 表示用户取消。
  static Future<String?> export(
    BuildContext context, {
    required Settings settings,
    required ConversationStore conversations,
    required NoteStore notes,
    required TaskStore tasks,
    required PluginStore plugins,
  }) async {
    // 密钥默认不带出去。备份文件经常被丢进网盘、发进聊天，
    // 里面躺着一串明文 API Key 是很实际的风险。
    final bool? includeSecrets = await _askSecrets(context);
    if (includeSecrets == null) return null;

    final Map<String, dynamic> bundle = Backup.build(
      // 走 `history` 而不是 `conversations`：空白页不是内容，
      // 备份里塞一条「新对话」只会让人以为导出坏了（见 Conversation.isBlank）。
      conversations: conversations.history,
      notes: notes.items,
      tasks: tasks.items,
      plugins: plugins.plugins,
      settings: settings,
      includeSecrets: includeSecrets,
    );

    final String json = Backup.encode(bundle);
    final String name = Backup.suggestedFileName();

    try {
      final FileSaveLocation? loc = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: <XTypeGroup>[
          const XTypeGroup(label: 'JSON', extensions: <String>['json']),
        ],
      );
      if (loc == null) return null;

      String path = loc.path;
      if (!path.toLowerCase().endsWith('.json')) path = '$path.json';

      await File(path).writeAsString(json);

      final int conv = conversations.history.length;
      final int n = notes.items.length;
      final int t = tasks.items.length;
      return '已导出：会话 $conv、笔记 $n、任务 $t'
          '${includeSecrets ? '（含 API Key）' : '（不含 API Key）'}';
    } catch (e) {
      return '导出失败：$e';
    }
  }

  /// 导入。返回给用户看的提示。
  static Future<String?> import(
    BuildContext context, {
    required Settings settings,
    required ConversationStore conversations,
    required NoteStore notes,
    required TaskStore tasks,
    required PluginStore plugins,
  }) async {
    final XFile? file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[
        const XTypeGroup(label: 'JSON', extensions: <String>['json']),
      ],
    );
    if (file == null) return null;

    final BackupContents contents;
    try {
      contents = Backup.parse(await file.readAsString());
    } on BackupException catch (e) {
      return '文件无法识别：${e.message}';
    } catch (e) {
      return '读取失败：$e';
    }

    if (!context.mounted) return null;

    if (contents.isEmpty) {
      return '文件里没有可导入的内容。';
    }

    final String? mode = await _askMode(context, contents);
    if (mode == null) return null;

    final bool replace = mode == 'replace';

    // ---- 会话 ----
    if (contents.conversations.isNotEmpty) {
      if (replace) {
        conversations.replaceAll(contents.conversations);
      } else {
        // 合并时按 id 去重：重复导入同一个文件不该产生一堆重复会话
        conversations.appendMissing(contents.conversations);
      }
    }

    // ---- 笔记 ----
    if (contents.notes.isNotEmpty) {
      if (replace) {
        notes.replaceAll(contents.notes);
      } else {
        final Set<String> existing = notes.items.map((Note n) => n.id).toSet();
        for (final Note n in contents.notes) {
          if (!existing.contains(n.id)) notes.items.add(n);
        }
        notes.saveQuietly();
      }
    }

    // ---- 任务 ----
    if (contents.tasks.isNotEmpty) {
      if (replace) {
        tasks.replaceAll(contents.tasks);
      } else {
        final Set<String> existing = tasks.items
            .map((TaskItem t) => t.id)
            .toSet();
        for (final TaskItem t in contents.tasks) {
          if (!existing.contains(t.id)) tasks.items.add(t);
        }
        tasks.saveQuietly();
      }
    }

    // ---- 插件 ----
    if (contents.plugins.isNotEmpty) {
      if (replace) {
        plugins.plugins
          ..clear()
          ..addAll(contents.plugins);
      } else {
        final Set<String> existing = plugins.plugins
            .map((CustomPlugin p) => p.name)
            .toSet();
        for (final CustomPlugin p in contents.plugins) {
          if (!existing.contains(p.name)) plugins.plugins.add(p);
        }
      }
      await plugins.save();
    }

    // ---- 设置（只应用非敏感项；密钥在 parse 时已被剥掉）----
    if (contents.settings.isNotEmpty) {
      await Backup.applySettings(settings, contents.settings);
    }

    final int conv = contents.conversations.length;
    final int n = contents.notes.length;
    final int t = contents.tasks.length;
    return '已导入${replace ? '（覆盖）' : '（合并）'}：'
        '会话 $conv、笔记 $n、任务 $t、插件 ${contents.plugins.length}。'
        '${contents.settings.isEmpty ? '' : '设置项也已应用（不含 API Key）。'}';
  }

  /// 两个确认框共用的外壳：图标块 + 标题，正文，底部按钮。
  ///
  /// 之前两处各自写了一遍 `AlertDialog`，圆角来自主题（[AppRadius.sheet]），
  /// 但标题字号、正文间距、按钮之间的空隙三处都不完全一样。
  /// 收成一个函数之后，改一次两处都跟着变。
  ///
  /// 回调签名、返回值和 `showDialog` 的行为完全不变。
  static Future<T?> _dialog<T>(
    BuildContext context, {
    required IconData icon,
    required Color tone,
    required String title,
    required Widget body,
    // 动作按钮由外部按**对话框自己的 context** 构造：用外层的 context
    // 取 Navigator 虽然通常也对（顶层 Navigator 是同一个），
    // 但在嵌套 Navigator（工作台里的子页面）里会 pop 错一层。
    required List<Widget> Function(BuildContext ctx) actions,
  }) {
    return showDialog<T>(
      context: context,
      builder: (BuildContext ctx) {
        final AppSurface s = AppSurface.of(ctx);
        return AlertDialog(
          // 圆角走主题的 dialogTheme（AppRadius.sheet），这里只定内边距。
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          actionsPadding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
          title: Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.code),
                ),
                child: Icon(icon, size: 18, color: tone),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  title,
                  style: AppFonts.body(
                    size: 16.5,
                    weight: FontWeight.w600,
                    color: s.text,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          content: body,
          actions: <Widget>[
            for (final Widget a in actions(ctx)) a,
          ],
        );
      },
    );
  }

  /// 问是否把 API Key 一起导出
  static Future<bool?> _askSecrets(BuildContext context) {
    return _dialog<bool>(
      context,
      icon: Icons.key_outlined,
      tone: AppColors.warning,
      title: '导出备份',
      body: mdText(
        '将导出会话、笔记、任务、插件和设置。\n\n'
        '是否包含 API Key？\n'
        '· 不包含（推荐）—— 备份文件可以安全地存网盘或分享，'
        '换设备后手动填一次 Key 即可。\n'
        '· 包含 —— 省事，但**文件里会有一串明文密钥**，'
        '一旦泄露别人可以直接用你的额度。',
        style: AppFonts.body(size: 13, height: 1.6),
      ),
      actions: (BuildContext ctx) => <Widget>[
        GlassButton(label: '取消', onTap: () => Navigator.of(ctx).pop()),
        GlassButton(
          label: '包含 Key',
          onTap: () => Navigator.of(ctx).pop(true),
        ),
        GlassButton(
          label: '不包含',
          accent: true,
          onTap: () => Navigator.of(ctx).pop(false),
        ),
      ],
    );
  }

  /// 问合并还是覆盖
  static Future<String?> _askMode(
    BuildContext context,
    BackupContents contents,
  ) {
    return _dialog<String>(
      context,
      icon: Icons.download_rounded,
      tone: AppColors.accent,
      title: '导入方式',
      body: mdText(
        '文件里含有：会话 ${contents.conversations.length}、'
        '笔记 ${contents.notes.length}、'
        '任务 ${contents.tasks.length}、'
        '插件 ${contents.plugins.length}。\n\n'
        '· 合并 —— 保留现有内容，只补进文件里有而本地没有的（按 id 判断）。\n'
        '· 覆盖 —— **清空现有内容**再写入，现有数据会丢失。',
        style: AppFonts.body(size: 13, height: 1.6),
      ),
      actions: (BuildContext ctx) => <Widget>[
        GlassButton(label: '取消', onTap: () => Navigator.of(ctx).pop()),
        GlassButton(
          label: '覆盖',
          danger: true,
          onTap: () => Navigator.of(ctx).pop('replace'),
        ),
        GlassButton(
          label: '合并',
          accent: true,
          onTap: () => Navigator.of(ctx).pop('merge'),
        ),
      ],
    );
  }
}
