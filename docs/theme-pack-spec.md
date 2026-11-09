# 主题包规范 v1

> 适用版本：MindClaw **2.33.0+**  
> 2.33.1：`onState` / `fontScale` / `dark` / 附件与模型接口  
> 2.33.2：调用守卫、内置包自动迁移  
> 2.33.3：`mark` / `quote` / `onMentions`，以及推送性能（缓存 / 截断 / 自适应节流）  
> 2.34.0：剪贴板导入、`model` / `modelId` 分开  
> 2.34.1：`dark`/`fontScale` 改为真类型  
> 2.34.2：剪贴板 `paste`、双指缩放  
> 2.34.3：首帧底色写入 HTML（切换不再发白）、换包真正重载  
> 2.34.4：`image` / `images` / `open` —— 看图与打开文件  
> 2.35.0：页面改从 `file://` 加载（`about:blank` 不认本地子资源）；
> 推送前沿触发 + 合并而非叠加  
> 2.35.3：剥掉页面自带的 CSP、允许媒体自动播放  
> 2.36.0：图片白名单纳入**外部私有目录**、失败返回具体原因、页面端缓存 data URI
>
> 本文是**规范**：写主题包时按它做，行为就是确定的。文末有版本对照与调试清单。

---

## 0. 术语

| 词 | 含义 |
|---|---|
| 主题包（pack） | 一份自包含的个性化配置：名称 + 主题色 + 一整页 HTML |
| 宿主 | MindClaw 应用本体。它创建 WebView、注入数据、接收回调 |
| 页面 | 主题包里的 HTML 文档，跑在 WebView 中 |
| 桥 | 宿主与页面之间的双向调用通道 |

---

## 1. 作用域

主题包**只接管聊天界面**：消息列表、输入框、工具行、思考区，全部由页面绘制。

不接管的部分：

- 首页、抽屉、设置页、工具页等所有非聊天界面
- 顶栏（标题/返回/菜单）—— 仍由宿主绘制
- 系统的模型选择器、文件/图片选择器、确认框（页面只能**请求**打开）

> 全局强调色**会**被主题包影响，见 §6。

---

## 2. 数据结构

```ts
type ThemePack = {
  id: string;        // 宿主生成，形如 'p1730000000000000'；内置包固定为 'builtin'
  name: string;      // 显示名，非空
  seed: number;      // 主题色，ARGB 整数，如 0xFF4F46E5 = 4283416805
  html: string;      // 整页 HTML（含 <style> / <script>），上限 512 KB
  builtin: boolean;  // 内置示例包：不可删、不可改
};
```

### 存储

```
<应用私有目录>/theme_packs.json
```

```json
{
  "activeId": "p1730000000000000",
  "packs": [ { "id": "builtin", "name": "内置示例", "seed": -11316123,
               "html": "<!DOCTYPE html>…", "builtin": true } ]
}
```

规则：

1. `activeId` 为空串表示**使用应用默认界面**。
2. 一份 JSON 即完整备份；导入导出都按这个格式。
3. `html` 超过 **512 KB**（524288 字节）会被**拒绝保存**，不截断 ——
   截断后的 HTML 会变成"少了半截脚本"的坏包，比拒绝更难排查。
4. `activeId` 指向的包被删除时，自动回退到默认界面。
5. 内置包始终存在，用户删不掉（新手需要一份能跑的参考）。

---

## 3. 生命周期

```
宿主创建 WebView
  → 加载 pack.html（initialData，mimeType=text/html, utf-8）
  → onLoadStop
      → 调用 onTheme(colors)     一次
      → 调用 onState(state)      一次
      → 调用 onMessages(list, busy) 一次
  → 之后的变化按需推送（见 §5.4）
```

页面**不需要**在 `DOMContentLoaded` 时主动拉数据 —— 宿主保证加载完成后会推一次。
但如果你的脚本是在 `onLoadStop` 之后才定义 `window.App`，第一推会丢（见 §7 守卫规则）。

