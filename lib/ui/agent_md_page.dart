import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/agent_doc.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';

/// **Agent.md 编辑页**。
///
/// ## 它是什么
///
/// 一个纯 markdown 文本框，内容会被塞进**系统提示词最前面**，并注明
/// "最高优先级"。用户可以用它覆盖内置的回答风格、编码规范、交付格式、
/// 术语表……
///
/// ## 为什么做成"整页一个大文本框"，而不是一条条规则
///
/// 因为这类内容**成体系**：一份编码规范是一个整体（缩进、命名、注释、
/// 提交信息……），拆成一条条"当…就…"会失去结构和上下文。而且用户往往
/// 已经有现成的 `AGENTS.md` / `CLAUDE.md`，整段粘进来就能用。
///
/// ## 保存策略
///
/// 自动保存（输入停顿后），但**离开页面时再存一次**。用户点返回就直接走了，
/// 没有"保存"这个动作会让他不确定到底存没存 —— 所以头部还有一个明确的
/// 保存按钮，点了给一句"已保存"的反馈。
class AgentMdPage extends StatefulWidget {
  const AgentMdPage({super.key, required this.store});

  final AgentDocStore store;

  @override
  State<AgentMdPage> createState() => _AgentMdPageState();
}

class _AgentMdPageState extends State<AgentMdPage> {
  late final TextEditingController _text = TextEditingController(
    text: widget.store.text,
  );
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onChanged);
  }

  @override
  void dispose() {
    // 离开页面时兜底保存一次。dispose 里不能 setState，只落盘。
    if (_dirty) widget.store.setText(_text.text);
    _text.dispose();
    super.dispose();
  }

  void _onChanged() {
    final bool dirty = _text.text != widget.store.text;
    if (dirty != _dirty && mounted) setState(() => _dirty = dirty);
  }

  void _save() {
    final String? err = widget.store.setText(_text.text);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存，下一条消息就生效')),
    );
  }

  /// 填入**为这个 App 写的推荐模板**。
  ///
  /// ## 为什么要有它
  ///
  /// 空白输入框对大多数人是不知道怎么下手的：写什么、写到多细、哪些是
  /// 有用的约束。模板给了一个**能直接用的起点** —— 用户读一遍、删掉
  /// 不要的、补上自己的项目习惯，比从零写快得多。
  ///
  /// 模板内容见 `assets/agent_md_template.md`：已经对齐本 App 的工具
  /// （`reader` / `writer` / `varbank` / `termux` / 内置 Python 的边界）。
  ///
  /// 已有内容时**先确认**再覆盖：这份文档可能是用户写了很久的。
  Future<void> _useTemplate() async {
    if (_text.text.trim().isNotEmpty) {
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('替换当前内容？'),
          content: const Text('填入推荐模板会覆盖你现在写的内容，且不能撤销。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('替换'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    String tpl;
    try {
      tpl = await rootBundle.loadString('assets/agent_md_template.md');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('读取模板失败：$e')));
      return;
    }
    if (!mounted) return;
    // 监听器会自己把 `_dirty` 置 1 并触发重建，这里不用再 setState。
    _text.value = TextEditingValue(
      text: tpl,
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final int len = _text.text.length;

    return PopScope(
      // 返回前保存。`canPop: false` 会拦下系统返回，手动 pop 一次 ——
      // 这样"改了没存就退出"不会发生。
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        _save();
        Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: s.pageBg,
        body: Column(
          children: <Widget>[
            _header(s),
            _hint(s),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
                child: Container(
                  decoration: BoxDecoration(
                    color: s.codeBg,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: s.border, width: 0.9),
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: TextField(
                    controller: _text,
                    maxLines: null,
                    expands: true,
                    // 代码/规范类内容用等宽字体：缩进、列表对齐才看得清。
                    style: AppFonts.code(size: 13.2, color: s.text, height: 1.6),
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      hintText:
                          '# 例如\n\n'
                          '## 回答\n'
                          '- 先用一句话给结论。\n'
                          '- 代码一律写进文件，不要贴在聊天里。\n\n'
                          '## 代码\n'
                          '- Dart 用 2 空格缩进；命名用 lowerCamelCase。\n'
                          '- 每个 public 函数写一行注释说清它做什么。\n\n'
                          '## 交付\n'
                          '- 说清：改了什么、在哪个文件、怎么验证。\n',
                      hintStyle: AppFonts.code(
                        size: 13.2,
                        color: s.muted,
                        height: 1.6,
                      ),
                      counterText: '',
                    ),
                  ),
                ),
              ),
            ),
            // ---- 底部：字数 + 保存 ----
            Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                0,
                16,
                MediaQuery.of(context).padding.bottom + 12,
              ),
              child: Row(
                children: <Widget>[
                  // 一键填入推荐模板：空白页最容易卡在"写什么"。
                  TextButton.icon(
                    onPressed: _useTemplate,
                    icon: const Icon(Icons.auto_awesome_outlined, size: 15),
                    label: Text(
                      '推荐模板',
                      style: AppFonts.body(size: 12.5, color: AppColors.accent),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$len / ${AgentDocStore.maxChars}',
                    style: AppFonts.body(
                      size: 12,
                      // 接近上限时变红：这是"每轮都要背上"的成本。
                      color: len > AgentDocStore.maxChars
                          ? AppColors.danger
                          : s.muted,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(width: 10),
                  GlassButton(
                    label: _dirty ? '保存' : '已保存',
                    icon: _dirty ? Icons.save_outlined : Icons.check_rounded,
                    accent: _dirty,
                    onTap: _dirty ? _save : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(AppSurface s) {
    final double top = MediaQuery.of(context).padding.top;
    return GlassBar(
      hairlineBottom: true,
      padding: EdgeInsets.fromLTRB(8, top + 6, 12, 10),
      child: Row(
        children: <Widget>[
          BackButton(
            onPressed: () {
              _save();
              Navigator.of(context).pop();
            },
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Agent.md',
                  style: AppFonts.body(
                    size: 17,
                    weight: FontWeight.w600,
                    color: s.text,
                    height: 1.2,
                  ),
                ),
                Text(
                  '最高优先级规范',
                  style: AppFonts.body(size: 11.5, color: s.muted, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 页首那段说明：**必须写清优先级和边界**。
  ///
  /// 不写"优先级最高"的话，用户会以为它和自定义规则是同级的 ——
  /// 而它们冲突时他需要知道谁赢。不写"安全机制不受影响"的话，
  /// 有人会试着用它关掉危险操作确认，然后发现没生效。
  Widget _hint(AppSurface s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 8, 11, 9),
        decoration: BoxDecoration(
          color: s.chipBg,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Text(
          '这里写的内容会放在系统提示词**最前面**，优先级高于内置规则；'
          '两者冲突时以这里为准。\n'
          '危险操作确认、不可信输入处理等安全机制由程序执行，不受此文档影响。',
          style: AppFonts.body(size: 12.2, color: s.muted, height: 1.55),
        ),
      ),
    );
  }
}
