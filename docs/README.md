# Tinkung 工程手册

这份文档写的是这个工程实际有什么、能做到哪一步、代码放在哪里。
产品介绍在 [README.md](../README.md)，依赖许可见 [THIRD-PARTY.md](../THIRD-PARTY.md)。

---

## 一、这是什么

Tinkung 是跑在 Android 手机上的 AI Agent，包名 `dsh_agent`，当前版本 3.0.0+1081。

它不是聊天客户端加一层壳，差别在工具：模型可以真的执行 shell 命令、管理应用、
读写文件、改系统设置、截屏、操作界面控件，也可以运行内置的 Python 写代码验证结果。
数据都留在本机，没有后端服务，唯一的网络流量是模型 API 和搜索。

启动最快路径只等三件事：设置、应用目录、应用锁。会话历史、插件、知识库索引
都在首帧之后才读。

---

## 二、能做什么

### 对话与模型

接的是任意 OpenAI 兼容接口，默认 DeepSeek。模型可以存成多条"档案"，
对话时从输入栏切换，每条档案能各自限定工具集。

支持流式输出、多轮、函数调用、思维链。思考强度分低 / 中 / 高三档，
对应输入栏模型名旁边那个图标（闪电 / 弯月 / 土星）。

发送前可以让另一个模型把用户那句话改写成更清晰的描述，这个过程在发送按钮
按下之后、真正请求之前完成，随时可以取消。

### 工具

当前注册 36 个工具，按能力分成几组：

系统操作（需要 Shizuku）：`run_shell`、`app_manage`、`file_op`、`system_settings`、`screen_capture`。

联网：`web`、`browser`、`read_image`。

本机数据：`notes`、`tasks`、`memory`、`rules`、`learn`、`varbank`、`recall`、`mark`。

运行环境：`python`（内置 CPython 3.13）、`termux`（Termux 或内置 Alpine）。

界面：`ui_tree`、`ui_action`、`draw_path`，走无障碍服务，可以读控件树、
点按钮、画路径。

文件编辑：`reader`、`writer`、`filesearch`、`geter`、`sheller`。
`writer` 是按段替换的，所以有"改之前必须先读"的硬约束，没读过就拒绝执行。

其他：`pc`（连电脑上的 `pc_agent.exe`）、`plan`（多步任务拆节点）、
`multibot`（子智能体）、`plugin`（让模型给自己加工具）、
`tool`（成套的做法按需读取）、`request_unlock`（危险操作请用户验证一次）、
`notify_user`（后台完成时提醒）、`chat_alarm`（在回复下面挂风险告示）、
`generate_image`、`mcp_admin` / `mcp`、`knowledge`、`interact`、`change_think`。

### 内容与数据

笔记支持文件夹、标签、搜索，有独立的编辑页，能写 Markdown 或纯文本。
任务是标题、详情、执行时间、完成状态。两者都能被模型直接读写。

记忆是模型自己判断该记什么，可开关、可逐条删，每轮对话自动带上。
自学习是模型给自己写的操作笔记，用户只能看和删。

知识库可以导入文档，切片后建索引，支持向量检索和重排，
前提是在设置里配了 embedding 和 rerank 服务。

会话可以导出成 JSON 打包，笔记、任务、规则、插件、设置一起带走。

### 界面

对话页输入框是毛玻璃：正文能滚到框下面并被打糊，但不会跑到框以外。
附件用统一的小卡片，待发和已发长得一样，多个水平排开。

设置是条目式的，没有卡片。侧边栏是 Tinkung 的形态，历史按置顶 / 今天 /
昨天 / 更早分组，当前会话用强调色标出。

强调色是 Claude 橙 `#D97757`，字体是 Inter（拉丁）+ 系统字体（中文）。

---

## 三、做不到什么

这一节是实测和读代码确认过的，不是免责声明。

**任务不会到点自动执行。** 有执行时间字段，也能排序和提醒，但没有接
`AlarmManager` 和前台定时服务。写"明天九点提醒我"只会被记下来，不会自己响。

