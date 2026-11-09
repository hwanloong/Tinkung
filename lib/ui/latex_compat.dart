/// LaTeX 兼容层。
///
/// ## 它修的是什么
///
/// 模型写公式时习惯用 **MathJax / 完整 LaTeX** 的那一套：
/// `\begin{align}`、`\tag{1}`、`\ce{H2O}`、`\abs{x}`、把 `&` 对齐符直接写在
/// `$$...$$` 里……而 `flutter_math_fork` 只实现了 **KaTeX 的一个子集**。
/// 解析器一报错，公式就退回"显示原始 LaTeX 字符串"——用户看到的就是
/// **"这段公式没渲染出来"**。
///
/// 这里干两件事：
///
/// 1. [normalizeLatex]：把常见的不兼容写法换成等价的可渲染写法
///    （环境改名、去掉编号/标签、宏展开）。失败率为 0，纯字符串处理。
/// 2. [repairLatex]：仍然解析失败时的兜底修复（去掉顶层 `&`、`\\` 等）。
/// 3. [latexToPlain]：真的救不回来时，输出**人能读的**纯文本公式，
///    而不是一串 `\frac{a}{b}` 原样糊在屏幕上。
///
/// 全部是纯函数，方便单测（见 `test/latex_compat_test.dart`）。
library;

/// `flutter_math_fork` 认识的环境（多了会解析失败）。
const Set<String> supportedMathEnvs = <String>{
  'array',
  'darray',
  'matrix',
  'pmatrix',
  'bmatrix',
  'Bmatrix',
  'vmatrix',
  'Vmatrix',
  'smallmatrix',
  'subarray',
  'cases',
  'dcases',
  'rcases',
  'drcases',
  'aligned',
  'alignedat',
};

/// 模型爱写、但包不认的环境 → 等价的可渲染环境。
const Map<String, String> _envAlias = <String, String>{
  'align': 'aligned',
  'align*': 'aligned',
  'alignat': 'aligned',
  'alignat*': 'aligned',
  'flalign': 'aligned',
  'flalign*': 'aligned',
  'equation': 'aligned',
  'equation*': 'aligned',
  'gather': 'aligned',
  'gather*': 'aligned',
  'gathered': 'aligned',
  'split': 'aligned',
  'multline': 'aligned',
  'multline*': 'aligned',
  'eqnarray': 'aligned',
  'eqnarray*': 'aligned',
  'displaylines': 'aligned',
  'cases*': 'cases',
  'dcases*': 'dcases',
  'rcases*': 'rcases',
};

/// 数学环境（用来识别"没有 `$$` 包着的裸 `\begin{align}`"）。
final Set<String> mathEnvs = <String>{...supportedMathEnvs, ..._envAlias.keys};

/// 常见宏 → 可渲染写法的固定替换（不带参数的那些）。
const Map<String, String> _simpleMacros = <String, String>{
  r'\degree': r'^{\circ}',
  r'\celsius': r'^{\circ}\mathrm{C}',
  r'\ohm': r'\Omega',
  r'\micro': r'\mu',
  r'\mathds': r'\mathbb',
  r'\wideparen': r'\widehat',
  r'\overparen': r'\overbrace',
  r'\underparen': r'\underbrace',
  r'\newline': r'\\',
  r'\linebreak': r'\\',
};

