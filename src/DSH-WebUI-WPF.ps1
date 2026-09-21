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

# 工作区：单文件 exe 会把本脚本释放到临时目录运行，那时 $PSScriptRoot 无意义，
# 启动器通过 DSH_WEBUI_WORKSPACE 传入真实目录。没有该变量时按脚本位置推断。
$script:DefaultWorkspace = $null
if ($env:DSH_WEBUI_WORKSPACE -and (Test-Path -LiteralPath $env:DSH_WEBUI_WORKSPACE -PathType Container)) {
    $script:DefaultWorkspace = $env:DSH_WEBUI_WORKSPACE
}
if (-not $script:DefaultWorkspace) {
    $parentDir = Split-Path -Parent $PSScriptRoot
    if ($parentDir -and (Test-Path -LiteralPath $parentDir -PathType Container)) {
        $script:DefaultWorkspace = $parentDir
    } else {
        $script:DefaultWorkspace = $PSScriptRoot
    }
}
$script:Workspace = $script:DefaultWorkspace

# ============================================================ 业务逻辑

function Get-DshWebInstance {
    param([int] $ProbePort, [string[]] $Snapshot)
    if (-not $Snapshot) { $Snapshot = & netstat -ano 2>$null }
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
    $result = [ordered]@{ Running = $false; Port = $script:EffectivePort; Pid = $null; Workspace = $null }
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $saved = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            if ($saved -and $saved.pid -and (Get-Process -Id ([int]$saved.pid) -ErrorAction SilentlyContinue)) {
                $result.Running   = $true
                $result.Pid       = [int] $saved.pid
                $result.Port      = if ($saved.port) { [int] $saved.port } else { $script:EffectivePort }
                $result.Workspace = $saved.workspace
                return [pscustomobject] $result
            }
        } catch { }
    }
    $inst = Get-DshWebInstance -ProbePort $script:EffectivePort
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
        Title="DSH WebUI" Width="600" Height="760"
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

        <!-- 标题栏：左侧图标+标题可拖动，右侧是最小化/关闭（固定命中区，便于点击） -->
        <Grid Grid.Row="0" Background="Transparent">
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

          <!-- 行3：工作区 -->
          <TextBlock Grid.Row="2" Grid.Column="0" Text="&#xE8B7;" FontFamily="Segoe MDL2 Assets"
                     FontSize="15" Foreground="{StaticResource Muted}" Margin="0,14,0,0" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="2" Grid.Column="1" Text="工作区：" FontSize="15"
                     Foreground="{StaticResource Muted}" Margin="10,14,0,0" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="2" Grid.Column="2" Grid.ColumnSpan="4" x:Name="TxtWorkspace"
                     Text="__WORKSPACE__" FontSize="15" Foreground="{StaticResource Ink}"
                     Margin="0,14,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
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

        <!-- 次按钮行 -->
        <Grid Grid.Row="5" Margin="0,12,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="16"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Button Grid.Column="0" x:Name="BtnOpen" Style="{StaticResource SecondaryButton}">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE8A7;" FontFamily="Segoe MDL2 Assets" FontSize="14"
                         Foreground="{StaticResource Primary}" VerticalAlignment="Center"/>
              <TextBlock Text="打开 WebUI" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <Button Grid.Column="2" x:Name="BtnRefresh" Style="{StaticResource SecondaryButton}">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="14"
                         Foreground="{StaticResource Primary}" VerticalAlignment="Center"/>
              <TextBlock Text="刷新" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
        </Grid>

        <!-- 日志 -->
        <Border Grid.Row="6" Height="1" Background="{StaticResource Border}" Margin="0,20,0,0"/>

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
$xamlText = $xamlText.Replace('Text="__WORKSPACE__"', 'Text="' + $script:Workspace + '"')

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

# 窗口首次显示时，纠正“被 CreateNoWindow 建成隐藏窗口”的情况。
# 这里不再调用 Show()：Show() 本身已由主流程 / Show-MainWindow 负责，
# 在 Loaded 里再调一次是多余且危险的（重入）。
$win.Add_Loaded({
    try {
        $script:winHandle = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        [void] [Win32Window]::ShowWindow($script:winHandle, 5)   # 5 = SW_SHOW
        [void] [Win32Window]::SetForegroundWindow($script:winHandle)
    } catch { }
})

# 命名元素
$badgeBorder = $win.FindName('BadgeBorder')
$badgeText   = $win.FindName('BadgeText')
$txtPid      = $win.FindName('TxtPid')
$txtWs       = $win.FindName('TxtWorkspace')
$btnMain     = $win.FindName('BtnMain')
$mainLabel   = $win.FindName('MainLabel')
$mainIcon    = $win.FindName('MainIcon')
$btnOpen     = $win.FindName('BtnOpen')
$btnRefresh  = $win.FindName('BtnRefresh')
$logList     = $win.FindName('LogList')
$logScroll   = $win.FindName('LogScroll')

