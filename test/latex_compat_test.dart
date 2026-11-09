// LaTeX 兼容层的单元测试。
//
// 这些字符串都是**模型真实会写**、而 `flutter_math_fork` 直接解析失败的写法。
// 断言两件事：
//
//   1. 规整之后解析器能过（这才是"公式能渲染"的判据）；
//   2. 兜底的纯文本至少是「人能读」的，不是一串反斜杠。
import 'package:dsh_agent/ui/latex_compat.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

bool _parses(String latex) =>
    Math.tex(normalizeLatex(latex)).parseError == null;

void main() {
  group('normalizeLatex 让不兼容写法变得可渲染', () {
    test('环境别名', () {
      for (final String env in <String>[
        'align',
        'align*',
        'equation',
        'equation*',
        'gather',
        'gather*',
        'gathered',
        'split',
        'multline',
        'eqnarray',
      ]) {
        final String src = '\\begin{$env} a &= b \\\\ c &= d \\end{$env}';
        expect(_parses(src), isTrue, reason: '$env 应该被换成 aligned');
      }
    });

    test('cases* / dcases', () {
      expect(_parses(r'\begin{cases*} x & a \\ y & b \end{cases*}'), isTrue);
      expect(_parses(r'\begin{dcases} x & a \end{dcases}'), isTrue);
    });

    test('编号、标签、对齐开关', () {
      expect(_parses(r'\tag{1} x=1'), isTrue);
      expect(_parses(r'\label{eq:1} x=1'), isTrue);
      expect(_parses(r'x=1 \notag'), isTrue);
      expect(_parses(r'x=1 \nonumber'), isTrue);
      expect(normalizeLatex(r'\tag{1} x=1'), isNot(contains(r'\tag')));
      expect(normalizeLatex(r'\label{eq:1} x=1'), isNot(contains(r'\label')));
    });

    test('顶层 & 自动包一层 aligned', () {
      expect(_parses(r'a &= b \\ c &= d'), isTrue);
      expect(_parses(r'f(x) &= x^2 \\ g(x) &= x+1'), isTrue);
      // 已经有环境时不能再包一层
      final String s = normalizeLatex(r'\begin{cases} a & b \end{cases}');
      expect(s, isNot(contains(r'\begin{aligned}')));
    });

    test('化学式 / 物理量 / 单位', () {
      expect(_parses(r'\ce{H2O}'), isTrue);
      expect(_parses(r'\ce{2H2 + O2 -> 2H2O}'), isTrue);
      expect(_parses(r'\pu{5 m/s}'), isTrue);
      expect(_parses(r'\SI{9.8}{m/s^2}'), isTrue);
      expect(_parses(r'\qty{3}{\mu m}'), isTrue);
      expect(_parses(r'\unit{kg}'), isTrue);
      expect(_parses(r'\num{3.14}'), isTrue);
      expect(_parses(r'\ang{30}'), isTrue);
      // 箭头要真的换成数学符号
      expect(normalizeLatex(r'\ce{A -> B}'), contains(r'\rightarrow'));
    });

    test('MathJax 风格的宏', () {
      expect(_parses(r'\abs{x}'), isTrue);
      expect(_parses(r'\norm{x}_2'), isTrue);
      expect(_parses(r'\order{\log n}'), isTrue);
      expect(_parses(r'\eval{x^2}_0^1'), isTrue);
      expect(_parses(r'\mathds{1}'), isTrue);
      expect(_parses(r'\overparen{AB}'), isTrue);
      expect(_parses(r'\underparen{AB}'), isTrue);
      expect(_parses(r'\wideparen{AB}'), isTrue);
      expect(_parses(r'\dv{f}{x}'), isTrue);
      expect(_parses(r'\pdv{u}{x}'), isTrue);
      expect(_parses(r'\displaylines{a \\ b}'), isTrue);
    });

    test('原来的正常公式不被改坏', () {
      for (final String src in <String>[
        r'E = mc^2',
        r'\frac{-b \pm \sqrt{b^2-4ac}}{2a}',
        r'\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}',
        r'\begin{cases} x & x>0 \\ -x & x\le 0 \end{cases}',
        r'\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}',
        r'\text{速度 } v = \frac{s}{t}',
        r'x \in \mathbb{R}^n',
      ]) {
        expect(_parses(src), isTrue, reason: src);
      }
    });

    test('幂等：规整两遍结果一样', () {
      for (final String src in <String>[
        r'a &= b \\ c &= d',
        r'\ce{H2O}',
        r'\SI{9.8}{m/s^2}',
        r'\tag{1} x=1',
      ]) {
        final String once = normalizeLatex(src);
        expect(normalizeLatex(once), once, reason: src);
      }
    });
  });

  group('repairLatex 是最后一档抢救', () {
    test('干掉坏掉的环境与裸符号', () {
      final String s = repairLatex(r'\begin{foo} a & b \\ \end{foo}');
      expect(s, isNot(contains(r'\begin{foo}')));
      expect(s, isNot(contains('&')));
    });

    test('落单的上下标不会让整条消息空白', () {
      expect(repairLatex('x^'), isNot(endsWith('^')));
      expect(repairLatex('x_'), isNot(endsWith('_')));
    });
  });

  group('latexToPlain 至少能读', () {
    test('分式与根号', () {
      expect(latexToPlain(r'\frac{a}{b}'), contains('(a)/(b)'));
      expect(latexToPlain(r'\sqrt{x}'), contains('√'));
    });

    test('希腊字母与关系符', () {
      final String t = latexToPlain(r'\alpha + \beta \le \infty');
      expect(t, contains('α'));
      expect(t, contains('β'));
      expect(t, contains('≤'));
      expect(t, contains('∞'));
    });

    test('不再露出反斜杠命令', () {
      expect(latexToPlain(r'\text{速度}'), contains('速度'));
      expect(latexToPlain(r'\foo{x} + \bar'), isNot(contains(r'\foo')));
    });
  });
}