---

## 4. 桥：页面 → 宿主

统一走 `flutter_inappwebview` 的 handler：

```js
window.flutter_inappwebview.callHandler(名字, ...参数)
```

| handler | 参数 | 行为 |
|---|---|---|
| `send` | `text: string` | 发一条消息。空串忽略。走与用户点发送**完全相同**的流程（描述改进 → 工具确认 → 流式输出） |
| `stop` | — | 停止当前生成。**真的取消请求**，不只是 UI 变色 |
| `pickModel` | — | 打开宿主原生的模型选择器。选完通过 `onState.model` 回传 |
| `pickFile` | — | 打开系统文件选择器，选中后进入"待发附件" |
| `pickImage` | — | 打开系统图片选择器，同上 |
| `mark` | `{index, text, occurrence?, color?}` | 给第 `index` 条消息里的 `text` 打标记。`occurrence` 是它在该消息里第几次出现（从 0 起），`color` 见 §7.1 |
| `quote` | `{index, text}` | 引用第 `index` 条消息里的 `text`，下一次发送会带上它 |
| `paste` | — | 返回剪贴板文本（允许为空串） |
| `image` | `path` | 返回该本地图片的 `data:` URI；读不到返回 **`!` 开头的具体原因** |
| `images` | `text` | 解析 Markdown 里的图片，返回 JSON 字符串（见 §8.1） |
| `open` | `path` | 用系统/内置查看器打开文件。返回空串=成功，否则是错误说明 |

约束：

1. **只有这五个**上行通道。页面不能读文件、不能发网络请求（见 §8）。
2. `pickFile` / `pickImage` 选中的文件**不会**把内容交给页面 ——
   宿主只告诉你"挂了几个附件"（`onState.pendingAttachments`）。
   附件由宿主负责随消息发出。
3. `send` 的文本不会自动加入待发附件 —— 附件与文本是两条独立通道。
4. **@ 工具没有单独的 handler**：在 `send` 的文本里写 `@tool:<id>` 或
   `@plugin:<name>`，宿主在发送时会把它展开成上下文（和原生输入框同一套
   `MentionParser`）。再开一个 handler 会造成"两套 @ 语义"。
   可用的 id 由 `onMentions` 下发（§5.5）。

---

## 5. 桥：宿主 → 页面

宿主通过 `evaluateJavascript` 调用 `window.App` 上的方法。

### 5.1 调用守卫（重要）

宿主**每次都先检查方法是否存在**：

```js
(window.App && typeof window.App.onMessages === "function") && window.App.onMessages(...)
```

因此：

- 你可以只实现其中几个（例如只实现 `onMessages` 和 `onTheme`）。
- 未实现的方法被跳过，**不会报错**。
- 但实现时**必须是函数值**，写成属性（`window.App.onState = {...}`）会被跳过。

### 5.2 `onMessages(list, busy)`

```js
window.App.onMessages = function (list, busy) { /* … */ };
```

- `list` 是**当前会话的全部消息**，不是增量。
- `busy` 为 `true` 表示这一轮还在生成。

> 每次调用都代表"这就是全部"。**不要往列表里追加** ——
> 流式输出时每秒会推数次，追加会得到 N 条重复。

### 5.3 `onTheme(colors)`

```js
window.App.onTheme = function (c) { /* … */ };
```

| key | 类型 | 含义 |
|---|---|---|
| `primary` | `'#RRGGBB'` | 强调色（主按钮、选中态、链接） |
| `onPrimary` | `'#RRGGBB'` | 压在 `primary` 上的文字色 |
| `surface` | `'#RRGGBB'` | 卡片/控件填充 |
| `page` | `'#RRGGBB'` | 页面底色 |
| `text` | `'#RRGGBB'` | 主文字 |
| `muted` | `'#RRGGBB'` | 次要文字 |
| `bubble` | `'#RRGGBB'` | 用户气泡底色 |
| `dark` | `boolean` | 当前是否深色（**真布尔**，不是字符串） |
| `fontScale` | `number` | 全局字号缩放（设置里的「字号」） |

