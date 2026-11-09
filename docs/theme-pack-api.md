# 主题包接口规范

把聊天界面整体换成你自己写的 HTML，用 CSS 做外观、用 JS 做交互。
应用只负责三件事：**把消息推给你**、**把主题色推给你**、**接收你要发出的文本**。

> 适用范围：MindClaw 2.33.0 及以上。
> 选中主题包后，聊天界面从消息列表到输入框**全部**由你的页面负责；
> 选「应用默认界面」即回到原生渲染。

---

## 1. 主题包是什么

一个主题包就三样东西：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 应用生成，不可改（内置包是 `builtin`） |
| `name` | string | 列表里显示的名字 |
| `seed` | int | 主题色，ARGB 整数（如 `0xFF4F46E5`） |
| `html` | string | **整页** HTML，可含 `<style>` / `<script>` |
| `builtin` | bool | 内置示例包，不可删（可复制后改） |

### 存储位置与格式

```
<应用私有目录>/theme_packs.json
```

```json
{
  "activeId": "p1730000000000000",
  "packs": [
    { "id": "builtin", "name": "内置示例", "seed": -11316123,
      "html": "<!DOCTYPE html>…", "builtin": true }
  ]
}
```

- `activeId` 为空串 = 用应用默认界面。
- 一份 JSON 就是**完整备份**：导出这个文件发给别人，对方导回去即可用。
- 单个包 `html` 上限 **512 KB**。超出会被拒绝保存（不会静默截断 ——
  截断后的 HTML 会变成"少了半截脚本"的坏包，比拒绝更难排查）。
- `activeId` 指向的包被删掉时，自动退回默认界面。

---

## 2. 方向一：你 → 应用

### `callHandler('send', text)`

把一条消息发出去，等同用户点了发送。

```js
window.flutter_inappwebview.callHandler('send', '帮我查一下天气');
```

- 只有**这一个**上行通道。除此之外你的页面无法与外界通信（见 §5 沙箱）。
- 空字符串会被忽略。
- 发送后应用会照常跑完整流程：描述改进、工具确认、流式输出，
  结果通过 `onMessages` 推回来。

---

## 3. 方向二：应用 → 你

应用会在合适的时机调用你挂在 `window.App` 上的方法。
**你不需要自己声明它们**，只要实现即可；没实现的方法调用会被忽略。

### `onMessages(list, busy)`

全量推送当前会话。**每次都推完整列表**，你负责重建 DOM。

```js
window.App.onMessages = function (list, busy) { /* … */ };
```

| 参数 | 类型 | 说明 |
|---|---|---|
| `list` | array | 消息数组，见 §4 |
| `busy` | bool | 这一轮是否还在生成（true 时输入框应禁用） |

> 之所以全量推而不是增量：消息会被编辑、重新生成、工具状态更新、
> 中断回滚 —— 增量协议要为这些各自定义事件，出错时状态就永远修不回来。
> 全量推让"你的 DOM 一定等于应用的消息"。

### `onTheme(colors)`

推送一套**已经算好**的颜色。换主题色、切换深浅色时都会重调，
不需要刷新页面。

```js
window.App.onTheme = function (c) {
  const r = document.documentElement.style;
  r.setProperty('--primary', c.primary);
  r.setProperty('--text', c.text);
};
```

| key | 说明 |
|---|---|
| `primary` | 强调色（主按钮、选中态） |
| `onPrimary` | 压在 `primary` 上的文字色 |
| `surface` | 卡片/控件填充 |
| `page` | 页面底色 |
| `text` | 主文字 |
| `muted` | 次要文字 |
| `bubble` | 用户气泡底色 |

值都是 `#RRGGBB` 字符串，直接写进 CSS 变量即可。
**不要自己猜深浅** —— 应用会在深色模式下给一套更亮的，照用就行。

### `onSendResult(ok, errorText)`

发送失败时给个反馈。

```js
window.App.onSendResult = function (ok, err) { if (!ok) alert(err); };
```

### `setBusy(bool)`

`busy` 的单独版本。和 `onMessages` 里的 `busy` 等价，
方便你不想重绘整个列表时单独处理。

---

## 4. 消息对象

```ts
type Message = {
  role: 'user' | 'assistant';
  content: string;          // 可能很长，含换行
  pending: boolean;         // true = 还在流式生成
  error: string | null;     // 出错时的说明
  tools: Array<{
    name: string;           // 工具名，如 'python' / 'termux' / 'web'
    summary: string;        // 目前等于 name（保留字段，将来会给摘要）
    status: string;         // 见下表
  }>;
};
```

`tools[].status` 取值：

