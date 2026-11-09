// 搜索来源标注：从工具输出里挑 URL。
//
// 这一步不好好做的话，标注出去的东西是**错的链接** —— 比不标更糟：
// 用户点开是 404，或者点到一个风马牛不相及的页面，然后开始怀疑整条回答。
import 'package:dsh_agent/ai/agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('挑出来源，去重，并削掉尾部的标点', () {
    const String out =
        '- [保定天气](https://www.weather.com.cn/weather/101090201.shtml)。\n'
        '- [墨迹天气](https://tianqi.moji.com/baoding)，\n'
        '- 又见 https://www.weather.com.cn/weather/101090201.shtml\n';
    final List<String> urls = sourceUrlsIn(out);

    expect(urls.length, 2, reason: '同一个地址出现两次只算一条');
    expect(
      urls.first,
      'https://www.weather.com.cn/weather/101090201.shtml',
      reason: '中文句号/逗号跟着 URL 一起被正则吃掉的话，点开就是 404',
    );
    expect(urls[1], 'https://tianqi.moji.com/baoding');
  });

  test('最多 6 条（搜索结果按相关度排，先出现的更可能是依据）', () {
    final String out = <int>[
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
    ].map((int i) => 'https://example.com/page$i').join('\n');
    expect(sourceUrlsIn(out).length, 6);
  });

  test('太短的不是页面，太长的多半是带签名的图片地址', () {
    final String longUrl =
        'https://cdn.example.com/img?sig=${List<String>.filled(300, 'a').join()}';
    expect(sourceUrlsIn('https://x.c'), isEmpty, reason: '太短，不像页面');
    expect(sourceUrlsIn(longUrl), isEmpty, reason: '太长，多半是带签名的资源地址');
  });

  test('没有 URL 时返回空（不硬凑）', () {
    expect(sourceUrlsIn('保定今天晴，10~24 度'), isEmpty);
  });
}
