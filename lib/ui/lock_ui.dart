import 'package:flutter/material.dart';

import '../core/lock.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';

/// 全局锁仓库（`main()` 里创建并 load 一次）。
///
/// 可空：widget 测试不跑 `main()`，那里没有锁 —— 写成 `late` 会让每个
/// 构建聊天页的测试抛 `LateInitializationError`。
LockStore? appLock;

/// 需要验证某个范围时调用它。
///
/// 返回 true = 已通过（或本来就不需要验证）。所有入口（设置、笔记、
/// 计划、记忆、规则、工具、权限、以及模型调工具）都走这一个函数，
/// 保证"判定逻辑只有一处"。
Future<bool> ensureUnlocked(BuildContext context, LockScope scope) async {
  final LockStore? lock = appLock;
  if (lock == null) return true;
  if (!lock.needsUnlock(scope)) return true;

  final bool? ok = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (BuildContext _) => LockScreen(scope: scope),
    ),
  );
  return ok == true;
}

/// **强制**验证一次（模型调用密码工具时用）。
///
/// 和 [ensureUnlocked] 的区别：后者只在"这个范围开着"时才拦；
/// 这里是**无条件**验证 —— 模型自己判断这一步危险，就该由用户点头。
///
/// 用**弹窗**而不是整页：它是模型流程中间的一次确认，弹窗能让人看清
/// "原来这一步被拦住了"，而整页会让人以为跳到了别的界面。
/// 返回值是**三态**：
///  · `true`  —— 用户验证通过；
///  · `false` —— 用户拒绝 / 取消了；
///  · `null`  —— **没设密码**，根本没有可验证的东西。
///
/// ## 为什么不能把 `null` 折成 `false`
///
/// 之前这里 `if (lock == null || !lock.hasPassword) return false;`。
/// 后果是：用户没设密码时，工具调用拿到的结论是"用户拒绝或取消"，
/// 于是模型对用户说「验证被拒绝了，我停止」—— 而他根本没被问过。
/// 那不是安全边界，那是**误报**：真正的拒绝（用户点了取消）必须和
/// "这里没有密码可验"分开，否则模型无法区分"用户不让做"和"没这道门"。
Future<bool?> requestVerify(BuildContext context, String reason) async {
  final LockStore? lock = appLock;
  if (lock == null || !lock.hasPassword) return null;
  final bool? ok = await showDialog<bool>(
    context: context,
    // 点外面关掉 = 拒绝。不允许"顺手点空白就通过"。
    barrierDismissible: false,
    builder: (BuildContext ctx) => _LockDialog(reason: reason),
  );
  return ok == true;
}

/// 模型请求验证时弹的**对话框**。
///
/// 和 [LockScreen] 内容一样（密码 + 指纹按钮），但装进 Dialog：
/// 它出现在模型流程中间，用户需要明白"这一步被拦住了"，而不是
/// 以为界面被切走了。
class _LockDialog extends StatefulWidget {
  const _LockDialog({required this.reason});

  final String reason;

  @override
  State<_LockDialog> createState() => _LockDialogState();
}

class _LockDialogState extends State<_LockDialog> {
  final TextEditingController _input = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _canBiometric = false;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final LockStore? lock = appLock;
    if (lock == null || !lock.biometric) return;
    final bool ok = await SystemAuth.available();
    if (!mounted) return;
    setState(() => _canBiometric = ok);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final LockStore? lock = appLock;
    if (lock == null) return;
    if (lock.verify(_input.text)) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _error = '密码不对');
    }
  }

  Future<void> _useBiometric() async {
    if (_busy) return;
    setState(() => _busy = true);
    final bool ok = await SystemAuth.authenticate();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    return AlertDialog(
      backgroundColor: s.pageBg,
      // ---- 键盘弹出时不要和对话框重叠 ----
      //
      // ⚠️ **这里不要自己加 `viewInsets.bottom`**。
      //
      // `Dialog.build`（framework 里）算的是：
      //
      // ```dart
      // effectivePadding = MediaQuery.viewInsetsOf(context) + insetPadding
      // ```
      //
      // 也就是说键盘高度**框架已经叠过一次**了。这里再写
      // `bottom: 24 + viewInsets.bottom`，键盘就会被算两遍 ——
      // 对话框被往上顶双倍的距离，可用高度只剩一条缝，内容挤压变形
      // （用户报的"弹出输入法时会被挤得变形"就是这个）。
      //
      // 现在只留视觉留白 24，键盘交给框架。
      // 内容仍然包在 `SingleChildScrollView` 里：横屏 + 键盘时高度真的不够，
      // 那时应该能滚，而不是溢出。
      insetPadding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      icon: Icon(
        Icons.lock_outline_rounded,
        size: 26,
        color: AppSurface.of(context).muted,
      ),
      title: Text(
        '模型请求验证',
        textAlign: TextAlign.center,
        style: AppFonts.body(size: 16, weight: FontWeight.w600, color: s.text),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              // 把模型写的那句话原样放出来：用户要判断的是"这一步该不该做"，
              // 而不是"要不要解锁"。
              widget.reason,
              style: AppFonts.body(size: 13.5, color: s.text, height: 1.6),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _input,
              autofocus: true,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              style: AppFonts.body(size: 15, color: s.text),
              decoration: InputDecoration(
                labelText: '密码',
                errorText: _error,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.field),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          // 拒绝 = 让模型停下。文案写"拒绝"而不是"取消"：
          // 这个选择会直接决定模型能不能继续。
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('拒绝'),
        ),
        if (_canBiometric)
          TextButton(
            onPressed: _busy ? null : _useBiometric,
            child: const Text('用指纹 / 面部'),
          ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('通过'),
        ),
      ],
    );
  }
}

