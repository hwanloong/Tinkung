// 把浏览器里的 cookie 导出成 curl 能直接吃的 `cookies.txt`。
//
// ## 为什么值得单独测
//
// 这是"AI 在浏览器里登录过 → 让 termux 里的 curl 带着登录态去拉接口"
// 这条链上唯一的格式转换点。Netscape 那个格式是**制表符分隔的老古董**：
// 列数、域名前那个点、过期时间用 Unix 秒……让模型手写，它每次都写错，
// 而 curl 拿到错的文件只会**静默地不带 cookie**（不报错），
// 表现为"接口返回未登录"，排查时根本想不到是导出的格式错了一列。
import 'package:dsh_agent/tools/webview_loader.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('导出成 Netscape 格式：七列、制表符分隔', () {
    final String out = WebViewLoader.netscapeCookies(<Cookie>[
      Cookie(name: 'sid', value: 'abc123', domain: '.example.com', path: '/'),
      Cookie(
        name: 'token',
        value: 'xyz',
        domain: 'api.example.com',
        path: '/v1',
        expiresDate: 1800000000,
      ),
    ]);

    final List<String> lines = out
        .split('\n')
        .where((String l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
    expect(lines.length, 2);

    final List<String> first = lines[0].split('\t');
    expect(first.length, 7, reason: 'Netscape 格式就是 7 列，少一列 curl 会整份不理');
    expect(first[0], 'example.com', reason: '域名前那个点是"含子域"的标记，不属于域名本身');
    expect(first[1], 'TRUE', reason: '以点开头的域 → 第 2 列 TRUE');
    expect(first[2], '/');
    expect(first[3], 'TRUE', reason: 'HTTPS 标记');
    expect(first[4], '0', reason: '没有过期时间＝会话 cookie，写 0');
    expect(first[5], 'sid');
    expect(first[6], 'abc123');

    final List<String> second = lines[1].split('\t');
    expect(second[0], 'api.example.com');
    expect(second[1], 'FALSE');
    expect(second[4], '1800000000', reason: '过期时间是 Unix 秒');
  });

  test('没有域名的 cookie 直接丢掉（写进去会污染整个文件）', () {
    final String out = WebViewLoader.netscapeCookies(<Cookie>[
      Cookie(name: 'noname', value: 'v'),
      Cookie(name: 'ok', value: 'v', domain: 'a.com', path: '/'),
    ]);
    expect(out.contains('noname'), isFalse);
    expect(out.contains('ok'), isTrue);
  });
}