/// 把模型输出规整成 `flutter_math_fork` 能解析的写法。
///
/// 幂等：对已经规整过的字符串再跑一遍不会继续变形。
String normalizeLatex(String src) {
  String s = src.trim();
  if (s.isEmpty) return s;

  // ---- 1. 编号 / 标签 / 纯排版开关：包里没有这些概念，直接丢掉 ----
  s = s.replaceAll(RegExp(r'\\tag\*?\s*\{[^{}]*\}'), '');
  s = s.replaceAll(RegExp(r'\\label\s*\{[^{}]*\}'), '');
  s = s.replaceAll(RegExp(r'\\(?:nonumber|notag|allowbreak|nobreak)\b'), '');
  s = s.replaceAll(RegExp(r'\\(?:limits|nolimits)\b'), '');

  // ---- 2. `\\[2mm]` 这种换行间距：包不认方括号参数 ----
  s = s.replaceAll(RegExp(r'\\\\\s*\[[^\]]*\]'), r'\\');

  // ---- 3. 环境改名 ----
  s = s.replaceAllMapped(RegExp(r'\\(begin|end)\s*\{([a-zA-Z]+\*?)\}'), (
    Match m,
  ) {
    final String name = m.group(2)!;
    final String mapped = _envAlias[name] ?? name;
    return '\\${m.group(1)}{$mapped}';
  });

  // ---- 4. 无参数的宏 ----
  for (final MapEntry<String, String> e in _simpleMacros.entries) {
    s = s.replaceAll(e.key, e.value);
  }
  s = s.replaceAll(r'\operatorname*', r'\operatorname');

  // ---- 5. 带参数的宏：展开成包能渲染的等价形式 ----
  s = _replaceBraced(
    s,
    r'\abs',
    (String x) => r'\left\lvert ' + x + r'\right\rvert',
  );
  s = _replaceBraced(
    s,
    r'\norm',
    (String x) => r'\left\lVert ' + x + r'\right\rVert',
  );
  s = _replaceBraced(
    s,
    r'\order',
    (String x) => r'\mathcal{O}\left(' + x + r'\right)',
  );
  s = _replaceBraced(s, r'\eval', (String x) => r'\left.' + x + r'\right|');
  s = _replaceBraced(s, r'\dd', (String x) => r'\mathrm{d}' + x);
  // 导数：`\dv{f}{x}` 两个参数时展开成真正的分式
  s = _replaceTwoArgs(
    s,
    r'\pdv',
    (String a, String b) => r'\frac{\partial ' + a + r'}{\partial ' + b + r'}',
  );
  s = _replaceTwoArgs(
    s,
    r'\dv',
    (String a, String b) =>
        r'\frac{\mathrm{d}' + a + r'}{\mathrm{d}' + b + r'}',
  );
  s = _replaceBraced(s, r'\pdv', (String x) => r'\partial ' + x);
  s = _replaceBraced(s, r'\dv', (String x) => r'\mathrm{d}' + x);
  s = _replaceBraced(
    s,
    r'\displaylines',
    (String x) => '\\begin{aligned}$x\\end{aligned}',
  );
  s = _replaceBraced(
    s,
    r'\substack',
    (String x) => '\\begin{subarray}{l}$x\\end{subarray}',
  );

  // 化学式 / 物理量：包完全不认识，降级成数学文本
  s = _replaceBraced(s, r'\ce', _chemText);
  s = _replaceBraced(s, r'\pu', _unitText);

  // 单位宏可能带一个或两个参数
  s = _replaceTwoArgs(
    s,
    r'\SI',
    (String a, String b) => '${_unitText(a)}\\,${_unitText(b)}',
  );
  s = _replaceTwoArgs(
    s,
    r'\qty',
    (String a, String b) => '${_unitText(a)}\\,${_unitText(b)}',
  );
  s = _replaceBraced(s, r'\unit', _unitText);
  s = _replaceBraced(s, r'\si', _unitText);
  s = _replaceBraced(s, r'\num', _unitText);
  s = _replaceBraced(s, r'\ang', (String x) => '${_unitText(x)}^\\circ');

  // ---- 6. 顶层对齐符 / 换行：没有环境包着就自己包一层 ----
  //
  // 模型很爱写 `a &= b \\ c &= d`（以为在 align 里）。
  // 这种写法在顶层会让解析器直接报错；`aligned` 正好接受它们。
  if (!s.contains(r'\begin{') && (s.contains('&') || s.contains(r'\\'))) {
    s = '\\begin{aligned}$s\\end{aligned}';
  }
  // 去掉宏替换留下的首尾空白 —— 保证「规整两遍」结果一致
  return s.trim();
}

/// 解析仍然失败时的"抢救"：把最容易惹事的符号降级掉。
///
/// 只在前一轮已经失败时使用 —— 所以宁可牺牲排版，也要让它显出图形。
String repairLatex(String src) {
  String s = normalizeLatex(src);
  // 环境对不齐、数组列数不对……都不管了，把结构符号换成空白
  s = s.replaceAll(RegExp(r'\\begin\{[^{}]*\}(?:\{[^{}]*\})?'), '');
  s = s.replaceAll(RegExp(r'\\end\{[^{}]*\}'), '');
  s = s.replaceAll(r'&', r'\quad ');
  s = s.replaceAll(r'\\', r'\quad ');
  s = s.replaceAll(RegExp(r'\\(?:hline|hdashline|cline\s*\{[^{}]*\})'), '');
  // 落单的上下标：`x^`、`x_` 结尾，解析器会报"缺参数"
  s = s.replaceAll(RegExp(r'[\^_]\s*$'), '');
  s = s.replaceAll(RegExp(r'[\^_]\s*([\\{}])'), r'\1');
  // 落单的 `\left` / `\right`
  s = s.replaceAll(RegExp(r'\\left\s*(?![\[\(\{.|\\])'), '');
  s = s.replaceAll(RegExp(r'\\right\s*(?![\]\)\}.|\\])'), '');
  return s.trim();
}

