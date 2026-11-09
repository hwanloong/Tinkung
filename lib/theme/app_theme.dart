import 'package:flutter/cupertino.dart'
    show CupertinoTextThemeData, CupertinoThemeData;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 字体。
///
/// ## **全部走系统默认字体**
///
/// | 用在哪 | 字体 |
/// |---|---|
/// | AI 正文（消息、思考、工具输出） | 系统默认无衬线（`sans-serif`） |
/// | 界面交互文字（按钮、标题、设置项…） | 系统默认无衬线（`sans-serif`） |
/// | 代码 / 命令 / 路径 | 系统等宽（`monospace`） |
///
/// ## 为什么不再打包 Noto Sans SC
///
/// 之前正文用的是打进 APK 的 `assets/fonts/NotoSansSC-SemiBold.otf`
/// （24.7 MB），理由是"中英文一套字形、长文阅读稳"。但它有两个实际代价：
///
///  · **APK 直接大 24.7 MB** —— 这几乎是包体里最大的一笔单项开支；
///  · 它和界面控件用的系统字体**不是同一套字形**，两者挨在一起时
///    （比如消息正文和它下面的「复制」按钮）笔画粗细、字面大小都对不齐，
///    看起来像两个应用拼起来的。
///
/// 系统字体本来就已经覆盖中文（各 ROM 内置 MiSans / HarmonyOS Sans /
/// Roboto），深色浅色都有对应字重，而且**整个界面只有一套字形**。
/// 这是 iOS 和绝大多数原生应用的做法：界面不该自带字体。
///
/// 代码仍然用等宽：对齐是代码可读性的前提，而系统字体族的
/// `monospace` 一定存在（各平台都映射到自己的等宽字体）。
class AppFonts {
  const AppFonts._();

  /// **AI 正文字体族**。
  ///
  /// 和界面文字**同一族** —— 这是这一版的关键：正文和控件不再是两套字形。
  /// 保留这个常量，是因为 10 处 `AppFonts.read(...)` 调用点都引用它；
  /// 把值换成 [uiFamily] 之后，那些调用点一行都不用动。
  static const String bodyFamily = uiFamily;

  /// 界面交互文字用的族名。
  ///
  /// 打包的 **Inter**（见 `pubspec.yaml` 的 `fonts:`）：四个静态字面
  /// 400/500/600/700，约 1.6 MB。拉丁字母、数字、标点都走它 ——
  /// 这一版的观感（紧凑的字距、清楚的数字）主要就来自它。
  ///
  /// ## 汉字不在这里，靠 `bodyFallback`
  ///
  /// Inter 的 cmap 里**没有 CJK**。中文、日文、韩文全部落到
  /// [bodyFallback] 的第一项 `sans-serif`，由系统解析成 Noto Sans CJK /
  /// 苹方 / MiSans。中英混排时两种字形会挨在一起 —— 这是自带拉丁字体
  /// 的必然代价，但 Inter 的 x-height 和主流中文字体接近，不会跳。
  ///
  /// **不要删掉兜底链**：删了中文就是一片空心方块。
  static const String uiFamily = 'Inter';

  /// 正文的兜底族名。
  ///
  /// 第一项 `sans-serif` 接住所有 Inter 没有的字形（中文、emoji 部分区段、
  /// 罕见符号）。顺序有意义：系统族名必须在**最后**当作总兜底。
  static const List<String> bodyFallback = <String>['sans-serif'];

  /// 代码用等宽族名。
  ///
  /// 直接写系统族名 `monospace`：Android 映射到 Droid Sans Mono / ROM 自带的
  /// 等宽字体，iOS 映射到 Menlo。不再写 `Consolas` —— 那是 Windows 字体，
  /// 真机上**根本不存在**，写了也只会多一层回退跳转。
  static const String mono = 'monospace';
  static const List<String> monoFallback = <String>['sans-serif'];

  /// 用户额外放大的倍数（设置里的滑杆）
  static double userScale = 1.0;

  /// 基础缩放 —— 这是"整体字号"的基准值。
  /// 最终倍率 = [baseScale] × [userScale]。
  ///
  /// 为什么不用 `MediaQuery.textScaler`：markdown 渲染走的是 `RichText`，
  /// 它**不会**响应 textScaler，结果是正文放大了、代码块和表格没放大，
  /// 排版反而更乱。在字体工厂里乘一次就没这个问题。
  ///
  /// 为什么是 1.0：这里曾经是 1.15，等于给所有字号悄悄加了 15%，
  /// 结果是正文 17.25px、标题 28.75px —— 比 iOS 自己的规格还大一档，
  /// 整屏看起来"字很大、很挤"。1.0 意味着**调用点写的数字就是实际像素**，
  /// 不用在心里做一次换算。想让字大一点是设置里那根滑杆的事。
  static const double baseScale = 1.0;

  /// 最终倍率
  static double get scale => baseScale * userScale;

  /// 全局**行距**倍率。`body()` / `code()` 收到的 `height` 会乘上它。
  ///
  /// 为什么不直接把各处调用点的 `height` 逐个调大：那些值是分布式的
  /// （1.2 / 1.4 / 1.5 / 1.55 / 1.6…），逐个改既容易漏，又会把
  /// "某处故意紧凑"的地方一起改掉 —— 而它们之间的**相对关系**
  /// （标题紧、正文松、注释更紧）本身是对的。
  ///
  /// 乘一个统一系数就只改"整体松紧"，不动那份关系：
  /// 想更宽松把这个数调大，想更紧凑就调小。
  ///
  /// **1.14**：正文 1.6 → 1.82。这主要是**为中文调的** ——
  /// 中文没有词间空格、段落又长，行距偏紧时整块看上去就是一片
  /// 密不透风的字；拉丁文靠词间空白还能喘口气，中文不行。
  static double lineHeight = 1.14;

