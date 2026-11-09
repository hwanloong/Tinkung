# Tinkung 架构图

三张图：运行时分层栈、一轮对话的时序、工程模块全景。
所有节点都能在仓库里找到对应文件，模块职责见 [工程手册](README.md)。

---

## 一、运行时分层栈

从用户点下发送，到命令真的在手机上执行，中间经过六层。
每一层只依赖下一层，跨层调用只有一处例外：界面直接读存储（列表、设置回显）。

```mermaid
flowchart TB
    subgraph L1["① 界面层 · lib/ui"]
        UI1["对话页<br/>chat_page.dart"]
        UI2["设置 / 模型 / 工具页<br/>settings_sheet.dart 等"]
        UI3["消息与组件<br/>widgets.dart · markdown.dart"]
        UI4["侧边栏 / 外壳<br/>app_drawer.dart · home_shell.dart"]
    end

    subgraph L2["② 状态与存储层 · lib/core"]
        S1["Settings<br/>SharedPreferences"]
        S2["ConversationStore<br/>conversations.json"]
        S3["笔记 / 任务 / 规则 / 记忆<br/>learning / varbank / Agent.md"]
        S4["Metrics<br/>token 与上下文占用"]
    end

    subgraph L3["③ Agent 层 · lib/ai"]
        A1["AgentRunner<br/>主循环 · 校验 · 确认 · 中止"]
        A2["buildApiMessages<br/>压缩 · 附件 · 引用 · 变量展开"]
        A3["DeepSeekClient<br/>SSE 流式 · tool_calls 分片"]
        A4["系统提示词<br/>Agent.md > 规则 > 记忆 > 学习"]
    end

    subgraph L4["④ 工具层 · lib/tools"]
        T1["ToolRegistry<br/>36 个工具"]
        T2["RiskClassifier<br/>风险分级 + 确认"]
        T3["各工具实现<br/>shell / 文件 / 浏览器 / python …"]
    end

    subgraph L5["⑤ 原生桥 · Kotlin 17 个文件"]
        N1["ShizukuBridge<br/>shell 权限"]
        N2["A11yBridge<br/>无障碍控件树"]
        N3["LinuxRuntime<br/>proot + Alpine"]
        N4["Termux / Python / Web<br/>Speech / Pdf / Lock / Overlay"]
    end

    subgraph L6["⑥ 系统与服务"]
        O1["Android 系统<br/>包管理 / 设置 / 截屏"]
        O2["外部进程<br/>Termux · pc_agent.exe"]
        O3["模型 API<br/>OpenAI 兼容接口"]
        O4["搜索与抓取<br/>Tavily · 内置浏览器"]
    end

    UI1 --> A1
    UI2 --> S1
    UI3 --> UI1
    UI4 --> S2
    UI1 --> S2
    UI2 --> S3
    A1 --> A2
    A1 --> A3
    A1 --> A4
    A2 --> S2
    A1 --> S4
    A3 --> O3
    A1 --> T1
    T1 --> T2
    T2 --> T3
    T3 --> N1
    T3 --> N2
    T3 --> N3
    T3 --> N4
    N1 --> O1
    N2 --> O1
    N3 --> O2
    N4 --> O2
    T3 --> O4
    S1 --> A1
```

阅读方式：**纵向是依赖**（上层调下层），**横向是同层协作**。
`③ → ④` 是唯一一条"由模型决定走哪条"的边 —— 工具名和参数都是模型给的，
所以参数校验和风险确认都发生在 `AgentRunner` 里，不在工具自己身上（工具无从拒绝）。

---

## 二、一轮对话的时序

包含工具调用、串并行、确认、中止五条分支。

