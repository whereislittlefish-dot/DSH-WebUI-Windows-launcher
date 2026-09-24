<#
    DSH-WebUI-WPF.ps1  —  DSH WebUI 按钮界面（WPF 版）

    按设计图实现：浅灰页面 + 白色圆角卡片 + 彩色状态徽章 + 红色主按钮 +
    浅蓝描边次按钮 + 日志卡片。

    为什么用 WPF 而不是之前的 WinForms：设计图里的圆角、阴影、矢量图标、
    精确排版，WinForms 做不出来或要大量自绘。WPF 随 .NET Framework 自带，
    零安装、零依赖。

    这个文件是自包含的：不依赖任何其它脚本。配套的「启动 DSH WebUI.vbs」
    只是零窗口入口，要带走就整个文件夹一起拷。
#>

[CmdletBinding()]
param(
    [int] $Port = 3080
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# 显式显示/激活窗口用（VBS 用 SW_HIDE 启动我们时 Windows 会把窗口也建成隐藏的）
if (-not ('Win32Window' -as [type])) {
    Add-Type -Namespace '' -Name 'Win32Window' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@
}

# 任务栏图标归属：窗口跑在 powershell.exe 进程里，若不显式声明 AppUserModelID，
# Windows 会把 PowerShell 当成宿主，任务栏就显示 PowerShell 的图标。
# 声明一个稳定的 AppUserModelID 后，任务栏才会用本窗口自己的图标。
if (-not ('TaskbarIdentity' -as [type])) {
    Add-Type -Namespace '' -Name 'TaskbarIdentity' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetCurrentProcessExplicitAppUserModelID(out System.Text.StringBuilder AppID);
'@
}

$script:AppUserModelId = 'DSH.WebUI.Launcher'
$script:AumidStatus = '未设置'
try {
    $hr = [TaskbarIdentity]::SetCurrentProcessExplicitAppUserModelID($script:AppUserModelId)
    if ($hr -eq 0) {
        # 回读确认，结果写进日志，便于排查任务栏图标归属问题
        $sb = New-Object System.Text.StringBuilder 512
        [void] [TaskbarIdentity]::GetCurrentProcessExplicitAppUserModelID([ref] $sb)
        $script:AumidStatus = $sb.ToString()
    }
    else {
        $script:AumidStatus = ("设置失败 hr=0x{0:X8}" -f $hr)
    }
}
catch { $script:AumidStatus = ('异常：' + $_.Exception.Message) }

# ---------------------------------------------------------------- 运行环境常量
$script:StateDir      = Join-Path $env:LOCALAPPDATA 'dsh-web-launcher'
$script:EffectivePort = $Port
$script:StateFile     = Join-Path $script:StateDir "dsh-web-web-$($script:EffectivePort).json"
$script:LogFile       = Join-Path $script:StateDir "dsh-web-web-$($script:EffectivePort).log"

# 界面版本号：显示在标题栏，并写进 ui-diagnostics.log——排障或反馈时一眼能确认用的是哪一版。
# 发版时这里要跟着 README 徽章和 git tag 一起改。
$script:AppVersion = 'v1.2.1'

# netstat 探测结果缓存（见 Get-DshWebInstance）：界面每隔几秒刷新一次状态，
# 没有缓存时每次都要拉起一个 netstat 进程，白白消耗 CPU。
$script:ProbeCache = $null

# v1.2.0 浏览器联动状态：
#   WebUiUrl        = 本次服务启动时抓到的**带 token** 的地址（不带 token 访问会 401）
#   WebUIWindowMode = 窗口是怎么打开的（app = 受控独立窗口，可自动关；default = 系统默认浏览器，关不掉）
$script:WebUiUrl        = $null
$script:WebUIWindowMode = 'none'

# v1.1.1：启动器不再掺和 dsh 的工作区。
# 工作区完全由 DSH WebUI 里新建/选择的工作区决定（新建会话时带 workspaceId）；
# 服务进程的 cwd 只在"一个工作区都还没有"时作兜底，界面既不显示也不解释它。

# ============================================================ WebUI 浏览器联动（v1.2.0）

<#
    方案 B：用 Chromium 系浏览器的 --app + 独立 --user-data-dir 打开一个无地址栏的独立窗口。

    为什么要独立 --user-data-dir：不开它，窗口会挂进用户日常浏览器的那棵进程树，
    按 PID 关闭就会误伤用户正在看的标签页。独立目录之后它是独立进程树，
    可以按 profile 路径精确关闭整组进程，于是「停止服务 → 窗口自动关闭」才成立。

    实测数据（2026-09-24，见 docs\验证日志\v1.2.0-浏览器联动实测.log）：
      · 一次 --app 会拉起 8~17 个进程，关闭耗时约 1.2 秒，关闭后零残留；
      · 重复执行 --app 会**真的开出第二个窗口**（两个窗口还可能挤在同一个 PID 里），
        所以「窗口已在 → 聚焦」必须自己做，不能靠再调一次 --app；
      · 关掉最后一个窗口后浏览器自己会回收整组进程，但按 profile 关整组仍是必要的兜底；
      · SetForegroundWindow 从后台进程调用会被系统前台锁定策略拒绝 → 聚焦失败只记日志。

    刻意**不内嵌 WebView2**：那需要释放原生 DLL，会让 101 KB 的单文件 exe 涨到 MB 级
    （详见 docs\浏览器联动调研-260922-1531.md 第九、十章）。
#>

# 枚举顶层窗口用的 Win32 入口（窗口存活检测与聚焦都要用）
if (-not ('WebUiWindowApi' -as [type])) {
    Add-Type -Namespace '' -Name 'WebUiWindowApi' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr h, int c);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr h);
'@
}

# 独立 profile 目录：与用户日常浏览器完全隔离。
# 停止服务时只关进程、**保留目录**（保留登录态与缓存，下次打开更快，也避免反复重建 profile）。
function Get-WebUIBrowserProfile {
    $dir = Join-Path $script:StateDir 'browser-profile'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return $dir
}

<#
    浏览器探测：只收 Chromium 内核（--app 与独立 profile 是它的通用参数）。
    顺序 Edge → Chrome → Brave → Vivaldi → Opera → 360极速（按"机器上出现的概率"排）。
    路径来源三选一，命中后一律 Test-Path 校验，绝不写死盘符：
      ① 注册表 App Paths\<exe>（HKLM、WOW6432Node、HKCU 三处都查）
      ② 常见安装目录
    刻意不纳入夸克等非可靠候选：实测其注册表项连 shell\open\command 都是空的。
#>
function Resolve-WebUIBrowser {
    $candidates = @(
        [pscustomobject]@{ Name = 'Microsoft Edge'; Exe = 'msedge.exe'
            Dirs = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application", "$env:ProgramFiles\Microsoft\Edge\Application") }
        [pscustomobject]@{ Name = 'Google Chrome'; Exe = 'chrome.exe'
            Dirs = @("$env:ProgramFiles\Google\Chrome\Application", "${env:ProgramFiles(x86)}\Google\Chrome\Application", "$env:LOCALAPPDATA\Google\Chrome\Application") }
        [pscustomobject]@{ Name = 'Brave'; Exe = 'brave.exe'
            Dirs = @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application", "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application") }
        [pscustomobject]@{ Name = 'Vivaldi'; Exe = 'vivaldi.exe'
            Dirs = @("$env:ProgramFiles\Vivaldi\Application", "${env:ProgramFiles(x86)}\Vivaldi\Application", "$env:LOCALAPPDATA\Vivaldi\Application") }
        [pscustomobject]@{ Name = 'Opera'; Exe = 'opera.exe'
            Dirs = @("$env:LOCALAPPDATA\Programs\Opera", "$env:ProgramFiles\Opera") }
        [pscustomobject]@{ Name = '360极速浏览器'; Exe = '360chrome.exe'
            Dirs = @("$env:LOCALAPPDATA\360Chrome\Chrome\Application", "$env:ProgramFiles\360\360Chrome\Chrome\Application") }
    )

    foreach ($c in $candidates) {
        foreach ($hive in @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths')) {
            $key = Join-Path $hive $c.Exe
            if (Test-Path -LiteralPath $key) {
                $val = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'(default)'
                if ($val) {
                    $val = ([string] $val).Trim('"')
                    if (Test-Path -LiteralPath $val) { return [pscustomobject]@{ Name = $c.Name; Path = $val } }
                }
            }
        }
        foreach ($d in $c.Dirs) {
            if (-not $d) { continue }
            $candidate = Join-Path $d $c.Exe
            if (Test-Path -LiteralPath $candidate) { return [pscustomobject]@{ Name = $c.Name; Path = $candidate } }
        }
    }
    return $null
}

# 属于本启动器 profile 的浏览器进程（关闭与存活检测都以它为准）。
# 只按命令行里的 profile 路径匹配，绝不按进程名批量操作——那是会误伤用户浏览器的做法。
function Get-WebUIBrowserProcesses {
    param([string] $ProfilePath)
    if (-not $ProfilePath) { return @() }
    $names = @('msedge.exe', 'chrome.exe', 'brave.exe', 'vivaldi.exe', 'opera.exe', '360chrome.exe')
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and $_.CommandLine.Contains($ProfilePath) -and ($names -contains $_.Name)
        })
}

<#
    真正的 WebUI 应用窗口：属于 profile 组、类名 Chrome_WidgetWin_1、标题非空。

    为什么不能用「组内有进程」代替：浏览器会常驻一批**没有窗口**的进程池进程，
    还有 HintWnd / MSCTFIME UI / Sogou_TSF_UI 这类辅助顶层窗口。
    只看进程数会把「用户已经关掉的窗口」误判为「还开着」，
    于是再也不会打开新窗口——这是实测踩到的坑，判据必须落在"窗口"上。
#>
function Get-WebUIWindows {
    param([string] $ProfilePath)
    $pids = @(Get-WebUIBrowserProcesses -ProfilePath $ProfilePath | ForEach-Object { [int] $_.ProcessId })
    if ($pids.Count -eq 0) { return @() }

    $list = New-Object System.Collections.ArrayList
    $cb = [WebUiWindowApi+EnumProc]{
        param($h, $p)
        $owner = 0
        [void] [WebUiWindowApi]::GetWindowThreadProcessId($h, [ref] $owner)
        if ($pids -contains [int] $owner) {
            $sbTitle = New-Object System.Text.StringBuilder 512
            [void] [WebUiWindowApi]::GetWindowText($h, $sbTitle, $sbTitle.Capacity)
            if ($sbTitle.Length -gt 0) {
                $sbClass = New-Object System.Text.StringBuilder 256
                [void] [WebUiWindowApi]::GetClassName($h, $sbClass, $sbClass.Capacity)
                if ($sbClass.ToString() -eq 'Chrome_WidgetWin_1') {
                    [void] $list.Add([pscustomobject]@{ Hwnd = $h; Pid = [int] $owner; Title = $sbTitle.ToString() })
                }
            }
        }
        return $true
    }
    [void] [WebUiWindowApi]::EnumWindows($cb, [System.IntPtr]::Zero)
    return $list.ToArray()
}

<#
    聚焦已有的 WebUI 窗口。

    实测：SetForegroundWindow 从后台进程调用会被 Windows 的前台锁定策略拒绝。
    所以这里只尽力而为，失败**不报错、不抛异常**——用户仍可 Alt+Tab 找到窗口，
    而为此引入 AttachThreadInput 之类的技巧不值得（脆弱且容易被系统更新破坏）。
#>
function Focus-WebUIWindow {
    param([string] $ProfilePath)
    $wins = @(Get-WebUIWindows -ProfilePath $ProfilePath)
    if ($wins.Count -eq 0) { return $false }
    try {
        [void] [WebUiWindowApi]::ShowWindow($wins[0].Hwnd, 9)          # 9 = SW_RESTORE
        [void] [WebUiWindowApi]::SetForegroundWindow($wins[0].Hwnd)
    }
    catch { Write-UILog ("聚焦 WebUI 窗口失败（不影响使用）：{0}" -f $_.Exception.Message) }
    return $true
}

<#
    关闭 WebUI 窗口：按 profile 路径匹配**整组**进程。

    绝对不能只关主 PID：--app 会拉起 8~17 个进程（实测 2026-09-24：10~17 个），
    只关主进程一定留下残留子进程继续吃内存。这里整组关 + 复查补刀（最多 4 轮）。
