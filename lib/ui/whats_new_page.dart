import 'package:flutter/material.dart';

import '../core/app_info.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';

/// 版本更新后的「新版本特性」页。
///
/// 只在这次版本第一次打开时出现一次（见 main.dart 的 [_maybeShowWhatsNew]）。
///
/// ## 内容必须跟着版本走
///
/// 这一页是用户**唯一**会读的更新说明。写"更安全、更流畅、更智能"
/// 那种话等于没写 —— 用户看完还是不知道这次能多做什么。
/// 所以每一条都写**具体能力**：能用它做什么、在哪、和以前差在哪。
class WhatsNewPage extends StatelessWidget {
  const WhatsNewPage({super.key});

  /// 这次版本的主标题。
  static const String _version = '3.0.0';

  /// 一句话总结。
  static const String _lead = '这一版把"怎么看文件"和"怎么改文件"整条链路重做了一遍，'
      '并加入了工作组。';

  static const List<(IconData, String, String)> _features =
      <(IconData, String, String)>[
        (
          Icons.workspaces_outline,
          '工作组：多条对话共用一个项目',
          '把调研、写稿、核对拆成几个对话，各自干净；但它们共享同一份 agent.md '
              '（项目背景、称呼口径、产出格式）和同一批资料文件。'
              '组里可以引用本地文件夹，也可以随意增删、复制粘贴、建子文件夹，AI 也能改。',
        ),
        (
          Icons.edit_note_rounded,
          'writer：按段改文件，不再整份重写',
          '改一行只发那一行。原文不经过模型复述，所以它不可能记漏；'
              '改动片段会直接显示在思考链里，不用点开就能看出改了哪儿。'
              '要改的那段出现多次时会拒绝执行并说明原因，而不是猜一处改掉。',
        ),
        (
          Icons.article_outlined,
          'reader：默认只给摘要',
          '看文件先拿到大小、行数、开头和结构索引；要正文就指定行范围，'
              '或直接 grep 关键词。四十万字的文件也能看，而且不会把整份塞进上下文。',
        ),
        (
          Icons.search_rounded,
          'filesearch：结构化找文件',
          '按名字、通配或正则找，结果带路径、大小、修改时间，分页返回。'
              '找"刚下的那个文件"可以按最近修改时间筛。',
        ),
        (
          Icons.bolt_rounded,
          'sheller：把文件喂给命令，而不是拼进命令行',
          '参数写 path://a 会解析成真实路径，stdin://a 接到标准输入。'
              '大内容因此不会撞上命令行长度上限 —— 那个失败以前看起来像"引号写错了"。',
        ),
        (
          Icons.inventory_2_outlined,
          '对象池：大内容只传句柄',
          '同一份大内容要用好几次时，存成 obj://a 之后每次只花几个字符。'
              '在回复里写 {{obj://a}} 会自动展开成原文，{{obj://a:10-20}} 只展开那几行。',
        ),
        (
          Icons.psychology_outlined,
          '思考中的指示器重做',
          '原来是三个点（像省略号）和转圈（像加载失败），现在改成图标在原地呼吸 —— '
              '和"已思考 x 秒"是同一个字形、同一个位置，切换时图标不跳。',
        ),
        (
          Icons.format_align_left_rounded,
          '侧栏历史去掉圆角卡片',
          '每条历史改成通栏的平直一行，靠选中底色和行间距区分。'
              '和下面的工作组、文件列表放在一起时，不再有两种轮廓互相打架。',
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    return Scaffold(
      backgroundColor: s.pageBg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 26, 20, 28),
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    size: 23,
                    color: AppColors.accent,
                  ),
                ),
                const SizedBox(width: 13),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      kAppName,
                      style: AppFonts.body(
                        size: 23,
                        weight: FontWeight.w700,
                        color: s.text,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '版本 $_version',
                      style: AppFonts.body(
                        size: 12.5,
                        color: s.muted,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              _lead,
              style: AppFonts.body(size: 13.5, color: s.muted, height: 1.6),
            ),
            const SizedBox(height: 20),
            for (final (IconData icon, String title, String desc)
                in _features) ...<Widget>[
              SurfaceCard(
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: s.chipBg,
                        borderRadius: BorderRadius.circular(AppRadius.code),
                      ),
                      child: Icon(icon, size: 19, color: AppColors.accent),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title,
                            style: AppFonts.body(
                              size: 14.5,
                              weight: FontWeight.w600,
                              color: s.text,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            desc,
                            style: AppFonts.body(
                              size: 12.5,
                              color: s.muted,
                              height: 1.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            Text(
              '名称从 MindClaw 改为 Zeus，版本号进入 3.x —— '
              '这一版换了新图标，界面里的名字也跟着改了。',
              style: AppFonts.body(size: 11.5, color: s.muted, height: 1.6),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                backgroundColor: AppColors.accent,
                foregroundColor: AppColors.onAccent,
              ),
              child: const Text('开始使用'),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                kAppVersionLabel,
                style: AppFonts.body(size: 11, color: s.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
