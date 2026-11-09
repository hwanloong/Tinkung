// 「图像老是不走多模态、直接 OCR」的配置层回归。
//
// 现象：设置页写着「地址/密钥留空则复用上面那条」，用户只填了模型名
// （或只填了地址），读图却直接掉到本地 OCR。
//
// 根因：`ImageTool` 曾经要求**地址和密钥同时非空**才认这个视觉模型 ——
// 用户按提示留空的那一项，反而让整份配置被跳过；主模型再不支持图像
// （deepseek-v4-pro）时，候选列表为空 → 只能 OCR。
//
// 这里钉的是"候选怎么解析"，不依赖网络或真实模型。
import 'package:dsh_agent/tools/extra_tools.dart';
import 'package:flutter_test/flutter_test.dart';

List<VisionTarget> _resolve({
  String mainBaseUrl = 'https://api.deepseek.com',
  String mainApiKey = 'main-key',
  String mainModel = 'deepseek-v4-pro',
  bool mainSeesImages = false,
  String visionBaseUrl = '',
  String visionApiKey = '',
  String visionModel = 'deepseek-flash',
}) => resolveVisionTargets(
  mainBaseUrl: mainBaseUrl,
  mainApiKey: mainApiKey,
  mainModel: mainModel,
  mainSeesImages: mainSeesImages,
  visionBaseUrl: visionBaseUrl,
  visionApiKey: visionApiKey,
  visionModel: visionModel,
);

void main() {
  group('视觉候选解析', () {
    test('主模型不支持图像、没配视觉 → 用主档案试默认视觉模型', () {
      final List<VisionTarget> t = _resolve();

      expect(t, hasLength(1), reason: 'deepseek-v4-pro 用户不该因为没配视觉模型就直接 OCR');
      expect(t.single.model, 'deepseek-flash');
      expect(t.single.baseUrl, 'https://api.deepseek.com');
      expect(t.single.apiKey, 'main-key');
    });

    test('只填了视觉地址：密钥按设置页说明复用主 key', () {
      final List<VisionTarget> t = _resolve(
        visionBaseUrl: 'https://relay.example.com/v1',
        visionApiKey: '',
        visionModel: 'qwen-vl-max',
      );

      expect(t, isNotEmpty);
      expect(t.first.baseUrl, 'https://relay.example.com/v1');
      expect(
        t.first.apiKey,
        'main-key',
        reason: '页面写的是"留空则复用主模型的 Key"，不能因为留空就跳过',
      );
      expect(t.first.model, 'qwen-vl-max');
    });

    test('只填了视觉 Key：地址复用主档案', () {
      final List<VisionTarget> t = _resolve(
        visionBaseUrl: '',
        visionApiKey: 'vision-key',
        visionModel: 'deepseek-flash',
      );

      expect(t.first.baseUrl, 'https://api.deepseek.com');
      expect(t.first.apiKey, 'vision-key');
    });

    test('主模型自己能看图 → 直接用它', () {
      final List<VisionTarget> t = _resolve(
        mainModel: 'deepseek-flash',
        mainSeesImages: true,
      );

      expect(t, hasLength(1));
      expect(t.single.model, 'deepseek-flash');
      expect(t.single.label, '主模型');
    });

    test('视觉配置和主模型相同 → 只请求一次', () {
      final List<VisionTarget> t = _resolve(
        mainModel: 'deepseek-flash',
        mainSeesImages: true,
        visionBaseUrl: 'https://api.deepseek.com',
        visionApiKey: 'main-key',
        visionModel: 'deepseek-flash',
      );

      expect(t, hasLength(1), reason: '同一地址 + 同一模型重复请求只是白等');
    });

    test('主模型能看图、自定义视觉失败后仍能兜底', () {
      final List<VisionTarget> t = _resolve(
        mainSeesImages: true,
        visionBaseUrl: 'https://relay.example.com/v1',
        visionApiKey: 'relay-key',
        visionModel: 'qwen-vl-max',
      );

      expect(t.map((VisionTarget e) => e.label), <String>['自定义视觉模型', '主模型']);
    });

    test('没有主模型 Key 时不产生任何候选（交给 OCR 并说明原因）', () {
      expect(_resolve(mainApiKey: ''), isEmpty);
    });

    test('用户说主模型看不了图、而兜底模型就是它自己 → 不再试', () {
      expect(
        _resolve(
          mainModel: 'deepseek-flash',
          mainSeesImages: false,
          visionModel: 'deepseek-flash',
        ),
        isEmpty,
        reason: '同一个模型再发一次只会拿到同样的 400，多等一轮',
      );
    });

    test('模型名留空时按 deepseek-flash 兜底', () {
      final List<VisionTarget> t = _resolve(visionModel: '');
      expect(t.single.model, 'deepseek-flash');
    });
  });

  group('视觉接口地址', () {
    test('只有域名时补 /chat/completions', () {
      expect(
        visionChatEndpoint('https://api.deepseek.com'),
        'https://api.deepseek.com/chat/completions',
      );
      expect(
        visionChatEndpoint('https://api.deepseek.com///'),
        'https://api.deepseek.com/chat/completions',
      );
    });

    test('粘的是完整 endpoint 时不再重复拼接', () {
      expect(
        visionChatEndpoint('https://api.deepseek.com/chat/completions'),
        'https://api.deepseek.com/chat/completions',
        reason: '重复拼接会 404，然后被当成"识图失败"降级 OCR',
      );
      expect(
        visionChatEndpoint('https://relay.example.com/v1/chat/completions'),
        'https://relay.example.com/v1/chat/completions',
      );
    });

    test('带 /v1 的 base 正常补全', () {
      expect(
        visionChatEndpoint('https://relay.example.com/v1/'),
        'https://relay.example.com/v1/chat/completions',
      );
    });
  });
}