#>
function Stop-WebUIWindow {
    param([string] $ProfilePath)
    $procs = @(Get-WebUIBrowserProcesses -ProfilePath $ProfilePath)
    if ($procs.Count -eq 0) { return 0 }

    $killed = 0
    for ($round = 1; $round -le 4; $round++) {
        $procs = @(Get-WebUIBrowserProcesses -ProfilePath $ProfilePath)
        if ($procs.Count -eq 0) { break }
        foreach ($p in $procs) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            $killed++
        }
        Start-Sleep -Milliseconds 500
    }

    $left = @(Get-WebUIBrowserProcesses -ProfilePath $ProfilePath).Count
    if ($left -eq 0) { Write-UILog ("已关闭 WebUI 窗口（整组 {0} 个进程）" -f $killed) }
    else { Write-UILog ("WebUI 窗口关闭后仍有 {0} 个进程残留" -f $left) }
    return $killed
}

<#
    取当前服务的 WebUI 地址。

    必须**带 token**：实测 `http://127.0.0.1:3080/` 不带 token 返回 401。
    token 每次启动服务重新签发，所以来源按可靠性排序：
      ① 本次启动流程刚抓到的地址（内存）
      ② state 文件里的 webUrl（启动器重启后仍可用）
      ③ 服务日志里的 `dsh web: http://…?token=…`（正则实测可完整匹配）
      ④ 兜底：不带 token 的地址（浏览器若已持有 cookie 仍能进）
#>
function Get-WebUIUrl {
    if ($script:WebUiUrl) { return $script:WebUiUrl }

    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $saved = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            # 只采用**带 token** 的地址：v1.2.0 用独立浏览器数据目录（没有旧 cookie），
            # 不带 token 访问必定 401。若 state 里存的是旧格式（无 token），继续往下找日志。
            if ($saved -and $saved.webUrl -and $saved.webUrl -match 'token=') { $script:WebUiUrl = $saved.webUrl; return $script:WebUiUrl }
        }
        catch { }
    }

    if (Test-Path -LiteralPath $script:LogFile) {
        try {
            $text = Get-Content -LiteralPath $script:LogFile -Raw -ErrorAction SilentlyContinue
            if ($text) {
                $m = [regex]::Match($text, 'dsh web:\s*(http://[^\s]+)')
                if ($m.Success) { $script:WebUiUrl = $m.Groups[1].Value; return $script:WebUiUrl }
            }
        }
        catch { }
    }

    return "http://127.0.0.1:$($script:EffectivePort)"
}

<#
    打开（或聚焦）WebUI 窗口——四级降级链：

      ① Edge  --app + 独立 profile          能自动关窗
      ② 其他 Chromium 浏览器，同上           能自动关窗（Edge 被卸载时的主要出路）
      ③ 系统默认浏览器 Start-Process <url>   **不能**自动关窗，必须明确告知用户
      ④ 连默认浏览器都没有                   显示地址 + 复制到剪贴板，不报错

    回滚开关：DSH_WEBUI_BROWSER=default → 跳过 ①②，直接走 ③，退回 v1.1.2 的观感。
#>
function Start-WebUIWindow {
    param([string] $Url)

    if (-not $Url) { $Url = Get-WebUIUrl }
    $profileDir = Get-WebUIBrowserProfile

    # 窗口已在 → 聚焦。重复调 --app 会真的开出第二个窗口（实测），必须自己拦。
    if (@(Get-WebUIWindows -ProfilePath $profileDir).Count -gt 0) {
        [void] (Focus-WebUIWindow -ProfilePath $profileDir)
        Write-UILog 'WebUI 窗口已在运行，已切换到该窗口'
        return $true
    }

    if ($env:DSH_WEBUI_BROWSER -ne 'default') {
        $browser = Resolve-WebUIBrowser
        if ($browser) {
            try {
                $argList = @(
                    "--app=`"$Url`"",
                    "--user-data-dir=`"$profileDir`"",
                    '--no-first-run',
                    '--no-default-browser-check'
                )
                Start-Process -FilePath $browser.Path -ArgumentList $argList | Out-Null
                $script:WebUIWindowMode = 'app'
                Write-UILog ("已用 {0} 打开独立窗口（停止服务时会自动关闭）" -f $browser.Name)
                return $true
            }
            catch {
                Write-UILog ("用 {0} 打开窗口失败：{1}" -f $browser.Name, $_.Exception.Message)
            }
        }
        else {
            Write-UILog '未找到 Chromium 系浏览器（Edge / Chrome / Brave / Vivaldi / Opera / 360极速），改用系统默认浏览器'
        }
    }

    try {
        Start-Process $Url | Out-Null
        $script:WebUIWindowMode = 'default'
        if ($env:DSH_WEBUI_BROWSER -eq 'default') {
            Write-UILog '已按回滚开关（DSH_WEBUI_BROWSER=default）用系统默认浏览器打开'
        }
        else {
            Write-UILog '已用系统默认浏览器打开'
        }
        Write-UILog '注意：这种方式打开的标签页无法自动关闭，停止服务后请手动关掉它'
        return $true
    }
    catch { Write-UILog ("打开浏览器失败：{0}" -f $_.Exception.Message) }

    $script:WebUIWindowMode = 'none'
    Write-UILog '未能打开任何浏览器，请手动复制下面的地址访问：'
    Write-UILog $Url
    try { Set-Clipboard -Value $Url; Write-UILog '（地址已复制到剪贴板）' } catch { }
    return $false
}

<#
    「DS开放平台」入口（v1.2.0 开发中，按用户要求由「获取 API Key」更名）。

    固定指向 DeepSeek 开放平台首页：只作快捷入口，用户自己在那里注册/登录/建 Key。
    刻意**不做**任何额外功能——不检测用户是否已配 Key、不按状态高亮、不直达 /api_keys 子页；
    也**不用**受控的 --app 窗口（那是 WebUI 专用的；Key 页面属于用户的日常浏览，走系统默认浏览器）。
#>
function Open-ApiKeyPage {
    $url = 'https://platform.deepseek.com/'
    try {
        Start-Process $url | Out-Null
        Write-UILog '已在浏览器打开 DeepSeek 开放平台'
        return $true
    }
    catch {
        Write-UILog ("打开开放平台失败：{0}" -f $_.Exception.Message)
        Write-UILog ("可手动访问：{0}" -f $url)
        try { Set-Clipboard -Value $url; Write-UILog '（地址已复制到剪贴板）' } catch { }
        return $false
    }
}

# ============================================================ 业务逻辑

function Get-DshWebInstance {
    param([int] $ProbePort, [string[]] $Snapshot, [switch] $Force)
    if ($Snapshot) {
        # 调用方已经有一份 netstat 快照（例如启动前的残留扫描），直接用，不走缓存。
    }
    else {
        # v1.1.2：带 5 秒缓存。界面定时刷新时「服务没在跑」只有这一条路径，
        # 原来每秒都会拉起一个 netstat 进程；缓存后最多 5 秒一次。
        # 用户操作（启动/停止/点刷新）一律带 -Force 立即重探，手感不变。
        # 探测本身刻意不写日志：它每几秒发生一次，写进日志区会把用户信息刷掉。
        $now = Get-Date
        if (-not $Force -and $script:ProbeCache -and (($now - $script:ProbeCache.Time).TotalSeconds -lt 5)) {
            $Snapshot = $script:ProbeCache.Snapshot
        }
        else {
            $Snapshot = & netstat -ano 2>$null
            $script:ProbeCache = [pscustomobject]@{ Time = $now; Snapshot = $Snapshot }
        }
    }
    $hit = $Snapshot | Select-String -Pattern ":$ProbePort\s" | Select-String -Pattern 'LISTENING'
    if (-not $hit) { return $null }
    $ownerPid = ($hit[0].Line -split '\s+')[-1]
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction SilentlyContinue
    $cmdline = if ($proc) { $proc.CommandLine } else { $null }
    return [pscustomobject]@{
        Kind = if ($cmdline -and $cmdline -match 'dsh' -and $cmdline -match 'web') { 'dsh' } else { 'other' }
        Pid  = $ownerPid
    }
}

function Get-DshWebStatus {
    param([switch] $Force)
    $result = [ordered]@{ Running = $false; Port = $script:EffectivePort; Pid = $null }
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $saved = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            if ($saved -and $saved.pid -and (Get-Process -Id ([int]$saved.pid) -ErrorAction SilentlyContinue)) {
                $result.Running = $true
                $result.Pid     = [int] $saved.pid
                $result.Port    = if ($saved.port) { [int] $saved.port } else { $script:EffectivePort }
                return [pscustomobject] $result
            }
        } catch { }
    }
    $inst = Get-DshWebInstance -ProbePort $script:EffectivePort -Force:$Force
    if ($inst -and $inst.Kind -eq 'dsh') { $result.Running = $true; $result.Pid = $inst.Pid }
    return [pscustomobject] $result
}

