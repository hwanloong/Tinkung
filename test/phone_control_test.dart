import 'package:dsh_agent/core/phone_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('语义操作和绘制算手机控制', () {
    expect(isPhoneControlCall('ui_action', <String, dynamic>{}), isTrue);
    expect(isPhoneControlCall('draw_path', <String, dynamic>{}), isTrue);
  });

  test('shell 里的 input / monkey / am start 算手机控制', () {
    for (final String cmd in <String>[
      'input tap 500 900',
      'monkey -p com.demo 1',
      'am start -a android.intent.action.VIEW -d https://example.com',
    ]) {
      expect(
        isPhoneControlCall('run_shell', <String, dynamic>{'command': cmd}),
        isTrue,
        reason: cmd,
      );
    }
  });

  test('普通任务不弹浮窗', () {
    expect(
      isPhoneControlCall('run_shell', <String, dynamic>{'command': 'ls -la'}),
      isFalse,
    );
    expect(
      isPhoneControlCall('python', <String, dynamic>{'code': 'print(1)'}),
      isFalse,
    );
    expect(isPhoneControlCall('file', <String, dynamic>{}), isFalse);
    expect(
      isPhoneControlCall('app_manage', <String, dynamic>{'action': 'list'}),
      isFalse,
    );
  });

  test('应用管理只有启动类动作算手机控制', () {
    expect(
      isPhoneControlCall('app_manage', <String, dynamic>{'action': 'launch'}),
      isTrue,
    );
    expect(
      isPhoneControlCall('app_manage', <String, dynamic>{'action': 'open'}),
      isTrue,
    );
  });
}