/// 解锁界面：输入密码，或者用系统凭据（指纹 / 面部）。
///
/// ## 为什么把"用指纹"做成一个显式按钮
///
/// 打开就自动弹系统生物识别，在**没有录制指纹**的机器上会直接失败 ——
/// 用户看到的是"闪一下就没了"，然后还得手动输密码。做成按钮之后，
/// 按钮只在 `SystemAuth.available()` 为 true 时出现，点了才弹。
class LockScreen extends StatefulWidget {
  const LockScreen({
    super.key,
    required this.scope,
    this.onUnlocked,
    this.reason,
  });

  /// 覆盖默认文案（模型调用时传"要执行 X，请确认"）。
  final String? reason;

  final LockScope scope;

  /// 验证通过时的回调。
  ///
  /// 有它 = 被当作**页面**用在启动门禁里（没有路由栈可 pop）；
  /// 没有它 = 被当作**路由**push 上来（ensureUnlocked），
  /// 通过后自己 pop(true)。
  final VoidCallback? onUnlocked;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final TextEditingController _input = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _canBiometric = false;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final LockStore? lock = appLock;
    if (lock == null || !lock.biometric) return;
    final bool ok = await SystemAuth.available();
    if (!mounted) return;
    setState(() => _canBiometric = ok);
    // 有系统凭据就**顺手弹一次**：用户来这里就是为了解锁，
    // 让他再多点一下没有意义。
    if (ok) _useBiometric();
  }

  Future<void> _useBiometric() async {
    if (_busy) return;
    setState(() => _busy = true);
    final bool ok = await SystemAuth.authenticate();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) _finish(true);
  }

  void _finish(bool ok) {
    if (!ok) return;
    appLock?.markUnlocked(widget.scope);
    final VoidCallback? cb = widget.onUnlocked;
    if (cb != null) {
      cb();
    } else {
      Navigator.of(context).pop(true);
    }
  }

  void _submit() {
    final LockStore? lock = appLock;
    if (lock == null) return;
    if (lock.verify(_input.text)) {
      _finish(true);
    } else {
      setState(() => _error = '密码不对');
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    return Scaffold(
      backgroundColor: s.pageBg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            // 上下留白给足：这一屏只有一件事要做，贴着边缘会显得局促。
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Center(
                  child: Icon(
                    Icons.lock_outline_rounded,
                    size: 44,
                    color: s.muted,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  widget.reason ?? '需要验证才能查看${widget.scope.label}',
                  textAlign: TextAlign.center,
                  style: AppFonts.body(
                    size: 16,
                    weight: FontWeight.w600,
                    color: s.text,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.scope.note,
                  textAlign: TextAlign.center,
                  style: AppFonts.body(size: 12.5, color: s.muted),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _input,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.visiblePassword,
                  textAlign: TextAlign.center,
                  onSubmitted: (_) => _submit(),
                  // 密码是这一屏的主角：22 号、居中，输入时能看清自己在打什么
                  // （圆点之间也留得住间距）。
                  style: AppFonts.body(
                    size: 22,
                    weight: FontWeight.w600,
                    color: s.text,
                    letterSpacing: 2,
                  ),
                  decoration: InputDecoration(
                    labelText: '密码',
                    errorText: _error,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.field),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // 确认键做成**圆形**：和下面那颗"指纹"胶囊在宽度上不再
                // 抢视线，而它又是这一屏的主操作，圆形按钮比整行色块更贴身。
                Center(
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero,
                      ),
                      child: const Icon(Icons.arrow_forward_rounded, size: 26),
                    ),
                  ),
                ),
                if (_canBiometric) ...<Widget>[
                  const SizedBox(height: 20),
                  // 这里的按钮用圆角块（M3），和全应用一致
                  GlassButton(
                    label: '用指纹 / 面部解锁',
                    icon: Icons.fingerprint_rounded,
                    expand: true,
                    onTap: _busy ? null : _useBiometric,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 密码与作用范围的设置页。
class LockSettingsPage extends StatefulWidget {
  const LockSettingsPage({super.key, required this.store});

  final LockStore store;

  @override
  State<LockSettingsPage> createState() => _LockSettingsPageState();
}

class _LockSettingsPageState extends State<LockSettingsPage> {
  final TextEditingController _pwd = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _canBiometric = false;

  @override
  void initState() {
    super.initState();
    SystemAuth.available().then((bool v) {
      if (mounted) setState(() => _canBiometric = v);
    });
  }

  @override
  void dispose() {
    _pwd.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _savePassword() async {
    final String a = _pwd.text;
    if (a.length < 4) {
      _snack('密码至少 4 位');
      return;
    }
    if (a != _confirm.text) {
      _snack('两次输入不一致');
      return;
    }
    await widget.store.setPassword(a);
    _pwd.clear();
    _confirm.clear();
    if (mounted) setState(() {});
    _snack('密码已保存');
  }

  Future<void> _removePassword() async {
    // 删密码前必须能证明是本人 —— 否则拿到手机的人可以直接清空锁。
    final bool ok = await ensureUnlocked(context, LockScope.app);
    if (!ok || !mounted) return;
    await widget.store.clearPassword();
    if (mounted) setState(() {});
    _snack('密码已移除');
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final LockStore lock = widget.store;

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: '密码与安全',
            subtitle: lock.hasPassword ? '已设置密码' : '未设置密码',
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
              children: <Widget>[
                if (!lock.hasPassword) ...<Widget>[
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '设置密码',
                          style: AppFonts.body(
                            size: 15,
                            weight: FontWeight.w600,
                            color: s.text,
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _pwd,
                          obscureText: true,
                          style: AppFonts.body(size: 15, color: s.text),
                          decoration: InputDecoration(
                            labelText: '新密码',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.field,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _confirm,
                          obscureText: true,
                          style: AppFonts.body(size: 15, color: s.text),
                          decoration: InputDecoration(
                            labelText: '再输一次',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.field,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: _savePassword,
                          child: const Text('保存密码'),
                        ),
                      ],
                    ),
                  ),
                ] else ...<Widget>[
                  SurfaceCard(
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.verified_user_outlined,
                          size: 20,
                          color: AppColors.accent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '密码已启用',
                            style: AppFonts.body(
                              size: 15,
                              weight: FontWeight.w600,
                              color: s.text,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _removePassword,
                          child: const Text('移除'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '保护范围',
                    style: AppFonts.body(size: 12.8, color: s.muted),
                  ),
                  const SizedBox(height: 8),
                  for (final LockScope scope in LockScope.values)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SurfaceCard(
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    scope.label,
                                    style: AppFonts.body(
                                      size: 14.5,
                                      weight: FontWeight.w600,
                                      color: s.text,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    scope.note,
                                    style: AppFonts.body(
                                      size: 12,
                                      color: s.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: lock.isEnabled(scope),
                              onChanged: (bool v) async {
                                await lock.setScope(scope, v);
                                if (mounted) setState(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  SurfaceCard(
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                '用指纹 / 面部解锁',
                                style: AppFonts.body(
                                  size: 14.5,
                                  weight: FontWeight.w600,
                                  color: s.text,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _canBiometric
                                    ? '调用系统解锁（设备凭据）'
                                    : '这台设备没有可用的锁屏凭据',
                                style: AppFonts.body(size: 12, color: s.muted),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: lock.biometric && _canBiometric,
                          onChanged: _canBiometric
                              ? (bool v) async {
                                  await lock.setBiometric(v);
                                  if (mounted) setState(() {});
                                }
                              : null,
                        ),
                      ],
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
}
