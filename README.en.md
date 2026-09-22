<p align="center">
  <img src="src/app.ico" width="80" alt="DSH WebUI launcher">
</p>

<h1 align="center">DSH WebUI Windows Launcher</h1>

<p align="center">
  A single-file Windows launcher that manages the local Web UI of
  <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a> from one small window.
</p>

<p align="center">
  This project is built entirely with dsh, purely out of personal working habits.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-2EA44F.svg"></a>
  <img alt="Platform: Windows" src="https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-4493F8.svg">
  <img alt="Version" src="https://img.shields.io/badge/version-v1.1.1-2563EB.svg">
  <img alt="Size: 97.5 KB" src="https://img.shields.io/badge/Size-97.5%20KB-171513.svg">
</p>

<p align="center">
  <a href="README.md">中文</a> | English
</p>

---

## Download

| Option | Best for |
|---|---|
| **[Direct download: dsh-webui.exe](https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher/raw/main/dsh-webui.exe)** (97.5 KB) | Just want to start using it |
| [Releases page](https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher/releases) | Browsing version history and packaged builds |
| [Latest release asset](https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher/releases/latest) | Pinning to a specific version |

> The `dsh-webui.exe` in the repository and the asset attached to each Release are built from **the same sources** (the `src/` folder here). Releases exist to keep a build artifact per version; for everyday use, the copy in the repository is enough.

After downloading, **put it in any folder you like** and double-click it — where the launcher lives never affects the dsh workspace. See "Quick start" below.

> [!IMPORTANT]
> **Your browser may block this download. That is a normal safety prompt, not a sign that the file is bad.**
>
> Edge / Chrome usually show "This file may be dangerous" or block it outright — click **`...`** next to the download and choose **Keep**.
> In Firefox, click **Keep file** in the downloads panel.
>
> The reason is simply that it is a directly runnable `.exe`. Browsers show this for every executable, regardless of where it came from.

---

## What this is

DeepSeek Harness (`dsh`) serves its browser UI locally through `dsh web`. But it is a command-line program: you have to remember the command, open a terminal, and closing the wrong window can kill the service along with it.

This launcher folds all of that into one window:

- **One button** that flips between "Start service" and "Stop service" based on the current state — no commands to remember, no way to click the wrong thing
- **A single exe** (97.5 KB) — double-click and go, no console window
- **Zero dependencies**: only the .NET Framework and PowerShell that ship with Windows
- The service runs in a **separate background process**, so closing the window does not stop it
- Supports **minimizing to the system tray**
- **Guided first run**: detects Node.js, installs dsh automatically, and shows live install progress

> **This is a third-party tool, not an official DeepSeek component.** It drives `@deepseek-ai/dsh` from the command line and contains none of dsh's own code.

## Requirements

