// 往浏览器里**写** cookie：解析部分。
//
// 这一段错了不会报错，只会**静默写进去一堆垃圾** —— 而 cookie 是登录态，
// 污染它的表现是"这个站点突然登不上了"，排查时根本想不到是格式化的问题。
import 'package:dsh_agent/tools/webview_loader.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('一行 document.cookie 写法：a=1; b=2', () {
    final List<Cookie> c = WebViewLoader.parseCookieInput(
      'a=1; b=2',
      defaultDomain: 'x.com',
    );
    expect(c.length, 2);
    expect(c[0].name, 'a');
    expect(c[0].value, '1');
    expect(c[0].domain, 'x.com', reason: '没写域名时用调用方给的默认域名');
    expect(c[1].name, 'b');
  });

  test('一行一个', () {
    final List<Cookie> c = WebViewLoader.parseCookieInput(
      'sid=abc\n token = xyz \n',
      defaultDomain: 'x.com',
    );
    expect(c.length, 2);
    expect(c[1].name, 'token');
    expect(c[1].value, 'xyz', reason: '等号两边的空格要去掉');
  });

  test('Netscape 格式（我们导出的那份可以直接写回去）', () {
    final List<Cookie> c = WebViewLoader.parseCookieInput(
      '# 注释行\n'
      'example.com\tTRUE\t/\tTRUE\t1800000000\tsid\tabc123\n',
      defaultDomain: 'other.com',
    );
    expect(c.length, 1);
    expect(c[0].name, 'sid');
    expect(c[0].value, 'abc123');
    expect(c[0].domain, 'example.com', reason: '这种写法自带域名，不用默认值');
    expect(c[0].expiresDate, 1800000000);
  });

  test('认不出来的行直接忽略，不硬塞', () {
    expect(WebViewLoader.parseCookieInput('这是一句中文'), isEmpty);
    expect(WebViewLoader.parseCookieInput('=noName'), isEmpty);
    expect(WebViewLoader.parseCookieInput(''), isEmpty);
  });
}