调用时机：页面加载完成、**系统深浅色切换**、**字号变化**。

要求：

1. 颜色值已是最终色，**不要自己再算深浅**。
2. 字号请乘到根字号上，例如
   `body { font: calc(15px * var(--fs))/1.65 sans-serif; }`，
   并在 `onTheme` 里 `setProperty('--fs', c.fontScale)`。

### 5.4 `onState(state)`

```js
window.App.onState = function (s) { /* … */ };
```

| key | 类型 | 含义 |
|---|---|---|
| `busy` | `boolean` | 这一轮是否在生成 |
| `model` | `string` | 当前模型名，未配置时为空串 |
| `canStop` | `boolean` | 是否可停止（= `busy`） |
| `pendingAttachments` | `number` | 待发附件条数 |

推送频率：与 `onMessages` 同步（同一节拍）。

> 与 `onMessages` 分开的理由：模型名/附件数变化不需要重绘整个消息列表，
> 而消息列表在流式时每秒要重绘数次。

### 5.5 `onMentions({tools, plugins})`

```js
window.App.onMentions = function (m) { /* 画 @ 选择器 */ };
```

```ts
{ tools:   Array<{ id: string; title: string; note: string }>,
  plugins: Array<{ id: string; title: string; note: string }> }
```

- `id` 就是 `@tool:<id>` 里用的那个标识；`note` 是工具备注的首行。
- 只给**元信息**，不给实现 —— 真正的展开在宿主发送时做。
- 推送时机：页面加载完成后一次。工具/插件增删后重新进页面才更新。

### 5.6 `onSendResult(ok, errorText)`

```js
window.App.onSendResult = function (ok, err) { /* … */ };
```

**当前版本预留，宿主尚未调用。** 实现它不会有副作用，但不要依赖它做唯一反馈。

### 5.7 推送节流与截断

宿主侧规则（页面据此设计）：

1. **指纹比对**：消息条数 + 最后一条的 `content.length` / `reasoning.length` /
   `pending` / `error` + `busy`。没变就完全不推。
2. **按消息缓存编码结果**：只有变化的那条重新 JSON 化，历史消息复用缓存。
3. **自适应节流**（间隔取决于上一次载荷大小）：

| 上次载荷 | 推送间隔 |
|---|---|
| < 16 KB | 120ms |
| 16–48 KB | 180ms |
| > 48 KB | 260ms |

4. **重字段截断**（超长会在尾部注明"已截断，共 N 字"）：

| 字段 | 上限 |
|---|---|
| `reasoning` | 4000 字 |
| `tools[].args` | 1200 字 |
| `tools[].output` | 1200 字 |

推论：页面会收到**近似连续**但非逐字的更新；不要假设每次推送只差一个字符，
也不要假设 `args`/`output` 是完整的（需要完整内容应让用户看原生界面）。

---

## 6. 全局强调色

激活一个主题包时，它的 `seed` 会写入 `settings.themeSeed`，
从而**重建整个应用配色**（原生界面与页面一起变）。

- 切回"应用默认界面"**不会**自动还原之前的颜色 ——
  想要固定颜色，用户可在设置里另选。
- `seed` 为 0 时跳过（视为不干预）。

---

## 7. 消息对象

