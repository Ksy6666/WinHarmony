# WinRemote

**用 HarmonyOS 手机 / 平板，在局域网内远程遥控 Windows 11 电脑。**

WinRemote 由两部分组成：

- **电脑端服务**（`server/winremote_server.py`）：运行在 Windows 11 上的 Python 程序，通过 WebSocket 接收手机指令，注入鼠标 / 键盘操作，并把屏幕画面实时推送给手机。
- **手机端应用**（HarmonyOS App，本仓库主体）：连接电脑、显示电脑画面、提供触控板手势和虚拟键盘，让你用手机操控电脑。

整体是一个自研的轻量级"远程桌面 + 远程输入"方案，不依赖任何第三方远控服务，所有数据只在内网（局域网）中传输。

```
┌─────────────────────┐      Wi-Fi / 局域网       ┌───────────────────────────────┐
│  HarmonyOS 手机/平板 │ ◄────── WebSocket ──────► │  Windows 11 电脑              │
│  WinRemote App      │   控制指令 (JSON 文本帧)    │  winremote_server.py         │
│                     │   画面 (H.264 / JPEG 帧)   │  pynput 注入鼠标键盘          │
│  H.264 硬解 / JPEG  │   ack 回执 (渲染后发送)     │  WGC/mss 抓屏 → PyAV H.264   │
└─────────────────────┘                           │                    / JPEG 编码│
                                                    └───────────────────────────────┘
```

---

## 目录

