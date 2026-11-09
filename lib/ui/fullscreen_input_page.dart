import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 全屏输入页。
///
/// ## 为什么需要它
///
/// 对话页的输入框最多 5 行、宽度是屏宽的七成。写一句短话够用，但
/// **贴一段代码、写一长段提示词、改一份草稿**时就不行了：
/// 你只能看到最后两三行，前面写了什么全靠记忆 —— 而这类内容恰恰
/// 最需要"整段看得见"。
///
/// ## 为什么是"长按打开"而不是加一个按钮
///
/// 输入框那一行已经很挤（`+` / 模型选择器 / 发送键）。再加一个图标
/// 会继续压缩本来就窄的输入宽度，而这是**低频**操作 ——
/// 天天用的话加按钮是对的，一个月用两次就该藏在手势里。
///
/// 代价是长按原本是"选中文字"，被这里抢走了。所以这个页面本身是一个
/// 完整的编辑器（能选、能改、能全选复制），长按进来的用户在这里做这件事
/// 反而更舒服：屏幕大、看得全、不会误触发送。
class FullscreenInputPage extends StatefulWidget {
  const FullscreenInputPage({
    super.key,
    required this.controller,
    this.hint = '发消息，或让我调用工具',
  });

  /// **共用同一个 controller**，不复制内容。
  ///
  /// 复制的话就得决定"哪边算最新"，而用户在两个地方来回改是常态
  /// （全屏写一半、退出去看看上下文、再进来接着写）。
  /// 共用一个 controller 时两边天然同步，退出即生效。
  final TextEditingController controller;

  final String hint;

  /// 返回 true = 用户点了「完成并发送」。
  static Future<bool> open(
    BuildContext context, {
    required TextEditingController controller,
    String hint = '发消息，或让我调用工具',
  }) async {
    final bool? send = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (BuildContext _) =>
            FullscreenInputPage(controller: controller, hint: hint),
      ),
    );
    return send ?? false;
  }

  @override
  State<FullscreenInputPage> createState() => _FullscreenInputPageState();
}

class _FullscreenInputPageState extends State<FullscreenInputPage> {
  @override
  void initState() {
    super.initState();
    // 进来就把光标放到末尾并聚焦：用户长按进来就是为了继续写，
    // 让他再点一下输入区才能打字是多余的一步。
    widget.controller.selection = TextSelection.fromPosition(
      TextPosition(offset: widget.controller.text.length),
    );
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final String text = widget.controller.text;
    final int lines = '\n'.allMatches(text).length + 1;

    return Scaffold(
      backgroundColor: s.pageBg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: '收起（内容会保留在输入框里）',
          onPressed: () => Navigator.of(context).pop(false),
        ),
        title: const Text('全屏输入'),
        actions: <Widget>[
          if (text.trim().isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: '清空',
              onPressed: () => setState(() {
                widget.controller.clear();
              }),
            ),
          TextButton(
            onPressed: text.trim().isEmpty
                ? null
                : () => Navigator.of(context).pop(true),
            child: const Text('完成并发送'),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: <Widget>[
          // 字数和行数：长文输入时用户需要知道"写了多少"，
          // 而这个信息在短输入框里是看不到的。
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
            child: Row(
              children: <Widget>[
                Text(
                  '$lines 行 · ${text.characters.length} 字',
                  style: AppFonts.code(size: 11.5, color: s.muted),
                ),
                const Spacer(),
                Text(
                  '内容实时同步到对话输入框',
                  style: AppFonts.body(size: 12, color: s.muted, height: 1.4),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Container(
                decoration: ShapeDecoration(
                  color: s.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    side: BorderSide(color: s.border),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: TextField(
                  controller: widget.controller,
                  autofocus: true,
                  // 全屏了就**不要再限行数** —— 这正是它存在的意义。
                  // `expands: true` + `maxLines: null` 让输入区铺满剩余空间，
                  // 而不是长到某一行就开始内部滚动。
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: AppFonts.body(size: 15, color: s.text, height: 1.7),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    hintText: widget.hint,
                    hintStyle: AppFonts.body(
                      size: 15,
                      color: s.muted,
                      height: 1.7,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