  /// 正文 TextStyle 的统一构造。
  static TextStyle body({
    double size = 15,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double height = 1.6,
    double letterSpacing = 0.1,
  }) {
    return TextStyle(
      // `body()` 是**界面文字**的默认样式：按钮、标题、设置项、列表行…
      // 它用系统默认字体（`uiFamily` 为空 = 交给平台），这样应用看起来
      // 就是"这个系统上的应用"，不会因为自带字体而显得格格不入。
      //
      // **要读的内容**（AI 正文、思考、工具输出）请用 [read]。
      fontFamily: uiFamily.isEmpty ? null : uiFamily,
      fontFamilyFallback: bodyFallback,
      fontSize: size * scale,
      fontWeight: weight,
      // 行距统一乘全局系数，见 [lineHeight]
      height: height * lineHeight,
      color: color,
      letterSpacing: letterSpacing,
      // ---- 行距的**分配方式**：上下均分 ----
      //
      // Flutter 默认是 `proportional`：`height` 多出来的那部分空白，
      // 按字体自身的上升/下降度量比例分配。而中英混排字体的下降部
      // （留给 g/p/y 的尾巴）远小于上升部，于是**八成的多余空白落在
      // 字的上方** —— 结果是：每个用了 `height` 的文字，在它的行盒里
      // 都偏低一点点（实测 15px 正文约 2.5px）。
      //
      // 单看一处不明显，但整个应用有几百处带 `height` 的文字：
      // 气泡里的字偏低、输入框里的字偏低、列表行的标题偏低……
      // 用户的原话是「很多没有对齐的地方」—— 那不是几十个独立 bug，
      // 就是这一个。
      //
      // `even` 把多余空白上下各分一半，字形就真的坐进了行盒中央。
      // 行盒总高度不变，所以这一改**不会**改变任何布局高度，
      // 只是把字往上挪了一点 —— 这也是它安全的原因。
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  /// 代码块样式：系统等宽。
  ///
  /// 代码块**不参与行距调整**：等宽字体本来就是按固定行高排版的，
  /// 拉开行距只会让一屏少显示好几行，而代码的可读性靠的是对齐，
  /// 不是留白。所以这里乘的是 1.0（见 [codeLineHeight]）。
  static double codeLineHeight = 1.0;

  static TextStyle code({
    double size = 13,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double height = 1.6,
  }) {
    return TextStyle(
      fontFamily: mono,
      fontFamilyFallback: monoFallback,
      fontSize: size * scale,
      fontWeight: weight,
      height: height * codeLineHeight,
      color: color,
      letterSpacing: 0,
      // 同 [body]：上下均分。代码块里这尤其重要 —— 等宽字体
      // 的行盒本来就高，proportional 会让整块代码看起来往上挤。
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  /// **要读的内容**（AI 正文、思考、工具输出）用的样式。
  ///
  /// 和 [body] 现在是**同一套字体和同一份行距**（都走系统默认）——
  /// 两者刻意保持差异的只剩 `letterSpacing` 的调用点取值。
  ///
  /// 曾经这里指向打包的 Noto Sans SC，和界面文字是两套字形。那导致正文
  /// 和它下面的按钮、时间戳粗细对不齐，看起来像两段不同的文字拼在一起。
  ///
  /// 保留这个函数（而不是让调用点直接用 [body]）是为了让
  /// "这是给人读的内容"在代码里仍然可检索 —— 将来若要再给正文单独
  /// 换字体，改这一处就够。
  static TextStyle read({
    double size = 15,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double height = 1.6,
    double letterSpacing = 0.1,
  }) {
    return TextStyle(
      fontFamily: bodyFamily,
      fontFamilyFallback: bodyFallback,
      fontSize: size * scale,
      fontWeight: weight,
      height: height * lineHeight,
      color: color,
      letterSpacing: letterSpacing,
      leadingDistribution: TextLeadingDistribution.even,
    );
  }
}

/// 全局取色。
///
/// ## 这一版改成了 Material You
///
/// 从前这里是一套**固定的 iOS 语义色**（灰底白卡 + 固定系统蓝），而
/// [accent] 甚至被写成 `static const`。理由是"iOS 观感来自那份固定"。
/// 现在整个应用走 M3 的动态配色，所以改成：
///
/// · 表面色（页面底 / 卡片 / 描边 / 文字）**全部由 [AppSurface.fromScheme]
///   从当前 `ColorScheme` 推导**，也就是跟着种子色或系统壁纸走；
/// · 下面这几个强调色字段变成**可变的**，由 [AppTheme._build] 在构建主题时
///   按当下的 `ColorScheme` 赋值。
///
/// ### 为什么仍然保留 `AppColors.accent` 这种"全局静态"的写法
///
/// 全项目有 78 处直接写 `AppColors.accent`，其中不少在 build 之外
/// （回调、异步逻辑、工具层）——那些地方拿不到 `BuildContext`，
/// 改成 `Theme.of(context).colorScheme.primary` 要么做不到，要么得把
/// context 一路透传十几个文件。
///
/// 所以这里保留静态字段，但**不再是 const**：每次构建主题时刷新一遍。
/// 主题是单例式的（同一时刻只有一套生效），这个取舍是安全的。
/// 颜色变化时由 `MaterialApp` 重建整棵树，读到新值。
class AppColors {
  const AppColors._();

  /// 页面底色。**可变**，由 [AppTheme] 按当前配色方案赋值。
  ///
  /// 保留这个名字是因为 15 个页面在 Scaffold 上直接引用了它。
  static Color lightBg = const Color(0xFFF2F2F7);
  static Color darkBg = const Color(0xFF000000);

  /// 强调色 = M3 的 `primary`。
  static Color accent = defaultSeed;

  /// 品牌色：**Claude 的陶土橙**（`#D97757`）。
  ///
  /// ## 和上一版"系统蓝"的取舍
  ///
  /// 上一版特意收掉了橙色，理由是"给每个控件都上暖色 = 颜色太浓"。
  /// 那条判断本身没错，但它说的是**整套暖色板**（暖纸底 + 暖描边 +
  /// 暖投影）；现在结构色已经全部钉成中性灰，橙色只活在强调色这**一个**
  /// 位置上 —— 发送键、开关、选中行、链接。灰底 + 一处橙，和当初
  /// 灰底 + 一处蓝是同一种克制，只是换了个色相。
  ///
  /// ## 为什么是 `#D97757`
  ///
  /// 这是 Anthropic 自己用的那一支陶土橙：饱和度不高（HSL 约 34%），
  /// 压在白字上对比度 3.2:1 —— 图标和按钮够用，而不会像纯橙 `#FF9500`
  /// 那样在灰底上"跳"出来。亮度 0.286，仍然低于 [seed_color_test] 里
  /// 那条 `< 0.35` 的阈值（白字要压得住）。
  static const Color defaultSeed = Color(0xFFD97757);

  /// 深色模式下的强调色。
  ///
  /// `#E8916B`：同一支橙提亮一档。纯黑底上 `#D97757` 会显得发闷，
  /// 提亮之后仍然保持同一个色相（不是换成另一个颜色）。
  static const Color darkAccent = Color(0xFFE8916B);

  /// 深浅两套主题里的页面底。
  ///
  /// 浅色 **`#F2F2F7`**、深色 **纯黑 `#000000`** —— 都是 iOS 系统
  /// 设置页的底色。纯黑比"暖黑"更像系统：深色模式下 OLED 的黑就是黑，
  /// 卡片浮在上面才有"分层"的感觉，而不是一整块深灰板。
  static const Color lightPage = Color(0xFFF2F2F7);
  static const Color darkPage = Color(0xFF000000);

  /// 用户实际选中的种子色。
  ///
  /// 保留字段只为兼容旧调用点（`main.dart` 不再按设置写它）。
  static Color seed = defaultSeed;

  /// M3 的 `onPrimary` —— 压在 [accent] 上的文字/图标色。
  static Color onAccent = const Color(0xFFFFFFFF);

  /// 语义色 = iOS 的系统色。
  ///
  /// `#FF3B30`（红）/ `#34C759`（绿）/ `#FF9500`（橙）是 iOS 自己的
  /// systemRed / systemGreen / systemOrange。它们在这套灰阶界面上只在
  /// 出错、成功、警告三种状态里出现 —— 出现即意味着"这里真的有事"。
  static Color danger = const Color(0xFFFF3B30);
  static Color success = const Color(0xFF34C759);
  static Color warning = const Color(0xFFFF9500);

  /// 中性色：用于「无 Shizuku」这类「不是错误、只是缺失」的状态，
  /// 避免用红色吓唬用户以为应用坏了。
  static Color neutral = const Color(0xFF8E8E93);

  /// 「深入研究」的语义色。
  ///
  /// 跟着强调色走（现在是一支陶土橙）。单独留这个字段是因为它出现在
  /// 输入框上方的小标签里、字号更小，深色下需要比强调色再亮一档；
  /// 但它**不能是另一个色相** —— 全界面只允许一种彩色。
  static Color research = defaultSeed;

  /// 全屏看图的背景。**刻意不跟主题走** —— 看图时任何色调的背景
  /// 都会干扰对图片本身明暗的判断，而那个页面上唯一的目的是看清这张图。
  static const Color imageBg = Color(0xFF000000);

  /// 按一套配色方案刷新上面的字段。
  ///
  /// [dark] 决定强调色用哪一档 —— 同一个橙在深底上需要提亮，
  /// 否则和背景的对比度不够。
  static void applyScheme(ColorScheme scheme, {required bool dark}) {
    accent = dark ? darkAccent : defaultSeed;
    onAccent = const Color(0xFFFFFFFF);
    lightBg = dark ? darkPage : lightPage;
    darkBg = dark ? darkPage : lightPage;
    // iOS 深色模式下的系统色是同一支色提亮一档（不是换成另一个色相）。
    danger = dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);
    success = dark ? const Color(0xFF30D158) : const Color(0xFF34C759);
    warning = dark ? const Color(0xFFFF9F0A) : const Color(0xFFFF9500);
    neutral = dark ? const Color(0xFF8E8E93) : const Color(0xFF8E8E93);
    research = dark ? darkAccent : defaultSeed;
  }
}

/// 圆角刻度。
///
/// 统一成一套刻度：**要么明显不同，要么完全一致**，
/// 不要"差不多但不一样"。
///
/// 这一版是 **iOS 的克制圆角**：卡片 14（接近 iOS grouped 列表的
/// 10~14）、输入框 22、弹窗 20。上一版是 18 / 30 / 26 —— 那组数字
/// 让每张卡都像一颗药丸，小屏上堆几行就显得"软、挤"。
class AppRadius {
  const AppRadius._();

  /// 代码块、小色块
  static const double code = 10;

  /// 列表项、小输入框
  static const double field = 12;

  /// 普通卡片
  static const double card = 14;

  /// 弹窗、面板的顶部圆角
  static const double sheet = 20;

  /// 聊天输入框的圆角。
  ///
  /// **12**：两头的中间值。14 在 40 高的框上偏"胶囊"，10 又方得像
  /// 一块标签（用户的原话："圆角又太小了"）。12 刚好读成
  /// "一块圆润的圆角面板"——和描边、投影一起是浮起来的一小块。
  static const double input = 12;

  /// 全圆角（胶囊按钮、圆形图标按钮）
  static const double pill = 999;
}

/// 通过 ThemeExtension 下发「面 / 描边 / 代码底 / 次要文字」四组颜色，
/// 这样组件不必到处写 `isDark ? a : b`。
@immutable
class AppSurface extends ThemeExtension<AppSurface> {
  const AppSurface({
    required this.surface,
    required this.border,
    required this.codeBg,
    required this.chipBg,
    required this.text,
    required this.muted,
    required this.barBackground,
    required this.scrim,
    required this.isDark,
    required this.pageBg,
    required this.bubbleBg,
  });

  /// 是否暗色。
  ///
  /// **必须用这个字段判断明暗，不要再写 `s == AppSurface.dark`。**
  /// 颜色由配色方案推导（`fromScheme` 返回新实例），而 `AppSurface.dark`
  /// 是静态常量 —— 两者永远不相等，判断会恒为 false，暗色模式就整片变白。
  final bool isDark;

  /// 卡片底色 = M3 `surfaceContainerLow`
  final Color surface;

  /// 卡片描边（发丝线）= M3 `outlineVariant`
  final Color border;

  /// 代码块 / 输入框底色 = M3 `surfaceContainerHighest`
  final Color codeBg;

  /// **胶囊/片状控件的底色** = M3 `surfaceContainerHigh`。
  ///
  /// 比 [surface]（卡片）明显深一档，但又没到 [codeBg]（代码块）那么重。
  ///
  /// 为什么需要单独一档：模型选择器那种小胶囊如果和卡片同色，
  /// 在描边容器（输入框）里就"浮不起来"——看起来像一段说明文字，
  /// 而不是一个可以点的控件。用 `surfaceContainerHighest` 又太重，
  /// 在输入框里显得像一块补丁。
  final Color chipBg;

  /// 主文字 = M3 `onSurface`
  final Color text;

  /// 次要文字 = M3 `onSurfaceVariant`
  final Color muted;

  /// 导航栏 / 输入栏的底色（半透明，配合 BackdropFilter）
  final Color barBackground;

  /// 弹窗后面的遮罩 = M3 `scrim`
  final Color scrim;

  /// 页面底色 = M3 `surface`。
  ///
  /// 加这个字段是因为有 15 处 `Scaffold` 在直接引用
  /// `AppColors.lightBg / darkBg` —— 那条路绕过了 `ColorScheme` 和
  /// `AppSurface`，改成 M3 之后页面底会停在旧的固定灰/黑上，
  /// 而卡片已经是色调面，两者对不上。同一个信息从前有两个来源，
  /// 现在并到一个。
  final Color pageBg;

  /// **用户气泡的底色。**
  ///
  /// ## 为什么必须单独给一档，而不是复用 chipBg
  ///
  /// 复用 `chipBg`（= `surfaceContainerHigh` = `#EFEFF4`）时，气泡和
  /// 页面底（`#F2F2F7`）的差只有 **3/255** —— 屏幕上等于看不见，
  /// 那一行字就那么飘在空白里。实测出来的差值，不是估计。
  ///
  /// iOS 里对话气泡和页面底的真实关系是 systemGray5 `#E5E5EA`
  /// 配 `#F2F2F7`（差 13）：**够淡，但一眼看得出这是块气泡**。
  /// 这就是这个字段取的值。
  final Color bubbleBg;

  /// 亮色面：**iOS 系统设置页**。
  ///
  /// 三档灰阶，全部取自 iOS 自己：
  ///  · 页面底 `#F2F2F7`（systemGroupedBackground）
  ///  · 卡片 `#FFFFFF`（secondaryGroupedBackground）
  ///  · 代码/输入框 `#F2F2F7`、胶囊 `#EDEDF2`（systemGray6 / 5）
  ///
  /// 描边用 `#E5E5EA`（systemGray5）而不是 iOS 表格里那根 `#C6C6C8`：
  /// 那根线是为"一张长表格"设计的，卡片这种小面积上它太重，
  /// 整屏看起来就是一层层框线。
  static const AppSurface light = AppSurface(
    surface: Color(0xFFFFFFFF),
    border: Color(0xFFE5E5EA),
    codeBg: Color(0xFFF2F2F7),
    chipBg: Color(0xFFEDEDF2),
    text: Color(0xFF1C1C1E),
    muted: Color(0xFF8E8E93),
    barBackground: Color(0xE6F2F2F7),
    scrim: Color(0x66000000),
    isDark: false,
    pageBg: Color(0xFFF2F2F7),
    // 用户气泡 = systemGray5。和页面底差 9/255：淡，但一眼是块气泡。
    bubbleBg: Color(0xFFE9E9EB),
  );

  /// 暗色面：**深灰底 + 一档更亮的灰卡**。
  ///
  /// 之前是纯黑 `#000000`。参考图指的是**深灰**（`#1A1A1A` 那一档）：
  /// 纯黑在 OLED 上确实"黑得干净"，但整屏没有层次 —— 卡片、输入区、
  /// 气泡全都要靠描边才分得出来，读起来像一块挖了洞的黑板。
  ///
  /// 深灰底之后，只要**比底色亮一点点**就能分出层：气泡 `#2C2C2C`、
  /// 输入区 `#262626`、页面 `#1A1A1A`。这三档差得很小，但眼睛能"看"
  /// 到边界 —— 参考图里那种"一整块、但看得出分区"的感觉就是它。
  ///
  /// 描边也随之降到 `#333333`：深灰底上 `#38383A` 偏亮，会显出一圈明显
  /// 的框；参考图里的线几乎看不见。
  static const AppSurface dark = AppSurface(
    surface: Color(0xFF232323),
    border: Color(0xFF333333),
    codeBg: Color(0xFF262626),
    chipBg: Color(0xFF2C2C2C),
    text: Color(0xFFEDEDED),
    muted: Color(0xFF8A8A8A),
    barBackground: Color(0xF21A1A1A),
    scrim: Color(0x99000000),
    isDark: true,
    pageBg: Color(0xFF1A1A1A),
    // 用户气泡：比输入区再亮一档 —— 它是这一屏里**唯一**该"浮起来"的块。
    bubbleBg: Color(0xFF2E2E2E),
  );

  /// 从配色方案推导「面 / 描边 / 代码底 / 次要文字」。
  ///
  /// 这一版**不从 `ColorScheme` 推导表面色**：界面是固定的一套中性灰阶，
  /// 系统配色只用来给 M3 组件自己的语义（onPrimary 等）。
  /// 仍然保留这个工厂，是因为全项目 49 处 `AppSurface.of(context)` 都走它，
  /// 改签名要动几十个文件，而这里换实现只要动一处。
  ///
  /// 保留 [s] 参数只是为了将来若要做"跟随系统动态色"时有地方接。
  factory AppSurface.fromScheme(ColorScheme s, {required bool dark}) {
    final AppSurface base = dark ? AppSurface.dark : AppSurface.light;
    // 语义色跟着配色方案走（M3 的 error 等仍然来自系统），
    // 但**结构色不跟** —— 见上面的说明。
    return base.copyWith(scrim: s.scrim);
  }

  /// 页面底色。所有 `Scaffold(backgroundColor: …)` 都该用它。
  static Color pageBackgroundOf(BuildContext context) => of(context).pageBg;

  /// **表格格线**（Markdown 表格的行线 / 列线）用的颜色。
  ///
  /// 为什么不能直接复用 [border]：`border` 是"卡片描边"那一档
  /// （`outlineVariant`，浅色下 `#E4E4E8`），它在白底上的对比度只有
  /// **1.2:1** —— 画一条卡片边框刚好够"若有若无"，但表格格线是要
  /// **分隔内容**的，用同一个值就变成"表格没有线"。
  ///
  /// 所以按次要文字色降透明度算：浅色下约 `#B5B5B7`（≈2.1:1，能看清
  /// 但不抢正文），深色下自动跟着变亮。不新增字段，因为它是从
  /// [muted] 派生出来的纯函数 —— 多一个字段就多一处要同步的地方。
  Color get gridLine => muted.withValues(alpha: isDark ? 0.34 : 0.30);

  static AppSurface of(BuildContext context) {
    return Theme.of(context).extension<AppSurface>() ??
        (Theme.of(context).brightness == Brightness.dark ? dark : light);
  }

  @override
  AppSurface copyWith({
    Color? surface,
    Color? border,
    Color? codeBg,
    Color? chipBg,
    Color? text,
    Color? muted,
    Color? barBackground,
    Color? scrim,
    bool? isDark,
    Color? pageBg,
    Color? bubbleBg,
  }) {
    return AppSurface(
      surface: surface ?? this.surface,
      border: border ?? this.border,
      codeBg: codeBg ?? this.codeBg,
      chipBg: chipBg ?? this.chipBg,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      barBackground: barBackground ?? this.barBackground,
      scrim: scrim ?? this.scrim,
      isDark: isDark ?? this.isDark,
      pageBg: pageBg ?? this.pageBg,
      bubbleBg: bubbleBg ?? this.bubbleBg,
    );
  }

  @override
  AppSurface lerp(ThemeExtension<AppSurface>? other, double t) {
    if (other is! AppSurface) return this;
    return AppSurface(
      surface: Color.lerp(surface, other.surface, t)!,
      border: Color.lerp(border, other.border, t)!,
      codeBg: Color.lerp(codeBg, other.codeBg, t)!,
      chipBg: Color.lerp(chipBg, other.chipBg, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      barBackground: Color.lerp(barBackground, other.barBackground, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      isDark: t < 0.5 ? isDark : other.isDark,
      pageBg: Color.lerp(pageBg, other.pageBg, t)!,
      bubbleBg: Color.lerp(bubbleBg, other.bubbleBg, t)!,
    );
  }
}

/// 全局主题。暗色模式通过 [ThemeMode.system] 跟随系统。
class AppTheme {
  const AppTheme._();

  /// 沉浸式系统栏（亮色）：透明状态栏/导航栏 + 深色图标。
  ///
  /// 两个 `*ContrastEnforced: false` 很关键：Android 10+ 默认会给
  /// 透明导航栏自动加一层半透明遮罩，导致纯黑背景底部发灰、破坏沉浸感。
  static const SystemUiOverlayStyle lightSystemUi = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark, // Android：浅底用深色图标
    statusBarBrightness: Brightness.light, // iOS
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );

  /// 沉浸式系统栏（暗色）：透明 + 浅色图标。
  /// 不设这个的话，深色模式下状态栏图标是深色的，压在纯黑背景上几乎看不见。
  static const SystemUiOverlayStyle darkSystemUi = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );

  static SystemUiOverlayStyle systemUiFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkSystemUi : lightSystemUi;

  /// 亮色主题。
  ///
  /// [fromSystem] 是系统动态取色（Android 12+ 的壁纸取色）给的那套配色方案。
  /// 为 null 时用 [AppColors.defaultSeed] 推一套 —— 桌面端和
  /// Android 12 以下都会走这条路，所以"没有动态取色"也必须好看。
  ///
  /// （参数名不能用 `dynamic`：它在这个文件里同时是个内建类型名，
  /// `ThemeExtension<dynamic>` 会因此解析失败。）
  static ThemeData light({ColorScheme? fromSystem}) =>
      _build(Brightness.light, fromSystem: fromSystem);

  static ThemeData dark({ColorScheme? fromSystem}) =>
      _build(Brightness.dark, fromSystem: fromSystem);

  static ThemeData _build(Brightness brightness, {ColorScheme? fromSystem}) {
    final bool isDark = brightness == Brightness.dark;

    // 系统给了动态配色就用它，否则从种子色推。
    //
    // **这里不再覆盖 `primary` / `surface`。** 从前为了让强调色正好等于
    // `#007AFF`，把 `fromSeed` 推出来的 primary 又改回种子色本身 ——
    // 那正是"半套 Material You"：只有强调色跟着走，表面色是写死的 iOS 灰。
    // M3 的整套色调关系（primary 与 onPrimary 的对比度、
    // surfaceContainer 各档的明度阶梯）都建立在"不手工干预"之上。
    //
    // ---- 中性种子色必须走 monochrome ----
    //
    // 「纯灰白主题」实现不了，根源就在这里：`tonalSpot`（默认变体）会
    // 给每个色调**加上种子的色相**。而灰色的 HCT 色相是未定义的，
    // 算法回落到一个固定的冷色 —— 于是明明选了灰色，
    // 开关、选中项、chip 显示的还是**偏蓝**。
    //
    // 所以：种子色饱和度极低时（用户就是想要素色），
    // 换成 `monochrome` 变体 —— 它是 M3 专门为"无色"提供的方案，
    // 所有色调的 chroma 都是 0，出来的是真正的灰阶，不带任何色偏。
    // 有彩色种子仍然走 `tonalSpot`，那套观感更好。
    // ---- Android 16/17 风格：Material 3 Expressive ----
    //
    // 前面几轮做的是 iOS 中性风（表面固定灰阶、强调色近黑/系统蓝）。
    // 那套已经**推翻**，现在回到 Material 3 的彩色色调体系 ——
    // 这正是 Android 16 起系统界面的样子：表面带一点主题色的色相、
    // 大圆角、高饱和强调色。
    //
    // 关键差别在**表面怎么来**：
    //  · iOS 方案：手工写死 `#F2F2F7`，表面永远是中性灰；
    //  · M3 方案：`fromSeed` 从种子色推整套色调，`surface` 会带上
    //    种子的色相（紫蓝种子 → 表面是极淡的紫灰）。这就是
    //    "Material You / Expressive" 的辨识度所在，不是可选项。
    //
    // 变体用 `vibrant`：`tonalSpot`（默认）偏保守，`vibrant` 会把
    // 强调色的 chroma 拉高，接近 Android 16 里那种更"跳"的配色。
    // `monochrome` 那条分支删掉了 —— 它只为"纯灰白"服务，而现在
    // 要的就是有颜色。
    ColorScheme scheme =
        fromSystem ??
        ColorScheme.fromSeed(
          seedColor: AppColors.defaultSeed,
          brightness: brightness,
          dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
        );

    // ---- 结构色一律用固定灰阶，不从种子色推 ----
    //
    // `fromSeed` 推出来的 surface 会带一点种子的色相（蓝种子 → 表面是
    // 极淡的蓝灰）—— 那正是"界面到处泛着一点蓝"的来源，也是 iOS 风格
    // 最不该有的东西：**iOS 的表面是纯中性的，颜色只出现在控件上**。
    //
    // 所以结构色钉死在 [AppSurface] 上，只让 M3 自己的组件（对话框、
    // 导航栏、按钮）通过 ColorScheme 拿到同一份灰阶。
    //
    // 换句话说：ColorScheme 在这里不是"配色来源"，而是"把已经定好的
    // 颜色翻译给 Material 组件听的翻译层"。
    final AppSurface structure = AppSurface.fromScheme(scheme, dark: isDark);
    // **这里不能用 `AppColors.accent`**：它是全局静态，而 light / dark
    // 两份主题都会被构建 —— 读到的可能是另一份刚写进去的值。
    // 直接按当前明暗取字面量，两份主题各自确定。
    scheme = scheme.copyWith(
      primary: isDark ? AppColors.darkAccent : AppColors.defaultSeed,
      onPrimary: AppColors.onAccent,
      surface: structure.pageBg,
      onSurface: structure.text,
      onSurfaceVariant: structure.muted,
      outline: structure.border,
      outlineVariant: structure.border,
      surfaceContainerLowest: structure.pageBg,
      surfaceContainerLow: structure.pageBg,
      surfaceContainer: structure.surface,
      surfaceContainerHigh: structure.surface,
      surfaceContainerHighest: structure.codeBg,
      error: AppColors.danger,
    );

    // 把强调色/语义色刷新成当前配色方案的值。
    //
    // **必须在建 AppSurface 之前调用**，而且它改的是全局静态字段 ——
    // 全项目 78 处 `AppColors.accent` 靠这一步才跟着动态配色变。
    AppColors.applyScheme(scheme, dark: isDark);

    final AppSurface surface = AppSurface.fromScheme(scheme, dark: isDark);

    final ThemeData base = ThemeData(
      // **关掉 Material 3。** M3 就是 Material You：它的圆角族、
      // 状态层、surfaceTint 抬升、以及那套"每个组件都带主题色底色"
      // 的设计语言，和目标观感（iOS 的平面 + 细分隔线）是冲突的。
      //
      // 关掉之后组件退回 M2 的平面形态，再叠加下面那些 iOS 化的覆盖，
      // 出来的就是"灰白 + 细分隔线 + 无阴影"的样子。
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
    );

    // 关键：一次性把字体 fallback 应用到整套 textTheme，
    // 这样所有组件（含 Dialog / SnackBar / 按钮）都自动获得正确字体。
    //
    // **这里走系统默认字体**（`uiFamily` 为空 → `fontFamily: null`）：
    // 按钮、标题、设置项这些"界面交互文字"要像这个系统的应用，
    // 不该带上正文字体的字形。正文（`AppFonts.read`）才用 Noto。
    final TextTheme textTheme = base.textTheme.apply(
      fontFamily: AppFonts.uiFamily.isEmpty ? null : AppFonts.uiFamily,
      fontFamilyFallback: AppFonts.bodyFallback,
      bodyColor: surface.text,
      displayColor: surface.text,
    );

    return base.copyWith(
      textTheme: textTheme,
      // 让 Cupertino 系组件也用同一套字体。
      //
      // 它们读的是 `CupertinoTheme` 而不是 `ThemeData.textTheme`；
      // 不接这一根的话，个别 Cupertino 控件的文字会走默认字体 ——
      // 界面里就冒出几处字体不一样的地方。
      cupertinoOverrideTheme: CupertinoThemeData(
        brightness: brightness,
        textTheme: CupertinoTextThemeData(
          textStyle: AppFonts.body(size: 14, color: surface.text),
        ),
      ),
      extensions: <ThemeExtension<dynamic>>[surface],
      scaffoldBackgroundColor: surface.pageBg,
      canvasColor: surface.pageBg,
      // ---- 点击反馈 ----
      //
      // 这里一度把 `splashColor` 设成完全透明（想做出 iOS 那种"整块压暗、
      // 没有波纹"的手感）。结果是用户反馈「设置选项动画消失了」——
      // 因为设置、工具、列表这些可点卡片全靠那圈波纹表示"按到了"，
      // 只留一个 6% 的 highlight 在浅色底上几乎看不出来。
      //
      // 所以恢复波纹，但用**强调色**而不是黑白：它和 iOS 的高亮更像
      // （系统蓝色的一层薄光），而不是 Material 默认那种灰雾。
      highlightColor: scheme.primary.withValues(alpha: 0.10),
      splashColor: scheme.primary.withValues(alpha: 0.14),
      hoverColor: surface.text.withValues(alpha: 0.04),
      focusColor: scheme.primary.withValues(alpha: 0.12),
      appBarTheme: AppBarTheme(
        backgroundColor: surface.pageBg,
        foregroundColor: surface.text,
        // iOS 导航栏是纯色 + 一条发丝分隔线，没有 M3 的 surfaceTint 抬升
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: surface.text,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface.surface,
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        // iOS 的 alert 圆角是 14，不是 M3 的 28。28 在手机屏上显得"过圆"，
        // 而且会让并排的两个按钮看起来像贴纸。
        shape: RoundedRectangleBorder(
          // M3 的对话框圆角是 28。14 是 iOS alert 的规格，
          // 做 iOS 风时改过来的，现在要回去。
          borderRadius: BorderRadius.circular(AppRadius.sheet),
        ),
        titleTextStyle: textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: surface.text,
        ),
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: surface.text),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: surface.codeBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        hintStyle: AppFonts.body(size: 14.5, color: surface.muted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.28),
        selectionHandleColor: scheme.primary,
      ),
      listTileTheme: ListTileThemeData(
        textColor: surface.text,
        iconColor: surface.text,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      // 开关：交给 M3 的默认配色。
      //
      // 从前这里手工把打开态设成 iOS 的系统绿（"用户对它的绿色有肌肉记忆"）。
      // Material You 下开关就跟 `primary` 走 —— 这也正是 Android 用户
      // 在系统设置里看到的那个样子。
      // 卡片：iOS 是白底 + 无描边 + 极小阴影（或干脆没有阴影）。
      cardTheme: CardThemeData(
        color: surface.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        // 大按钮直接用主题色（而不是 `primaryContainer`）：
        // 容器色是**淡彩**，浮在页面上像是"一块没点亮的按钮"；
        // 而且它的色相来自种子色，用户选了灰色种子后仍会偏蓝。
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card + 4),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface.pageBg,
        // 选中项的胶囊**不取 `secondaryContainer`** —— 同 `chipBg` 的理由：
        // 那是种子色相推出来的彩度块，灰/蓝种子的机器上就是一片"莫名的蓝"。
        // 改成中性档 + 主题色极薄一层：看得出选中，但不会另起一种颜色。
        indicatorColor: Color.alphaBlend(
          scheme.primary.withValues(alpha: 0.14),
          surface.chipBg,
        ),
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(
          AppFonts.body(size: 12, weight: FontWeight.w600),
        ),
      ),

      // ================= iOS 化的组件主题 =================
      //
      // ## 为什么在主题里做，而不是一个个改调用点
      //
      // 全项目有 28 个 `FilledButton`、10 个 `Switch`、19 个 `Slider`。
      // 逐个换成 `CupertinoButton` / `CupertinoSwitch` / `CupertinoSlider`
      // 要改几十处、还要重接每一处的 onPressed 和尺寸，而**观感收益
      // 和主题级覆盖完全一样** —— 因为 iOS 与 Material 的差别主要就在
      // 形状、粗细、内边距这几项，不涉及行为。
      //
      // 所以在主题里一次调好，几十个调用点自动跟着变。

      // iOS 开关：轨道是强调色胶囊，滑块是**纯白圆**带轻微投影，
      // 没有描边。Material 的开关滑块是带 `onPrimary` 着色的方形，
      // 一眼就能看出不是 iOS。
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => const Color(0xFFFFFFFF),
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : (surface.isDark
                    // iOS 深色下的未选轨道 = `#3A3A3C`（systemGray4 深色档）
                    ? const Color(0xFF3A3A3C)
                    // 浅色下 = `#E5E5EA`（systemGray5）
                    : const Color(0xFFE5E5EA)),
        ),
        // 去掉描边：iOS 的轨道没有轮廓线
        trackOutlineColor: const WidgetStatePropertyAll<Color>(
          Color(0x00000000),
        ),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),

      // iOS 滑块：细轨道 + 白圆点。Material 的滑块是"轨道 + 竖线手柄"，
      // 而且 M3 会在拖动时鼓出一个值气泡 —— 那个气泡是最明显的 Material 签名。
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: surface.isDark
            ? const Color(0xFF3A3A3C)
            : const Color(0xFFE5E5EA),
        thumbColor: const Color(0xFFFFFFFF),
        // 白色滑块在浅色轨道上会"消失"，靠一圈淡描边把它托出来
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 11,
          elevation: 2,
          pressedElevation: 3,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
        overlayColor: scheme.primary.withValues(alpha: 0.10),
        showValueIndicator: ShowValueIndicator.never,
        valueIndicatorColor: scheme.primary,
      ),

