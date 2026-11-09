// 生图工具的**改图端点**拼接。
//
// 这块的失败方式是"静默走错分支"：路径拼错了会 404，
// 而 404 的报错只说"接口不存在"，完全看不出是本地拼坏的 ——
// 用户会以为是自己模型名填错了，去反复改一个本来对的配置。
import 'package:dsh_agent/tools/image_gen_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('改图端点拼接', () {
    test('标准 generations 端点换成 edits', () {
      expect(
        ImageGenTool.editEndpointForTest(
          Uri.parse('https://api.x.com/v1/images/generations'),
        ).toString(),
        'https://api.x.com/v1/images/edits',
      );
    });

    test('只给 baseUrl（带 /v1）时补上 images/edits', () {
      expect(
        ImageGenTool.editEndpointForTest(Uri.parse('https://api.x.com/v1'))
            .toString(),
        'https://api.x.com/v1/images/edits',
      );
    });

    test('只给域名时补全整条路径', () {
      expect(
        ImageGenTool.editEndpointForTest(Uri.parse('https://api.x.com'))
            .toString(),
        'https://api.x.com/v1/images/edits',
      );
    });

    test('带前缀的中转站路径只改最后一段', () {
      // 这条是重点：用 replaceAll 会把路径里**所有**出现的
      // "generations" 都换掉，前缀里万一有同名字段就一起坏了。
      expect(
        ImageGenTool.editEndpointForTest(
          Uri.parse('https://relay.cn/api/v3/images/generations'),
        ).toString(),
        'https://relay.cn/api/v3/images/edits',
      );
    });

    test('已经是 edits 时保持原样（幂等，不会变成 edits/edits）', () {
      expect(
        ImageGenTool.editEndpointForTest(
          Uri.parse('https://api.x.com/v1/images/edits'),
        ).toString(),
        'https://api.x.com/v1/images/edits',
      );
    });

    test('查询参数保留', () {
      expect(
        ImageGenTool.editEndpointForTest(
          Uri.parse('https://api.x.com/v1/images/generations?k=1'),
        ).toString(),
        'https://api.x.com/v1/images/edits?k=1',
      );
    });
  });
}