function Resolve-DshEntry {
    param([string] $DshCmdPath)
    $cmdText = Get-Content -LiteralPath $DshCmdPath -Raw
    $m = [regex]::Match($cmdText, '%dp0%\\([^"]*?\.(?:js|cjs|mjs))')
    if (-not $m.Success) { return $null }
    $candidate = Join-Path (Split-Path -Parent $DshCmdPath) ($m.Groups[1].Value -replace '%%', '%')
    if (-not (Test-Path -LiteralPath $candidate)) { return $null }
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Find-Dsh {
    $found = @(Get-Command dsh -CommandType Application -ErrorAction SilentlyContinue)
    if ($found.Count -gt 0) {
        $preferred = $found | Where-Object { $_.Source -like '*.cmd' } | Select-Object -First 1
        if (-not $preferred) { $preferred = $found | Select-Object -First 1 }
        if ($preferred -and $preferred.Source -and (Test-Path -LiteralPath $preferred.Source)) { return $preferred.Source }
    }
    $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
    if ($npmCommand) {
        $prefix = (& $npmCommand.Source prefix -g 2>$null | Select-Object -First 1)
        if ($prefix) {
            $globalDsh = Join-Path $prefix 'dsh.cmd'
            if (Test-Path -LiteralPath $globalDsh) { return $globalDsh }
        }
    }
    return $null
}

<#
    确认服务真正能响应了再打开浏览器：只判断“端口在监听”不够，
    dsh 监听之后还要几秒才处理请求。
#>
function Wait-HttpReady {
    param([string] $BaseUrl, [int] $TimeoutSeconds = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $req = [System.Net.WebRequest]::Create("$BaseUrl/")
            $req.Method = 'GET'
            $req.Timeout = 2500
            $req.AllowAutoRedirect = $false
            $resp = $req.GetResponse()
            $code = [int] $resp.StatusCode
            $resp.Close()
            if ($code -ge 200 -and $code -lt 400) { return $true }
        }
        catch [System.Net.WebException] {
            $r = $_.Exception.Response
            if ($r) {
                $code = [int] $r.StatusCode
                if ($code -ge 200 -and $code -lt 500) { return $true }
            }
        }
        catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
# ============================================================== 界面 XAML

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="DSH WebUI" Width="600" Height="780"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanMinimize" FontFamily="Microsoft YaHei UI" TextOptions.TextFormattingMode="Ideal">
  <Window.Resources>
    <SolidColorBrush x:Key="Ink"     Color="#1F2937"/>
    <SolidColorBrush x:Key="Muted"   Color="#6B7280"/>
    <SolidColorBrush x:Key="Primary" Color="#2563EB"/>
    <SolidColorBrush x:Key="Danger"  Color="#DC2626"/>
    <SolidColorBrush x:Key="Success" Color="#16A34A"/>
    <SolidColorBrush x:Key="SuccessBg" Color="#DCFCE7"/>
    <SolidColorBrush x:Key="IdleBg"  Color="#F3F4F6"/>
    <SolidColorBrush x:Key="Border"  Color="#E5E7EB"/>
    <SolidColorBrush x:Key="PageBg"  Color="#F5F6F8"/>

    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Primary}"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#BFD4FB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="14.5"/>
      <Setter Property="Padding" Value="0,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#EFF6FF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#DBEAFE"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="MainButton" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="15.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="0,13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.75"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 标题栏图标按钮：必须是真正的 Button。TextBlock 不可交互，鼠标点不到 -->
    <Style x:Key="IconButton" TargetType="Button">
      <Setter Property="Foreground" Value="#9CA3AF"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Width" Value="44"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F3F4F6"/>
                <Setter Property="Foreground" Value="#4B5563"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E5E7EB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border Background="{StaticResource PageBg}" CornerRadius="14" Margin="16">
    <Border.Effect>
      <DropShadowEffect Color="#28000000" BlurRadius="28" ShadowDepth="4" Direction="270"/>
    </Border.Effect>
    <Border CornerRadius="14" Background="White" BorderBrush="{StaticResource Border}" BorderThickness="1">
      <Grid Margin="28,22,28,22">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- 标题栏：整行都可拖动（含中间的空白区）；右侧是最小化/关闭（固定命中区，便于点击） -->
        <Grid Grid.Row="0" x:Name="TitleBarArea" Background="Transparent">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <StackPanel Grid.Column="0" x:Name="TitleBar" Orientation="Horizontal" Background="Transparent">
            <TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="24"
                       Foreground="{StaticResource Primary}" VerticalAlignment="Center"/>
            <TextBlock Text="DSH WebUI" FontSize="21" FontWeight="SemiBold"
                       Foreground="{StaticResource Ink}" Margin="12,0,0,0" VerticalAlignment="Center"/>
            <TextBlock Text="__VERSION__" FontSize="12.5" Foreground="{StaticResource Muted}"
                       Margin="8,0,0,5" VerticalAlignment="Bottom"/>
          </StackPanel>

          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnMin" Content="&#xE921;" FontFamily="Segoe MDL2 Assets" FontSize="12"
                       Foreground="#9CA3AF" Width="44" Height="28" Background="Transparent"
                       Cursor="Hand" ToolTip="最小化" Style="{StaticResource IconButton}"/>
            <Button x:Name="BtnClose" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets" FontSize="12"
                       Foreground="#9CA3AF" Width="44" Height="28" Background="Transparent"
                       Cursor="Hand" ToolTip="关闭" Style="{StaticResource IconButton}"/>
          </StackPanel>
        </Grid>

        <Border Grid.Row="1" Height="1" Background="{StaticResource Border}" Margin="0,18,0,0"/>

        <!-- 状态卡片 -->
        <Grid Grid.Row="2" Margin="0,18,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <!-- 行1：状态 -->
          <TextBlock Grid.Row="0" Grid.Column="0" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets"
                     FontSize="15" Foreground="{StaticResource Success}" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="0" Grid.Column="1" Text="状态：" FontSize="15"
                     Foreground="{StaticResource Muted}" Margin="10,0,0,0" VerticalAlignment="Center"/>
          <Border Grid.Row="0" Grid.Column="2" x:Name="BadgeBorder" Background="{StaticResource SuccessBg}"
                  CornerRadius="12" Padding="12,3">
            <TextBlock x:Name="BadgeText" Text="运行中" FontSize="13.5" FontWeight="SemiBold"
                       Foreground="{StaticResource Success}"/>
          </Border>

          <!-- 行2：端口 + PID -->
          <TextBlock Grid.Row="1" Grid.Column="0" Text="&#xE968;" FontFamily="Segoe MDL2 Assets"
                     FontSize="15" Foreground="{StaticResource Muted}" Margin="0,16,0,0" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="1" Grid.Column="1" Text="端口：" FontSize="15"
                     Foreground="{StaticResource Muted}" Margin="10,16,0,0" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="1" Grid.Column="2" Text="3080" FontSize="15" FontWeight="SemiBold"
                     Foreground="{StaticResource Ink}" Margin="0,16,0,0" VerticalAlignment="Center"/>
          <Border Grid.Row="1" Grid.Column="4" Width="1" Background="{StaticResource Border}"
                  Margin="18,14,18,2" Height="22"/>
          <StackPanel Grid.Row="1" Grid.Column="5" Orientation="Horizontal" Margin="0,16,0,0">
            <TextBlock Text="PID " FontSize="15" FontWeight="SemiBold"
                       Foreground="{StaticResource Ink}" VerticalAlignment="Center"/>
            <TextBlock x:Name="TxtPid" Text="34732" FontSize="15" FontWeight="SemiBold"
                       Foreground="{StaticResource Ink}" VerticalAlignment="Center"/>
          </StackPanel>
        </Grid>

        <Border Grid.Row="3" Height="1" Background="{StaticResource Border}" Margin="0,20,0,0"/>

        <!-- 主按钮 -->
        <Button Grid.Row="4" x:Name="BtnMain" Style="{StaticResource MainButton}"
                Background="{StaticResource Danger}" Margin="0,20,0,0">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="MainIcon" Text="&#xE71A;" FontFamily="Segoe MDL2 Assets" FontSize="15"
                       VerticalAlignment="Center"/>
            <TextBlock x:Name="MainLabel" Text="停止服务" Margin="10,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>

        <!-- 次按钮行（v1.2.0：2 列 → 3 列，中间新增「DS开放平台」入口） -->
        <Grid Grid.Row="5" Margin="0,12,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="12"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="12"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Button Grid.Column="0" x:Name="BtnOpen" Style="{StaticResource SecondaryButton}">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE8A7;" FontFamily="Segoe MDL2 Assets" FontSize="14"
                         Foreground="{StaticResource Primary}" VerticalAlignment="Center"/>
              <TextBlock Text="打开 WebUI" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <Button Grid.Column="2" x:Name="BtnApiKey" Style="{StaticResource SecondaryButton}">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE192;" FontFamily="Segoe MDL2 Assets" FontSize="14"
                         Foreground="{StaticResource Primary}" VerticalAlignment="Center"/>
              <TextBlock Text="DS开放平台" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <Button Grid.Column="4" x:Name="BtnRefresh" Style="{StaticResource SecondaryButton}">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="14"
                         Foreground="{StaticResource Primary}" VerticalAlignment="Center"/>
              <TextBlock Text="刷新" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
        </Grid>

        <!-- 日志 -->
        <Border Grid.Row="6" Height="1" Background="{StaticResource Border}" Margin="0,20,0,0"/>

        <!-- DSH 版本 / 更新入口（v1.2.1）：Row 7 原本空着，正好放这一行。
             启动时自动检查一次新版本，按钮文案随状态变化；
             只有「有新版本」与「检查失败」两种状态可点（见 Update-DshUpdateButton）。 -->
        <Button Grid.Row="7" x:Name="BtnDshUpdate" Style="{StaticResource SecondaryButton}"
                Margin="0,12,0,0" IsEnabled="False">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="DshUpdateIcon" Text="&#xE895;" FontFamily="Segoe MDL2 Assets" FontSize="14"
                       Foreground="{StaticResource Muted}" VerticalAlignment="Center"/>
            <TextBlock x:Name="DshUpdateLabel" Text="正在检查 DSH 版本 ..." Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>

        <Border Grid.Row="8" Background="#F9FAFB" CornerRadius="8" BorderBrush="{StaticResource Border}"
                BorderThickness="1" Margin="0,20,0,0" Padding="14,12">
          <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto">
            <ItemsControl x:Name="LogList">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                    <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="13"
                               Foreground="{StaticResource Success}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                    <TextBlock Text="{Binding}" Margin="10,0,0,0" FontSize="13.5"
                               Foreground="{StaticResource Ink}" TextWrapping="Wrap"/>
                  </StackPanel>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </ScrollViewer>
        </Border>
      </Grid>
    </Border>
  </Border>
</Window>
'@

$xamlText = $xamlText.Replace('Text="3080"', 'Text="' + $script:EffectivePort + '"')
$xamlText = $xamlText.Replace('Text="__VERSION__"', 'Text="' + $script:AppVersion + '"')

$script:appDispatcher = $null

$reader = [System.Xml.XmlNodeReader]::new([xml]$xamlText)
$win = [System.Windows.Markup.XamlReader]::Load($reader)

# ------------------------------------------------------------ 窗口生命周期状态
# 统一成一个退出标志，并在窗口创建后立刻初始化，绝不留“变量未设置”的可能：
#   IsExiting = 真的要退出（托盘「退出」、标题栏 ✕）→ 这时才允许 Close()
#   winClosed = 窗口已经被真正关闭（WPF 里关闭不可逆）→ 之后绝不能再 Show()
# 方案 A：普通关闭一律 Hide()，复用同一个窗口实例，不重建窗口。
$script:IsExiting     = $false
$script:winClosed     = $false
$script:trayHintShown = $false

<#
    显示并前置主窗口。

    托盘双击、托盘菜单「显示主窗口」、「打开 WebUI」都走这里。
    先判断窗口状态再决定是否 Show()：
      - 已经真正关闭（winClosed）→ 只记日志，绝不调用 Show()，
        因为 WPF 对已关闭窗口执行 Show() 必抛 InvalidOperationException；
      - 仍可见（Hide 之后 IsVisible 为 False）→ 不必 Show()，只需置前；
      - 未加载 / 已隐藏 → 才 Show()。
    整个函数不向外抛异常，任何失败都转成日志。

    注意：函数里每个语句都要 [void] 吞掉返回值，否则 WPF 方法的返回值会和
    $true/$false 一起变成数组返回（曾观察到返回 System.Object[]）。
#>
function Show-MainWindow {
    if ($script:winClosed) {
        Write-UILog '窗口已关闭；请重新双击本程序。'
        return $false
    }
    try {
        if (-not $win.IsVisible) { [void] $win.Show() }
        $win.WindowState = [System.Windows.WindowState]::Normal
        [void] $win.Activate()
        # exe 用 CreateNoWindow 启动 PowerShell 时，首个顶层窗口可能被建成隐藏的，
        # 这里用 Win32 强制显示一次（对正常双击启动无副作用）。
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
            [void] [Win32Window]::ShowWindow($h, 5)          # 5 = SW_SHOW
            [void] [Win32Window]::SetForegroundWindow($h)
        } catch { }
        return $true
    }
    catch {
        Write-UILog ("显示窗口失败：{0}" -f $_.Exception.Message)
        return $false
    }
}

<#
    退出前确认（方案 C）。

    只在**服务正在运行时**才打扰用户；服务已停止就直接放行，不弹框。
    标题栏 ✕ 与托盘「退出」两条路径共用本函数，语义才不会分叉。

    返回：
      $true  → 允许退出（调用方继续关窗口 / 结束消息循环）
      $false → 用户选了「取消」，什么都不做
#>
function Confirm-LauncherExit {
    $status = Get-DshWebStatus -Force
    if (-not $status.Running) { return $true }

    $text = @"
DSH 服务仍在运行。

是：退出并停止服务
否：仅退出启动器；服务继续在后台运行。
    如需停止服务，再次打开启动器，点「停止服务」即可。
取消：不退出，返回启动器
"@

    # 默认按钮 = 取消（防误按：直接回车不会把服务顺手停掉）
    $choice = [System.Windows.MessageBox]::Show(
        $text,
        'DSH WebUI',
        [System.Windows.MessageBoxButton]::YesNoCancel,
        [System.Windows.MessageBoxImage]::Warning,
        [System.Windows.MessageBoxResult]::Cancel)

    if ($choice -eq [System.Windows.MessageBoxResult]::Yes) {
        Write-UILog '正在停止服务并退出 ...'
        Stop-DshService
        return $true
    }

    if ($choice -eq [System.Windows.MessageBoxResult]::No) {
        # 「仅退出启动器」：服务继续跑，并明确告诉用户怎么再停它——这正是本轮加该需求的本意
        Write-UILog '已选择「仅退出启动器」：DSH 服务继续在后台运行。'
        Write-UILog '如需停止服务：再次打开启动器，点「停止服务」。'
        try {
            Add-Content -LiteralPath (Join-Path $script:StateDir 'ui-diagnostics.log') `
                -Value ("[{0}] 用户选择「仅退出启动器」，服务保持运行（端口 {1}）" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $status.Port) `
                -Encoding UTF8
        }
        catch { }
        return $true
    }

    Write-UILog '已取消退出（服务与界面都保持原样）。'
    return $false
}