**远程控制是空页面。** 手机在 NAT 后面没有公网地址，要远程连上必须有中转服务，
那是需要长期维护和付费的东西，这一版没做。

**只出 Android 包。** 仓库里没有 `ios/` 目录。Kotlin 那 17 个文件全是 Android 通道。

**搜索通道只剩两条能用的。** DeepSeek 官方的服务端 `web_search` 已被厂商关闭，
自建搜索服务因为没人部署已经从链路里删掉。现在能用的是 Tavily 免 key 通道
（实测可用）和内置浏览器抓百度；DuckDuckGo 在国内被墙，基本等于兜底失败。

**模型不支持图片时识图会降级。** 选 `deepseek-v4-pro` 这类不能接图的模型时，
图片走本地 OCR，能拿到文字，拿不到画面理解。

**APK 123.6 MB。** 内嵌的 CPython 3.13 加上科学计算和文档类 wheel 占了大头，
Chaquopy 在构建期把包固化进去，运行期没有 pip。想减只能删包。

**签名回退。** `android/key.properties` 存在时用项目密钥，不存在时退回调试签名；
调试密钥随机器变，换了签名的包装不上去。本机有这个文件，所以出的是正式签名包。

**导出默认不含 API Key。** 换设备要手填一次。

**中文靠系统字体。** Inter 没有 CJK 字形，中文由 `sans-serif` 兜底，
不同 ROM 的字形和字重会不一样，深色下的观感也跟着 ROM 走。

**远程 / 多窗口没有。** 只有单设备单窗口。横屏支持分栏，但那是同一台设备上的分栏。

---

## 四、环境与构建

工具链不在标准路径：

```
Flutter      D:\flutter\flutter_windows_3.47.4-stable\flutter
JDK 21       D:\pj2\.toolchain\jdk-21.0.2
Android SDK  D:\pj2\.toolchain\android-sdk
```

`android/local.properties` 已经指向这两处。

```bash
export PATH="/d/flutter/flutter_windows_3.47.4-stable/flutter/bin:$PATH"

flutter pub get
flutter analyze lib
flutter test
flutter build apk --release
```

版本是钉住的，升级前先看这几条：

| 组件 | 版本 | 原因 |
|---|---|---|
| AGP | 9.1.0 | 整条构建链按它验证；9 移除了旧的 proguard 默认文件接口 |
| Kotlin | 2.4.0 | `compilerOptions` 扩展依赖这个版本 |
| Chaquopy | 17.0.0 | 同时支持 AGP 9.0–9.2 和 settings.gradle 里的插件声明 |
| minSdk | 26 | 用到前台服务和 MediaProjection 的新行为 |
| ABI | arm64-v8a + x86_64 | Chaquopy 从 Python 3.12 起不支持 32 位 |

不要用 `splits` 出分架构包。AGP 9 默认启用 `android.newDsl=true`，`splits`
在这一层不被支持，会先报 `android{} is deprecated` 再连锁失败。只能用 `ndk.abiFilters`。

仓库镜像只配了阿里云，外加 `storage.googleapis.com/download.flutter.io`
（Flutter 引擎制品只在那里）。没列 `google()` 和 `mavenCentral()`，
因为当前网络下它们会握手超时，把 Gradle 卡在主线程上。

`flutter_inappwebview_android` 和 `jni_flutter` 是 vendored 或钉版本的，
前者的补丁在 `third_party/flutter_inappwebview_android/VENDORED.md`。
升级 `flutter_inappwebview_android` 时要重新打补丁。

---

## 五、代码在哪

```
lib/
├── main.dart                启动
├── ai/                      AgentRunner 主循环、API 客户端、改写、联想
├── core/                    52 个文件：模型、存储、平台适配
├── tools/                   38 个文件，36 个已注册工具
├── ui/                      51 个文件：页面和组件
├── theme/                   字体、颜色、圆角、AppSurface
├── cwt/                     思维重写 + Office/PDF 预览
├── interaction/             互动面板（内嵌 WebView）
├── knowledge/               文档解析、切片、向量、检索
├── mcp/                     MCP 客户端与配置
├── plugins/                 自定义插件
└── shizuku/                 Shizuku 封装
```

