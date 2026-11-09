import 'package:flutter/material.dart';

import '../core/productivity.dart';
import '../core/store.dart';
import '../plugins/plugin.dart';
import '../shizuku/shizuku_service.dart';
import '../theme/app_theme.dart';
import 'app_drawer.dart';
import 'chat_page.dart';

/// 应用外壳：**首页就是一个对话**。
///
/// ## 为什么首页不是一屏卡片
///
/// 原来首页是一屏卡片（继续 / 聊天列表 / 计划 / 笔记 / 拓展）。那屏卡片
/// 的信息量其实很低：每次打开应用，用户要做的事几乎总是"接着说" ——
/// 要么继续上一个对话，要么开一个新的。让一屏卡片挡在这件事前面，
/// 等于每次都要多点一次，而卡片上还放不下真正的历史列表。
///
/// 现在打开应用**直接落在对话上**，其余的去处（历史对话 / 计划 / 笔记 /
/// 研究 / 设置）搬到侧边菜单里（见 [AppDrawer]）：
///  · 从屏幕左边缘往右拉，或从右边缘往左拉，都能把菜单拉出来；
///  · 也可以点左上角那个菜单图标。
///
/// ## 为什么仍然保留这一层
///
/// 它是"首页"的定义所在：一个**没有返回键**的对话（菜单键代替了它），
/// 以及"首次启动先建一个空会话"这件事。从别处 push 上来的对话页则
/// 不带菜单 —— 那种情况下用户要的是退回上一屏。
class HomeShell extends StatelessWidget {
  const HomeShell({
    super.key,
    required this.settings,
    required this.conversations,
    required this.plugins,
    required this.shizuku,
    required this.workDir,
    required this.notes,
    required this.tasks,
  });

  final Settings settings;
  final ConversationStore conversations;
  final PluginStore plugins;
  final ShizukuService shizuku;
  final String workDir;
  final NoteStore notes;
  final TaskStore tasks;

  @override
  Widget build(BuildContext context) {
    // 首次启动：一个会话都没有时先建一个空的。
    //
    // 这样用户打开应用就能直接打字，不需要先理解"我还没有对话，得先新建
    // 一个" —— 那是实现细节，不该让人先学会。
    //
    // ⚠️ **必须等历史读完**（`conversations.loaded`）：历史现在不在首帧
    // 前面加载，列表在启动初期天然是空的。这时候建会话等于凭空多一条
    // 空白页 —— 而且历史随后读到，用户看到的就是"每次打开都多一条
    // 空对话"。真正的首次启动判断只在 `loaded` 之后才有意义。
    if (conversations.loaded && conversations.conversations.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (conversations.loaded && conversations.conversations.isEmpty) {
          conversations.createNew();
        }
      });
    }

    return ChatPage(
      settings: settings,
      conversations: conversations,
      plugins: plugins,
      shizuku: shizuku,
      workDir: workDir,
      notes: notes,
      tasks: tasks,
      drawer: AppDrawer(
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        shizuku: shizuku,
        workDir: workDir,
        notes: notes,
        tasks: tasks,
      ),
    );
  }
}

/// 各页面共用的头部。
///
/// 抽出来是为了让各页面的头部样式完全一致 ——
/// 否则迟早会出现「对话页的标题 22px、笔记页 20px」这种细碎的不一致。
///
/// 现在它**不再是玻璃**：转 Material You 之后，顶栏就是主题色 + 状态层，
/// 而且 M3 的 `AppBar` 本来就带"内容滚到底下时抬升"的行为。
/// 各调用点给它传 `leading` / `actions` 就行。
///
/// ## 状态栏那一段留白，**已经由 `AppBar` 自己加过了**
///
/// `AppBar` 的 `primary`（默认 true）会把 `MediaQuery.padding.top` 加到
/// 自己头上，所以这类页面（记忆 / 工作空间 / 远程控制 / 设置…）的标题
/// 天然就在状态栏之下，而且因为标题在 `toolbarHeight`（56）里**垂直居中**，
/// 实际留白比裸数字看起来还宽一档 —— 不需要、也不该再补。
///
/// ⚠️ 所以**不要**给这个控件套 `SafeArea`，也不要给它加顶部内边距：
/// 那会和 `AppBar` 加的那一份叠加，标题凭空下移 24~48 像素。
///
/// 对话页的顶栏是**手写的**（`ChatPage._header`：一行图标 + 标题直接浮在
/// 内容上，不是 `AppBar`），它没有这层自动处理，所以那份 `padding.top`
/// 得自己加 —— 见那边的 `_headerGap`。两边不是同一套机制，别互相照抄。
class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.leading,
    this.bottom,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? leading;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    return AppBar(
      leading: leading,
      actions: <Widget>[...actions, const SizedBox(width: 6)],
      // 大标题栏 + 滚动抬升交给 M3 自己处理。
      toolbarHeight: subtitle == null && bottom == null ? kToolbarHeight : 72,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 22 + w600：M3 的标题档位。中文在同样磅值下视觉重量比拉丁字母
            // 大得多，再往上加就会压着下面的内容。
            style: AppFonts.body(
              size: 20,
              weight: FontWeight.w600,
              color: s.text,
              height: 1.2,
              letterSpacing: -0.2,
            ),
          ),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.body(size: 12.5, color: s.muted, height: 1.25),
            ),
          ],
        ],
      ),
      bottom: bottom == null
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: bottom,
              ),
            ),
    );
  }
}

/// 空状态提示（多个页面共用）
class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    required this.desc,
  });

  final IconData icon;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: s.muted.withValues(alpha: 0.6)),
            const SizedBox(height: 14),
            Text(
              title,
              style: AppFonts.body(
                size: 15,
                weight: FontWeight.w600,
                color: s.text,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              desc,
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 13, color: s.muted, height: 1.55),
            ),
          ],
        ),
      ),
    );
  }
}
