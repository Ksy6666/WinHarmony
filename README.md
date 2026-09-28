# WinRemote

**用 HarmonyOS 手机 / 平板，在局域网内远程遥控 Windows 11 电脑。**

WinRemote 由两部分组成：

- **电脑端服务**（`server/winremote_server.py`）：运行在 Windows 11 上的 Python 程序，通过 WebSocket 接收手机指令，注入鼠标 / 键盘操作，并把屏幕画面实时推送给手机。
- **手机端应用**（HarmonyOS App，本仓库主体）：连接电脑、显示电脑画面、提供触控板手势和虚拟键盘，让你用手机操控电脑。

整体是一个自研的轻量级"远程桌面 + 远程输入"方案，不依赖任何第三方远控服务，所有数据只在内网（局域网）中传输。

```
┌─────────────────────┐      Wi-Fi / 局域网       ┌──────────────────────────┐
│  HarmonyOS 手机/平板 │ ◄────── WebSocket ──────► │  Windows 11 电脑          │
│  WinRemote App      │   控制指令 (JSON 文本帧)    │  winremote_server.py     │
│                     │   屏幕画面 (JPEG 二进制帧)  │  pynput 注入鼠标键盘       │
└─────────────────────┘                           │  WGC/mss 抓屏 → JPEG 编码 │
                                                  └──────────────────────────┘
```

---

## 目录

