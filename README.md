# 手机上的硬件加速 Linux 桌面

**简体中文** | [English](docs/en/README.md)

---

把一台 Android 手机变成能跑 **GPU 硬件加速 XFCE 桌面**的 Linux 机器：Termux 宿主 + proot Ubuntu 24.04 容器，**VNC 与 Termux:X11 两套显示同时在线**，OpenGL 走 Adreno KGSL 原生路径（不经 zink 翻译），Vulkan 走 Turnip。

这个仓库不是驱动本身，而是**驱动之上那一层**：显示服务怎么起、GPU 环境变量怎么配、Electron 应用为什么看不到显卡、以及怎么让这些改动在 `apt upgrade` 和应用商店更新之后依然活着。

> [!NOTE]
> 所有结论都来自**本机实测**，不是照抄文档。跑不通的地方在「[已知问题](#已知问题)」里如实写明，没有藏。

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
| 本机 | 骁龙 8 Elite | **Adreno 830** | proot Ubuntu 24.04 | ✔ kgsl 原生 | ✔ Turnip | 本仓全部结论的来源 |
| Redmi K60 | 骁龙 8+ Gen 1 | **Adreno 725** | proot Ubuntu 24.04 | ✔ zink | ✔ Turnip | 早期形态，配方已不同，见下 |

> [!IMPORTANT]
> **K60 时代的老配方在 Adreno 830 上是错的。** 当年 VNC 侧靠「zink 四件套 + `-rendernode /dev/kgsl-3d0` + `+iglx`」，现在 kgsl 后端成熟后应当直起 `Xvnc` 并走 kgsl 原生路径。仓库里的脚本注释保留了两代配方的对照，迁移时按注释走，别把旧变量原样抄过来。

驱动本身请用 [**lfdevs/mesa-for-android-container**](https://github.com/lfdevs/mesa-for-android-container) 的 Release，本仓不重复造。

---

## 宿主侧：Termux 与 Termux:X11

这一段的坑比容器内多，且几乎没有文档。

### ZeroTermux 自签名的连锁后果

本项目宿主用的是 **ZeroTermux**（Termux 的第三方分支）。它用自己的签名打包，于是：

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

XFCE「设置 → 鼠标 → 光标大小」在本机怎么拖都不变大。用 XFIXES `GetCursorImage` 读出实际像素才定位到双重原因：

1. **主题没有大图。** 本机四个光标主题（vintage / Adwaita / bloom / bloom-dark）内含图最大只有 **48px**，`XcursorLibraryLoadImage` 请求 64/96/128 一律回落 48。
2. **`xfsettingsd` 不写 xrdb。** 它只管 XSETTINGS（GTK 应用读这个），不写 `Xcursor.*` 资源；而桌面根窗的光标是会话启动时定死的，改 xfconf 不会重设。

对应两个工具：

- `tools/make-hidpi-cursor.py` —— 纯标准库，把主题内最大那档最近邻放大，生成含 24/32/48/64/96/128 六档的新主题到 `~/.icons/`。用最近邻而非插值，因为光标是硬边像素画，插值会糊边。
- `files/desktop-env/cursor-sync.sh` —— 读 xfconf → 写 xrdb → `xsetroot` 重设根窗光标。**只读 xfconf、不设 `XCURSOR_*` 环境变量**，这样 GUI 始终是唯一真源，不架空原生设置界面。

```bash
tools/make-hidpi-cursor.py vintage vintage-hidpi 24,32,48,64,96,128
files/desktop-env/cursor-sync.sh :1 :2
```

> [!NOTE]
> 已打开的窗口大多在创建时就定好了光标，不会立刻变；根窗/桌面会立刻变，其余应用重开即可。这是 X 的固有行为。

---

## 仓库内容

本仓只放**通用、可直接搬走复用**的部分。完整的一键部署脚本、各应用包装、本机 `.desktop` 与包清单属于私人订制，不在这里。

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

## 已知问题

| 问题 | 状态 |
| :-- | :-- |
| **视频播放器黑帧** —— 走 GPU 呈现路径时，两个显示端都有 20–40% 的帧整帧全黑 | 未解决。已缩到两个候选根因：Mesa kgsl 的 EGL/WSI 在 swap 时清屏，或 Xvnc-dri3 / Xlorie 以 `PROT_READ` mmap dmabuf 时缺少 cache invalidate。已备三个用户级绕法（播放器改用 x11/xcb 输出、mpv 软件呈现），尚未合入。 |
| **Chrome 148 硬件路径** | 被 DRM render node 的 `EACCES` 挡住，判定不值得继续投入 |
| **VNC 侧 Vulkan swapchain** | 已有可用补丁但慢 3.4 倍，当前用 `MESA_VK_WSI_DEBUG=sw` 绕过 |

---

## 致谢

- [**lfdevs/mesa-for-android-container**](https://github.com/lfdevs/mesa-for-android-container) —— Android 容器可用的 Mesa 构建，本项目的 GPU 地基。本仓 README 的组织方式也参考了它。
- [**termux/termux-x11**](https://github.com/termux/termux-x11) —— `:2` 显示服务。
- [**TigerVNC**](https://github.com/TigerVNC/tigervnc) —— `:1` 显示服务。
- **xMeM**、**Robert Kirkman**、**Lucas Fryzek**、**Rob Clark** 以及 Termux 维护团队 —— Freedreno KGSL 后端与相关移植工作。

---

## 许可

脚本与文档以 MIT 发布。第三方组件（Mesa、TigerVNC、Termux:X11 等）各自遵循其原始许可。
