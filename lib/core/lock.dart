import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// **密码保护的作用范围**。
///
/// ## 为什么是"范围"而不是一个总开关
///
/// 用户要保护的从来不是"整个应用"，而是**几类具体的东西**：
/// 设置（可能含密钥）、笔记、计划、记忆、规则、工具、敏感权限。
/// 做成一个开关的话，要么全锁（每次打开应用都要按指纹，很快就被关掉），
/// 要么全不锁（等于没有）。分开之后才可能真的用起来。
enum LockScope {
  /// 启动应用。
  app('app', '打开应用', '每次冷启动都要验证'),

  /// 设置页（里面能改模型、密钥、权限）。
  settings('settings', '设置', '包含模型与密钥'),

  /// 笔记。
  notes('notes', '笔记', '含私人记录'),

  /// 计划 / 待办。
  plans('plans', '计划', '含日程与任务'),

  /// 记忆库。
  memory('memory', '记忆', '含模型记住的偏好'),

  /// 规则（自动化规则、触发条件）。
  rules('rules', '规则', '含自动化触发条件'),

  /// 工具（打开工具清单 / 自定义工具）。
  tools('tools', '工具', '含自定义工具与命令'),

  /// 敏感权限（无障碍、通知读取、Shizuku 等）。
  permissions('permissions', '敏感权限', '含系统级授权');

  const LockScope(this.id, this.label, this.note);

  /// 存在 JSON 里的稳定标识（**不要用 `name`**：改枚举顺序会串）。
  final String id;
  final String label;
  final String note;

  static LockScope? byId(String? id) {
    for (final LockScope s in LockScope.values) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// 密码与作用范围的持久化。
///
/// ## 为什么自己存哈希，不用 SharedPreferences 存明文
///
/// 这是个**本地锁**：拿到手机的人能看到文件。存明文等于没设密码。
/// 这里用 `salt + SHA-256(iterations 轮)`：
///
///  · 加盐 → 彩虹表无效；
///  · 迭代 → 单次试错变慢，四位数字也不至于几毫秒跑完。
///
/// 说明白它的边界：**这不是加密保险箱**。真正的密钥材料（模型 API Key）
/// 仍在设置文件里，这里做的是"挡住拿手机的人随手翻"。
class LockStore extends ChangeNotifier {
  LockStore(this._file);

  final File _file;

  /// 迭代轮数。10000 在手机上约 30~60ms —— 用户感觉不到，
  /// 但暴力枚举 1 万个候选要多花 5~10 分钟。
  static const int _iterations = 10000;

  String _salt = '';

  /// `sha256(salt + password)` 的十六进制。
  String _hash = '';

  /// 已启用的范围。
  final Set<String> _enabled = <String>{};

  /// 是否允许用系统凭据（指纹 / 面部 / PIN）解锁。
  bool biometric = true;

  /// 本次运行内**已经验证过**的范围。
  ///
  /// 只存在内存里：进程被杀就清空 —— 这正是"下次打开还要验证"的实现。
  final Set<String> _unlocked = <String>{};

  bool get hasPassword => _hash.isNotEmpty;

  bool isEnabled(LockScope s) => _enabled.contains(s.id);

  bool isUnlocked(LockScope s) => _unlocked.contains(s.id);

  /// 这个范围现在要不要拦。
  ///
  /// 没设密码 → 永远不拦（否则首次启动会把人锁在外面）。
  bool needsUnlock(LockScope s) =>
      hasPassword && isEnabled(s) && !isUnlocked(s);

  Future<void> load() async {
    _enabled.clear();
    try {
      if (await _file.exists()) {
        final dynamic j = jsonDecode(await _file.readAsString());
        if (j is Map) {
          _salt = (j['salt'] ?? '').toString();
          _hash = (j['hash'] ?? '').toString();
          biometric = j['biometric'] != false;
          final dynamic list = j['scopes'];
          if (list is List) {
            for (final dynamic e in list) {
              final LockScope? s = LockScope.byId(e?.toString());
              if (s != null) _enabled.add(s.id);
            }
          }
        }
      }
    } catch (_) {
      // 存档坏了就当没设密码：宁可不锁，也不能把用户锁在外面。
    }
    notifyListeners();
  }

  Future<void> save() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode(<String, dynamic>{
        'salt': _salt,
        'hash': _hash,
        'biometric': biometric,
        'scopes': _enabled.toList(),
      }),
    );
    notifyListeners();
  }

  /// 设 / 改密码。改密码要求调用方**先**验证旧密码（见 UI 层）。
  Future<void> setPassword(String password) async {
    final Random r = Random.secure();
    _salt = List<int>.generate(
      16,
      (_) => r.nextInt(256),
    ).map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
    _hash = _digest(password, _salt);
    // 换密码后之前"已验证"的标记全部作废 —— 否则改完密码还开着门。
    _unlocked.clear();
    await save();
  }

  Future<void> clearPassword() async {
    _salt = '';
    _hash = '';
    _enabled.clear();
    _unlocked.clear();
    await save();
  }

  bool verify(String password) {
    if (!hasPassword) return false;
    return _digest(password, _salt) == _hash;
  }

  void markUnlocked(LockScope s) {
    _unlocked.add(s.id);
    notifyListeners();
  }

  /// 锁回去（切后台、或者用户点"立即锁定"）。
  void relock([LockScope? only]) {
    if (only == null) {
      _unlocked.clear();
    } else {
      _unlocked.remove(only.id);
    }
    notifyListeners();
  }

  Future<void> setScope(LockScope s, bool on) async {
    if (on) {
      _enabled.add(s.id);
    } else {
      _enabled.remove(s.id);
    }
    await save();
  }

  Future<void> setBiometric(bool on) async {
    biometric = on;
    await save();
  }

  static String _digest(String password, String salt) {
    List<int> bytes = utf8.encode('$salt$password');
    for (int i = 0; i < _iterations; i++) {
      bytes = sha256.convert(bytes).bytes;
    }
    return bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// 系统凭据（指纹 / 面部 / PIN）的桥。
///
/// 走 `KeyguardManager`，**不引入 local_auth**：系统的确认界面会按用户
/// 自己的设置弹出，验证也在系统进程里完成。
class SystemAuth {
  const SystemAuth._();

  static const MethodChannel _ch = MethodChannel('dsh/lock');

  /// 设备上有没有可用的锁屏凭据。
  ///
  /// 返回 false 时 UI 要把"用指纹"那个按钮**藏起来** —— 点一下什么都不发生，
  /// 比没有按钮更让人困惑。
  static Future<bool> available() async {
    try {
      final bool? r = await _ch.invokeMethod<bool>('available');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 弹系统解锁界面，返回是否通过。
  static Future<bool> authenticate() async {
    try {
      final bool? r = await _ch.invokeMethod<bool>('authenticate');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }
}
