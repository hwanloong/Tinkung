import 'package:flutter/material.dart';

import '../core/store.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';

/// 使用模式的一个选项。
///
/// 用 record 而不是 enum：这一页只是"从三条里挑一条"，
/// 真正决定行为的是 `Settings.assistantMode` 里的那个字符串
/// （`lib/ai/agent.dart` 的模式段按它拼提示词）。在这里再造一个
/// enum 就得写一层到字符串的映射，多一处能写错的地方。
/// record 把 id / 文案 / 图标放在一起，改文案时不会漏掉其中一份。
typedef _Mode = ({String id, IconData icon, String title, String desc});

/// 「工作方式」选择页：学生 / 日常 / 程序员。
///
/// ## 为什么单独成页，而不是塞进设置里
///
/// 这三个选项决定的是**模型的说话方式**（见 `buildSystemPrompt` 的模式段），
/// 比字号、配色这类外观项重得多，而且首次启动必须先撞上它一次 ——
/// 塞进设置面板最深处，等于默认所有人都用「日常」，而不知道自己选过。
///
/// ## 为什么三张卡片竖着排，而不是三个并排的小方块
///
/// 每一项都带一句说明（"讲清楚再动手…"），并排三等分会把每段文字
/// 挤成两行折行、参差不齐；竖排每张卡都能把说明写完整。
/// 而且这是**一次性的低频选择**，一屏看全比"省一屏高度"重要。
class AssistantModePage extends StatefulWidget {
  const AssistantModePage({
    super.key,
    required this.settings,
    this.firstRun = false,
  });

  final Settings settings;

  /// 首次启动时为 true：没有返回箭头、按钮文案是「开始使用」。
  ///
  /// 首次启动必须选一个 —— 给个返回箭头，用户一滑就退回了设置以外的
  /// 空白状态，而这时 [Settings.assistantMode] 还是空串，下次启动又弹。
  final bool firstRun;

  /// 模式 id → 中文名。空串（或任何不认识的旧值）→ 未选择。
  ///
  /// 设置入口的 `trailingText` 也走这里：两处各写一份 switch，
  /// 迟早出现"设置里显示学生、选择页停在日常"这种对不上的问题。
  static String labelOf(String mode) => switch (mode) {
    'student' => '学生',
    'daily' => '日常',
    'programmer' => '程序员',
    _ => '未选择',
  };

  @override
  State<AssistantModePage> createState() => _AssistantModePageState();
}

class _AssistantModePageState extends State<AssistantModePage> {
  static const List<_Mode> _modes = <_Mode>[
    (
      id: 'student',
      icon: Icons.school_outlined,
      title: '学生',
      desc: '讲清楚再动手：先解释、分步说、多用图',
    ),
    (
      id: 'daily',
      icon: Icons.wb_sunny_outlined,
      title: '日常',
      desc: '简洁直接：能一句话说清就不多说',
    ),
    (
      id: 'programmer',
      icon: Icons.terminal_rounded,
      title: '程序员',
      desc: '代码优先：命令、路径、报错原样给出，直接动手',
    ),
  ];

  /// 当前选中的模式 id；null = 还没选。
  ///
  /// 首启时从空串开始（必须亲手选一次）；从设置进来时预选中已保存的，
  /// 这样"我只想改一下"的人不用再点一遍才知道现在是什么。
  String? _picked;

  @override
  void initState() {
    super.initState();
    final String saved = widget.settings.assistantMode;
    // 只认已知的三个值：空串和任何意外值都当"未选择"，
    // 免得界面上出现一个没有任何一张卡点亮、但按钮又允许点的状态。
    if (_modes.any((_Mode m) => m.id == saved)) _picked = saved;
  }