```mermaid
sequenceDiagram
    autonumber
    actor U as 用户
    participant P as ChatPage
    participant R as AgentRunner
    participant M as DeepSeekClient
    participant API as 模型 API
    participant G as ToolRegistry
    participant T as 工具
    participant N as 原生桥

    U->>P: 输入并点发送
    P->>P: 长文本 >2000 字 → 存变量库，框内换占位标记
    P->>R: run(conversation, onUpdate, onConfirm)

    R->>R: 组装系统提示词（Agent.md → 规则 → 记忆 → 学习 → 计划）
    R->>R: buildApiMessages：压缩 / 附件 / 引用 / 变量展开
    Note over R: compressMode = every 始终压<br/>ratio 在用量 ≥80% 时压<br/>off 不压
    R->>M: stream()
    M->>API: POST /chat/completions（带 tools）
    API-->>M: SSE 增量

    loop 流式输出
        M-->>R: 文本增量 / tool_calls 分片
        R-->>P: onUpdate() → 界面刷新
        P-->>U: 逐字显示
        opt 用户按停止
            U->>P: 停止
            P->>R: abort()
            R->>R: 先置 _aborted 再 cancel() 连接
            R-->>P: 收工，命令不再继续
        end
    end

    alt 没有 tool_calls
        R->>R: 拆分思考标签 → 展开对象引用 → 展开变量库
        R->>P: 落盘并结束
    else 有 tool_calls
        R->>R: 参数结构校验（在弹框之前）
        R->>R: 第一遍：串行确认
        Note over R,G: 同一条失败调用第二次出现 → 直接熔断<br/>writer 未读过目标文件 → 拒绝执行
        R->>P: onConfirm(风险 + 摘要)
        P-->>U: 确认框 / 悬浮窗
        U-->>P: 允许
        R->>G: 第二遍：执行
        par 只读工具并行
            G->>T: 同时跑
        and 有副作用工具串行
            G->>T: 逐个跑
        end
        T->>N: MethodChannel
        N->>N: 线程池执行（不占主线程）
        N-->>T: 结果 / stdout / 二进制
        T-->>R: 文本结果
        R->>R: 结果写回上下文 → 下一轮（上限 maxToolRounds）
    end
```

几个容易画错的点，这里按代码写：

**确认在串行段之前。** 校验和确认是第一遍，全部过完才开始执行第二遍。
不然并行执行到一半跳出确认框，用户拒绝时前几个已经跑了。

**只读并行、有副作用串行。** 同一轮里重复的只读调用只跑一次。

**停止不是只断网络。** `abort()` 先置标志再断连接，两处都要查这个标志，
否则命令照样执行、下一页照样请求。

---

## 三、工程模块全景