| Requirement | Notes |
|---|---|
| Windows 10 / 11 | Uses the built-in .NET Framework 4.x and PowerShell 5.1 |
| Node.js 20+ | Recommended: install it first from [nodejs.org](https://nodejs.org/en/download). **It also works without Node.js** — the UI shows the download link and opens the page for you |
| Network (first run only) | The first launch installs dsh automatically (about 200 MB) |

## Quick start

1. Download `dsh-webui.exe` (any folder will do)
2. Double-click it
3. Click "Start service"

The first time you click "Start service", two things happen in order, each with clear on-screen feedback, and the window never freezes:

**① Node.js detection**

If `node` is not on `PATH`, the launcher probes a few common install locations
(`%ProgramFiles%\nodejs`, `%LOCALAPPDATA%\Programs\nodejs`, nvm directories, and so on) and adds them to the environment.
If Node.js is genuinely missing, the log area shows:

```
Node.js not found — DSH WebUI requires Node.js 20 or newer.
Download: https://nodejs.org/en/download
After installing, reopen this program (the installer adds node to PATH).
```

and the download page opens automatically.

**② Installing dsh (about 200 MB, first run only)**

- The install runs as an **asynchronous, separate process**: the UI stays responsive and the window can be minimized;
- Live `install progress xx%`; npm errors (`npm ERR!`, `ETIMEDOUT`, `ECONNRESET`, …) are passed through verbatim;
- While installing, the main button becomes "**Cancel install**" — click it again to abort;
- When it finishes you get an explicit message:

  ```
  dsh installed in 26 seconds.
  Entry: C:\Users\<you>\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\lib\bin.js
  Ready to run — continuing to start the service ...
  ```

  The service then starts automatically, reports `Service is ready.` and opens your browser.

Every later start is nearly instant.

> To stop the service when you are done: click "Stop service" in the window, then **close the browser tab manually** (it will not close itself — see "After stopping the service" below).

## About the "workspace"

The workspace is where the dsh agent does its work — file reads and writes, and command execution, are all rooted there.

**Workspaces live entirely inside the DSH Web UI: when you start a new conversation you pick (or create) a workspace, and the conversation is rooted in that directory.**

The launcher only starts and stops the service. It **does not take part in, and cannot determine, the workspace**:

- `dsh-webui.exe` can live in any folder — unrelated to the workspace
- To use a project as a workspace, create it as a workspace inside the DSH UI; that has nothing to do with where the exe sits
- Moving the exe, or keeping several copies in different folders, changes neither existing nor new conversations

> v1.1.0 and earlier displayed a "workspace" in the window. That value was guessed from the launcher's own folder and was never used by dsh. v1.1.1 removes it together with the whole plumbing that passed it around.

## Window and tray behavior

| Action | Result |
|---|---|
| Main button | Start / stop the background service; becomes "Cancel install" while dsh is installing |
| **—** | Minimize to tray; the service keeps running |
| **✕** | Close the window and clean up the tray icon; **the background service keeps running** |
| Double-click the tray icon | Restore and bring the original window to the front |
| Tray menu "Exit" | Really quit the program |
| System-initiated close (Alt+F4, etc.) | Cancelled and tucked into the tray instead — avoids the "window is gone but the tray icon remains" state |

## After stopping the service

> [!IMPORTANT]
> **After stopping the service, you must close the browser tab yourself.**
>
> It will show "reconnecting" or "this page can't be reached". That is **expected, not a fault** — the service is simply stopped.
>
> **Why it cannot be closed for you**: browsers impose a hard security rule — only `window.close()` called by the page itself can close a tab, and that page must have been opened by a script. Your tab was opened manually (or by the system), so **no server-side trick can close it**. This is part of the browser security model, not a defect of this tool.

Recommended order:

1. Click "Stop service" in the window
2. Close the DSH tab in your browser manually
3. When you need it again, click "Start service" (this opens a fresh tab with fresh credentials)

## Building from source

You need Windows + .NET Framework 4.x (already included).

```powershell
git clone https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher.git
cd DSH-WebUI-Windows-launcher
.\build.ps1
```

The artifact lands in `dist/dsh-webui.exe`.

### Layout

| Path | Purpose |
|---|---|
| `src/Launcher.cs` | The single-file launcher: embeds the UI script and icon as resources, extracts them to a temp directory at runtime, and runs them |
| `src/DSH-WebUI-WPF.ps1` | The UI itself (WPF): status detection, start/stop, Node.js detection, install progress, tray, logging |
| `src/app.ico` | Icon (7 sizes, 16–256 px) |
| `build.ps1` | Compiles the single-file exe with `csc` |
| `.github/workflows/release.yml` | CI: pushing a tag builds and attaches the artifact to a Release; can also be triggered manually from the Actions page |

### Changing the icon

Replace `src/app.ico` and run `build.ps1` again. The exe's file icon comes from `/win32icon` at compile time, while the window and tray icons are loaded at runtime from the extracted `app.ico` — so one file covers all three places.

> The taskbar icon needs one extra step: the window actually runs inside a `powershell.exe` process, and the script calls
> `SetCurrentProcessExplicitAppUserModelID` to declare its app identity. Without it, Windows treats PowerShell as the host
> and shows the PowerShell icon on the taskbar. After launching, the effective value is recorded in
> `%LOCALAPPDATA%\dsh-web-launcher\ui-diagnostics.log`.

> **Note**: `src/DSH-WebUI-WPF.ps1` must be saved as **UTF-8 with a BOM**.
> PowerShell 5.1 decodes BOM-less UTF-8 scripts as GBK, which mangles non-ASCII text and fails immediately with
> "unexpected attribute CmdletBinding".

## FAQ

**Q: The browser says the download "may be dangerous", or blocks it entirely?**
A: That is the standard warning browsers show for **every `.exe`**, regardless of where it came from — **the file is not corrupt and this tool is not suspicious**. To proceed: in Edge / Chrome click `...` next to the download and choose **Keep**; in Firefox click **Keep file** in the downloads panel. This launcher is fully open source — read all of `src/`, or build it yourself as described in "Building from source", and confirm the exe matches these sources.

**Q: Must the exe sit inside my project folder?**
A: No. The launcher only starts and stops the dsh service, and **the workspace is managed entirely by the DSH Web UI** — create or pick a workspace there and the conversation is rooted in that directory, no matter where `dsh-webui.exe` lives. (v1.1.0 and earlier displayed a "workspace" guessed from the launcher's own folder; dsh never used it, and v1.1.1 removed it.)

**Q: Double-clicking does nothing?**
A: First make sure `Node.js` is installed (run `node -v` in a terminal). If it is missing, the UI shows the download link and opens the page; the log area has details too.

**Q: The UI says "starting" for a long time?**
A: On first run it is downloading and installing dsh (about 200 MB). The log area keeps showing a percentage; later starts are fast.

**Q: The taskbar shows the PowerShell icon?**
A: Fixed in v1.1.0. If it still looks wrong, check `AppUserModelID` and the window icon values in `%LOCALAPPDATA%\dsh-web-launcher\ui-diagnostics.log`; if both are correct it is the Windows icon cache — move or rename the exe and run it again, or sign out once.

**Q: I clicked the window's close button and the program is still running?**
A: By design — **✕ only closes the window; the background service keeps running** (the tray icon is cleaned up). To quit the program entirely, use "Exit" in the tray menu; to stop the service, use "Stop service" in the window.

**Q: The service is still running after I closed the window?**
A: Same as above — the service is a separate background process. Use the "Stop service" button or the tray menu's "Exit" to end it.

**Q: Does it work on macOS / Linux?**
A: No. The launcher depends on the Windows .NET Framework and PowerShell.

**Q: Why doesn't the browser tab close itself after stopping the service?**
A: The browser security model does not allow a server to close a tab the user opened — only `window.close()` from the page itself works, and the page must have been script-opened. So this step is **manual by necessity**. A tab showing "reconnecting" afterwards is normal and means the service stopped as expected.

**Q: Does it upload my local sessions or keys?**
A: No. The launcher makes no network calls and has no telemetry; it only invokes your local `dsh`. Your sessions and configuration stay in `%USERPROFILE%\.dsh\` and never pass through this project.

**Q: Where does the launcher put its own files?**
A: All under `%LOCALAPPDATA%\dsh-web-launcher\`: service logs, install logs,
and `ui-diagnostics.log` for troubleshooting the icon.

## License

[MIT](LICENSE)
