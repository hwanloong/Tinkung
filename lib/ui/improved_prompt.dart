import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 「描述改进」改写的提示词，折叠展示。
///
/// ## 为什么放在原话**下面**而且默认折叠
///
/// 用户最关心的是"我说了什么"——原话必须在最显眼的位置、完整显示。
/// 而改进版是**实际发给模型的那一段**，它的用途是"我要核对一下它有没有
/// 曲解我的意思"，属于按需查看。
///
/// 铺开的话每条消息都会长一倍，长会话翻起来非常累。
///
/// ## 为什么值得显示出来（而不是静默改写）
///
/// 自动改写用户的输入是有风险的动作：模型可能加上用户没提的要求。
/// 把结果**摆在明面上**，用户一眼就能发现"这不是我要的" ——
/// 这比在设置里写十行免责说明都管用。
class ImprovedPromptBlock extends StatefulWidget {
  const ImprovedPromptBlock({
    super.key,
    required this.improved,
    required this.original,
  });

  final String improved;

  /// 用户原话，用来做"到底改了什么"的判断和展示。
  final String original;

  @override
  State<ImprovedPromptBlock> createState() => _ImprovedPromptBlockState();
}

class _ImprovedPromptBlockState extends State<ImprovedPromptBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.auto_fix_high_rounded,
                  size: 13,
                  color: AppColors.onAccent.withValues(alpha: 0.75),
                ),
                const SizedBox(width: 5),
                Text(
                  _open ? '已改进的提示词' : '已改进提示词 · 点开看',
                  style: AppFonts.body(
                    size: 12.5,
                    weight: FontWeight.w600,
                    // 压在用户气泡的底色上，所以用 onAccent 的弱化版 ——
                    // 这里的 `muted` 是按页面底色选的，放在气泡上看不清。
                    color: AppColors.onAccent.withValues(alpha: 0.75),
                  ),
                ),
                Icon(
                  _open
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: AppColors.onAccent.withValues(alpha: 0.75),
                ),
              ],
            ),
          ),
          if (_open) ...<Widget>[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                // 气泡内部再套一层，所以用气泡底色的**加深**而不是
                // 页面的 codeBg —— 后者在气泡上会是一块突兀的浅色。
                color: AppColors.onAccent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppRadius.code),
              ),
              child: Text(
                widget.improved.trim(),
                style: AppFonts.body(
                  size: 13,
                  color: AppColors.onAccent,
                  height: 1.55,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '上面这段是实际发给模型的；你写的那句仍然原样保留在上面。',
              textAlign: TextAlign.right,
              style: AppFonts.body(
                size: 11.5,
                color: AppColors.onAccent.withValues(alpha: 0.66),
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