# 窗口首次显示时，纠正“被 CreateNoWindow 建成隐藏窗口”的情况。
# 这里不再调用 Show()：Show() 本身已由主流程 / Show-MainWindow 负责，
# 在 Loaded 里再调一次是多余且危险的（重入）。
$win.Add_Loaded({
    try {
        $script:winHandle = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        [void] [Win32Window]::ShowWindow($script:winHandle, 5)   # 5 = SW_SHOW
        [void] [Win32Window]::SetForegroundWindow($script:winHandle)
    } catch { }

    # v1.1.2：窗口高度写死 726 DIP，在 768p（工作区约 728 DIP）或 150% 缩放的小屏上
    # 会顶满甚至超出屏幕底部，主按钮点不到。这里按当前屏幕的可用工作区设上限：
    #   - 屏幕够高 → MaxHeight 大于 726，窗口保持原尺寸，观感不变；
    #   - 屏幕不够高 → 窗口被压到工作区内，居中的内容可能略有裁剪，但主按钮始终可点。
    # 同时加一道 MinWidth/MinHeight 下限，避免以后放开缩放时被拖成不可用的小尺寸。
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $limH = $wa.Height - 16
        $limW = $wa.Width - 16
        if ($limH -gt 0) { $win.MaxHeight = [Math]::Max(420, $limH) }
        if ($limW -gt 0) { $win.MaxWidth = [Math]::Max(360, $limW) }
        $win.MinWidth = 480
        $win.MinHeight = 520
    } catch { }
})

# 命名元素
$badgeBorder = $win.FindName('BadgeBorder')
$badgeText   = $win.FindName('BadgeText')
$txtPid      = $win.FindName('TxtPid')
$btnMain     = $win.FindName('BtnMain')
$mainLabel   = $win.FindName('MainLabel')
$mainIcon    = $win.FindName('MainIcon')
$btnOpen     = $win.FindName('BtnOpen')
$btnApiKey   = $win.FindName('BtnApiKey')
$btnRefresh  = $win.FindName('BtnRefresh')
$btnDshUpdate   = $win.FindName('BtnDshUpdate')
$dshUpdateLabel = $win.FindName('DshUpdateLabel')
$dshUpdateIcon  = $win.FindName('DshUpdateIcon')
$logList     = $win.FindName('LogList')
$logScroll   = $win.FindName('LogScroll')

$logItems = New-Object System.Collections.ObjectModel.ObservableCollection[string]
$logList.ItemsSource = $logItems

function Write-UILog {
    param([string] $Message)
    if (-not $Message) { return }
    $logItems.Add(("[{0}] {1}" -f (Get-Date).ToString('HH:mm:ss'), $Message))
    # 只保留最近 300 条：窗口开一整天时日志会无限累积，滚动和重绘都会变慢。
    while ($logItems.Count -gt 300) { $logItems.RemoveAt(0) }
    $logScroll.ScrollToEnd()
}

function Update-SetupUI {
    $st = $script:InstallState
    if ($st.Phase -eq 'installing') {
        Write-InstallProgress

        $exited = $true
        if ($st.Pid) {
            $proc = Get-Process -Id $st.Pid -ErrorAction SilentlyContinue
            $exited = -not $proc
        }
        if (-not $exited) {
            # v1.2.1 修复（用户实测）：**绝不要**用 $btnMain.Content 覆盖按钮内容 ——
            # XAML 里它是一个 StackPanel（图标 + 文字两个 TextBlock），一旦被替换成字符串，
            # MainLabel 就脱离可视树，之后 Update-UI 里所有 $mainLabel.Text 更新都会失效，
            # 按钮会永远停在「取消升级」，必须重启启动器才恢复。
            $mainLabel.Text = if ($st.Kind -eq 'update') { '取消升级' } else { '取消安装' }
            return
        }

        if (Complete-DshInstall) {
            if ($st.Kind -eq 'update') {
                # 升级成功：按用户要求**不自动启动服务**，只把版本状态刷成"已是最新"
                $script:DshVersionState.Phase = 'latest'
                $script:DshVersionState.Installed = $st.TargetVersion
                $script:DshVersionState.Latest = $st.TargetVersion
                Update-DshUpdateButton
            }
            else {
                # 首次安装成功 → 继续原来那套启动流程
                Start-DshService
            }
        }
    }
}

<#
    启动 dsh 服务（原主按钮逻辑中「启动」的那一半）。
    假定 node 与 dsh 已经就绪；未就绪时只记录日志并返回。
#>

function Update-UI {
    param([switch] $Force)
    $status = Get-DshWebStatus -Force:$Force
    if ($status.Running) {
        $badgeText.Text = '运行中'
        $badgeText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#16A34A')
        $badgeBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#DCFCE7')
        $txtPid.Text = "$($status.Pid)"
        $mainLabel.Text = '停止服务'
        $mainIcon.Text = [char]0xE71A
        $btnMain.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#DC2626')
    }
    elseif ($script:InstallState -and $script:InstallState.Phase -eq 'installing') {
        # 安装 / 升级 dsh 期间：主按钮变成「取消安装 / 取消升级」，徽章对应显示
        $isUpd = ($script:InstallState.Kind -eq 'update')
        $badgeText.Text = if ($isUpd) { '升级中' } else { '安装中' }
        $badgeText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#B45309')
        $badgeBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FEF3C7')
        $txtPid.Text = '—'
        $mainLabel.Text = if ($isUpd) { '取消升级' } else { '取消安装' }
        $mainIcon.Text = [char]0xE711
        $btnMain.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#B45309')
    }
    else {
        $badgeText.Text = '已停止'
        $badgeText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#6B7280')
        $badgeBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F3F4F6')
        $txtPid.Text = '—'
        $mainLabel.Text = '启动服务'
        $mainIcon.Text = [char]0xE768
        $btnMain.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#2563EB')
    }

    # v1.2.0：托盘动态项跟着状态走（服务在跑显示「停止服务」，否则「启动服务」）
    if ($script:miToggle) {
        $script:miToggle.Text = if ($status.Running) { '停止服务' } else { '启动服务' }
    }

    # v1.2.1：顺带读一次 dsh 版本检查结果（整个会话只查一次，结果到了就更新那行按钮）
    Update-DshVersionResult

    # 推进安装状态（读取 npm 输出、判断结束、成功后自动继续启动服务）
    Update-SetupUI
}

# ------------------------------------------------------------------ 事件

$win.Add_MouseLeftButtonDown({ })

$titleBarArea = $win.FindName('TitleBarArea')
$btnMin       = $win.FindName('BtnMin')
$btnClose     = $win.FindName('BtnClose')

# 拖动：挂到**整个标题栏行**上。原先只挂在 x:Name="TitleBar" 那个 StackPanel（Auto 宽度、
# 只包住图标和"DSH WebUI"两个字）上，于是只有点在文字笔画上才能拖，标题栏中间的空白区
# 完全没有背景、不参与命中测试，按住也拖不动。
# 现在这个 Grid 自带 Background="Transparent"，整行（含空白）都能接收鼠标。
# 右侧的最小化/关闭按钮不受影响：ButtonBase 会在 MouseLeftButtonDown 上把事件标记为已处理，
# 不会冒泡到这个处理器。
if ($titleBarArea) {
    $titleBarArea.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.ButtonState -eq [System.Windows.Input.MouseButtonState]::Pressed) {
            try { $win.DragMove() } catch { }
        }
    })
}

if ($btnMin) {
$btnMin.Add_Click({
    try {
        $win.WindowState = [System.Windows.WindowState]::Minimized
        $win.Hide()
        if ($script:trayIcon) {
            $script:trayIcon.Visible = $true
            $script:trayIcon.ShowBalloonTip(1500, 'DSH WebUI', '已最小化到托盘，双击图标可重新打开。', 'Info')
        }
    } catch { }
})
}

if ($btnClose) {
    # 点 ✕ = 真正退出：必须先置 IsExiting，否则 Closing 会把它当成“关闭到托盘”而取消。
    # v1.2.0：退出前先过 Confirm-LauncherExit（方案 C）——仅当服务在运行时才弹三选一。
    $btnClose.Add_Click({
        if (-not (Confirm-LauncherExit)) { return }
        $script:IsExiting = $true
        if ($script:trayIcon) { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() }
        $win.Close()
        if ($script:appDispatcher) { $script:appDispatcher.InvokeShutdown() }
    })
}

$btnMain.Add_Click({
    # 正在安装 dsh 时，主按钮变成「取消安装」
    if ($script:InstallState.Phase -eq 'installing') {
        Write-UILog '正在取消安装 ...'
        if ($script:InstallState.Pid) {
            Stop-Process -Id $script:InstallState.Pid -Force -ErrorAction SilentlyContinue
        }
        $script:InstallState.Phase = 'cancelled'
        Write-UILog '已取消 dsh 安装（可用 npm install --global @deepseek-ai/dsh 手动安装）。'
        Update-UI
        return
    }

    # 先检测 Node.js：缺失时给出下载地址，不做无用的后续尝试
    $node = Find-NodeRuntime
    if (-not $node.Node) {
        Show-NodeMissingHint
        return
    }

    $status = Get-DshWebStatus -Force
    if ($status.Running) { Stop-DshService }
    else                 { Start-DshService }
})

$btnOpen.Add_Click({
    $status = Get-DshWebStatus
    if ($status.Running) {
        $base = "http://127.0.0.1:$($status.Port)"
        if (-not (Wait-HttpReady -BaseUrl $base -TimeoutSeconds 10)) {
            Write-UILog '服务尚未响应，请稍等几秒再点「打开 WebUI」'
            return
        }
        # v1.2.0：用**带 token** 的地址开受控独立窗口（不带 token 会 401）；
        # 窗口已在时改为聚焦，不会开出第二个窗口。
        [void] (Start-WebUIWindow -Url (Get-WebUIUrl))
    }
    else { Write-UILog '服务尚未运行，请先点「启动服务」' }
})

# v1.2.0：「DS开放平台」入口。固定指向 DeepSeek 开放平台首页，用**系统默认浏览器**打开
# （刻意不用受控 --app 窗口：那是 WebUI 专用的，Key 页面属于用户的日常浏览）。
$btnApiKey.Add_Click({ [void] (Open-ApiKeyPage) })

# v1.2.1：dsh 版本行——有新版时点击升级；检查失败时点击重试
# （二次确认对话框在 Invoke-DshUpdate 里，默认按钮是「否」）
$btnDshUpdate.Add_Click({ Invoke-DshUpdate })

$btnRefresh.Add_Click({ Update-UI -Force; Write-UILog '状态已刷新' })

# ==================================================== Node.js 与 dsh 的安装流程
# 目标：首次启动时把「装 Node / 装 dsh」的每一步都显示给用户，
#       并且在真正可以运行时明确提示；安装全程异步，窗口不假死。
$script:InstallState = [pscustomobject]@{
    Phase      = 'idle'      # idle | installing | done | failed | cancelled
    Kind       = 'install'   # install | update（v1.2.1：同一个状态机服务两条流程）
    TargetVersion = $null    # update 时的目标版本，用于完成文案
    Pid        = $null
    LogOffset  = 0           # stdout 已读字节偏移
    ErrOffset  = 0           # stderr 已读字节偏移（npm 把下载进度写在 stderr）
    LogPath    = $null
    NpmPath    = $null
    NpmArgs    = $null
    Progress   = -1
    LastNote   = 0           # 上次用兜底提示的时间刻度
    EncFallback = $false     # npm 输出不是 UTF-8 时改用系统 ANSI（中文系统为 GBK）
    StartedAt  = $null
}

# ---------------------------------------------------------------- dsh 版本检测与升级（v1.2.1）
# 目标：让"能装 dsh 却不能升 dsh"这个缺口闭合，同时**不打扰、不多联网**：
#   · 只在**启动器启动时检查一次**（整个会话不再重复访问 npm）；
#   · 检查失败静默处理（只在日志写一行），绝不弹窗；
#   · 升级必须由用户点按钮 + 二次确认，且升级前自动停服务、升级后**不自动重启**；
#   · README 里"不联网"的措辞随之改为"除启动时检查一次 dsh 新版本外，不联网、无遥测"。
$script:DshVersionState = [pscustomobject]@{
    Phase     = 'idle'    # idle | checking | latest | outdated | failed | nosh
    Installed = $null
    Latest    = $null
    Pid       = $null
    OutPath   = $null
    CheckedAt = $null
}

$script:NodeUrl = 'https://nodejs.org/zh-cn/download'

<#
    找出 node 与 npm 的真实路径。
    PATH 找不到时再探测几个常见安装位置，并把这些目录补进 PATH，
    这样后续的 npm 调用也能用。
