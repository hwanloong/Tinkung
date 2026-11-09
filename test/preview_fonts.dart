import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 预览出图用的字体加载。
///
/// ## 为什么单独一个文件
///
/// `ui_preview_test.dart` 和 `markdown_preview_test.dart` 都要加载字体，
/// 两份实现以前各写一遍（Times/宋体/Consolas 各一处）—— 换字体时改了
/// 一处忘了另一处，出图就悄悄变成空心方块。现在只有这一份。
///
/// ## 为什么"缺文件不报错"
///
/// 这些字体**不进仓库**（见 `.gitignore` 和 `assets/fonts/README.md`）：
/// San Francisco Display 是苹果的字体，Noto Sans CJK 有 17MB。
/// 所以"没准备字体"是克隆仓库后的**正常状态** —— 这时让预览测试
/// **跳过缺失的字体继续跑**，比直接抛异常有用得多：
/// 布局、间距、颜色照样能验证，只是字形是替身。

/// 加载 [family]，文件不存在时静默跳过。
///
/// 返回是否真的加载了。调用方可以据此决定要不要打印提示。
Future<bool> loadPreviewFont(String family, List<String> assets) async {
  final List<ByteData> loaded = <ByteData>[];
  for (final String asset in assets) {
    try {
      loaded.add(await rootBundle.load(asset));
    } catch (_) {
      // 这个字体没准备 —— 见库注释，这不是错误
      return false;
    }
  }

  final FontLoader loader = FontLoader(family);
  for (final ByteData data in loaded) {
    loader.addFont(Future<ByteData>.value(data));
  }
  await loader.load();
  return true;
}

/// 把预览出图需要的所有字体注册好。
///
/// 两类：
///  · **系统字体的替身** —— 真机上界面和正文都走 `sans-serif`（系统默认），
///    代码走 `monospace`，测试环境里没有真实字体，得各注册一份替身；
///  · **图标字体** `MaterialIcons` —— 不加载的话每个图标都是一个空方块，
///    而界面上到处是图标，出图就没法看了。
Future<void> loadPreviewFonts() async {
  // ---- `sans-serif`：真机上它映射到系统默认字体（MiSans / Roboto…）----
  //
  // 测试环境里**没有任何系统字体**，所有没注册的字符都会落到 Ahem
  // 占位字体（表现为一整块黑方块 —— 数字、英文路径、代码全都会中招）。
  //
  // 用 Noto 当**系统字体的替身**：它同时含完整拉丁与汉字，出图才能反映
  // 真机上的实际观感。早先这里用的是 `CJK-subset.ttf`，那个子集**只收
  // 汉字**，于是数字和英文全变方块 —— 这正是之前 golden 图里
  // 「电池: ████」的来源。
  //
  // 注意：真机**不再打包**这份字体（见 pubspec 的说明），
  // 它现在只服务于预览出图。
  await loadPreviewFont('sans-serif', <String>[
    'assets/fonts/NotoSansSC-SemiBold.otf',
  ]);

  // ---- `Inter`：真机上界面文字用的**打包字体**（见 pubspec 的 `fonts:`）----
  //
  // 只注册 400：`FontLoader` 不支持按字重注册多个文件（它只有 family
  // 一个维度），而 400 是界面绝大多数文字的字重。500/600 在出图里会由
  // 400 **合成**粗体 —— 比真机的静态字面糊一点，但布局、字距、行高
  // 都对得上，出图仍然能反映真实观感。
  await loadPreviewFont('Inter', <String>['assets/fonts/Inter-Regular.ttf']);

  // ---- `monospace`：代码块、行内代码、shell 命令 ----
  //
  // `AppFonts.mono` 现在就是系统族名 `monospace`，测试环境里同样没有，
  // 不注册的话这些地方会整片变成黑方块。
  await loadPreviewFont('monospace', <String>['assets/fonts/Mono.ttf']);

  await loadPreviewFont('MaterialIcons', <String>[
    'fonts/MaterialIcons-Regular.otf',
  ]);
}