```ts
type Message = {
  role: 'user' | 'assistant';
  content: string;      // Markdown **原文**，宿主不做 HTML 渲染
  reasoning: string;    // 思考过程（可能为空串）
  reasoningMs: number;  // 思考耗时（毫秒），0 表示未知/无
  pending: boolean;     // true = 该条仍在流式生成
  error: string | null; // 出错说明
  marks: Mark[];        // 标记（荧光笔）与引用锚点
  quote: { text: string; color: string } | null; // 本条自带的引用
  tools: Tool[];
};

type Mark = {
  text: string;       // 被标记的原文
  occurrence: number; // 在该消息里第几次出现（从 0 起）——不能省，
                      // 否则同一个字会全被标上
  color: string;      // 见 §7.1
  kind: 'mark' | 'quote';
};

type Tool = {
  name: string;    // 'python' / 'termux' / 'web' / 'file_op' …
  summary: string; // 目前等于 name（保留字段）
  status: 'awaitingConfirm' | 'running' | 'success' | 'failed' | 'rejected';
  args: string;    // 工具参数的原始 JSON 字符串
  output: string;  // 执行输出（未执行时为空串）
  error: boolean;  // 是否失败（便于加红）
};
```

### 7.1 标记颜色

| `color` | 含义 |
|---|---|
| `yellow` | 默认荧光笔 |
| `green` / `blue` / `pink` | 其它荧光笔色 |
| `quote` | 引用锚点（虚线）—— 由系统留出，不要手动用 |

渲染要求：

- `content` 是 Markdown 源文。想渲染就自己解析；不想就 `textContent` 原样显示。
  **不要**直接 `innerHTML = content` —— 那是把模型输出当 HTML 执行。
- `tools[].args` 是 JSON 字符串，展示前建议折叠。
- `pending` 与 `busy` 不一定同时为真：`busy` 是整轮，`pending` 是单条。

---

## 8. 沙箱与安全边界

WebView 设置（宿主侧固定，主题包不可改）：

| 设置 | 值 | 原因 |
|---|---|---|
| `javaScriptEnabled` | `true` | 这是功能定义 |
| `allowFileAccess` | `false` | 页面不能读本机文件 |
| `allowFileAccessFromFileURLs` | `false` | 同上 |
| `allowUniversalAccessFromFileURLs` | `false` | 禁止跨域 |
| `allowContentAccess` | `false` | 禁止 `content://` |
| `disableContextMenu` | `true` | 长按菜单留给页面自己 |
| `supportZoom` | `false` | 固定视图，避免与原生手势打架 |

因此：

1. **页面不能联网。** 需要外部信息时调 `send`，让 agent 去取 ——
   这样请求走应用的工具链（有确认、有记录），而不是绕过它。
2. **页面不能读文件。** 图片要么内联（data URI / 内联 SVG），
   要么由宿主在消息附件里提供。
3. **页面看到的数据只有 §5、§7 列出的那些。**

### 8.1 看图片、打开文件

页面**不能**直接读文件，但可以**显示图片**和**打开文件** —— 两者都由
宿主代做，读盘集中在一处并按白名单校验。

#### 显示图片

最省事的做法是让宿主解析正文里的 Markdown 图片：

```js
// 返回 [{ alt, src, remote: boolean, data: string }]
const imgs = await window.App.images(m.content);
for (const im of imgs) {
  const img = document.createElement('img');
  // 远程图直接给 url（WebView 能加载）；本地图给 data URI
  img.src = im.remote ? im.src : im.data;
  img.alt = im.alt;
  if (!im.data && !im.remote) img.alt = '（图片读取失败）';
  img.onclick = () => window.App.open(im.src);   // 点开看原图
  el.appendChild(img);
}
```

单张图也可以直接问：

```js
img.src = await window.App.image('/storage/emulated/0/DCIM/a.jpg');
```

为什么要转 data URI，而不是让页面写 `<img src="file://…">`：

- `allowFileAccess = false`，`file://` 子资源会被拒；
- 页面由 `initialData` 加载，源是 `about:blank`，`file://` 属于跨源；
- data URI 不涉及文件与跨源规则，**必定能显示**。

#### 打开文件

```js
const err = await window.App.open('/shared/report.pdf');
if (err) alert(err);
```

