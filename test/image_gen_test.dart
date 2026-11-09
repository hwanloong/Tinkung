// 生图返回体的解析测试。
//
// 为什么必须测：解析失败的表现是"点了生图没反应 / 生成失败"，
// 而用户看不到服务端到底返回了什么。这里把实测见过的几种形状都钉住。
//
// 特别地：**`gpt-image-*` 系列总是返回 b64，而且不接受 `response_format`
// 参数**（发了会 400）。所以工具侧不再发这个字段，两种返回都要能接住。
import 'package:dsh_agent/tools/image_gen_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('_mentionsUnknownParam：判断要不要去掉 response_format 重发', () {
    // 这条判断错了会**朝反方向重试** —— 把"要求带这个参数"当成
    // "拒绝这个参数"，于是把本来能成功的请求改坏。所以正反两面都要测。
    bool mentions(String body) =>
        ImageGenTool.mentionsUnknownParamForTest(body, 'response_format');

    test('拒绝这个参数（该去掉重发）', () {
      expect(
        mentions('{"error":{"message":"Unknown parameter: response_format"}}'),
        isTrue,
      );
      expect(
        mentions(
          '{"error":{"message":"Unrecognized request argument '
          'supplied: response_format"}}',
        ),
        isTrue,
      );
      expect(
        mentions(
          '{"error":{"message":"response_format is not supported '
          'for this model"}}',
        ),
        isTrue,
      );
    });

    test('**要求**这个参数 —— 不能当成拒绝', () {
      // 只说"缺少/必须"，没有"不认识"的意思
      expect(
        mentions('{"error":{"message":"response_format is required"}}'),
        isFalse,
      );
      expect(
        mentions(
          '{"error":{"message":"missing required parameter: '
          'response_format"}}',
        ),
        isFalse,
      );
    });

    test('报错里根本没提这个参数', () {
      expect(mentions('{"error":{"message":"model not found"}}'), isFalse);
      expect(mentions('{"error":{"message":"insufficient balance"}}'), isFalse);
    });

    test('顺带认其它字段名（函数是通用的）', () {
      expect(
        ImageGenTool.mentionsUnknownParamForTest(
          '{"error":{"message":"Unknown parameter: quality"}}',
          'quality',
        ),
        isTrue,
      );
    });
  });

  group('parseImageResponse', () {
    test('标准 b64_json（gpt-image 系的形状）', () {
      // "aGVsbG8=" 是 "hello"
      const String body = '{"created":1,"data":[{"b64_json":"aGVsbG8="}]}';
      final GenImage? img = ImageGenTool.parseImageResponse(body);
      expect(img, isNotNull);
      expect(img!.bytes, isNotNull);
      expect(String.fromCharCodes(img.bytes!), 'hello');
    });

    test('标准 url（dall-e 的默认形状）', () {
      const String body =
          '{"data":[{"url":"https://example.com/a.png","revised_prompt":"x"}]}';
      final GenImage? img = ImageGenTool.parseImageResponse(body);
      expect(img, isNotNull);
      expect(img!.url, 'https://example.com/a.png');
    });

    test('data URL 前缀的 b64 也能解', () {
      const String body =
          '{"data":[{"b64_json":"data:image/png;base64,aGVsbG8="}]}';
      final GenImage? img = ImageGenTool.parseImageResponse(body);
      expect(img?.bytes, isNotNull);
      expect(String.fromCharCodes(img!.bytes!), 'hello');
    });

    test('b64 里有换行也能解', () {
      const String body = '{"data":[{"b64_json":"aGVs\\nbG8="}]}';
      final GenImage? img = ImageGenTool.parseImageResponse(body);
      expect(img?.bytes, isNotNull);
    });

    test('各家自创的 images / output 字段也认', () {
      expect(
        ImageGenTool.parseImageResponse(
          '{"images":[{"url":"https://x.com/1.png"}]}',
        )?.url,
        'https://x.com/1.png',
      );
      expect(
        ImageGenTool.parseImageResponse(
          '{"output":{"url":"https://x.com/2.png"}}',
        )?.url,
        'https://x.com/2.png',
      );
      // 字段直接放在顶层
      expect(
        ImageGenTool.parseImageResponse('{"url":"https://x.com/3.png"}')?.url,
        'https://x.com/3.png',
      );
    });

    test('用 image / image_url 做字段名的也认', () {
      expect(
        ImageGenTool.parseImageResponse(
          '{"data":[{"image":"https://x.com/4.png"}]}',
        )?.url,
        'https://x.com/4.png',
      );
    });

    test('b64 优先于 url（同一个对象里两个都有时）', () {
      const String body =
          '{"data":[{"b64_json":"aGVsbG8=","url":"https://x.com/5.png"}]}';
      final GenImage? img = ImageGenTool.parseImageResponse(body);
      expect(img!.bytes, isNotNull, reason: '有 b64 就该直接用，不再多跑一趟网络');
      expect(img.url, isNull);
    });

    test('没有图片数据时返回 null（而不是抛异常）', () {
      expect(ImageGenTool.parseImageResponse('{"data":[]}'), isNull);
      expect(ImageGenTool.parseImageResponse('{}'), isNull);
      // 服务端返回的纯文本错误
      expect(ImageGenTool.parseImageResponse('model not found'), isNull);
      // 非法 base64
      expect(
        ImageGenTool.parseImageResponse('{"data":[{"b64_json":"!!!not-b64"}]}'),
        isNull,
      );
    });

    test('坏 JSON 返回 null', () {
      expect(ImageGenTool.parseImageResponse('<html>502</html>'), isNull);
    });
  });

  group('edit_from 的解析：一张 / 多张都要收得住', () {
    // "把图二的衣服 P 到图一上"这类需求必须**两张一起**发到编辑端点：
    // 只发一张，生图模型看不到另一张，只能凭空编（用户看到的就是
    // "生图错误"或者一张毫不相干的图）。所以解析这里少一张都不行。
    test('字符串 = 一张（老写法，模型经常还给字符串）', () {
      expect(
        ImageGenTool.sourcesOf(<String, dynamic>{'edit_from': '/tmp/a.png'}),
        <String>['/tmp/a.png'],
      );
    });

    test('数组 = 按顺序多张', () {
      expect(
        ImageGenTool.sourcesOf(<String, dynamic>{
          'edit_from': <String>['/tmp/one.png', '/tmp/two.png'],
        }),
        <String>['/tmp/one.png', '/tmp/two.png'],
        reason:
            '顺序就是"图 1、图 2"，发给生图模型时也按这个顺序 —— '
            '换顺序等于把衣服穿到别人身上',
      );
    });

    test('空串、空白、重复的都滤掉', () {
      expect(
        ImageGenTool.sourcesOf(<String, dynamic>{
          'edit_from': <String>['', '  ', '/tmp/a.png', '/tmp/a.png'],
        }),
        <String>['/tmp/a.png'],
        reason: '重复发同一张会被一些服务当成"两张不一样的图"直接 400',
      );
    });

    test('没给 edit_from 时是纯文生图（空列表）', () {
      expect(ImageGenTool.sourcesOf(<String, dynamic>{}), isEmpty);
      expect(
        ImageGenTool.sourcesOf(<String, dynamic>{'edit_from': <String>[]}),
        isEmpty,
      );
    });
  });
}