#>
function Find-NodeRuntime {
    $result = [pscustomobject]@{ Node = $null; Npm = $null }
    $nodeCmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nodeCmd) { $result.Node = $nodeCmd.Source }

    $npmCmd = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $npmCmd) { $npmCmd = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($npmCmd) { $result.Npm = $npmCmd.Source }

    if (-not $result.Node) {
        $candidates = @(
            "$env:ProgramFiles\nodejs\node.exe",
            "${env:ProgramFiles(x86)}\nodejs\node.exe",
            "$env:LOCALAPPDATA\Programs\nodejs\node.exe",
            "$env:APPDATA\nvm\node.exe",
            "$env:ProgramData\nvm\node.exe"
        )
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate) {
                $dir = Split-Path -Parent $candidate
                $env:Path = "$dir;$env:Path"
                $result.Node = $candidate
                $npmCand = Join-Path $dir 'npm.cmd'
                if (-not $result.Npm -and (Test-Path -LiteralPath $npmCand)) { $result.Npm = $npmCand }
                Write-UILog ("node 不在 PATH 中，已从 {0} 找到" -f $dir)
                break
            }
        }
    }
    return $result
}

# ---------------------------------------------------------------- dsh 版本检测与升级（v1.2.1）

# 读本机已安装的 dsh 版本（直接读 npm 全局包里的 package.json：不启进程、不联网）
function Get-DshInstalledVersion {
    $pkg = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\package.json'
    if (-not (Test-Path -LiteralPath $pkg)) { return $null }
    try { return [string] ((Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json).version) }
    catch { return $null }
}

<#
    判断 $Latest 是否比 $Installed 新。
    刻意**不用字符串比较**（那样 0.1.5-rc.10 会被判成比 rc.9 旧），
    而是拆成 主.次.补 + 预发布后缀：主版本相同、都带 -rc.N 时比尾部数字。
    正式版优先于预发布；无法解析时保守地认为"不同即更新"（提示里两个版本号都写出来，
    用户自己能判断）。
#>
function Test-DshNewerVersion {
    param([string] $Installed, [string] $Latest)
    if (-not $Installed -or -not $Latest -or $Installed -eq $Latest) { return $false }
    $rx = '^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$'
    $a = [regex]::Match($Installed, $rx); $b = [regex]::Match($Latest, $rx)
    if (-not $a.Success -or -not $b.Success) { return $true }
    $an = @([int] $a.Groups[1].Value, [int] $a.Groups[2].Value, [int] $a.Groups[3].Value)
    $bn = @([int] $b.Groups[1].Value, [int] $b.Groups[2].Value, [int] $b.Groups[3].Value)
    for ($i = 0; $i -lt 3; $i++) {
        if ($bn[$i] -gt $an[$i]) { return $true }
        if ($bn[$i] -lt $an[$i]) { return $false }
    }
    $ap = if ($a.Groups[4].Success) { $a.Groups[4].Value } else { '' }
    $bp = if ($b.Groups[4].Success) { $b.Groups[4].Value } else { '' }
    if ($ap -eq $bp) { return $false }
    if ($ap -eq '') { return $false }   # 已装正式版、npm 上却是预发布 → 不算更新
    if ($bp -eq '') { return $true }    # 已装预发布、npm 上已是正式版 → 算更新
    $da = 0; $db = 0
    [void][int]::TryParse([regex]::Match($ap, '\d+$').Value, [ref] $da)
    [void] [int]::TryParse([regex]::Match($bp, '\d+$').Value, [ref] $db)
    if ($db -ne $da) { return ($db -gt $da) }
    return $true
}

<#
    启动时**只跑一次**的新版本检查。
    问 npm「最新版是多少」，输出重定向到文件，结果由界面已有的 3 秒定时器读取
    —— 与安装流程同构（独立进程 + 文件 + 轮询），不用 Start-Job（那会绑在会话上）。
#>
function Start-DshVersionCheck {
    $st = $script:DshVersionState
    if ($st.Phase -eq 'checking') { return }
    $st.Phase = 'checking'
    $st.Installed = Get-DshInstalledVersion
    if (-not $st.Installed) {
        # 还没装 dsh：没有可比对象，按钮显示「DSH 尚未安装」
        $st.Phase = 'nosh'
        Update-DshUpdateButton
        return
    }
    $node = Find-NodeRuntime
    if (-not $node.Npm) {
        $st.Phase = 'failed'
        Write-UILog '检查 dsh 更新失败：未找到 npm（可点下方按钮重试）'
        Update-DshUpdateButton
        return
    }
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
    }
    $out = Join-Path $script:StateDir 'dsh-version-check.log'
    Remove-Item -LiteralPath $out, "$out.err" -Force -ErrorAction SilentlyContinue
    $quotedNpm = '"' + $node.Npm + '"'
    try {
        $proc = Start-Process -FilePath 'cmd.exe' `
            -ArgumentList @('/d', '/c', "$quotedNpm view @deepseek-ai/dsh version") `
            -WindowStyle Hidden `
            -RedirectStandardOutput $out -RedirectStandardError "$out.err" -PassThru
    }
    catch {
        $st.Phase = 'failed'
        Write-UILog ("检查 dsh 更新失败：{0}" -f $_.Exception.Message)
        Update-DshUpdateButton
        return
    }
    $st.Pid = $proc.Id
    $st.OutPath = $out
    $st.CheckedAt = Get-Date
    Update-DshUpdateButton
}

# 读取检查结果（由 Update-UI 顺带调用；成功与失败都只写日志，不弹窗）
function Update-DshVersionResult {
    $st = $script:DshVersionState
    if ($st.Phase -ne 'checking' -or -not $st.Pid) { return }

    if (Get-Process -Id $st.Pid -ErrorAction SilentlyContinue) {
        # 超时保护：网络慢时不无限等（60 秒），到点放弃并允许手动重试
        if ($st.CheckedAt -and ((Get-Date) - $st.CheckedAt).TotalSeconds -gt 60) {
            Stop-Process -Id $st.Pid -Force -ErrorAction SilentlyContinue
            $st.Phase = 'failed'
            Write-UILog '检查 dsh 更新超时（网络较慢），可点下方按钮重试'
            Update-DshUpdateButton
        }
        return
    }

    $raw = ''
    try { if (Test-Path -LiteralPath $st.OutPath) { $raw = [string] (Get-Content -LiteralPath $st.OutPath -Raw) } } catch { }
    $m = [regex]::Match($raw, '(\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?)')
    if (-not $m.Success) {
        $st.Phase = 'failed'
        Write-UILog '检查 dsh 更新失败（拿不到版本号，多半是网络或代理问题），可点下方按钮重试'
        Update-DshUpdateButton
        return
    }
    $st.Latest = $m.Groups[1].Value
    if (Test-DshNewerVersion -Installed $st.Installed -Latest $st.Latest) {
        $st.Phase = 'outdated'
        # 只陈述事实：日志区里没有按钮，写"点下方升级"会误导（用户实测反馈）
        Write-UILog ("发现 dsh 新版本：{0} → {1}" -f $st.Installed, $st.Latest)
    }
    else {
        $st.Phase = 'latest'
        Write-UILog ("dsh 已是最新版本（{0}）" -f $st.Installed)
    }
    Update-DshUpdateButton
}

# 按当前状态刷新那行按钮的文案与可用性
function Update-DshUpdateButton {
    $st = $script:DshVersionState
    if (-not $BtnDshUpdate) { return }
    $brush = { param($hex) [System.Windows.Media.BrushConverter]::new().ConvertFrom($hex) }
    switch ($st.Phase) {
        'latest' {
            $BtnDshUpdate.IsEnabled = $false
            $DshUpdateLabel.Text = ('当前 DSH 已是最新版本（{0}）' -f $st.Installed)
            $DshUpdateLabel.Foreground = (& $brush '#16A34A'); $DshUpdateIcon.Foreground = (& $brush '#16A34A')
        }
        'outdated' {
            $BtnDshUpdate.IsEnabled = $true
            $DshUpdateLabel.Text = ('更新 DSH（{0} → {1}）' -f $st.Installed, $st.Latest)
            $DshUpdateLabel.Foreground = (& $brush '#2563EB'); $DshUpdateIcon.Foreground = (& $brush '#2563EB')
        }
        'failed' {
            $BtnDshUpdate.IsEnabled = $true
            $DshUpdateLabel.Text = '检查 DSH 更新失败（点击重试）'
            $DshUpdateLabel.Foreground = (& $brush '#B45309'); $DshUpdateIcon.Foreground = (& $brush '#B45309')
        }
        'nosh' {
            $BtnDshUpdate.IsEnabled = $false
            $DshUpdateLabel.Text = 'DSH 尚未安装'
            $DshUpdateLabel.Foreground = (& $brush '#6B7280'); $DshUpdateIcon.Foreground = (& $brush '#6B7280')
        }
        default {
            $BtnDshUpdate.IsEnabled = $false
            $DshUpdateLabel.Text = '正在检查 DSH 版本 ...'
            $DshUpdateLabel.Foreground = (& $brush '#6B7280'); $DshUpdateIcon.Foreground = (& $brush '#6B7280')
        }
    }
}

<#
    升级前的二次确认（默认按钮是「否」，防误触）。
    单独抽成函数是为了**可测**：回归测试可以覆盖它，不必真的弹窗。
#>
function Confirm-DshUpdate {
    param([string] $Installed, [string] $Latest)
    $msg = @"
将把 dsh 从 $Installed 升级到 $Latest。

· 升级前会先停止 DSH 服务；
· 升级完成后不会自动重启服务，需要你点「启动服务」；
· 实际执行的就是官方升级命令：npm install --global @deepseek-ai/dsh@latest

继续吗？
"@
    $choice = [System.Windows.MessageBox]::Show(
        $msg, 'DSH WebUI — 升级 dsh',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question,
        [System.Windows.MessageBoxResult]::No)
    return ($choice -eq [System.Windows.MessageBoxResult]::Yes)
}

<#
    升级 dsh：二次确认 → 停服务 → 复用安装流程执行 npm install @latest。
    升级完成后**不自动重启服务**（把"什么时候重启"的决定权留给用户）。
#>
function Invoke-DshUpdate {
    $st = $script:DshVersionState
    if ($st.Phase -eq 'failed') {      # 失败态点击 = 重试检查
        $st.Phase = 'idle'
        Start-DshVersionCheck
        return
    }
    if ($st.Phase -ne 'outdated') { return }

    if (-not (Confirm-DshUpdate -Installed $st.Installed -Latest $st.Latest)) {
        Write-UILog '已取消 dsh 升级。'
        return
    }

    $node = Find-NodeRuntime
    if (-not $node.Npm) {
        Write-UILog '未找到 npm，无法升级 dsh。'
        return
    }

    # npm 会覆盖 dsh 安装目录，服务在跑时可能占用文件 → 先停服务
    $status = Get-DshWebStatus -Force
    if ($status.Running) {
        Write-UILog '升级 dsh 前先停止服务 ...'
        Stop-DshService
    }

    $script:InstallState.NpmPath = $node.Npm
    $script:InstallState.Kind = 'update'
    $script:InstallState.TargetVersion = $st.Latest
    Start-DshInstall -Mode update
}

# 提示用户安装 Node.js（带可点击的下载地址）
function Show-NodeMissingHint {
    Write-UILog '未检测到 Node.js —— DSH WebUI 需要先安装 Node.js 20 或更高版本。'
    Write-UILog ("下载地址：{0}" -f $script:NodeUrl)
    Write-UILog '安装完请重新打开本程序（安装包会自动把 node 加入 PATH）。'
    try { Start-Process $script:NodeUrl } catch { Write-UILog '（未能自动打开浏览器，请手动复制上面的网址）' }
}

<#
    启动 npm 全局安装 dsh。用 cmd /c 调用 npm.cmd 并把输出重定向到文件，
    之后由 Update-SetupUI 增量读取，实现「安装进度可见」。
#>
function Start-DshInstall {
    param([string] $Mode = 'install')     # install | update（v1.2.1：同一套流程服务两条命令）
    $npm = $script:InstallState.NpmPath
    if (-not $npm -or -not (Test-Path -LiteralPath $npm)) {
        $script:InstallState.Phase = 'failed'
        Write-UILog '未找到 npm，无法自动安装 dsh。'
        Write-UILog ("请安装 Node.js（自带 npm）：{0}" -f $script:NodeUrl)
        try { Start-Process $script:NodeUrl } catch { }
        return
    }

    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
    }
    $isUpdate = ($Mode -eq 'update')
    $logPath = if ($isUpdate) {
        Join-Path $script:StateDir 'npm-update-dsh.log'
    } else {
        Join-Path $script:StateDir 'npm-install-dsh.log'
    }
    Remove-Item -LiteralPath $logPath, "$logPath.err" -Force -ErrorAction SilentlyContinue

    if ($isUpdate) {
        Write-UILog ("开始升级 dsh 到 {0} ..." -f $script:InstallState.TargetVersion)
        Write-UILog '升级进度会实时显示在下面；期间窗口可以最小化，不会中断升级。'
    }
    else {
        Write-UILog '开始安装 dsh（首次约 200 MB，需要联网，请耐心等待）...'
        Write-UILog '安装进度会实时显示在下面；期间窗口可以最小化，不会中断安装。'
    }

    # 升级走官方命令 install @latest（比 npm update 更明确，且能一步到最新）
    $npmArgs = if ($isUpdate) { 'install --global @deepseek-ai/dsh@latest' } else { 'install --global @deepseek-ai/dsh' }
    $quotedNpm = '"' + $npm + '"'
    try {
        $proc = Start-Process -FilePath 'cmd.exe' `
            -ArgumentList @('/d','/c',"$quotedNpm $npmArgs") `
            -WindowStyle Hidden `
            -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err" `
            -PassThru
    }
    catch {
        $script:InstallState.Phase = 'failed'
        Write-UILog ("启动 npm 失败：{0}" -f $_.Exception.Message)
        return
    }

    $script:InstallState.Phase     = 'installing'
    $script:InstallState.Pid       = $proc.Id
    $script:InstallState.LogPath   = $logPath
    $script:InstallState.LogOffset = 0
    $script:InstallState.ErrOffset = 0
    $script:InstallState.Progress  = -1
    $script:InstallState.LastNote  = 0
    $script:InstallState.EncFallback = $false
    $script:InstallState.Kind      = $Mode
    $script:InstallState.StartedAt = Get-Date
    Write-UILog ("npm 进程已启动（PID {0}），正在下载 ..." -f $proc.Id)
    if ($isUpdate) { Write-UILog '（如果想中止升级，再点一次主按钮即可）' }
    else { Write-UILog '（如果想中止安装，再点一次主按钮即可）' }
}

