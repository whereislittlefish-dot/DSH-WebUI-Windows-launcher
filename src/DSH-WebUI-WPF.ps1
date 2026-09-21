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

# 窗口显示兜底：exe 用 CreateNoWindow 启动 PowerShell 时，Windows 会把
# 首个顶层窗口建成隐藏的。ContentRendered 在“未渲染”时不会触发，所以这里
# 挂在更早的 Loaded 上，强制把窗口显示出来（对正常双击启动无副作用）。
try {
    $win.Add_Loaded({
        try {
            $win.Show()
            $win.Activate()
            $script:winHandle = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
            [void] [Win32Window]::ShowWindow($script:winHandle, 5)   # 5 = SW_SHOW
            [void] [Win32Window]::SetForegroundWindow($script:winHandle)
        } catch { }
    })
}
catch { }
$reader = [System.Xml.XmlNodeReader]::new([xml]$xamlText)
$win = [System.Windows.Markup.XamlReader]::Load($reader)

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
}

# ------------------------------------------------------------------ 事件

$win.Add_MouseLeftButtonDown({ })

# 标题栏拖动 / 关闭
$script:Quitting = $false

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
    $btnClose.Add_Click({ $script:Quitting = $true; if ($script:trayIcon) { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() }; $win.Close(); if ($script:appDispatcher) { $script:appDispatcher.InvokeShutdown() } })
}

$btnMain.Add_Click({
    $status = Get-DshWebStatus
    if ($status.Running) {
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
    else {
        Write-UILog '正在启动服务 ...'
        $btnMain.IsEnabled = $false
        try {
            if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw '未找到 Node.js，请先安装 Node.js 20+' }
            $dshPath = Find-Dsh
            if (-not $dshPath) {
                Write-UILog '未安装 dsh，正在自动安装（约 200 MB）...'
                & npm install --global @deepseek-ai/dsh 2>&1 | Out-Null
                $dshPath = Find-Dsh
                if (-not $dshPath) { throw 'dsh 安装后仍找不到' }
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
            Write-UILog '服务已就绪'
            Write-UILog '服务已就绪'
            Start-Process $url
            Write-UILog ("已在浏览器打开 http://127.0.0.1:{0}" -f $script:EffectivePort)
        }
        catch { Write-UILog ("失败：{0}" -f $_.Exception.Message) }
        finally { $btnMain.IsEnabled = $true; Update-UI }
    }
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


$win.Add_Closing({
    param($sender, $e)
    # 点关闭只收进托盘/隐藏，不退出（避免误关后找不到界面）
    $script:Quitting = $true
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({ Update-UI })
$timer.Start()

# 窗口图标：XAML 的 Window.Icon 不接受 data: URI，只能在代码里加载。
# 找不到 app.ico 时静默跳过——任务栏仍会显示 exe 自带的图标。
try {
    $icoPath = Join-Path $PSScriptRoot 'app.ico'
    if (-not (Test-Path -LiteralPath $icoPath)) {
        $icoPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'app.ico'
    }
    if (Test-Path -LiteralPath $icoPath) {
        $icoStream = [System.IO.File]::OpenRead($icoPath)
        $icoFrame = [System.Windows.Media.Imaging.BitmapFrame]::Create(
            $icoStream,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $win.Icon = $icoFrame
        $icoStream.Close()
    }
} catch { }

$win.Add_ContentRendered({
    Write-UILog '欢迎使用 DSH WebUI'
    Write-UILog '点主按钮即可启动或停止服务'
    Update-UI

    # VBS 用 SW_HIDE 启动时窗口会被建成隐藏的，这里显式显示并提到前台
    try {
        $win.Show()
        $win.Activate()
        $win.Topmost = $true
        $win.Topmost = $false
        [void] [Win32Window]::ShowWindow((New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle, 5)
    }
    catch { }
})


# ---------------------------------------------------------------- 系统托盘
$script:Quitting = $false
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
        $win.Show()
        $win.WindowState = [System.Windows.WindowState]::Normal
        $win.Activate()
    })

    $miOpen.Add_Click({
        $status = Get-DshWebStatus
        if ($status.Running) {
            $base = "http://127.0.0.1:$($status.Port)"
            if (Wait-HttpReady -BaseUrl $base -TimeoutSeconds 10) { Start-Process $base }
            else { Write-UILog '服务尚未响应，请稍后再试' }
        }
        else {
            $win.Show()
            $win.WindowState = [System.Windows.WindowState]::Normal
            $win.Activate()
            Write-UILog '服务尚未运行，请先点「启动服务」'
        }
    })

    $miExit.Add_Click({
        $script:Quitting = $true
        try { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() } catch { }
        $win.Close()
    })

    $script:trayIcon.ContextMenuStrip = $trayMenu
    $script:trayIcon.Add_MouseDoubleClick({
        $win.Show()
        $win.WindowState = [System.Windows.WindowState]::Normal
        $win.Activate()
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
[System.Windows.Threading.Dispatcher]::Run()
$timer.Stop()
try { if ($script:trayIcon) { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() } } catch { }