      // iOS 主按钮：圆角矩形（不是胶囊）。iOS 的 filled 按钮半径大约
      // 是高度的 1/3 —— 用 AppRadius.field（12）配 46 高的按钮正好。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.field),
          ),
          textStyle: AppFonts.body(size: 15, weight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.field),
          ),
          textStyle: AppFonts.body(size: 15, weight: FontWeight.w600),
        ),
      ),
      // 纯文字按钮：iOS 里这类按钮**没有背景也没有胶囊**，只有文字。
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.field),
          ),
          textStyle: AppFonts.body(size: 15, weight: FontWeight.w600),
        ),
      ),

      // iOS 芯片：胶囊形、填充底色、**无边框**。
      // Material 的芯片带 1px 描边，那一圈线是它最容易辨认的特征之一。
      chipTheme: ChipThemeData(
        // 和 `AppSurface.chipBg` 同一个来源：**不取 secondaryContainer**。
        // 那是一个由种子色相推出来的彩度色块，会在这里单独冒出一片
        // 「说不清为什么是蓝的」底色。改为中性档 + 主题色极薄一层。
        backgroundColor: surface.chipBg,
        selectedColor: scheme.primary,
        secondarySelectedColor: scheme.primary,
        side: const BorderSide(color: Color(0x00000000)),
        labelStyle: AppFonts.body(size: 12.5, color: surface.text),
        secondaryLabelStyle: AppFonts.body(size: 12.5, color: scheme.onPrimary),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      ),

      // 分割线：iOS 是**发丝线**（1 物理像素），不是 1 逻辑像素。
      // 在高 DPI 屏上 `thickness: 1` 会画成 2~3 物理像素，明显比 iOS 粗。
      dividerTheme: DividerThemeData(
        color: surface.border,
        thickness: 0.5,
        space: 0.5,
      ),

      // 底部弹出面板：iOS 是圆角 + 抓条，没有 M3 的拖拽把手动画和阴影。
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface.surface,
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        modalElevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
      ),
    );
  }
}