$logItems = New-Object System.Collections.ObjectModel.ObservableCollection[string]
$logList.ItemsSource = $logItems

function Write-UILog {
    param([string] $Message)
    if (-not $Message) { return }
    $logItems.Add(("[{0}] {1}" -f (Get-Date).ToString('HH:mm:ss'), $Message))
    $logScroll.ScrollToEnd()
}

#>
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
            $btnMain.Content = '取消安装'
            return
        }

        if (Complete-DshInstall) {
            # 安装成功 → 继续原来那套启动流程
            Start-DshService
        }
    }
}

<#
    启动 dsh 服务（原主按钮逻辑中「启动」的那一半）。
    假定 node 与 dsh 已经就绪；未就绪时只记录日志并返回。
#>

function Update-UI {
    $status = Get-DshWebStatus
    if ($status.Running) {
        $badgeText.Text = '运行中'
        $badgeText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#16A34A')
        $badgeBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#DCFCE7')
        $txtPid.Text = "$($status.Pid)"
        $txtWs.Text  = if ($status.Workspace) { $status.Workspace } else { $script:Workspace }
        $mainLabel.Text = '停止服务'
        $mainIcon.Text = [char]0xE71A
        $btnMain.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#DC2626')
    }
    elseif ($script:InstallState -and $script:InstallState.Phase -eq 'installing') {
        # 安装 dsh 期间：主按钮变成「取消安装」，徽章显示「安装中」
        $badgeText.Text = '安装中'
        $badgeText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#B45309')
        $badgeBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FEF3C7')
        $txtPid.Text = '—'
        $txtWs.Text  = $script:Workspace
        $mainLabel.Text = '取消安装'
        $mainIcon.Text = [char]0xE711
        $btnMain.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#B45309')
    }
    else {
        $badgeText.Text = '已停止'
        $badgeText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#6B7280')
        $badgeBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F3F4F6')
        $txtPid.Text = '—'
        $txtWs.Text  = $script:Workspace
        $mainLabel.Text = '启动服务'
        $mainIcon.Text = [char]0xE768
        $btnMain.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#2563EB')
    }

    # 推进安装状态（读取 npm 输出、判断结束、成功后自动继续启动服务）
    Update-SetupUI
}

# ------------------------------------------------------------------ 事件

$win.Add_MouseLeftButtonDown({ })

$titleBar = $win.FindName('TitleBar')
$btnMin   = $win.FindName('BtnMin')
$btnClose = $win.FindName('BtnClose')

