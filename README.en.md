<p align="center">
  <img src="src/app.ico" width="80" alt="DSH WebUI launcher">
</p>

<h1 align="center">DSH WebUI Windows Launcher</h1>

<p align="center">
  A single-file Windows launcher that manages the local Web UI of
  <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a> from one small window.
</p>

<p align="center">
  This is a personal, unofficial project — built entirely with dsh, purely for my own working habits.
</p>

<p align="center">
  <b>How it differs from other dsh desktop apps</b>:
  There are several desktop clients that package dsh into a self-contained app (mostly Electron/Tauri),
  with a large install size and updates tied to dsh.<br>
  This project takes the opposite route: it neither modifies nor bundles dsh —
  it simply drives the <code>dsh web</code> you already have, managing start/stop,
  with a one-button window and a tray icon.<br>
  The whole program is a <b>single exe</b>: no Node.js, no dsh inside;
  update dsh with npm whenever you like, and the launcher is unaffected.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-2EA44F.svg"></a>
  <img alt="Platform: Windows" src="https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-4493F8.svg">
  <img alt="Version" src="https://img.shields.io/badge/version-v1.2.0-2563EB.svg">
</p>

<p align="center">
  <a href="README.md">中文</a> | English
</p>

---

## Download

| Option | Best for |
|---|---|
| **[Direct download: dsh-webui.exe](https://github.com/whereislittlefish-dot/DSH-WebUI-Windows-launcher/raw/main/dsh-webui.exe)** | Just want to start using it |
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
- **A single exe** — double-click and go, no console window
- **Zero dependencies**: only the .NET Framework and PowerShell that ship with Windows
- **Browser integration**: starting the service opens a **frameless standalone window**, and stopping the service **closes it automatically** — no more leftover tabs piling up in your everyday browser (this removes the old "the page won't close" limitation)
- The service runs in a **separate background process**, so closing the window does not stop it
- Supports **minimizing to the system tray**; the tray menu can start/stop the service directly
- A **"DS Open Platform" shortcut** (in both the window and the tray) that opens the DeepSeek platform so you can get an API key
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

> To stop the service when you are done: just click "Stop service" — since v1.2.0 the standalone window **closes itself**, so there is no tab to close by hand (a few exceptions are covered in "After stopping the service" below).

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
| **✕** | Quit the launcher (with a confirmation when the service is running, see below); **does not stop the DSH service** |
| Double-click the tray icon | Restore and bring the original window to the front |
| Tray menu "Start service / Stop service" | Start or stop the service right from the tray — no need to restore the window first (one item that renames itself) |
| Tray menu "Open WebUI" | Open the standalone window; if it is already open, switch to it instead of opening a second one |
| Tray menu "DS Open Platform" | Open the DeepSeek platform home page in your default browser |
| Tray menu "Exit" | Really quit the program (same confirmation as ✕) |
| System-initiated close (Alt+F4, etc.) | Cancelled and tucked into the tray instead — avoids the "window is gone but the tray icon remains" state |

### What happens when you close the launcher (since v1.2.0)

Clicking **✕** or the tray menu's "Exit" while **the DSH service is running** first shows a three-way confirmation:

```
The DSH service is still running.

Yes:    quit and stop the service
No:     quit the launcher only; the service keeps running in the background.
        To stop it later, open the launcher again and click "Stop service".
Cancel: do not quit, return to the launcher
```

- The **default button is "Cancel"**, to avoid accidental clicks (pressing Enter will not stop your service);
- When the service is **not** running, **no** dialog appears — the launcher just exits;
- Choosing "No" leaves the service running. That is why **closing the launcher never stops the dsh service**:
  to stop it, either pick "Yes" here or open the launcher again and click "Stop service".

## After stopping the service

**Since v1.2.0 you normally have nothing to close by hand**: starting the service opens a
**controlled standalone window**, and stopping the service closes it — together with its whole process group.

That works because the window uses a **dedicated browser data directory**
(`%LOCALAPPDATA%\dsh-web-launcher\browser-profile`). That makes it a separate process group which can be
shut down precisely by directory, **without touching the tabs you have open in your everyday browser**.

The launcher picks a browser in this order (Chromium-based only — they all support the required flags):

| Tier | Opened with | Auto-closes on stop? |
|---|---|---|
| ① | Microsoft Edge | ✅ yes |
| ② | Another Chromium browser (Chrome / Brave / Vivaldi / Opera / 360Chrome) | ✅ yes |
| ③ | Your system default browser | ❌ **no** — close the tab yourself |
| ④ | None available | ❌ the UI shows the address and copies it to the clipboard |

- When it falls back to ③ / ④, the log area **explicitly tells you** that this kind of tab cannot be closed
  automatically and must be closed by hand (a tab showing "reconnecting" afterwards is normal — the service
  stopped as expected);
- After you **close the WebUI window manually**, you can always reopen it with "Open WebUI" in the window or
  the tray menu (the launcher checks whether the window still exists: if it does, it switches to it instead of
  opening a second one).

> **Why it used to be impossible**: older versions opened the page in your system default browser. That tab was
> "user-opened", and the browser security model forbids a server from closing it (only `window.close()` from the
> page itself works). v1.2.0 switches to a controlled standalone window, which genuinely removes that limitation.

To temporarily go back to the old behavior (always use the default browser, no window management), set the
environment variable `DSH_WEBUI_BROWSER` to `default` before starting the launcher.

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
A: It depends — since v1.2.0, clicking ✕ **while the service is running** first shows a three-way confirmation (quit and stop the service / quit the launcher only / cancel). If you pick "quit the launcher only", or the service is not running at all, the program exits while **the service keeps running in the background** — that is by design (the service is a separate background process). To stop it: open the launcher again and click "Stop service", or pick "Yes" in that dialog.

**Q: The service is still running after I closed the window?**
A: Same as above — the service is a separate background process. End it with the "Stop service" button, the tray menu's "Stop service", or by choosing "Yes" in the exit confirmation.

**Q: Does it work on macOS / Linux?**
A: No. The launcher depends on the Windows .NET Framework and PowerShell.

**Q: Why doesn't the browser tab close itself after stopping the service?**
A: Since v1.2.0 it **does close automatically** — the service opens a controlled standalone window (its own browser data directory), and stopping the service closes that whole process group. Only when the launcher falls back to **your system default browser** do you need to close the tab yourself: that tab was opened by the browser and cannot be closed by a server (browser security model). The log area tells you explicitly when that happens.

**Q: Could it accidentally close tabs in my everyday browser?**
A: No. The WebUI window uses a **dedicated data directory** (`%LOCALAPPDATA%\dsh-web-launcher\browser-profile`) and is therefore its own process group; closing matches on that directory exactly, leaving your everyday browser untouched.

**Q: Can I open a second WebUI window?**
A: "Open WebUI" brings the existing window to the front if it is already open; a new one is created only after the old one has been closed.

**Q: Does it upload my local sessions or keys?**
A: No. The launcher makes no network calls and has no telemetry; it only invokes your local `dsh`. Your sessions and configuration stay in `%USERPROFILE%\.dsh\` and never pass through this project.

**Q: Where does the launcher put its own files?**
A: All under `%LOCALAPPDATA%\dsh-web-launcher\`: service logs, install logs,
and `ui-diagnostics.log` for troubleshooting the icon.

## License

[MIT](LICENSE)