1. [功能特性](#功能特性)
2. [技术栈](#技术栈)
3. [系统架构](#系统架构)
4. [通信协议](#通信协议)
5. [使用方法](#使用方法)
6. [详细制作过程](#详细制作过程)
7. [性能优化细节](#性能优化细节)
8. [自测](#自测)
9. [常见问题 FAQ](#常见问题-faq)
10. [目录结构](#目录结构)

---

## 功能特性

- **屏幕实时串流**：电脑画面以 JPEG 帧推送，支持调节分辨率（原生 / 1920 / 1600 / 1280）、帧率（10~60fps）、画质（低 / 中 / 高），随时暂停 / 恢复。
- **触控板手势**（画面区域）：
  | 手势 | 作用 |
  |---|---|
  | 单指轻触 | 鼠标左键单击 |
  | 单指拖动 | 移动鼠标指针（绝对定位） |
  | 长按（约 0.42s） | 按住左键（可配合拖动选中文本） |
  | 双指上下滑动 | 鼠标滚轮 |
- **虚拟键鼠面板**：
  - 左 / 右 / 中键单击按钮，滚轮 ↑↓ 按钮；
  - 22 个常用按键与组合键：Enter、Esc、Tab、退格、Del、空格、方向键、Ctrl+C/V/X/A/Z、Alt+Tab、Alt+F4、Win、Win+D/E/L、Ctrl+Shift+Esc 等；
  - 文字输入框：发送任意文字到电脑，**中文等 CJK 字符自动走剪贴板 + Ctrl+V 粘贴**（绕过键盘模拟无法输入中文的问题）。
- **连接管理**：地址 / 端口 / 访问令牌（token）配置，连接状态实时显示，错误信息友好化（如"该端口不是 WebSocket 服务"）。
- **自适应布局**：窄屏时画面 + 底部抽屉式控制面板；宽屏（≥600vp，平板 / 折叠屏展开）时左右分栏。
- **流控（ack 模式）**：手机每解码完一帧才回执，服务器据此决定下一帧发送时机，避免网络 / 解码积压造成"越用延迟越大"。
- **安全**：可选共享令牌鉴权；不设置 token 时服务端会醒目警告。
- **单文件 exe**：服务端可用 PyInstaller 打包成免安装的 `WinRemoteServer.exe`。

## 技术栈

### 电脑端（server/）

| 技术 | 用途 |
|---|---|
| **Python 3.10+** | 服务端语言 |
| **websockets ≥ 12.0** | 异步 WebSocket 服务器（`websockets.asyncio.server`） |
| **pynput ≥ 1.7.6** | 鼠标移动 / 点击 / 滚轮、键盘按键与组合键注入（Win32 `SendInput` 封装） |
| **windows-capture ≥ 2.0.0** | Windows.Graphics.Capture（WGC）抓屏，Rust 扩展、独立捕获线程、零拷贝，首选后端 |
| **mss ≥ 9.0.1** | GDI BitBlt 抓屏，WGC 不可用时的回退后端 |
| **Pillow ≥ 10.0.0** | 图像缩放（`reduce()` / BOX `resize()`）与 JPEG 编码；`ImageGrab` 为最后回退 |
| **numpy** | WGC 帧缓冲 BGRA→RGB 转换 |
| **asyncio + ThreadPoolExecutor** | 事件循环与专用抓屏/编码工作线程 |
| **ctypes（Win32 API）** | `GetSystemMetrics`（DPI 感知的屏幕尺寸）、进程完整性级别（判断是否管理员） |
| **PowerShell 子进程** | 读取用户名、写剪贴板（`Set-Clipboard`，UTF-8，支持中文） |
| **PyInstaller** | 打包单文件 `WinRemoteServer.exe` |

### 手机端（HarmonyOS App）

| 技术 | 用途 |
|---|---|
| **ArkTS / ArkUI（声明式 UI）** | 全部界面：`@Entry @Component struct`、`@State / @Prop / @Link` 状态驱动、`@Builder` 拆分 UI |
| **@kit.NetworkKit（webSocket）** | WebSocket 客户端，文本帧收 JSON、二进制帧收 JPEG |
| **@kit.ImageKit（image）** | `createImageSource` + `createPixelMap` 异步解码 JPEG 帧 |
| **@kit.PerformanceAnalysisKit（hilog）** | 日志与性能统计输出 |
| **@kit.AbilityKit（UIAbility）** | 应用入口 `EntryAbility` |
| **TouchEvent（onTouch）** | 原始多点触控处理：单击 / 拖动 / 长按 / 双指滚轮手势识别 |
| **hvigor 构建体系** | HarmonyOS 工程构建（API 24 / SDK 6.1.1(24)，HarmonyOS 签名） |

## 系统架构

### 总体分层

```
HarmonyOS App (entry 模块)
├── pages/Index.ets          # 入口页面：连接状态机 + 宽窄屏路由
├── view/ConnectPanel.ets    # 连接表单（地址/端口/令牌）
├── view/ControlPanel.ets    # 控制台：画面渲染 + 手势 + 虚拟键鼠 + 串流设置
├── service/RemoteClient.ets # WebSocket 封装（连接/收发/错误翻译/ack 回执）
└── model/RemoteProtocol.ets # 协议常量：连接状态枚举、服务端消息接口、指令构造器

Windows 11 服务端 (server/winremote_server.py，单文件约 880 行)
├── 输入后端      # pynput 键鼠注入；特殊键映射表；组合键 press/release 顺序
├── 协议分发      # dispatch()：move/moveto/click/scroll/key/combo/text/sysinfo/ping
├── 屏幕捕获      # ScreenCapturer：WGC → mss → Pillow 三级后端，专用线程
├── 编码          # encode_jpeg()：整数倍快速缩小 + BOX 缩小 + JPEG 编码
├── 传输          # Session 管理、stream_loop 帧推送循环、ack 流控、发送锁
└── CLI / 横幅    # argparse 参数、局域网 IP 列举、管理员权限检测与警告
```

### 手机端关键设计

- **状态机驱动 UI**：`ConnState`（Idle → Connecting → Connected → Closed/Error）决定显示 `ConnectPanel` 还是 `ControlPanel`。
- **回调解耦**：`RemoteClient` 暴露 `onState / onMessage / onFrame` 三个回调，页面在 `aboutToAppear` 中挂载，`RemoteClient` 本身不持有任何 UI 引用。
- **帧解码队列（丢帧保延迟）**：`ControlPanel.handleFrame()` 收到二进制帧后只保留最新一帧到 `pendingFrame`，解码循环 `decodeNext()` 串行解码；若解码中又来新帧则**直接丢弃旧帧并计数**，用"宁可丢帧、不可积压"的策略把端到端延迟压到最低。每解码完一帧调用 `client.ack()` 回执服务器。
- **绝对坐标映射**：手机触点根据画面容器尺寸和电脑屏幕宽高比做 letterbox 换算，映射为 0~1 的归一化坐标发给服务器（`moveto`），规避两端 DPI / 分辨率差异。
- **手势识别**：用 `TAP_TOLERANCE_VP`（10vp）区分"轻触"与"拖动"，用 `LONG_PRESS_MS`（420ms）定时器实现长按左键，双指平均 Y 位移按档位累计成滚轮 notch 数。

### 服务端关键设计

- **单线程 asyncio 事件循环 + 1 个抓屏工作线程**：`CAPTURE_POOL` 是 `max_workers=1` 的线程池，`grab_jpeg()` 通过 `run_in_executor` 投递。抓屏和 JPEG 编码刻意放在同一线程——实测分离反而因 GIL 争用降低帧率。
- **三级抓屏后端**：
  1. **wgc**（`windows-capture` 包）：独立捕获线程回调交付帧（BGRA→RGB 一次拷贝），只在画面变化时产生帧，且在 PyInstaller 打包后依然可用；
  2. **mss**：GDI BitBlt，`mss` 实例绑定创建线程，因此用 `threading.local` 懒加载；
  3. **pillow**：`ImageGrab` 兜底。
  WGC 启动 10 秒内没有帧或回调报错会自动降级到 mss。
- **ack 流控**（`stream_loop`）：开启 ack 模式时，先**异步启动下一帧抓取**，再等待客户端"已消费一帧"的回执（`asyncio.Condition`，超时 0.5s 放行）。信用式判断（`acks > base`）而不是精确对账，避免一次丢 ack 就把整条流卡死。
- **参数热更新**：`stream_loop` 每轮循环重新读取 fps / quality / max_width，改设置无需重启推流任务。
- **UIPI 权限检测**：通过 Win32 令牌完整性级别（`TOKEN_INTEGRITY_LEVEL`）判断是否以管理员运行，启动横幅中明确警告——因为 Windows UIPI 会静默丢弃注入到提权窗口（任务管理器等）的输入。

## 通信协议

基于 WebSocket（默认端口 8765），**文本帧 = JSON 控制消息，二进制帧 = JPEG 屏幕画面**。

### 握手

1. 客户端连接后，服务端立即下发 `{"t":"hello","ok":false,"needToken":true,...}`（要求先发 token）或免鉴权时直接 `ok:true`；
2. 客户端发送 `{"t":"hello","token":"...","client":"harmony"}`，token 校验失败则服务端回 `err` 并以 4001 关闭连接；
3. 客户端发送 `{"t":"sysinfo"}`，服务端回 `{"t":"info","ok":true,"host":"主机名","user":"用户名","sw":宽,"sh":高,...}`。

### 客户端 → 服务端指令

| t | 参数 | 说明 |
|---|---|---|
| `hello` | `token` | 鉴权 |
| `sysinfo` | — | 查询电脑信息 |
| `move` | `dx, dy` | 鼠标相对移动 |
| `moveto` | `x, y` | 鼠标绝对移动（0~1 归一化坐标） |
| `click` | `b`（left/right/middle）、`a`（click/down/up） | 点击 / 按下 / 抬起 |
| `scroll` | `dx, dy` | 滚轮（dy 为 notch 数） |
| `key` | `k` | 单键名（enter/esc/f4/win/...） |
| `combo` | `keys: string[]` | 组合键，最后一个键为主键 |
| `text` | `s` | 发送文本（ASCII 走键盘，CJK 走剪贴板+Ctrl+V） |
| `stream` | `on, fps, quality, maxWidth, ack` | 开关推流及参数 |
| `ack` | — | 帧消费回执（流控） |
| `ping` | — | 心跳，服务端回 `pong` |

### 服务端 → 客户端消息

| t | 说明 |
|---|---|
| `hello` / `info` | 握手结果 / 电脑信息 |
| `streamState` | 推流状态确认（含 `screenW/screenH`，客户端据此计算画面宽高比；含 `ackMode`） |
| `textResult` | 文字发送结果 |
| `err` | 错误 |
| `pong` | 心跳回应 |
| （二进制帧） | JPEG 图像数据 |

## 使用方法

### 第 1 步：启动电脑端服务

在 Windows 11 电脑上（PowerShell）：

```powershell
# 安装依赖（Python 3.10+）
py -m pip install -r server/requirements.txt

# 启动服务（--token 设置访问令牌，可省略；--port 默认 8765）
py server/winremote_server.py --port 8765 --token 1234
```

启动后服务端会打印横幅，列出本机所有局域网 IPv4 地址、抓屏后端、权限状态：

```
==============================================================
  WinRemote  --  HarmonyOS remote control server   v1.0.0
==============================================================
  Status   : LISTENING
  Screen   : 2560 x 1440
  Capture  : wgc
  Rights   : administrator
  Port     : 8765
  Token    : (the value you passed with --token)
  Address  : type ONE of these into the phone app:
               192.168.1.23
==============================================================
```

> - **首次运行**需允许程序通过 Windows 防火墙（专用网络）。
> - **建议以管理员身份运行**：否则当前台是任务管理器等提权窗口时，注入的鼠标键盘会被 Windows UIPI 静默丢弃。横幅中会明确警告。
> - 也可直接使用已打包的 `server/dist/WinRemoteServer.exe`（免 Python 环境）。

命令行参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--host` | `0.0.0.0` | 绑定地址 |
| `-p, --port` | `8765` | 监听端口 |
| `-t, --token` | 空 | 访问令牌；为空表示不鉴权（任何人可控电脑，慎用） |
| `-q, --quiet` | — | 减少日志输出 |
| `-V, --version` | — | 查看版本 |

### 第 2 步：手机连接

1. 将本工程构建出的 HAP 安装到 HarmonyOS 手机 / 平板（`dist/WinRemote-1.0.0-tablet-api24-signed.hap` 为已构建签名产物），确保手机与电脑在**同一局域网 / Wi-Fi** 下；
2. 打开 App，输入服务端横幅中打印的**内网 IP**、端口（默认 8765）和 token（若有），点击"连接"；
3. 连接成功后自动开始接收电脑画面。

### 第 3 步：遥控操作

- **画面区域**：轻触 = 左键单击；拖动 = 移动鼠标；长按 = 按住左键拖选；双指上下滑 = 滚轮；
- **"控制"按钮**：展开面板，使用鼠标按键、滚轮按钮、快捷键和文字输入框；
- **"播放 / 暂停"**：暂停画面串流（省流量）；
- **串流设置**：切换分辨率 / 帧率 / 画质，立即生效；
- **"断开"** 或系统返回键：断开连接。

### 打包服务端为 exe（可选）

```powershell
py -m pip install pyinstaller
cd server
py -m PyInstaller WinRemoteServer.spec
# 产物在 server/dist/WinRemoteServer.exe
```

## 详细制作过程

下面是本项目从零到一的完整制作步骤，可以依此复现或扩展。

### 阶段一：搭建 HarmonyOS 工程骨架

1. **创建工程**：在 DevEco Studio 中新建 Empty Ability 工程（Application），工程名 `WinRemote`，Bundle Name `com.example.winremote`，编译 SDK 选择 **HarmonyOS 6.1.1(24)（API 24）**，设备类型勾选 phone + tablet。
2. **配置网络权限**：在 `entry/src/main/module.json5` 的 `requestPermissions` 中声明：
   ```json5
   "requestPermissions": [
     { "name": "ohos.permission.INTERNET" },
     { "name": "ohos.permission.GET_NETWORK_INFO" }
   ]
   ```
   没有这两个权限，WebSocket 无法建立连接。
3. **配置签名**：`File → Project Structure → Signing Configs`，勾选 Automatically generate signature，生成调试签名（`build-profile.json5` 中会写入 `signingConfigs`），保证 HAP 可安装到真机。
4. 工程生成后得到标准结构：`AppScope/app.json5`（应用级配置）、`entry/src/main/ets/entryability/EntryAbility.ets`（入口 Ability，`onWindowStageCreate` 中加载 `pages/Index`）。

### 阶段二：设计通信协议（model 层先行）

1. 新建 `entry/src/main/ets/model/RemoteProtocol.ets`；
2. 定义连接状态枚举 `ConnState`（Idle / Connecting / Connected / Closed / Error）；
3. 定义服务端消息接口 `ServerMessage`（全部字段可选，`t` 为消息类型判别字段）；
4. 编写 `RemoteCmd` 静态类，为每条客户端指令提供 `JSON.stringify` 构造方法。注意 ArkTS 严格模式要求：
   - 不允许对象字面量直接当类型，简单指令用模板字符串手写 JSON（如 `{"t":"move","dx":1,"dy":2}`）；
   - 复杂指令（数组字段）用显式 class（`ComboPayload` / `TextPayload` / `StreamPayload` / `HelloPayload`）+ 显式字段初始化，再 `JSON.stringify`。

### 阶段三：封装 WebSocket 客户端（service 层）

新建 `entry/src/main/ets/service/RemoteClient.ets`，用 `@kit.NetworkKit` 的 `webSocket.createWebSocket()`：

1. `connect(host, port, token)`：先 `disconnect()` 防重入，拼 `ws://host:port`，注册 `open / message / close / error` 四个事件；
2. **事件语义**：
   - `open` → 上报 Connected 并发送 `hello`（带 token）和 `sysinfo`；
   - `message` → 字符串走 `JSON.parse` 解析为 `ServerMessage` 交给 `onMessage`；`ArrayBuffer` 是 JPEG 帧直接交给 `onFrame`（WebSocket 的消息事件天然区分文本 / 二进制帧，正好承载双通道协议）；
   - `close / error` → 清理 socket 引用并上报状态，注意用"闭包中的 socket 与成员变量比对"防止旧连接的迟到回调污染新连接；
3. **错误翻译**：`describeError()` 把 `err.code === 200`（非 WS 服务）等系统错误码翻译成用户能看懂的中文提示；
4. **ack 回执**：收到 `streamState.ackMode === true` 时进入 ack 模式，`ack()` 方法仅在 ack 模式下发送 `{"t":"ack"}`，避免无谓流量；
5. 所有日志走 `hilog`（DOMAIN 0x0000，TAG `WinRemote`）。

### 阶段四：连接页面（ConnectPanel）

新建 `entry/src/main/ets/view/ConnectPanel.ets`（`@Component struct`）：

1. `@Link host / port / token` 双向绑定输入框，`@Prop statusText / busy` 接收页面状态；
2. 深色主题样式（背景 `#0B1020`），表单居中，最大宽度 560vp，`Scroll` 包裹防止小屏溢出；
3. 状态行用绿 / 红圆点 + 文本提示连接进度与错误。

### 阶段五：主页面状态机与响应式布局（Index）

`entry/src/main/ets/pages/Index.ets`（`@Entry`）：

1. 持有 `host / port / token / connState / statusText / infoText / isWide / screenRatio` 等 `@State`，`RemoteClient` 作为普通成员（非状态变量）；
2. `aboutToAppear` 挂载 `onState / onMessage` 回调；`onMessage` 中按 `t` 分发：`hello/info` 组装电脑信息文本，`streamState` 记录屏幕宽高比（供画面 letterbox 用），`err` / `textResult` 更新状态提示；
3. `build()` 中按 `connState` 切换 `ConnectPanel` / `ControlPanel`；
4. `onAreaChange` 监听页面宽度，≥600vp 记为宽屏（平板分栏布局）；
5. `onBackPress()`：已连接时返回键先断开连接，再退出应用。

### 阶段六：控制面板与手势（ControlPanel，工作量最大）

新建 `entry/src/main/ets/view/ControlPanel.ets`：

1. **帧接收与解码**：`aboutToAppear` 挂载 `client.onFrame` 并发送 `stream on`；
   - `handleFrame()`：统计到达间隔 / 字节数，若正在解码则丢弃旧帧（`statsDropped++`），始终保留最新帧到 `pendingFrame`；
   - `decodeNext()`：串行解码循环，`image.createImageSource(data)` → `createPixelMap()` → 更新 `@State frame` → 释放旧 PixelMap 与 ImageSource（**内存管理必须严谨，否则几秒内泄漏爆内存**）→ 每帧解码完 `client.ack()`；
   - `reportStats()`：每 20 帧输出一次解码耗时 / 实际 fps / 丢帧 / 平均帧大小到 hilog，用于调优。
2. **画面渲染**：`Image(this.frame).objectFit(ImageFit.Contain)` + `interpolation(Low)`（低质量插值更快）；`onAreaChange` 记录容器尺寸 `padW / padH`。
3. **手势识别**（`onTouch` 原始事件，非手势组件，因为需要区分按下 / 抬起 / 多指）：
   - 触摸模式常量 `TOUCH_IDLE / TOUCH_POINTER / TOUCH_SCROLL`；
   - Down：单指进入 POINTER 模式，记起点、启动长按定时器（420ms 后发送 `press left`）；双指进入 SCROLL 模式；
   - Move：POINTER 模式下累计位移超 10vp 标记为拖动并取消长按，同时把触点换算为归一化坐标发送 `moveto`；SCROLL 模式下用双指平均 Y 位移、按"容器高度 10%（最小 16vp）"为一档累计 notch，单次事件限幅 ±12，发送 `scroll`；
   - Up：若长按中则发送 `release left`；否则若未拖动且时长 < 350ms 判定为轻触，发送 `click left`；
   - `sendAbsolute()`：按电脑屏幕宽高比与容器尺寸做 letterbox（Contain）反算，把触点映射到 0~1 归一化坐标并夹取边界。
4. **控制面板**：`@Builder` 拆分 `header / screenArea / mouseButtons / keyboard / streamSettings`；
   - 虚拟按键用 `KeyButton` class 数组 + `ForEach` 渲染（ArkTS 要求显式类型，不能用对象字面量数组）；
   - 串流设置切换后立即调用 `applyStream()` 重发 `stream` 指令（服务端热更新参数）；
   - 布局：宽屏左右分栏（3:2），窄屏上下布局（面板占 42% 高）。

### 阶段七：编写 Windows 服务端

新建 `server/winremote_server.py`（单文件，约 880 行）：

1. **依赖与入口**：`argparse` 解析 `--host/--port/--token/--quiet`；`sys.platform != "win32"` 直接拒绝（输入注入依赖 Win32 API）；缺依赖时给出精确的 `pip install` 提示。
2. **输入注入层**：
   - `pynput` 的 `KeyboardController / MouseController` 全局实例；
   - `SPECIAL_KEYS` 映射表：enter/esc/tab/backspace/delete/space/方向键/F1~F12/win/ctrl/alt/shift 等 → `pynput.keyboard.Key`；
   - `press_combo()`：按序按下所有修饰键 → 按下主键 → 抬主键 → 逆序抬修饰键；
   - `type_text()`：纯 ASCII 走 `keyboard.type()`；含 CJK 则 `set_clipboard()`（PowerShell `Set-Clipboard`，UTF-8 编码，`CREATE_NO_WINDOW` 防闪窗）后 `Ctrl+V`；
   - `screen_size()`：`SetProcessDPIAware()` + `GetSystemMetrics` 拿物理分辨率。
3. **UIPI 检测**：`own_integrity_rid()` 用 ctypes 走 `OpenProcessToken → GetTokenInformation(TOKEN_INTEGRITY_LEVEL)`，解析 TOKEN_MANDATORY_LABEL SID 的最后一个 sub-authority 得到完整性级别（≥0x3000 即管理员）。
4. **抓屏层 `ScreenCapturer`**：
   - 构造时探测可用后端：`import windows_capture` 成功选 **wgc**，否则 `import mss` 选 **mss**，再否则 **pillow**；
   - WGC：`WindowsCapture(cursor_capture=False, draw_border=False, monitor_index=1)`，`on_frame_arrived` 回调里 `np.asarray(frame.frame_buffer)`（BGRA，仅回调内有效）→ `array[:, :, 2::-1]` 一次通道翻转 → 拷贝成 PIL Image 存入带锁成员；`start_free_threaded()` 独立线程运行；10 秒启动宽限期内无帧或回调异常 → `_use_fallback()` 降级 mss；
   - mss：`threading.local` 保存实例（mss 与创建线程绑定），专用线程上懒创建；
   - `grab()` 统一入口。
5. **编码层 `encode_jpeg`**：
   - `max_width` 缩小：先算整数因子，若 2 的幂且误差 ≤2px 用 `image.reduce(factor)`（比通用 `resize` 快约 6 倍）；否则用 BOX（面积平均，正确的缩小滤波，又比 BILINEAR 快约 30%）；
   - JPEG `save` 到 `BytesIO`，`optimize=False` 换速度。
6. **执行模型**：`CAPTURE_POOL = ThreadPoolExecutor(max_workers=1)`，`grab_jpeg()` 用 `run_in_executor` 把抓屏+编码整体投到该线程（刻意不拆开，GIL 争用下拆开反而更慢）。
7. **会话与推流**：
   - `Session`：鉴权标志、推流参数、ack 计数（`asyncio.Condition`）、发送锁（`asyncio.Lock`，防止 JSON 与二进制帧交错写坏消息边界）；
   - `stream_loop()`：循环 = 先发起下一帧抓取 future →（ack 模式下）等待客户端回执（信用式 `acks > base`，超时 0.5s 放行，保证不卡死）→ await 帧 → `send_frame` 二进制发送 → 按 fps 计算剩余睡眠；每轮重读参数实现热更新；
   - `handle_client()`：连上先发 hello/needToken → 逐条收消息：hello 鉴权（失败回 err 并以 4001 关闭）、ack 计数、stream 开关 + 参数 clamp（fps 1~60、quality 10~95、maxWidth 320~3840 或 0=原生）并回 `streamState`、其余交给 `dispatch()` 执行并按需回包；断开时 `stop_stream()`。
8. **启动横幅 `print_banner`**：枚举局域网 IPv4（先 `getaddrinfo(hostname)`，失败则 UDP connect 8.8.8.8 探测法），打印屏幕 / 后端 / 权限 / 端口 / 地址列表；非管理员时给出醒目的 UIPI 警告与解决方法。

### 阶段八：联调与迭代

1. 手机与电脑同网，启动服务端 → App 输入 IP 连接 → 验证握手、信息显示；
2. 用 `hilog`（TAG `WinRemote`）观察解码耗时 / fps / 丢帧统计，服务端看帧耗时日志；
3. 按实测调整默认参数：fps 20、quality 70、maxWidth 1280（GDI 后端抓屏约 40~70ms/帧，实测 10~15fps 封顶，UI 中如实提示用户）；
4. 针对发现的问题迭代：
   - 延迟越拖越大 → 加入 ack 流控 + 客户端丢帧解码；
   - 打包 exe 后黑屏 → 从 DXGI 复制换成 WGC 后端（COM 初始化在 PyInstaller 下不可靠）；
   - 中文输不进去 → 剪贴板 + Ctrl+V 通道；
   - 提权窗口遥控失灵 → 完整性级别检测 + 横幅警告。

### 阶段九：构建与分发

1. **构建 HAP**：DevEco Studio `Build → Build Hap(s)`，或命令行 hvigor 打包；签名后产物为 `dist/WinRemote-1.0.0-tablet-api24-signed.hap`，用 DevEco Studio 或 `hdc install` 安装到设备；
2. **构建 exe**：编写 `server/WinRemoteServer.spec`，关键点：
   - `hiddenimports = ['pynput.keyboard._win32', 'pynput.mouse._win32', 'mss.windows']`（这些是运行时动态导入的 Win32 后端，PyInstaller 静态分析找不到）；
   - `collect_submodules('mss')` 兜底收集 mss 全部子模块；
   - `console=True`（保留控制台窗口，用户需要看 IP 横幅）；
   - 单文件 EXE（`runtime_tmpdir=None`），产物 `server/dist/WinRemoteServer.exe`；
3. **编写自测**：`server/selftest.py` 端到端回环测试（见下节）。

## 性能优化细节

本项目在延迟和帧率上做了大量针对性优化，值得单独说明：

1. **客户端丢帧解码**：解码永远只处理"最新一帧"，旧帧直接丢弃。低配设备解码慢时表现为帧率下降，但**延迟不增长**。
2. **服务端 ack 流控**：不 ack 的盲目推流会让帧在 TCP / Wi-Fi 缓冲里排队，表现为"画面越来越落后"；ack 模式把在途帧数限制在 1，且下一帧抓取与等待回执**并行**，隐藏编码耗时。
3. **抓屏后端分级**：WGC 在独立线程零拷贝交付，只在画面变化时产帧，服务线程只付 JPEG 编码的成本；失败自动降级，保证开箱即用。
4. **缩放算法选型**：整数倍用 `reduce()`（约 6× 速度），一般缩小用 BOX 滤波（正确且约 30% 速度优势），`optimize=False` 关闭 JPEG 优化换编码速度。
5. **单工作线程**：抓屏 + 编码同线程，避免 GIL 争用把帧率腰斩。
6. **触摸 → 指令直发**：拖动事件直接换算 `moveto` 归一化坐标发送，不做客户端节流（WebSocket / 局域网吞吐足够），指针跟随手感更好。
7. **解码统计**：`STATS` 日志（每 20 帧）暴露 decodeAvg / decodeMax / gapAvg / fps / dropped / kb，为参数选择提供实测依据。

## 自测

服务端附带端到端自测 `server/selftest.py`，会启动真实服务（端口 8799）并用 WebSocket 客户端回环验证协议，**只使用非破坏性命令（零位移 move / scroll），不会动你的真实鼠标键盘**：

```powershell
cd server
py selftest.py
```

覆盖项：token 公告与校验（错 token 拒绝并断开）、hello / sysinfo / ping 回包、空 text 回执、非法 JSON 与未知命令的 err 回包、真实抓屏推流（校验 JPEG 魔数 `FF D8`）、stream 开关确认、按键名解析表。

## 常见问题 FAQ

**Q：连不上 / 提示"该端口不是 WebSocket 服务"？**
确认服务端已启动且端口一致；检查 Windows 防火墙是否放行（首次运行弹窗要勾选"专用网络"）；确认手机和电脑在同一网段；地址要用服务端横幅打印的内网 IP，不是 `localhost`。

**Q：画面卡 / 帧率上不去？**
抓屏是瓶颈（GDI 后端约 40~70ms/帧）。优先安装 `windows-capture` 启用 WGC 后端（横幅 `Capture: wgc`）；降低分辨率 / 帧率 / 画质；关闭其他占用 GPU 的程序。

**Q：遥控任务管理器等管理员窗口时鼠标键盘"失灵"？**
Windows UIPI 限制。右键以管理员身份重启服务端（横幅会检测并警告）。

**Q：怎么输入中文？**
用控制面板的文字输入框发送（服务端自动走剪贴板 + Ctrl+V）。直接逐键模拟无法输入中文。

**Q：token 必须设吗？**
不必须，但强烈建议。不设 token 时同一局域网内任何设备都可以控制你的电脑，服务端横幅也会警告。

**Q：支持互联网远程吗？**
不支持，设计上仅限局域网。协议为明文 `ws://`，跨公网使用需自建 VPN / 隧道并自担风险。

**Q：支持多显示器 / 非主屏吗？**
当前仅捕获主显示器（`monitor_index=1` / `mss.monitors[1]`）。

## 目录结构

```
WinRemote/
├── AppScope/
│   └── app.json5                        # 应用级配置（bundleName、版本、图标）
├── entry/                               # HarmonyOS 应用主模块
│   ├── build-profile.json5              # 模块构建配置
│   ├── oh-package.json5                 # 模块依赖
│   └── src/main/
│       ├── module.json5                 # 模块配置（权限、Ability、页面路由）
│       └── ets/
│           ├── entryability/EntryAbility.ets     # 入口 UIAbility
│           ├── entrybackupability/EntryBackupAbility.ets
│           ├── model/RemoteProtocol.ets          # 协议：状态枚举/消息接口/指令构造
│           ├── pages/Index.ets                   # 主页面：状态机 + 响应式布局
│           ├── service/RemoteClient.ets          # WebSocket 客户端封装
│           └── view/
│               ├── ConnectPanel.ets              # 连接表单
│               └── ControlPanel.ets              # 画面 + 手势 + 虚拟键鼠 + 串流设置
├── server/                              # Windows 电脑端服务
│   ├── winremote_server.py              # 服务端主程序（单文件）
│   ├── selftest.py                      # 端到端协议自测
│   ├── requirements.txt                 # Python 依赖
│   ├── WinRemoteServer.spec             # PyInstaller 打包配置
│   └── dist/WinRemoteServer.exe         # 已打包的单文件服务端
├── dist/
│   └── WinRemote-1.0.0-tablet-api24-signed.hap   # 已构建签名的应用包
├── build-profile.json5                  # 工程级构建配置（签名、SDK 版本）
├── oh-package.json5                     # 工程级依赖
├── hvigorfile.ts                        # hvigor 构建脚本
├── code-linter.json5                    # 代码检查配置
└── LICENSE
```

## 许可证

见 [LICENSE](LICENSE)。
