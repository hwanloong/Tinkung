import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/linux.dart';
import '../core/terminal_session.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';

/// **终端页**：看 agent 在 Alpine 里跑了什么、结果如何。
///
/// ## 它是什么（以及不是什么）
///
/// 它**不是**一个交互式终端。必须说清楚，否则用户会以为能敲 `vim`：
///
/// 底层 `LinuxRuntime.exec` 是"跑一条命令、拿一份完整输出"，
/// 中途没有 stdout 流，也没有真正的 TTY。所以：
///  · 命令跑完之后才看得到输出（不是逐行滚出来的）；
///  · 交互式程序（`vim`、`python` 的 REPL、`apk` 的 y/n 提示）用不了。
///
/// 它的定位是**记录 + 回看**：模型替你跑了什么命令、成没成、输出是什么。
/// 这解决的是"agent 动了我的环境，我想知道它到底干了什么" —— 而这
/// 恰恰是这类应用最需要的透明度。
///
/// 环境是应用自带的 Alpine（proot），**启动时自动安装**，用户不需要
/// 点任何按钮；这里的卡片只在还没装好时显示进度和失败原因。
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, this.initialCommand});

  /// 打开时要执行的命令（用户在终端页里敲的那种）。
  /// 从别处带命令进来时用。
  final String? initialCommand;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final TerminalSession _session = TerminalSession.instance;
  final LinuxService _linux = LinuxService.instance;

  @override
  void initState() {
    super.initState();
    // 状态一变就重建（装完没有、哪个在跑、跑完没有）
    _session.addListener(_onChange);
    _linux.addListener(_onChange);
    _linux.refresh();
    _ensureInstalled();
    if (widget.initialCommand != null &&
        widget.initialCommand!.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _run(widget.initialCommand!);
      });
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onChange);
    _linux.removeListener(_onChange);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// 自动安装：用户不需要点任何按钮。
  ///
  /// 启动预热（`main.dart`）已经调用过一次 `ensureInstalled()`；
  /// 这里再调一次是为了"用户在预热失败后打开终端页"这种情况 ——
  /// 它内部会先 refresh 再判断，重复调用是安全的。
  Future<void> _ensureInstalled() async {
    if (!_linux.supported) return;
    await _linux.ensureInstalled();
  }

  Future<void> _run(String command) async {
    final String cmd = command.trim();
    if (cmd.isEmpty) return;
    _input.clear();
    await _session.run(cmd, workdir: null);
    if (!mounted) return;
    // 跑完滚到最新一条
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: '终端',
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: '清屏',
                onPressed: _session.entries.isEmpty
                    ? null
                    : () => setState(_session.clear),
              ),
            ],
          ),

          // 没装好就显示状态卡（安装是自动的，这里只解释"正在做什么"）。
          if (_linux.supported && !_linux.installed) _installCard(s),

          Expanded(
            child: _session.entries.isEmpty
                ? _empty(s)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
                    itemCount: _session.entries.length,
                    itemBuilder: (BuildContext context, int i) =>
                        _entry(s, _session.entries[i]),
                  ),
          ),
          _composer(s),
        ],
      ),
    );
  }

  /// 安装状态卡。
  ///
  /// **必须说清"要花几秒、占多少空间"** —— 否则用户会以为终端卡住了，
  /// 或者担心它偷偷下了什么东西。注意它**没有"安装"按钮**：
  /// 环境在启动时自动解压，这里只是把进度和失败原因摆出来。
  Widget _installCard(AppSurface s) {
    final bool busy = _linux.installing;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  busy
                      ? Icons.downloading_rounded
                      : Icons.error_outline_rounded,
                  size: 18,
                  color: busy ? AppColors.accent : AppColors.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    busy ? '正在准备 Linux 环境' : 'Linux 环境还没有装好',
                    style: AppFonts.body(
                      size: 14,
                      weight: FontWeight.w600,
                      color: s.text,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              busy
                  ? '正在解压自带的 Alpine（proot + 约 4MB 根文件系统），'
                        '一般几秒就完成。解完占约 20MB，之后一直保留。'
                  : '应用**自带**一套 Alpine Linux，正常情况下启动后会'
                        '自动解压，不需要你做任何事。\n'
                        '如果一直停在这里，通常是存储空间不足；'
                        '清出一些空间后重试即可。',
              style: AppFonts.body(size: 12.2, color: s.muted, height: 1.55),
            ),
            if (busy) ...<Widget>[
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 3),
            ],
            if (!busy) ...<Widget>[
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _ensureInstalled,
                icon: const Icon(Icons.refresh_rounded, size: 19),
                label: const Text('重试'),
              ),
            ],
            if (_linux.lastError != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _linux.lastError!,
                style: AppFonts.body(
                  size: 11.5,
                  color: AppColors.danger,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 空状态

  Widget _empty(AppSurface s) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.terminal_rounded, size: 34, color: s.muted),
            const SizedBox(height: 14),
            Text(
              '还没有跑过命令',
              style: AppFonts.body(
                size: 14,
                weight: FontWeight.w600,
                color: s.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '在下面输入框里敲命令，或者直接在聊天里让 agent 干活 ——\n'
              '**两者的记录都在这一个列表里**，所以你能看到它到底执行了什么。',
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 12.5, color: s.muted, height: 1.6),
            ),
            const SizedBox(height: 14),
            // ---- /shared 的说明 ----
            //
            // 这一段是**发现性问题**的解法：Linux 里生成的文件默认落在
            // rootfs 内部（/root 之类），那是应用私有目录，用户在
            // 文件管理器里怎么翻都找不到 —— 看起来就像"文件没生成"。
            // 必须在这里明确告诉他往 /shared 写。
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: s.codeBg,
                borderRadius: BorderRadius.circular(AppRadius.field),
                border: Border.all(color: s.border, width: 0.7),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.folder_open_rounded,
                        size: 15,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '文件要放在 /shared',
                        style: AppFonts.body(
                          size: 12.5,
                          weight: FontWeight.w600,
                          color: s.text,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '`/shared` 是 Linux 和手机之间的交换目录。写在这里的文件\n'
                    '在聊天里能一键打开、也能发给别的应用；\n'
                    '写在 `/root`、`/tmp` 里的文件只存在于 Linux 内部，\n'
                    '**手机的文件管理器找不到**。\n'
                    '`/sdcard` 也能直接读写（已挂载）。',
                    style: AppFonts.body(
                      size: 11.5,
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
    );
  }

  // ---------------------------------------------------------------- 一条记录

  Widget _entry(AppSurface s, TerminalEntry e) {
    final Color state = e.running
        ? AppColors.accent
        : (e.ok ? AppColors.success : AppColors.danger);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 命令行：`$ 命令`
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (e.running)
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: 7),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.7,
                      color: state,
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 1, right: 7),
                  child: Icon(
                    e.ok
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    size: 15,
                    color: state,
                  ),
                ),
              Expanded(
                child: SelectableText(
                  '\$ ${e.command}',
                  style: AppFonts.code(size: 12.5, color: s.text, height: 1.5),
                ),
              ),
            ],
          ),
          // 元信息一行：耗时 / 退出码。
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 2),
            child: Text(
              <String>[
                '${(e.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s',
                if (!e.running && e.exitCode != null) 'exit ${e.exitCode}',
                if (e.running) '运行中',
              ].join(' · '),
              style: AppFonts.body(size: 10.5, color: s.muted),
            ),
          ),
          if (e.error != null) ...<Widget>[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: Text(
                e.error!,
                style: AppFonts.body(
                  size: 12,
                  color: AppColors.danger,
                  height: 1.5,
                ),
              ),
            ),
          ],
          if (e.output.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(left: 22),
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              decoration: ShapeDecoration(
                color: s.codeBg,
                shape: RoundedRectangleBorder(
                  // 输出区是这一页的主体内容块，用卡片档圆角 ——
                  // 和 Python 控制台的输出区同一规格。
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  side: BorderSide(color: s.border, width: 0.6),
                ),
              ),
              child: SelectableText(
                e.output.trim(),
                style: AppFonts.code(size: 12, color: s.text, height: 1.55),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 输入

  Widget _composer(AppSurface s) {
    final bool busy = _session.busy;
    final bool ready = _linux.installed;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: s.surface,
          border: Border(top: BorderSide(color: s.border, width: 0.8)),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              // 输入行做成一个 codeBg 的小块（field 圆角），和上面的
              // 输出块同一套「纸面上的深一档」—— 输入的是命令，
              // 视觉上就该和输出属于同一类东西。
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: s.codeBg,
                  borderRadius: BorderRadius.circular(AppRadius.field),
                  border: Border.all(color: s.border, width: 0.6),
                ),
                child: TextField(
                  controller: _input,
                  enabled: !busy && ready,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _run,
                  style: AppFonts.code(size: 13, color: s.text),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: busy
                        ? '上一条还在跑'
                        : ready
                        ? '在 Alpine 里执行（如 apk add python3）'
                        : '环境准备中…',
                    hintStyle: AppFonts.code(size: 12.5, color: s.muted),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.arrow_forward_rounded),
              tooltip: '执行',
              onPressed: busy || !ready ? null : () => _run(_input.text),
            ),
          ],
        ),
      ),
    );
  }
}

/// 让设置页也能打开终端页（终端图标平时只在跑的时候出现在聊天页，
/// 不跑的时候从设置进来）。
void openTerminal(BuildContext context, {String? command}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext _) => TerminalPage(initialCommand: command),
    ),
  );
}

/// 复制一段文本到剪贴板（工具输出常用）。
Future<void> copyText(String text) =>
    Clipboard.setData(ClipboardData(text: text));