`lib/` 下共 164 个 Dart 文件。最大的是 `ui/chat_page.dart`（292 KB），
其次是 `tools/web_session.dart`、`ai/agent.dart`、`ui/settings_sheet.dart`。

原生侧 17 个 Kotlin 文件在 `android/app/src/main/kotlin/com/dsh/dsh_agent/`，
主要的几个是 `MainActivity.kt`（通道注册）、`ShizukuBridge.kt`（执行命令）、
`AgentAccessibilityService.kt`（无障碍）、`LinuxRuntime.kt`（proot + Alpine）、
`SpeechBridge.kt`（语音）。

---

## 六、数据存在哪

设置走 `SharedPreferences`，其余全是应用文档目录下的文件：

| 内容 | 位置 |
|---|---|
| 会话 | `docs/conversations.json` |
| 笔记 / 任务 | `docs/notes.json` / `docs/tasks.json` |
| 规则 / 记忆 / 学习 | `docs/rules.json` / `memory.json` / `learning.json` |
| MCP / 变量库 / Agent.md | `docs/mcp_servers.json` / `varbank.json` / `Agent.md` |
| 应用锁 | `docs/lock.json` |
| 知识库索引 | `docs/knowledge/` |
| 工具目录 | `docs/tools/`，首次启动从 assets 铺开 |
| 工作目录 | 外部存储或应用支持目录下的 `/dsh`，可在设置里改 |

设置类是"可变字段 + `update()`"，写入统一这样包：

```dart
await settings.update(() => settings.reasoningEffort = 'high');
```

加新字段时一律带默认值，类型变了要写迁移分支，并且新旧 key 都写一遍，
这样回滚旧版本也读不出脏值。压缩模式就是这么做从 `bool` 变成三档 `String` 的。

会话历史不参与首帧加载。`ConversationStore.load()` 在后台 isolate 里解析，
聊到几千条消息时会话文件是几 MB，解析完才通知界面。

---

## 七、工具系统的组织

一个工具就是一个 `AgentTool` 子类：

```dart
abstract class AgentTool {
  String get name;                       // 模型看到的函数名
  String get title;                      // 人看到的中文名
  String get description;                // 给模型看的说明
  Map<String, dynamic> get parameters;   // JSON Schema
  RiskAssessment riskFor(Map<String, dynamic> args);
  bool get autoApprove => false;
  Future<String> run(ToolContext ctx, Map<String, dynamic> args);
  Duration get timeout => const Duration(minutes: 10);
}
```

`timeout` 是兜底，不是给慢工具调时间的开关。任何一次调用卡住，主循环就停在
`await` 上，用户看到的是转圈，停止按钮也掐不掉。需要跑更久的工具自己覆盖它。

工具表在 `ChatPage._buildRegistry()` 里组装，每场对话一份。注册分三类：

依赖 Shizuku 的五个只在 `shizuku.ready` 时注册，否则模型会反复调用、
拿到一堆"无法执行"，白白浪费轮次。

依赖别的东西但能给出下一步的（无障碍、Python、Linux、生图、电脑）一律无条件注册。
它们不可用时会自己返回一句可操作的提示，比如"去设置里点一下安装"。
工具不在表里的时候，模型只会说"我没有这个能力"，用户不知道真正的原因。

纯本地的（`open_file`、`get_location`、`web`、`browser`）无条件注册。

风险等级和是否跳过确认是两件事。`riskFor` 决定颜色、日志和工具卡片上的标记，
`autoApprove` 决定要不要让用户点一下。设置里的"自动放行安全操作"只关后者，
前者照实报，否则工具行上的红点会变成绿的，用户就看不出来刚才那条命令删了东西。

---

## 八、一轮对话怎么走

每发一条消息新建一个 `AgentRunner`：