走的是原生「生成文件」卡片点一下同一条路（`PlatformFiles.open`）：
系统能打开什么就打开什么 —— 图片进查看器、PDF 进阅读器、文本进编辑器。
返回空串表示成功，否则是给用户看的错误说明（文件被清理、没有能打开它的应用等）。

#### 白名单与上限

```
内部私有目录     /data/user/0/<pkg>/files | cache
外部私有目录     /storage/emulated/0/Android/data/<pkg>/files   ← 附件在这里
                 （workDir = 外部私有目录/files/dsh，
                   附件 = workDir/attachments/）
相册 / 下载      /storage/emulated/0/DCIM | Pictures | Download
                 /sdcard/DCIM | Pictures | Download
```

另外，**当前待发附件里的每一个路径无条件放行** —— 用户主动选进来
给模型看的文件，页面预览它天经地义，不该被目录规则挡住。

> 外部私有目录是最容易漏的一档：它在 `/storage/emulated/0/Android/data/<pkg>`
> 下面，既不在内部私有目录里，也不是相册/下载。漏掉它，"附件图片
> 读不到"就会一直存在。

| 项 | 限制 | 超出时 |
|---|---|---|
| 单张图片 | 6 MB | `data`/返回值为空串 |
| 一条消息的图片数 | 24 张 | 多出的忽略 |
| MIME | 按扩展名推断 | png/jpg/webp/gif/svg/bmp，其余当 jpeg |

#### 读不到时返回什么

`App.image()` 失败**不再返回空串**，而是返回一句人以原文，`!` 开头：

| 返回值 | 含义 |
|---|---|
| `data:image/png;base64,…` | 成功 |
| `!文件不存在（可能已被清理）` | 路径对，但文件没了 |
| `!这个路径不在可读范围内` | 白名单没覆盖到 |
| `!图片 3.4 MB 超过 6 MB 上限` | 体积超限 |

页面**应当把 `!` 之后那半句显示出来** —— 三种话对应三个完全不同的
地方，一律吞掉的话，"看不到图"就永远只能靠猜。

```js
const d = await window.App.image(path);
if (d.startsWith('data:')) img.src = d;
else if (d.startsWith('!')) toast(d.slice(1));
```

#### 一定要在页面端缓存

```js
const picCache = new Map();
async function pictureFor(path) {
  const hit = picCache.get(path);
  if (hit) return hit;
  const d = await window.App.image(path);
  if (d.startsWith('data:')) picCache.set(path, d);
  return d;
}
```

不缓存的话，消息列表每次重绘都要重新跨桥要一遍 base64 ——
一张 2 MB 的图会产生几 MB 的字符串来回传，那是"滚一下卡一下"的
直接来源。

#### 媒体播放

`<audio>` / `<video>` / WebAudio **可用**。宿主已设：

```dart
mediaPlaybackRequiresUserGesture: false,
```

并且会**剥掉页面自带的 `Content-Security-Policy`**。模型写卡片时很爱
加 `<meta http-equiv="Content-Security-Policy" content="default-src 'none'">`，
看着安全，实际把页面自己的媒体请求全掐死，报 `Refused to load media …
violates … default-src none`。主题页是用户自己的内容，这条只帮倒忙。

注意：

- 路径先归一化再比前缀，`..` 骗不过去。
- `App.open` **不设**路径白名单：它要打开的正是消息里出现的那些路径，
  而 `PlatformFiles.open` 本身会按可分享范围判断。
- 音频地址可能带防盗链（Referer / Cookie），那种失败是 403 或
  `MEDIA_ELEMENT_ERROR`，和 CSP 无关 —— 看到这两种就别再查 CSP 了。

### 性能硬性要求

