import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/android_linux_subsystem.dart';
import '../core/linux.dart';
import '../core/sandbox_plugin.dart';
import '../core/termux.dart';
import '../core/terminal_session.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';

/// **终端页**：看 agent 在 Termux 里跑了什么、结果如何。
///
/// ## 它是什么（以及不是什么）
///
/// 它**不是**一个交互式终端。必须说清楚，否则用户会以为能敲 `vim`：
///
/// Termux 的 `RUN_COMMAND` 广播只在命令**结束时**回一次结果，
/// 中途没有 stdout 流，也没有 stdin 通道。所以：
///  · 命令跑完之后才看得到输出（不是逐行滚出来的）；
///  · 交互式程序（`vim`、`python` 的 REPL、`apt` 的 y/n 提示）用不了。
///
/// 它的定位是**记录 + 回看**：模型替你跑了什么命令、成没成、输出是什么。
/// 这解决的是"agent 动了我的系统，我想知道它到底干了什么" —— 而这
/// 恰恰是这类应用最需要的透明度。
///
/// 想要完整的 Ubuntu 终端，走页面顶部的独立沙箱插件：
/// 它是一个无桌面图标的 APK，内置 Ubuntu rootfs + proot，点安装即可。
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
  SandboxPluginStatus _sandbox = const SandboxPluginStatus();
  AndroidLinuxSubsystemStatus _androidLinux =
      const AndroidLinuxSubsystemStatus();

  @override
  void initState() {
    super.initState();
    // 状态一变就重建（哪个在跑、跑完没有）
    _session.addListener(_onChange);
    // 两条通道都探一下：自带环境装没装决定"自动模式"走哪条
    // （见 TerminalSession.active 的说明）。
    LinuxService.instance.addListener(_onChange);
    LinuxService.instance.refresh();
    TermuxService.instance.refresh();
    _refreshSandbox();
    _refreshAndroidLinux();
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
    LinuxService.instance.removeListener(_onChange);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshSandbox() async {
    final SandboxPluginStatus s = await SandboxPluginService.instance.status();
    if (mounted) setState(() => _sandbox = s);
  }

  Future<void> _refreshAndroidLinux() async {
    final AndroidLinuxSubsystemStatus s = await AndroidLinuxSubsystemService
        .instance
        .status();
    if (mounted) setState(() => _androidLinux = s);
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
    final LinuxService linux = LinuxService.instance;
    final TermuxStatus st = TermuxService.instance.status;

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
          // 当前走哪条通道 + 手动切换
          _sandboxCard(s),
          _androidLinuxCard(s),
          _backendBar(s),

          // 没装自带环境就先把入口摆出来 —— 它是"零配置"那条路，
          // 应该是最先看到的选项。
          if (linux.supported && !linux.installed) _installCard(s, linux),
          // Termux 那条也不可用时才提示怎么配 Termux
          if (!linux.installed && !TermuxService.instance.canAttempt)
            _setupHint(s, st),

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
          _session.active == ShellBackend.systemLinux
              ? _systemLinuxComposer(s)
              : _composer(s),
        ],
      ),
    );
  }

  Widget _sandboxCard(AppSurface s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.inventory_2_outlined,
                  size: 18,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '独立 Ubuntu 沙箱',
                    style: AppFonts.body(
                      size: 14,
                      weight: FontWeight.w600,
                      color: s.text,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.refresh_rounded, size: 18, color: s.muted),
                  tooltip: '刷新状态',
                  onPressed: _refreshSandbox,
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              _sandbox.installed
                  ? '已安装 · Ubuntu 24.04 · 无桌面图标'
                  : '独立 APK · Ubuntu 24.04 + proot + apt；'
                        '安装后不会在桌面生成图标。装好后在下方「运行环境」'
                        '里选「独立沙箱」。',
              style: AppFonts.body(size: 12, color: s.muted, height: 1.5),
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                if (_sandbox.installed)
                  FilledButton.icon(
                    onPressed: () async {
                      final Map<dynamic, dynamic>? r =
                          await SandboxPluginService.instance.launch();
                      if (!mounted) return;
                      if (r?['ok'] != true) {
                        _snack(r?['error']?.toString() ?? '打开沙箱失败');
                      }
                    },
                    icon: const Icon(Icons.terminal_rounded, size: 19),
                    label: const Text('打开沙箱'),
                  )
                else
                  FilledButton.icon(
                    onPressed: () async {
                      final Map<dynamic, dynamic>? r =
                          await SandboxPluginService.instance.install();
                      if (!mounted) return;
                      if (r?['ok'] != true) {
                        _snack(r?['error']?.toString() ?? '已打开安装设置，请允许后重试');
                      } else {
                        _snack('请在系统安装器中确认安装，完成后回到这里刷新');
                      }
                      await Future<void>.delayed(const Duration(seconds: 2));
                      await _refreshSandbox();
                    },
                    icon: const Icon(Icons.download_rounded, size: 19),
                    label: const Text('安装插件'),
                  ),
                if (!_sandbox.canInstall)
                  TextButton(
                    onPressed: () =>
                        SandboxPluginService.instance.openInstallSettings(),
                    child: const Text('允许安装'),
                  ),
                if (_sandbox.installed)
                  TextButton(
                    onPressed: () async {
                      final Map<dynamic, dynamic>? r =
                          await SandboxPluginService.instance.install();
                      if (!mounted) return;
                      if (r?['ok'] != true) {
                        _snack(r?['error']?.toString() ?? '打开更新失败');
                      } else {
                        _snack('请在系统安装器中确认更新');
                      }
                    },
                    child: const Text('更新插件'),
                  ),
                if (_sandbox.installed)
                  TextButton(
                    onPressed: () => SandboxPluginService.instance.uninstall(),
                    child: Text(
                      '卸载',
                      style: AppFonts.body(size: 12, color: AppColors.danger),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _androidLinuxCard(AppSurface s) {
    final bool available = _androidLinux.installed && _androidLinux.launchable;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.memory_rounded, size: 18, color: AppColors.accent),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Android 16 Linux 子系统',
                    style: AppFonts.body(
                      size: 14,
                      weight: FontWeight.w600,
                      color: s.text,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.refresh_rounded, size: 18, color: s.muted),
                  tooltip: '刷新状态',
                  onPressed: _refreshAndroidLinux,
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              available
                  ? '系统 Terminal 已安装。它由 Android 的 AVF 虚拟机管理，'
                        'Zeus 只能打开它，不能把里面的命令接进当前终端流水。'
                  : _androidLinux.installed
                  ? '检测到系统 Terminal，但没有可启动的界面。'
                  : '未检测到系统 Terminal。该功能通常需要 Android 16、'
                        '支持 AVF 的设备，并在开发者选项里启用 Linux 终端。',
              style: AppFonts.body(size: 12, color: s.muted, height: 1.5),
            ),
            const SizedBox(height: 9),
            if (available)
              FilledButton.icon(
                onPressed: () async {
                  final Map<dynamic, dynamic>? r =
                      await AndroidLinuxSubsystemService.instance.launch();
                  if (!mounted) return;
                  if (r?['ok'] != true) {
                    _snack(r?['error']?.toString() ?? '打开系统 Terminal 失败');
                  }
                },
                icon: const Icon(Icons.open_in_new_rounded, size: 19),
                label: const Text('打开系统终端'),
              )
            else
              Text(
                '不是 Zeus 插件，也不是 proot；它使用系统 AVF 虚拟机。',
                style: AppFonts.body(size: 11.5, color: s.muted),
              ),
          ],
        ),
      ),
    );
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// 当前走哪条通道 + 手动切换。
  ///
  /// 为什么要把"跑在哪"摆在明面上：两条通道的环境**完全不同** ——
  /// 自带的是空白 Alpine（要从零 `apk add`），Termux 是用户自己配好的。
  /// 不显示的话，用户会困惑"为什么我 Termux 里装的工具这里没有"。
  Widget _backendBar(AppSurface s) {
    final TerminalSession session = TerminalSession.instance;
    final bool builtinReady = LinuxService.instance.installed;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: <Widget>[
          Text('运行环境', style: AppFonts.body(size: 12, color: s.muted)),
          for (final (ShellBackend, String, bool) b
              in <(ShellBackend, String, bool)>[
                (ShellBackend.builtin, '自带 Alpine', builtinReady),
                (
                  ShellBackend.termux,
                  'Termux',
                  TermuxService.instance.canAttempt,
                ),
                (ShellBackend.sandbox, '独立沙箱', _sandbox.installed),
                (
                  ShellBackend.systemLinux,
                  '系统 Linux',
                  _androidLinux.installed && _androidLinux.launchable,
                ),
              ])
            ChoiceChip(
              label: Text(b.$2, style: AppFonts.body(size: 12)),
              selected: session.preferred == b.$1,
              // 不可用的通道**仍然显示**但点不动：
              // 用户需要知道"有这条路，只是还没满足条件"，
              // 否则他会以为应用根本不支持。
              onSelected: b.$3
                  ? (_) => setState(() => session.preferred = b.$1)
                  : null,
            ),
        ],
      ),
    );
  }

  /// 安装自带环境的卡片。
  ///
  /// 首次进来会看到它。**必须说清"要花几秒、占多少空间"** ——
  /// 否则用户会以为终端卡住了，或者担心它偷偷下了什么东西。
  Widget _installCard(AppSurface s, LinuxService linux) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.download_rounded, size: 18, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '安装自带 Linux 环境',
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
              '应用**自带**一套 Alpine Linux（proot + 约 4MB 根文件系统），'
              '所以不需要装 Termux、也不用改任何设置。\n'
              '第一次要解压一次（几秒，解完占约 20MB），之后一直在。',
              style: AppFonts.body(size: 12.2, color: s.muted, height: 1.55),
            ),
            const SizedBox(height: 10),
            if (linux.installing)
              Row(
                children: <Widget>[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '正在解压',
                    style: AppFonts.body(size: 12.5, color: s.muted),
                  ),
                ],
              )
            else
              Row(
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: () => _install(linux),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: const Text('安装并启用'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '或者用上面那条 Termux 通道',
                      style: AppFonts.body(size: 11.5, color: s.muted),
                    ),
                  ),
                ],
              ),
            if (linux.lastError != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                linux.lastError!,
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

  Future<void> _install(LinuxService linux) async {
    final bool ok = await linux.install();
    if (!mounted) return;
    if (ok) {
      // 装完自动切到自带通道 —— 点这个按钮就是要用它
      TerminalSession.instance.preferred = ShellBackend.builtin;
    }
    setState(() {});
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

  /// Termux 不可用时的说明。**必须给出可操作的下一步**，
  /// 否则用户只知道"不行"，不知道怎么办。
  Widget _setupHint(AppSurface s, TermuxStatus st) {
    final String what = switch (st) {
      TermuxStatus.notInstalled => '还没装 Termux。装好之后回到这一页就会自动识别。',
      TermuxStatus.noPermission => '缺少 RUN_COMMAND 权限（理论上不该发生 —— 应用已经在清单里声明了）。',
      TermuxStatus.notVerified =>
        'Termux 已安装，但还没成功跑过命令。\n'
            '**最可能的原因**：没开 `allow-external-apps`。',
      TermuxStatus.unsupported => '当前平台不支持 Termux（只有 Android 可以）。',
      TermuxStatus.ready => '',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: SurfaceCard(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderColor: AppColors.warning.withValues(alpha: 0.3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: AppColors.warning,
                ),
                const SizedBox(width: 8),
                Text(
                  'Termux 还不可用',
                  style: AppFonts.body(
                    size: 13.5,
                    weight: FontWeight.w600,
                    color: s.text,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              what,
              style: AppFonts.body(size: 12.5, color: s.text, height: 1.6),
            ),
            if (st == TermuxStatus.notVerified) ...<Widget>[
              const SizedBox(height: 8),
              SelectableText(
                // 这条命令要在 Termux 里手动执行一次 —— 没法代劳，
                // 因为它改的是 Termux 自己的配置。
                'mkdir -p ~/.termux && echo "allow-external-apps=true" >> ~/.termux/termux.properties',
                style: AppFonts.code(size: 11.5, color: s.text),
              ),
              const SizedBox(height: 6),
              Text(
                '在 Termux 里执行上面这一行，然后**完全重启 Termux**。',
                style: AppFonts.body(size: 12, color: s.muted, height: 1.5),
              ),
            ],
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
                style: AppFonts.code(
                  size: 12,
                  color: s.text,
                  height: 1.55,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 输入

  Widget _systemLinuxComposer(AppSurface s) {
    final bool ready = _androidLinux.installed && _androidLinux.launchable;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 9, 12, 9),
        decoration: BoxDecoration(
          color: s.surface,
          border: Border(top: BorderSide(color: s.border, width: 0.8)),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.memory_rounded, size: 19, color: AppColors.accent),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                ready
                    ? '系统 Linux 由 Android AVF 管理，命令请在系统 Terminal 里输入。'
                    : '未检测到 Android 16 系统 Terminal，暂时不能打开。',
                style: AppFonts.body(size: 12, color: s.muted, height: 1.45),
              ),
            ),
            if (ready) ...<Widget>[
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () async {
                  final Map<dynamic, dynamic>? r =
                      await AndroidLinuxSubsystemService.instance.launch();
                  if (!mounted) return;
                  if (r?['ok'] != true) {
                    _snack(r?['error']?.toString() ?? '打开系统 Terminal 失败');
                  }
                },
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('打开'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _composer(AppSurface s) {
    final bool busy = _session.busy;
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: s.codeBg,
                  borderRadius: BorderRadius.circular(AppRadius.field),
                  border: Border.all(color: s.border, width: 0.6),
                ),
                child: TextField(
                  controller: _input,
                  enabled: !busy,
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
                        : '在 Termux 里执行（如 pkg list-installed）',
                    hintStyle: AppFonts.code(size: 12.5, color: s.muted),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.arrow_forward_rounded),
              tooltip: '执行',
              onPressed: busy ? null : () => _run(_input.text),
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
