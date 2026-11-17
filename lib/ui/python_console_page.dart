import 'package:flutter/material.dart';

import '../core/python.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';

/// Python 控制台。
///
/// ## 为什么需要它
///
/// Python 本来是给 agent 用的工具，用户不该直接操作。**但调试需要它。**
///
/// 如果 agent 调用失败，你没法判断是：
/// · 解释器根本没起来（构建期/运行期问题）
/// · 还是 agent 没把工具调对（提示词问题）
///
/// 有个控制台就一目了然：这里能跑通 → 问题在 agent 那边；
/// 这里也跑不通 → 问题在 Python 本身，错误信息直接给你看。
///
/// 顺带它也是个趁手的计算器/试验台，不用绕一圈去问 agent。
class PythonConsolePage extends StatefulWidget {
  const PythonConsolePage({super.key});

  @override
  State<PythonConsolePage> createState() => _PythonConsolePageState();
}

class _PythonConsolePageState extends State<PythonConsolePage> {
  final TextEditingController _code = TextEditingController(
    text: 'import sys\nprint(sys.version)',
  );

  PyResult? _result;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    // 进页面时探测一次 —— 让用户马上知道解释器到底起没起来
    PythonService.instance.refresh().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final String code = _code.text;
    if (code.trim().isEmpty) return;

    setState(() {
      _running = true;
      _result = null;
    });

    final PyResult r = await PythonService.instance.run(code);

    if (!mounted) return;
    setState(() {
      _running = false;
      _result = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final PythonService py = PythonService.instance;

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          _header(s),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: <Widget>[
                _statusCard(s, py),
                const SizedBox(height: 14),
                _codeField(s),
                const SizedBox(height: 10),
                _actions(s),
                if (_result != null) ...<Widget>[
                  const SizedBox(height: 16),
                  _outputCard(s, _result!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(AppSurface s) {
    final double top = MediaQuery.of(context).padding.top;
    return GlassBar(
      hairlineBottom: true,
      padding: EdgeInsets.fromLTRB(8, top + 6, 14, 10),
      child: Row(
        children: <Widget>[
          BackButton(onPressed: () => Navigator.of(context).maybePop()),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Python 控制台',
              style: AppFonts.body(
                size: 17,
                weight: FontWeight.w600,
                color: s.text,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 解释器状态。**这是这个页面最重要的信息** ——
  /// 它直接回答"Python 到底能不能用"。
  Widget _statusCard(AppSurface s, PythonService py) {
    final bool ok = py.available;

    final Color tint = ok ? AppColors.success : AppColors.danger;
    return SurfaceCard(
      radius: AppRadius.card,
      color: tint.withValues(alpha: 0.09),
      borderColor: tint.withValues(alpha: 0.28),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.code),
            ),
            child: Icon(
              ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
              size: 18,
              color: tint,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  ok ? '解释器可用' : '解释器不可用',
                  style: AppFonts.body(
                    size: 14.5,
                    weight: FontWeight.w600,
                    color: s.text,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  ok
                      ? (py.version ?? '(已就绪)')
                      : (py.lastError ??
                            '还没探测到。点「运行」会自动解压 Alpine 并安装 python3。'),
                  style: AppFonts.code(size: 11.5, color: s.muted),
                ),
                if (ok) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    py.packages == null
                        ? 'Alpine 内置 python3 · 首次运行自动安装'
                        : '已装 ${py.packages!.length} 个 Python 包',
                    style: AppFonts.body(
                      size: 11.5,
                      color: s.muted,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _codeField(AppSurface s) {
    return Container(
      decoration: ShapeDecoration(
        color: s.codeBg,
        shape: RoundedRectangleBorder(
          // 输入区用 field 档：它是「可编辑的框」，和终端页的命令行同档；
          // card 档留给只读的输出块。
          borderRadius: BorderRadius.circular(AppRadius.field),
          side: BorderSide(color: s.border, width: 0.6),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: TextField(
        controller: _code,
        minLines: 5,
        maxLines: 14,
        keyboardType: TextInputType.multiline,
        // 代码一律等宽，否则缩进看不出层级
        style: AppFonts.code(size: 12.5, color: s.text, height: 1.55),
        decoration: InputDecoration(
          isDense: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          hintText: 'print("hello")',
          hintStyle: AppFonts.code(size: 12.5, color: s.muted),
        ),
      ),
    );
  }

  Widget _actions(AppSurface s) {
    return Row(
      children: <Widget>[
        GlassButton(
          label: _running ? '运行中' : '运行',
          icon: _running ? null : Icons.play_arrow_rounded,
          accent: true,
          onTap: _running ? null : _run,
        ),
        const SizedBox(width: 9),
        GlassButton(
          label: '重新探测',
          icon: Icons.refresh_rounded,
          fontSize: 13,
          onTap: () async {
            await PythonService.instance.refresh();
            if (mounted) setState(() {});
          },
        ),
        const Spacer(),
        // 每次运行都是独立进程，变量不会带到下一次；
        // 这一点必须写在界面上，否则用户会以为"上一轮的变量丢了"。
        Text(
          '每次运行独立',
          style: AppFonts.body(size: 11.5, color: s.muted),
        ),
      ],
    );
  }

  Widget _outputCard(AppSurface s, PyResult r) {
    final Color tint = r.ok ? AppColors.success : AppColors.danger;
    final String text = r.ok
        ? (r.output.trim().isEmpty ? '（没有输出）' : r.output.trim())
        : '${r.errorType ?? 'Exception'}\n\n${r.error ?? ''}'
              '${r.output.trim().isEmpty ? '' : '\n\n--- 报错前已产生的输出 ---\n${r.output.trim()}'}';

    return SurfaceCard(
      radius: AppRadius.card,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                r.ok ? Icons.terminal_rounded : Icons.bug_report_rounded,
                size: 15,
                color: tint,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  r.ok ? '输出' : '出错了',
                  style: AppFonts.body(
                    size: 14.5,
                    weight: FontWeight.w600,
                    color: tint,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 输出正文放进 codeBg 的块里：等宽、深一档底、card 圆角 ——
          // 和终端页的输出区一致。外层卡片只负责"这段属于一次运行"。
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
            decoration: BoxDecoration(
              color: s.codeBg,
              borderRadius: BorderRadius.circular(AppRadius.code),
              border: Border.all(color: s.border, width: 0.6),
            ),
            child: SelectableText(
              text,
              // 输出用 SelectableText 而不是 Text：报错信息经常要复制出去搜，
              // 而 markdown 那边的 RichText 是选不中的（踩过这个坑）。
              style: AppFonts.code(size: 11.5, color: s.text, height: 1.55),
            ),
          ),
        ],
      ),
    );
  }
}