| 禁止 / 要求 | 原因 |
|---|---|
| ❌ `backdrop-filter: blur(...)` | Android WebView 上每帧重模糊整个可视区，滚动直接掉到十几帧 |
| ❌ 每次推送 `innerHTML = ''` 全量重建 | 每秒 8 次 × 几十条消息 = 每秒重建数百节点，滚动条位置还会被重置 |
| ✅ 条数不变时只更新最后一条的正文 | 消息只会追加或整条替换，不会从中间插入，这个判断是安全的 |
| ✅ 长列表用 `overflow-y: auto` + 固定容器高 | 避免整页撑高导致 WebView 布局抖动 |
| ✅ 大图 `loading="lazy"` / 内联 SVG | 解码大图会卡主线程 |

---

## 9. 会失去的原生能力

主题包接管整页，所以下列能力在页面里**没有**（页可以自己实现，但不会免费得到）：

- 长按消息的「引用 / 标记 / 重新生成 / 修改」
- 代码块、表格、图片的原生卡片渲染与横向滚动
- 工具调用行的折叠/展开细节（数据有，渲染要自己写）
- 输入框的长按菜单、全屏编辑
- 消息引用跳转、标记锚点

这是"拿走控制权"的必然成本。

---

## 10. 兼容性与迁移

| 版本 | 变化 | 向后兼容处理 |
|---|---|---|
| 2.33.0 | 首版：`onMessages` / `onTheme` / `send` | — |
| 2.33.1 | 新增 `onState`、`stop`、`pickModel`、`pickFile`、`pickImage`、`fontScale`、`dark`、工具 `args`/`output`/`error`、`reasoning` | 宿主调用前做 `typeof` 守卫，老页面不会报错 |
| 2.33.2 | 内置包自动迁移 | 内置包 HTML 中若无 `onState` 则重建；**用户自建包永不自动修改** |
| 2.33.3 | `mark` / `quote` / `onMentions`；推送性能（缓存 / 截断 / 自适应节流） | 老页面不受影响；重字段可能被截断，需要完整值请引导用户看原生界面 |
| 2.34.1 | `dark` / `fontScale` 改真类型 | `dark` 过去是字符串，`if (c.dark)` 恒为真 |
| 2.34.2 | `paste`、双指缩放 | 老页面不受影响 |
| 2.34.3 | 首帧底色、换包重载 | 解决"一切换就发白"与"换主题不生效" |
| 2.34.4 | `image` / `images` / `open` | 新增能力，老页面不需要改 |
| 2.35.0 | 页面从 `file://` 加载 | 本地图片才可读；`loadData` 会退回 `about:blank` |
| 2.35.3 | 剥 CSP、允许媒体 | 页面被自己的 CSP 掐住时不再报错 |
| 2.36.0 | 白名单含外部私有目录、`!` 错误、页面端缓存 | **老页面若把失败当空串处理，仍能工作**，只是看不到原因 |

**用户自建包永远不会被自动改写。** 新接口是否需要，由你决定要不要同步进自己的包。

---

## 11. 调试

| 症状 | 先查 |
|---|---|
| 一片白屏 | 宿主会弹错误提示（页面加载失败 / JS 报错 / 注入失败）。先看那条提示 |
| `window.App.xxx is not a function` | 你的页面没实现该回调。新版宿主会跳过，但老包建议同步 |
| 消息不出现 | 是否实现了 `onMessages`？**名字大小写敏感** |
| 发送没反应 | handler 名必须正好是 `send`，且参数是字符串 |
| 颜色不跟随深浅色 | 是否在 `onTheme` 里写了 CSS 变量？宿主会重调，但**不会 reload 页面** |
| 切号了也不变 | 同上 —— 字号也是通过 `onTheme.fontScale` 下发的 |
| 滚动卡 | 检查 `backdrop-filter`、阴影、每次推送是否全量重建 |
| 消息重复 | 你做了追加，而宿主推的是全量 |

宿主的错误上报来源：