1. [功能特性](#功能特性)
2. [技术栈](#技术栈)
3. [系统架构](#系统架构)
4. [通信协议](#通信协议)
5. [使用方法](#使用方法)
6. [详细制作过程](#详细制作过程)
7. [低延迟设计](#低延迟设计)
8. [实测数据](#实测数据)
9. [自测](#自测)
10. [常见问题 FAQ](#常见问题-faq)
11. [目录结构](#目录结构)

---

## 功能特性

- **双编码串流（连接时选择）**：连接成功后弹窗选择画面传输编码：
  - **H.264 硬编码**：服务端 PyAV 调用 Media Foundation / NVENC / x264 编码（自动降级），客户端 NDK `OH_VideoDecoder` 硬解 + XComponent Surface 直渲。带宽约为 JPEG 的 **1/20 ~ 1/60**（实测静止桌面 ~0.4KB/帧 vs JPEG ~23KB/帧），支持 2K 原生分辨率高帧率（实测 18fps），解码耗时 ~1ms；
  - **JPEG 兼容模式**：每帧独立、无参考依赖，网络波动不花屏，作为兜底方案。
  H.264 不可用时（服务端缺 PyAV 或客户端解码器创建失败）自动回退 JPEG。
- **渲染后回执（ack-on-render）**：H.264 模式下手机端**画面真正上屏后**才回执 ack，服务器据此发送下一帧——在途帧数恒为 1，从机制上杜绝真机硬解内部缓存帧导致的"越用延迟越大"（实测 1200 帧后渲染延迟稳定在 61~77ms 不增长）。
- **屏幕实时串流**：支持调节分辨率（原生 / 1920 / 1600 / 1280）、帧率（10~60fps）、画质（低 / 中 / 高），随时暂停 / 恢复。
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
- **安全**：可选共享令牌鉴权；不设置 token 时服务端会醒目警告。
- **单文件 exe**：服务端可用 PyInstaller 打包成免安装的 `WinRemoteServer.exe`，内置父进程看门狗，关闭窗口 / 杀掉进程后不残留后台。

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
| **PyAV ≥ 12.0.0** | H.264 编码（FFmpeg 绑定），编码器自动降级链：h264_mf → h264_nvenc → libx264，CBR + 1 秒周期性 IDR + zerolatency，输出 Annex B 裸流 |
| **numpy** | WGC 帧缓冲 BGRA→RGB 转换 |
| **asyncio + ThreadPoolExecutor** | 事件循环与专用抓屏/编码工作线程 |
| **ctypes（Win32 API）** | `GetSystemMetrics`（DPI 感知的屏幕尺寸）、进程完整性级别（判断是否管理员）、控制台事件处理 |
| **PowerShell 子进程** | 读取用户名、写剪贴板（`Set-Clipboard`，UTF-8，支持中文） |
| **PyInstaller** | 打包单文件 `WinRemoteServer.exe` |

### 手机端（HarmonyOS App）

| 技术 | 用途 |
|---|---|
| **ArkTS / ArkUI（声明式 UI）** | 全部界面：`@Entry @Component struct`、`@State / @Prop / @Link` 状态驱动、`@Builder` 拆分 UI |
| **@kit.NetworkKit（webSocket）** | WebSocket 客户端，文本帧收 JSON、二进制帧收 H.264 / JPEG |
| **@kit.ImageKit（image）** | `createImageSource` + `createPixelMap` 异步解码 JPEG 帧 |
| **NDK AVCodec（C++ 原生模块）** | `entry/src/main/cpp/video_decoder_napi.cpp`：`OH_VideoDecoder` H.264 硬解 + XComponent Surface 直渲（低延迟模式）。Annex B 解析：SPS/PPS 参数集拆分后作为 CODEC_DATA 单独推送、IDR 标记 SYNC_FRAME；真实微秒 pts 时间戳；`SetRenderCallback` 通过 napi_threadsafe_function 在**渲染完成后**回调 ArkTS 实现 ack-on-render |
| **@kit.PerformanceAnalysisKit（hilog）** | 日志与性能统计输出（含 `render delay` 渲染延迟指标） |
| **@kit.AbilityKit（UIAbility）** | 应用入口 `EntryAbility` |
| **TouchEvent（onTouch）** | 原始多点触控处理：单击 / 拖动 / 长按 / 双指滚轮手势识别 |
| **hvigor 构建体系** | HarmonyOS 工程构建（API 24 / SDK 6.1.1(24)，HarmonyOS 签名），CMake 编译 `libh264decoder.so` |

## 系统架构

### 总体分层

```
HarmonyOS App (entry 模块)
├── pages/Index.ets          # 入口页面：连接状态机 + 宽窄屏路由 + 编码选择弹窗
├── view/ConnectPanel.ets    # 连接表单（地址/端口/令牌）
├── view/ControlPanel.ets    # 控制台：画面渲染 + 手势 + 虚拟键鼠 + 串流设置
├── service/RemoteClient.ets # WebSocket 封装（连接/收发/错误翻译/ack 回执）
├── model/RemoteProtocol.ets # 协议常量：连接状态枚举、服务端消息接口、指令构造器
└── cpp/video_decoder_napi.cpp # H.264 硬解原生模块（OH_VideoDecoder → Surface 直渲）
    └── CMakeLists.txt         # 链接 libnative_media_vdec / codecbase / core 等

Windows 11 服务端 (server/winremote_server.py，单文件 ~960 行)
├── 输入后端      # pynput 键鼠注入；特殊键映射表；组合键 press/release 顺序
├── 协议分发      # dispatch()：move/moveto/click/scroll/key/combo/text/sysinfo/ping
├── 屏幕捕获      # ScreenCapturer：WGC → mss → Pillow 三级后端，专用线程
├── 编码          # encode_jpeg()：缩小 + JPEG；H264Encoder：PyAV h264_mf/nvenc/x264 降级链，Annex B 输出，GOP=1 秒
├── 传输          # Session 管理、stream_loop 帧推送循环（按 codec 分派）、ack 流控、发送锁
├── 生命周期      # install_exit_handler（控制台事件即退出）+ parent_watchdog（父进程死亡自杀）
└── CLI / 横幅    # argparse 参数、局域网 IP 列举、管理员权限检测与警告
```

### 手机端关键设计

- **状态机驱动 UI**：`ConnState`（Idle → Connecting → Connected → Closed/Error）决定显示 `ConnectPanel` 还是 `ControlPanel`；连接成功后由 `Index.ets` 弹出编码选择，用户选定后进入 `ControlPanel` 并以此初始化串流。
- **回调解耦**：`RemoteClient` 暴露 `onState / onMessage / onFrame` 三个回调，页面在 `aboutToAppear` 中挂载，`RemoteClient` 本身不持有任何 UI 引用。
- **双解码路径**（`ControlPanel.handleFrame()` 按 `codec` 分派）：
  - **JPEG**：`pendingFrame` 只保留最新一帧，解码循环 `decodeNext()` 串行解码，解码中又来新帧则**直接丢弃旧帧并计数**；每解码完一帧 `client.ack()` 回执。用"宁可丢帧、不可积压"把端到端延迟压到最低；
  - **H.264**：整包交给原生 `pushFrame`，由 C++ 侧解析 Annex B 并推入 `OH_VideoDecoder`；ArkTS 层**不做任何 ack**，ack 改在原生模块的**渲染完成回调**（`setRenderCallback`）中发送——画面上屏才算消费完成。
- **绝对坐标映射**：手机触点根据画面容器尺寸和电脑屏幕宽高比做 letterbox 换算，映射为 0~1 的归一化坐标发给服务器（`moveto`），规避两端 DPI / 分辨率差异。
- **手势识别**：用 `TAP_TOLERANCE_VP`（10vp）区分"轻触"与"拖动"，用 `LONG_PRESS_MS`（420ms）定时器实现长按左键，双指平均 Y 位移按档位累计成滚轮 notch 数。

### 服务端关键设计

- **单线程 asyncio 事件循环 + 1 个抓屏工作线程**：`CAPTURE_POOL` 是 `max_workers=1` 的线程池，`grab_jpeg()` 通过 `run_in_executor` 投递。抓屏和 JPEG 编码刻意放在同一线程——实测分离反而因 GIL 争用降低帧率。
- **三级抓屏后端**：
  1. **wgc**（`windows-capture` 包）：独立捕获线程回调交付帧（BGRA→RGB 一次拷贝），只在画面变化时产生帧，且在 PyInstaller 打包后依然可用；
  2. **mss**：GDI BitBlt，`mss` 实例绑定创建线程，因此用 `threading.local` 懒加载；
  3. **pillow**：`ImageGrab` 兜底。
  WGC 启动 10 秒内没有帧或回调报错会自动降级到 mss。
- **ack 流控**（`stream_loop`）：开启 ack 模式时，先**异步启动下一帧抓取**，再等待客户端回执（`asyncio.Condition`，超时 0.5s 放行）。信用式判断（`acks > base`）而不是精确对账，避免一次丢 ack 就把整条流卡死。JPEG 模式 ack 语义为"解码完成"，H.264 模式为"渲染完成"。
- **H.264 编码参数**：CBR 码率随分辨率 / 帧率估算，`tune=zerolatency` 关闭 B 帧，**GOP = 1 倍 fps**（每秒一个 IDR 关键帧，保证断流 / 丢包后 1 秒内画面恢复），Annex B 裸流输出。
- **参数热更新**：`stream_loop` 每轮循环重新读取 fps / quality / max_width，改设置无需重启推流任务。
- **UIPI 权限检测**：通过 Win32 令牌完整性级别（`TOKEN_INTEGRITY_LEVEL`）判断是否以管理员运行，启动横幅中明确警告——因为 Windows UIPI 会静默丢弃注入到提权窗口（任务管理器等）的输入。
- **进程退出保障**（打包 exe 场景）：PyInstaller onefile 是"父 bootloader + 子进程"结构，直接杀父进程会让子进程残留后台并占住端口。服务端内置双重保障：
  - `install_exit_handler()`：注册控制台事件（Ctrl+C / 关窗）处理，收到即 `os._exit(0)`；
  - `parent_watchdog()`：frozen 模式下每 3 秒轮询父进程存活，父进程死亡则自杀。
  实测：只杀父进程，子进程 3 秒内退出、端口释放。

## 通信协议

基于 WebSocket（默认端口 8765），**文本帧 = JSON 控制消息，二进制帧 = 屏幕画面（H.264 Annex B 裸流或 JPEG，由 stream 指令的 `codec` 字段决定）**。

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
| `stream` | `on, fps, quality, maxWidth, ack, codec` | 开关推流及参数；`codec`：`h264` / `jpeg`，h264 不可用时服务端回退 jpeg 并在回包中说明 |
| `ack` | — | 帧消费回执（流控；JPEG=解码完成，H.264=渲染完成） |
| `ping` | — | 心跳，服务端回 `pong` |

### 服务端 → 客户端消息

| t | 说明 |
|---|---|
| `hello` / `info` | 握手结果 / 电脑信息 |
| `streamState` | 推流状态确认（含 `screenW/screenH`，客户端据此计算画面宽高比；含 `ackMode`；含实际生效的 `codec`） |
| `textResult` | 文字发送结果 |
| `err` | 错误 |
| `pong` | 心跳回应 |
| （二进制帧） | H.264 Annex B 裸流 / JPEG 图像数据 |

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
> - 免 Python 环境使用：按下方[打包服务端为 exe](#打包服务端为-exe可选)章节自行打包（仓库不含 exe 成品，体积超过 GitHub 100MB 文件上限）。

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
3. 连接成功后弹出**编码选择**：选"H.264 硬编码"（推荐，带宽低、帧率高）或"JPEG 兼容模式"，进入控制面板开始接收画面。

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
   - 复杂指令（数组字段）用显式 class（`ComboPayload` / `TextPayload` / `StreamPayload` / `HelloPayload`）+ 显式字段初始化，再 `JSON.stringify`。`StreamPayload` 含 `codec` 字段用于选择编码。

### 阶段三：封装 WebSocket 客户端（service 层）

新建 `entry/src/main/ets/service/RemoteClient.ets`，用 `@kit.NetworkKit` 的 `webSocket.createWebSocket()`：

1. `connect(host, port, token)`：先 `disconnect()` 防重入，拼 `ws://host:port`，注册 `open / message / close / error` 四个事件；
2. **事件语义**：
   - `open` → 上报 Connected 并发送 `hello`（带 token）和 `sysinfo`；
   - `message` → 字符串走 `JSON.parse` 解析为 `ServerMessage` 交给 `onMessage`；`ArrayBuffer` 是视频帧直接交给 `onFrame`（WebSocket 的消息事件天然区分文本 / 二进制帧，正好承载双通道协议）；
   - `close / error` → 清理 socket 引用并上报状态，注意用"闭包中的 socket 与成员变量比对"防止旧连接的迟到回调污染新连接；
3. **错误翻译**：`describeError()` 把 `err.code === 200`（非 WS 服务）等系统错误码翻译成用户能看懂的中文提示；
4. **ack 回执**：收到 `streamState.ackMode === true` 时进入 ack 模式，`ack()` 方法仅在 ack 模式下发送 `{"t":"ack"}`，避免无谓流量；
5. 所有日志走 `hilog`（DOMAIN 0x0000，TAG `WinRemote`），每条发出的指令带 `CMD -> {...}` 日志便于联调。

### 阶段四：连接页面（ConnectPanel）

新建 `entry/src/main/ets/view/ConnectPanel.ets`（`@Component struct`）：

1. `@Link host / port / token` 双向绑定输入框，`@Prop statusText / busy` 接收页面状态；
2. 深色主题样式（背景 `#0B1020`），表单居中，最大宽度 560vp，`Scroll` 包裹防止小屏溢出；
3. 状态行用绿 / 红圆点 + 文本提示连接进度与错误。

### 阶段五：主页面状态机与响应式布局（Index）

`entry/src/main/ets/pages/Index.ets`（`@Entry`）：

1. 持有 `host / port / token / connState / statusText / infoText / isWide / screenRatio` 等 `@State`，`RemoteClient` 作为普通成员（非状态变量）；
2. `aboutToAppear` 挂载 `onState / onMessage` 回调；`onMessage` 中按 `t` 分发：`hello/info` 组装电脑信息文本（记录屏幕宽高），`streamState` 记录屏幕宽高比（供画面 letterbox 用），`err` / `textResult` 更新状态提示；
3. 连接成功后弹出**编码选择弹窗**（H.264 / JPEG 两张卡片），用户选定后把 `codec` 传给 `ControlPanel`；
4. `build()` 中按 `connState` 切换 `ConnectPanel` / `ControlPanel`；
5. `onAreaChange` 监听页面宽度，≥600vp 记为宽屏（平板分栏布局）；
6. `onBackPress()`：已连接时返回键先断开连接，再退出应用。

### 阶段六：控制面板与手势（ControlPanel，工作量最大）

新建 `entry/src/main/ets/view/ControlPanel.ets`：

1. **帧接收与解码**：`aboutToAppear` 挂载 `client.onFrame` 并发送 `stream on`（携带 codec）；`handleFrame()` 按 codec 分派：
   - **JPEG 路径**：统计到达间隔 / 字节数，若正在解码则丢弃旧帧（`statsDropped++`），始终保留最新帧到 `pendingFrame`；`decodeNext()` 串行解码，`image.createImageSource(data)` → `createPixelMap()` → 更新 `@State frame` → 释放旧 PixelMap 与 ImageSource（**内存管理必须严谨，否则几秒内泄漏爆内存**）→ 每帧解码完 `client.ack()`；
   - **H.264 路径**：整包二进制直接交原生模块 `h264.pushFrame(data)`，ArkTS 层不 ack；先注册 `h264.setRenderCallback()`，原生模块在**每帧渲染上屏后**回调 `onRendered()` → `client.ack()`；
   - `reportStats()`：每 20 帧输出一次解码耗时 / 实际 fps / 丢帧 / 平均帧大小到 hilog，用于调优。
2. **画面渲染**：
   - JPEG：`Image(this.frame).objectFit(ImageFit.Contain)` + `interpolation(Low)`；
   - H.264：`XComponent`（type Surface）+ 原生硬解直渲，`onLoad` 后取 `surfaceId` 再创建解码器；
   - `onAreaChange` 记录容器尺寸 `padW / padH`。
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

### 阶段七：编写 H.264 原生解码模块（C++ / NDK）

新建 `entry/src/main/cpp/video_decoder_napi.cpp`，CMake 编译为 `libh264decoder.so`：

1. **解码器创建**（`createDecoder(surfaceId, w, h)`）：`OH_VideoDecoder_CreateByMime("video/avc")` → `OH_AVFormat` 设置宽高 → `SetSurface`（XComponent 的 surfaceId，输出即渲染不重排）→ 低延迟模式（`OH_MD_KEY_REQUEST_LOW_LATENCY`，可用时）→ `Start`；
2. **Annex B 解析**（`ParseAnnexB`）：扫描起始码（00 00 01 / 00 00 00 01）切出 NAL，按类型分派：
   - **SPS(7) / PPS(8)**：缓存参数集，作为**独立 buffer 标记 CODEC_DATA** 先于切片推送——硬解规范要求参数集单独成包，整包混推会导致真机解码器无输出（本项目实测踩过的黑屏坑）；
   - **IDR(5)**：标记 `SYNC_FRAME`；
   - 其余切片：正常帧；
3. **真实 pts**：每帧入队时用 `NowUs()`（微秒单调时钟）赋 pts。**不要用 0,1,2 假序号**——真机呈现引擎会按 pts 调度输出，假 pts 会造成播放异常；
4. **渲染回调**（`setRenderCallback`）：用 `napi_create_threadsafe_function` 创建跨线程回调，`OnOutputBufferAvailable` → 渲染完成后（`RenderOutputBuffer` 返回）在解码线程调用， ArkTS 侧收到即发送 ack——这就是 ack-on-render 的客户端半边；
5. **渲染延迟统计**：输出渲染完成时对比该帧 pts 打印 `render delay: Xms`，是端到端延迟的核心观测指标；
6. **链接库**：`libnative_media_vdec.so`（解码器）、`libnative_media_codecbase.so`（`OH_MD_KEY_*` 宏）、`libnative_media_core.so`（`OH_AVBuffer` / `OH_AVFormat`）、`libace_napi.z.so`、`libhilog_ndk.z.so`——缺一都会链接失败，宏和类型分属不同 so 是隐蔽的坑；
7. **类型声明**：`types/libh264decoder/index.d.ts` 导出 `createDecoder / pushFrame / releaseDecoder / setRenderCallback`，ArkTS 侧 `import h264 from 'libh264decoder.so'`。

### 阶段八：编写 Windows 服务端

新建 `server/winremote_server.py`（单文件，约 960 行）：

1. **依赖与入口**：`argparse` 解析 `--host/--port/--token/--quiet`；`sys.platform != "win32"` 直接拒绝（输入注入依赖 Win32 API）；缺依赖时给出精确的 `pip install` 提示；
2. **输入注入层**：
   - `pynput` 的 `KeyboardController / MouseController` 全局实例；
   - `SPECIAL_KEYS` 映射表：enter/esc/tab/backspace/delete/space/方向键/F1~F12/win/ctrl/alt/shift 等 → `pynput.keyboard.Key`；
   - `press_combo()`：按序按下所有修饰键 → 按下主键 → 抬主键 → 逆序抬修饰键；
   - `type_text()`：纯 ASCII 走 `keyboard.type()`；含 CJK 则 `set_clipboard()`（PowerShell `Set-Clipboard`，UTF-8 编码，`CREATE_NO_WINDOW` 防闪窗）后 `Ctrl+V`；
   - `screen_size()`：`SetProcessDPIAware()` + `GetSystemMetrics` 拿物理分辨率；
   - 指令日志：click/scroll/key 全量记录，move/moveto 每 50 条抽 1 条。
3. **UIPI 检测**：`own_integrity_rid()` 用 ctypes 走 `OpenProcessToken → GetTokenInformation(TOKEN_INTEGRITY_LEVEL)`，解析 TOKEN_MANDATORY_LABEL SID 的最后一个 sub-authority 得到完整性级别（≥0x3000 即管理员）；
4. **抓屏层 `ScreenCapturer`**：
   - 构造时探测可用后端：`import windows_capture` 成功选 **wgc**，否则 `import mss` 选 **mss**，再否则 **pillow**；
   - WGC：`WindowsCapture(cursor_capture=False, draw_border=False, monitor_index=1)`，`on_frame_arrived` 回调里 `np.asarray(frame.frame_buffer)`（BGRA，仅回调内有效）→ `array[:, :, 2::-1]` 一次通道翻转 → 拷贝成 PIL Image 存入带锁成员；`start_free_threaded()` 独立线程运行；10 秒启动宽限期内无帧或回调异常 → `_use_fallback()` 降级 mss；
   - mss：`threading.local` 保存实例（mss 与创建线程绑定），专用线程上懒创建；
   - `grab()` 统一入口，返回 PIL Image。
5. **编码层**：
   - `encode_jpeg`：`max_width` 缩小——先算整数因子，若 2 的幂且误差 ≤2px 用 `image.reduce(factor)`（比通用 `resize` 快约 6 倍）；否则用 BOX（面积平均，正确的缩小滤波，又比 BILINEAR 快约 30%）；JPEG `save` 到 `BytesIO`，`optimize=False` 换速度；
   - `H264Encoder`：PyAV `av.CodecContext`，编码器名依次尝试 `h264_mf` → `h264_nvenc` → `libx264`；`gop_size = fps`（1 秒一个 IDR）、`tune=zerolatency`（无 B 帧）、CBR 码率按像素面积估算、`bit_rate_tolerance` 压低、time_base 1/fps、pix_fmt yuv420p（BGR0 需 swscale 转换）；输出 Annex B 裸流字节。
6. **执行模型**：`CAPTURE_POOL = ThreadPoolExecutor(max_workers=1)`，抓屏+JPEG 编码整体用 `run_in_executor` 投到该线程（刻意不拆开，GIL 争用下拆开反而更慢）；H.264 编码在独立线程池执行。
7. **会话与推流**：
   - `Session`：鉴权标志、推流参数、ack 计数（`asyncio.Condition`）、发送锁（`asyncio.Lock`，防止 JSON 与二进制帧交错写坏消息边界）；
   - `stream_loop()`：循环 = 先发起下一帧抓取 future →（ack 模式下）等待客户端回执（信用式 `acks > base`，超时 0.5s 放行，保证不卡死）→ await 帧 → 按 codec 编码 → `send_frame` 二进制发送 → 按 fps 计算剩余睡眠；每轮重读参数实现热更新；
   - `handle_client()`：连上先发 hello/needToken → 逐条收消息：hello 鉴权（失败回 err 并以 4001 关闭）、ack 计数、stream 开关 + 参数 clamp（fps 1~60、quality 10~95、maxWidth 320~3840 或 0=原生）并回 `streamState`（含实际 codec / ackMode / screenW/H）、其余交给 `dispatch()` 执行并按需回包；断开时 `stop_stream()`。
8. **生命周期保障**：
   - `install_exit_handler()`：`SetConsoleCtrlHandler` 捕获 Ctrl+C / 关闭事件，立即 `os._exit(0)`，避免 websockets 优雅关闭流程卡住；
   - `parent_watchdog()`：`sys.frozen` 时每 3 秒 `OpenProcess` 探测父进程，死亡即自杀——解决 PyInstaller onefile"杀父留子"的后台残留问题。
9. **启动横幅 `print_banner`**：枚举局域网 IPv4（先 `getaddrinfo(hostname)`，失败则 UDP connect 8.8.8.8 探测法），打印屏幕 / 后端 / 权限 / 端口 / 地址列表；非管理员时给出醒目的 UIPI 警告与解决方法。

### 阶段九：联调与迭代（真机踩坑记录）

1. 手机 / 模拟器与电脑同网，启动服务端 → App 输入 IP 连接 → 验证握手、信息显示、编码选择；
2. 用 `hilog`（TAG `WinRemote` / `WinRemoteH264`）观察解码耗时 / fps / 丢帧 / **render delay** 统计，服务端看帧耗时与编码器日志；
3. 按实测调整默认参数：fps 20、quality 70、maxWidth 1280；
4. 针对发现的问题迭代（每一条都是真实踩坑）：
   - 延迟越拖越大 → ack 流控 + 客户端丢帧解码（JPEG）；
   - **真机 H.264 延迟远大于 JPEG** → ack 发生在"入队"而非"渲染"，真机硬解内部缓存多帧导致延迟无限累积 → 重构为 ack-on-render（`SetRenderCallback`）+ GOP 缩到 1 秒，实测延迟稳定 61~77ms 不再增长；
   - **真机 H.264 黑屏（模拟器正常）** → `DetectFlags` 曾把 SPS+PPS+IDR 整包标 CODEC_DATA，硬解无输出 → 改为 `ParseAnnexB` 扫描全部 NAL，参数集单独成包；
   - **真机 pts 相关播放异常** → 假 pts（0,1,2）被真机呈现引擎按时间戳调度 → 改为真实微秒 pts；
   - 打包 exe 后黑屏 → 从 DXGI 复制换成 WGC 后端（COM 初始化在 PyInstaller 下不可靠）；
   - 打包 exe 缺 FFmpeg DLL → spec 加 `collect_dynamic_libs('av')`；
   - **exe 关窗后残留后台占端口** → PyInstaller onefile 父子进程结构 + Windows Terminal 伪窗口 → 控制台事件处理 + 父进程看门狗双保险；
   - 中文输不进去 → 剪贴板 + Ctrl+V 通道；
   - 提权窗口遥控失灵 → 完整性级别检测 + 横幅警告。

### 阶段十：构建与分发

1. **构建 HAP**：DevEco Studio `Build → Build Hap(s)`，或命令行 hvigor 打包；签名后产物同步到 `dist/WinRemote-1.0.0-tablet-api24-signed.hap`，用 DevEco Studio 或 `hdc install` 安装到设备；
2. **构建 exe**：编写 `server/WinRemoteServer.spec`，关键点：
   - `hiddenimports = ['pynput.keyboard._win32', 'pynput.mouse._win32', 'mss.windows']`（这些是运行时动态导入的 Win32 后端，PyInstaller 静态分析找不到）；
   - `collect_submodules('mss')` 兜底收集 mss 全部子模块；
   - `collect_dynamic_libs('av')` 打包 PyAV 附带的 FFmpeg DLL（缺了 H.264 编码直接不可用）；
   - `console=True`（保留控制台窗口，用户需要看 IP 横幅）；
   - 单文件 EXE（`runtime_tmpdir=None`），产物 `server/dist/WinRemoteServer.exe`；
3. **编写自测**：`server/selftest.py` 端到端回环测试（见下节）。

## 低延迟设计

本项目在延迟上做了端到端的针对性设计，是最大的工程亮点：

1. **客户端丢帧解码**（JPEG）：解码永远只处理"最新一帧"，旧帧直接丢弃。低配设备解码慢时表现为帧率下降，但**延迟不增长**。
2. **ack-on-render 流控**（H.264）：ack 在**画面真正渲染上屏后**（原生模块渲染回调）才发送，服务器见 ack 才发下一帧——在途帧数恒为 1。相比"入队即 ack"，即使真机硬解内部缓存多帧，延迟也不会累积，只是帧率略降；且下一帧抓取与等待回执**并行**，隐藏编码耗时。
3. **真机硬解规范**：SPS/PPS 参数集单独作为 CODEC_DATA 推送 + IDR 标记 SYNC_FRAME + 真实微秒 pts，保证硬解码器与呈现引擎按预期即时输出。
4. **编码端零延迟**：`tune=zerolatency` 关闭 B 帧、CBR 恒定码率、GOP 1 秒（丢包后快速恢复、画质周期性刷新）。
5. **抓屏后端分级**：WGC 在独立线程零拷贝交付，只在画面变化时产帧，服务线程只付编码成本；失败自动降级，保证开箱即用。
6. **缩放算法选型**：整数倍用 `reduce()`（约 6× 速度），一般缩小用 BOX 滤波（正确且约 30% 速度优势），`optimize=False` 关闭 JPEG 优化换编码速度。
7. **单工作线程**：抓屏 + JPEG 编码同线程，避免 GIL 争用把帧率腰斩。
8. **触摸 → 指令直发**：拖动事件直接换算 `moveto` 归一化坐标发送，不做客户端节流（WebSocket / 局域网吞吐足够），指针跟随手感更好。
9. **可观测性**：客户端 `STATS` 日志（每 20 帧：decodeAvg / decodeMax / gapAvg / fps / dropped / kb）+ 原生模块 `render delay: Xms`（每 120 帧采样），延迟问题可以精确定位到解码端还是渲染端还是网络端。

## 实测数据

测试环境：Windows 11（2560×1440，WGC 抓屏）+ HarmonyOS 6.1.1 平板模拟器 / 真机，同一 Wi-Fi 局域网。

| 指标 | H.264 硬解 | JPEG |
|---|---|---|
| 带宽（静止桌面） | ~0.4 KB/帧 | ~23 KB/帧（约 60 倍） |
| 客户端解码耗时 | ~1ms（硬解） | ~50ms（软解） |
| 实际帧率 | 16~18fps | ~15fps |
| 渲染延迟（render delay） | 61~77ms，1200 帧后仍稳定 | （无此指标，丢帧保延迟） |
| 画质 | 2K 原生分辨率 | 受 JPEG 压缩限制 |

服务端 `selftest.py` 25 项端到端检查全部通过。

## 自测

服务端附带端到端自测 `server/selftest.py`，会启动真实服务（端口 8799）并用 WebSocket 客户端回环验证协议，**只使用非破坏性命令（零位移 move / scroll），不会动你的真实鼠标键盘**：

```powershell
cd server
py selftest.py
```

覆盖项：token 公告与校验（错 token 拒绝并断开）、hello / sysinfo / ping 回包、空 text 回执、非法 JSON 与未知命令的 err 回包、真实抓屏推流（校验 JPEG 魔数 `FF D8`）、stream 开关确认、H.264 编码器可用性与降级链、按键名解析表等。

## 常见问题 FAQ

**Q：连不上 / 提示"该端口不是 WebSocket 服务"？**
确认服务端已启动且端口一致；检查 Windows 防火墙是否放行（首次运行弹窗要勾选"专用网络"）；确认手机和电脑在同一网段；地址要用服务端横幅打印的内网 IP，不是 `localhost`。

**Q：画面卡 / 帧率上不去？**
优先选择 H.264 编码（带宽和解码开销都远低于 JPEG）；抓屏是瓶颈（GDI 后端约 40~70ms/帧），优先安装 `windows-capture` 启用 WGC 后端（横幅 `Capture: wgc`）；降低分辨率 / 帧率 / 画质；关闭其他占用 GPU 的程序。

**Q：H.264 和 JPEG 怎么选？**
日常使用选 H.264：带宽约为 JPEG 的 1/60，手机端硬解仅 ~1ms，且采用渲染后回执（ack-on-render）流控，延迟稳定不累积。JPEG 模式每帧独立、无参考依赖，网络剧烈波动时不花屏，可在 H.264 异常时兜底。H.264 需要服务端安装 `av`（`pip install av`），缺失时自动回退 JPEG。

**Q：H.264 画面黑屏 / 延迟越来越大？**
本项目已修复两类典型问题：① 参数集与切片整包混推导致真机硬解黑屏（现参数集单独成包）；② 入队即 ack 导致真机硬解缓存帧延迟累积（现渲染上屏后才 ack）。若仍异常，用 `hilog | grep WinRemoteH264` 抓 `render delay` 日志排查。

**Q：遥控任务管理器等管理员窗口时鼠标键盘"失灵"？**
Windows UIPI 限制。右键以管理员身份重启服务端（横幅会检测并警告）。

**Q：怎么输入中文？**
用控制面板的文字输入框发送（服务端自动走剪贴板 + Ctrl+V）。直接逐键模拟无法输入中文。

**Q：关掉 exe 窗口后端口还被占用 / 进程残留后台？**
已修复：服务端内置控制台事件处理 + 父进程看门狗，关窗 / 杀进程后子进程 3 秒内自动退出。若遇残留，任务管理器结束 `WinRemoteServer` 进程即可。

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
│       ├── cpp/                         # C++ 原生 H.264 解码模块（libh264decoder.so）
│       │   ├── CMakeLists.txt           # 链接 vdec / codecbase / core / napi / hilog
│       │   ├── video_decoder_napi.cpp   # OH_VideoDecoder 硬解 + Surface 直渲 + 渲染回调 NAPI
│       │   └── types/libh264decoder/    # NAPI 类型声明（含 setRenderCallback）
│       └── ets/
│           ├── entryability/EntryAbility.ets     # 入口 UIAbility
│           ├── entrybackupability/EntryBackupAbility.ets
│           ├── model/RemoteProtocol.ets          # 协议：状态枚举/消息接口/指令构造
│           ├── pages/Index.ets                   # 主页面：状态机 + 编码选择 + 响应式布局
│           ├── service/RemoteClient.ets          # WebSocket 客户端封装
│           └── view/
│               ├── ConnectPanel.ets              # 连接表单
│               └── ControlPanel.ets              # 画面 + 手势 + 虚拟键鼠 + 串流设置
├── server/                              # Windows 电脑端服务
│   ├── winremote_server.py              # 服务端主程序（单文件）
│   ├── selftest.py                      # 端到端协议自测
│   ├── requirements.txt                 # Python 依赖
│   └── WinRemoteServer.spec             # PyInstaller 打包配置
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