<#
    读取 npm 新增的输出并转成界面日志。
    npm 的进度是原地刷新的一行，用字节偏移增量读会读到很多碎片，
    所以按“取最后一次匹配”的方式显示，而不是每来一段就打印一行。
#>
function Write-InstallProgress {
    $st = $script:InstallState
    if (-not $st.LogPath) { return }

    # npm 把「下载/写入进度」写到 stderr、把结果写到 stdout，两个流必须各自
    # 记录读取偏移，否则会互相顶掉、漏读进度（实测确认过这一点）。
    $streams = @(
        [pscustomobject]@{ Path = $st.LogPath;         Offset = 'LogOffset' },
        [pscustomobject]@{ Path = "$($st.LogPath).err"; Offset = 'ErrOffset' }
    )
    $lines = New-Object System.Collections.Generic.List[string]

    foreach ($stream in $streams) {
        if (-not (Test-Path -LiteralPath $stream.Path)) { continue }
        $offset = [int64] $st.($stream.Offset)
        $text = $null
        try {
            $fs = [System.IO.File]::Open($stream.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $len = $fs.Length
                if ($len -gt $offset) {
                    [void] $fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
                    $buf = New-Object byte[] ($len - $offset)
                    $read = $fs.Read($buf, 0, $buf.Length)
                    $st.($stream.Offset) = $len
                    if ($read -gt 0) {
                        if ($st.EncFallback) {
                            $text = [System.Text.Encoding]::Default.GetString($buf, 0, $read)
                        }
                        else {
                            try {
                                $strict = New-Object System.Text.UTF8Encoding($false, $true)
                                $text = $strict.GetString($buf, 0, $read)
                            }
                            catch {
                                # npm 在中文系统上可能按 GBK 输出，切换到系统 ANSI 解码
                                $st.EncFallback = $true
                                $text = [System.Text.Encoding]::Default.GetString($buf, 0, $read)
                            }
                        }
                    }
                }
            }
            finally { $fs.Dispose() }
        }
        catch { }

        if ($text) {
            # 去掉 ANSI 控制序列与回车（npm 的进度条是原地刷新的）
            $clean = $text -replace "`e\[[0-9;]*[A-Za-z]", '' -replace "`r", ''
            foreach ($line in ($clean -split "`n")) {
                $t = $line.Trim()
                if ($t) { [void] $lines.Add($t) }
            }
        }
    }

    if ($lines.Count -eq 0) { return }

    # 1) 百分比进度：取这一批里最后一次出现的数字，避免刷屏
    $pct = -1
    foreach ($line in $lines) {
        $m = [regex]::Match($line, '(\d{1,3})%')
        if ($m.Success) { $pct = [int] $m.Groups[1].Value }
    }
    if ($pct -ge 0 -and $pct -ne $st.Progress) {
        $st.Progress = $pct
        Write-UILog ("  安装进度 {0}%" -f $pct)
    }

    # 2) 报错与警告：原样透出，方便用户判断是不是网络问题
    foreach ($line in $lines) {
        if ($line -match 'npm (ERR|error)|ERR!|EACCES|ETIMEDOUT|ECONNRESET|ENOTFOUND|EAI_AGAIN|deprecated') {
            Write-UILog ("  [npm] {0}" -f $line)
        }
    }

    # 3) 长时间没有百分比变化时，用最后一行的内容给个“还在动”的反馈
    $now = (Get-Date).TimeOfDay.TotalSeconds
    if ($now - $st.LastNote -ge 20) {
        $st.LastNote = $now
        $tail = $lines[$lines.Count - 1]
        if ($tail.Length -gt 100) { $tail = $tail.Substring(0, 100) + '...' }
        if ($tail) { Write-UILog ("  安装中 ... {0}" -f $tail) }
        $st.Progress = -1        # 允许同样的百分比再次提示
    }
}

<#
    安装收尾：重新定位 dsh，并明确告诉用户“现在可以运行了”。
#>
function Complete-DshInstall {
    $st = $script:InstallState
    $elapsed = if ($st.StartedAt) { [int] ((Get-Date) - $st.StartedAt).TotalSeconds } else { 0 }
    # npm 输出可能还有尾巴，补读一次
    Write-InstallProgress

    $dshPath = Find-Dsh
    $entry = $null
    if ($dshPath) { $entry = Resolve-DshEntry -DshCmdPath $dshPath }

    if ($entry) {
        $st.Phase = 'done'
        if ($st.Kind -eq 'update') {
            # 升级完成：按用户要求**不自动重启服务**，只提示（重启时机由用户定）
            Write-UILog ("dsh 已升级完成，用时 {0} 秒。" -f $elapsed)
            Write-UILog ("入口：{0}" -f $entry)
            Write-UILog ("目标版本：{0}；点「启动服务」即可用新版本启动。" -f $st.TargetVersion)
            if ($script:trayIcon) {
                try { $script:trayIcon.ShowBalloonTip(2000, 'DSH WebUI', 'dsh 升级完成，请点「启动服务」。', 'Info') } catch { }
            }
            return $true
        }
        Write-UILog ("dsh 安装完成，用时 {0} 秒。" -f $elapsed)
        Write-UILog ("入口：{0}" -f $entry)
        Write-UILog '现在可以运行了，正在继续启动服务 ...'
        if ($script:trayIcon) {
            try { $script:trayIcon.ShowBalloonTip(2000, 'DSH WebUI', 'dsh 安装完成，正在启动服务。', 'Info') } catch { }
        }
        return $true
    }

    $st.Phase = 'failed'
    if ($st.Kind -eq 'update') {
        Write-UILog 'npm 已结束，但升级可能没有成功（找不到 dsh 命令）。'
        Write-UILog '必要时可回滚到旧版本（把 <旧版本号> 换成升级前的版本）：'
        Write-UILog '  npm install --global @deepseek-ai/dsh@<旧版本号>'
    }
    else {
        Write-UILog 'npm 已结束，但仍找不到 dsh 命令，安装可能没有成功。'
    }
    if ($st.LogPath -and (Test-Path -LiteralPath $st.LogPath)) {
        Write-UILog ("完整安装日志：{0}" -f $st.LogPath)
    }
    Write-UILog '常见原因与处理：'
    Write-UILog '  - 网络或代理问题：设置 HTTPS_PROXY 后重试，或改用国内镜像源'
    Write-UILog '  - Node.js 版本过低：需要 Node.js 20 或更高'
    Write-UILog ("  - 手动安装命令：npm install --global @deepseek-ai/dsh")
    return $false
}

# 启动 dsh 服务：node 与 dsh 未就绪时给出提示或转入异步安装
function Start-DshService {
    Write-UILog '正在启动服务 ...'
    $btnMain.IsEnabled = $false
    try {
        $node = Find-NodeRuntime
        if (-not $node.Node) { throw ('未找到 Node.js。请先安装：{0}' -f $script:NodeUrl) }

        $dshPath = Find-Dsh
        if (-not $dshPath) {
            # 首次使用：进入异步安装流程，安装完成后会自动继续启动
            $script:InstallState.NpmPath = $node.Npm
            Start-DshInstall
            return
        }

        $entry = Resolve-DshEntry -DshCmdPath $dshPath
        if (-not $entry) { throw '无法解析 dsh 入口脚本' }

        if (-not (Test-Path -LiteralPath $script:StateDir)) {
            New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
        }
        Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue

        # 不指定 -WorkingDirectory：node 继承启动器钉好的 cwd（exe 所在目录）。
        # dsh 的工作区由 WebUI 里新建/选择的工作区决定，跟这个 cwd 没有关系。
        $proc = Start-Process -FilePath 'node' `
            -ArgumentList @($entry, 'web', '--no-open', '--port', "$($script:EffectivePort)") `
            -WindowStyle Hidden `
            -RedirectStandardOutput $script:LogFile -RedirectStandardError "$($script:LogFile).err" `
            -PassThru

        $state = [ordered]@{
            pid = $proc.Id; port = $script:EffectivePort
            url = "http://127.0.0.1:$($script:EffectivePort)"
            log = $script:LogFile; startedAt = (Get-Date).ToString('s')
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
        Write-UILog ("进程已启动（PID {0}），等待就绪 ..." -f $proc.Id)

        # v1.2.0 修复（重要）：**必须以服务日志里带 token 的地址为准**。
        # 实测：端口开始监听比日志打印 `dsh web: …?token=…` 早约 1.8 秒，而 v1.2.0 用的是
        # **独立浏览器数据目录**（没有旧 cookie），不带 token 访问必定 401，页面会显示
        # "dsh web authentication required"。所以端口探测只当"服务已起来"的信号，
        # 绝不用它当地址；只有始终等不到 token 行时才退化，并明确告警。
        $url = $null
        $portReady = $false
        $portReadyAt = $null
        $deadline = (Get-Date).AddSeconds(120)
        $waited = 0
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 800
            $waited++
            if ($waited % 10 -eq 0) { Write-UILog ("  已等待约 {0} 秒 ..." -f [int]($waited * 0.8)) }
            $win.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{})

            # ① 首选且唯一可靠：日志里带 token 的地址
            if (Test-Path -LiteralPath $script:LogFile) {
                $t = Get-Content -LiteralPath $script:LogFile -Raw -ErrorAction SilentlyContinue
                if ($t) {
                    $m = [regex]::Match($t, 'dsh web:\s*(http://[^\s]+)')
                    if ($m.Success -and $m.Groups[1].Value -match 'token=') { $url = $m.Groups[1].Value; break }
                }
            }

            # ② 端口监听只是"服务起来了"的信号，不能当地址用（比 token 早约 1.8 秒）
            if (-not $portReady) {
                $probe = & netstat -ano 2>$null | Select-String -Pattern ":$($script:EffectivePort)\s" | Select-String -Pattern 'LISTENING'
                if ($probe) {
                    $portReady = $true
                    $portReadyAt = Get-Date
                    Write-UILog '端口已监听，正在等待服务输出带 token 的访问地址 ...'
                }
            }
            elseif ($portReadyAt -and ((Get-Date) - $portReadyAt).TotalSeconds -gt 45) {
                # ③ 45 秒仍等不到 token：退化（例如将来 dsh 改了输出格式），并明确告警
                $url = "http://127.0.0.1:$($script:EffectivePort)"
                Write-UILog '警告：45 秒内没等到服务输出带 token 的地址，已改用不带 token 的地址。'
                Write-UILog '     若页面提示 "authentication required"，请点「停止服务」后重新启动。'
                break
            }

            if ($proc.HasExited) { break }
        }

        if (-not $url) { throw "服务未在 120 秒内就绪（PID $($proc.Id)）" }

        # v1.2.0：把**带 token** 的地址记进内存与 state。
        # 两个场景都要用它：打开受控窗口；窗口被用户手动关掉后再从托盘/界面打开。
        # （不带 token 访问返回 401，所以这里不能只存 http://127.0.0.1:端口）
        $script:WebUiUrl = $url
        $state['webUrl'] = $url
        $state | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding UTF8

        $baseUrl = "http://127.0.0.1:$($script:EffectivePort)"
        Write-UILog '端口已就绪，确认服务能响应 ...'
        if (-not (Wait-HttpReady -BaseUrl $baseUrl)) {
            throw "服务端口已监听，但 30 秒内没有正常响应。稍等片刻后点「打开 WebUI」再试。"
        }
        Write-UILog '服务已就绪，可以使用了。'
        if ($script:trayIcon) {
            try { $script:trayIcon.ShowBalloonTip(2000, 'DSH WebUI', '服务已启动，WebUI 窗口即将打开。', 'Info') } catch { }
        }
        # v1.2.0 修复：服务每次启动都会**重新签发 token**，上一次打开的窗口里那个页面
        # 必然已经失效。若此时还残留着旧窗口，Start-WebUIWindow 会把它当成"已打开"而只做聚焦，
        # 用户看到的就是 "authentication required"。所以开窗前先把残留窗口（本启动器 profile
        # 的整个进程组）关掉，再开一个带新 token 的窗口。
        $profileDir = Get-WebUIBrowserProfile
        if (@(Get-WebUIWindows -ProfilePath $profileDir).Count -gt 0) {
            Write-UILog '检测到上次遗留的 WebUI 窗口（其登录凭据已失效），先关闭它再打开新窗口'
            [void] (Stop-WebUIWindow -ProfilePath $profileDir)
        }
        # 交给浏览器联动——开一个受控的独立窗口（停止服务时能自动关掉它）
        [void] (Start-WebUIWindow -Url $url)
    }
    catch { Write-UILog ("失败：{0}" -f $_.Exception.Message) }
    finally { $btnMain.IsEnabled = $true; Update-UI }
}

