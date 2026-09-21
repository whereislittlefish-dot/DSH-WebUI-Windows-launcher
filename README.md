<p align="center">
  <img src="src/app.ico" width="80" alt="DSH WebUI launcher">
</p>

<h1 align="center">DSH WebUI Windows Launcher</h1>

<p align="center">
  一个单文件 Windows 启动器，用按钮界面管理
  <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a> 的本地 Web UI。
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-2EA44F.svg"></a>
  <img alt="Platform: Windows" src="https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-4493F8.svg">
  <img alt="Size: 73 KB" src="https://img.shields.io/badge/Size-73%20KB-171513.svg">
</p>

---

## 下载

| 方式 | 适合 |
|---|---|
| **[直接下载 DSH WebUI.exe](https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher/raw/main/DSH%20WebUI.exe)**（73 KB）| 只想快点用上 |
| [Releases 页面](https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher/releases) | 想看版本记录、下最新版 |

下载后**把它放进你想作为工作区的文件夹**，然后双击运行。详见下方「快速开始」。

---

## 这是什么

DeepSeek Harness（`dsh`）本身通过 `dsh web` 在本地起一个浏览器界面。但它是个命令行程序：你需要记命令、开终端、关窗口还可能把服务一起关掉。

这个启动器把那些操作收进一个窗口里：

- **一个按钮**，随状态自动在「启动服务 / 停止服务」之间切换——不需要记命令，也不会点错
- **单文件 exe**（73 KB），双击即用，不带命令行窗口
- **零依赖**：只用 Windows 自带的 .NET Framework 与 PowerShell
- 服务以**独立后台进程**运行，关掉界面不会停止服务
- 支持**最小化到系统托盘**

> **这是第三方工具，不是 DeepSeek 官方组件。** 它通过命令行调用 `@deepseek-ai/dsh`，不包含 dsh 的任何代码。

## 前置要求

| 要求 | 说明 |
|---|---|
| Windows 10 / 11 | 需要系统自带的 .NET Framework 4.x 与 PowerShell 5.1 |
| **Node.js 20+** | **必须预先安装**：[nodejs.org](https://nodejs.org/) 或 `winget install OpenJS.NodeJS.LTS` |
| 网络（仅首次） | 首次启动会自动安装 dsh（约 213 MB）|

## 快速开始

1. 下载 `DSH WebUI.exe`（见 Releases）
2. **把它放进你希望做为「工作区」的文件夹**（见下方说明）
3. 双击运行
4. 点击「启动服务」

首次启动会先自动安装 `dsh`，**需要几分钟且保持联网**。窗口下方的日志区会显示进度，请不要因为看起来没动静就关掉它。

之后的每次启动都是秒开。

## 关于「工作区」

工作区就是 dsh 的默认工作目录——agent 读写文件、执行命令都以它为根。

**本启动器的规则很简单：exe 放在哪个文件夹，工作区就是哪里。**

所以：

- exe 放在 `D:\myproject\` → 工作区是 `D:\myproject`
- exe 放在桌面 → 工作区是整个桌面（不推荐，agent 的活动范围会过大）

如果你想让 agent 只操作某个项目，就把 exe 放进那个项目文件夹。

## 停止服务后

界面提供两种收敛方式：

- 点 **—** 最小化到托盘（服务继续运行）
- 点 **✕** 完全退出界面（**服务仍在后台运行**）

要真正停止服务，请点界面里的「停止服务」按钮，或右键托盘图标选择「退出」。

停止后，浏览器里那个标签页会显示"需要重新连接"，这是正常的——**请手动关掉它**。浏览器安全模型不允许服务端关闭用户打开的标签页，这一步无法自动化。

## 从源码构建

需要 Windows + .NET Framework 4.x（自带）。

```powershell
git clone https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher.git
cd DSH-WebUI-Windows-launcher
.\build.ps1
```

产物在 `dist/DSH WebUI.exe`。

### 结构

| 路径 | 作用 |
|---|---|
| `src/Launcher.cs` | 单文件启动器：把界面脚本与图标作为资源内嵌，运行时释放到临时目录并执行 |
| `src/DSH-WebUI-WPF.ps1` | 界面本体（WPF）：状态检测、启动/停止、托盘、日志 |
| `src/app.ico` | 图标（16~256 共 7 个尺寸）|
| `build.ps1` | 调用 `csc` 编译出单文件 exe |
| `.github/workflows/release.yml` | 打 tag 时自动构建并附到 Release |

想换图标：替换 `src/app.ico` 后重新运行 `build.ps1` 即可。

## 常见问题

**Q：双击没反应？**
A：先确认 `Node.js` 已安装（在终端里跑 `node -v`）。若没有，界面会提示；也可以看日志区。

**Q：界面显示"正在启动"很久？**
A：首次运行正在下载安装 dsh（约 213 MB）。日志区会持续输出进度。装完后后续启动很快。

**Q：关掉窗口后服务还在跑？**
A：这是设计如此。请用「停止服务」按钮或托盘菜单的「退出」来结束服务。

**Q：能用在 macOS / Linux 吗？**
A：不能。启动器依赖 Windows 的 .NET Framework 与 PowerShell。

**Q：会把我本地的会话或密钥上传吗？**
A：不会。本启动器不联网、无遥测，只调用本机的 `dsh`。你的会话与配置保存在 `%USERPROFILE%\.dsh\`，不经过本项目。

## 许可

[MIT](LICENSE)
