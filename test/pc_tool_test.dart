// `pc` 工具对**地址的解析**。
//
// 这块的失败方式是静默的：用户从 exe 窗口里复制的时候，很容易
// 少复制一段（比如复制成 `http://192.168.43.5:8765/` 而没有 `?token=`），
// 或者复制到浏览器地址栏之后被去掉了查询串。
//
// 不校验的话，结果是连上了一个"没有口令"的请求 → 401 → 用户看到
// "口令不对"，然后去电脑上找 token —— 而真正的问题是他根本没把 token 粘进来。
import 'package:dsh_agent/tools/pc_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PcClient 构造', () {
    test('baseUrl 和 token 分开保存，拼请求时不会丢端口', () {
      final PcClient c = PcClient(
        baseUrl: 'http://192.168.43.5:8765',
        token: 'abc',
      );
      expect(c.baseUrl, 'http://192.168.43.5:8765');
      expect(c.token, 'abc');
    });
  });

  group('PcResponse.describe（给模型看的文本）', () {
    test('exec 会把 stdout 和退出码分开写', () {
      const PcResponse r = PcResponse.forTest(
        ok: true,
        data: <String, dynamic>{
          'exit': 0,
          'stdout': 'hello\n',
          'stderr': '',
          'duration_ms': 12,
        },
      );
      final String s = r.describe('exec');
      expect(s, contains('退出码：0'));
      expect(s, contains('hello'));
      // 没有 stderr 时不该硬塞一个空段
      expect(s.contains('--- stderr ---'), isFalse);
    });

    test('exec 有 stderr 时两段都在', () {
      const PcResponse r = PcResponse.forTest(
        ok: true,
        data: <String, dynamic>{
          'exit': 1,
          'stdout': '',
          'stderr': 'invalid syntax',
        },
      );
      final String s = r.describe('exec');
      // 空 stdout 也要明确写"（无）"，否则模型以为字段丢了
      expect(s, contains('（无）'));
      expect(s, contains('invalid syntax'));
    });

    test('ls 标出目录和大小', () {
      const PcResponse r = PcResponse.forTest(
        ok: true,
        data: <String, dynamic>{
          'path': r'C:\work',
          'entries': <dynamic>[
            <String, dynamic>{'name': 'sub', 'dir': true},
            <String, dynamic>{'name': 'a.txt', 'dir': false, 'size': 12},
          ],
        },
      );
      final String s = r.describe('ls');
      expect(s, contains('[目录] sub'));
      expect(s, contains('a.txt'));
      expect(s, contains('12 字节'));
    });

    test('空目录不会返回空字符串', () {
      const PcResponse r = PcResponse.forTest(
        ok: true,
        data: <String, dynamic>{'path': r'C:\empty', 'entries': <dynamic>[]},
      );
      expect(r.describe('ls'), contains('目录是空的'));
    });

    test('info 列出磁盘可用空间', () {
      const PcResponse r = PcResponse.forTest(
        ok: true,
        data: <String, dynamic>{
          'machine': 'HWL',
          'user': 'lmqhw',
          'os': 'Windows',
          'cores': 32,
          'drives': <dynamic>[
            <String, dynamic>{
              'name': r'C:\',
              'free_gb': 100.5,
              'total_gb': 500.0,
            },
          ],
        },
      );
      final String s = r.describe('info');
      expect(s, contains('HWL'));
      expect(s, contains('32'));
      expect(s, contains('100.5'));
    });
  });
}