/// 渲染彻底失败时，输出人能读的公式文本。
///
/// 不追求排版，只求"看得懂"：`\frac{a}{b}` → `(a)/(b)`、
/// `\alpha` → `α`、`\sqrt{x}` → `√(x)`。
String latexToPlain(String src) {
  String s = normalizeLatex(src);

  s = _replaceTwoArgs(
    s,
    r'\frac',
    (String a, String b) => '(${latexToPlain(a)})/(${latexToPlain(b)})',
  );
  s = _replaceTwoArgs(
    s,
    r'\dfrac',
    (String a, String b) => '(${latexToPlain(a)})/(${latexToPlain(b)})',
  );
  s = _replaceTwoArgs(
    s,
    r'\tfrac',
    (String a, String b) => '(${latexToPlain(a)})/(${latexToPlain(b)})',
  );
  s = _replaceBraced(s, r'\sqrt', (String x) => '√(${latexToPlain(x)})');
  s = _replaceBraced(s, r'\text', latexToPlain);
  s = _replaceBraced(s, r'\mathrm', latexToPlain);
  s = _replaceBraced(s, r'\mathbf', latexToPlain);
  s = _replaceBraced(s, r'\mathit', latexToPlain);
  s = _replaceBraced(s, r'\operatorname', latexToPlain);

  // 希腊字母与常见符号
  for (final MapEntry<String, String> e in _plainSymbols.entries) {
    s = s.replaceAll(e.key, e.value);
  }
  // 剩下的结构符号
  s = s.replaceAll(RegExp(r'\\(?:left|right|big|Big|bigg|Bigg)[lrm]?\b'), '');
  s = s.replaceAll(RegExp(r'\\(?:quad|qquad|,|;|:|!|\s)'), ' ');
  s = s.replaceAll(r'\\', ' ');
  s = s.replaceAll('&', ' ');
  s = s.replaceAll(RegExp(r'\\[a-zA-Z]+'), ' '); // 未识别的命令：名字去掉
  s = s.replaceAll(RegExp(r'[{}]'), '');
  s = s.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  return s;
}

const Map<String, String> _plainSymbols = <String, String>{
  r'\alpha': 'α',
  r'\beta': 'β',
  r'\gamma': 'γ',
  r'\Gamma': 'Γ',
  r'\delta': 'δ',
  r'\Delta': 'Δ',
  r'\epsilon': 'ε',
  r'\varepsilon': 'ε',
  r'\zeta': 'ζ',
  r'\eta': 'η',
  r'\theta': 'θ',
  r'\Theta': 'Θ',
  r'\kappa': 'κ',
  r'\lambda': 'λ',
  r'\Lambda': 'Λ',
  r'\mu': 'μ',
  r'\nu': 'ν',
  r'\xi': 'ξ',
  r'\Xi': 'Ξ',
  r'\pi': 'π',
  r'\Pi': 'Π',
  r'\rho': 'ρ',
  r'\sigma': 'σ',
  r'\Sigma': 'Σ',
  r'\tau': 'τ',
  r'\upsilon': 'υ',
  r'\phi': 'φ',
  r'\varphi': 'φ',
  r'\Phi': 'Φ',
  r'\chi': 'χ',
  r'\psi': 'ψ',
  r'\Psi': 'Ψ',
  r'\omega': 'ω',
  r'\Omega': 'Ω',
  r'\infty': '∞',
  r'\pm': '±',
  r'\mp': '∓',
  r'\times': '×',
  r'\div': '÷',
  r'\cdot': '·',
  r'\leq': '≤',
  r'\le': '≤',
  r'\geq': '≥',
  r'\ge': '≥',
  r'\neq': '≠',
  r'\ne': '≠',
  r'\approx': '≈',
  r'\equiv': '≡',
  r'\sim': '~',
  r'\propto': '∝',
  r'\rightarrow': '→',
  r'\to': '→',
  r'\leftarrow': '←',
  r'\Rightarrow': '⇒',
  r'\Leftrightarrow': '⇔',
  r'\sum': '∑',
  r'\prod': '∏',
  r'\int': '∫',
  r'\oint': '∮',
  r'\partial': '∂',
  r'\nabla': '∇',
  r'\in': '∈',
  r'\notin': '∉',
  r'\subset': '⊂',
  r'\supset': '⊃',
  r'\cup': '∪',
  r'\cap': '∩',
  r'\forall': '∀',
  r'\exists': '∃',
  r'\angle': '∠',
  r'\triangle': '△',
  r'\circ': '°',
  r'\degree': '°',
  r'\ldots': '',
  r'\dots': '',
  r'\cdots': '⋯',
  r'\lt': '<',
  r'\gt': '>',
};