```mermaid
mindmap
  root((Tinkung))
    ai 智能层
      AgentRunner 主循环
        轮次上限 maxToolRounds
        失败调用熔断
        写前必读约束
        中止标志
      系统提示词
        Agent.md 最高优先级
        规则 / 记忆 / 学习
        计划树 / 工具说明
        输出纪律
      buildApiMessages
        压缩三档 every ratio off
        附件与图片内联
        引用原文
        变量库展开
      DeepSeekClient
        SSE 流式
        tool_calls 按 index 拼片
        usage 取在 choices 之前
      辅助
        输入联想 input_suggestions
        描述改写 prompt_improver
    core 领域层
      设置与存储
        Settings 可变字段 update 包写入
        ConversationStore 后台 isolate 解析
        NoteStore / TaskStore
        RuleStore / MemoryStore / LearningStore
        VarBankStore 超长文本
        AgentDocStore
        LockStore 加盐 SHA-256 一万轮
      平台适配
        ShizukuService
        LinuxService / TermuxService
        PythonService Chaquopy
        A11y / UiTree / PhoneControl
        VoiceInput / Overlay / Notify
      联网
        WebSearch 多级通道
        WebFetch HTTP 优先 WebView 兜底
        Scrub 提示注入清洗
        NetError 错误翻译与重试
      其他
        Metrics token 与上下文
        Ids 时间戳加序号
        ShQuote shell 转义
        ThinkTags 思考标签
        Resolver 路径规范化
    tools 工具层 36 个
      无条件的本地能力
        notes tasks
        web browser read_image
        open_file get_location
        filesearch reader writer geter sheller
      依赖 Shizuku
        run_shell app_manage file_op
        system_settings screen_capture
      能给出下一步的
        python termux
        ui_tree ui_action draw_path
        pc generate_image
        plugin tool plan multibot
      协作与治理
        request_unlock 请用户验证
        notify_user 后台提醒
        chat_alarm 风险告示
        rules memory learn
        mark recall varbank knowledge
        mcp mcp_admin model_manager
        interact change_think
    ui 界面层 51 个
      对话
        chat_page 输入框毛玻璃
        fullscreen_input 全屏输入
        mention_input 高亮与补全
        markdown 渲染 LaTeX
        cards 富卡片
      消息组件
        widgets 气泡 附件 chip 告示条
        tool_steps 折叠工具过程
        inline_image 内联图
        image_viewer 看图
      设置与管理
        settings_sheet 条目式
        models_sheet 多档案
        tools_page 工具与权限
        knowledge_page 知识库
        memory_page 记忆
        learning_page 自学习
        mcp_page
        performance_sheet 性能面板
        storage_sheet 存储清理
      导航与外壳
        home_shell 底部导航
        app_drawer Tinkung 侧栏
        greeting 问候语
        lock_ui 锁屏与验证
    theme 视觉层
      AppFonts
        Inter 四个静态字面
        bodyFallback sans-serif 接中文
        lineHeight 1.14
        baseScale × userScale
      AppColors
        defaultSeed D97757
        applyScheme 按亮度重写
      AppRadius
        input 12
        card 16
      AppSurface ThemeExtension
        pageBg surface chipBg
        border text muted bubbleBg
        isDark
      glass 玻璃封装
    cwt 思维重写
      多轮重写流水线
      预览 docx pdf pptx xlsx
    knowledge 知识库
      document_parser
      knowledge_chunker
      knowledge_embedder
      knowledge_store 检索与重排
    mcp
      client
      store
    plugins 自定义插件
      shell 模板
      HTTP 模板
      sandbox 独立 APK
    interaction 互动面板
      WebView 内嵌
      可拖高度
    android 原生 17 个 Kotlin
      MainActivity 通道注册
      ShizukuBridge
      AgentAccessibilityService
      LinuxRuntime proot Alpine
      TermuxBridge
      SpeechBridge
      WebBridge
      PdfBridge
      LockBridge
      FileOpenBridge
      OverlayConfirm
      Notifier
    存储 本机文件
      conversations.json
      notes / tasks / rules
      memory / learning
      varbank / Agent.md
      lock.json
      工作目录 dsh
    构建与测试
      工具链 固定路径
      AGP 9.1.0 Kotlin 2.4.0
      Chaquopy 17.0.0
      minSdk 26
      arm64-v8a x86_64
      717 项测试
      39 张预览图
```

---

## 四、数据流向速查

| 起点 | 终点 | 载体 |
|---|---|---|
| 用户输入 | 模型 | `buildApiMessages` 组装的 messages 数组 |
| 模型返回 | 界面 | `onUpdate()` 回调，逐帧刷新 |
| 工具调用 | 原生 | `MethodChannel`，见 `MainActivity.kt` |
| 原生结果 | 模型 | `run()` 返回的字符串 |
| 任何设置改动 | 磁盘 | `settings.update()` → `SharedPreferences` |
| 会话内容 | 磁盘 | `ConversationStore.save()` → JSON |
| 生成的文件 | 工作目录 | 外部存储或应用支持目录下的 `/dsh` |

---

## 五、图里没画的东西

诚实说明边界：

- **没有画时序图里的重试和降级细节**。网络失败由 `net_error.dart` 翻译后
  返回给模型，模型自己决定重不重试，这一层在 Agent 循环之上，不属于单轮时序。
- **没有画子智能体**。`multibot` 会新建一个 `AgentRunner` 跑独立任务，
  结构上和主循环是同一张图，画进来会变成递归。
- **没有画 MCP 的远端服务器**。它属于工具层的扩展，外部依赖，不在本仓库。
- **玻璃控件的 shader 路径没有画**。它属于 Flutter 引擎，预览图也证明不了它的观感。
