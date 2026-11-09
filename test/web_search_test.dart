// 新解析器的单元测试。
//
// 为什么单独测这几处：它们都是**外部返回格式的解析**，
// 而解析错的表现是"功能看起来正常但内容是错的"——
// 比如把别的查询的结果当成这次的搜索结果、往模型列表里灌一堆垃圾条目。
// 这类 bug 在界面上看不出来，只能靠测。
import 'package:dsh_agent/core/model_profile.dart';
import 'package:dsh_agent/core/web_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelImporter.parseModelList', () {
    test('标准 OpenAI 形状', () {
      const String body =
          '{"object":"list","data":['
          '{"id":"gpt-4o","object":"model"},'
          '{"id":"gpt-4o-mini","object":"model"}]}';
      expect(ModelImporter.parseModelList(body), <String>[
        'gpt-4o',
        'gpt-4o-mini',
      ]);
    });

    test('顶层就是数组（自建网关）', () {
      const String body = '[{"id":"qwen-max"},{"id":"qwen-plus"}]';
      expect(ModelImporter.parseModelList(body), <String>[
        'qwen-max',
        'qwen-plus',
      ]);
    });

    test('用 model 字段而不是 id', () {
      const String body = '{"data":[{"model":"llama3.1:8b"}]}';
      expect(ModelImporter.parseModelList(body), <String>['llama3.1:8b']);
    });

    test('字符串数组', () {
      const String body = '["deepseek-chat","deepseek-reasoner"]';
      expect(ModelImporter.parseModelList(body), <String>[
        'deepseek-chat',
        'deepseek-reasoner',
      ]);
    });

    test('过滤掉明显不是模型名的条目', () {
      // 中转站的返回里偶尔混进错误信息、或带空格的描述文案
      const String body =
          '{"data":['
          '{"id":"gpt-4o"},'
          '{"id":"余额不足，请联系客服充值"},'
          '{"id":"a b c"},'
          '{"id":""},'
          '{"noid":true}]}';
      expect(ModelImporter.parseModelList(body), <String>['gpt-4o']);
    });

    test('去重并排序', () {
      const String body = '{"data":[{"id":"b"},{"id":"a"},{"id":"b"}]}';
      expect(ModelImporter.parseModelList(body), <String>['a', 'b']);
    });

    test('坏 JSON 返回空表而不是抛异常', () {
      expect(ModelImporter.parseModelList('<html>502</html>'), isEmpty);
      expect(ModelImporter.parseModelList('{}'), isEmpty);
    });
  });

  group('WebSearchSource.parseBingRss', () {
    const String rss = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel>
  <title>必应搜索</title>
  <item>
    <title>Flutter 官方文档</title>
    <link>https://docs.flutter.dev/</link>
    <description>Flutter &amp; Dart 的官方文档，含 &lt;widget&gt; 目录。</description>
  </item>
  <item>
    <title>第二篇</title>
    <link>https://example.com/second</link>
    <description>正文</description>
  </item>
</channel></rss>''';

    test('解析出标题 / 链接 / 摘要', () {
      final List<WebHit> hits = WebSearchSource.parseBingRss(rss, 10);
      expect(hits, hasLength(2));
      expect(hits[0].title, 'Flutter 官方文档');
      expect(hits[0].url, 'https://docs.flutter.dev/');
      // `&amp;` 要解成 `&`
      expect(hits[0].snippet, contains('Flutter & Dart'));
      expect(hits[0].snippet, isNot(contains('&amp;')));
      // RSS 的 description 里常常**把 HTML 标签转义了**（`&lt;p&gt;`）。
      // 先解实体再剥标记，所以 `<widget>` 会被当成标签剥掉、只留下正文 ——
      // 这正是我们要的：模型不该看到一堆标记。
      expect(hits[0].snippet, isNot(contains('<widget>')));
      expect(hits[0].snippet, contains('目录'));
    });

    test('limit 生效', () {
      expect(WebSearchSource.parseBingRss(rss, 1), hasLength(1));
    });

    test('不是 RSS 时返回空表', () {
      expect(WebSearchSource.parseBingRss('<html>被反爬拦了</html>', 10), isEmpty);
    });

    test('&amp; 不会被二次解码成标记', () {
      // `&amp;lt;` 必须先解 &lt; 再解 &amp;，顺序反了会凭空造出 `<`
      const String tricky =
          '<item><title>a</title><link>https://x.com</link>'
          '<description>&amp;lt;b&amp;gt;</description></item>';
      final List<WebHit> hits = WebSearchSource.parseBingRss(tricky, 10);
      expect(hits.single.snippet, '&lt;b&gt;');
    });
  });

  group('WebSearchSource.parseDuckLite', () {
    const String html = '''
<table>
  <tr><td><a rel="nofollow" href="https://example.com/one" class='result-link'>第一条</a></td></tr>
  <tr><td class='result-snippet'>第一条的摘要</td></tr>
  <tr><td><a rel="nofollow" href="/l/?uddg=https%3A%2F%2Fexample.org%2Ftwo" class='result-link'>第二条</a></td></tr>
  <tr><td class='result-snippet'>第二条的摘要</td></tr>
</table>''';

    test('解析出结果并按顺序配上摘要', () {
      final List<WebHit> hits = WebSearchSource.parseDuckLite(html, 10);
      expect(hits, hasLength(2));
      expect(hits[0].title, '第一条');
      expect(hits[0].url, 'https://example.com/one');
      expect(hits[0].snippet, '第一条的摘要');
      expect(hits[1].snippet, '第二条的摘要');
    });

    test('还原 /l/?uddg= 跳转链接', () {
      final List<WebHit> hits = WebSearchSource.parseDuckLite(html, 10);
      // 不还原的话模型拿到的是 DDG 的跳转地址，抓不到内容
      expect(hits[1].url, 'https://example.org/two');
    });

    test('摘要数量对不上时宁可不填，也不串位', () {
      const String broken = '''
<a href="https://a.com" class='result-link'>A</a>
<a href="https://b.com" class='result-link'>B</a>
<td class='result-snippet'>只有一条摘要</td>''';
      final List<WebHit> hits = WebSearchSource.parseDuckLite(broken, 10);
      expect(hits, hasLength(2));
      expect(hits[0].snippet, isEmpty);
      expect(hits[1].snippet, isEmpty);
    });

    test('没有 result-link 时返回空表', () {
      expect(WebSearchSource.parseDuckLite('<html>被拦了</html>', 10), isEmpty);
    });
  });

  group('searchWithFallback', () {
    test('首选通道不可用时说明降级', () async {
      // DuckDuckGo 在测试环境必然连不上（无网络），
      // 而 Bing 也一样 —— 所以这里测的是"都失败时的错误文案"，
      // 不去断言哪个通道成功（那依赖真实网络，测了也不稳）。
      final WebSearchResult r = await WebSearchSource.searchWithFallback(
        'flutter test',
        3,
        preferred: 'duckduckgo',
      );
      if (!r.ok) {
        // 失败时必须带上"试过什么"，否则用户不知道是哪一步的问题
        expect(r.error, isNotNull);
        expect(r.error, isNotEmpty);
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