1. `onReceivedError` —— 页面加载失败
2. `onConsoleMessage`（`ERROR` 级）—— 页面脚本报错
3. `evaluateJavascript` 抛异常 —— 注入失败

三类都会以一条悬浮提示呈现，不做静默。

---

## 12. 让 AI 帮你写

内置工具 `theme_pack` 支持：

| action | 说明 |
|---|---|
| `list` | 列出所有包与当前启用状态 |
| `read` | 读某个包的完整 HTML（**改之前必须先读**） |
| `create` | 新建（不给 `html` 时用内置模板） |
| `update` | 改（整段替换 `html`，不是打补丁） |
| `activate` | 启用；`id` 传空串 = 回默认界面 |
| `delete` | 删除（内置包不可删） |
| `docs` | 返回 §4–§8 的接口摘要 |

限制（模型本身也看不到渲染结果）：

- 它写不出"你以为的样子"，只能按本规范写 —— 写完需要用户切过去看。
- 它不能顺手优化你没让它改的包（必须显式 `read` 再 `update`）。
- 它改不了沙箱，加能力要改应用本身。

---

## 附：最小可用页面

```html
<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<style>
  :root { --page:#fff; --text:#111; --bubble:#e8e4ff; --primary:#4f46e5; --fs:1; }
  html,body{height:100%;margin:0}
  body{background:var(--page);color:var(--text);
       font:calc(15px * var(--fs))/1.65 -apple-system,"PingFang SC",sans-serif}
  #list{height:100%;overflow-y:auto;padding:16px 14px 90px;
        display:flex;flex-direction:column;gap:10px}
  .me{align-self:flex-end;background:var(--bubble);padding:10px 14px;
      border-radius:18px;max-width:82%;white-space:pre-wrap}
  .ai{max-width:88%;white-space:pre-wrap}
  #bar{position:fixed;left:0;right:0;bottom:0;display:flex;gap:8px;
       padding:10px 12px calc(10px + env(safe-area-inset-bottom));
       background:var(--page);border-top:1px solid rgba(0,0,0,.08)}
  #i{flex:1;padding:12px;border-radius:20px;border:1px solid #ddd;
     background:#fff;font:inherit}
  #s{width:46px;height:46px;border:0;border-radius:50%;
     background:var(--primary);color:#fff;font-size:18px}
</style></head>
<body>
<div id="list"></div>
<div id="bar"><textarea id="i" rows="1"></textarea><button id="s">↑</button></div>
<script>
const list=document.getElementById('list'), input=document.getElementById('i'),
      btn=document.getElementById('s');
let busy=false, lastLen=-1;

window.App={
  onMessages(msgs,b){
    busy=b; btn.disabled=b;
    // 条数没变就只更新最后一条（性能要求，见规范 §8）
    if(msgs.length===lastLen && msgs.length){
      const el=list.lastElementChild;
      if(el) el.textContent=msgs[msgs.length-1].content||'';
      list.scrollTop=list.scrollHeight; return;
    }
    lastLen=msgs.length; list.innerHTML='';
    for(const m of msgs){
      const el=document.createElement('div');
      el.className=m.role==='user'?'me':'ai';
      el.textContent=m.content||(m.pending?'…':'');
      list.appendChild(el);
    }
    list.scrollTop=list.scrollHeight;
  },
  onTheme(c){
    const r=document.documentElement.style;
    r.setProperty('--page',c.page); r.setProperty('--text',c.text);
    r.setProperty('--bubble',c.bubble); r.setProperty('--primary',c.primary);
    if(c.fontScale) r.setProperty('--fs',c.fontScale);
  },
  onState(s){ /* 可在这里显示模型名 / 附件数 */ },
};

function send(){
  const t=input.value.trim(); if(!t||busy) return;
  input.value='';
  window.flutter_inappwebview.callHandler('send',t);
}
btn.onclick=send;
input.addEventListener('keydown',e=>{
  if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();send();}
});
</script></body></html>
```