/// 化学式：`H2O` → `H_2O`，箭头换掉，再包进 `\mathrm`。
String _chemText(String inner) {
  String s = inner
      .replaceAll('<=>', r'\rightleftharpoons ')
      .replaceAll('->', r'\rightarrow ')
      .replaceAll('=>', r'\Rightarrow ');
  // 元素后面的数字变下标：H2O、CO2、Ca(OH)2
  s = s.replaceAllMapped(
    RegExp(r'([A-Za-z\)\]])(\d+)'),
    (Match m) => '${m.group(1)}_{${m.group(2)}}',
  );
  return '\\mathrm{$s}';
}

/// 单位里的数字/符号换个字体；带 `^` `_` 或命令的必须留在数学模式里。
///
/// `\text{m/s^2}` 会解析失败（文本模式不认 `^`），所以这里按内容选
/// `\mathrm`（数学模式）还是 `\text`（纯文本）。
String _unitText(String s) {
  final String t = s.trim();
  if (t.isEmpty) return '';
  if (RegExp(r'^[-+0-9.eE]+$').hasMatch(t)) return t;
  if (t.contains('^') || t.contains('_') || t.contains(r'\')) {
    return '\\mathrm{$t}';
  }
  return '\\text{$t}';
}

/// 把 `\cmd{...}` 里的花括号内容交给 [f]，支持嵌套花括号。
String _replaceBraced(
  String src,
  String command,
  String Function(String inner) f,
) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < src.length) {
    if (!src.startsWith(command, i)) {
      out.write(src[i]);
      i++;
      continue;
    }
    int j = i + command.length;
    // `\pu` 不能吃掉 `\purple`
    if (j < src.length && RegExp(r'[a-zA-Z]').hasMatch(src[j])) {
      out.write(src[i]);
      i++;
      continue;
    }
    while (j < src.length && (src[j] == ' ' || src[j] == '\n')) {
      j++;
    }
    if (j >= src.length || src[j] != '{') {
      out.write(src[i]);
      i++;
      continue;
    }
    final int close = _matchingBrace(src, j);
    if (close < 0) {
      out.write(src[i]);
      i++;
      continue;
    }
    out.write(f(src.substring(j + 1, close)));
    i = close + 1;
  }
  return out.toString();
}

/// 把 `\cmd{a}{b}` 的两个参数交给 [f]。
String _replaceTwoArgs(
  String src,
  String command,
  String Function(String a, String b) f,
) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < src.length) {
    if (!src.startsWith(command, i)) {
      out.write(src[i]);
      i++;
      continue;
    }
    int j = i + command.length;
    if (j < src.length && RegExp(r'[a-zA-Z]').hasMatch(src[j])) {
      out.write(src[i]);
      i++;
      continue;
    }
    while (j < src.length && (src[j] == ' ' || src[j] == '\n')) {
      j++;
    }
    if (j >= src.length || src[j] != '{') {
      out.write(src[i]);
      i++;
      continue;
    }
    final int close1 = _matchingBrace(src, j);
    if (close1 < 0) {
      out.write(src[i]);
      i++;
      continue;
    }
    int k = close1 + 1;
    while (k < src.length && (src[k] == ' ' || src[k] == '\n')) {
      k++;
    }
    if (k >= src.length || src[k] != '{') {
      out.write(src[i]);
      i++;
      continue;
    }
    final int close2 = _matchingBrace(src, k);
    if (close2 < 0) {
      out.write(src[i]);
      i++;
      continue;
    }
    out.write(f(src.substring(j + 1, close1), src.substring(k + 1, close2)));
    i = close2 + 1;
  }
  return out.toString();
}

/// 返回与 `open` 处 `{` 配对的 `}` 下标；找不到返回 -1。
int _matchingBrace(String src, int open) {
  int depth = 0;
  for (int i = open; i < src.length; i++) {
    final String ch = src[i];
    if (ch == r'\') {
      i++; // 跳过被转义的字符
      continue;
    }
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}
