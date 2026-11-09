import 'package:flutter/material.dart';

import '../core/rules.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';
import 'ios_switch.dart';

/// 自定义规则页：**当 XXX 的时候，就 YYY**。
class RulesPage extends StatefulWidget {
  const RulesPage({super.key, required this.store});

  final RuleStore store;

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  /// 搜索框里的字。
  ///
  /// 规则一多，找一条就得从头翻一遍 —— 而"我记得有那么一条、
  /// 但它在列表第几行"正是最常发生的场景。
  final TextEditingController _search = TextEditingController();
  String _q = '';

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onChange);
    _search.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final List<CustomRule> all = widget.store.rules;
    final List<CustomRule> hits = _filter(all);

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          _header(s),
          // 一条规则都没有时不摆搜索框：搜一个空列表没有意义，
          // 而且那一屏已经有一整块"还没有规则"的引导在说该干什么。
          if (all.isNotEmpty) _searchBar(s),
          Expanded(
            child: all.isEmpty
                ? _empty(s)
                : hits.isEmpty
                ? _noMatch(s)
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                    children: <Widget>[
                      ...hits.map((CustomRule r) => _row(s, r)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 按关键词筛。`when_` 和 `then_` **两段都搜** ——
  /// 用户记得的可能是触发条件，也可能是那句话本身。
  List<CustomRule> _filter(List<CustomRule> all) {
    final String q = _q.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where(
          (CustomRule r) =>
              r.when_.toLowerCase().contains(q) ||
              r.then_.toLowerCase().contains(q),
        )
        .toList();
  }

  Widget _searchBar(AppSurface s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Container(
        decoration: ShapeDecoration(
          color: s.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.field),
            side: BorderSide(color: s.border, width: 1),
          ),
        ),
        padding: const EdgeInsets.only(left: 11, right: 4),
        child: Row(
          children: <Widget>[
            Icon(Icons.search_rounded, size: 17, color: s.muted),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _search,
                onChanged: (String v) => setState(() => _q = v),
                style: AppFonts.body(size: 14, color: s.text, height: 1.4),
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  hintText: '搜规则：条件或动作里任一个词都行',
                  hintStyle: AppFonts.body(size: 13, color: s.muted),
                ),
              ),
            ),
            if (_q.trim().isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close_rounded),
                iconSize: 16,
                tooltip: '清空',
                color: s.muted,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => setState(() {
                  _search.clear();
                  _q = '';
                }),
              ),
          ],
        ),
      ),
    );
  }

  /// 搜不到时的提示。**必须和"还没有规则"分开写** ——
  /// 用同一句"还没有规则"的话，用户会以为自己的规则被删了。
  Widget _noMatch(AppSurface s) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 60, 24, 24),
      children: <Widget>[
        Icon(
          Icons.search_off_rounded,
          size: 34,
          color: s.muted.withValues(alpha: 0.5),
        ),
        const SizedBox(height: 12),
        Text(
          '没有匹配的规则',
          textAlign: TextAlign.center,
          style: AppFonts.body(
            size: 14.5,
            weight: FontWeight.w600,
            color: s.text,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '换个词试试；规则本身都还在。',
          textAlign: TextAlign.center,
          style: AppFonts.body(size: 12.8, color: s.muted, height: 1.6),
        ),
      ],
    );
  }

  Widget _header(AppSurface s) {
    final double top = MediaQuery.of(context).padding.top;
    return GlassBar(
      hairlineBottom: true,
      padding: EdgeInsets.fromLTRB(8, top + 6, 12, 10),
      child: Row(
        children: <Widget>[
          BackButton(onPressed: () => Navigator.of(context).maybePop()),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '自定义规则',
              style: AppFonts.body(
                size: 17,
                weight: FontWeight.w600,
                color: s.text,
                height: 1.2,
              ),
            ),
          ),
          GlassIconButton(
            icon: Icons.add_rounded,
            tooltip: '新建规则',
            size: 38,
            iconSize: 19,
            onTap: () => _edit(null),
          ),
        ],
      ),
    );
  }

  /// 空状态：和记忆页、自学习页共用同一个 [EmptyHint]，
  /// 底下那条「新建规则」是这个页面独有的入口 —— 那两页用户不能添加，
  /// 这一页能，所以按钮必须留着。
  Widget _empty(AppSurface s) {
    return Column(
      children: <Widget>[
        const Expanded(
          child: EmptyHint(
            icon: Icons.rule_folder_outlined,
            title: '还没有规则',
            desc:
                '规则就是一句话：当……的时候，就……\n\n'
                '· 当我问天气时，先用 web 查我所在城市再回答\n'
                '· 当我发英文时，先翻译成中文再回答\n'
                '· 回答技术问题时，代码块要带注释\n\n'
                '规则会在每次对话里生效。',
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
          child: GlassButton(
            label: '新建规则',
            icon: Icons.add_rounded,
            accent: true,
            expand: true,
            onTap: () => _edit(null),
          ),
        ),
      ],
    );
  }

  /// 一条规则 = **一行**。
  ///
  /// ## 为什么不把规则原文铺在列表里（2026-10-16 用户要求）
  ///
  /// 原来每条规则在列表里是完整的两段话（"当……时，就……"），
  /// 一条长规则能占三四行。列表里真正要回答的问题只是
  /// "**有没有那么一条、它开着吗**" —— 要读全文、要改，点一下进编辑页，
  /// 那里文本框就把它完整摊开了。
  ///
  /// 所以这一行只留：开关、一句**截断的**说明、删除。超过一行的部分
  /// 用省略号收掉，行的位置和高度因此变得可预期 —— 一列扫下来才快。
  Widget _row(AppSurface s, CustomRule r) {
    final String summary = '当 ${r.when_} 时，就 ${r.then_}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
        onTap: () => _edit(r),
        child: Row(
          children: <Widget>[
            // 开关：规则可以留着但临时关掉，比"删了再重建"实用得多。
            //
            // 原来这里套了一层 `Transform.scale(0.82)`，本意是让行"矮下来"——
            // 但 Transform 只改**绘制**、不改布局，行高其实一直是被 Material
            // 开关那 40 的外框顶着的，缩小只是让开关自己变小。
            // 换成 iOS 开关后外框是 44（见 IosSwitch），行高只多 4；
            // 而轨道**本身就是** iOS 的 31 —— 再缩就比原生尺寸还小了，
            // 所以把那层缩放去掉。
            IosSwitch(
              value: r.enabled,
              onChanged: (bool v) => widget.store.toggle(r, v),
            ),
            // 间距从 2 加到 6：iOS 的轨道 51 宽，比 M2 的 33 宽 18px，
            // 外框里的横向余量因此只剩 4（原来是 13）。不补的话开关会
            // **贴着**规则文字，看着像挤在一起。
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(
                  size: 13,
                  // 关掉的规则整行退到次要色：不用看开关也能一眼分辨。
                  color: r.enabled ? s.text : s.muted,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(width: 4),
            GlassIconButton(
              icon: Icons.delete_outline_rounded,
              tooltip: '删除',
              size: 32,
              iconSize: 16,
              color: AppColors.danger,
              onTap: () => widget.store.remove(r.id),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(CustomRule? existing) async {
    final TextEditingController whenC = TextEditingController(
      text: existing?.when_ ?? '',
    );
    final TextEditingController thenC = TextEditingController(
      text: existing?.then_ ?? '',
    );
    final AppSurface s = AppSurface.of(context);

    final bool? ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                existing == null ? '新建规则' : '编辑规则',
                style: AppFonts.body(
                  size: 17,
                  weight: FontWeight.w600,
                  color: s.text,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 14),
              _label(s, '当的时候'),
              const SizedBox(height: 6),
              _input(s, whenC, '例如：我让你查资料时'),
              const SizedBox(height: 14),
              _label(s, '就'),
              const SizedBox(height: 6),
              _input(s, thenC, '例如：先列出三个来源再总结', maxLines: 3),
              const SizedBox(height: 10),
              mdText(
                '用大白话写就行，模型能理解。\n'
                '规则只在**对话时**生效 —— 应用没打开时不会自己触发。',
                style: AppFonts.body(size: 11.5, color: s.muted, height: 1.6),
              ),
              const SizedBox(height: 16),
              GlassButton(
                label: '保存',
                accent: true,
                expand: true,
                onTap: () => Navigator.of(ctx).pop(true),
              ),
            ],
          ),
        ),
      ),
    );

    if (ok == true) {
      final String w = whenC.text.trim();
      final String t = thenC.text.trim();
      if (w.isNotEmpty && t.isNotEmpty) {
        if (existing == null) {
          widget.store.add(w, t);
        } else {
          existing.when_ = w;
          existing.then_ = t;
          widget.store.update(existing);
        }
      }
    }

    whenC.dispose();
    thenC.dispose();
  }

  Widget _label(AppSurface s, String text) => Text(
    text,
    style: AppFonts.body(
      size: 12.5,
      weight: FontWeight.w600,
      color: s.muted,
      height: 1.3,
    ),
  );

  Widget _input(
    AppSurface s,
    TextEditingController c,
    String hint, {
    int maxLines = 1,
  }) {
    return Container(
      decoration: ShapeDecoration(
        color: s.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          side: BorderSide(color: s.border, width: 1),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        style: AppFonts.body(size: 14, color: s.text, height: 1.5),
        decoration: InputDecoration(
          isDense: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
          hintText: hint,
          hintStyle: AppFonts.body(size: 13, color: s.muted),
        ),
      ),
    );
  }
}