| 值 | 含义 |
|---|---|
| `awaitingConfirm` | 等用户确认 |
| `running` | 正在执行 |
| `success` | 成功 |
| `failed` | 执行出错 |
| `rejected` | 被用户拒绝或已停止 |

> `content` 是**纯文本 Markdown**（应用不做 HTML 渲染）。
> 想显示代码块/表格，自己解析或直接 `textContent` 原样显示。

---

## 5. 沙箱与限制

| 能力 | 是否允许 | 原因 |
|---|---|---|
| JS | ✅ | 这是功能定义 |
| 本地文件访问 | ❌ | `allowFileAccess = false`，页面不能翻本机 |
| 跨域请求 | ❌ | `allowUniversalAccessFromFileURLs = false` |
| `content://` 访问 | ❌ | `allowContentAccess = false` |
| 缩放 | ❌ | 固定视图，避免和原生手势打架 |
| 长按系统菜单 | ❌ | `disableContextMenu = true`，把交互留给你 |

**你的页面不能联网。** 需要外部信息时，通过 `App.send()` 让 agent 去取 ——
这样请求走的是应用的工具链（有确认、有记录），而不是绕过它。

### 你会失去什么

主题包接管的是**整页**，所以下面这些原生能力用不了：

- 长按消息的「引用 / 标记 / 重新生成 / 修改」
- 代码块、表格、图片的原生卡片渲染
- 工具调用行的折叠/展开细节
- 输入框的长按菜单、全屏编辑

这是"拿走控制权"的必然成本。

---

## 6. 最小可用例子

```html
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<style>
  :root { --page:#fff; --text:#111; --bubble:#e8e4ff; --primary:#4f46e5; }
  body { margin:0; height:100%; background:var(--page); color:var(--text);
         font:15px/1.6 -apple-system,"PingFang SC",sans-serif; }
  #list { height:100%; overflow-y:auto; padding:16px 14px 90px;
          display:flex; flex-direction:column; gap:10px; }
  .me { align-self:flex-end; background:var(--bubble);
        padding:10px 14px; border-radius:18px; max-width:82%; }
  .ai { max-width:88%; white-space:pre-wrap; }
  #bar { position:fixed; left:0; right:0; bottom:0; display:flex; gap:8px;
         padding:10px 12px calc(10px + env(safe-area-inset-bottom));
         background:var(--page); }
  #i { flex:1; padding:12px; border-radius:20px;
       border:1px solid #ddd; background:#fff; font:inherit; }
  #s { width:46px; height:46px; border:0; border-radius:50%;
       background:var(--primary); color:#fff; font-size:18px; }
</style></head>
<body>
<div id="list"></div>
<div id="bar"><textarea id="i" rows="1"></textarea><button id="s">↑</button></div>
<script>
const list = document.getElementById('list');
const input = document.getElementById('i');
const btn = document.getElementById('s');
let busy = false;

window.App = {
  onMessages(msgs, b) {
    busy = b; btn.disabled = b;
    list.innerHTML = '';
    for (const m of msgs) {
      const el = document.createElement('div');
      el.className = m.role === 'user' ? 'me' : 'ai';
      el.textContent = m.content || (m.pending ? '…' : '');
      list.appendChild(el);
    }
    list.scrollTop = list.scrollHeight;
  },
  onTheme(c) {
    const r = document.documentElement.style;
    r.setProperty('--page', c.page);
    r.setProperty('--text', c.text);
    r.setProperty('--bubble', c.bubble);
    r.setProperty('--primary', c.primary);
  },
};

function send() {
  const t = input.value.trim();
  if (!t || busy) return;
  input.value = '';
  window.flutter_inappwebview.callHandler('send', t);
}
btn.onclick = send;
input.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
});
</script>
</body></html>
```

---

## 7. 调试建议

| 现象 | 先查什么 |
|---|---|
| 一片白屏 | 右上角 **?** 旁边会弹错误提示；再看控制台报错（会转发成 snackbar） |
| 消息不出现 | 是否实现了 `window.App.onMessages`？名字大小写要对 |
| 发送没反应 | `callHandler('send', …)` 的 handler 名必须正好是 `send` |
| 颜色不跟着变 | 是否在 `onTheme` 里写了 CSS 变量？换主题色会重调，但**不会 reload 页面** |
| 换主题包后旧界面还在 | 应用会整页重载；如果仍不对，检查 `activeId` 是否保存成功 |

### 一个容易踩的坑

`onMessages` 是**全量**的。每次调用都意味着"这是当前全部消息"，
不要往列表里追加 —— 否则流式输出时会出现 N 条重复。