# 停止服务（原主按钮逻辑中「停止」的那一半，逻辑保持不变并加了明确反馈）
function Stop-DshService {
    $status = Get-DshWebStatus
    if (-not $status.Running) { return }
    Write-UILog ("正在停止 {0} ..." -f $status.Port)
    $btnMain.IsEnabled = $false
    try {
        # v1.2.0：先关掉受控的 WebUI 窗口（按 profile 关整组），再停服务。
        # 这样页面上不会留着"连接断开"的样子；两步互不依赖（关窗只认 profile 路径），
        # 任何一步失败都不会影响另一步。
        $profileDir = Get-WebUIBrowserProfile
        [void] (Stop-WebUIWindow -ProfilePath $profileDir)

        $targetPid = [int] $status.Pid
        Stop-Process -Id $targetPid -ErrorAction SilentlyContinue
        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 250
            $win.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{})
        }
        if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
            Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 600
        }
        if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
            Write-UILog ("失败：PID {0} 无法结束" -f $targetPid)
        }
        else {
            Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$($script:LogFile).err" -Force -ErrorAction SilentlyContinue
            Write-UILog ("已停止，端口 {0} 已释放" -f $status.Port)
            # v1.2.0：窗口是受控的独立窗口时已经自动关掉了；只有降级到系统默认浏览器时才要提醒手动关。
            if ($script:WebUIWindowMode -eq 'default') {
                Write-UILog '提醒：系统默认浏览器里那个 DSH 标签页不会自动关闭，请手动关掉它（显示"需要重新连接"属正常）'
            }
            $script:WebUIWindowMode = 'none'
            $script:WebUiUrl = $null
        }
    }
    catch { Write-UILog ("失败：{0}" -f $_.Exception.Message) }
    finally { $btnMain.IsEnabled = $true; Update-UI }
}


