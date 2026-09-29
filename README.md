# 手机上的硬件加速 Linux 桌面

**简体中文** | [English](docs/en/README.md)

---

把一台 Android 手机变成能跑 **GPU 硬件加速 XFCE 桌面**的 Linux 机器：Termux 宿主 + proot Ubuntu 24.04 容器，**VNC 与 Termux:X11 两套显示同时在线**，OpenGL 走 Adreno KGSL 原生路径（不经 zink 翻译），Vulkan 走 Turnip。

这个仓库不是驱动本身，而是**驱动之上那一层**：显示服务怎么起、GPU 环境变量怎么配、Electron 应用为什么看不到显卡、以及怎么让这些改动在 `apt upgrade` 和应用商店更新之后依然活着。

> [!NOTE]
> 所有结论都来自 **Redmi K90（标准版）** 实测，不是照抄文档。跑不通的地方在「[已知问题](#已知问题)」里如实写明，没有藏。

---

## 特性

- **双显示并存** —— `:1` TigerVNC（可后台常驻、可远程接入）与 `:2` Termux:X11（本地低延迟直出）各自独立会话、独立 D-Bus 总线，互不干扰，可同时开两套桌面。
- **Adreno 原生 OpenGL** —— `MESA_LOADER_DRIVER_OVERRIDE=kgsl` 直出，省掉 zink 的 GL→Vulkan 翻译开销。
- **Turnip Vulkan** —— Adreno 8xx 上可用；VNC 侧 swapchain 的绕法见下文。
- **Electron 全版本 GPU 通用解法** —— 本仓最独特的部分。用 `LD_PRELOAD` 补出 Chromium 需要的 PCI 设备枚举，再**按 Chromium 大版本自动分档**下参数，一套脚本覆盖市面上各版本 Electron 应用。
- **用户级防更新覆盖** —— 改动一律落在 `~/.local/lib/` 与 `~/.config/`，`/usr/local/bin` 只放软链。`apt upgrade`、应用商店自更新都冲不掉，删掉对应目录即完全回退，绝不动 dpkg 管辖的文件。
- **一键部署** —— 宿主侧与容器侧分两段脚本，新机器照着跑即可重建。

---

## 兼容性

| 设备 | SoC | GPU | 容器 | OpenGL | Vulkan | 备注 |
| :-: | :-: | :-: | :-: | :-: | :-: | :-- |
| **Redmi K90（标准版）** | 骁龙 8 Elite | **Adreno 830v1** | proot Ubuntu 24.04 | ✔ kgsl 原生 | ✔ Turnip | 本仓全部结论的来源(2026-09 在用; GPU 型号取自 glxinfo/vulkaninfo 实测) |
| **Redmi K60** | 骁龙 8+ Gen 1 | **Adreno 725** | proot Ubuntu 24.04 | ✔ zink | ✔ Turnip | 早期形态，配方已不同，见下 |

> [!IMPORTANT]
> **K60 时代的老配方在 Adreno 830 上是错的。** 当年 VNC 侧靠「zink 四件套 + `-rendernode /dev/kgsl-3d0` + `+iglx`」，现在 kgsl 后端成熟后应当直起 `Xvnc` 并走 kgsl 原生路径。仓库里的脚本注释保留了两代配方的对照，迁移时按注释走，别把旧变量原样抄过来。

驱动本身请用 [**lfdevs/mesa-for-android-container**](https://github.com/lfdevs/mesa-for-android-container) 的 Release，本仓不重复造。

---

## 宿主侧：Termux 与 Termux:X11

这一段的坑比容器内多，且几乎没有文档。

### ZeroTermux 自签名的连锁后果

本项目（Redmi K90（标准版））宿主用的是 **ZeroTermux**（Termux 的第三方分支）。它用自己的签名打包，于是：

> [!WARNING]
> **官方 Termux 插件一律装不上**，报 `INSTALL_FAILED_SHARED_USER_INCOMPATIBLE (-8)`。
> 因为 Termux 系插件与主程序共享 `sharedUserId`，Android 要求两者签名一致。官方 Termux:X11 APK 是官方签名，ZeroTermux 是自签名，**签名不匹配 → 系统直接拒装**，这与 APK 本身是否损坏无关。

对策二选一：

1. 用 ZeroTermux 自己分发的配套插件（签名一致）；
2. 整套换回官方 Termux，再装官方 Termux:X11。

**不要**试图用 `adb install -r`、降级安装或改包名绕过——`sharedUserId` 的签名校验在包管理器层，绕不过去。

### 启动脚本落在哪

宿主侧入口 `start.sh` **必须放在 Termux 家目录**（容器外），因为它的职责就是把容器拉起来。容器内那份是副本，**两份会随时间漂移**——本项目就踩过：容器内副本 3922 字节、宿主真身 9033 字节，改错了那份，结果 1M 上下文头的配置怎么改都不生效。

`termux/01-termux-bootstrap.sh` 里加了**自愈软链**：每次启动都检查宿主家目录下的脚本是否指向容器内的规范版本，不一致就 `ln -sf` 重建，从根上消除"改了副本"这类问题。

### Termux:X11 侧的显示

`files/vnc/startx11` 负责拉起 `:2`：清理陈旧 X socket、起 `termux-x11`、起独立 D-Bus 会话总线、起 XFCE，最后同步光标设置。脚本里有一道曾经存在的 `xdpyinfo` 探活门**已被移除**——实测它从没拦到真问题，反而会把正常的桌面误判成失败挡掉。

---

## GPU

### 基本环境变量

```bash
MESA_LOADER_DRIVER_OVERRIDE=kgsl     # OpenGL 走 Adreno 原生, 不经 zink
```

### VNC 侧 Vulkan swapchain

`:1` 上 Vulkan 程序建 swapchain 会失败，根因是所用 Xvnc 缺少 `miSyncShmScreenInit`（DRI3/同步扩展初始化）。

打过补丁的 Xvnc 能修好，但实测**整体慢 3.4 倍**，不划算。当前采用的绕法是让 WSI 走软件路径：

```bash
MESA_VK_WSI_DEBUG=sw
```

Vulkan 计算与离屏渲染仍是硬件，只有呈现这一步软件化，代价远小于换 Xvnc。

---

## Electron 应用的 GPU：按版本分档

这是本仓最花力气的部分。

### 问题

proot 容器里**没有 PCI 设备节点**。Chromium 的 GPU 进程启动时要枚举 PCI 设备来识别显卡，枚举为空就直接判定"无 GPU"，于是无论传什么 `--use-gl` 参数都回落到软件渲染。

### 解法

`files/local-lib/electron-shim/fakepci.c` 用 `LD_PRELOAD` 拦截设备枚举，伪造出一条 Adreno 条目让 Chromium 认下去，随后它就会正常打开 `/dev/kgsl-3d0`（可在 GPU 进程里看到 `kgsl` fd）。

> [!TIP]
> aarch64 上写这类 shim，**务必 `#include <stdlib.h>`**。少了它，`getenv` 被当成返回 `int` 的隐式声明，64 位指针会被截成 32 位，表现是"读到的环境变量是乱码"，而且只在 arm64 上复现。

### 版本分档表

Chromium 各代对 `--use-gl` 的实现允许列表不同，一套参数不可能通吃。`files/desktop-env/electron-gpu.sh` 会读出应用自带的 Chromium 大版本（结果按 `路径|大小|mtime` 的 md5 缓存），自动选档：

| Chromium 主版本 | 档位 | 参数策略 | 实测结果 |
| :-: | :-: | :-- | :-- |
| **≤ 144** | `kgsl` | 不传 `--use-gl`，加 `--ignore-gpu-blocklist` | ✔ 真实硬件 GL，GPU 进程持有 kgsl fd |
| **≥ 145** | `swsafe` | 同上，另加 `--enable-unsafe-swiftshader` | SwiftShader 软渲染，稳定不崩 |
| **识别不出** | `safe` | 不传 `--use-gl`，加 `--ignore-gpu-blocklist` | 跟随 Chromium 自身判定 |

另有 `off` / `full` / `egl` 三档供手动排障。`ELECTRON_FAKEPCI=0` 可临时关掉 shim。

> [!CAUTION]
> **`--use-gl=egl` 看着人畜无害，实际有害。** 在 Chrome 120 上加了它，反而从真实硬件掉到 SwiftShader，并伴随 3 次崩溃。所以 `safe` 档的正解是**什么都不传**，让 Chromium 自己选。
>
> 另外 Chrome ≥ 125 起，软件渲染必须显式加 `--enable-unsafe-swiftshader`，否则直接拒绝启动软件后端。

---

## 用户级防更新覆盖

本项目的硬性约定，所有改动遵守：

| 放什么 | 放哪 | 为什么 |
| :-- | :-- | :-- |
| 脚本/shim 本体 | `~/.local/lib/<名>-shim/` | dpkg 不管这里，更新冲不掉 |
| 可执行入口 | `/usr/local/bin/<名>` → **软链** | 保持 PATH 可达，同时本体可随时替换 |
| 配置 | `~/.config/<名>/` | 同上，且删目录即完全回退 |

> [!WARNING]
> 写备份/采集脚本时注意：**`[ -f "$f" ]` 会跟随软链**。想跳过软链必须先 `[ -L "$f" ] && continue`，否则会把软链指向的真实文件（可能在 `/opt` 下、可能含敏感内容）一并收走。这个坑本项目踩过。

---

## 光标：为什么滑块拖到 48 以上没反应

XFCE「设置 → 鼠标 → 光标大小」在 Redmi K90（标准版） 上怎么拖都不变大。用 XFIXES `GetCursorImage` 读出实际像素才定位到双重原因：

1. **主题没有大图。** 本机装的四个光标主题（vintage / Adwaita / bloom / bloom-dark）内含图最大只有 **48px**，`XcursorLibraryLoadImage` 请求 64/96/128 一律回落 48。实测各档位：vintage `[24,32,48]`、bloom `[24,36,48]`、Adwaita `[24,32,48,64,96]`。
2. **`xfsettingsd` 不写 xrdb。** 它只管 XSETTINGS（GTK 应用读这个），不写 `Xcursor.*` 资源；而桌面根窗的光标是会话启动时定死的，改 xfconf 不会重设。
3. **两个 display 的 `xfconfd` 抢刷同一份 `xsettings.xml`。** 两套显示各有一个 xfconfd，都读写 `~/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml`，谁后写谁赢。更隐蔽的是 D-Bus：输入法脚本 autolaunch 出来的会话总线和 XFCE 全家用的不是同一条，于是系统里跑着两个 xfconfd。判据是 `_DBUS_SESSION_BUS_SELECTION_root_*` 这个 X 属性的 owner 指向谁 —— 修好后全系统 xfconfd 计数应为 1。
4. **`~/.icons/default/index.theme` 把回落链的根钉死了。** 这条最容易漏：它通常写着 `Inherits=<某个小主题>`，于是**任何主题里缺的光标名都掉到这里**拿 ≤48 的图，或者干脆找不到而退回 X 核心字体光标（固定小号）。所以"换了 hidpi 主题，还是有些光标不变大"就是这条。把它也改成 `Inherits=<你的 hidpi 主题>`。
   > 补完这条之后，连 Adwaita 请求 96 时 `left_ptr`/`default`/`pointer`/`text`/`xterm`/`watch`/`hand2`/`top_left_corner` 都能给到 96×96（补之前 `left_ptr` 只有 48，后三个完全找不到）—— 也就不必给每个主题都生成 hidpi 版。

对应两个工具：

- `tools/make-hidpi-cursor.py` —— 纯标准库，把主题内最大那档最近邻放大，生成含 24/32/48/64/96/128 六档的新主题到 `~/.icons/`。用最近邻而非插值，因为光标是硬边像素画，插值会糊边。
- `files/desktop-env/cursor-sync.sh` —— 读 xfconf → 写 xrdb → `xsetroot` 重设根窗光标。**只读 xfconf、不设 `XCURSOR_*` 环境变量**，这样 GUI 始终是唯一真源，不架空原生设置界面。

```bash
tools/make-hidpi-cursor.py vintage vintage-hidpi 24,32,48,64,96,128
files/desktop-env/cursor-sync.sh :1 :2
```

> [!NOTE]
> **改完大小要动一下鼠标**（移到桌面空白处再移回窗口）。已在指针下的窗口不会原地变 —— GDK 只更新 `GdkCursor` 对象，要等下一次 enter 事件触发 `gdk_window_set_cursor` 才把新 XID 挂上去。单变量实验 4/4：原地不动 3 秒不变，跨出跨回立刻变。这是 GTK/GDK 固有行为，不是配置问题；根窗/桌面是 0.2 秒立刻变的。

配套还需要一个**常驻看守**（`cursor-watch.sh`）：`cursor-sync.sh` 只在会话启动时跑一次，用户在 GUI 里改完就没人再同步了。看守监听 xfconf 变更，变化时对该 display 重新同步一次。

---

## 仓库内容

本仓只放**通用、可直接搬走复用**的部分。完整的一键部署脚本、各应用包装、这台 K90 的 `.desktop` 与包清单属于私人订制，不在这里。

```
README.md                                  全部实测结论(本仓主体)
files/desktop-env/
  gpu.sh                                   GPU 环境变量(kgsl / Turnip / WSI)
  electron-gpu.sh                          Electron 按 Chromium 版本自动分档
  cursor-sync.sh                           xfconf → xrdb → 根窗光标 同步
files/local-lib/electron-shim/
  fakepci.c                                LD_PRELOAD 伪造 PCI 枚举(核心)
tools/
  make-hidpi-cursor.py                     生成多档尺寸光标主题(纯标准库)
files/icons/
  README-光标主题重建.txt                    光标主题重建说明
```

> [!NOTE]
> 上面这些脚本可以单独拿走用，彼此不强耦合。`electron-gpu.sh` 与 `fakepci.c` 要配套；`cursor-sync.sh` 与 `make-hidpi-cursor.py` 要配套。

---

## 怎么用

```bash
# 1. 编译 fakepci
gcc -shared -fPIC -o fakepci.so files/local-lib/electron-shim/fakepci.c

# 2. GPU 环境
source files/desktop-env/gpu.sh

# 3. 拉起某个 Electron 应用(自动识别版本选档)
files/desktop-env/electron-gpu.sh /path/to/app

# 4. 光标: 先造大图主题, 再同步到 X 层
tools/make-hidpi-cursor.py vintage vintage-hidpi 24,32,48,64,96,128
files/desktop-env/cursor-sync.sh :1 :2
```

## 视频播放：黑帧的真凶是缺围栏

走 GPU 呈现时视频会整帧全黑。定位这件事的难点在**判据**——`xwd`/`XGetImage` 抓到的黑，到底是真黑还是抓帧伪影？

解法是一个**活体时钟**：在同一次 `XGetImage` 里，视频区旁 20px 放一个纯 Xlib `XFillRectangle` 画的覆盖窗，每 16ms 换一次自校验码（上行码 + 下行反码），**完全不碰 GPU/DRI3/dmabuf**。时钟码新鲜而视频区 100% 黑 ⇒ 黑是真的；时钟也黑或陈旧 ⇒ 抓帧伪影。

用这个判据测出来：

| 呈现路径 | 黑帧事件 / 抽样 |
| :-- | :-: |
| mpv GL（`opengl`/`x11egl`）+ kgsl | **29/120、29/120、33/120**（整窗全黑，偶尔画到一半） |
| mpv Vulkan（`x11vk`） | 0 |
| mpv zink | 0 |
| mpv + `LIBGL_DRI3_DISABLE=1` | **26/120 —— 对黑帧完全无效** |
| mpv + `vblank_mode=1/3` | 0，但**画面冻成 2.0fps，不可用** |
| VLC `--vout=gl` | 0 黑帧，但 **72/320 帧原地不动**，CPU 64% |
| VLC `--vout=xcb_x11` | 0，CPU 19~43% |

**根因：X 服务端读到了还没画完的 buffer。** 只有 GL + kgsl 这条 present 路会黑；Vulkan 在两种服务端上都干净。`xcb` trace 显示 GL 路径**一次都不调 `fence_from_fd`**。黑帧形态也吻合——大量整帧全黑（渲染器先 `glClear`）加少量"画到一半"，撕裂恒为 0。

**不是** Mesa 在 swap 时清屏：如果是，那 Termux:X11 侧的原生 Vulkan DRI3 也该黑（同一个 Mesa、同一个 GPU），实测 0/320。

对策：让上屏走有围栏的那条路。有 `vo` 开关的用最省的（mpv → Vulkan `x11vk`，VLC → `xcb_x11`）；没开关的 GL 应用用 `MESA_LOADER_DRIVER_OVERRIDE=zink`；VNC 上一律补 `MESA_VK_WSI_DEBUG=sw`。修后 6 组 × 320 帧**全 0 事件**，帧率 23.9~24.0（素材 23.98）。

> [!TIP]
> 顺带纠正一个容易误判的现象：VLC 在 VNC 上的"区块刷新"**不是黑块，是重复帧**。

---

## VNC 上视频卡顿：瓶颈在 `CompareFB`，不在应用也不在带宽

在手机上用 VNC 看视频只有 2 fps，而播放器自报满帧不丢帧。

排查时有个陷阱值得单说：**测 Xvnc 的 CPU 必须有客户端连着**。TigerVNC 无客户端时既不做帧缓冲比较也不编码，此时看到的 `Xvnc CPU ≈ 0` 会让人得出"瓶颈在应用侧"的错误结论 —— 那个结论只在没人看的时候成立。

| 段 | 证据 | 判定 |
| :-- | :-- | :-: |
| 应用侧 | 播放器自报 23.976fps drop=0；客户端一连上，播放器 CPU 反而从 16.0% **掉到** 5.2%（被饿着） | 不是瓶颈 |
| **Xvnc 比较+编码** | 有客户端时 Xvnc **73~81% 单核顶死**；二进制里只有 `InputThread`、无编码线程池 ⇒ 单核天花板；`CompareFB` 把变化区切成 **3757 矩形/秒**（≈1100 矩形/更新），每个小矩形单独走一遍编码 | **★瓶颈** |
| 传输 | 环回 Raw 零压缩 186 MB/s 照样 23.57fps ⇒ **带宽免费，压缩率不重要、压缩耗时才重要** | 不是瓶颈 |

A/B（视频窗固定 1920×1080，3 轮交替 ±0.06fps，另 4 次独立复现）：

| 服务端 `-CompareFB` | 客户端编码 | 送达 fps | 延迟 p50 | Xvnc CPU |
| :-: | :-- | :-: | :-: | :-: |
| 2（默认） | ZRLE 32bpp | 2.06 | 406ms | 79.1% |
| 2 | Tight q6 | 4.09 | 143ms | 67.6% |
| 0 | ZRLE | 3.32 | 383ms | 92.6% |
| **0** | **Tight q6** | **23.94（满帧 0 丢帧）** | **42ms** | 64.9% |

**11.6 倍。** 两边都要改——只把服务端调成 `-CompareFB 0` 而客户端仍用 ZRLE，只有 2.06 → 6.74fps，仍然卡。

> [!NOTE]
> `-CompareFB 1` 比默认的 `2` 还差，不要用。
> 代价实测：静止桌面与暂停视频下 `CompareFB` 0 与 2 **完全一样**（都是 0 更新、0% CPU）；最坏的滚动文本 Xvnc CPU +7pp（3%→10%）、流量 0.10→0.31 MB/s、延迟不变。
> 客户端其余设置：色深留全彩（`CompareFB 0` 下 32bpp 已满帧）、JPEG 质量留中档（q9 反而略慢且流量 5 倍）、压缩级别调低、缩放在客户端做。

还有一条反直觉的：**呈现路径不影响 VNC 送达帧率**。`CompareFB 0` + Tight 下，`--vo=gpu`（kgsl DRI3）23.94 / `gpu-next` 23.57 / `zink` 22.96 / `--vo=x11` 23.99 —— 全是满帧，差别只在应用自身 CPU（x11 路径是 GPU 路径的 3 倍）。所以呈现路径按**功耗**选，不要为了"流畅度"去改它。

---

## Electron 应用的界面闪黑块：`backdrop-filter` 的渲染面

一个 Electron 应用（Chromium 144）在切换页面时侧栏反复闪黑块。六组渲染后端对照（kgsl / llvmpipe / zink+Turnip / SwiftShader / 关 GPU 合成 / 全关 GPU）**全部复现**，只是频率不同 —— 这就排除了驱动层和 X 呈现层。

真凶是 **Chromium 合成器为 `backdrop-filter: blur(8px)` 建的「非根渲染面」**：那个面整块没画，露出背后的背景色。而那个元素的背景本来就不透明，**这个 blur 视觉上 100% 无用**。注入 CSS 去掉它：黑块 69 → 0，两个显示端各 20 次来回切换后都是 0 事件。

> [!TIP]
> 先查技术栈再动手。这个应用一眼看像 Qt（国产商店常见），实际 `ldd` 里没有任何 `libQt5*/libQt6*`，strings 里是 `Electron/40.8.0 + Chrome/144`。如果照着 Qt 的思路去试 `QT_QUICK_BACKEND=software` 之类，全是无效动作。

---

## 测量纪律

这些结论之所以能互相咬合，靠的是几条纪律。它们看着像小事，但本项目有多个结论曾互相打对台，根子都在这里。方法论参考了 [zalexdev/linux-um-arm64](https://github.com/zalexdev/linux-um-arm64) 的 harness。

- **跨 display 比较必须归一化到像素。** 本机 `:1` 是 2504×1152（288 万像素），`:2` 是 1280×1024（131 万像素），**差 2.2 倍**。直接比帧率就带着 2.2 倍的系统性偏差。
- **性能测量要带 `compute` 验证器。** 同一轮里跑一段纯用户态算术（不进内核）作对照：跨条件差异 >5% 或组内抖动 >8%，**整张表作废、什么都不打印**。相同指令流不可能有差异，有差异就是机器动了。实测并发跑多个测试时抖动会到 8.5%~40%。
- **条件交错跑，不分块跑；取中位数不取均值。** 分块跑会把温度漂移整个压在后半段条件上。
- **判据必须能区分"功能不存在"与"工具表达不了这个测试"。** 这条最值钱。反例：`pgrep -x claude` 不管 Claude 在不在跑都返回 0（进程 comm 是 `claude-real`、exe 是版本号路径），于是那道守卫形同不存在。同理，按 cmdline 文本匹配进程会把"命令行里恰好提到该程序名"的自己误判进去 —— 正确做法是 `readlink /proc/<pid>/exe`。
  > 还有个更阴的：某次测试在缺窗口管理器的 display 上跑，"最大化"成了空操作 → 窗口挂在屏幕外 → 抓帧器拒绝抓 → 帧数 0 → **表格全 0 看起来像"已修好"**。

`tools/measure-lib.sh` 把这几条做成了可直接 `source` 的函数。

---

## 致谢

- [**lfdevs/mesa-for-android-container**](https://github.com/lfdevs/mesa-for-android-container) —— Android 容器可用的 Mesa 构建，本项目的 GPU 地基。本仓 README 的组织方式也参考了它。
- [**termux/termux-x11**](https://github.com/termux/termux-x11) —— `:2` 显示服务。
- [**TigerVNC**](https://github.com/TigerVNC/tigervnc) —— `:1` 显示服务。
- **xMeM**、**Robert Kirkman**、**Lucas Fryzek**、**Rob Clark** 以及 Termux 维护团队 —— Freedreno KGSL 后端与相关移植工作。

---

## 许可

脚本与文档以 MIT 发布。第三方组件（Mesa、TigerVNC、Termux:X11 等）各自遵循其原始许可。
