<p align="center">
  <img src="src/app.ico" width="80" alt="DSH WebUI launcher">
</p>

<h1 align="center">DSH WebUI Windows Launcher</h1>

<p align="center">
  一个单文件 Windows 启动器，用按钮界面管理
  <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a> 的本地 Web UI。
</p>

<p align="center">
  本项目完全采用 dsh 制作，仅出于个人工作习惯。
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-2EA44F.svg"></a>
  <img alt="Platform: Windows" src="https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-4493F8.svg">
  <img alt="Version" src="https://img.shields.io/badge/version-v1.1.2-2563EB.svg">
  <img alt="Size: 101 KB" src="https://img.shields.io/badge/Size-101%20KB-171513.svg">
</p>

<p align="center">
  <a href="README.en.md">English</a> | 中文
</p>

---

## 下载

| 方式 | 适合 |
|---|---|
| **[直接下载 dsh-webui.exe](https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher/raw/main/dsh-webui.exe)**（101 KB）| 只想快点用上 |
| [Releases 页面](https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher/releases) | 想看版本记录、下打包版本 |
| [最新版 Release 附件](https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher/releases/latest) | 想要固定版本的附件 |

> 仓库里的 `dsh-webui.exe` 与 Releases 里的附件来自**同一份源码**（仓库中的 `src/`）。Releases 用于留存每个版本的构建产物，日常直接下载仓库里那份即可。

下载后**放在任意文件夹**双击运行即可——启动器放在哪里都不影响 dsh 的工作区。详见下方「快速开始」。

> [!IMPORTANT]
> **浏览器可能会拦截这次下载，这是正常的安全提示，不是文件有问题。**
>
> Edge / Chrome 通常会在下载栏提示"此文件可能有风险"或直接拦下，请点下载项右侧的 **`...`** → **`保留`**（Keep）。
> Firefox 若在下载面板里拦住，点 **`保留文件`** 即可。
>
> 之所以会被拦：它是一个可直接运行的 `.exe`。浏览器对所有可执行文件都会这样提示，与文件来源是否可信无关。

---

## 这是什么

DeepSeek Harness（`dsh`）本身通过 `dsh web` 在本地起一个浏览器界面。但它是个命令行程序：你需要记命令、开终端、关窗口还可能把服务一起关掉。

这个启动器把那些操作收进一个窗口里：

- **一个按钮**，随状态自动在「启动服务 / 停止服务」之间切换——不需要记命令，也不会点错
- **单文件 exe**（101 KB），双击即用，不带命令行窗口
- **零依赖**：只用 Windows 自带的 .NET Framework 与 PowerShell
- 服务以**独立后台进程**运行，关掉界面不会停止服务
- 支持**最小化到系统托盘**
- **首次使用全程有提示**：自动检测 Node.js、自动安装 dsh，并实时显示安装进度

> **这是第三方工具，不是 DeepSeek 官方组件。** 它通过命令行调用 `@deepseek-ai/dsh`，不包含 dsh 的任何代码。

## 前置要求