```
组装系统提示词（Agent.md → 规则 → 记忆 → 学习 → 计划树 → 工具说明）
  ↓
buildApiMessages() 处理压缩
  ↓
DeepSeekClient 流式请求
  ↓
有 tool_calls？
  ├ 有 → 逐个校验参数 → 风险确认 → 执行（带 timeout）→ 结果写回 → 下一轮
  └ 没有 → 结束，落盘
```

几条硬约束写在这里，改主循环时别绕开：

调用失败过的同一条请求，在本次任务里第二次出现会直接短路。模型卡住时的典型表现
就是原样重发同一个调用。

写文件前必须读过。`writer` 是按"找一段换一段"改的，没读过就写等于让模型
凭记忆覆盖用户的东西。`create: true` 新建的文件、本次任务里读过的文件放行。

停止按钮先置标志再断连接。反过来的话中间有一段窗口，后续代码仍然以为自己在跑，
表现出来就是"按了停止，命令还在执行"。

带 `tools` 的请求里，历史轮次的 `reasoning_content` 必须完整回传，否则接口返回 400。
所以思维链要跟会话一起存，不能当成展示用的临时数据。

`usage` 在最后一个 chunk 里，而那个 chunk 的 `choices` 通常是空数组，
取法要在判断 `choices.isEmpty` 之前。

请求体的图片只能出现在 user 消息里，放进 system 或 assistant 会 400。

模型被要求改完工程后把成品放进工作目录、清掉中间文件（`.bak`、`_v2`、`draft`、
`tmp`、分片），但不删用户文件，也不删已经交付的东西，拿不准就问。
这条约束写在提示词里，代码层面没有强制。

---

## 九、上下文压缩

设置里三档：

`每轮压缩` 是原来的逻辑，每次请求前都压一遍较早的工具输出，最省 token，
代价是模型回看旧输出时看到的已经是摘要。

`80% 压缩` 在上下文用量到上限的 80% 时才开始压，宽裕时给模型完整原文。

`不压缩` 原样发送，需要模型精确回看某段工具原文时用，代价是更容易撞上限。

决策在调用 `buildApiMessages` 的地方：

```dart
compressContext:
    settings.compressMode == 'every' ||
    (settings.compressMode == 'ratio' &&
        (AppMetrics.instance.contextRatio ?? 1) >= 0.8) ||
    (settings.compressMode == 'ratio' &&
        AppMetrics.instance.contextRatio == null),
keepTurns: settings.compressKeepTurns,
```

新会话还没有服务端用量时拿不到比例，这时按压缩处理，宁可保守。
`compressKeepTurns` 是保留最近几轮完整工具输出，值为几就留几轮。

---

## 十、界面约定

主题相关的四个东西都在 `lib/theme/app_theme.dart`。

`AppFonts` 提供 `body()`、`read()`、`code()` 三个工厂，最终倍率是
`baseScale × userScale`，行距再乘 `lineHeight = 1.14`。中文靠
`bodyFallback` 里的 `sans-serif` 兜底，这条链不能删，删了中文是空心方块。

不用 `MediaQuery.textScaler` 做整体缩放，因为 Markdown 渲染走的 `RichText`
不响应它，结果是正文变了、代码块没变。缩放系数在字体工厂里乘一次，全篇统一。

`AppColors` 是可变的静态量，`applyScheme()` 在构建主题时写入强调色。
注意 `theme` 和 `darkTheme` 两份都会构建，而后者在后，所以 `main.dart` 在
`builder` 里按当前亮度又写了一次。少这一步，浅色界面里的图标会用深色那套值。

`AppSurface` 是 `ThemeExtension`，提供 `pageBg`、`surface`、`chipBg`、`border`、
`text`、`muted`、`bubbleBg`、`isDark`。新写组件时从它取色，不要硬编码。

输入框的形状：

外框是 1px `s.border` 描边加一层很轻的投影，里面是 `ClipRRect` →
`BackdropFilter(sigma 20)` → 半透明填充。高度恒等于 36，靠
`contentPadding` 的上下留白算出来，外层不再补余量。居中用
`textAlignVertical: center`，行距用 `leadingDistribution: even`，
否则多出来的 leading 会堆在字上面，汉字看起来偏下。