$win.Add_Closing({
    param($sender, $e)

    # 方案 A：只要不是真退出，就把这次关闭取消掉，改成 Hide() 收进托盘。
    # 这样窗口实例一直活着，托盘双击/菜单随时能把它显示回来，
    # 不会出现“窗口已关闭、托盘图标还在”的半死状态。
    if (-not $script:IsExiting) {
        $e.Cancel = $true
        try {
            $win.Hide()
            if ($script:trayIcon) {
                $script:trayIcon.Visible = $true
                if (-not $script:trayHintShown) {
                    $script:trayHintShown = $true
                    $script:trayIcon.ShowBalloonTip(1500, 'DSH WebUI', '窗口已收进托盘，双击图标可重新打开；要退出请用托盘菜单「退出」。', 'Info')
                }
            }
        } catch { }
        Write-UILog '已把窗口收进托盘（服务继续运行）；双击托盘图标可重新打开。'
        return
    }

    $script:winClosed = $true          # 真退出：窗口已关闭
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
# v1.1.2：原来 1 秒一次，现在 3 秒一次。服务在跑时读 state 文件已经很便宜，
# 服务没在跑时靠 Get-DshWebInstance 的 5 秒 netstat 缓存兜住，所以这里放宽不影响手感，
# 但闲时几乎不再有规律性的进程创建。用户操作后都走 Update-UI -Force，立即重探。
$timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.Add_Tick({ Update-UI })
$timer.Start()

# 窗口图标：XAML 的 Window.Icon 不接受 data: URI，只能在代码里加载。
# 同时把加载结果写进日志——任务栏图标出问题时，这行日志能立刻区分
# “图标没加载上” 和 “加载上了但归属不对”。
try {
    $icoPath = Join-Path $PSScriptRoot 'app.ico'
    if (-not (Test-Path -LiteralPath $icoPath)) {
        $icoPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'app.ico'
    }
    if (-not (Test-Path -LiteralPath $icoPath)) {
        Write-UILog '未找到 app.ico（不影响使用，但窗口/任务栏会用默认图标）'
    }
    else {
        # 从多尺寸 ico 里挑最接近 32x32 的一层给任务栏用。
        # 直接让 WPF 从 ico 取帧往往拿到 16x16 那层，任务栏把它放大就发糊。
        $icoStream = [System.IO.File]::OpenRead($icoPath)
        try {
            $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
                $icoStream,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $frames = @($decoder.Frames)
            $pick = $frames | Sort-Object { [Math]::Abs([int]$_.PixelWidth - 32) } | Select-Object -First 1
            if ($pick) {
                $win.Icon = $pick
                # 用户反馈：界面日志里这条与启动诊断的「窗口图标」重复，已移除界面提示；
                # 诊断信息仍写入 %LOCALAPPDATA%\dsh-web-launcher\ui-diagnostics.log。
            }
            else {
                Write-UILog 'app.ico 里没有可用图层，窗口图标未设置'
            }
        }
        finally { $icoStream.Close() }
    }
}
catch { Write-UILog ("加载 app.ico 失败：{0}" -f $_.Exception.Message) }

$win.Add_ContentRendered({
    Write-UILog ("欢迎使用 DSH WebUI {0}" -f $script:AppVersion)
    Write-UILog '点主按钮即可启动或停止服务'
    # 任务栏/窗口图标的诊断：换图标或任务栏图标不对时先看这两行，
    # 同时落盘到 %LOCALAPPDATA%\dsh-web-launcher\ui-diagnostics.log 便于事后排查
    $iconDesc = if ($win.Icon) { "$($win.Icon.PixelWidth)x$($win.Icon.PixelHeight)" } else { '未设置' }
    Write-UILog ("任务栏标识：{0}" -f $script:AumidStatus)
    # 「窗口图标」同样只在 ui-diagnostics.log 里保留（下面的 diagLines），界面日志不再重复提示
    try {
        if (-not (Test-Path -LiteralPath $script:StateDir)) {
            New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
        }
        $diagLines = @(
            ("[{0}] DSH WebUI 启动诊断" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
            ("界面版本       : {0}" -f $script:AppVersion)
            ("AppUserModelID : {0}" -f $script:AumidStatus)
            ("窗口图标       : {0}" -f $iconDesc)
        )
        Set-Content -LiteralPath (Join-Path $script:StateDir 'ui-diagnostics.log') -Value $diagLines -Encoding UTF8
    }
    catch { }
    Update-UI

    # 窗口若被建成隐藏的，这里显式显示并提到前台（Show-MainWindow 内含守卫）
    [void] (Show-MainWindow)

    # v1.2.1：启动时检查一次 dsh 新版本。**整个会话只查这一次**（唯一的联网行为），
    # 失败静默（只写一行日志），不弹窗、不阻塞界面。
    try { Start-DshVersionCheck }
    catch { Write-UILog ("检查 dsh 更新失败：{0}" -f $_.Exception.Message) }

    try {
        $win.Topmost = $true
        $win.Topmost = $false
    }
    catch { }
})


# ---------------------------------------------------------------- 系统托盘
# 退出标志已在窗口创建后初始化（$script:IsExiting），这里不要再重复赋值，
# 否则会把「正在退出」的状态覆盖回 $false，导致窗口关不掉。
$script:trayIcon = $null
# v1.2.0：托盘菜单对象与「启动/停止服务」动态项要在别处（Update-UI、界面自检）也能访问，
# 因此存到脚本作用域，不再只是局部变量。
$script:trayMenu = $null
$script:miToggle = $null
try {
    $script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
    # 托盘图标：用 app.ico（和 exe、窗口标题栏保持一致）。
    # 之前误用了 SystemIcons.Application（系统默认图标），所以托盘显示的不是自定义图。
    $trayIco = $null
    foreach ($cand in @(
        (Join-Path $PSScriptRoot 'app.ico'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'app.ico'))) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $trayIco = $cand; break }
    }
    if ($trayIco) {
        try { $script:trayIcon.Icon = New-Object System.Drawing.Icon($trayIco, 32, 32) }
        catch { $script:trayIcon.Icon = [System.Drawing.SystemIcons]::Application }
    } else {
        $script:trayIcon.Icon = [System.Drawing.SystemIcons]::Application
    }
    $script:trayIcon.Text = 'DSH WebUI'
    $script:trayIcon.Visible = $true

    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miShow = $trayMenu.Items.Add('显示主窗口')
    # v1.2.0：一个动态项——服务在跑显示「停止服务」，否则「启动服务」（文案由 Update-UI 刷新）
    $miToggle = $trayMenu.Items.Add('启动服务')
    $miOpen = $trayMenu.Items.Add('打开 WebUI')
    $miApiKey = $trayMenu.Items.Add('DS开放平台')
    [void] $trayMenu.Items.Add('-')
    $miExit = $trayMenu.Items.Add('退出')
    $script:trayMenu = $trayMenu
    $script:miToggle = $miToggle

    $miShow.Add_Click({
        [void] (Show-MainWindow)
    })

    # v1.2.0：托盘里可直接启停服务，不必先恢复主窗口再点主按钮。
    # 状态一律 -Force 立即重探；动作结束后用气泡反馈结果，并刷新动态项文案。
    $miToggle.Add_Click({
        $st = Get-DshWebStatus -Force
        if ($st.Running) {
            Stop-DshService
            if ($script:trayIcon) { try { $script:trayIcon.ShowBalloonTip(2000, 'DSH WebUI', '服务已停止。', 'Info') } catch { } }
        }
        else {
            Start-DshService
            if ($script:trayIcon) { try { $script:trayIcon.ShowBalloonTip(2000, 'DSH WebUI', '服务已启动。', 'Info') } catch { } }
        }
        Update-UI -Force
    })

    $miApiKey.Add_Click({ [void] (Open-ApiKeyPage) })

    $miOpen.Add_Click({
        $status = Get-DshWebStatus
        if ($status.Running) {
            $base = "http://127.0.0.1:$($status.Port)"
            if (Wait-HttpReady -BaseUrl $base -TimeoutSeconds 10) {
                # v1.2.0：带 token 开受控独立窗口；窗口已在则聚焦
                # （实测重复执行 --app 会真的开出第二个窗口，所以不能无脑再开）
                [void] (Start-WebUIWindow -Url (Get-WebUIUrl))
            }
            else { Write-UILog '服务尚未响应，请稍后再试' }
        }
        else {
            [void] (Show-MainWindow)
            Write-UILog '服务尚未运行，请先点「启动服务」'
        }
    })

    $miExit.Add_Click({
        # v1.2.0：与标题栏 ✕ 共用同一套退出确认（方案 C）。
        # 先从托盘把主窗口显示出来，让对话框有明确的归属，用户看得见它在问什么。
        [void] (Show-MainWindow)
        if (-not (Confirm-LauncherExit)) { return }
        # 真正退出：先置 IsExiting（否则 Closing 会把关闭取消掉），再关窗口
        $script:IsExiting = $true
        try { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() } catch { }
        $win.Close()
        if ($script:appDispatcher) { $script:appDispatcher.InvokeShutdown() }
    })

    $script:trayIcon.ContextMenuStrip = $trayMenu
    $script:trayIcon.Add_MouseDoubleClick({
        [void] (Show-MainWindow)
    })
}
catch {
    Write-UILog ("托盘初始化失败：{0}" -f $_.Exception.Message)
}

# 用 Show() + 显式消息循环，而不是 ShowDialog()：
# 隐藏窗口（收进托盘）时不会结束程序，只有显式 Shutdown 才退出。
# 注意不要用 [System.Windows.Application]::Current —— 这里并没有 Application
# 对象（窗口是独立创建的），访问它会报“找不到属性 ShutdownMode”。
$script:appDispatcher = $win.Dispatcher
$win.Show() | Out-Null
$win.Dispatcher.InvokeAsync({ }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null

# ------------------------------------------------------------------ 界面自检
# 仅供回归测试：正常双击运行完全不受影响（不设 DSH_WEBUI_SELFTEST 就什么都不做）。
# 覆盖用户实际会遇到的路径：关闭到托盘 → 托盘双击恢复 → 反复循环 → 真正退出。
if ($env:DSH_WEBUI_SELFTEST) {
    Write-UILog ("SELFTEST 开始：{0}" -f $env:DSH_WEBUI_SELFTEST)
    $script:SelfTestSteps = @($env:DSH_WEBUI_SELFTEST -split ';' | Where-Object { $_ })
    $script:SelfTestIndex = 0
    # 结果同时落盘：exe 用 CreateNoWindow 启动 PowerShell，stdout 看不到，只能写文件取证
    $script:SelfTestLog = Join-Path $env:TEMP 'dsh-webui-selftest.log'
    Remove-Item -LiteralPath $script:SelfTestLog -Force -ErrorAction SilentlyContinue
    function Write-SelfTestLog {
        param([string] $Message)
        try { Add-Content -LiteralPath $script:SelfTestLog -Value $Message -Encoding UTF8 } catch { }
    }
    Write-SelfTestLog ("SELFTEST start: {0}" -f $env:DSH_WEBUI_SELFTEST)
    $selfTestTimer = New-Object System.Windows.Threading.DispatcherTimer
    $selfTestTimer.Interval = [TimeSpan]::FromMilliseconds(900)
    $selfTestTimer.Add_Tick({
        if ($script:SelfTestIndex -ge $script:SelfTestSteps.Count) {
            $selfTestTimer.Stop()
            Write-UILog 'SELFTEST 步骤执行完毕，请求退出'
            Write-SelfTestLog 'SELFTEST done -> request quit'
            # 走真正的退出路径：先置 IsExiting，再关窗口
            $script:IsExiting = $true
            try { if ($script:trayIcon) { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() } } catch { }
            $win.Close()
            if ($script:appDispatcher) { $script:appDispatcher.InvokeShutdown() }
            return
        }
        $stepName = $script:SelfTestSteps[$script:SelfTestIndex]
        $script:SelfTestIndex++
        switch ($stepName) {
            'show' {
                $ok = Show-MainWindow
                $m = ("SELFTEST show -> {0} (visible={1} closed={2} exiting={3})" -f $ok, $win.IsVisible, $script:winClosed, $script:IsExiting)
                Write-UILog $m; Write-SelfTestLog $m
            }
            'close-to-tray' {
                # 等价于任何“关闭窗口”的请求（Alt+F4 / 任务栏关闭等）。
                # 方案 A：Closing 取消关闭并 Hide()，窗口实例保留。
                $win.Close()
                $m = ("SELFTEST close-to-tray -> visible={0} closed={1} exiting={2} [期望 False/False/False]" -f $win.IsVisible, $script:winClosed, $script:IsExiting)
                Write-UILog $m; Write-SelfTestLog $m
            }
            'minimize' {
                # 等价于点「—」：Hide()，不触发 Closing
                $win.Hide()
                $m = ("SELFTEST minimize -> visible={0} closed={1} [期望 False/False]" -f $win.IsVisible, $script:winClosed)
                Write-UILog $m; Write-SelfTestLog $m
            }
            'tray-double-click' {
                # 复刻托盘双击处理器：窗口隐藏时 Show() 并置前
                if (-not $win.IsVisible) { [void] $win.Show() }
                $win.WindowState = [System.Windows.WindowState]::Normal
                [void] $win.Activate()
                $m = ("SELFTEST tray-double-click -> visible={0} closed={1} [期望 True/False]" -f $win.IsVisible, $script:winClosed)
                Write-UILog $m; Write-SelfTestLog $m
            }
            'cycle' {
                # 一次跑完「关闭到托盘 → 托盘双击恢复」，用于连续循环验证
                $win.Close()
                if (-not $win.IsVisible) { [void] $win.Show() }
                $win.WindowState = [System.Windows.WindowState]::Normal
                [void] $win.Activate()
                $m = ("SELFTEST cycle -> visible={0} closed={1} [期望 True/False]" -f $win.IsVisible, $script:winClosed)
                Write-UILog $m; Write-SelfTestLog $m
            }
            'true-exit' {
                # 等价于托盘菜单「退出」：先置 IsExiting 再关窗口，这次应真的关闭
                $script:IsExiting = $true
                $win.Close()
                $m = ("SELFTEST true-exit -> visible={0} closed={1} exiting={2} [期望 False/True/True]" -f $win.IsVisible, $script:winClosed, $script:IsExiting)
                Write-UILog $m; Write-SelfTestLog $m
            }
            'main-button' {
                # 只读取主按钮当前状态并记录，绝不触发它。
                # 曾经用一个假“运行中”状态去驱动「停止服务」链路，结果误伤到运行中的
                # dsh 进程（PowerShell 按名字清理更是危险）。自检从此不碰任何进程。
                $m = ("SELFTEST main-button-state -> label='{0}' enabled={1}" -f $mainLabel.Text, $btnMain.IsEnabled)
                Write-UILog $m; Write-SelfTestLog $m
            }
            'webui-browser' {
                # v1.2.0 只读：只探测浏览器与 profile 目录，绝不启动或关闭任何进程
                $b = Resolve-WebUIBrowser
                if ($b) { $m = ("SELFTEST webui-browser -> {0} @ {1}" -f $b.Name, $b.Path) }
                else { $m = 'SELFTEST webui-browser -> 未找到 Chromium 系浏览器（将降级到系统默认浏览器）' }
                Write-UILog $m; Write-SelfTestLog $m
                $m2 = ("SELFTEST webui-profile -> {0}" -f (Get-WebUIBrowserProfile))
                Write-UILog $m2; Write-SelfTestLog $m2
            }
            'webui-state' {
                # v1.2.0 只读：窗口存活检测的实际取值（窗口数 / 组内进程数 / 当前降级模式）
                $prof  = Get-WebUIBrowserProfile
                $wins  = @(Get-WebUIWindows -ProfilePath $prof)
                $procs = @(Get-WebUIBrowserProcesses -ProfilePath $prof)
                $hasToken = [bool] ($script:WebUiUrl -match 'token=')
                $m = ("SELFTEST webui-state -> 窗口={0} 组内进程={1} 模式={2} url带token={3}" -f `
                        $wins.Count, $procs.Count, $script:WebUIWindowMode, $hasToken)
                Write-UILog $m; Write-SelfTestLog $m
            }
            'tray-menu' {
                # v1.2.0 只读：列出托盘菜单项，确认新增入口都在、动态启停项的文案正确
                $items = New-Object System.Collections.ArrayList
                if ($script:trayMenu) {
                    foreach ($it in $script:trayMenu.Items) {
                        [void] $items.Add($(if ($it.Text) { $it.Text } else { '---' }))
                    }
                }
                $m = ("SELFTEST tray-menu -> {0}" -f ($items -join ' | '))
                Write-UILog $m; Write-SelfTestLog $m
            }
            'api-key' {
                # v1.2.0 只读：确认两处「DS开放平台」入口都已挂接。
                # 刻意**不点击**——点了会真的打开浏览器，自检不该有这种副作用。
                $hasTrayItem = [bool] ($script:trayMenu -and @($script:trayMenu.Items | Where-Object { $_.Text -eq 'DS开放平台' }).Count)
                $m = ("SELFTEST api-key -> 主界面按钮={0} 托盘菜单项={1} 目标=https://platform.deepseek.com/" -f `
                        [bool] $btnApiKey, $hasTrayItem)
                Write-UILog $m; Write-SelfTestLog $m
            }
            'dsh-version' {
                # v1.2.1 只读：报告 dsh 版本检测状态与那行按钮的文案。
                # 不触发检查、不升级（自检绝不改环境）。
                $st = $script:DshVersionState
                $m = ("SELFTEST dsh-version -> phase={0} installed={1} latest={2} 版本行可点={3}" -f `
                        $st.Phase, $st.Installed, $st.Latest, $btnDshUpdate.IsEnabled)
                Write-UILog $m; Write-SelfTestLog $m
                $m2 = ("SELFTEST dsh-update-button -> '{0}'" -f $dshUpdateLabel.Text)
                Write-UILog $m2; Write-SelfTestLog $m2
            }
            'btn-structure' {
                # v1.2.1 防回归（用户实测缺陷）：主按钮的 Content 必须**始终是那个 StackPanel**
                # （含 MainIcon / MainLabel）。曾经的写法 `$btnMain.Content = '取消安装'` 会把整个
                # StackPanel 换成字符串，MainLabel 因此脱离可视树，之后所有文案更新失效 ——
                # 表现为"升级完成后按钮一直显示取消升级，必须重启启动器"。
                $isPanel = ($btnMain.Content -is [System.Windows.Controls.StackPanel])
                $inTree  = ($null -ne $mainLabel.Parent)
                $m = ("SELFTEST btn-structure -> Content类型={0} 是StackPanel={1} MainLabel有父级={2} 当前文案='{3}'" -f `
                        $btnMain.Content.GetType().Name, $isPanel, $inTree, $mainLabel.Text)
                Write-UILog $m; Write-SelfTestLog $m
            }
            'btn-label-cycle' {
                # v1.2.1 修复验证：模拟「升级中 → 升级完成」，主按钮文案必须能切回去
                # （用户实测缺陷正是"完成后仍停在取消升级"）。
                # 技巧：把 InstallState.Pid 指向当前进程，让 Update-SetupUI 认为"npm 还在跑"，
                # 从而只设置文案、不会真的去走 Complete-DshInstall。
                $origPhase = $script:InstallState.Phase
                $origKind = $script:InstallState.Kind
                $origPid = $script:InstallState.Pid
                $script:InstallState.Kind = 'update'
                $script:InstallState.Phase = 'installing'
                $script:InstallState.Pid = $PID
                Update-UI
                $during = $mainLabel.Text
                $script:InstallState.Phase = 'done'
                $script:InstallState.Pid = $null
                Update-UI
                $after = $mainLabel.Text
                $script:InstallState.Phase = $origPhase
                $script:InstallState.Kind = $origKind
                $script:InstallState.Pid = $origPid
                Update-UI
                $m = ("SELFTEST btn-label-cycle -> 升级中='{0}' 完成后='{1}'（期望：取消升级 / 启动服务或停止服务）" -f $during, $after)
                Write-UILog $m; Write-SelfTestLog $m
            }
            default {
                Write-UILog ("SELFTEST 未知步骤：{0}" -f $stepName)
                Write-SelfTestLog ("SELFTEST unknown step: {0}" -f $stepName)
            }
        }
    })
    $selfTestTimer.Start()
}

[System.Windows.Threading.Dispatcher]::Run()
$timer.Stop()

# ------------------------------------------------------------------ 测试用提前返回
# 只在开发/自动化测试时使用：设置 DSH_WEBUI_IMPORT_ONLY 后，本脚本变成“只定义函数”，
# 不进入消息循环、不显示窗口，方便对安装进度等纯逻辑做单元测试。
if ($env:DSH_WEBUI_IMPORT_ONLY) { return }
# 退出时务必销毁托盘图标，否则会在通知区域留下一个点不动的幽灵图标
try { if ($script:trayIcon) { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() } } catch { }
Write-UILog '程序已退出。'

