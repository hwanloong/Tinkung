// 报错翻译的测试。
//
// 为什么值得单独测：**服务端的错误文案是用户唯一能看到的线索**。
// 原文是英文、而且只说现象不说动作，翻错了会让排查方向彻底跑偏
// （比如"模型名不存在"被当成"密钥错了"，用户会去反复换 Key）。
import 'package:dsh_agent/ai/deepseek.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('humanizeError 认认真实会遇到的几种错误', () {
    test('拿生图模型去对话 —— 这次实测遇到的那个', () {
      const String body =
          '{"error":{"message":'
          '"This model is not supported on chat completions endpoint",'
          '"type":"invalid_request_error"}}';
      final String out = DeepSeekClient.humanizeError(body);

      // 原文要保留：用户可能需要拿它去搜/去问客服
      expect(out, contains('not supported on chat completions endpoint'));
      // 更要紧的是**补上了怎么办**
      expect(out, contains('不提供对话接口'));
      expect(out, contains('换一个对话模型'));
      expect(out, contains('images/generations'));
    });

    test('大小写和措辞不同也要认出来', () {
      const String body =
          '{"message":"The model is unsupported for '
          'CHAT COMPLETIONS."}';
      expect(DeepSeekClient.humanizeError(body), contains('不提供对话接口'));
    });

    test('反过来：拿对话模型去生图', () {
      const String body =
          '{"error":{"message":'
          '"This model is not supported for image generation."}}';
      final String out = DeepSeekClient.humanizeError(body);
      expect(out, contains('不支持生成图片'));
      expect(out, contains('关掉'));
    });

    test('模型名写错（中转站最常见）', () {
      const String body =
          '{"error":{"message":'
          '"The model `gpt-4o-x` does not exist"}}';
      final String out = DeepSeekClient.humanizeError(body);
      expect(out, contains('不认识这个模型名'));
      expect(out, contains('批量导入'));
    });

    test('endpoint 这个词单独出现、但不是"用错模型"时不乱补建议', () {
      // 比如限流错误里也含 endpoint —— 不能被误判成用错端点
      const String body =
          '{"error":{"message":'
          '"Rate limit reached for the chat completions endpoint."}}';
      final String out = DeepSeekClient.humanizeError(body);
      expect(out, isNot(contains('不提供对话接口')));
    });

    test('不认识的错误：原样返回，不硬编一段可能误导的话', () {
      const String body = '{"error":{"message":"Internal server error"}}';
      expect(DeepSeekClient.humanizeError(body), 'Internal server error');
    });

    test('不是 JSON 时用原文（截断）', () {
      final String body = '<html>${'x' * 500}</html>';
      final String out = DeepSeekClient.humanizeError(body);
      expect(out.length, lessThan(450));
      expect(out, endsWith('…'));
    });
  });
}