| 要求 | 说明 |
|---|---|
| Windows 10 / 11 | 需要系统自带的 .NET Framework 4.x 与 PowerShell 5.1 |
| Node.js 20+ | 建议预先安装：[nodejs.org](https://nodejs.org/zh-cn/download)。**没装也能启动**，界面会给出下载地址并自动打开下载页 |
| 网络（仅首次） | 首次启动会自动安装 dsh（约 200 MB）|

## 快速开始

1. 下载 `dsh-webui.exe`（放在哪个文件夹都可以）
2. 双击运行
3. 点击「启动服务」

首次点「启动服务」时会依次处理两件事，每一步都有明确提示，窗口不会假死：

**① 检测 Node.js**

PATH 里找不到 `node` 时，会继续探测几个常见安装位置
（`%ProgramFiles%\nodejs`、`%LOCALAPPDATA%\Programs\nodejs`、nvm 目录等）并自动补进环境。
完全没有时，日志区会显示：

```
未检测到 Node.js —— DSH WebUI 需要先安装 Node.js 20 或更高版本。
下载地址：https://nodejs.org/zh-cn/download
安装完请重新打开本程序（安装包会自动把 node 加入 PATH）。
```

并自动打开该下载页。

**② 安装 dsh（约 200 MB，仅首次）**

- 安装以**独立进程异步执行**，界面保持可交互，窗口可以最小化；
- 实时显示 `安装进度 xx%`；npm 的报错（`npm ERR!`、`ETIMEDOUT`、`ECONNRESET` 等）原样透出；
- 安装期间主按钮变成「**取消安装**」，再点一次即中止；
- 完成后会明确提示：

  ```
  dsh 安装完成，用时 26 秒。
  入口：C:\Users\<你>\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\lib\bin.js
  现在可以运行了，正在继续启动服务 ...
  ```

  随后自动继续启动服务，就绪时提示 `服务已就绪，可以使用了。` 并打开浏览器。

之后的每次启动都是秒开。

> 用完后要停止服务：点界面里的「停止服务」，然后**手动关掉浏览器里的标签页**（它不会自己关，原因见下方「停止服务后」）。

## 关于「工作区」

工作区就是 dsh 里 agent 干活的地方——读写文件、执行命令都以它为根。

**工作区完全在 DSH WebUI 里管理：新建对话时先选（或新建）一个工作区，对话就落在那个目录下。**

启动器只负责启动 / 停止服务，**不参与、也决定不了工作区**：

- `dsh-webui.exe` 放在哪个文件夹都可以，与工作区无关
- 想把某个项目作为工作区，就在 DSH 界面里把它新建为工作区，与 exe 的位置互不影响
- 挪动 exe、甚至复制成好几份分别运行，都不会改变已有对话或新建对话的工作区

> v1.1.0 及更早版本的界面里显示过一个"工作区"，那其实是启动器按自己所在目录猜出来的值，
> 从未被 dsh 使用过。v1.1.1 已把它连同整套传值逻辑一并删除。

## 界面与托盘的行为

| 操作 | 结果 |
|---|---|
| 主按钮 | 启动 / 停止后台服务；安装 dsh 期间变为「取消安装」 |
| **—** | 最小化到托盘，服务继续运行 |
| **✕** | 退出界面并清理托盘图标，**后台服务仍在运行** |
| 托盘图标双击 | 恢复并置前原窗口 |
| 托盘菜单「退出」 | 真正退出程序 |
| 系统发起的关闭（Alt+F4 等） | 被取消并收进托盘，程序不退出——避免出现"窗口没了、托盘图标还在"的状态 |

## 停止服务后

> [!IMPORTANT]
> **停止服务后，浏览器里那个标签页需要你手动关闭。**
>
> 它会显示"需要重新连接"或"找不到此页"，这是**正常现象，不是故障**——因为服务已经停了。
>
> **为什么不能自动关掉它**：浏览器有硬性安全限制——只有页面自己调用的 `window.close()` 才能关闭它，而且该页面必须是由脚本打开的。你的标签页是手动/系统打开的，因此**任何服务端手段都无法关闭它**。这是浏览器安全模型的一部分，不是本工具的缺陷。

推荐的操作顺序：

1. 点界面里的「停止服务」
2. 手动关掉浏览器里的 DSH 标签页
3. 需要再用时，重新点「启动服务」（会打开一个新的、带新凭据的标签页）

## 从源码构建

需要 Windows + .NET Framework 4.x（自带）。

```powershell
git clone https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher.git
cd DSH-WebUI-Windows-launcher
.\build.ps1
```

产物在 `dist/dsh-webui.exe`。

### 结构

| 路径 | 作用 |
|---|---|
| `src/Launcher.cs` | 单文件启动器：把界面脚本与图标作为资源内嵌，运行时释放到临时目录并执行 |
| `src/DSH-WebUI-WPF.ps1` | 界面本体（WPF）：状态检测、启动/停止、Node 检测、安装进度、托盘、日志 |
| `src/app.ico` | 图标（16~256 共 7 个尺寸）|
| `build.ps1` | 调用 `csc` 编译出单文件 exe |
| `.github/workflows/release.yml` | CI：打 tag 自动构建并附到 Release，也可在 Actions 页手动触发 |

### 换图标

替换 `src/app.ico` 后重新运行 `build.ps1`。exe 的文件图标来自编译时的 `/win32icon`，
窗口与托盘图标由脚本运行时从释放出来的 `app.ico` 加载，所以换这一个文件三处都会变。

> 任务栏图标另有一处关键处理：窗口实际运行在 `powershell.exe` 进程里，脚本会调用
> `SetCurrentProcessExplicitAppUserModelID` 声明应用归属，否则 Windows 会把 PowerShell
> 当宿主、任务栏显示 PowerShell 的图标。启动后可在
> `%LOCALAPPDATA%\dsh-web-launcher\ui-diagnostics.log` 查看实际取值。

> **注意**：`src/DSH-WebUI-WPF.ps1` 必须保存为**带 BOM 的 UTF-8**。
> PowerShell 5.1 读没有 BOM 的 UTF-8 脚本会按 GBK 解码，中文被拆坏后直接报
> 「意外的属性 CmdletBinding」。

## 常见问题

**Q：下载时浏览器提示"文件可能有风险"，或干脆拦下了？**
A：这是浏览器对**所有 `.exe`** 的常规安全提示，与文件来源是否可信无关——**不是文件损坏，也不是本工具可疑**。处理方式：Edge / Chrome 点下载项旁的 `...` → `保留`；Firefox 在下载面板里点「保留文件」。本启动器完全开源，你可以直接查看 `src/` 下的全部源码，或按下方「从源码构建」自行编译，对照确认这个 exe 就是这些源码的产物。

**Q：exe 必须放在项目文件夹里吗？**
A：不必。启动器只负责启停 dsh 服务，**工作区完全由 DSH WebUI 管理**——在界面里新建或选择一个工作区，对话就落在那个目录下，与 `dsh-webui.exe` 放在哪里无关。（v1.1.0 及更早版本的界面显示过一个"工作区"，那是启动器按自己所在目录猜出来的值，从未被 dsh 使用；v1.1.1 已删除。）

**Q：双击没反应？**
A：先确认 `Node.js` 已安装（在终端里跑 `node -v`）。若没有，界面会给出下载地址并自动打开下载页；也可以看日志区。

**Q：界面显示"正在启动"很久？**
A：首次运行正在下载安装 dsh（约 200 MB），日志区会持续显示进度百分比。装完后后续启动很快。

**Q：任务栏图标显示成 PowerShell 的图标？**
A：v1.1.0 已修复。若仍不对，先看 `%LOCALAPPDATA%\dsh-web-launcher\ui-diagnostics.log`
里的 `AppUserModelID` 与窗口图标取值；两项都正常的话是 Windows 图标缓存，把 exe
换个目录或改个名字再运行、或注销一次即可。

**Q：点了窗口关闭按钮，程序还在？**
A：这是设计如此——**✕ 只退出界面，后台服务继续运行**（托盘图标会一并清理）。
想彻底结束程序用托盘菜单的「退出」；想停服务用界面里的「停止服务」。

**Q：关掉窗口后服务还在跑？**
A：同上，服务是独立后台进程。请用「停止服务」按钮或托盘菜单「退出」来结束服务。

**Q：能用在 macOS / Linux 吗？**
A：不能。启动器依赖 Windows 的 .NET Framework 与 PowerShell。

**Q：停止服务后，浏览器标签页为什么不自己关掉？**
A：浏览器的安全模型不允许服务端关闭用户打开的标签页——只有页面自己调用的 `window.close()` 才行，且该页面必须由脚本打开。所以这一步**只能手动关闭**。停止后标签页显示"需要重新连接"是正常的，说明服务已按预期停止。

**Q：会把我本地的会话或密钥上传吗？**
A：不会。本启动器不联网、无遥测，只调用本机的 `dsh`。你的会话与配置保存在 `%USERPROFILE%\.dsh\`，不经过本项目。

**Q：启动器自己产生的文件在哪？**
A：都在 `%LOCALAPPDATA%\dsh-web-launcher\`：服务日志、安装日志、
以及排查图标问题时用的 `ui-diagnostics.log`。

## 许可

[MIT](LICENSE)
