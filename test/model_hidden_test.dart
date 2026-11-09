import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_agent/core/model_profile.dart';
import 'package:dsh_agent/core/store.dart';

/// 模型**隐藏**（只在切换列表里不显示，档案仍在）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Settings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = await Settings.load();
    settings.profiles
      ..clear()
      ..addAll(<ModelProfile>[
        ModelProfile(id: 'a', name: 'A', model: 'a'),
        ModelProfile(id: 'b', name: 'B', model: 'b'),
        ModelProfile(id: 'c', name: 'C', model: 'c'),
      ]);
  });

  test('隐藏之后 isProfileHidden 为真，其他不受影响', () {
    settings.setProfileHidden('b', true);
    expect(settings.isProfileHidden('b'), isTrue);
    expect(settings.isProfileHidden('a'), isFalse);
    // 档案本身还在列表里 —— 隐藏不是删除。
    expect(settings.profiles.map((ModelProfile p) => p.id), contains('b'));
  });

  test('再次传 false 就恢复', () {
    settings.setProfileHidden('b', true);
    settings.setProfileHidden('b', false);
    expect(settings.isProfileHidden('b'), isFalse);
  });

  test('不能隐藏当前正在用的模型', () {
    settings.selectProfile('a');
    settings.setProfileHidden('a', true);
    expect(
      settings.isProfileHidden('a'),
      isFalse,
      reason: '当前模型必须一直可见，否则用户看不到自己在用什么',
    );
  });

  test('切到被隐藏的模型会自动让它可见', () {
    settings.setProfileHidden('c', true);
    settings.selectProfile('c');
    expect(settings.isProfileHidden('c'), isFalse);
  });

  test('隐藏的 id 会持久化', () async {
    await settings.update(() => settings.setProfileHidden('b', true));
    final Settings again = await Settings.load();
    expect(again.isProfileHidden('b'), isTrue);
  });
}