  Future<void> _save() async {
    final String? id = _picked;
    if (id == null) return;
    await widget.settings.update(() => widget.settings.assistantMode = id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: widget.firstRun ? '先选一个工作方式' : '工作方式',
            // 首启不给返回：这个页面是"必须先答完的第一道题"，
            // 退回去只会落在还没初始化的聊天页上。
            //
            // 这里必须给一个**占位**的 leading，不能写 null：
            // `AppBar` 在 `leading == null` 时会自己推断出返回箭头
            // （只要当前路由能 pop），那样首启页右上照样能退出去。
            // 占位用一个空盒子，标题的左边距和其它页保持一致。
            leading: widget.firstRun
                ? const SizedBox.shrink()
                : BackButton(onPressed: () => Navigator.of(context).maybePop()),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              children: <Widget>[
                _intro(s),
                const SizedBox(height: 18),
                for (final _Mode m in _modes) ...<Widget>[
                  _modeCard(s, m),
                  // 卡与卡之间固定 10：卡片本身圆角 20、带描边，
                  // 间距再大就会散成"三个互不相关的块"，而它们其实是
                  // 同一道题的三选一。
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
          // 按钮固定在底部，不跟着列表滚：只有三项时它本来就在屏幕里，
          // 但横屏 / 大字号下会滚走 —— 而这是页面上唯一能完成的动作。
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: GlassButton(
                label: widget.firstRun ? '开始使用' : '完成',
                accent: true,
                expand: true,
                // 没选就把按钮压暗（GlassButton 在 onTap == null 时降到 0.4），
                // 而不是弹一个提示 —— 页面上只有三张卡，点一张是很自然的事，
                // 出一句"请先选择"的报错反而像在责怪用户。
                onTap: _picked == null ? null : _save,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 标题下方那句总说明：回答"这选的是什么、以后能不能改"。
  ///
  /// 必须明说**随时可改** —— 否则用户会以为这是不可逆的初始化步骤，
  /// 在首启页上反复犹豫。
  Widget _intro(AppSurface s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '选一个最像你的场景，AI 会按它调整解释的详略和动手的节奏。',
          style: AppFonts.body(size: 13.5, color: s.muted, height: 1.5),
        ),
        const SizedBox(height: 4),
        Text(
          '之后随时可以在「设置 → 外观与字号」里改回来。',
          style: AppFonts.body(size: 12.5, color: s.muted, height: 1.5),
        ),
      ],
    );
  }

  /// 单张可选卡片。
  ///
  /// 这里用 `Container` + 手写描边，而不是 `SurfaceCard`：
  /// 后者的描边宽度固定在 1.1，没法让**选中**那张用 1.4 加重。
  /// 选中靠"描边变粗 + 变橙 + 右侧点亮",三件事一起说清楚，
  /// 只换一种方式很容易在灰底上漏看。背景色选中/未选中都用
  /// `s.surface` —— 卡片本来就是页面底色上抬一档的纸面，
  /// 选中的区别不该是"又换了一张纸"，而是"这张被圈出来了"。
  Widget _modeCard(AppSurface s, _Mode m) {
    final bool selected = _picked == m.id;

    return Pressable(
      onTap: () => setState(() => _picked = m.id),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(
            color: selected ? AppColors.accent : s.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            // 图标放在浅色圆里：三张卡只有图标不同，圆底让它在
            // 一列文字里先被扫到，用户靠它区分选项而不是先读标题。
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: s.chipBg,
                shape: BoxShape.circle,
              ),
              child: Icon(
                m.icon,
                size: 19,
                color: selected ? AppColors.accent : s.muted,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    m.title,
                    style: AppFonts.body(
                      size: 15,
                      weight: FontWeight.w600,
                      color: s.text,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    m.desc,
                    style: AppFonts.body(size: 12.5, color: s.muted, height: 1.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // 勾选圆点：**始终占位**，未选中时画成空心。
            // 如果选中时才插入这个圆，卡片右边的文字宽度会跳一下，
            // 三张卡一起看就像列表在抖。
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: selected ? AppColors.accent : Colors.transparent,
                shape: BoxShape.circle,
                border: selected
                    ? null
                    : Border.all(color: s.border, width: 1),
              ),
              child: selected
                  ? Icon(Icons.check_rounded, size: 15, color: AppColors.onAccent)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