`maxLines: 5`，超出的部分靠输入框内部滚动。这里有个容易漏的点：
`EditableText` 只在用户输入时把光标滚进视野，代码里往输入框塞字（引用片段、
语音结果、放回消息、展开变量库、取消发送还原）之后不会自动滚。
这些地方写完都要调一次 `_revealInputCaret()`，否则内容有几屏、显示却停在开头几行。

超过 2000 字会自动存进变量库，输入框里换成一个占位标记，发送时带上引用。

消息气泡：用户侧是浅填充圆角块，没有描边；AI 侧是 Markdown 渲染，
公式走 `flutter_math_fork`。附件用 `AttachmentChip`，28×28 缩略图加文件名，
多个水平排开。工具调用默认折叠，`chat_alarm` 不折叠，单独渲染成左侧带色条的告示。

设置页全是条目，不用卡片。侧边栏顶部是 Tinkung 品牌名，下面是新建对话胶囊、
三个入口行，再下面是历史分组。

---

## 十一、测试

```bash
flutter test
flutter test test/ui_preview_test.dart --update-goldens
flutter test test/markdown_preview_test.dart --update-goldens
```

当前 81 个测试文件、717 项测试、39 张预览图，产物在 `test/goldens/`。

预览图是用真实控件渲染的，走的是 `flutter_test` 的渲染管线，不是 HTML 模拟稿。
字体必须显式注册（`test/preview_fonts.dart`），测试环境里没有系统字体，
不注册的话中文和图标都是黑方块；公式的族名带包名前缀
（`packages/flutter_math_fork/KaTeX_Main`），注册成裸名匹配不上。

预览图能证明布局和颜色，证明不了玻璃的观感。`flutter_test` 不跑真 shader 路径，
液态玻璃在测试里正常、真机上可能发白，这部分只能看真机。

跑测试时会重建整个 widget 树，所以临时探针文件（`test/tmp_*_test.dart`、
`test/tmp_probe/`）用完就删，别混进去。

---

## 十二、怎么加东西

### 加一个工具

在 `lib/tools/` 新建文件，写一个 `AgentTool` 子类，参数用 JSON Schema 描述，
`riskFor` 按实际操作给出等级。然后在 `ChatPage._buildRegistry()` 里注册，
按前面第七节的三类判断该不该带条件。

如果界面要特殊展示，再去 `ui/widgets.dart` 加分支；纯文本结果的工具不用改界面。

补三个测试：参数校验、风险分级、输出格式。

### 加一个设置项

`lib/core/store.dart` 加字段，`load()` 里带默认值和迁移，`save()` 里写盘。
界面在 `lib/ui/settings_sheet.dart`，用 `_SettingRow`、`_switchRow`、
`_stepperRow` 现成的行，写入用 `await settings.update(...)` 包住。

### 加一个页面

`lib/ui/` 下新建文件，取色走 `AppSurface.of(context)`。如果是设置类页面，
先看 `settings_sheet.dart` 的行写法，别又用回卡片。

### 改界面之后

跑 `flutter analyze lib`，动了 `chat_page.dart`、`widgets.dart` 或主题的，
重新出预览图并过一遍全量测试。

---

## 十三、想找什么

| 想找 | 去 |
|---|---|
| 系统提示词 | `lib/ai/agent.dart`，搜「系统提示词」 |
| 工具注册 | `lib/ui/chat_page.dart` 的 `_buildRegistry()` |
| 设置字段 | `lib/core/store.dart` 的 `Settings` |
| 颜色 / 圆角 / 字体 | `lib/theme/app_theme.dart` |
| 消息气泡 / 工具卡片 / 附件 | `lib/ui/widgets.dart` |
| 输入框布局 | `lib/ui/chat_page.dart` 的 `_inputField()` 和 `_composerGlass()` |
| 上下文压缩 | `lib/ai/agent.dart` 的 `buildApiMessages()` |
| 原生通道 | `android/app/src/main/kotlin/com/dsh/dsh_agent/MainActivity.kt` |
| 界面预览图 | `test/goldens/` |