if ($titleBar) {
    $titleBar.Add_MouseLeftButtonDown({
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
    # 点 ✕ = 真正退出：必须先置 IsExiting，否则 Closing 会把它当成“关闭到托盘”而取消
    $btnClose.Add_Click({
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

    $status = Get-DshWebStatus
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
        Start-Process $base
        Write-UILog ("已在浏览器打开 http://127.0.0.1:{0}" -f $status.Port)
        Write-UILog '（停止服务后该标签页需手动关闭，这是浏览器限制）'
    }
    else { Write-UILog '服务尚未运行，请先点「启动服务」' }
})

$btnRefresh.Add_Click({ Update-UI; Write-UILog '状态已刷新' })

# ==================================================== Node.js 与 dsh 的安装流程
# 目标：首次启动时把「装 Node / 装 dsh」的每一步都显示给用户，
#       并且在真正可以运行时明确提示；安装全程异步，窗口不假死。
$script:InstallState = [pscustomobject]@{
    Phase      = 'idle'      # idle | installing | done | failed | cancelled
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
    $logPath = Join-Path $script:StateDir 'npm-install-dsh.log'
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

    Write-UILog '开始安装 dsh（首次约 200 MB，需要联网，请耐心等待）...'
    Write-UILog '安装进度会实时显示在下面；期间窗口可以最小化，不会中断安装。'

    $quotedNpm = '"' + $npm + '"'
    try {
        $proc = Start-Process -FilePath 'cmd.exe' `
            -ArgumentList @('/d','/c',"$quotedNpm install --global @deepseek-ai/dsh") `
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
    $script:InstallState.StartedAt = Get-Date
    Write-UILog ("npm 进程已启动（PID {0}），正在下载 ..." -f $proc.Id)
    Write-UILog '（如果想中止安装，再点一次主按钮即可）'
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
        Write-UILog ("dsh 安装完成，用时 {0} 秒。" -f $elapsed)
        Write-UILog ("入口：{0}" -f $entry)
        Write-UILog '现在可以运行了，正在继续启动服务 ...'
        if ($script:trayIcon) {
            try { $script:trayIcon.ShowBalloonTip(2000, 'DSH WebUI', 'dsh 安装完成，正在启动服务。', 'Info') } catch { }
        }
        return $true
    }

    $st.Phase = 'failed'
    Write-UILog 'npm 已结束，但仍找不到 dsh 命令，安装可能没有成功。'
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

        $proc = Start-Process -FilePath 'node' `
            -ArgumentList @($entry, 'web', '--no-open', '--port', "$($script:EffectivePort)") `
            -WorkingDirectory $script:Workspace -WindowStyle Hidden `
            -RedirectStandardOutput $script:LogFile -RedirectStandardError "$($script:LogFile).err" `
            -PassThru

        $state = [ordered]@{
            pid = $proc.Id; port = $script:EffectivePort
            url = "http://127.0.0.1:$($script:EffectivePort)"
            workspace = $script:Workspace; log = $script:LogFile; startedAt = (Get-Date).ToString('s')
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
        Write-UILog ("进程已启动（PID {0}），等待就绪 ..." -f $proc.Id)

        $url = $null
        $deadline = (Get-Date).AddSeconds(120)
        $waited = 0
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 800
            $waited++
            if ($waited % 10 -eq 0) { Write-UILog ("  已等待约 {0} 秒 ..." -f [int]($waited * 0.8)) }
            $win.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{})
            if (Test-Path -LiteralPath $script:LogFile) {
                $t = Get-Content -LiteralPath $script:LogFile -Raw -ErrorAction SilentlyContinue
                if ($t) { $m = [regex]::Match($t, 'dsh web:\s*(http://[^\s]+)'); if ($m.Success) { $url = $m.Groups[1].Value; break } }
            }
            $probe = & netstat -ano 2>$null | Select-String -Pattern ":$($script:EffectivePort)\s" | Select-String -Pattern 'LISTENING'
            if ($probe) { $url = "http://127.0.0.1:$($script:EffectivePort)"; break }
            if ($proc.HasExited) { break }
        }

        if (-not $url) { throw "服务未在 120 秒内就绪（PID $($proc.Id)）" }

        $baseUrl = "http://127.0.0.1:$($script:EffectivePort)"
        Write-UILog '端口已就绪，确认服务能响应 ...'
        if (-not (Wait-HttpReady -BaseUrl $baseUrl)) {
            throw "服务端口已监听，但 30 秒内没有正常响应。稍等片刻后点「打开 WebUI」再试。"
        }
        Write-UILog '服务已就绪，可以使用了。'
        if ($script:trayIcon) {
            try { $script:trayIcon.ShowBalloonTip(2000, 'DSH WebUI', '服务已启动，浏览器即将打开。', 'Info') } catch { }
        }
        Start-Process $url
        Write-UILog ("已在浏览器打开 http://127.0.0.1:{0}" -f $script:EffectivePort)
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
            Write-UILog '提醒：浏览器里那个 DSH 标签页不会自动关闭，请手动关掉它（显示"需要重新连接"属正常）'
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
$timer.Interval = [TimeSpan]::FromSeconds(1)
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
                Write-UILog ("窗口图标已加载：{0}x{1}（来自 {2}，共 {3} 层）" -f $pick.PixelWidth, $pick.PixelHeight, (Split-Path -Leaf $icoPath), $frames.Count)
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
    Write-UILog '欢迎使用 DSH WebUI'
    Write-UILog '点主按钮即可启动或停止服务'
    # 任务栏/窗口图标的诊断：换图标或任务栏图标不对时先看这两行，
    # 同时落盘到 %LOCALAPPDATA%\dsh-web-launcher\ui-diagnostics.log 便于事后排查
    $iconDesc = if ($win.Icon) { "$($win.Icon.PixelWidth)x$($win.Icon.PixelHeight)" } else { '未设置' }
    Write-UILog ("任务栏标识：{0}" -f $script:AumidStatus)
    Write-UILog ("窗口图标：{0}" -f $iconDesc)
    try {
        if (-not (Test-Path -LiteralPath $script:StateDir)) {
            New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
        }
        $diagLines = @(
            ("[{0}] DSH WebUI 启动诊断" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
            ("AppUserModelID : {0}" -f $script:AumidStatus)
            ("窗口图标       : {0}" -f $iconDesc)
            ("工作区         : {0}" -f $script:Workspace)
        )
        Set-Content -LiteralPath (Join-Path $script:StateDir 'ui-diagnostics.log') -Value $diagLines -Encoding UTF8
    }
    catch { }
    Update-UI

    # 窗口若被建成隐藏的，这里显式显示并提到前台（Show-MainWindow 内含守卫）
    [void] (Show-MainWindow)
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
    $miOpen = $trayMenu.Items.Add('打开 WebUI')
    [void] $trayMenu.Items.Add('-')
    $miExit = $trayMenu.Items.Add('退出')

    $miShow.Add_Click({
        [void] (Show-MainWindow)
    })

    $miOpen.Add_Click({
        $status = Get-DshWebStatus
        if ($status.Running) {
            $base = "http://127.0.0.1:$($status.Port)"
            if (Wait-HttpReady -BaseUrl $base -TimeoutSeconds 10) { Start-Process $base }
            else { Write-UILog '服务尚未响应，请稍后再试' }
        }
        else {
            [void] (Show-MainWindow)
            Write-UILog '服务尚未运行，请先点「启动服务」'
        }
    })

    $miExit.Add_Click({
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

