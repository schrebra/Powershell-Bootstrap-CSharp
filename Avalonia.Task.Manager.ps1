param(
    [string]$ProjectName = 'CpuTaskManager',
    [ValidateSet('Auto','Console','Avalonia')][string]$ProjectType = 'Avalonia',
    [string]$BaseDir = '',
    [switch]$NoLaunch,
    [int]$MaxRetries = 3
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Script:StageName = 'Initialization'
$Script:InstallerPath = ''
$Script:DotnetDir = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
$Script:AppKind = 'Avalonia'

function Write-Info([string]$m){Write-Host $m -ForegroundColor Cyan}
function Write-Ok([string]$m){Write-Host $m -ForegroundColor Green}
function Write-Warn2([string]$m){Write-Host $m -ForegroundColor Yellow}
function Write-Err2([string]$m){Write-Host $m -ForegroundColor Red}
function Throw-Code([int]$c,[string]$m){throw "[$c] $m"}
function Write-Stage([string]$n,[string]$m){Write-Host '';Write-Host "[$n] $m" -ForegroundColor Cyan}

function Initialize-Tls {
    try {[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12} catch {}
    try {[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13} catch {}
}

function Get-SafeName([string]$n) {
    $n = [regex]::Replace($n, '[^A-Za-z0-9_]', '')
    if ($n.Length -eq 0) { return 'CpuTaskManager' }
    if ($n -match '^\d') { $n = 'App' + $n }
    $n = $n.Substring(0, 1).ToUpperInvariant() + $n.Substring(1)
    $kw = @('abstract','as','async','await','base','bool','break','byte','case','catch','char','checked','class','const','continue','decimal','default','delegate','do','double','else','enum','event','explicit','extern','false','finally','fixed','float','for','foreach','goto','if','implicit','in','init','int','interface','internal','is','lock','long','namespace','new','null','object','operator','out','override','params','private','protected','public','readonly','record','ref','return','sbyte','sealed','short','sizeof','stackalloc','static','string','struct','switch','this','throw','true','try','typeof','uint','ulong','unchecked','unsafe','ushort','using','var','virtual','void','volatile','while')
    if ($kw -contains $n.ToLowerInvariant()) { $n = $n + 'App' }
    return $n
}

function Remove-Folder([string]$Path) {
    $p = $Path.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $p)) { return $true }
    for ($i = 1; $i -le 3; $i++) {
        try {
            Get-ChildItem -LiteralPath $p -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = [IO.FileAttributes]::Normal } catch {} }
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
        } catch {
            Start-Sleep -Seconds ([math]::Min(30, 5 * $i))
        }
        if (-not (Test-Path -LiteralPath $p)) { return $true }
    }
    try { & cmd.exe /c rd /s /q "$p" | Out-Null } catch {}
    $gone = -not (Test-Path -LiteralPath $p)
    if (-not $gone) { Write-Warn2 "cmd rd /s /q exited with code $LASTEXITCODE but '$p' still exists." }
    return $gone
}

function Find-DotNetSdk {
    $cand = @()
    $local = Join-Path $Script:DotnetDir 'dotnet.exe'
    if (Test-Path -LiteralPath $local) { $cand += $local }
    $resolved = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($resolved -and ($cand -notcontains $resolved.Source)) { $cand += $resolved.Source }
    foreach ($d in $cand) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $null = (& $d --version 2>$null)
            if ($LASTEXITCODE -eq 0) {
                $sdks = @(& $d --list-sdks 2>$null)
                if ($LASTEXITCODE -eq 0 -and (@($sdks | Where-Object { $_ -match '^8\.' }).Count -gt 0)) { return $d }
            }
        } catch {} finally { $ErrorActionPreference = $prev }
    }
    return $null
}

function Test-SdkWorks([string]$DotNetPath) {
    if ([string]::IsNullOrWhiteSpace($DotNetPath) -or -not (Test-Path -LiteralPath $DotNetPath)) { return $false }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $null = (& $DotNetPath --version 2>$null)
        if ($LASTEXITCODE -ne 0) { return $false }
        $sdks = @(& $DotNetPath --list-sdks 2>$null)
        if ($LASTEXITCODE -ne 0) { return $false }
        return (@($sdks | Where-Object { $_ -match '^8\.' }).Count -gt 0)
    } catch { return $false } finally { $ErrorActionPreference = $prev }
}

function Save-FileWithRetry([string]$Url, [string]$Dest) {
    for ($i = 1; $i -le $MaxRetries; $i++) {
        if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue }
        try {
            if ($env:HTTPS_PROXY) {
                Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120 -Proxy $env:HTTPS_PROXY -ErrorAction Stop
            } else {
                Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            }
            if ((Test-Path -LiteralPath $Dest) -and ((Get-Item -LiteralPath $Dest).Length -gt 1000)) {
                $head = ((Get-Content -LiteralPath $Dest -TotalCount 5 -ErrorAction SilentlyContinue) -join ' ')
                if ($head -notmatch '(?i)<\s*html|<!doctype') { return $true }
            }
        } catch {}
        Write-Warn2 "Download attempt $i failed for: $Url"
        if ($i -lt $MaxRetries) {
            Write-Warn2 "Retrying in $([math]::Min(30, 5 * $i)) seconds..."
            Start-Sleep -Seconds ([math]::Min(30, 5 * $i))
        }
    }
    return $false
}

function Install-DotNetSdk {
    $Script:InstallerPath = Join-Path $env:TEMP 'dotnet-install.ps1'
    $urls = @('https://dot.net/v1/dotnet-install.ps1', 'https://raw.githubusercontent.com/dotnet/install-scripts/main/src/dotnet-install.ps1')
    $got = $false
    foreach ($u in $urls) {
        if (Save-FileWithRetry -Url $u -Dest $Script:InstallerPath) { $got = $true; break }
    }
    if (-not $got) { Throw-Code 2 "Could not download dotnet-install.ps1 from any mirror after repeated attempts." }
    try { Unblock-File -LiteralPath $Script:InstallerPath -ErrorAction SilentlyContinue } catch {}
    Write-Info "Installing user-local .NET 8 SDK under: $($Script:DotnetDir)"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:InstallerPath -Channel 8.0 -Architecture x64 -InstallDir $Script:DotnetDir
    if ($LASTEXITCODE -ne 0) { Throw-Code 3 "dotnet-install.ps1 exited with code $LASTEXITCODE." }
}

function Set-DotNetEnv([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { Throw-Code 3 "Expected dotnet directory '$Dir' does not exist." }
    $env:DOTNET_ROOT = $Dir
    $env:DOTNET_MULTILEVEL_LOOKUP = '0'
    $env:DOTNET_NOLOGO = '1'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:MSBUILDDISABLENODEREUSE = '1'
    $env:NUGET_INTERACTIVE = 'false'
    if (@($env:Path -split ';') -notcontains $Dir) { $env:Path = "$Dir;$env:Path" }
}

function Invoke-DotNet {
    param([string]$ExePath, [int]$FailCode = 5, [string[]]$CliArgs = @())
    & $ExePath @CliArgs
    if ($LASTEXITCODE -ne 0) { Throw-Code $FailCode "dotnet $($CliArgs -join ' ') failed with exit code $LASTEXITCODE." }
}

function Test-DiskSpace([string]$Path) {
    $gb = $null
    try {
        $di = New-Object IO.DriveInfo($Path.Substring(0, 1))
        if ($di.IsReady) { $gb = [math]::Round($di.AvailableFreeSpace / 1GB, 2) }
    } catch {}
    if ($null -eq $gb) { Write-Warn2 'Could not determine free disk space; continuing.'; return }
    $L = $Path.Substring(0, 1)
    if ($gb -lt 0.5) { Throw-Code 1 "Only $gb GB free on drive ${L}: - minimum 0.5 GB is required." }
    elseif ($gb -lt 2) { Write-Warn2 "Low disk space: $gb GB free on drive ${L}:" }
    else { Write-Ok "Disk space OK: $gb GB free on drive ${L}:" }
}

function Write-SourceFiles([string]$Dir, [string]$Name) {
$projAva = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <SelfContained>true</SelfContained>
    <RuntimeIdentifier>win-x64</RuntimeIdentifier>
    <PublishSingleFile>true</PublishSingleFile>
    <IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract>
    <EnableCompressionInSingleFile>true</EnableCompressionInSingleFile>
    <DebugType>embedded</DebugType>
    <RootNamespace>__APPNAME__</RootNamespace>
    <AssemblyName>__APPNAME__</AssemblyName>
    <ServerGarbageCollection>false</ServerGarbageCollection>
    <ConcurrentGarbageCollection>true</ConcurrentGarbageCollection>
    <NoWarn>CA1416</NoWarn>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Avalonia" Version="11.0.10" />
    <PackageReference Include="Avalonia.Win32" Version="11.0.10" />
    <PackageReference Include="Avalonia.Skia" Version="11.0.10" />
    <PackageReference Include="Avalonia.Themes.Fluent" Version="11.0.10" />
    <PackageReference Include="System.Management" Version="8.0.0" />
  </ItemGroup>
</Project>
'@

$progCs = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Avalonia;

namespace __APPNAME__
{
    internal class Program
    {
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern int MessageBox(IntPtr hWnd, string text, string caption, uint type);

        [STAThread]
        public static void Main(string[] args)
        {
            try
            {
                BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
            }
            catch (Exception ex)
            {
                try { File.WriteAllText("crash.log", ex.ToString()); } catch { }
                MessageBox(IntPtr.Zero, ex.ToString(), "Application Error", 0x10);
            }
        }

        public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>().UseWin32().UseSkia().LogToTrace();
    }
}
'@

$appAxaml = @'
<Application xmlns="https://github.com/avaloniaui"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             x:Class="__APPNAME__.App">
  <Application.Styles>
    <FluentTheme />
  </Application.Styles>
</Application>
'@

$appCs = @'
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace __APPNAME__
{
    public partial class App : Application
    {
        public override void Initialize() => AvaloniaXamlLoader.Load(this);

        public override void OnFrameworkInitializationCompleted()
        {
            if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            {
                desktop.MainWindow = new MainWindow();
            }
            base.OnFrameworkInitializationCompleted();
        }
    }
}
'@

$mwAxaml = @'
<Window xmlns="https://github.com/avaloniaui"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Class="__APPNAME__.MainWindow"
        Title="Task Manager" Width="1100" Height="720" MinWidth="850" MinHeight="550"
        WindowStartupLocation="CenterScreen"
        WindowState="Maximized"
        FontFamily="Segoe UI, -apple-system, BlinkMacSystemFont, sans-serif">
  <Grid x:Name="RootGrid" RowDefinitions="Auto,Auto,*,Auto">
    <!-- Row 0: Menu Bar -->
    <Border Grid.Row="0" x:Name="MenuBarBorder" Height="24" BorderThickness="0,0,0,1">
      <Menu x:Name="MainMenu" VerticalAlignment="Center" Height="24">
        <MenuItem Header="_File" x:Name="MenuFile">
          <MenuItem Header="Run new task" Click="OnRunTaskClick"/>
          <Separator/>
          <MenuItem Header="Exit" Click="OnExitClick"/>
        </MenuItem>
        <MenuItem Header="_Options" x:Name="MenuOptions">
          <MenuItem Header="Always on top" x:Name="MenuAlwaysOnTop" Click="OnAlwaysOnTopClick"/>
          <MenuItem Header="Minimize on use"/>
          <MenuItem Header="Hide when minimized"/>
          <Separator/>
          <MenuItem Header="Dark mode" x:Name="MenuDarkMode" Click="OnToggleDarkModeClick"/>
        </MenuItem>
        <MenuItem Header="_View" x:Name="MenuView">
          <MenuItem Header="Refresh now" Click="OnRefreshNowClick"/>
          <MenuItem Header="Update speed">
            <MenuItem Header="High" Click="OnSpeedHighClick"/>
            <MenuItem Header="Normal" Click="OnSpeedNormalClick"/>
            <MenuItem Header="Low" Click="OnSpeedLowClick"/>
            <MenuItem Header="Paused" Click="OnSpeedPausedClick"/>
          </MenuItem>
          <Separator/>
          <MenuItem Header="Change graph to" x:Name="MenuChangeGraphRoot">
            <MenuItem Header="Overall utilization" Click="OnOverallGraphClick"/>
            <MenuItem Header="Logical processors" Click="OnLogicalGraphClick"/>
          </MenuItem>
        </MenuItem>
      </Menu>
    </Border>

    <!-- Row 1: Tab Bar -->
    <Border Grid.Row="1" x:Name="TabBarBorder" Height="30" Padding="8,0" BorderThickness="0,0,0,1">
      <StackPanel Orientation="Horizontal" Spacing="2" VerticalAlignment="Bottom">
        <Border x:Name="TabProcessesBorder" Padding="10,4,10,6" Cursor="Hand" PointerPressed="OnProcessesTabClick">
          <TextBlock x:Name="TabProcesses" Text="Processes" FontSize="12"/>
        </Border>
        <Border x:Name="TabPerfBorder" BorderThickness="1,1,1,0" Padding="12,5,12,6" Margin="0,0,0,-1">
          <TextBlock x:Name="TabPerformance" Text="Performance" FontSize="12" FontWeight="SemiBold"/>
        </Border>
        <Border x:Name="TabAppHistoryBorder" Padding="10,4,10,6" Cursor="Hand" PointerPressed="OnAppHistoryTabClick">
          <TextBlock x:Name="TabAppHistory" Text="App history" FontSize="12"/>
        </Border>
        <Border x:Name="TabStartupBorder" Padding="10,4,10,6" Cursor="Hand" PointerPressed="OnStartupTabClick">
          <TextBlock x:Name="TabStartup" Text="Startup" FontSize="12"/>
        </Border>
        <Border x:Name="TabUsersBorder" Padding="10,4,10,6" Cursor="Hand" PointerPressed="OnUsersTabClick">
          <TextBlock x:Name="TabUsers" Text="Users" FontSize="12"/>
        </Border>
        <Border x:Name="TabDetailsBorder" Padding="10,4,10,6" Cursor="Hand" PointerPressed="OnDetailsTabClick">
          <TextBlock x:Name="TabDetails" Text="Details" FontSize="12"/>
        </Border>
        <Border x:Name="TabServicesBorder" Padding="10,4,10,6" Cursor="Hand" PointerPressed="OnServicesTabClick">
          <TextBlock x:Name="TabServices" Text="Services" FontSize="12"/>
        </Border>
      </StackPanel>
    </Border>

    <!-- Row 2: Main Split View (Sidebar + Content) -->
    <Grid Grid.Row="2" x:Name="PerformanceMainGrid" ColumnDefinitions="230,*">
      <!-- Left Sidebar: Performance List -->
      <Border Grid.Column="0" x:Name="SidebarBorder" BorderThickness="0,0,1,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="0,4,0,4">
            <!-- CPU Tile -->
            <Border x:Name="CpuTileBorder" Height="64" BorderThickness="1" Padding="8,6" Margin="4,2" Cursor="Hand" PointerPressed="OnCpuTileClick">
              <Grid ColumnDefinitions="58,*" RowDefinitions="20,20" VerticalAlignment="Top">
                <Border Grid.RowSpan="2" Grid.Column="0" x:Name="MiniCpuBox" Height="40" Width="54" HorizontalAlignment="Left" BorderThickness="1">
                  <Canvas x:Name="MiniCpuCanvas" Height="38" Width="52" ClipToBounds="True"/>
                </Border>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="MiniCpuHeading" Text="CPU" FontSize="12" FontWeight="SemiBold" Margin="8,1,0,0"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="MiniCpuText" Text="4% 3.92 GHz" FontSize="11" Margin="8,2,0,0"/>
              </Grid>
            </Border>

            <!-- Memory Tile -->
            <Border x:Name="MemTileBorder" Height="64" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" Padding="8,6" Margin="4,2" Cursor="Hand" PointerPressed="OnMemTileClick">
              <Grid ColumnDefinitions="58,*" RowDefinitions="20,20" VerticalAlignment="Top">
                <Border Grid.RowSpan="2" Grid.Column="0" x:Name="MiniMemBox" Height="40" Width="54" HorizontalAlignment="Left" BorderThickness="1">
                  <Canvas x:Name="MiniMemCanvas" Height="38" Width="52" ClipToBounds="True"/>
                </Border>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="MiniMemHeading" Text="Memory" FontSize="12" FontWeight="SemiBold" Margin="8,1,0,0"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="MiniMemText" Text="10.9/27.7 GB (39%)" FontSize="11" Margin="8,2,0,0"/>
              </Grid>
            </Border>

            <!-- Disk 0 Tile -->
            <Border x:Name="DiskTileBorder" Height="64" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" Padding="8,6" Margin="4,2" Cursor="Hand" PointerPressed="OnDiskTileClick">
              <Grid ColumnDefinitions="58,*" RowDefinitions="20,20" VerticalAlignment="Top">
                <Border Grid.RowSpan="2" Grid.Column="0" x:Name="MiniDiskBox" Height="40" Width="54" HorizontalAlignment="Left" BorderThickness="1">
                  <Canvas x:Name="MiniDiskCanvas" Height="38" Width="52" ClipToBounds="True"/>
                </Border>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="MiniDiskHeading" Text="Disk 0 (C:)" FontSize="12" FontWeight="SemiBold" Margin="8,1,0,0"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="MiniDiskText" Text="SSD&#x0a;0%" FontSize="11" Margin="8,2,0,0"/>
              </Grid>
            </Border>

            <!-- Wi-Fi Tile -->
            <Border x:Name="WifiTileBorder" Height="64" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" Padding="8,6" Margin="4,2">
              <Grid ColumnDefinitions="58,*" RowDefinitions="20,20" VerticalAlignment="Top">
                <Border Grid.RowSpan="2" Grid.Column="0" x:Name="MiniWifiBox" Height="40" Width="54" HorizontalAlignment="Left" BorderThickness="1">
                  <Canvas x:Name="MiniWifiCanvas" Height="38" Width="52" ClipToBounds="True"/>
                </Border>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="MiniWifiHeading" Text="Wi-Fi" FontSize="12" FontWeight="SemiBold" Margin="8,1,0,0"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="MiniWifiText" Text="Wi-Fi&#x0a;S: 8.0 R: 152 Kbps" FontSize="11" Margin="8,2,0,0"/>
              </Grid>
            </Border>

            <!-- Ethernet 1 Tile -->
            <Border x:Name="Eth1TileBorder" Height="64" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" Padding="8,6" Margin="4,2">
              <Grid ColumnDefinitions="58,*" RowDefinitions="20,20" VerticalAlignment="Top">
                <Border Grid.RowSpan="2" Grid.Column="0" x:Name="MiniEth1Box" Height="40" Width="54" HorizontalAlignment="Left" BorderThickness="1">
                  <Canvas x:Name="MiniEth1Canvas" Height="38" Width="52" ClipToBounds="True"/>
                </Border>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="MiniEth1Heading" Text="Ethernet" FontSize="12" FontWeight="SemiBold" Margin="8,1,0,0"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="MiniEth1Text" Text="VMware Network Ad...&#x0a;S: 0 R: 0 Kbps" FontSize="11" Margin="8,2,0,0"/>
              </Grid>
            </Border>

            <!-- Ethernet 2 Tile -->
            <Border x:Name="Eth2TileBorder" Height="64" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" Padding="8,6" Margin="4,2">
              <Grid ColumnDefinitions="58,*" RowDefinitions="20,20" VerticalAlignment="Top">
                <Border Grid.RowSpan="2" Grid.Column="0" x:Name="MiniEth2Box" Height="40" Width="54" HorizontalAlignment="Left" BorderThickness="1">
                  <Canvas x:Name="MiniEth2Canvas" Height="38" Width="52" ClipToBounds="True"/>
                </Border>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="MiniEth2Heading" Text="Ethernet" FontSize="12" FontWeight="SemiBold" Margin="8,1,0,0"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="MiniEth2Text" Text="VMware Network Ad...&#x0a;S: 0 R: 0 Kbps" FontSize="11" Margin="8,2,0,0"/>
              </Grid>
            </Border>

            <!-- GPU 0 Tile -->
            <Border x:Name="GpuTileBorder" Height="64" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" Padding="8,6" Margin="4,2">
              <Grid ColumnDefinitions="58,*" RowDefinitions="20,20" VerticalAlignment="Top">
                <Border Grid.RowSpan="2" Grid.Column="0" x:Name="MiniGpuBox" Height="40" Width="54" HorizontalAlignment="Left" BorderThickness="1">
                  <Canvas x:Name="MiniGpuCanvas" Height="38" Width="52" ClipToBounds="True"/>
                </Border>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="MiniGpuHeading" Text="GPU 0" FontSize="12" FontWeight="SemiBold" Margin="8,1,0,0"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="MiniGpuText" Text="AMD Radeon 780M...&#x0a;1% (45 &#xB0;C)" FontSize="11" Margin="8,2,0,0"/>
              </Grid>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </Border>

      <!-- Right Main Pane: Hosts CPU, Memory, or Disk View -->
      <Grid Grid.Column="1">
        <!-- CPU Performance View -->
        <Grid x:Name="CpuView" RowDefinitions="Auto,Auto,*,Auto,Auto" Margin="24,12,24,12" IsVisible="True">
          <!-- Row 0: Big Header & Brand String -->
          <Grid Grid.Row="0" ColumnDefinitions="Auto,*" Margin="0,0,0,10">
            <TextBlock Grid.Column="0" x:Name="CpuBigHeader" Text="CPU" FontSize="32" FontWeight="Light" VerticalAlignment="Center"/>
            <TextBlock Grid.Column="1" x:Name="CpuBrandText" Text="AMD Ryzen 7 PRO 8840HS w/ Radeon 780M Graphics" FontSize="13" VerticalAlignment="Bottom" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
          </Grid>

          <!-- Row 1: Graph Top Scale Labels -->
          <Grid Grid.Row="1" ColumnDefinitions="*,Auto" Margin="0,0,0,2">
            <TextBlock x:Name="GraphHeaderLabel" Text="% Utilization over 60 seconds" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="GraphScaleMax" Text="100%" FontSize="11"/>
          </Grid>

          <!-- Row 2: The Graph Box (Overall or Logical) -->
          <Grid Grid.Row="2">
            <Border x:Name="OverallGraphBorder" BorderThickness="1" IsVisible="False">
              <Canvas x:Name="OverallCpuCanvas" ClipToBounds="True"/>
            </Border>
            <Grid x:Name="LogicalCoresGrid" IsVisible="True"/>
          </Grid>

          <!-- Row 3: Graph Bottom Scale Labels -->
          <Grid Grid.Row="3" ColumnDefinitions="*,Auto" Margin="0,2,0,14" IsVisible="False">
            <TextBlock x:Name="GraphScaleTime" Text="60 seconds" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="GraphScaleZero" Text="0" FontSize="11"/>
          </Grid>

          <!-- Row 4: Authentic Statistics & Specs Section -->
          <Grid Grid.Row="4" HorizontalAlignment="Left" ColumnDefinitions="95,95,95,Auto,Auto" Margin="0,8,0,0">
            <!-- Col 0: Utilization, Processes, Up time -->
            <StackPanel Grid.Column="0" Spacing="10">
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelUtil" Text="Utilization" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatUtilization" Text="4%" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelProcs" Text="Processes" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatProcesses" Text="217" FontSize="16" FontWeight="Normal"/>
              </StackPanel>
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelUptime" Text="Up time" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatUptime" Text="0:06:32:42" FontSize="16" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 1: Speed, Threads -->
            <StackPanel Grid.Column="1" Spacing="10" Margin="4,0,0,0">
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelSpeed" Text="Speed" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatSpeed" Text="3.92 GHz" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelThreads" Text="Threads" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatThreads" Text="2799" FontSize="16" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 2: Handles -->
            <StackPanel Grid.Column="2" Spacing="10" Margin="4,0,0,0">
              <Border Height="38"/>
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelHandles" Text="Handles" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatHandles" Text="101988" FontSize="16" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 3: Hardware Spec Labels -->
            <StackPanel Grid.Column="3" Spacing="2" Margin="32,2,12,0" VerticalAlignment="Top">
              <TextBlock x:Name="LabelBaseSpeed" Text="Base speed:" FontSize="11"/>
              <TextBlock x:Name="LabelSockets" Text="Sockets:" FontSize="11"/>
              <TextBlock x:Name="LabelCores" Text="Cores:" FontSize="11"/>
              <TextBlock x:Name="LabelLogical" Text="Logical processors:" FontSize="11"/>
              <TextBlock x:Name="LabelVirt" Text="Virtualization:" FontSize="11"/>
              <TextBlock x:Name="LabelL1" Text="L1 cache:" FontSize="11"/>
              <TextBlock x:Name="LabelL2" Text="L2 cache:" FontSize="11"/>
              <TextBlock x:Name="LabelL3" Text="L3 cache:" FontSize="11"/>
            </StackPanel>

            <!-- Col 4: Hardware Spec Values -->
            <StackPanel Grid.Column="4" Spacing="2" Margin="0,2,0,0" VerticalAlignment="Top">
              <TextBlock x:Name="MetaBaseSpeed" Text="3.30 GHz" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaSockets" Text="1" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaPhysicalCores" Text="8" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaLogicalCores" Text="16" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaVirtualization" Text="Enabled" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaL1" Text="512 KB" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaL2" Text="8.0 MB" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaL3" Text="16.0 MB" FontSize="11" FontWeight="Normal"/>
            </StackPanel>
          </Grid>
        </Grid>

        <!-- Memory Performance View (1-to-1 Windows 10 Task Manager) -->
        <Grid x:Name="MemoryView" RowDefinitions="Auto,Auto,*,Auto,Auto,Auto" Margin="24,12,24,12" IsVisible="False">
          <!-- Row 0: Big Header & Memory Capacity/Type String -->
          <Grid Grid.Row="0" ColumnDefinitions="Auto,*" Margin="0,0,0,10">
            <TextBlock Grid.Column="0" x:Name="MemBigHeader" Text="Memory" FontSize="32" FontWeight="Light" VerticalAlignment="Center"/>
            <TextBlock Grid.Column="1" x:Name="MemTotalHeader" Text="32.0 GB" FontSize="13" VerticalAlignment="Bottom" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
          </Grid>

          <!-- Row 1: Graph Top Scale Labels -->
          <Grid Grid.Row="1" ColumnDefinitions="*,Auto" Margin="0,0,0,2">
            <TextBlock x:Name="MemGraphHeaderLabel" Text="Memory usage" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="MemGraphScaleMax" Text="27.7 GB" FontSize="11"/>
          </Grid>

          <!-- Row 2: Memory Line/Area Usage Chart Box -->
          <Grid Grid.Row="2">
            <Border x:Name="OverallMemBorder" BorderThickness="1">
              <Canvas x:Name="OverallMemCanvas" ClipToBounds="True"/>
            </Border>
          </Grid>

          <!-- Row 3: Graph Bottom Scale Labels -->
          <Grid Grid.Row="3" ColumnDefinitions="*,Auto" Margin="0,2,0,10">
            <TextBlock x:Name="MemGraphScaleTime" Text="60 seconds" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="MemGraphScaleZero" Text="0" FontSize="11"/>
          </Grid>

          <!-- Row 4: Authentic Memory Composition Segmented Bar Section -->
          <StackPanel Grid.Row="4" Margin="0,0,0,14">
            <TextBlock x:Name="LabelMemComposition" Text="Memory composition" FontSize="11" Margin="0,0,0,4"/>
            <Border x:Name="MemCompositionBorder" BorderThickness="1" Height="18">
              <Canvas x:Name="MemCompositionCanvas" ClipToBounds="True" Height="16"/>
            </Border>
          </StackPanel>

          <!-- Row 5: Authentic Memory Statistics & Hardware Specs Section -->
          <Grid Grid.Row="5" HorizontalAlignment="Left" ColumnDefinitions="115,115,115,Auto,Auto" Margin="0,0,0,0">
            <!-- Col 0: In use (Compressed), Available -->
            <StackPanel Grid.Column="0" Spacing="10">
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelMemInUse" Text="In use (Compressed)" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatMemInUse" Text="10.8 GB" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelMemAvailable" Text="Available" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatMemAvailable" Text="16.9 GB" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 1: Committed, Cached -->
            <StackPanel Grid.Column="1" Spacing="10" Margin="4,0,0,0">
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelMemCommitted" Text="Committed" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatMemCommitted" Text="14.2/35.0 GB" FontSize="16" FontWeight="Normal"/>
              </StackPanel>
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelMemCached" Text="Cached" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatMemCached" Text="15.8 GB" FontSize="16" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 2: Paged pool, Non-paged pool -->
            <StackPanel Grid.Column="2" Spacing="10" Margin="4,0,0,0">
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelMemPagedPool" Text="Paged pool" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatMemPagedPool" Text="640 MB" FontSize="16" FontWeight="Normal"/>
              </StackPanel>
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelMemNonPagedPool" Text="Non-paged pool" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatMemNonPagedPool" Text="480 MB" FontSize="16" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 3: Hardware Spec Labels -->
            <StackPanel Grid.Column="3" Spacing="2" Margin="36,2,12,0" VerticalAlignment="Top">
              <TextBlock x:Name="LabelMemSpeed" Text="Speed:" FontSize="11"/>
              <TextBlock x:Name="LabelMemSlots" Text="Slots used:" FontSize="11"/>
              <TextBlock x:Name="LabelMemFormFactor" Text="Form factor:" FontSize="11"/>
              <TextBlock x:Name="LabelMemReserved" Text="Hardware reserved:" FontSize="11"/>
            </StackPanel>

            <!-- Col 4: Hardware Spec Values -->
            <StackPanel Grid.Column="4" Spacing="2" Margin="0,2,0,0" VerticalAlignment="Top">
              <TextBlock x:Name="MetaMemSpeed" Text="5600 MHz" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaMemSlots" Text="2 of 2" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaMemFormFactor" Text="SODIMM" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaMemReserved" Text="4.3 GB" FontSize="11" FontWeight="Normal"/>
            </StackPanel>
          </Grid>
        </Grid>

        <!-- Disk Performance View (1-to-1 Windows 10 Task Manager) -->
        <Grid x:Name="DiskView" RowDefinitions="Auto,Auto,*,Auto,Auto,*,Auto,Auto" Margin="24,12,24,12" IsVisible="False">
          <!-- Row 0: Big Header & Disk Model String -->
          <Grid Grid.Row="0" ColumnDefinitions="Auto,*" Margin="0,0,0,10">
            <TextBlock Grid.Column="0" x:Name="DiskBigHeader" Text="Disk 0 (C:)" FontSize="32" FontWeight="Light" VerticalAlignment="Center"/>
            <TextBlock Grid.Column="1" x:Name="DiskModelText" Text="NVMe Samsung SSD 980 PRO 1TB" FontSize="13" VerticalAlignment="Bottom" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
          </Grid>

          <!-- Row 1: Active Time Graph Top Scale Labels -->
          <Grid Grid.Row="1" ColumnDefinitions="*,Auto" Margin="0,0,0,2">
            <TextBlock x:Name="DiskActiveTimeHeaderLabel" Text="Active time" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="DiskActiveTimeScaleMax" Text="100%" FontSize="11"/>
          </Grid>

          <!-- Row 2: Active Time Graph Box -->
          <Grid Grid.Row="2" MinHeight="75">
            <Border x:Name="DiskActiveBorder" BorderThickness="1">
              <Canvas x:Name="DiskActiveCanvas" ClipToBounds="True"/>
            </Border>
          </Grid>

          <!-- Row 3: Active Time Graph Bottom Scale Labels -->
          <Grid Grid.Row="3" ColumnDefinitions="*,Auto" Margin="0,2,0,8">
            <TextBlock x:Name="DiskActiveScaleTime" Text="60 seconds" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="DiskActiveScaleZero" Text="0" FontSize="11"/>
          </Grid>

          <!-- Row 4: Transfer Rate Graph Top Scale Labels -->
          <Grid Grid.Row="4" ColumnDefinitions="*,Auto" Margin="0,0,0,2">
            <TextBlock x:Name="DiskTransferHeaderLabel" Text="Disk transfer rate" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="DiskTransferScaleMax" Text="100 KB/s" FontSize="11"/>
          </Grid>

          <!-- Row 5: Transfer Rate Graph Box -->
          <Grid Grid.Row="5" MinHeight="75">
            <Border x:Name="DiskTransferBorder" BorderThickness="1">
              <Canvas x:Name="DiskTransferCanvas" ClipToBounds="True"/>
            </Border>
          </Grid>

          <!-- Row 6: Transfer Rate Graph Bottom Scale Labels -->
          <Grid Grid.Row="6" ColumnDefinitions="*,Auto" Margin="0,2,0,10">
            <TextBlock x:Name="DiskTransferScaleTime" Text="60 seconds" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="DiskTransferScaleZero" Text="0" FontSize="11"/>
          </Grid>

          <!-- Row 7: Authentic Statistics & Specs Section -->
          <Grid Grid.Row="7" HorizontalAlignment="Left" ColumnDefinitions="110,150,110,110,Auto,Auto" Margin="0,0,0,0">
            <!-- Col 0: Active time -->
            <StackPanel Grid.Column="0" Spacing="10">
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelDiskActiveTime" Text="Active time" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatDiskActiveTime" Text="0%" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 1: Average response time -->
            <StackPanel Grid.Column="1" Spacing="10" Margin="4,0,0,0">
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelDiskResponseTime" Text="Average response time" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatDiskResponseTime" Text="0.0 ms" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 2: Read speed -->
            <StackPanel Grid.Column="2" Spacing="10" Margin="4,0,0,0">
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelDiskReadSpeed" Text="Read speed" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatDiskReadSpeed" Text="0 KB/s" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 3: Write speed -->
            <StackPanel Grid.Column="3" Spacing="10" Margin="4,0,0,0">
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelDiskWriteSpeed" Text="Write speed" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatDiskWriteSpeed" Text="0 KB/s" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 4: Hardware Spec Labels -->
            <StackPanel Grid.Column="4" Spacing="2" Margin="36,2,12,0" VerticalAlignment="Top">
              <TextBlock x:Name="LabelDiskCapacity" Text="Capacity:" FontSize="11"/>
              <TextBlock x:Name="LabelDiskFormatted" Text="Formatted:" FontSize="11"/>
              <TextBlock x:Name="LabelDiskSystemDisk" Text="System disk:" FontSize="11"/>
              <TextBlock x:Name="LabelDiskPageFile" Text="Page file:" FontSize="11"/>
              <TextBlock x:Name="LabelDiskType" Text="Type:" FontSize="11"/>
            </StackPanel>

            <!-- Col 5: Hardware Spec Values -->
            <StackPanel Grid.Column="5" Spacing="2" Margin="0,2,0,0" VerticalAlignment="Top">
              <TextBlock x:Name="MetaDiskCapacity" Text="477 GB" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaDiskFormatted" Text="476 GB" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaDiskSystemDisk" Text="Yes" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaDiskPageFile" Text="Yes" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaDiskType" Text="SSD" FontSize="11" FontWeight="Normal"/>
            </StackPanel>
          </Grid>
        </Grid>
        <!-- Network Performance View (1-to-1 Windows 10 Task Manager) -->
        <Grid x:Name="NetworkView" RowDefinitions="Auto,Auto,*,Auto,Auto" Margin="24,12,24,12" IsVisible="False">
          <!-- Row 0: Big Header & Adapter Description -->
          <Grid Grid.Row="0" ColumnDefinitions="Auto,*" Margin="0,0,0,10">
            <TextBlock Grid.Column="0" x:Name="NetBigHeader" Text="Wi-Fi" FontSize="32" FontWeight="Light" VerticalAlignment="Center"/>
            <TextBlock Grid.Column="1" x:Name="NetAdapterText" Text="" FontSize="13" VerticalAlignment="Bottom" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
          </Grid>

          <!-- Row 1: Throughput Graph Top Scale Labels -->
          <Grid Grid.Row="1" ColumnDefinitions="*,Auto" Margin="0,0,0,2">
            <TextBlock x:Name="NetGraphHeaderLabel" Text="Throughput" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="NetGraphScaleMax" Text="100 Kbps" FontSize="11"/>
          </Grid>

          <!-- Row 2: Throughput Graph Box -->
          <Grid Grid.Row="2">
            <Border x:Name="NetGraphBorder" BorderThickness="1">
              <Canvas x:Name="NetGraphCanvas" ClipToBounds="True"/>
            </Border>
          </Grid>

          <!-- Row 3: Graph Bottom Scale Labels -->
          <Grid Grid.Row="3" ColumnDefinitions="*,Auto" Margin="0,2,0,14">
            <TextBlock x:Name="NetGraphScaleTime" Text="60 seconds" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="NetGraphScaleZero" Text="0" FontSize="11"/>
          </Grid>

          <!-- Row 4: Send / Receive Statistics & Adapter Specs -->
          <Grid Grid.Row="4" HorizontalAlignment="Left" ColumnDefinitions="115,115,Auto,Auto" Margin="0,0,0,0">
            <StackPanel Grid.Column="0" Spacing="1">
              <TextBlock x:Name="LabelNetSend" Text="Send" FontSize="11" Margin="0,0,0,1"/>
              <TextBlock x:Name="StatNetSend" Text="0 bps" FontSize="22" FontWeight="Normal"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Spacing="1" Margin="4,0,0,0">
              <TextBlock x:Name="LabelNetReceive" Text="Receive" FontSize="11" Margin="0,0,0,1"/>
              <TextBlock x:Name="StatNetReceive" Text="0 bps" FontSize="22" FontWeight="Normal"/>
            </StackPanel>
            <StackPanel Grid.Column="2" Spacing="2" Margin="36,2,12,0" VerticalAlignment="Top">
              <TextBlock x:Name="LabelNetAdapterName" Text="Adapter name:" FontSize="11"/>
              <TextBlock x:Name="LabelNetConnType" Text="Connection type:" FontSize="11"/>
              <TextBlock x:Name="LabelNetRow3" Text="SSID:" FontSize="11"/>
              <TextBlock x:Name="LabelNetRow4" Text="Signal strength:" FontSize="11"/>
              <TextBlock x:Name="LabelNetRow5" Text="IPv4 address:" FontSize="11"/>
              <TextBlock x:Name="LabelNetRow6" Text="Link speed (Receive/Transmit):" FontSize="11"/>
            </StackPanel>
            <StackPanel Grid.Column="3" Spacing="2" Margin="0,2,0,0" VerticalAlignment="Top">
              <TextBlock x:Name="MetaNetAdapterName" Text="" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaNetConnType" Text="" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaNetRow3" Text="" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaNetRow4" Text="" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaNetRow5" Text="" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaNetRow6" Text="" FontSize="11" FontWeight="Normal"/>
            </StackPanel>
          </Grid>
        </Grid>

        <!-- GPU Performance View (1-to-1 Windows 10 Task Manager) -->
        <!-- GPU Performance View (1-to-1 Windows 10 Task Manager) -->
        <Grid x:Name="GpuView" RowDefinitions="Auto,*,Auto,Auto,Auto,Auto,Auto" Margin="24,12,24,12" IsVisible="False">
          <!-- Row 0: Big Header & GPU Name -->
          <Grid Grid.Row="0" ColumnDefinitions="Auto,*" Margin="0,0,0,10">
            <TextBlock Grid.Column="0" x:Name="GpuBigHeader" Text="GPU" FontSize="32" FontWeight="Light" VerticalAlignment="Center"/>
            <TextBlock Grid.Column="1" x:Name="GpuNameText" Text="" FontSize="13" VerticalAlignment="Bottom" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
          </Grid>

          <!-- Row 1: Per-engine graphs (3D, Copy, Compute 0/1, ...) built in code -->
          <Grid Grid.Row="1" x:Name="GpuEnginesGrid" MinHeight="140" Margin="0,0,0,8"/>

          <!-- Row 2: Dedicated GPU memory usage label + scale -->
          <Grid Grid.Row="2" ColumnDefinitions="*,Auto" Margin="0,0,0,2">
            <TextBlock x:Name="GpuDedMemHeaderLabel" Text="Dedicated GPU memory usage" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="GpuDedMemScaleMax" Text="" FontSize="11"/>
          </Grid>

          <!-- Row 3: Dedicated GPU memory graph -->
          <Grid Grid.Row="3" MinHeight="60" Margin="0,0,0,8">
            <Border x:Name="GpuDedMemBorder" BorderThickness="1">
              <Canvas x:Name="GpuDedMemCanvas" ClipToBounds="True"/>
            </Border>
          </Grid>

          <!-- Row 4: Shared GPU memory usage label + scale -->
          <Grid Grid.Row="4" ColumnDefinitions="*,Auto" Margin="0,0,0,2">
            <TextBlock x:Name="GpuSharedMemHeaderLabel" Text="Shared GPU memory usage" FontSize="11"/>
            <TextBlock Grid.Column="1" x:Name="GpuSharedMemScaleMax" Text="" FontSize="11"/>
          </Grid>

          <!-- Row 5: Shared GPU memory graph -->
          <Grid Grid.Row="5" MinHeight="60" Margin="0,0,0,10">
            <Border x:Name="GpuSharedMemBorder" BorderThickness="1">
              <Canvas x:Name="GpuSharedMemCanvas" ClipToBounds="True"/>
            </Border>
          </Grid>

          <!-- Row 6: Statistics & Specs -->
          <Grid Grid.Row="6" HorizontalAlignment="Left" ColumnDefinitions="150,190,Auto,Auto" Margin="0,0,0,0">
            <!-- Col 0: Utilization, GPU Memory -->
            <StackPanel Grid.Column="0" Spacing="10">
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelGpuUtil" Text="Utilization" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatGpuUtil" Text="0%" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelGpuMem" Text="GPU Memory" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatGpuMem" Text="0 B" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 1: Dedicated, Shared, Temperature -->
            <StackPanel Grid.Column="1" Spacing="10" Margin="4,0,0,0">
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelGpuDedicated" Text="Dedicated GPU memory" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatGpuDedicated" Text="0 B" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelGpuShared" Text="Shared GPU memory" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatGpuShared" Text="0 B" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
              <StackPanel Spacing="1">
                <TextBlock x:Name="LabelGpuTemp" Text="GPU Temperature" FontSize="11" Margin="0,0,0,1"/>
                <TextBlock x:Name="StatGpuTemp" Text="&#x2014;" FontSize="22" FontWeight="Normal"/>
              </StackPanel>
            </StackPanel>

            <!-- Col 2: Spec Labels -->
            <StackPanel Grid.Column="2" Spacing="2" Margin="36,2,12,0" VerticalAlignment="Top">
              <TextBlock x:Name="LabelGpuDriverVer" Text="Driver version:" FontSize="11"/>
              <TextBlock x:Name="LabelGpuDriverDate" Text="Driver date:" FontSize="11"/>
              <TextBlock x:Name="LabelGpuDx" Text="DirectX version:" FontSize="11"/>
              <TextBlock x:Name="LabelGpuLocation" Text="Physical location:" FontSize="11"/>
              <TextBlock x:Name="LabelGpuHwReserved" Text="Hardware reserved memory:" FontSize="11"/>
            </StackPanel>

            <!-- Col 3: Spec Values -->
            <StackPanel Grid.Column="3" Spacing="2" Margin="0,2,0,0" VerticalAlignment="Top">
              <TextBlock x:Name="MetaGpuDriverVer" Text="" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaGpuDriverDate" Text="" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaGpuDx" Text="" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaGpuLocation" Text="" FontSize="11" FontWeight="Normal"/>
              <TextBlock x:Name="MetaGpuHwReserved" Text="" FontSize="11" FontWeight="Normal"/>
            </StackPanel>
          </Grid>
        </Grid>
      </Grid>
    </Grid>
    
    <!-- Processes Panel (hidden by default) -->
    <Grid Grid.Row="2" x:Name="ProcessesPanel" IsVisible="False">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <!-- Column headers with totals -->
      <Grid Grid.Row="0" x:Name="ProcHeaderGrid" Margin="8,4,8,2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="100"/>
          <ColumnDefinition Width="100"/>
          <ColumnDefinition Width="100"/>
          <ColumnDefinition Width="100"/>
        </Grid.ColumnDefinitions>
        <!-- Totals row -->
        <TextBlock Grid.Row="0" Grid.Column="1" x:Name="ProcTotalCpu" Text="0%" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
        <TextBlock Grid.Row="0" Grid.Column="2" x:Name="ProcTotalMem" Text="0%" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
        <TextBlock Grid.Row="0" Grid.Column="3" x:Name="ProcTotalDisk" Text="0%" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
        <TextBlock Grid.Row="0" Grid.Column="4" x:Name="ProcTotalNet" Text="0%" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
        <!-- Labels row -->
        <TextBlock Grid.Row="1" Grid.Column="0" Text="Name" FontSize="12" Foreground="Gray"/>
        <TextBlock Grid.Row="1" Grid.Column="1" Text="CPU" FontSize="12" Foreground="Gray" HorizontalAlignment="Right"/>
        <TextBlock Grid.Row="1" Grid.Column="2" Text="Memory" FontSize="12" Foreground="Gray" HorizontalAlignment="Right"/>
        <TextBlock Grid.Row="1" Grid.Column="3" Text="Disk" FontSize="12" Foreground="Gray" HorizontalAlignment="Right"/>
        <TextBlock Grid.Row="1" Grid.Column="4" Text="Network" FontSize="12" Foreground="Gray" HorizontalAlignment="Right"/>
      </Grid>
      <!-- Process list -->
      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="ProcessListPanel" Margin="8,0,8,8"/>
      </ScrollViewer>
    </Grid>


    <!-- Row 3: Bottom Bar (Fewer details & Open Resource Monitor) -->
    <Border Grid.Row="3" x:Name="BottomBarBorder" Height="34" Padding="14,0" BorderThickness="0,1,0,0">
      <Grid ColumnDefinitions="Auto,*,Auto">
        <StackPanel Grid.Column="0" Orientation="Horizontal" Spacing="6" VerticalAlignment="Center" Cursor="Hand">
          <Border BorderThickness="1" BorderBrush="#888888" CornerRadius="8" Width="15" Height="15" VerticalAlignment="Center">
            <Path Data="M 3.5,8.5 L 7.5,4.5 L 11.5,8.5" Stroke="#888888" StrokeThickness="1.2" VerticalAlignment="Center" HorizontalAlignment="Center"/>
          </Border>
          <TextBlock x:Name="BottomFewerDetails" Text="Fewer details" FontSize="11" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" Spacing="6" VerticalAlignment="Center" Cursor="Hand" PointerPressed="OnOpenResmonClick">
          <Canvas Width="16" Height="16" VerticalAlignment="Center">
            <Path Data="M 2,12 A 6,6 0 1 1 14,12 Z" Fill="Transparent" Stroke="#1070B8" StrokeThickness="1.2"/>
            <Line StartPoint="8,10" EndPoint="11,6" Stroke="#C84B31" StrokeThickness="1.5" StrokeLineCap="Round"/>
            <Ellipse Width="3" Height="3" Canvas.Left="6.5" Canvas.Top="8.5" Fill="#1070B8"/>
          </Canvas>
          <TextBlock x:Name="BottomResmonText" Text="Open Resource Monitor" FontSize="11" VerticalAlignment="Center"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$mwProcCs = @'
// MainWindow.Processes.cs
// Processes tab for CpuTaskManager - Task Manager clone
// Grouped process list with auto-refresh, matching Windows 10 Task Manager.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;

namespace __APPNAME__
{
    internal sealed class ProcessInfo
    {
        public int Pid;
        public string Name = "";
        public string DisplayName = "";
        public double CpuPercent;
        public long MemoryBytes;
        public TimeSpan TotalProcessorTime;
        public DateTime LastSampleTime;
        public bool IsApp;
        public bool IsSystem;
    }

    internal sealed class ProcessGroup
    {
        public string Title = "";
        public List<ProcessInfo> Processes = new List<ProcessInfo>();
        public bool Expanded = true;
        public double TotalCpu;
        public long TotalMemory;
    }

    public partial class MainWindow
    {
        private Dictionary<int, ProcessInfo> _processCache = new Dictionary<int, ProcessInfo>();
        private List<ProcessGroup> _processGroups = new List<ProcessGroup>();
        private DispatcherTimer? _processTimer;
        private bool _processesInitialized = false;
        private double _totalCpuPercent;
        private double _totalMemPercent;

        private void InitializeProcessesTab()
        {
            if (_processesInitialized) return;
            _processesInitialized = true;
            // Start auto-refresh timer (2 seconds like Task Manager)
            _processTimer = new DispatcherTimer();
            _processTimer.Interval = TimeSpan.FromSeconds(2);
            _processTimer.Tick += (s, e) =>
            {
                if (_activePanel == PerformancePanel.Processes)
                {
                    RefreshProcessList();
                    UpdateProcessListUI();
                }
            };
        }

        private void RefreshProcessList()
        {
            try
            {
                var now = DateTime.UtcNow;
                var currentPids = new HashSet<int>();
                int cores = Environment.ProcessorCount;

                foreach (var proc in Process.GetProcesses())
                {
                    try
                    {
                        int pid = proc.Id;
                        currentPids.Add(pid);

                        if (!_processCache.TryGetValue(pid, out var info))
                        {
                            info = new ProcessInfo
                            {
                                Pid = pid,
                                Name = proc.ProcessName,
                                DisplayName = GetProcessDisplayName(proc),
                                TotalProcessorTime = proc.TotalProcessorTime,
                                LastSampleTime = now,
                                IsApp = HasVisibleWindow(proc),
                                IsSystem = IsSystemProcess(proc),
                            };
                            try { info.MemoryBytes = proc.WorkingSet64; } catch { }
                            _processCache[pid] = info;
                        }
                        else
                        {
                            try
                            {
                                var newCpuTime = proc.TotalProcessorTime;
                                var timeDelta = (now - info.LastSampleTime).TotalMilliseconds;
                                if (timeDelta > 100)
                                {
                                    var cpuDelta = (newCpuTime - info.TotalProcessorTime).TotalMilliseconds;
                                    info.CpuPercent = Math.Max(0, Math.Min(100, (cpuDelta / timeDelta) / cores * 100.0));
                                }
                                info.TotalProcessorTime = newCpuTime;
                                info.LastSampleTime = now;
                                try { info.MemoryBytes = proc.WorkingSet64; } catch { }
                            }
                            catch { }
                        }
                    }
                    catch { }
                    finally { try { proc.Dispose(); } catch { } }
                }

                var dead = _processCache.Keys.Where(k => !currentPids.Contains(k)).ToList();
                foreach (var pid in dead) _processCache.Remove(pid);

                // Group processes like Task Manager
                var apps = new ProcessGroup { Title = "Apps" };
                var bg = new ProcessGroup { Title = "Background processes" };
                var win = new ProcessGroup { Title = "Windows processes" };

                foreach (var p in _processCache.Values)
                {
                    if (p.IsSystem) win.Processes.Add(p);
                    else if (p.IsApp) apps.Processes.Add(p);
                    else bg.Processes.Add(p);
                }

                // Sort each group by CPU descending
                foreach (var g in new[] { apps, bg, win })
                {
                    g.Processes = g.Processes.OrderByDescending(p => p.CpuPercent).ToList();
                    g.TotalCpu = g.Processes.Sum(p => p.CpuPercent);
                    g.TotalMemory = g.Processes.Sum(p => p.MemoryBytes);
                    g.Title = g.Title.Split('(')[0].Trim() + $" ({g.Processes.Count})";
                }

                _processGroups = new List<ProcessGroup> { apps, bg, win };
                _totalCpuPercent = _processCache.Values.Sum(p => p.CpuPercent);
                
                // Memory percent
                try
                {
                    var totalMem = GC.GetTotalMemory(false);
                    // Use performance counter or estimate
                    _totalMemPercent = Math.Min(100, _processCache.Values.Sum(p => p.MemoryBytes) / (16.0 * 1024 * 1024 * 1024) * 100);
                }
                catch { }
            }
            catch { }
        }

        private static bool IsSystemProcess(Process proc)
        {
            try
            {
                string name = proc.ProcessName.ToLowerInvariant();
                // Windows system processes
                return name == "system" || name == "registry" || name == "smss" ||
                       name == "csrss" || name == "wininit" || name == "services" ||
                       name == "lsass" || name == "lsalso" || name == "winlogon" ||
                       name == "fontdrvhost" || name == "wudfhost" || name == "svchost" ||
                       name.StartsWith("secure system");
            }
            catch { return false; }
        }

        private static string GetProcessDisplayName(Process proc)
        {
            try
            {
                if (!string.IsNullOrEmpty(proc.MainWindowTitle))
                    return proc.MainWindowTitle.Trim();
            }
            catch { }
            try { return proc.ProcessName; } catch { return "?"; }
        }

        private static bool HasVisibleWindow(Process proc)
        {
            try { return proc.MainWindowHandle != IntPtr.Zero; }
            catch { return false; }
        }

        private void ShowProcessesPanel()
        {
            if (!_isInitialized) return;
            InitializeProcessesTab();
            _activePanel = PerformancePanel.Processes;

            var perfGrid = this.FindControl<Grid>("PerformanceMainGrid");
            var procPanel = this.FindControl<Grid>("ProcessesPanel");
            if (perfGrid != null) perfGrid.IsVisible = false;
            if (procPanel != null) procPanel.IsVisible = true;

            ClearMainTileHighlights();
            HighlightNetGpuTiles(null, false);

            _processTimer?.Start();
            RefreshProcessList();
            UpdateProcessListUI();
        }

        private void ShowPerformancePanel()
        {
            if (!_isInitialized) return;
            _processTimer?.Stop();
            _activePanel = PerformancePanel.Cpu;

            var perfGrid = this.FindControl<Grid>("PerformanceMainGrid");
            var procPanel = this.FindControl<Grid>("ProcessesPanel");
            if (perfGrid != null) perfGrid.IsVisible = true;
            if (procPanel != null) procPanel.IsVisible = false;

            SetActivePanel(PerformancePanel.Cpu);
        }

        private void UpdateProcessListUI()
        {
            var listPanel = this.FindControl<StackPanel>("ProcessListPanel");
            if (listPanel == null) return;

            // Update column header totals (like real Task Manager)
            var totalCpu = this.FindControl<TextBlock>("ProcTotalCpu");
            var totalMem = this.FindControl<TextBlock>("ProcTotalMem");
            var totalDisk = this.FindControl<TextBlock>("ProcTotalDisk");
            var totalNet = this.FindControl<TextBlock>("ProcTotalNet");
            if (totalCpu != null) totalCpu.Text = $"{_totalCpuPercent:F0}%";
            if (totalMem != null) totalMem.Text = $"{_totalMemPercent:F0}%";
            if (totalDisk != null) totalDisk.Text = "0%";
            if (totalNet != null) totalNet.Text = "0%";

            listPanel.Children.Clear();
            var textColor = new SolidColorBrush(_isDark ? Color.Parse("#FFFFFF") : Color.Parse("#000000"));
            var textDim = new SolidColorBrush(_isDark ? Color.Parse("#A0A0A0") : Color.Parse("#666666"));
            var groupColor = new SolidColorBrush(_isDark ? Color.Parse("#4CC2FF") : Color.Parse("#0067B8"));
            var highlightBg = new SolidColorBrush(_isDark ? Color.Parse("#3A3A00") : Color.Parse("#FFF8DC"));

            foreach (var group in _processGroups)
            {
                if (group.Processes.Count == 0) continue;

                // Group header
                var headerBtn = new Button
                {
                    Content = (group.Expanded ? "v " : "> ") + group.Title,
                    FontSize = 13,
                    FontWeight = FontWeight.SemiBold,
                    Foreground = groupColor,
                    Background = Brushes.Transparent,
                    BorderThickness = new Thickness(0),
                    Padding = new Thickness(4, 6, 0, 6),
                    HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Left,
                    Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
                };
                var g = group;
                headerBtn.Click += (s, e) => { g.Expanded = !g.Expanded; UpdateProcessListUI(); };
                listPanel.Children.Add(headerBtn);

                if (!group.Expanded) continue;

                // Group processes
                foreach (var p in group.Processes.Take(100))
                {
                    var grid = new Grid { Margin = new Thickness(16, 0, 0, 0) };
                    grid.ColumnDefinitions.Add(new ColumnDefinition(1, GridUnitType.Star));
                    grid.ColumnDefinitions.Add(new ColumnDefinition(100, GridUnitType.Pixel));
                    grid.ColumnDefinitions.Add(new ColumnDefinition(110, GridUnitType.Pixel));
                    grid.ColumnDefinitions.Add(new ColumnDefinition(100, GridUnitType.Pixel));
                    grid.ColumnDefinitions.Add(new ColumnDefinition(100, GridUnitType.Pixel));

                    bool highCpu = p.CpuPercent > 5;
                    if (highCpu) grid.Background = highlightBg;

                    var nameBlock = new TextBlock
                    {
                        Text = string.IsNullOrEmpty(p.DisplayName) ? p.Name : p.DisplayName,
                        FontSize = 12,
                        Foreground = textColor,
                        Margin = new Thickness(4, 3, 0, 3),
                        TextTrimming = Avalonia.Media.TextTrimming.CharacterEllipsis,
                    };
                    var cpuBlock = new TextBlock
                    {
                        Text = $"{p.CpuPercent:F1}%",
                        FontSize = 12,
                        Foreground = p.CpuPercent > 1 ? textColor : textDim,
                        HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right,
                        Margin = new Thickness(0, 3, 8, 3),
                    };
                    var memBlock = new TextBlock
                    {
                        Text = FormatBytes(p.MemoryBytes),
                        FontSize = 12,
                        Foreground = textColor,
                        HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right,
                        Margin = new Thickness(0, 3, 8, 3),
                    };
                    var diskBlock = new TextBlock
                    {
                        Text = "0 MB/s",
                        FontSize = 12,
                        Foreground = textDim,
                        HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right,
                        Margin = new Thickness(0, 3, 8, 3),
                    };
                    var netBlock = new TextBlock
                    {
                        Text = "0 Mbps",
                        FontSize = 12,
                        Foreground = textDim,
                        HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right,
                        Margin = new Thickness(0, 3, 8, 3),
                    };

                    Grid.SetColumn(nameBlock, 0);
                    Grid.SetColumn(cpuBlock, 1);
                    Grid.SetColumn(memBlock, 2);
                    Grid.SetColumn(diskBlock, 3);
                    Grid.SetColumn(netBlock, 4);
                    grid.Children.Add(nameBlock);
                    grid.Children.Add(cpuBlock);
                    grid.Children.Add(memBlock);
                    grid.Children.Add(diskBlock);
                    grid.Children.Add(netBlock);
                    listPanel.Children.Add(grid);
                }
            }
        }

        private static string FormatBytes(long bytes)
        {
            if (bytes < 1024) return $"{bytes} B";
            if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
            if (bytes < 1024 * 1024 * 1024) return $"{bytes / (1024.0 * 1024):F1} MB";
            return $"{bytes / (1024.0 * 1024 * 1024):F1} GB";
        }
    }
}

'@

$mwCs = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Avalonia.Media;
using Avalonia.Threading;
using Microsoft.Win32;

namespace __APPNAME__
{
    internal enum PerformancePanel
    {
        Cpu,
        Memory,
        Disk,
        Network,
        Gpu,
        Processes
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SystemProcessorPerformanceInfo
    {
        public long IdleTime;
        public long KernelTime;
        public long UserTime;
        public long DpcTime;
        public long InterruptTime;
        public uint InterruptCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ProcessPowerInformation
    {
        public uint Number;
        public uint MaxMhz;
        public uint CurrentMhz;
        public uint MhzLimit;
        public uint MaxIdleState;
        public uint CurrentIdleState;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PERFORMANCE_INFORMATION
    {
        public uint cb;
        public UIntPtr CommitTotal;
        public UIntPtr CommitLimit;
        public UIntPtr CommitPeak;
        public UIntPtr PhysicalTotal;
        public UIntPtr PhysicalAvailable;
        public UIntPtr SystemCache;
        public UIntPtr KernelTotal;
        public UIntPtr KernelPaged;
        public UIntPtr KernelNonpaged;
        public UIntPtr PageSize;
        public uint HandleCount;
        public uint ProcessCount;
        public uint ThreadCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PDH_FMT_COUNTERVALUE_DOUBLE
    {
        public uint CStatus;
        public double doubleValue;
    }

    public partial class MainWindow : Window
    {
        [DllImport("dwmapi.dll", PreserveSig = true)]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
        private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

        [DllImport("ntdll.dll", SetLastError = false)]
        private static extern int NtQuerySystemInformation(int systemInformationClass, IntPtr systemInformation, int systemInformationLength, out int returnLength);

        [DllImport("powrprof.dll", SetLastError = false)]
        private static extern int CallNtPowerInformation(int informationLevel, IntPtr inputBuffer, uint inputBufferLength, IntPtr outputBuffer, uint outputBufferLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetPhysicallyInstalledSystemMemory(out ulong totalMemoryInKilobytes);

        [DllImport("psapi.dll", SetLastError = true)]
        private static extern bool GetPerformanceInfo(out PERFORMANCE_INFORMATION pPerformanceInformation, uint cb);

        [DllImport("pdh.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern int PdhOpenQuery(string? szDataSource, IntPtr dwUserData, out IntPtr phQuery);

        [DllImport("pdh.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern int PdhAddEnglishCounterW(IntPtr hQuery, string szFullCounterPath, IntPtr dwUserData, out IntPtr phCounter);

        [DllImport("pdh.dll", SetLastError = true)]
        private static extern int PdhCollectQueryData(IntPtr hQuery);

        [DllImport("pdh.dll", SetLastError = true)]
        private static extern int PdhGetFormattedCounterValue(IntPtr hCounter, uint dwFormat, out uint lpdwType, out PDH_FMT_COUNTERVALUE_DOUBLE pValue);

        [DllImport("pdh.dll", SetLastError = true)]
        private static extern int PdhCloseQuery(IntPtr hQuery);

        private IntPtr _hPdhQuery = IntPtr.Zero;
        private IntPtr _hPdhCounter = IntPtr.Zero;

        // PDH Disk Counter Handles
        private IntPtr _hPdhDiskTimeCounter = IntPtr.Zero;
        private IntPtr _hPdhDiskResponseCounter = IntPtr.Zero;
        private IntPtr _hPdhDiskReadCounter = IntPtr.Zero;
        private IntPtr _hPdhDiskWriteCounter = IntPtr.Zero;
        private IntPtr _hPdhDiskTransferCounter = IntPtr.Zero;

        private bool _isInitialized = false;
        private DispatcherTimer? _timer;
        private int _updateIntervalSec = 1;
        private PerformancePanel _activePanel = PerformancePanel.Cpu;

        private long[]? _prevCoreIdle;
        private long[]? _prevCoreTotal;
        private long[]? _prevCoreKernel;

        private readonly List<double> _overallHistory = new List<double>();
        private readonly List<double> _overallKernelHistory = new List<double>();
        private readonly List<List<double>> _coreHistories = new List<List<double>>();
        private readonly List<List<double>> _coreKernelHistories = new List<List<double>>();

        private readonly List<double> _memHistory = new List<double>();
        private readonly List<double> _diskHistory = new List<double>();
        private readonly List<double> _diskTransferHistory = new List<double>();
        private double _latestPeakTransferRate = 100 * 1024.0;

        private readonly List<double> _wifiHistory = new List<double>();
        private readonly List<double> _eth1History = new List<double>();
        private readonly List<double> _eth2History = new List<double>();
        private readonly List<double> _gpuHistory = new List<double>();

        private double _latestMemInUseGb = 10.9;
        private double _latestMemAvailGb = 16.8;
        private double _latestMemTotalGb = 27.7;
        private double _latestMemCachedGb = 15.8;
        private double _latestMemStandbyGb = 15.0;
        private double _latestMemModifiedGb = 0.2;
        private double _latestMemFreeGb = 1.8;

        private long _prevWifiBytesSent = 0;
        private long _prevWifiBytesRecv = 0;
        private DateTime _prevNetSampleTime = DateTime.UtcNow;

        private bool _isDark = false;
        private bool _isLogicalView = true;
        private bool _showKernelTimes = false;
        private int _logicalCoreCount = 16;
        private double _baseFreqGhz = 3.30;
        private string _gpuName = "AMD Radeon 780M...";

        private Grid? _rootGrid;
        private Border? _menuBarBorder;
        private Border? _tabBarBorder;
        private Border? _sidebarBorder;
        private Border? _bottomBarBorder;
        private Border? _tabPerfBorder;

        private Menu? _mainMenu;
        private MenuItem? _menuFile;
        private MenuItem? _menuOptions;
        private MenuItem? _menuView;
        private MenuItem? _menuAlwaysOnTop;
        private MenuItem? _menuDarkMode;
        private MenuItem? _menuChangeGraphRoot;

        private TextBlock? _tabProcesses;
        private TextBlock? _tabPerformance;
        private TextBlock? _tabAppHistory;
        private TextBlock? _tabStartup;
        private TextBlock? _tabUsers;
        private TextBlock? _tabDetails;
        private TextBlock? _tabServices;

        private Border? _cpuTileBorder;
        private Border? _memTileBorder;
        private Border? _diskTileBorder;
        private Border? _wifiTileBorder;
        private Border? _eth1TileBorder;
        private Border? _eth2TileBorder;
        private Border? _gpuTileBorder;

        private Border? _miniCpuBox;
        private Border? _miniMemBox;
        private Border? _miniDiskBox;
        private Border? _miniWifiBox;
        private Border? _miniEth1Box;
        private Border? _miniEth2Box;
        private Border? _miniGpuBox;

        private TextBlock? _miniCpuHeading;
        private TextBlock? _miniCpuText;
        private TextBlock? _miniMemHeading;
        private TextBlock? _miniMemText;
        private TextBlock? _miniDiskHeading;
        private TextBlock? _miniDiskText;
        private TextBlock? _miniWifiHeading;
        private TextBlock? _miniWifiText;
        private TextBlock? _miniEth1Heading;
        private TextBlock? _miniEth1Text;
        private TextBlock? _miniEth2Heading;
        private TextBlock? _miniEth2Text;
        private TextBlock? _miniGpuHeading;
        private TextBlock? _miniGpuText;

        private Canvas? _miniCpuCanvas;
        private Canvas? _miniMemCanvas;
        private Canvas? _miniDiskCanvas;
        private Canvas? _miniWifiCanvas;
        private Canvas? _miniEth1Canvas;
        private Canvas? _miniEth2Canvas;
        private Canvas? _miniGpuCanvas;

        // CPU Panel Controls
        private Grid? _cpuView;
        private TextBlock? _cpuBigHeader;
        private TextBlock? _cpuBrandText;
        private TextBlock? _graphHeaderLabel;
        private TextBlock? _graphScaleMax;
        private TextBlock? _graphScaleTime;
        private TextBlock? _graphScaleZero;
        private Border? _overallGraphBorder;
        private Canvas? _overallCpuCanvas;
        private Grid? _logicalCoresGrid;

        private TextBlock? _labelUtil;
        private TextBlock? _labelSpeed;
        private TextBlock? _labelUptime;
        private TextBlock? _labelProcs;
        private TextBlock? _labelThreads;
        private TextBlock? _labelHandles;

        private TextBlock? _statUtilization;
        private TextBlock? _statSpeed;
        private TextBlock? _statUptime;
        private TextBlock? _statProcesses;
        private TextBlock? _statThreads;
        private TextBlock? _statHandles;

        private TextBlock? _labelBaseSpeed;
        private TextBlock? _labelSockets;
        private TextBlock? _labelCores;
        private TextBlock? _labelLogical;
        private TextBlock? _labelVirt;
        private TextBlock? _labelL1;
        private TextBlock? _labelL2;
        private TextBlock? _labelL3;

        private TextBlock? _metaBaseSpeed;
        private TextBlock? _metaSockets;
        private TextBlock? _metaPhysicalCores;
        private TextBlock? _metaLogicalCores;
        private TextBlock? _metaVirtualization;
        private TextBlock? _metaL1;
        private TextBlock? _metaL2;
        private TextBlock? _metaL3;

        // Memory Panel Controls
        private Grid? _memoryView;
        private TextBlock? _memBigHeader;
        private TextBlock? _memTotalHeader;
        private TextBlock? _memGraphHeaderLabel;
        private TextBlock? _memGraphScaleMax;
        private TextBlock? _memGraphScaleTime;
        private TextBlock? _memGraphScaleZero;
        private Border? _overallMemBorder;
        private Canvas? _overallMemCanvas;
        private TextBlock? _labelMemComposition;
        private Border? _memCompositionBorder;
        private Canvas? _memCompositionCanvas;

        private TextBlock? _labelMemInUse;
        private TextBlock? _labelMemAvailable;
        private TextBlock? _labelMemCommitted;
        private TextBlock? _labelMemCached;
        private TextBlock? _labelMemPagedPool;
        private TextBlock? _labelMemNonPagedPool;

        private TextBlock? _statMemInUse;
        private TextBlock? _statMemAvailable;
        private TextBlock? _statMemCommitted;
        private TextBlock? _statMemCached;
        private TextBlock? _statMemPagedPool;
        private TextBlock? _statMemNonPagedPool;

        private TextBlock? _labelMemSpeed;
        private TextBlock? _labelMemSlots;
        private TextBlock? _labelMemFormFactor;
        private TextBlock? _labelMemReserved;

        private TextBlock? _metaMemSpeed;
        private TextBlock? _metaMemSlots;
        private TextBlock? _metaMemFormFactor;
        private TextBlock? _metaMemReserved;

        // Disk Panel Controls
        private Grid? _diskView;
        private TextBlock? _diskBigHeader;
        private TextBlock? _diskModelText;
        private TextBlock? _diskActiveTimeHeaderLabel;
        private TextBlock? _diskActiveTimeScaleMax;
        private Border? _diskActiveBorder;
        private Canvas? _diskActiveCanvas;
        private TextBlock? _diskActiveScaleTime;
        private TextBlock? _diskActiveScaleZero;

        private TextBlock? _diskTransferHeaderLabel;
        private TextBlock? _diskTransferScaleMax;
        private Border? _diskTransferBorder;
        private Canvas? _diskTransferCanvas;
        private TextBlock? _diskTransferScaleTime;
        private TextBlock? _diskTransferScaleZero;

        private TextBlock? _labelDiskActiveTime;
        private TextBlock? _labelDiskResponseTime;
        private TextBlock? _labelDiskReadSpeed;
        private TextBlock? _labelDiskWriteSpeed;

        private TextBlock? _statDiskActiveTime;
        private TextBlock? _statDiskResponseTime;
        private TextBlock? _statDiskReadSpeed;
        private TextBlock? _statDiskWriteSpeed;

        private TextBlock? _labelDiskCapacity;
        private TextBlock? _labelDiskFormatted;
        private TextBlock? _labelDiskSystemDisk;
        private TextBlock? _labelDiskPageFile;
        private TextBlock? _labelDiskType;

        private TextBlock? _metaDiskCapacity;
        private TextBlock? _metaDiskFormatted;
        private TextBlock? _metaDiskSystemDisk;
        private TextBlock? _metaDiskPageFile;
        private TextBlock? _metaDiskType;

        private TextBlock? _bottomFewerDetails;
        private TextBlock? _bottomResmonText;

        private readonly List<Canvas> _coreCanvases = new List<Canvas>();
        private readonly List<Border> _coreCards = new List<Border>();

        public MainWindow()
        {
            this.Opened += (s, e) => UpdateTitleBarDarkMode();
            InitializeComponent();
            LoadSettings();
            BindControls();
            InitHardwareMetadata();
            InitMemoryMetadata();
            InitDiskMetadata();
            InitPdhFrequencyCounter();
            InitPdhDiskCounters();
            InitNetworkGpu();
            InitLogicalGraphs();
            SetupGraphContextMenus();
            ApplyThemeColors();
            _isInitialized = true;

            this.Opened += OnOpened;
            this.Closed += OnClosedCleanup;
            this.SizeChanged += (s, e) =>
            {
                if (_isInitialized)
                {
                    Dispatcher.UIThread.Post(() => RedrawAllCharts(), DispatcherPriority.Render);
                }
            };
        }

        private void InitializeComponent() => AvaloniaXamlLoader.Load(this);

        private static string GetSettingsFilePath()
        {
            string appData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string dir = System.IO.Path.Combine(appData, "CpuTaskManager");
            if (!System.IO.Directory.Exists(dir)) System.IO.Directory.CreateDirectory(dir);
            return System.IO.Path.Combine(dir, "settings.txt");
        }

        private void LoadSettings()
        {
            try
            {
                string path = GetSettingsFilePath();
                if (System.IO.File.Exists(path))
                {
                    string content = System.IO.File.ReadAllText(path).Trim();
                    if (content.Equals("dark", StringComparison.OrdinalIgnoreCase)) { _isDark = true; return; }
                    if (content.Equals("light", StringComparison.OrdinalIgnoreCase)) { _isDark = false; return; }
                }
            }
            catch { }
            DetectSystemTheme();
        }

        private void DetectSystemTheme()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                if (key != null && key.GetValue("AppsUseLightTheme") is int val)
                {
                    _isDark = (val == 0);
                }
            }
            catch { }
        }

        private void SaveSettings()
        {
            try
            {
                string path = GetSettingsFilePath();
                System.IO.File.WriteAllText(path, _isDark ? "dark" : "light");
            }
            catch { }
        }

        private void BindControls()
        {
            _rootGrid = this.FindControl<Grid>("RootGrid");
            _menuBarBorder = this.FindControl<Border>("MenuBarBorder");
            _tabBarBorder = this.FindControl<Border>("TabBarBorder");
            _sidebarBorder = this.FindControl<Border>("SidebarBorder");
            _bottomBarBorder = this.FindControl<Border>("BottomBarBorder");
            _tabPerfBorder = this.FindControl<Border>("TabPerfBorder");

            _mainMenu = this.FindControl<Menu>("MainMenu");
            _menuFile = this.FindControl<MenuItem>("MenuFile");
            _menuOptions = this.FindControl<MenuItem>("MenuOptions");
            _menuView = this.FindControl<MenuItem>("MenuView");
            _menuAlwaysOnTop = this.FindControl<MenuItem>("MenuAlwaysOnTop");
            _menuDarkMode = this.FindControl<MenuItem>("MenuDarkMode");
            _menuChangeGraphRoot = this.FindControl<MenuItem>("MenuChangeGraphRoot");

            _tabProcesses = this.FindControl<TextBlock>("TabProcesses");
            _tabPerformance = this.FindControl<TextBlock>("TabPerformance");
            _tabAppHistory = this.FindControl<TextBlock>("TabAppHistory");
            _tabStartup = this.FindControl<TextBlock>("TabStartup");
            _tabUsers = this.FindControl<TextBlock>("TabUsers");
            _tabDetails = this.FindControl<TextBlock>("TabDetails");
            _tabServices = this.FindControl<TextBlock>("TabServices");

            _cpuTileBorder = this.FindControl<Border>("CpuTileBorder");
            _memTileBorder = this.FindControl<Border>("MemTileBorder");
            _diskTileBorder = this.FindControl<Border>("DiskTileBorder");
            _wifiTileBorder = this.FindControl<Border>("WifiTileBorder");
            _eth1TileBorder = this.FindControl<Border>("Eth1TileBorder");
            _eth2TileBorder = this.FindControl<Border>("Eth2TileBorder");
            _gpuTileBorder = this.FindControl<Border>("GpuTileBorder");

            _miniCpuBox = this.FindControl<Border>("MiniCpuBox");
            _miniMemBox = this.FindControl<Border>("MiniMemBox");
            _miniDiskBox = this.FindControl<Border>("MiniDiskBox");
            _miniWifiBox = this.FindControl<Border>("MiniWifiBox");
            _miniEth1Box = this.FindControl<Border>("MiniEth1Box");
            _miniEth2Box = this.FindControl<Border>("MiniEth2Box");
            _miniGpuBox = this.FindControl<Border>("MiniGpuBox");

            _miniCpuHeading = this.FindControl<TextBlock>("MiniCpuHeading");
            _miniCpuText = this.FindControl<TextBlock>("MiniCpuText");
            _miniMemHeading = this.FindControl<TextBlock>("MiniMemHeading");
            _miniMemText = this.FindControl<TextBlock>("MiniMemText");
            _miniDiskHeading = this.FindControl<TextBlock>("MiniDiskHeading");
            _miniDiskText = this.FindControl<TextBlock>("MiniDiskText");
            _miniWifiHeading = this.FindControl<TextBlock>("MiniWifiHeading");
            _miniWifiText = this.FindControl<TextBlock>("MiniWifiText");
            _miniEth1Heading = this.FindControl<TextBlock>("MiniEth1Heading");
            _miniEth1Text = this.FindControl<TextBlock>("MiniEth1Text");
            _miniEth2Heading = this.FindControl<TextBlock>("MiniEth2Heading");
            _miniEth2Text = this.FindControl<TextBlock>("MiniEth2Text");
            _miniGpuHeading = this.FindControl<TextBlock>("MiniGpuHeading");
            _miniGpuText = this.FindControl<TextBlock>("MiniGpuText");

            _miniCpuCanvas = this.FindControl<Canvas>("MiniCpuCanvas");
            _miniMemCanvas = this.FindControl<Canvas>("MiniMemCanvas");
            _miniDiskCanvas = this.FindControl<Canvas>("MiniDiskCanvas");
            _miniWifiCanvas = this.FindControl<Canvas>("MiniWifiCanvas");
            _miniEth1Canvas = this.FindControl<Canvas>("MiniEth1Canvas");
            _miniEth2Canvas = this.FindControl<Canvas>("MiniEth2Canvas");
            _miniGpuCanvas = this.FindControl<Canvas>("MiniGpuCanvas");

            // CPU View Binding
            _cpuView = this.FindControl<Grid>("CpuView");
            _cpuBigHeader = this.FindControl<TextBlock>("CpuBigHeader");
            _cpuBrandText = this.FindControl<TextBlock>("CpuBrandText");
            _graphHeaderLabel = this.FindControl<TextBlock>("GraphHeaderLabel");
            _graphScaleMax = this.FindControl<TextBlock>("GraphScaleMax");
            _graphScaleTime = this.FindControl<TextBlock>("GraphScaleTime");
            _graphScaleZero = this.FindControl<TextBlock>("GraphScaleZero");
            _overallGraphBorder = this.FindControl<Border>("OverallGraphBorder");
            _overallCpuCanvas = this.FindControl<Canvas>("OverallCpuCanvas");
            _logicalCoresGrid = this.FindControl<Grid>("LogicalCoresGrid");

            _labelUtil = this.FindControl<TextBlock>("LabelUtil");
            _labelSpeed = this.FindControl<TextBlock>("LabelSpeed");
            _labelUptime = this.FindControl<TextBlock>("LabelUptime");
            _labelProcs = this.FindControl<TextBlock>("LabelProcs");
            _labelThreads = this.FindControl<TextBlock>("LabelThreads");
            _labelHandles = this.FindControl<TextBlock>("LabelHandles");

            _statUtilization = this.FindControl<TextBlock>("StatUtilization");
            _statSpeed = this.FindControl<TextBlock>("StatSpeed");
            _statUptime = this.FindControl<TextBlock>("StatUptime");
            _statProcesses = this.FindControl<TextBlock>("StatProcesses");
            _statThreads = this.FindControl<TextBlock>("StatThreads");
            _statHandles = this.FindControl<TextBlock>("StatHandles");

            _labelBaseSpeed = this.FindControl<TextBlock>("LabelBaseSpeed");
            _labelSockets = this.FindControl<TextBlock>("LabelSockets");
            _labelCores = this.FindControl<TextBlock>("LabelCores");
            _labelLogical = this.FindControl<TextBlock>("LabelLogical");
            _labelVirt = this.FindControl<TextBlock>("LabelVirt");
            _labelL1 = this.FindControl<TextBlock>("LabelL1");
            _labelL2 = this.FindControl<TextBlock>("LabelL2");
            _labelL3 = this.FindControl<TextBlock>("LabelL3");

            _metaBaseSpeed = this.FindControl<TextBlock>("MetaBaseSpeed");
            _metaSockets = this.FindControl<TextBlock>("MetaSockets");
            _metaPhysicalCores = this.FindControl<TextBlock>("MetaPhysicalCores");
            _metaLogicalCores = this.FindControl<TextBlock>("MetaLogicalCores");
            _metaVirtualization = this.FindControl<TextBlock>("MetaVirtualization");
            _metaL1 = this.FindControl<TextBlock>("MetaL1");
            _metaL2 = this.FindControl<TextBlock>("MetaL2");
            _metaL3 = this.FindControl<TextBlock>("MetaL3");

            // Memory View Binding
            _memoryView = this.FindControl<Grid>("MemoryView");
            _memBigHeader = this.FindControl<TextBlock>("MemBigHeader");
            _memTotalHeader = this.FindControl<TextBlock>("MemTotalHeader");
            _memGraphHeaderLabel = this.FindControl<TextBlock>("MemGraphHeaderLabel");
            _memGraphScaleMax = this.FindControl<TextBlock>("MemGraphScaleMax");
            _memGraphScaleTime = this.FindControl<TextBlock>("MemGraphScaleTime");
            _memGraphScaleZero = this.FindControl<TextBlock>("MemGraphScaleZero");
            _overallMemBorder = this.FindControl<Border>("OverallMemBorder");
            _overallMemCanvas = this.FindControl<Canvas>("OverallMemCanvas");
            _labelMemComposition = this.FindControl<TextBlock>("LabelMemComposition");
            _memCompositionBorder = this.FindControl<Border>("MemCompositionBorder");
            _memCompositionCanvas = this.FindControl<Canvas>("MemCompositionCanvas");

            _labelMemInUse = this.FindControl<TextBlock>("LabelMemInUse");
            _labelMemAvailable = this.FindControl<TextBlock>("LabelMemAvailable");
            _labelMemCommitted = this.FindControl<TextBlock>("LabelMemCommitted");
            _labelMemCached = this.FindControl<TextBlock>("LabelMemCached");
            _labelMemPagedPool = this.FindControl<TextBlock>("LabelMemPagedPool");
            _labelMemNonPagedPool = this.FindControl<TextBlock>("LabelMemNonPagedPool");

            _statMemInUse = this.FindControl<TextBlock>("StatMemInUse");
            _statMemAvailable = this.FindControl<TextBlock>("StatMemAvailable");
            _statMemCommitted = this.FindControl<TextBlock>("StatMemCommitted");
            _statMemCached = this.FindControl<TextBlock>("StatMemCached");
            _statMemPagedPool = this.FindControl<TextBlock>("StatMemPagedPool");
            _statMemNonPagedPool = this.FindControl<TextBlock>("StatMemNonPagedPool");

            _labelMemSpeed = this.FindControl<TextBlock>("LabelMemSpeed");
            _labelMemSlots = this.FindControl<TextBlock>("LabelMemSlots");
            _labelMemFormFactor = this.FindControl<TextBlock>("LabelMemFormFactor");
            _labelMemReserved = this.FindControl<TextBlock>("LabelMemReserved");

            _metaMemSpeed = this.FindControl<TextBlock>("MetaMemSpeed");
            _metaMemSlots = this.FindControl<TextBlock>("MetaMemSlots");
            _metaMemFormFactor = this.FindControl<TextBlock>("MetaMemFormFactor");
            _metaMemReserved = this.FindControl<TextBlock>("MetaMemReserved");

            // Disk View Binding
            _diskView = this.FindControl<Grid>("DiskView");
            _diskBigHeader = this.FindControl<TextBlock>("DiskBigHeader");
            _diskModelText = this.FindControl<TextBlock>("DiskModelText");
            _diskActiveTimeHeaderLabel = this.FindControl<TextBlock>("DiskActiveTimeHeaderLabel");
            _diskActiveTimeScaleMax = this.FindControl<TextBlock>("DiskActiveTimeScaleMax");
            _diskActiveBorder = this.FindControl<Border>("DiskActiveBorder");
            _diskActiveCanvas = this.FindControl<Canvas>("DiskActiveCanvas");
            _diskActiveScaleTime = this.FindControl<TextBlock>("DiskActiveScaleTime");
            _diskActiveScaleZero = this.FindControl<TextBlock>("DiskActiveScaleZero");

            _diskTransferHeaderLabel = this.FindControl<TextBlock>("DiskTransferHeaderLabel");
            _diskTransferScaleMax = this.FindControl<TextBlock>("DiskTransferScaleMax");
            _diskTransferBorder = this.FindControl<Border>("DiskTransferBorder");
            _diskTransferCanvas = this.FindControl<Canvas>("DiskTransferCanvas");
            _diskTransferScaleTime = this.FindControl<TextBlock>("DiskTransferScaleTime");
            _diskTransferScaleZero = this.FindControl<TextBlock>("DiskTransferScaleZero");

            _labelDiskActiveTime = this.FindControl<TextBlock>("LabelDiskActiveTime");
            _labelDiskResponseTime = this.FindControl<TextBlock>("LabelDiskResponseTime");
            _labelDiskReadSpeed = this.FindControl<TextBlock>("LabelDiskReadSpeed");
            _labelDiskWriteSpeed = this.FindControl<TextBlock>("LabelDiskWriteSpeed");

            _statDiskActiveTime = this.FindControl<TextBlock>("StatDiskActiveTime");
            _statDiskResponseTime = this.FindControl<TextBlock>("StatDiskResponseTime");
            _statDiskReadSpeed = this.FindControl<TextBlock>("StatDiskReadSpeed");
            _statDiskWriteSpeed = this.FindControl<TextBlock>("StatDiskWriteSpeed");

            _labelDiskCapacity = this.FindControl<TextBlock>("LabelDiskCapacity");
            _labelDiskFormatted = this.FindControl<TextBlock>("LabelDiskFormatted");
            _labelDiskSystemDisk = this.FindControl<TextBlock>("LabelDiskSystemDisk");
            _labelDiskPageFile = this.FindControl<TextBlock>("LabelDiskPageFile");
            _labelDiskType = this.FindControl<TextBlock>("LabelDiskType");

            _metaDiskCapacity = this.FindControl<TextBlock>("MetaDiskCapacity");
            _metaDiskFormatted = this.FindControl<TextBlock>("MetaDiskFormatted");
            _metaDiskSystemDisk = this.FindControl<TextBlock>("MetaDiskSystemDisk");
            _metaDiskPageFile = this.FindControl<TextBlock>("MetaDiskPageFile");
            _metaDiskType = this.FindControl<TextBlock>("MetaDiskType");

            _bottomFewerDetails = this.FindControl<TextBlock>("BottomFewerDetails");
            _bottomResmonText = this.FindControl<TextBlock>("BottomResmonText");
        }

        private void InitHardwareMetadata()
        {
            _logicalCoreCount = Math.Max(1, Environment.ProcessorCount);
            int physical = Math.Max(1, _logicalCoreCount / 2);
            string brand = "AMD Ryzen 7 PRO 8840HS w/ Radeon 780M Graphics";
            try
            {
                using var key = Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0");
                if (key != null)
                {
                    var nameObj = key.GetValue("ProcessorNameString");
                    if (nameObj != null) brand = nameObj.ToString()?.Trim() ?? brand;
                    var mhzObj = key.GetValue("~MHz");
                    if (mhzObj is int mhz && mhz > 500)
                    {
                        double rawGhz = mhz / 1000.0;
                        double roundedTenth = Math.Round(rawGhz, 1);
                        if (Math.Abs(rawGhz - roundedTenth) <= 0.025) _baseFreqGhz = roundedTenth;
                        else _baseFreqGhz = Math.Round(rawGhz, 2);
                    }
                }
            }
            catch { }

            try
            {
                using var gpuKey = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000");
                if (gpuKey != null)
                {
                    var desc = gpuKey.GetValue("DriverDesc")?.ToString();
                    if (!string.IsNullOrEmpty(desc))
                    {
                        _gpuName = desc.Length > 19 ? desc.Substring(0, 17) + "..." : desc;
                    }
                }
            }
            catch { }

            if (_cpuBrandText != null) _cpuBrandText.Text = brand;
            if (_metaBaseSpeed != null) _metaBaseSpeed.Text = _baseFreqGhz.ToString("F2") + " GHz";
            if (_metaSockets != null) _metaSockets.Text = "1";
            if (_metaPhysicalCores != null) _metaPhysicalCores.Text = physical.ToString();
            if (_metaLogicalCores != null) _metaLogicalCores.Text = _logicalCoreCount.ToString();
            if (_metaVirtualization != null) _metaVirtualization.Text = "Enabled";
            if (_metaL1 != null) _metaL1.Text = (_logicalCoreCount * 32).ToString() + " KB";
            if (_metaL2 != null) _metaL2.Text = (_logicalCoreCount * 512 / 1024.0).ToString("F1") + " MB";
            if (_metaL3 != null) _metaL3.Text = (Math.Max(8, physical * 2)).ToString("F1") + " MB";

            _prevCoreIdle = new long[_logicalCoreCount];
            _prevCoreTotal = new long[_logicalCoreCount];
            _prevCoreKernel = new long[_logicalCoreCount];

            for (int i = 0; i < _logicalCoreCount; i++)
            {
                _coreHistories.Add(new List<double>());
                _coreKernelHistories.Add(new List<double>());
            }

            for (int i = 0; i < 60; i++)
            {
                _overallHistory.Add(4.0);
                _overallKernelHistory.Add(1.0);
                _memHistory.Add(39.0);
                _diskHistory.Add(0.0);
                _diskTransferHistory.Add(0.0);
                _wifiHistory.Add(15.0);
                _eth1History.Add(0.0);
                _eth2History.Add(0.0);
                _gpuHistory.Add(1.0);
                for (int c = 0; c < _logicalCoreCount; c++)
                {
                    _coreHistories[c].Add(4.0);
                    _coreKernelHistories[c].Add(1.0);
                }
            }
        }

        private void InitMemoryMetadata()
        {
            double totalInstalledGb = 32.0;
            double hardwareReservedGb = 4.3;
            try
            {
                var mem = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
                if (GlobalMemoryStatusEx(ref mem))
                {
                    _latestMemTotalGb = mem.ullTotalPhys / (1024.0 * 1024.0 * 1024.0);
                    if (GetPhysicallyInstalledSystemMemory(out ulong totalKb))
                    {
                        totalInstalledGb = totalKb / (1024.0 * 1024.0);
                        hardwareReservedGb = Math.Max(0.1, (totalKb * 1024.0 - mem.ullTotalPhys) / (1024.0 * 1024.0 * 1024.0));
                    }
                    else
                    {
                        totalInstalledGb = Math.Ceiling(_latestMemTotalGb / 8.0) * 8.0;
                        hardwareReservedGb = Math.Max(0.1, totalInstalledGb - _latestMemTotalGb);
                    }
                }
            }
            catch { }

            string memHeader = $"{totalInstalledGb:F1} GB";
            if (Math.Abs(totalInstalledGb - Math.Round(totalInstalledGb)) < 0.1)
            {
                memHeader = $"{Math.Round(totalInstalledGb):F0} GB";
            }

            if (_memTotalHeader != null) _memTotalHeader.Text = memHeader;
            if (_memGraphScaleMax != null) _memGraphScaleMax.Text = $"{_latestMemTotalGb:F1} GB";
            if (_metaMemReserved != null)
            {
                _metaMemReserved.Text = hardwareReservedGb >= 1.0 
                    ? $"{hardwareReservedGb:F1} GB" 
                    : $"{Math.Round(hardwareReservedGb * 1024.0)} MB";
            }
            if (_metaMemSpeed != null) _metaMemSpeed.Text = "5600 MHz";
            if (_metaMemSlots != null) _metaMemSlots.Text = "2 of 2";
            if (_metaMemFormFactor != null) _metaMemFormFactor.Text = "SODIMM";
        }

        private void InitDiskMetadata()
        {
            string sysRoot = System.IO.Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\";
            string driveLetter = sysRoot.TrimEnd('\\');
            string diskTitle = $"Disk 0 ({driveLetter})";
            string modelName = "NVMe Samsung SSD 980 PRO 1TB";
            string capacityStr = "512 GB";
            string formattedStr = "476 GB";
            string diskType = "SSD";

            try
            {
                var di = new System.IO.DriveInfo(sysRoot);
                if (di.IsReady)
                {
                    double totalBytes = di.TotalSize;
                    double formattedGb = totalBytes / (1024.0 * 1024.0 * 1024.0);
                    formattedStr = $"{Math.Round(formattedGb):F0} GB";

                    double rawGb = Math.Round(totalBytes / 1_000_000_000.0);
                    if (rawGb >= 900) capacityStr = "1000 GB";
                    else if (rawGb >= 450) capacityStr = "512 GB";
                    else if (rawGb >= 220) capacityStr = "256 GB";
                    else capacityStr = $"{rawGb:F0} GB";
                }
            }
            catch { }

            try
            {
                using var scsiKey = Registry.LocalMachine.OpenSubKey(@"HARDWARE\DEVICEMAP\Scsi");
                if (scsiKey != null)
                {
                    foreach (var port in scsiKey.GetSubKeyNames())
                    {
                        using var portKey = scsiKey.OpenSubKey(port);
                        if (portKey == null) continue;
                        foreach (var bus in portKey.GetSubKeyNames())
                        {
                            using var busKey = portKey.OpenSubKey(bus);
                            if (busKey == null) continue;
                            foreach (var target in busKey.GetSubKeyNames())
                            {
                                using var targetKey = busKey.OpenSubKey(target);
                                if (targetKey == null) continue;
                                foreach (var lun in targetKey.GetSubKeyNames())
                                {
                                    using var lunKey = targetKey.OpenSubKey(lun);
                                    var idObj = lunKey?.GetValue("Identifier");
                                    if (idObj != null && !string.IsNullOrWhiteSpace(idObj.ToString()))
                                    {
                                        string foundModel = idObj.ToString()!.Trim();
                                        if (foundModel.Length > 2)
                                        {
                                            modelName = foundModel;
                                            break;
                                        }
                                    }
                                }
                                if (modelName != "NVMe Samsung SSD 980 PRO 1TB") break;
                            }
                            if (modelName != "NVMe Samsung SSD 980 PRO 1TB") break;
                        }
                        if (modelName != "NVMe Samsung SSD 980 PRO 1TB") break;
                    }
                }
            }
            catch { }

            if (_diskBigHeader != null) _diskBigHeader.Text = diskTitle;
            if (_miniDiskHeading != null) _miniDiskHeading.Text = diskTitle;
            if (_diskModelText != null) _diskModelText.Text = modelName;
            if (_metaDiskCapacity != null) _metaDiskCapacity.Text = capacityStr;
            if (_metaDiskFormatted != null) _metaDiskFormatted.Text = formattedStr;
            if (_metaDiskSystemDisk != null) _metaDiskSystemDisk.Text = "Yes";
            if (_metaDiskPageFile != null) _metaDiskPageFile.Text = "Yes";
            if (_metaDiskType != null) _metaDiskType.Text = diskType;
        }

        private void InitPdhFrequencyCounter()
        {
            try
            {
                int res = PdhOpenQuery(null, IntPtr.Zero, out _hPdhQuery);
                if (res == 0)
                {
                    int resCounter = PdhAddEnglishCounterW(_hPdhQuery, @"\Processor Information(_Total)\% Processor Performance", IntPtr.Zero, out _hPdhCounter);
                    if (resCounter != 0)
                    {
                        resCounter = PdhAddEnglishCounterW(_hPdhQuery, @"\Processor Information(0,_Total)\% Processor Performance", IntPtr.Zero, out _hPdhCounter);
                    }
                    if (resCounter != 0)
                    {
                        PdhAddEnglishCounterW(_hPdhQuery, @"\Processor Information(0,0)\% Processor Performance", IntPtr.Zero, out _hPdhCounter);
                    }
                    PdhCollectQueryData(_hPdhQuery);
                }
            }
            catch { }
        }

        private void InitPdhDiskCounters()
        {
            if (_hPdhQuery == IntPtr.Zero) return;
            try
            {
                int res = PdhAddEnglishCounterW(_hPdhQuery, @"\PhysicalDisk(_Total)\% Disk Time", IntPtr.Zero, out _hPdhDiskTimeCounter);
                if (res != 0) PdhAddEnglishCounterW(_hPdhQuery, @"\PhysicalDisk(0 C:)\% Disk Time", IntPtr.Zero, out _hPdhDiskTimeCounter);

                res = PdhAddEnglishCounterW(_hPdhQuery, @"\PhysicalDisk(_Total)\Avg. Disk sec/Transfer", IntPtr.Zero, out _hPdhDiskResponseCounter);
                if (res != 0) PdhAddEnglishCounterW(_hPdhQuery, @"\PhysicalDisk(0 C:)\Avg. Disk sec/Transfer", IntPtr.Zero, out _hPdhDiskResponseCounter);

                res = PdhAddEnglishCounterW(_hPdhQuery, @"\PhysicalDisk(_Total)\Disk Read Bytes/sec", IntPtr.Zero, out _hPdhDiskReadCounter);
                if (res != 0) PdhAddEnglishCounterW(_hPdhQuery, @"\PhysicalDisk(0 C:)\Disk Read Bytes/sec", IntPtr.Zero, out _hPdhDiskReadCounter);

                res = PdhAddEnglishCounterW(_hPdhQuery, @"\PhysicalDisk(_Total)\Disk Write Bytes/sec", IntPtr.Zero, out _hPdhDiskWriteCounter);
                if (res != 0) PdhAddEnglishCounterW(_hPdhQuery, @"\PhysicalDisk(0 C:)\Disk Write Bytes/sec", IntPtr.Zero, out _hPdhDiskWriteCounter);

                res = PdhAddEnglishCounterW(_hPdhQuery, @"\PhysicalDisk(_Total)\Disk Bytes/sec", IntPtr.Zero, out _hPdhDiskTransferCounter);
                if (res != 0) PdhAddEnglishCounterW(_hPdhQuery, @"\PhysicalDisk(0 C:)\Disk Bytes/sec", IntPtr.Zero, out _hPdhDiskTransferCounter);
            }
            catch { }
        }

        private void InitLogicalGraphs()
        {
            if (_logicalCoresGrid == null) return;
            int count = _logicalCoreCount;
            int cols = 4;
            int rows = 4;
            if (count <= 2) { cols = count; rows = 1; }
            else if (count <= 4) { cols = 2; rows = 2; }
            else if (count <= 8) { cols = 4; rows = 2; }
            else if (count <= 12) { cols = 4; rows = 3; }
            else if (count <= 16) { cols = 4; rows = 4; }
            else if (count <= 24) { cols = 6; rows = 4; }
            else if (count <= 32) { cols = 8; rows = 4; }
            else { cols = 8; rows = (int)Math.Ceiling((double)count / cols); }

            _logicalCoresGrid.RowDefinitions.Clear();
            _logicalCoresGrid.ColumnDefinitions.Clear();
            for (int r = 0; r < rows; r++) _logicalCoresGrid.RowDefinitions.Add(new RowDefinition(1, GridUnitType.Star));
            for (int c = 0; c < cols; c++) _logicalCoresGrid.ColumnDefinitions.Add(new ColumnDefinition(1, GridUnitType.Star));

            _logicalCoresGrid.Children.Clear();
            _coreCanvases.Clear();
            _coreCards.Clear();

            for (int i = 0; i < count; i++)
            {
                int r = i / cols;
                int c = i % cols;
                var card = new Border
                {
                    BorderThickness = new Thickness(1),
                    Margin = new Thickness(2),
                    Background = new SolidColorBrush(_isDark ? Color.Parse("#191919") : Color.Parse("#FFFFFF")),
                    BorderBrush = new SolidColorBrush(_isDark ? Color.Parse("#2A5A84") : Color.Parse("#70A5CC"))
                };
                ToolTip.SetTip(card, "CPU " + i);
                Grid.SetRow(card, r);
                Grid.SetColumn(card, c);

                var cvs = new Canvas { ClipToBounds = true };
                card.Child = cvs;
                _coreCanvases.Add(cvs);
                _coreCards.Add(card);
                _logicalCoresGrid.Children.Add(card);
            }
        }

        private ContextMenu CreateCpuContextMenu()
        {
            var menu = new ContextMenu();
            var changeItem = new MenuItem { Header = "Change graph to" };
            var overallOpt = new MenuItem { Header = "Overall utilization" };
            var logicalOpt = new MenuItem { Header = "Logical processors" };
            overallOpt.Click += (s, e) => SwitchGraphView(false);
            logicalOpt.Click += (s, e) => SwitchGraphView(true);
            changeItem.Items.Add(overallOpt);
            changeItem.Items.Add(logicalOpt);
            menu.Items.Add(changeItem);

            var kernelOpt = new MenuItem { Header = "Show kernel times" };
            kernelOpt.Click += (s, e) => { _showKernelTimes = !_showKernelTimes; RedrawAllCharts(); };
            menu.Items.Add(kernelOpt);

            var copyOpt = new MenuItem { Header = "Copy" };
            copyOpt.Click += (s, e) => CopyCpuStatsToClipboard();
            menu.Items.Add(copyOpt);

            return menu;
        }

        private ContextMenu CreateMemoryContextMenu()
        {
            var menu = new ContextMenu();
            var copyOpt = new MenuItem { Header = "Copy" };
            copyOpt.Click += (s, e) => CopyMemoryStatsToClipboard();
            menu.Items.Add(copyOpt);
            return menu;
        }

        private ContextMenu CreateDiskContextMenu()
        {
            var menu = new ContextMenu();
            var copyOpt = new MenuItem { Header = "Copy" };
            copyOpt.Click += (s, e) => CopyDiskStatsToClipboard();
            menu.Items.Add(copyOpt);
            return menu;
        }

        private void SetupGraphContextMenus()
        {
            var m1 = CreateCpuContextMenu();
            if (_logicalCoresGrid != null) _logicalCoresGrid.ContextMenu = m1;
            var m2 = CreateCpuContextMenu();
            if (_overallGraphBorder != null) _overallGraphBorder.ContextMenu = m2;

            var memMenu = CreateMemoryContextMenu();
            if (_overallMemBorder != null) _overallMemBorder.ContextMenu = memMenu;

            var diskMenu = CreateDiskContextMenu();
            if (_diskActiveBorder != null) _diskActiveBorder.ContextMenu = diskMenu;
            if (_diskTransferBorder != null) _diskTransferBorder.ContextMenu = diskMenu;
        }

        private async void CopyCpuStatsToClipboard()
        {
            try
            {
                string info = $"CPU\r\n\r\n{_cpuBrandText?.Text}\r\n\r\n" +
                              $"Base speed:\t{_metaBaseSpeed?.Text}\r\n" +
                              $"Sockets:\t{_metaSockets?.Text}\r\n" +
                              $"Cores:\t{_metaPhysicalCores?.Text}\r\n" +
                              $"Logical processors:\t{_metaLogicalCores?.Text}\r\n" +
                              $"Virtualization:\t{_metaVirtualization?.Text}\r\n" +
                              $"L1 cache:\t{_metaL1?.Text}\r\n" +
                              $"L2 cache:\t{_metaL2?.Text}\r\n" +
                              $"L3 cache:\t{_metaL3?.Text}\r\n\r\n" +
                              $"Utilization\t{_statUtilization?.Text}\r\n" +
                              $"Speed\t{_statSpeed?.Text}\r\n" +
                              $"Up time\t{_statUptime?.Text}\r\n" +
                              $"Processes\t{_statProcesses?.Text}\r\n" +
                              $"Threads\t{_statThreads?.Text}\r\n" +
                              $"Handles\t{_statHandles?.Text}";

                var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
                if (clipboard != null) await clipboard.SetTextAsync(info);
            }
            catch { }
        }

        private async void CopyMemoryStatsToClipboard()
        {
            try
            {
                string info = $"Memory\r\n\r\n{_memTotalHeader?.Text}\r\n\r\n" +
                              $"Speed:\t{_metaMemSpeed?.Text}\r\n" +
                              $"Slots used:\t{_metaMemSlots?.Text}\r\n" +
                              $"Form factor:\t{_metaMemFormFactor?.Text}\r\n" +
                              $"Hardware reserved:\t{_metaMemReserved?.Text}\r\n\r\n" +
                              $"Available\t{_statMemAvailable?.Text}\r\n" +
                              $"Cached\t{_statMemCached?.Text}\r\n" +
                              $"Committed\t{_statMemCommitted?.Text}\r\n" +
                              $"Total\t{_latestMemTotalGb:F1} GB\r\n" +
                              $"In use\t{_statMemInUse?.Text}\r\n" +
                              $"Paged pool\t{_statMemPagedPool?.Text}\r\n" +
                              $"Non-paged pool\t{_statMemNonPagedPool?.Text}";

                var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
                if (clipboard != null) await clipboard.SetTextAsync(info);
            }
            catch { }
        }

        private async void CopyDiskStatsToClipboard()
        {
            try
            {
                string info = $"{_diskBigHeader?.Text}\r\n\r\n{_diskModelText?.Text}\r\n\r\n" +
                              $"Capacity:\t{_metaDiskCapacity?.Text}\r\n" +
                              $"Formatted:\t{_metaDiskFormatted?.Text}\r\n" +
                              $"System disk:\t{_metaDiskSystemDisk?.Text}\r\n" +
                              $"Page file:\t{_metaDiskPageFile?.Text}\r\n" +
                              $"Type:\t{_metaDiskType?.Text}\r\n\r\n" +
                              $"Active time\t{_statDiskActiveTime?.Text}\r\n" +
                              $"Average response time\t{_statDiskResponseTime?.Text}\r\n" +
                              $"Read speed\t{_statDiskReadSpeed?.Text}\r\n" +
                              $"Write speed\t{_statDiskWriteSpeed?.Text}";

                var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
                if (clipboard != null) await clipboard.SetTextAsync(info);
            }
            catch { }
        }

        private void SetActivePanel(PerformancePanel panel)
        {
            if (!_isInitialized) return;
            _activePanel = panel;

            if (_cpuView != null) _cpuView.IsVisible = (panel == PerformancePanel.Cpu);
            if (_memoryView != null) _memoryView.IsVisible = (panel == PerformancePanel.Memory);
            if (_diskView != null) _diskView.IsVisible = (panel == PerformancePanel.Disk);
            if (_networkView != null) _networkView.IsVisible = (panel == PerformancePanel.Network);
            if (_gpuView != null) _gpuView.IsVisible = (panel == PerformancePanel.Gpu);
            if (_menuChangeGraphRoot != null) _menuChangeGraphRoot.IsEnabled = (panel == PerformancePanel.Cpu);

            var selTileBg = new SolidColorBrush(_isDark ? Color.Parse("#2B3844") : Color.Parse("#E5F1FB"));
            var selTileBorder = new SolidColorBrush(_isDark ? Color.Parse("#4CC2FF") : Color.Parse("#70C0E7"));
            var trans = Brushes.Transparent;

            if (_cpuTileBorder != null)
            {
                _cpuTileBorder.Background = (panel == PerformancePanel.Cpu) ? selTileBg : trans;
                _cpuTileBorder.BorderBrush = (panel == PerformancePanel.Cpu) ? selTileBorder : trans;
            }
            if (_memTileBorder != null)
            {
                _memTileBorder.Background = (panel == PerformancePanel.Memory) ? selTileBg : trans;
                _memTileBorder.BorderBrush = (panel == PerformancePanel.Memory) ? selTileBorder : trans;
            }
            if (_diskTileBorder != null)
            {
                _diskTileBorder.Background = (panel == PerformancePanel.Disk) ? selTileBg : trans;
                _diskTileBorder.BorderBrush = (panel == PerformancePanel.Disk) ? selTileBorder : trans;
            }
            HighlightNetGpuTiles(null, false);

            RedrawAllCharts();
        }

        private void OnCpuTileClick(object? sender, PointerPressedEventArgs e) => SetActivePanel(PerformancePanel.Cpu);
        private void OnMemTileClick(object? sender, PointerPressedEventArgs e) => SetActivePanel(PerformancePanel.Memory);
        private void OnDiskTileClick(object? sender, PointerPressedEventArgs e) => SetActivePanel(PerformancePanel.Disk);

        private void SwitchGraphView(bool logical)
        {
            if (!_isInitialized) return;
            _isLogicalView = logical;
            if (_logicalCoresGrid != null) _logicalCoresGrid.IsVisible = logical;
            if (_overallGraphBorder != null) _overallGraphBorder.IsVisible = !logical;
            UpdateGraphHeaderAndScale();
            Dispatcher.UIThread.Post(() => RedrawAllCharts(), DispatcherPriority.Render);
        }

        private void UpdateGraphHeaderAndScale()
        {
            string timeText = _updateIntervalSec == 4 ? "4 minutes" : "60 seconds";
            if (_graphHeaderLabel != null)
            {
                _graphHeaderLabel.Text = _isLogicalView 
                    ? $"% Utilization over {timeText}" 
                    : "% Utilization";
            }
            bool showBottomScale = !_isLogicalView;
            if (_graphScaleTime != null)
            {
                _graphScaleTime.Text = timeText;
                _graphScaleTime.IsVisible = showBottomScale;
            }
            if (_graphScaleZero != null)
            {
                _graphScaleZero.IsVisible = showBottomScale;
            }

            if (_memGraphScaleTime != null) _memGraphScaleTime.Text = timeText;
            if (_diskActiveScaleTime != null) _diskActiveScaleTime.Text = timeText;
            if (_diskTransferScaleTime != null) _diskTransferScaleTime.Text = timeText;
        }

        private void RedrawAllCharts()
        {
            Color cpuLineColor = _isDark ? Color.Parse("#4CC2FF") : Color.Parse("#1070B8");
            Color cpuFillColor = _isDark ? Color.FromArgb(0x25, 0x4C, 0xC2, 0xFF) : Color.FromArgb(0x1F, 0x10, 0x70, 0xB8);

            Color memLineColor = _isDark ? Color.Parse("#B45AC7") : Color.Parse("#762A83");
            Color memFillColor = _isDark ? Color.FromArgb(0x25, 0xB4, 0x5A, 0xC7) : Color.FromArgb(0x1F, 0x76, 0x2A, 0x83);

            Color diskLineColor = _isDark ? Color.Parse("#76C437") : Color.Parse("#4E7A27");
            Color diskFillColor = _isDark ? Color.FromArgb(0x25, 0x76, 0xC4, 0x37) : Color.FromArgb(0x1F, 0x4E, 0x7A, 0x27);

            DrawChart(_miniCpuCanvas, _overallHistory, null, cpuLineColor, cpuFillColor, isMini: true);
            DrawChart(_miniMemCanvas, _memHistory, null, memLineColor, memFillColor, isMini: true);
            DrawChart(_miniDiskCanvas, _diskHistory, null, diskLineColor, diskFillColor, isMini: true);
            DrawChart(_miniWifiCanvas, _wifiHistory, null, Color.Parse("#D08836"), Color.FromArgb(0x1F, 0x8E, 0x5A, 0x23), isMini: true);
            DrawChart(_miniEth1Canvas, _eth1History, null, Color.Parse("#D08836"), Color.FromArgb(0x1F, 0x8E, 0x5A, 0x23), isMini: true);
            DrawChart(_miniEth2Canvas, _eth2History, null, Color.Parse("#D08836"), Color.FromArgb(0x1F, 0x8E, 0x5A, 0x23), isMini: true);
            DrawChart(_miniGpuCanvas, _gpuHistory, null, cpuLineColor, cpuFillColor, isMini: true);

            if (_activePanel == PerformancePanel.Cpu)
            {
                for (int i = 0; i < _coreCanvases.Count; i++)
                {
                    var kHist = _showKernelTimes ? _coreKernelHistories[i] : null;
                    DrawChart(_coreCanvases[i], _coreHistories[i], kHist, cpuLineColor, cpuFillColor, isMini: false);
                }
                var overallKHist = _showKernelTimes ? _overallKernelHistory : null;
                DrawChart(_overallCpuCanvas, _overallHistory, overallKHist, cpuLineColor, cpuFillColor, isMini: false);
            }
            else if (_activePanel == PerformancePanel.Memory)
            {
                DrawChart(_overallMemCanvas, _memHistory, null, memLineColor, memFillColor, isMini: false, isMemory: true);
                DrawMemoryCompositionBar(_memCompositionCanvas);
            }
            else if (_activePanel == PerformancePanel.Disk)
            {
                DrawChart(_diskActiveCanvas, _diskHistory, null, diskLineColor, diskFillColor, isMini: false, isDisk: true);

                var (maxBytes, scaleLabel) = GetTransferScale(_latestPeakTransferRate);
                if (_diskTransferScaleMax != null) _diskTransferScaleMax.Text = scaleLabel;

                var normTransfer = new List<double>();
                foreach (var b in _diskTransferHistory)
                {
                    normTransfer.Add(Math.Clamp((b / maxBytes) * 100.0, 0.0, 100.0));
                }
                DrawChart(_diskTransferCanvas, normTransfer, null, diskLineColor, diskFillColor, isMini: false, isDisk: true);
            }
            else if (_activePanel == PerformancePanel.Network)
            {
                RedrawNetworkCharts();
            }
            else if (_activePanel == PerformancePanel.Gpu)
            {
                RedrawGpuCharts();
            }
        }

        private static (double maxBytes, string label) GetTransferScale(double peakBytesPerSec)
        {
            double[] thresholds = {
                100 * 1024.0,
                500 * 1024.0,
                1 * 1024.0 * 1024.0,
                5 * 1024.0 * 1024.0,
                10 * 1024.0 * 1024.0,
                20 * 1024.0 * 1024.0,
                50 * 1024.0 * 1024.0,
                100 * 1024.0 * 1024.0,
                250 * 1024.0 * 1024.0,
                500 * 1024.0 * 1024.0,
                1024.0 * 1024.0 * 1024.0
            };
            string[] labels = {
                "100 KB/s",
                "500 KB/s",
                "1.0 MB/s",
                "5.0 MB/s",
                "10 MB/s",
                "20 MB/s",
                "50 MB/s",
                "100 MB/s",
                "250 MB/s",
                "500 MB/s",
                "1.0 GB/s"
            };

            for (int i = 0; i < thresholds.Length; i++)
            {
                if (peakBytesPerSec <= thresholds[i])
                    return (thresholds[i], labels[i]);
            }

            double gbScale = Math.Ceiling(peakBytesPerSec / (1024.0 * 1024.0 * 1024.0));
            return (gbScale * 1024.0 * 1024.0 * 1024.0, $"{gbScale:F0} GB/s");
        }

        private static string FormatTransferRate(double bytesPerSec)
        {
            if (bytesPerSec < 1024.0) return $"{Math.Round(bytesPerSec)} B/s";
            if (bytesPerSec < 1024.0 * 1024.0) return $"{bytesPerSec / 1024.0:F1} KB/s";
            if (bytesPerSec < 1024.0 * 1024.0 * 1024.0) return $"{bytesPerSec / (1024.0 * 1024.0):F1} MB/s";
            return $"{bytesPerSec / (1024.0 * 1024.0 * 1024.0):F2} GB/s";
        }

        private void DrawMemoryCompositionBar(Canvas? canvas)
        {
            if (canvas == null) return;
            canvas.Children.Clear();
            double w = canvas.Bounds.Width;
            double h = canvas.Bounds.Height;
            if (double.IsNaN(w) || w <= 4) w = 500;
            if (double.IsNaN(h) || h <= 4) h = 16;

            double total = Math.Max(0.1, _latestMemTotalGb);
            double inUseRatio = Math.Clamp(_latestMemInUseGb / total, 0.0, 1.0);
            double modRatio = Math.Clamp(_latestMemModifiedGb / total, 0.0, 1.0);
            double standbyRatio = Math.Clamp(_latestMemStandbyGb / total, 0.0, 1.0);

            var inUseBrush = new SolidColorBrush(_isDark ? Color.Parse("#8E3B9E") : Color.Parse("#762A83"));
            var modBrush = new SolidColorBrush(_isDark ? Color.Parse("#B357C4") : Color.Parse("#9C47AC"));
            var standbyBrush = new SolidColorBrush(_isDark ? Color.Parse("#3A6890") : Color.Parse("#6EA8D9"));
            var freeBrush = new SolidColorBrush(_isDark ? Color.Parse("#2B2B2B") : Color.Parse("#E0E0E0"));

            double wInUse = Math.Round(w * inUseRatio);
            double wMod = Math.Round(w * modRatio);
            double wStandby = Math.Round(w * standbyRatio);
            double wFree = Math.Max(0, w - (wInUse + wMod + wStandby));

            double curX = 0;
            if (wInUse > 0)
            {
                var r = new Rectangle { Width = wInUse, Height = h, Fill = inUseBrush };
                Canvas.SetLeft(r, curX);
                canvas.Children.Add(r);
                curX += wInUse;
            }
            if (wMod > 0)
            {
                var r = new Rectangle { Width = wMod, Height = h, Fill = modBrush };
                Canvas.SetLeft(r, curX);
                canvas.Children.Add(r);
                curX += wMod;
            }
            if (wStandby > 0)
            {
                var r = new Rectangle { Width = wStandby, Height = h, Fill = standbyBrush };
                Canvas.SetLeft(r, curX);
                canvas.Children.Add(r);
                curX += wStandby;
            }
            if (wFree > 0)
            {
                var r = new Rectangle { Width = wFree, Height = h, Fill = freeBrush };
                Canvas.SetLeft(r, curX);
                canvas.Children.Add(r);
            }
        }

        private void ApplyThemeColors()
        {
            if (Application.Current != null)
            {
                Application.Current.RequestedThemeVariant = _isDark ? Avalonia.Styling.ThemeVariant.Dark : Avalonia.Styling.ThemeVariant.Light;
            }

            var mainBg = new SolidColorBrush(_isDark ? Color.Parse("#191919") : Color.Parse("#FFFFFF"));
            var subBg = new SolidColorBrush(_isDark ? Color.Parse("#1F1F1F") : Color.Parse("#FBFBFB"));
            var borderLine = new SolidColorBrush(_isDark ? Color.Parse("#2C2C2C") : Color.Parse("#E5E5E5"));
            var textHigh = new SolidColorBrush(_isDark ? Color.Parse("#FFFFFF") : Color.Parse("#000000"));
            var textMid = new SolidColorBrush(_isDark ? Color.Parse("#A0A0A0") : Color.Parse("#555555"));
            var cpuColor = new SolidColorBrush(_isDark ? Color.Parse("#4CC2FF") : Color.Parse("#1070B8"));

            if (_rootGrid != null) _rootGrid.Background = mainBg;
            if (_menuBarBorder != null) { _menuBarBorder.Background = mainBg; _menuBarBorder.BorderBrush = borderLine; }
            if (_tabBarBorder != null) { _tabBarBorder.Background = mainBg; _tabBarBorder.BorderBrush = borderLine; }
            if (_sidebarBorder != null) { _sidebarBorder.Background = subBg; _sidebarBorder.BorderBrush = borderLine; }
            if (_bottomBarBorder != null) { _bottomBarBorder.Background = new SolidColorBrush(_isDark ? Color.Parse("#1F1F1F") : Color.Parse("#FFFFFF")); _bottomBarBorder.BorderBrush = borderLine; }

            if (_mainMenu != null) _mainMenu.Foreground = textHigh;
            if (_menuFile != null) _menuFile.Foreground = textHigh;
            if (_menuOptions != null) _menuOptions.Foreground = textHigh;
            if (_menuView != null) _menuView.Foreground = textHigh;

            if (_menuDarkMode != null)
            {
                _menuDarkMode.Header = _isDark ? "\u2713 Dark mode" : "Dark mode";
            }

            if (_tabPerfBorder != null)
            {
                _tabPerfBorder.Background = mainBg;
                _tabPerfBorder.BorderBrush = new SolidColorBrush(_isDark ? Color.Parse("#383838") : Color.Parse("#D9D9D9"));
            }

            if (_tabProcesses != null) _tabProcesses.Foreground = textMid;
            if (_tabPerformance != null) _tabPerformance.Foreground = textHigh;
            if (_tabAppHistory != null) _tabAppHistory.Foreground = textMid;
            if (_tabStartup != null) _tabStartup.Foreground = textMid;
            if (_tabUsers != null) _tabUsers.Foreground = textMid;
            if (_tabDetails != null) _tabDetails.Foreground = textMid;
            if (_tabServices != null) _tabServices.Foreground = textMid;

            var selTileBg = new SolidColorBrush(_isDark ? Color.Parse("#2B3844") : Color.Parse("#E5F1FB"));
            var selTileBorder = new SolidColorBrush(_isDark ? Color.Parse("#4CC2FF") : Color.Parse("#70C0E7"));
            
            if (_cpuTileBorder != null)
            {
                _cpuTileBorder.Background = (_activePanel == PerformancePanel.Cpu) ? selTileBg : Brushes.Transparent;
                _cpuTileBorder.BorderBrush = (_activePanel == PerformancePanel.Cpu) ? selTileBorder : Brushes.Transparent;
            }
            if (_memTileBorder != null)
            {
                _memTileBorder.Background = (_activePanel == PerformancePanel.Memory) ? selTileBg : Brushes.Transparent;
                _memTileBorder.BorderBrush = (_activePanel == PerformancePanel.Memory) ? selTileBorder : Brushes.Transparent;
            }
            if (_diskTileBorder != null)
            {
                _diskTileBorder.Background = (_activePanel == PerformancePanel.Disk) ? selTileBg : Brushes.Transparent;
                _diskTileBorder.BorderBrush = (_activePanel == PerformancePanel.Disk) ? selTileBorder : Brushes.Transparent;
            }

            var miniBoxBg = new SolidColorBrush(_isDark ? Color.Parse("#191919") : Color.Parse("#FFFFFF"));
            if (_miniCpuBox != null) { _miniCpuBox.Background = miniBoxBg; _miniCpuBox.BorderBrush = new SolidColorBrush(_isDark ? Color.Parse("#2A5A84") : Color.Parse("#70A5CC")); }
            if (_miniMemBox != null) { _miniMemBox.Background = miniBoxBg; _miniMemBox.BorderBrush = new SolidColorBrush(_isDark ? Color.Parse("#8E3B9E") : Color.Parse("#762A83")); }
            if (_miniDiskBox != null) { _miniDiskBox.Background = miniBoxBg; _miniDiskBox.BorderBrush = new SolidColorBrush(_isDark ? Color.Parse("#5E9130") : Color.Parse("#4E7A27")); }
            if (_miniWifiBox != null) { _miniWifiBox.Background = miniBoxBg; _miniWifiBox.BorderBrush = new SolidColorBrush(_isDark ? Color.Parse("#A86C2B") : Color.Parse("#8E5A23")); }
            if (_miniEth1Box != null) { _miniEth1Box.Background = miniBoxBg; _miniEth1Box.BorderBrush = new SolidColorBrush(_isDark ? Color.Parse("#A86C2B") : Color.Parse("#8E5A23")); }
            if (_miniEth2Box != null) { _miniEth2Box.Background = miniBoxBg; _miniEth2Box.BorderBrush = new SolidColorBrush(_isDark ? Color.Parse("#A86C2B") : Color.Parse("#8E5A23")); }
            if (_miniGpuBox != null) { _miniGpuBox.Background = miniBoxBg; _miniGpuBox.BorderBrush = new SolidColorBrush(_isDark ? Color.Parse("#2A5A84") : Color.Parse("#70A5CC")); }

            if (_miniCpuHeading != null) _miniCpuHeading.Foreground = textHigh;
            if (_miniCpuText != null) _miniCpuText.Foreground = textMid;
            if (_miniMemHeading != null) _miniMemHeading.Foreground = textHigh;
            if (_miniMemText != null) _miniMemText.Foreground = textMid;
            if (_miniDiskHeading != null) _miniDiskHeading.Foreground = textHigh;
            if (_miniDiskText != null) _miniDiskText.Foreground = textMid;
            if (_miniWifiHeading != null) _miniWifiHeading.Foreground = textHigh;
            if (_miniWifiText != null) _miniWifiText.Foreground = textMid;
            if (_miniEth1Heading != null) _miniEth1Heading.Foreground = textHigh;
            if (_miniEth1Text != null) _miniEth1Text.Foreground = textMid;
            if (_miniEth2Heading != null) _miniEth2Heading.Foreground = textHigh;
            if (_miniEth2Text != null) _miniEth2Text.Foreground = textMid;
            if (_miniGpuHeading != null) _miniGpuHeading.Foreground = textHigh;
            if (_miniGpuText != null) _miniGpuText.Foreground = textMid;

            var cpuGraphBorderColor = new SolidColorBrush(_isDark ? Color.Parse("#2A5A84") : Color.Parse("#70A5CC"));
            if (_overallGraphBorder != null)
            {
                _overallGraphBorder.Background = mainBg;
                _overallGraphBorder.BorderBrush = cpuGraphBorderColor;
            }
            foreach (var card in _coreCards)
            {
                card.Background = mainBg;
                card.BorderBrush = cpuGraphBorderColor;
            }

            var memGraphBorderColor = new SolidColorBrush(_isDark ? Color.Parse("#8E3B9E") : Color.Parse("#762A83"));
            if (_overallMemBorder != null)
            {
                _overallMemBorder.Background = mainBg;
                _overallMemBorder.BorderBrush = memGraphBorderColor;
            }
            if (_memCompositionBorder != null)
            {
                _memCompositionBorder.BorderBrush = memGraphBorderColor;
            }

            var diskGraphBorderColor = new SolidColorBrush(_isDark ? Color.Parse("#4E7A27") : Color.Parse("#6BA832"));
            if (_diskActiveBorder != null)
            {
                _diskActiveBorder.Background = mainBg;
                _diskActiveBorder.BorderBrush = diskGraphBorderColor;
            }
            if (_diskTransferBorder != null)
            {
                _diskTransferBorder.Background = mainBg;
                _diskTransferBorder.BorderBrush = diskGraphBorderColor;
            }

            if (_cpuBigHeader != null) _cpuBigHeader.Foreground = textHigh;
            if (_cpuBrandText != null) _cpuBrandText.Foreground = textMid;
            if (_graphHeaderLabel != null) _graphHeaderLabel.Foreground = textMid;
            if (_graphScaleMax != null) _graphScaleMax.Foreground = textMid;
            if (_graphScaleTime != null) _graphScaleTime.Foreground = textMid;
            if (_graphScaleZero != null) _graphScaleZero.Foreground = textMid;

            if (_labelUtil != null) _labelUtil.Foreground = textMid;
            if (_labelSpeed != null) _labelSpeed.Foreground = textMid;
            if (_labelUptime != null) _labelUptime.Foreground = textMid;
            if (_labelProcs != null) _labelProcs.Foreground = textMid;
            if (_labelThreads != null) _labelThreads.Foreground = textMid;
            if (_labelHandles != null) _labelHandles.Foreground = textMid;

            if (_statUtilization != null) _statUtilization.Foreground = textHigh;
            if (_statSpeed != null) _statSpeed.Foreground = textHigh;
            if (_statUptime != null) _statUptime.Foreground = textHigh;
            if (_statProcesses != null) _statProcesses.Foreground = textHigh;
            if (_statThreads != null) _statThreads.Foreground = textHigh;
            if (_statHandles != null) _statHandles.Foreground = textHigh;

            if (_labelBaseSpeed != null) _labelBaseSpeed.Foreground = textMid;
            if (_labelSockets != null) _labelSockets.Foreground = textMid;
            if (_labelCores != null) _labelCores.Foreground = textMid;
            if (_labelLogical != null) _labelLogical.Foreground = textMid;
            if (_labelVirt != null) _labelVirt.Foreground = textMid;
            if (_labelL1 != null) _labelL1.Foreground = textMid;
            if (_labelL2 != null) _labelL2.Foreground = textMid;
            if (_labelL3 != null) _labelL3.Foreground = textMid;

            if (_metaBaseSpeed != null) _metaBaseSpeed.Foreground = textHigh;
            if (_metaSockets != null) _metaSockets.Foreground = textHigh;
            if (_metaPhysicalCores != null) _metaPhysicalCores.Foreground = textHigh;
            if (_metaLogicalCores != null) _metaLogicalCores.Foreground = textHigh;
            if (_metaVirtualization != null) _metaVirtualization.Foreground = textHigh;
            if (_metaL1 != null) _metaL1.Foreground = textHigh;
            if (_metaL2 != null) _metaL2.Foreground = textHigh;
            if (_metaL3 != null) _metaL3.Foreground = textHigh;

            // Memory Text Colors
            if (_memBigHeader != null) _memBigHeader.Foreground = textHigh;
            if (_memTotalHeader != null) _memTotalHeader.Foreground = textMid;
            if (_memGraphHeaderLabel != null) _memGraphHeaderLabel.Foreground = textMid;
            if (_memGraphScaleMax != null) _memGraphScaleMax.Foreground = textMid;
            if (_memGraphScaleTime != null) _memGraphScaleTime.Foreground = textMid;
            if (_memGraphScaleZero != null) _memGraphScaleZero.Foreground = textMid;
            if (_labelMemComposition != null) _labelMemComposition.Foreground = textMid;

            if (_labelMemInUse != null) _labelMemInUse.Foreground = textMid;
            if (_labelMemAvailable != null) _labelMemAvailable.Foreground = textMid;
            if (_labelMemCommitted != null) _labelMemCommitted.Foreground = textMid;
            if (_labelMemCached != null) _labelMemCached.Foreground = textMid;
            if (_labelMemPagedPool != null) _labelMemPagedPool.Foreground = textMid;
            if (_labelMemNonPagedPool != null) _labelMemNonPagedPool.Foreground = textMid;

            if (_statMemInUse != null) _statMemInUse.Foreground = textHigh;
            if (_statMemAvailable != null) _statMemAvailable.Foreground = textHigh;
            if (_statMemCommitted != null) _statMemCommitted.Foreground = textHigh;
            if (_statMemCached != null) _statMemCached.Foreground = textHigh;
            if (_statMemPagedPool != null) _statMemPagedPool.Foreground = textHigh;
            if (_statMemNonPagedPool != null) _statMemNonPagedPool.Foreground = textHigh;

            if (_labelMemSpeed != null) _labelMemSpeed.Foreground = textMid;
            if (_labelMemSlots != null) _labelMemSlots.Foreground = textMid;
            if (_labelMemFormFactor != null) _labelMemFormFactor.Foreground = textMid;
            if (_labelMemReserved != null) _labelMemReserved.Foreground = textMid;

            if (_metaMemSpeed != null) _metaMemSpeed.Foreground = textHigh;
            if (_metaMemSlots != null) _metaMemSlots.Foreground = textHigh;
            if (_metaMemFormFactor != null) _metaMemFormFactor.Foreground = textHigh;
            if (_metaMemReserved != null) _metaMemReserved.Foreground = textHigh;

            // Disk Text Colors
            if (_diskBigHeader != null) _diskBigHeader.Foreground = textHigh;
            if (_diskModelText != null) _diskModelText.Foreground = textMid;
            if (_diskActiveTimeHeaderLabel != null) _diskActiveTimeHeaderLabel.Foreground = textMid;
            if (_diskActiveTimeScaleMax != null) _diskActiveTimeScaleMax.Foreground = textMid;
            if (_diskActiveScaleTime != null) _diskActiveScaleTime.Foreground = textMid;
            if (_diskActiveScaleZero != null) _diskActiveScaleZero.Foreground = textMid;

            if (_diskTransferHeaderLabel != null) _diskTransferHeaderLabel.Foreground = textMid;
            if (_diskTransferScaleMax != null) _diskTransferScaleMax.Foreground = textMid;
            if (_diskTransferScaleTime != null) _diskTransferScaleTime.Foreground = textMid;
            if (_diskTransferScaleZero != null) _diskTransferScaleZero.Foreground = textMid;

            if (_labelDiskActiveTime != null) _labelDiskActiveTime.Foreground = textMid;
            if (_labelDiskResponseTime != null) _labelDiskResponseTime.Foreground = textMid;
            if (_labelDiskReadSpeed != null) _labelDiskReadSpeed.Foreground = textMid;
            if (_labelDiskWriteSpeed != null) _labelDiskWriteSpeed.Foreground = textMid;

            if (_statDiskActiveTime != null) _statDiskActiveTime.Foreground = textHigh;
            if (_statDiskResponseTime != null) _statDiskResponseTime.Foreground = textHigh;
            if (_statDiskReadSpeed != null) _statDiskReadSpeed.Foreground = textHigh;
            if (_statDiskWriteSpeed != null) _statDiskWriteSpeed.Foreground = textHigh;

            if (_labelDiskCapacity != null) _labelDiskCapacity.Foreground = textMid;
            if (_labelDiskFormatted != null) _labelDiskFormatted.Foreground = textMid;
            if (_labelDiskSystemDisk != null) _labelDiskSystemDisk.Foreground = textMid;
            if (_labelDiskPageFile != null) _labelDiskPageFile.Foreground = textMid;
            if (_labelDiskType != null) _labelDiskType.Foreground = textMid;

            if (_metaDiskCapacity != null) _metaDiskCapacity.Foreground = textHigh;
            if (_metaDiskFormatted != null) _metaDiskFormatted.Foreground = textHigh;
            if (_metaDiskSystemDisk != null) _metaDiskSystemDisk.Foreground = textHigh;
            if (_metaDiskPageFile != null) _metaDiskPageFile.Foreground = textHigh;
            if (_metaDiskType != null) _metaDiskType.Foreground = textHigh;

            if (_bottomFewerDetails != null) _bottomFewerDetails.Foreground = textHigh;
            if (_bottomResmonText != null) _bottomResmonText.Foreground = cpuColor;
        }

        private void OnOpened(object? sender, EventArgs e)
        {
            SwitchGraphView(_isLogicalView);
            SampleCoreCpuUsages(out _);
            Dispatcher.UIThread.Post(() => RedrawAllCharts(), DispatcherPriority.Loaded);
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(_updateIntervalSec) };
            _timer.Tick += OnTick;
            _timer.Start();
            OnTick(this, EventArgs.Empty);
        }

        private void OnClosedCleanup(object? sender, EventArgs e)
        {
            _timer?.Stop();
            _timer = null;
            if (_hPdhQuery != IntPtr.Zero)
            {
                try { PdhCloseQuery(_hPdhQuery); } catch { }
                _hPdhQuery = IntPtr.Zero;
            }
        }

        private void OnTick(object? sender, EventArgs e)
        {
            if (!_isInitialized) return;
            double[] coreUsages = SampleCoreCpuUsages(out double[] kernelUsages);
            double cpuPct = coreUsages.Length > 0 ? coreUsages.Average() : 0.0;
            double kernelPct = kernelUsages.Length > 0 ? kernelUsages.Average() : 0.0;

            _overallHistory.Add(cpuPct);
            if (_overallHistory.Count > 60) _overallHistory.RemoveAt(0);

            _overallKernelHistory.Add(kernelPct);
            if (_overallKernelHistory.Count > 60) _overallKernelHistory.RemoveAt(0);

            for (int i = 0; i < _logicalCoreCount; i++)
            {
                double val = i < coreUsages.Length ? coreUsages[i] : 0.0;
                double kval = i < kernelUsages.Length ? kernelUsages[i] : 0.0;
                _coreHistories[i].Add(Math.Clamp(val, 0.0, 100.0));
                if (_coreHistories[i].Count > 60) _coreHistories[i].RemoveAt(0);
                _coreKernelHistories[i].Add(Math.Clamp(kval, 0.0, 100.0));
                if (_coreKernelHistories[i].Count > 60) _coreKernelHistories[i].RemoveAt(0);
            }

            double speedGhz = SampleCurrentFrequencyGhz();

            if (_statUtilization != null) _statUtilization.Text = ((int)Math.Round(cpuPct)) + "%";
            if (_statSpeed != null) _statSpeed.Text = speedGhz.ToString("F2") + " GHz";
            if (_miniCpuText != null) _miniCpuText.Text = ((int)Math.Round(cpuPct)) + "% " + speedGhz.ToString("F2") + " GHz";

            SampleMemoryUsage();
            SampleDiskActivity();
            SampleNetworkAdapters();
            SampleGpuStats();

            TimeSpan uptime = TimeSpan.FromMilliseconds(Environment.TickCount64);
            if (_statUptime != null) _statUptime.Text = string.Format("{0}:{1:D2}:{2:D2}:{3:D2}", (int)uptime.TotalDays, uptime.Hours, uptime.Minutes, uptime.Seconds);

            UpdateProcessStats();
            RedrawAllCharts();
        }

        private double SampleCurrentFrequencyGhz()
        {
            if (_hPdhQuery != IntPtr.Zero && _hPdhCounter != IntPtr.Zero)
            {
                try
                {
                    if (PdhCollectQueryData(_hPdhQuery) == 0)
                    {
                        if (PdhGetFormattedCounterValue(_hPdhCounter, 0x00000200, out _, out PDH_FMT_COUNTERVALUE_DOUBLE val) == 0)
                        {
                            if (val.CStatus == 0 && val.doubleValue > 0)
                            {
                                if (val.doubleValue > 500)
                                {
                                    return Math.Round(val.doubleValue / 1000.0, 2);
                                }
                                double boostGhz = _baseFreqGhz * (val.doubleValue / 100.0);
                                if (boostGhz >= 1.0 && boostGhz <= 6.5) return Math.Round(boostGhz, 2);
                            }
                        }
                    }
                }
                catch { }
            }

            try
            {
                int structSize = Marshal.SizeOf<ProcessPowerInformation>();
                int bufferSize = structSize * _logicalCoreCount;
                IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
                try
                {
                    int status = CallNtPowerInformation(11, IntPtr.Zero, 0, buffer, (uint)bufferSize);
                    if (status == 0)
                    {
                        uint maxCurrentMhz = 0;
                        for (int i = 0; i < _logicalCoreCount; i++)
                        {
                            IntPtr offset = IntPtr.Add(buffer, i * structSize);
                            var info = Marshal.PtrToStructure<ProcessPowerInformation>(offset);
                            if (info.CurrentMhz > maxCurrentMhz) maxCurrentMhz = info.CurrentMhz;
                        }
                        if (maxCurrentMhz > 500) return Math.Round(maxCurrentMhz / 1000.0, 2);
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            catch { }

            return _baseFreqGhz;
        }

        private void SampleMemoryUsage()
        {
            try
            {
                var mem = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
                if (GlobalMemoryStatusEx(ref mem))
                {
                    double totalGb = mem.ullTotalPhys / (1024.0 * 1024.0 * 1024.0);
                    double availGb = mem.ullAvailPhys / (1024.0 * 1024.0 * 1024.0);
                    double inUseGb = (mem.ullTotalPhys - mem.ullAvailPhys) / (1024.0 * 1024.0 * 1024.0);
                    uint memPct = mem.dwMemoryLoad;

                    _latestMemTotalGb = totalGb;
                    _latestMemInUseGb = inUseGb;
                    _latestMemAvailGb = availGb;

                    _memHistory.Add((double)memPct);
                    if (_memHistory.Count > 60) _memHistory.RemoveAt(0);

                    if (_miniMemText != null)
                    {
                        _miniMemText.Text = $"{inUseGb:F1}/{totalGb:F1} GB ({memPct}%)";
                    }

                    if (_statMemInUse != null) _statMemInUse.Text = $"{inUseGb:F1} GB";
                    if (_statMemAvailable != null) _statMemAvailable.Text = $"{availGb:F1} GB";

                    var perfInfo = new PERFORMANCE_INFORMATION { cb = (uint)Marshal.SizeOf<PERFORMANCE_INFORMATION>() };
                    if (GetPerformanceInfo(out perfInfo, perfInfo.cb))
                    {
                        double pageSize = perfInfo.PageSize.ToUInt64();
                        double commitTotalGb = (perfInfo.CommitTotal.ToUInt64() * pageSize) / (1024.0 * 1024.0 * 1024.0);
                        double commitLimitGb = (perfInfo.CommitLimit.ToUInt64() * pageSize) / (1024.0 * 1024.0 * 1024.0);
                        double cachedGb = (perfInfo.SystemCache.ToUInt64() * pageSize) / (1024.0 * 1024.0 * 1024.0);
                        double pagedMb = (perfInfo.KernelPaged.ToUInt64() * pageSize) / (1024.0 * 1024.0);
                        double nonPagedMb = (perfInfo.KernelNonpaged.ToUInt64() * pageSize) / (1024.0 * 1024.0);

                        _latestMemCachedGb = cachedGb;
                        _latestMemStandbyGb = Math.Min(availGb, cachedGb);
                        _latestMemModifiedGb = Math.Max(0.05, Math.Min(0.4, inUseGb * 0.02));
                        _latestMemFreeGb = Math.Max(0.0, availGb - _latestMemStandbyGb);

                        if (_statMemCommitted != null) _statMemCommitted.Text = $"{commitTotalGb:F1}/{commitLimitGb:F1} GB";
                        if (_statMemCached != null) _statMemCached.Text = $"{cachedGb:F1} GB";
                        if (_statMemPagedPool != null) _statMemPagedPool.Text = $"{Math.Round(pagedMb)} MB";
                        if (_statMemNonPagedPool != null) _statMemNonPagedPool.Text = $"{Math.Round(nonPagedMb)} MB";
                    }
                }
            }
            catch { }
        }

        private void SampleDiskActivity()
        {
            double activePct = 0.0;
            double responseMs = 0.0;
            double readBytesSec = 0.0;
            double writeBytesSec = 0.0;
            double totalBytesSec = 0.0;

            if (_hPdhQuery != IntPtr.Zero)
            {
                try
                {
                    if (_hPdhDiskTimeCounter != IntPtr.Zero)
                    {
                        if (PdhGetFormattedCounterValue(_hPdhDiskTimeCounter, 0x00000200, out _, out PDH_FMT_COUNTERVALUE_DOUBLE val) == 0 && val.CStatus == 0)
                        {
                            activePct = Math.Clamp(val.doubleValue, 0.0, 100.0);
                        }
                    }
                    if (_hPdhDiskResponseCounter != IntPtr.Zero)
                    {
                        if (PdhGetFormattedCounterValue(_hPdhDiskResponseCounter, 0x00000200, out _, out PDH_FMT_COUNTERVALUE_DOUBLE val) == 0 && val.CStatus == 0)
                        {
                            responseMs = Math.Max(0.0, val.doubleValue * 1000.0);
                        }
                    }
                    if (_hPdhDiskReadCounter != IntPtr.Zero)
                    {
                        if (PdhGetFormattedCounterValue(_hPdhDiskReadCounter, 0x00000200, out _, out PDH_FMT_COUNTERVALUE_DOUBLE val) == 0 && val.CStatus == 0)
                        {
                            readBytesSec = Math.Max(0.0, val.doubleValue);
                        }
                    }
                    if (_hPdhDiskWriteCounter != IntPtr.Zero)
                    {
                        if (PdhGetFormattedCounterValue(_hPdhDiskWriteCounter, 0x00000200, out _, out PDH_FMT_COUNTERVALUE_DOUBLE val) == 0 && val.CStatus == 0)
                        {
                            writeBytesSec = Math.Max(0.0, val.doubleValue);
                        }
                    }
                    if (_hPdhDiskTransferCounter != IntPtr.Zero)
                    {
                        if (PdhGetFormattedCounterValue(_hPdhDiskTransferCounter, 0x00000200, out _, out PDH_FMT_COUNTERVALUE_DOUBLE val) == 0 && val.CStatus == 0)
                        {
                            totalBytesSec = Math.Max(0.0, val.doubleValue);
                        }
                    }
                    else
                    {
                        totalBytesSec = readBytesSec + writeBytesSec;
                    }
                }
                catch { }
            }

            _diskHistory.Add(activePct);
            if (_diskHistory.Count > 60) _diskHistory.RemoveAt(0);

            _diskTransferHistory.Add(totalBytesSec);
            if (_diskTransferHistory.Count > 60) _diskTransferHistory.RemoveAt(0);

            _latestPeakTransferRate = _diskTransferHistory.Count > 0 ? _diskTransferHistory.Max() : 100 * 1024.0;

            if (_miniDiskText != null)
            {
                _miniDiskText.Text = $"{_metaDiskType?.Text ?? "SSD"}\n{Math.Round(activePct)}%";
            }
            if (_statDiskActiveTime != null)
            {
                _statDiskActiveTime.Text = $"{Math.Round(activePct)}%";
            }
            if (_statDiskResponseTime != null)
            {
                _statDiskResponseTime.Text = $"{responseMs:F1} ms";
            }
            if (_statDiskReadSpeed != null)
            {
                _statDiskReadSpeed.Text = FormatTransferRate(readBytesSec);
            }
            if (_statDiskWriteSpeed != null)
            {
                _statDiskWriteSpeed.Text = FormatTransferRate(writeBytesSec);
            }
        }

        private void SampleNetworkTraffic()
        {
            try
            {
                long totalBytesSent = 0;
                long totalBytesRecv = 0;
                foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus == OperationalStatus.Up && nic.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                    {
                        var stats = nic.GetIPv4Statistics();
                        totalBytesSent += stats.BytesSent;
                        totalBytesRecv += stats.BytesReceived;
                    }
                }

                DateTime now = DateTime.UtcNow;
                double seconds = (now - _prevNetSampleTime).TotalSeconds;
                if (seconds >= 0.5 && _prevWifiBytesSent > 0)
                {
                    double sendKbps = Math.Max(0, (totalBytesSent - _prevWifiBytesSent) * 8.0 / (seconds * 1024.0));
                    double recvKbps = Math.Max(0, (totalBytesRecv - _prevWifiBytesRecv) * 8.0 / (seconds * 1024.0));

                    if (_miniWifiText != null)
                    {
                        _miniWifiText.Text = $"Wi-Fi\nS: {sendKbps:F1} R: {recvKbps:F1} Kbps";
                    }

                    double netLoad = Math.Clamp((sendKbps + recvKbps) / 20.0, 0.0, 100.0);
                    _wifiHistory.Add(netLoad);
                    if (_wifiHistory.Count > 60) _wifiHistory.RemoveAt(0);
                }

                _prevWifiBytesSent = totalBytesSent;
                _prevWifiBytesRecv = totalBytesRecv;
                _prevNetSampleTime = now;
            }
            catch { }

            _eth1History.Add(0.0);
            if (_eth1History.Count > 60) _eth1History.RemoveAt(0);
            _eth2History.Add(0.0);
            if (_eth2History.Count > 60) _eth2History.RemoveAt(0);

            if (_miniGpuText != null)
            {
                _miniGpuText.Text = $"{_gpuName}\n1% (45\u00B0C)";
            }
        }

        private double[] SampleCoreCpuUsages(out double[] kernelUsages)
        {
            double[] usages = new double[_logicalCoreCount];
            kernelUsages = new double[_logicalCoreCount];

            int structSize = Marshal.SizeOf<SystemProcessorPerformanceInfo>();
            int bufferSize = structSize * _logicalCoreCount;
            IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
            try
            {
                int status = NtQuerySystemInformation(8, buffer, bufferSize, out int returnLength);
                if (status == 0)
                {
                    int coresReturned = Math.Min(_logicalCoreCount, returnLength / structSize);
                    for (int i = 0; i < coresReturned; i++)
                    {
                        IntPtr offset = IntPtr.Add(buffer, i * structSize);
                        var info = Marshal.PtrToStructure<SystemProcessorPerformanceInfo>(offset);
                        long total = info.KernelTime + info.UserTime;
                        long idle = info.IdleTime;
                        long kernel = info.KernelTime - info.IdleTime;

                        if (_prevCoreTotal != null && _prevCoreIdle != null && _prevCoreTotal[i] > 0)
                        {
                            long deltaTotal = total - _prevCoreTotal[i];
                            long deltaIdle = idle - _prevCoreIdle[i];
                            long deltaKernel = _prevCoreKernel != null ? kernel - _prevCoreKernel[i] : 0;

                            if (deltaTotal > 0)
                            {
                                double pct = (double)(deltaTotal - deltaIdle) * 100.0 / deltaTotal;
                                usages[i] = Math.Clamp(pct, 0.0, 100.0);

                                double kpct = (double)Math.Max(0, deltaKernel) * 100.0 / deltaTotal;
                                kernelUsages[i] = Math.Clamp(kpct, 0.0, 100.0);
                            }
                        }
                        if (_prevCoreTotal != null && _prevCoreIdle != null && _prevCoreKernel != null)
                        {
                            _prevCoreTotal[i] = total;
                            _prevCoreIdle[i] = idle;
                            _prevCoreKernel[i] = kernel;
                        }
                    }
                }
            }
            catch { }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
            return usages;
        }

        private void UpdateProcessStats()
        {
            try
            {
                Process[] procs = Process.GetProcesses();
                int threads = 0;
                int handles = 0;
                foreach (var p in procs)
                {
                    try
                    {
                        threads += p.Threads.Count;
                        handles += p.HandleCount;
                    }
                    catch { }
                }

                if (_statProcesses != null) _statProcesses.Text = procs.Length.ToString();
                if (_statThreads != null) _statThreads.Text = threads.ToString();
                if (_statHandles != null) _statHandles.Text = handles.ToString();
            }
            catch { }
        }

        private void DrawChart(Canvas? canvas, List<double> history, List<double>? kernelHistory, Color lineColor, Color fillColor, bool isMini = false, bool isMemory = false, bool isDisk = false)
        {
            if (canvas == null) return;
            // Skip if VISIBLE but layout isn't complete - prevents half-size renders
            // (Hidden panels should still redraw to update theme colors)
            if (canvas.IsVisible && (!canvas.IsMeasureValid || !canvas.IsArrangeValid))
                return;
            canvas.Children.Clear();
            double w = canvas.Bounds.Width;
            double h = canvas.Bounds.Height;
            if (w <= 4) w = canvas.Width;
            if (h <= 4) h = canvas.Height;
            if (double.IsNaN(w) || w <= 4) w = isMini ? 52 : 500;
            if (double.IsNaN(h) || h <= 4) h = isMini ? 38 : 220;

            Color gridColor;
            if (isMemory)
            {
                gridColor = _isDark ? Color.Parse("#2D2330") : Color.Parse("#F5EBF7");
            }
            else if (isDisk)
            {
                gridColor = _isDark ? Color.Parse("#232E1B") : Color.Parse("#EAF2E6");
            }
            else
            {
                gridColor = _isDark ? Color.Parse("#233848") : Color.Parse("#E5F2FB");
            }
            var gridPen = new SolidColorBrush(gridColor);

            int horizDivs = isMini ? 3 : 10;
            for (int i = 1; i < horizDivs; i++)
            {
                double y = Math.Round(h * (i / (double)horizDivs)) + 0.5;
                canvas.Children.Add(new Line { StartPoint = new Point(0, y), EndPoint = new Point(w, y), Stroke = gridPen, StrokeThickness = 1 });
            }

            int vertDivs = isMini ? 3 : 10;
            for (int i = 1; i < vertDivs; i++)
            {
                double x = Math.Round(w * (i / (double)vertDivs)) + 0.5;
                canvas.Children.Add(new Line { StartPoint = new Point(x, 0), EndPoint = new Point(x, h), Stroke = gridPen, StrokeThickness = 1 });
            }

            if (history == null || history.Count == 0) return;

            double step = w / 59.0;
            double startX = w - ((history.Count - 1) * step);

            var fillPoints = new Avalonia.Collections.AvaloniaList<Point>();
            var strokePoints = new Avalonia.Collections.AvaloniaList<Point>();

            fillPoints.Add(new Point(startX, h));
            for (int i = 0; i < history.Count; i++)
            {
                double x = startX + (i * step);
                double pct = Math.Clamp(history[i], 0.0, 100.0);
                double y = (h - 1.0) - (pct / 100.0 * (h - 2.0));
                strokePoints.Add(new Point(x, y));
                fillPoints.Add(new Point(x, y));
            }
            fillPoints.Add(new Point(startX + ((history.Count - 1) * step), h));

            canvas.Children.Add(new Polygon
            {
                Points = fillPoints,
                Fill = new SolidColorBrush(fillColor)
            });

            canvas.Children.Add(new Polyline
            {
                Points = strokePoints,
                Stroke = new SolidColorBrush(lineColor),
                StrokeThickness = isMini ? 0.9 : 1.2
            });

            if (kernelHistory != null && kernelHistory.Count > 0)
            {
                var kStroke = new Avalonia.Collections.AvaloniaList<Point>();
                for (int i = 0; i < kernelHistory.Count; i++)
                {
                    double x = startX + (i * step);
                    double pct = Math.Clamp(kernelHistory[i], 0.0, 100.0);
                    double y = (h - 1.0) - (pct / 100.0 * (h - 2.0));
                    kStroke.Add(new Point(x, y));
                }
                canvas.Children.Add(new Polyline
                {
                    Points = kStroke,
                    Stroke = new SolidColorBrush(_isDark ? Color.Parse("#E05252") : Color.Parse("#C83232")),
                    StrokeThickness = 1.0
                });
            }
        }

        private void OnRunTaskClick(object? sender, RoutedEventArgs e)
        {
            try { Process.Start(new ProcessStartInfo("cmd.exe") { UseShellExecute = true }); } catch { }
        }

        private void OnExitClick(object? sender, RoutedEventArgs e) => Close();

        private void OnAlwaysOnTopClick(object? sender, RoutedEventArgs e)
        {
            Topmost = !Topmost;
            if (_menuAlwaysOnTop != null)
            {
                _menuAlwaysOnTop.Header = Topmost ? "\u2713 Always on top" : "Always on top";
            }
        }

        private void OnToggleDarkModeClick(object? sender, RoutedEventArgs e)
        {
            if (!_isInitialized) return;
            _isDark = !_isDark;
            SaveSettings();
            ApplyThemeColors();
            ApplyNetworkGpuTheme();
            RefreshTileHighlights();
            UpdateTitleBarDarkMode();
            // Post redraw to let layout settle with new theme colors
            // (synchronous redraw can use stale Bounds/colors)
            Dispatcher.UIThread.Post(() => RedrawAllCharts(), DispatcherPriority.Render);
        }

        // ================= Tab Switching =================
        
        private void OnProcessesTabClick(object? sender, PointerPressedEventArgs e)
        {
            SetActiveTopTab("Processes");
            ShowProcessesPanel();
        }
        
        private void OnPerformanceTabClick(object? sender, PointerPressedEventArgs e)
        {
            SetActiveTopTab("Performance");
            ShowPerformancePanel();
        }
        
        private void OnAppHistoryTabClick(object? sender, PointerPressedEventArgs e)
        {
            SetActiveTopTab("AppHistory");
            // TODO: Show app history panel
        }
        
        private void OnStartupTabClick(object? sender, PointerPressedEventArgs e)
        {
            SetActiveTopTab("Startup");
            // TODO: Show startup panel
        }
        
        private void OnUsersTabClick(object? sender, PointerPressedEventArgs e)
        {
            SetActiveTopTab("Users");
            // TODO: Show users panel
        }
        
        private void OnDetailsTabClick(object? sender, PointerPressedEventArgs e)
        {
            SetActiveTopTab("Details");
            // TODO: Show details panel
        }
        
        private void OnServicesTabClick(object? sender, PointerPressedEventArgs e)
        {
            SetActiveTopTab("Services");
            // TODO: Show services panel
        }
        
        private void SetActiveTopTab(string tab)
        {
            // Update tab visual states using Border x:Names directly
            var borderNames = new Dictionary<string, string>
            {
                { "Processes", "TabProcessesBorder" },
                { "Performance", "TabPerfBorder" },
                { "AppHistory", "TabAppHistoryBorder" },
                { "Startup", "TabStartupBorder" },
                { "Users", "TabUsersBorder" },
                { "Details", "TabDetailsBorder" },
                { "Services", "TabServicesBorder" },
            };
            var textNames = new Dictionary<string, string>
            {
                { "Processes", "TabProcesses" },
                { "Performance", "TabPerformance" },
                { "AppHistory", "TabAppHistory" },
                { "Startup", "TabStartup" },
                { "Users", "TabUsers" },
                { "Details", "TabDetails" },
                { "Services", "TabServices" },
            };
            
            // Active tab: dark bg in dark mode, white in light mode, with top border
            // Inactive: transparent
            var activeBg = new SolidColorBrush(_isDark ? Color.Parse("#1E1E1E") : Color.Parse("#FFFFFF"));
            var activeBorderBrush = new SolidColorBrush(_isDark ? Color.Parse("#3A3A3A") : Color.Parse("#CCCCCC"));
            
            foreach (var kv in borderNames)
            {
                string tabKey = kv.Key;
                string borderName = kv.Value;
                var border = this.FindControl<Border>(borderName);
                if (border != null)
                {
                    bool isActive = (tabKey == tab);
                    border.Background = isActive ? activeBg : Brushes.Transparent;
                    border.BorderBrush = activeBorderBrush;
                    border.BorderThickness = isActive ? new Thickness(1, 1, 1, 0) : new Thickness(0);
                }
                // Update text weight
                if (textNames.TryGetValue(tabKey, out var textName))
                {
                    var tb = this.FindControl<TextBlock>(textName);
                    if (tb != null)
                        tb.FontWeight = (tabKey == tab) ? FontWeight.SemiBold : FontWeight.Normal;
                }
            }
        }
        
private void UpdateTitleBarDarkMode()
        {
            try
            {
                var handle = TryGetPlatformHandle();
                if (handle != null)
                {
                    IntPtr hwnd = handle.Handle;
                    if (hwnd != IntPtr.Zero)
                    {
                        int darkMode = _isDark ? 1 : 0;
                        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkMode, sizeof(int));
                    }
                }
            }
            catch { }
        }

        private void RefreshTileHighlights()
        {
            // Re-apply tile selection colors after theme change
            // (SetActivePanel sets them, but theme change doesn't trigger it)
            var selTileBg = new SolidColorBrush(_isDark ? Color.Parse("#2B3844") : Color.Parse("#E5F1FB"));
            var selTileBorder = new SolidColorBrush(_isDark ? Color.Parse("#4CC2FF") : Color.Parse("#70C0E7"));
            var trans = Brushes.Transparent;

            if (_cpuTileBorder != null)
            {
                bool sel = (_activePanel == PerformancePanel.Cpu);
                _cpuTileBorder.Background = sel ? selTileBg : trans;
                _cpuTileBorder.BorderBrush = sel ? selTileBorder : trans;
            }
            if (_memTileBorder != null)
            {
                bool sel = (_activePanel == PerformancePanel.Memory);
                _memTileBorder.Background = sel ? selTileBg : trans;
                _memTileBorder.BorderBrush = sel ? selTileBorder : trans;
            }
            if (_diskTileBorder != null)
            {
                bool sel = (_activePanel == PerformancePanel.Disk);
                _diskTileBorder.Background = sel ? selTileBg : trans;
                _diskTileBorder.BorderBrush = sel ? selTileBorder : trans;
            }
            // Network/GPU tiles are in NetworkGpu.cs
            RefreshNetGpuTileHighlights();
        }

        private void OnRefreshNowClick(object? sender, RoutedEventArgs e) => OnTick(this, EventArgs.Empty);

        private void OnSpeedHighClick(object? sender, RoutedEventArgs e)
        {
            _updateIntervalSec = 1;
            if (_timer != null) _timer.Interval = TimeSpan.FromMilliseconds(500);
            UpdateGraphHeaderAndScale();
        }

        private void OnSpeedNormalClick(object? sender, RoutedEventArgs e)
        {
            _updateIntervalSec = 1;
            if (_timer != null) _timer.Interval = TimeSpan.FromSeconds(1);
            UpdateGraphHeaderAndScale();
        }

        private void OnSpeedLowClick(object? sender, RoutedEventArgs e)
        {
            _updateIntervalSec = 4;
            if (_timer != null) _timer.Interval = TimeSpan.FromSeconds(4);
            UpdateGraphHeaderAndScale();
        }

        private void OnSpeedPausedClick(object? sender, RoutedEventArgs e)
        {
            _timer?.Stop();
        }

        private void OnOverallGraphClick(object? sender, RoutedEventArgs e)
        {
            if (_activePanel == PerformancePanel.Cpu) SwitchGraphView(false);
        }

        private void OnLogicalGraphClick(object? sender, RoutedEventArgs e)
        {
            if (_activePanel == PerformancePanel.Cpu) SwitchGraphView(true);
        }

        private void OnOpenResmonClick(object? sender, PointerPressedEventArgs e)
        {
            try { Process.Start(new ProcessStartInfo("resmon.exe") { UseShellExecute = true }); } catch { }
        }
    }
}
'@

Set-Content -LiteralPath (Join-Path $Dir ($Name + '.csproj')) -Value $projAva.Replace('__APPNAME__', $Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'Program.cs') -Value $progCs.Replace('__APPNAME__', $Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'App.axaml') -Value $appAxaml.Replace('__APPNAME__', $Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'App.axaml.cs') -Value $appCs.Replace('__APPNAME__', $Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'MainWindow.axaml') -Value $mwAxaml.Replace('__APPNAME__', $Name) -Encoding UTF8
$mwNetGpuCs = @'
// MainWindow.NetworkGpu.cs
// Adds the missing Performance detail views: Wi-Fi / Ethernet (Network) and GPU.
// This is a second partial-class file for MainWindow. It needs NO changes to the
// existing MainWindow.axaml.cs logic except the small hook edits listed in
// APPLY_EDITS.md (enum values, InitNetworkGpu() call, SetActivePanel lines,
// RedrawAllCharts branches, OnTick sampling lines, OnToggleDarkMode theme line).
//
// The build script must write this file with the same __APPNAME__ -> project name
// replacement it already applies to the other sources.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Threading;
using Microsoft.Win32;

namespace __APPNAME__
{
    #region WLAN interop (SSID / signal strength)

    internal enum WLAN_INTF_OPCODE
    {
        wlan_intf_opcode_current_connection = 7,
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct DOT11_SSID
    {
        public uint uSSIDLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] ucSSID;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct WLAN_ASSOCIATION_ATTRIBUTES
    {
        public DOT11_SSID dot11Ssid;
        public uint dot11BssType;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)]
        public byte[] dot11Bssid;
        public uint dot11PhyType;
        public uint uDot11PhyIndex;
        public uint wlanSignalQuality;
        public uint ulRxRate;
        public uint ulTxRate;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct WLAN_SECURITY_ATTRIBUTES
    {
        [MarshalAs(UnmanagedType.Bool)] public bool bSecurityEnabled;
        [MarshalAs(UnmanagedType.Bool)] public bool bOneXEnabled;
        public uint dot11AuthAlgorithm;
        public uint dot11CipherAlgorithm;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct WLAN_CONNECTION_ATTRIBUTES
    {
        public uint isState;
        public uint wlanConnectionMode;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strProfileName;
        public WLAN_ASSOCIATION_ATTRIBUTES wlanAssociationAttributes;
        public WLAN_SECURITY_ATTRIBUTES wlanSecurityAttributes;
    }

    // NOTE: Pack=4 so Marshal.SizeOf matches the native 532-byte stride when
    // walking the InterfaceInfo[] array returned by WlanEnumInterfaces.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
    internal struct WLAN_INTERFACE_INFO
    {
        public Guid InterfaceGuid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strInterfaceDescription;
        public uint isState;
    }

    #endregion

    #region PDH wildcard-array interop (GPU engine / adapter memory counters)

    [StructLayout(LayoutKind.Sequential)]
    internal struct PDH_FMT_COUNTERVALUE_ITEM_DOUBLE
    {
        public IntPtr szName;
        public uint CStatus;
        public double doubleValue;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct DXGI_ADAPTER_DESC
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Description;
        public uint VendorId;
        public uint DeviceId;
        public uint SubSysId;
        public uint Revision;
        public UIntPtr DedicatedVideoMemory;
        public UIntPtr DedicatedSystemMemory;
        public UIntPtr SharedSystemMemory;
        public uint AdapterLuidLow;
        public int AdapterLuidHigh;
    }

    #endregion

    internal sealed class GpuEngineTracker
    {
        public string Key = "";
        public string Label = "";
        public int SortOrder;
        public readonly List<double> History = new List<double>();
        public double LastValue;
        public Border? Card;
        public Canvas? Canvas;
        public TextBlock? PctText;
        public TextBlock? NameText;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    internal struct ADLAdapterInfo
    {
        public int iSize;
        public int iAdapterIndex;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strUDID;
        public int iBusNumber;
        public int iDeviceNumber;
        public int iFunctionNumber;
        public int iVendorID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAdapterName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strDisplayName;
        public int iPresent;
        public int iExist;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strDriverPath;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strDriverPathExt;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strPNPString;
        public int iOSDisplayIndex;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ADLTemperature
    {
        public int iSize;
        public int iTemperature; // millidegrees Celsius
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ADLPMActivity
    {
        public int iSize;
        public int iEngineClock;
        public int iMemoryClock;
        public int iVddc;
        public int iActivityPercent;
        public int iCurrentPerformanceLevel;
        public int iCurrentBusSpeed;
        public int iCurrentBusLanes;
        public int iMaximumBusLanes;
        public int iReserved;
    }

    internal sealed class NetAdapterTracker
    {
        public string Key = "";
        public string NicId = "";
        public string Name = "";
        public string Description = "";
        public bool IsWifi;
        public bool Present;
        public double LinkSpeedBps;
        public string WifiPhy = "802.11";
        public long PrevSent;
        public long PrevRecv;
        public DateTime PrevTime = DateTime.UtcNow;
        public bool HasPrev;
        public double LastSendBps;
        public double LastRecvBps;
        public readonly List<double> SendHist = new List<double>();
        public readonly List<double> RecvHist = new List<double>();
    }

    public partial class MainWindow
    {
        [DllImport("wlanapi.dll", SetLastError = true)]
        private static extern int WlanOpenHandle(uint dwClientVersion, IntPtr pReserved, out uint pdwNegotiatedVersion, out IntPtr phClientHandle);

        [DllImport("wlanapi.dll", SetLastError = true)]
        private static extern int WlanEnumInterfaces(IntPtr hClientHandle, IntPtr pReserved, out IntPtr ppInterfaceList);

        [DllImport("wlanapi.dll", SetLastError = true)]
        private static extern int WlanQueryInterface(IntPtr hClientHandle, ref Guid pInterfaceGuid, WLAN_INTF_OPCODE OpCode, IntPtr pReserved, out uint pdwDataSize, out IntPtr ppData, IntPtr pWlanOpcodeValueType);

        [DllImport("wlanapi.dll")]
        private static extern void WlanFreeMemory(IntPtr pMemory);

        [DllImport("pdh.dll", SetLastError = true)]
        private static extern int PdhGetFormattedCounterArrayW(IntPtr hCounter, uint dwFormat, ref uint lpdwBufferSize, out uint lpdwItemCount, IntPtr lpBuffer);

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int PdhEnumObjectItemsW(string? szDataSource, string? szMachineName, string szObjectName,
            StringBuilder? mszCounterList, ref uint pcchCounterListLength,
            StringBuilder? mszInstanceList, ref uint pcchInstanceListLength,
            uint dwDetailLevel, uint dwFlags);

        [DllImport("pdh.dll", SetLastError = true)]
        private static extern int PdhRemoveCounter(IntPtr hCounter);

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int PdhExpandWildCardPathW(string? szDataSource, string szWildCardPath, StringBuilder? mszExpandedPathList, ref uint pcchPathListLength, uint dwFlags);

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int PdhValidatePathW(string szFullPathBuffer);

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int PdhAddCounterW(IntPtr hQuery, string szFullCounterPath, IntPtr userData, out IntPtr phCounter);

        [DllImport("dxgi.dll", CharSet = CharSet.Unicode)]
        private static extern int CreateDXGIFactory(ref Guid riid, out IntPtr ppFactory);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int DxgiEnumAdaptersDelegate(IntPtr self, uint adapter, out IntPtr ppAdapter);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int DxgiAdapterGetDescDelegate(IntPtr self, out DXGI_ADAPTER_DESC desc);

        [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int ADL2_Main_Control_Create(ADLMemoryAlloc callback, int enumConnectedAdapters, out IntPtr context);

        [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int ADL2_Overdrive6_Temperature_Get(IntPtr context, int adapterIndex, ref ADLTemperature temperature);

        [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int ADL2_OverdriveN_PerformanceStatus_Get(IntPtr context, int iAdapterIndex, IntPtr pPerformanceStatus);

        [DllImport("d3d12.dll")]
        private static extern int D3D12CreateDevice(IntPtr pAdapter, uint minimumFeatureLevel, ref Guid riid, out IntPtr ppDevice);

        private delegate IntPtr ADLMemoryAlloc(int size);
        private static readonly ADLMemoryAlloc _adlAlloc = size => Marshal.AllocHGlobal(size);

        [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int ADL_Main_Control_Create(ADLMemoryAlloc callback, int enumConnectedAdapters);

        [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int ADL_Adapter_NumberOfAdapters_Get(ref int numAdapters);

        [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int ADL_Adapter_AdapterInfo_Get(IntPtr info, int inputSize);

        [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int ADL_Overdrive5_Temperature_Get(int adapterIndex, int thermalControllerIndex, ref ADLTemperature temperature);

        [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int ADL_Overdrive5_CurrentActivity_Get(int iAdapterIndex, ref ADLPMActivity lpActivity);

        private static readonly Regex GpuEngRegex = new Regex(@"eng_(\d+)_engtype_([A-Za-z0-9]+)", RegexOptions.Compiled);

        private const int PDH_MORE_DATA = unchecked((int)0x800007D2);
        private const uint PDH_FMT_DOUBLE = 0x00000200;

        // ---- Network view controls ----
        private Grid? _networkView;
        private TextBlock? _netBigHeader;
        private TextBlock? _netAdapterText;
        private TextBlock? _netGraphHeaderLabel;
        private TextBlock? _netGraphScaleMax;
        private TextBlock? _netGraphScaleTime;
        private TextBlock? _netGraphScaleZero;
        private Border? _netGraphBorder;
        private Canvas? _netGraphCanvas;
        private TextBlock? _labelNetSend;
        private TextBlock? _labelNetReceive;
        private TextBlock? _statNetSend;
        private TextBlock? _statNetReceive;
        private TextBlock? _labelNetAdapterName;
        private TextBlock? _labelNetConnType;
        private TextBlock? _labelNetRow3;
        private TextBlock? _labelNetRow4;
        private TextBlock? _labelNetRow5;
        private TextBlock? _labelNetRow6;
        private TextBlock? _metaNetAdapterName;
        private TextBlock? _metaNetConnType;
        private TextBlock? _metaNetRow3;
        private TextBlock? _metaNetRow4;
        private TextBlock? _metaNetRow5;
        private TextBlock? _metaNetRow6;

        // ---- GPU view controls ----
        private Grid? _gpuView;
        private TextBlock? _gpuBigHeader;
        private TextBlock? _gpuNameText;
        private Grid? _gpuEnginesGrid;
        private TextBlock? _gpuDedMemHeaderLabel;
        private TextBlock? _gpuDedMemScaleMax;
        private Border? _gpuDedMemBorder;
        private Canvas? _gpuDedMemCanvas;
        private TextBlock? _gpuSharedMemHeaderLabel;
        private TextBlock? _gpuSharedMemScaleMax;
        private Border? _gpuSharedMemBorder;
        private Canvas? _gpuSharedMemCanvas;
        private TextBlock? _labelGpuUtil;
        private TextBlock? _labelGpuMem;
        private TextBlock? _statGpuUtil;
        private TextBlock? _statGpuMem;
        private TextBlock? _labelGpuDedicated;
        private TextBlock? _labelGpuShared;
        private TextBlock? _labelGpuTemp;
        private TextBlock? _statGpuDedicated;
        private TextBlock? _statGpuShared;
        private TextBlock? _statGpuTemp;
        private TextBlock? _labelGpuDriverVer;
        private TextBlock? _labelGpuDriverDate;
        private TextBlock? _labelGpuDx;
        private TextBlock? _labelGpuLocation;
        private TextBlock? _labelGpuHwReserved;
        private TextBlock? _metaGpuDriverVer;
        private TextBlock? _metaGpuDriverDate;
        private TextBlock? _metaGpuDx;
        private TextBlock? _metaGpuLocation;
        private TextBlock? _metaGpuHwReserved;

        // ---- Network / GPU state ----
        private readonly List<NetAdapterTracker> _netAdapters = new List<NetAdapterTracker>();
        private string _activeNetKey = "wifi";
        private readonly Dictionary<string, GpuEngineTracker> _gpuEngines = new Dictionary<string, GpuEngineTracker>();
        // 4 fixed engine slots like Task Manager; each slot displays one engine.
        // Defaults: 3D, Copy, Compute_0, Compute_1. User can change via dropdown.
        private readonly string[] _gpuEngineSlots = new string[4] { "3D", "Copy", "Compute_0", "Compute_1" };
        private readonly HashSet<string> _gpuKnownEngines = new HashSet<string>(StringComparer.Ordinal);
        private readonly List<double> _gpuDedHistory = new List<double>();
        private readonly List<double> _gpuSharedHistory = new List<double>();
        private readonly Dictionary<string, IntPtr> _gpuEngineCounters = new Dictionary<string, IntPtr>();
        private IntPtr _hPdhGpuEngineWildcard = IntPtr.Zero;
        private int _gpuEnumTick;
        private IntPtr _adl2Context = IntPtr.Zero;
        private int _adl2TempAdapter = -1;
        private int _adlPciBus = -1;
        private int _adlPciDevice;
        private int _adlPciFunction;
        private IntPtr _hPdhGpuDedUsage = IntPtr.Zero;
        private IntPtr _hPdhGpuSharedUsage = IntPtr.Zero;
        private IntPtr _hPdhGpuDedLimit = IntPtr.Zero;
        private IntPtr _hPdhGpuSharedLimit = IntPtr.Zero;
        private double _gpuDedLimitBytes;
        private double _gpuSharedLimitBytes;
        private double _gpuTempC = double.NaN;
        private string _gpuFullName = "";
        private string _gpuDriverVersion = "";
        private double _gpuHwReservedBytes = 0;
        private string _gpuDriverDate = "";
        private string _gpuLocation = "";
        private IntPtr _wlanHandle = IntPtr.Zero;
        private bool _adlInit;
        private bool _adlOk;
        private int _adlTempAdapter;

        // ================= Initialization =================

        private void InitNetworkGpu()
        {
            BindNetworkGpuControls();
            BuildNetworkAdapterList();
            InitGpuMetadata();
            InitGpuCounters();
            for (int i = 0; i < 60; i++) { _gpuDedHistory.Add(0.0); _gpuSharedHistory.Add(0.0); }
            WireNetworkGpuTiles();
            SetupNetworkGpuContextMenus();
            ApplyNetworkGpuTheme();
        }

        private void BindNetworkGpuControls()
        {
            _networkView = this.FindControl<Grid>("NetworkView");
            _netBigHeader = this.FindControl<TextBlock>("NetBigHeader");
            _netAdapterText = this.FindControl<TextBlock>("NetAdapterText");
            _netGraphHeaderLabel = this.FindControl<TextBlock>("NetGraphHeaderLabel");
            _netGraphScaleMax = this.FindControl<TextBlock>("NetGraphScaleMax");
            _netGraphScaleTime = this.FindControl<TextBlock>("NetGraphScaleTime");
            _netGraphScaleZero = this.FindControl<TextBlock>("NetGraphScaleZero");
            _netGraphBorder = this.FindControl<Border>("NetGraphBorder");
            _netGraphCanvas = this.FindControl<Canvas>("NetGraphCanvas");
            _labelNetSend = this.FindControl<TextBlock>("LabelNetSend");
            _labelNetReceive = this.FindControl<TextBlock>("LabelNetReceive");
            _statNetSend = this.FindControl<TextBlock>("StatNetSend");
            _statNetReceive = this.FindControl<TextBlock>("StatNetReceive");
            _labelNetAdapterName = this.FindControl<TextBlock>("LabelNetAdapterName");
            _labelNetConnType = this.FindControl<TextBlock>("LabelNetConnType");
            _labelNetRow3 = this.FindControl<TextBlock>("LabelNetRow3");
            _labelNetRow4 = this.FindControl<TextBlock>("LabelNetRow4");
            _labelNetRow5 = this.FindControl<TextBlock>("LabelNetRow5");
            _labelNetRow6 = this.FindControl<TextBlock>("LabelNetRow6");
            _metaNetAdapterName = this.FindControl<TextBlock>("MetaNetAdapterName");
            _metaNetConnType = this.FindControl<TextBlock>("MetaNetConnType");
            _metaNetRow3 = this.FindControl<TextBlock>("MetaNetRow3");
            _metaNetRow4 = this.FindControl<TextBlock>("MetaNetRow4");
            _metaNetRow5 = this.FindControl<TextBlock>("MetaNetRow5");
            _metaNetRow6 = this.FindControl<TextBlock>("MetaNetRow6");

            _gpuView = this.FindControl<Grid>("GpuView");
            _gpuBigHeader = this.FindControl<TextBlock>("GpuBigHeader");
            _gpuNameText = this.FindControl<TextBlock>("GpuNameText");
            _gpuEnginesGrid = this.FindControl<Grid>("GpuEnginesGrid");
            _gpuDedMemHeaderLabel = this.FindControl<TextBlock>("GpuDedMemHeaderLabel");
            _gpuDedMemScaleMax = this.FindControl<TextBlock>("GpuDedMemScaleMax");
            _gpuDedMemBorder = this.FindControl<Border>("GpuDedMemBorder");
            _gpuDedMemCanvas = this.FindControl<Canvas>("GpuDedMemCanvas");
            _gpuSharedMemHeaderLabel = this.FindControl<TextBlock>("GpuSharedMemHeaderLabel");
            _gpuSharedMemScaleMax = this.FindControl<TextBlock>("GpuSharedMemScaleMax");
            _gpuSharedMemBorder = this.FindControl<Border>("GpuSharedMemBorder");
            _gpuSharedMemCanvas = this.FindControl<Canvas>("GpuSharedMemCanvas");
            _labelGpuUtil = this.FindControl<TextBlock>("LabelGpuUtil");
            _labelGpuMem = this.FindControl<TextBlock>("LabelGpuMem");
            _statGpuUtil = this.FindControl<TextBlock>("StatGpuUtil");
            _statGpuMem = this.FindControl<TextBlock>("StatGpuMem");
            _labelGpuDedicated = this.FindControl<TextBlock>("LabelGpuDedicated");
            _labelGpuShared = this.FindControl<TextBlock>("LabelGpuShared");
            _labelGpuTemp = this.FindControl<TextBlock>("LabelGpuTemp");
            _statGpuDedicated = this.FindControl<TextBlock>("StatGpuDedicated");
            _statGpuShared = this.FindControl<TextBlock>("StatGpuShared");
            _statGpuTemp = this.FindControl<TextBlock>("StatGpuTemp");
            _labelGpuDriverVer = this.FindControl<TextBlock>("LabelGpuDriverVer");
            _labelGpuDriverDate = this.FindControl<TextBlock>("LabelGpuDriverDate");
            _labelGpuDx = this.FindControl<TextBlock>("LabelGpuDx");
            _labelGpuLocation = this.FindControl<TextBlock>("LabelGpuLocation");
            _labelGpuHwReserved = this.FindControl<TextBlock>("LabelGpuHwReserved");
            _metaGpuDriverVer = this.FindControl<TextBlock>("MetaGpuDriverVer");
            _metaGpuDriverDate = this.FindControl<TextBlock>("MetaGpuDriverDate");
            _metaGpuDx = this.FindControl<TextBlock>("MetaGpuDx");
            _metaGpuLocation = this.FindControl<TextBlock>("MetaGpuLocation");
            _metaGpuHwReserved = this.FindControl<TextBlock>("MetaGpuHwReserved");
        }

        private void BuildNetworkAdapterList()
        {
            _netAdapters.Clear();
            List<NetworkInterface> nics = new List<NetworkInterface>();
            try
            {
                nics = NetworkInterface.GetAllNetworkInterfaces()
                    .Where(n => n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211
                             || n.NetworkInterfaceType == NetworkInterfaceType.Ethernet)
                    .ToList();
            }
            catch { }

            NetworkInterface? wifiNic = nics.FirstOrDefault(n => n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 && n.OperationalStatus == OperationalStatus.Up)
                ?? nics.FirstOrDefault(n => n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211);

            var ethNics = nics.Where(n => n.NetworkInterfaceType == NetworkInterfaceType.Ethernet)
                .OrderByDescending(n => n.OperationalStatus == OperationalStatus.Up)
                .Take(2).ToList();

            AddTracker("wifi", wifiNic, true);
            AddTracker("eth1", ethNics.Count > 0 ? ethNics[0] : null, false);
            AddTracker("eth2", ethNics.Count > 1 ? ethNics[1] : null, false);

            var wifi = _netAdapters[0];
            if (_miniWifiHeading != null) _miniWifiHeading.Text = wifi.Present ? wifi.Name : "Wi-Fi";
            if (_miniWifiText != null && !wifi.Present) _miniWifiText.Text = "Not present";

            var e1 = _netAdapters[1];
            if (_miniEth1Heading != null) _miniEth1Heading.Text = e1.Present ? e1.Name : "Ethernet";
            if (_miniEth1Text != null) _miniEth1Text.Text = e1.Present ? "" : "Not present";

            var e2 = _netAdapters[2];
            if (_miniEth2Heading != null) _miniEth2Heading.Text = e2.Present ? e2.Name : "Ethernet 2";
            if (_miniEth2Text != null) _miniEth2Text.Text = e2.Present ? "" : "Not present";
        }

        private void AddTracker(string key, NetworkInterface? nic, bool isWifi)
        {
            var t = new NetAdapterTracker { Key = key, IsWifi = isWifi };
            if (nic != null)
            {
                t.Present = true;
                t.NicId = nic.Id;
                t.Name = string.IsNullOrWhiteSpace(nic.Name) ? (isWifi ? "Wi-Fi" : "Ethernet") : nic.Name;
                t.Description = string.IsNullOrWhiteSpace(nic.Description) ? t.Name : nic.Description;
                try { t.LinkSpeedBps = Math.Max(0, (double)nic.Speed); } catch { }
            }
            for (int i = 0; i < 60; i++) { t.SendHist.Add(0.0); t.RecvHist.Add(0.0); }
            _netAdapters.Add(t);
        }

        private void InitGpuMetadata()
        {
            try
            {
                using var classKey = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}");
                if (classKey != null)
                {
                    foreach (string sub in classKey.GetSubKeyNames())
                    {
                        if (sub == "Properties") continue;
                        try
                        {
                            using var gpuKey = classKey.OpenSubKey(sub);
                            if (gpuKey == null) continue;
                            string desc = gpuKey.GetValue("DriverDesc")?.ToString() ?? "";
                            // Match our GPU (AMD Radeon 780M) or first display adapter with driver
                            if (desc.IndexOf("Radeon", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                desc.IndexOf("AMD", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                (string.IsNullOrEmpty(_gpuFullName) && !string.IsNullOrEmpty(desc)))
                            {
                                _gpuFullName = desc.Trim();
                                _gpuDriverVersion = gpuKey.GetValue("DriverVersion")?.ToString()?.Trim() ?? "";
                                _gpuDriverDate = (gpuKey.GetValue("DriverDate")?.ToString()?.Trim() ?? "").Replace("-", "/");
                                _gpuLocation = gpuKey.GetValue("LocationInformation")?.ToString()?.Trim() ?? "";
                                if (desc.IndexOf("780M", StringComparison.OrdinalIgnoreCase) >= 0) break;
                            }
                        }
                        catch { }
                    }
                }
            }
            catch { }
            if (string.IsNullOrEmpty(_gpuFullName)) _gpuFullName = _gpuName;
            // Dedicated/shared memory totals via DXGI (same family of APIs Task Manager uses)
            try
            {
                if (TryGetDxgiAdapterMemory(out ulong dxgiDed, out ulong dxgiShared, out ulong dxgiHwRes))
                {
                    if (dxgiDed > 0) _gpuDedLimitBytes = dxgiDed;
                    if (dxgiShared > 0) _gpuSharedLimitBytes = dxgiShared;
                    // Task Manager's Dedicated total includes HW reserved; store it
                    // separately for the "Hardware reserved memory" row.
                    if (dxgiHwRes > 0)
                    {
                        _gpuHwReservedBytes = dxgiHwRes;
                        _gpuDedLimitBytes += dxgiHwRes;
                    }
                }
            }
            catch { }
            if (_metaGpuDriverVer != null) _metaGpuDriverVer.Text = string.IsNullOrEmpty(_gpuDriverVersion) ? "\u2014" : _gpuDriverVersion;
            if (_metaGpuDriverDate != null) _metaGpuDriverDate.Text = string.IsNullOrEmpty(_gpuDriverDate) ? "\u2014" : _gpuDriverDate;
            if (_metaGpuDx != null) _metaGpuDx.Text = DetectDirectXVersion();
            if (_metaGpuLocation != null) _metaGpuLocation.Text = string.IsNullOrEmpty(_gpuLocation) ? "\u2014" : _gpuLocation;
            if (_metaGpuHwReserved != null)
                _metaGpuHwReserved.Text = _gpuHwReservedBytes > 0
                    ? FormatBytesShort(_gpuHwReservedBytes)
                    : "\u2014";
        }


        private void InitGpuCounters()
        {
            if (_hPdhQuery == IntPtr.Zero) return;
            try
            {
                EnumerateGpuEngineInstances();
                _hPdhGpuEngineWildcard = PdhAddWildcard(@"\GPU Engine(*)\Utilization Percentage");
                _hPdhGpuDedUsage = PdhAddWildcard(@"\GPU Adapter Memory(*)\Dedicated Usage");
                _hPdhGpuSharedUsage = PdhAddWildcard(@"\GPU Adapter Memory(*)\Shared Usage");
                _hPdhGpuDedLimit = PdhAddWildcard(@"\GPU Adapter Memory(*)\Dedicated Limit");
                _hPdhGpuSharedLimit = PdhAddWildcard(@"\GPU Adapter Memory(*)\Shared Limit");
            }
            catch { }
        }

        private IntPtr PdhAddWildcard(string wildcardPath)
        {
            try
            {
                if (_hPdhQuery != IntPtr.Zero &&
                    PdhAddEnglishCounterW(_hPdhQuery, wildcardPath, IntPtr.Zero, out IntPtr h) == 0)
                    return h;
            }
            catch { }
            return IntPtr.Zero;
        }

        private static double PdhReadWildcardSum(IntPtr hCounter)
        {
            if (hCounter == IntPtr.Zero) return 0.0;
            try
            {
                uint bufSize = 0;
                int res = PdhGetFormattedCounterArrayW(hCounter, PDH_FMT_DOUBLE, ref bufSize, out _, IntPtr.Zero);
                if (res != PDH_MORE_DATA || bufSize == 0) return 0.0;
                IntPtr buf = Marshal.AllocHGlobal((int)bufSize);
                try
                {
                    res = PdhGetFormattedCounterArrayW(hCounter, PDH_FMT_DOUBLE, ref bufSize, out uint itemCount, buf);
                    if (res != 0) return 0.0;
                    double sum = 0.0;
                    int itemSize = Marshal.SizeOf<PDH_FMT_COUNTERVALUE_ITEM_DOUBLE>();
                    for (int i = 0; i < itemCount; i++)
                    {
                        var item = Marshal.PtrToStructure<PDH_FMT_COUNTERVALUE_ITEM_DOUBLE>(IntPtr.Add(buf, i * itemSize));
                        if (item.CStatus == 0) sum += Math.Max(0.0, item.doubleValue);
                    }
                    return sum;
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            catch { return 0.0; }
        }

        private void EnumerateGpuEngineInstances()
        {
            var log = new StringBuilder();
            try
            {
                // Deep diagnostics for GPU Engine PDH provider quirks
                try
                {
                    string wildPath = "\\GPU Engine(*)\\Utilization Percentage";
                    int vRes = PdhValidatePathW(wildPath);
                    log.Append("validate wildcard res=").Append(vRes).Append('\n');
                    int addRes = PdhAddEnglishCounterW(_hPdhQuery, wildPath, IntPtr.Zero, out IntPtr wh);
                    log.Append("add-english wildcard res=").Append(addRes).Append('\n');
                    if (addRes == 0 && wh != IntPtr.Zero) { try { PdhRemoveCounter(wh); } catch { } }
                    int addRes2 = PdhAddCounterW(_hPdhQuery, wildPath, IntPtr.Zero, out IntPtr wh2);
                    log.Append("add-plain wildcard res=").Append(addRes2).Append('\n');
                    if (addRes2 == 0 && wh2 != IntPtr.Zero) { try { PdhRemoveCounter(wh2); } catch { } }
                }
                catch (Exception ex) { log.Append("diag EX ").Append(ex.Message).Append('\n'); }

                var names = new List<string>();
                // Strategy 1: enumerate instances via PdhEnumObjectItems
                try
                {
                    const uint PERF_DETAIL_WIZARD = 400;
                    uint counterLen = 0, instanceLen = 0;
                    int res = PdhEnumObjectItemsW(null, null, "GPU Engine", null, ref counterLen, null, ref instanceLen, PERF_DETAIL_WIZARD, 0);
                    log.Append("enum-items probe res=").Append(res).Append(" instanceLen=").Append(instanceLen).Append('\n');
                    if ((res == 0 || res == PDH_MORE_DATA) && instanceLen > 0)
                    {
                        var counters = new StringBuilder(Math.Max((int)counterLen, 1));
                        var instances = new StringBuilder((int)instanceLen);
                        res = PdhEnumObjectItemsW(null, null, "GPU Engine", counters, ref counterLen, instances, ref instanceLen, PERF_DETAIL_WIZARD, 0);
                        log.Append("enum-items res=").Append(res).Append('\n');
                        if (res == 0)
                        {
                            foreach (string n in instances.ToString().Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries))
                                if (n.Length > 0) names.Add(n);
                        }
                    }
                }
                catch (Exception ex) { log.Append("enum-items EX ").Append(ex.Message).Append('\n'); }

                // Strategy 2: expand the wildcard path and try canonical paths directly
                var canonicalPaths = new List<string>();
                try
                {
                    uint len = 0;
                    int res = PdhExpandWildCardPathW(null, "\\GPU Engine(*)\\Utilization Percentage", null, ref len, 0);
                    log.Append("expand probe res=").Append(res).Append(" len=").Append(len).Append('\n');
                    if ((res == 0 || res == PDH_MORE_DATA) && len > 0)
                    {
                        var sb = new StringBuilder((int)len);
                        res = PdhExpandWildCardPathW(null, "\\GPU Engine(*)\\Utilization Percentage", sb, ref len, 0);
                        log.Append("expand res=").Append(res).Append('\n');
                        if (res == 0)
                        {
                            foreach (string p in sb.ToString().Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries))
                            {
                                if (p.Length == 0) continue;
                                canonicalPaths.Add(p);
                                log.Append("  canonical: ").Append(p).Append('\n');
                                int s = p.IndexOf('(');
                                int e = p.LastIndexOf(')');
                                if (s > 0 && e > s)
                                {
                                    string iname = p.Substring(s + 1, e - s - 1);
                                    if (!names.Contains(iname)) names.Add(iname);
                                }
                                else log.Append("  !! unparsable path").Append('\n');
                            }
                        }
                    }
                }
                catch (Exception ex) { log.Append("expand EX ").Append(ex.Message).Append('\n'); }

                // Strategy 2b: try adding the canonical expanded paths directly
                foreach (string cpath in canonicalPaths)
                {
                    if (_gpuEngineCounters.Count >= 128) break;
                    string ckey = "canon:" + cpath;
                    if (_gpuEngineCounters.ContainsKey(ckey)) continue;
                    try
                    {
                        int cr = PdhAddCounterW(_hPdhQuery, cpath, IntPtr.Zero, out IntPtr ch);
                        log.Append("  add-canonical res=").Append(cr).Append('\n');
                        if (cr == 0 && ch != IntPtr.Zero)
                        {
                            _gpuEngineCounters[ckey] = ch;
                            log.Append("  !! canonical add worked!").Append('\n');
                        }
                    }
                    catch (Exception ex) { log.Append("  add-canonical EX: ").Append(ex.Message).Append('\n'); }
                }

                log.Append("instances=").Append(names.Count).Append('\n');
                var seen = new HashSet<string>(StringComparer.Ordinal);
                bool firstDiag = true;
                foreach (string name in names)
                {
                    if (!seen.Add(name)) continue;
                    log.Append("  ").Append(name).Append(GpuEngRegex.IsMatch(name) ? "" : "  [NO REGEX MATCH]").Append('\n');
                    string instPath = "\\GPU Engine(" + name + ")\\Utilization Percentage";
                    if (firstDiag)
                    {
                        firstDiag = false;
                        try
                        {
                            int vRes = PdhValidatePathW(instPath);
                            log.Append("    validate instance res=").Append(vRes).Append('\n');
                            int pRes = PdhAddCounterW(_hPdhQuery, instPath, IntPtr.Zero, out IntPtr ph);
                            log.Append("    add-plain instance res=").Append(pRes).Append('\n');
                            if (pRes == 0 && ph != IntPtr.Zero)
                            {
                                _gpuEngineCounters[name] = ph;
                                log.Append("    !! plain add worked, using it").Append('\n');
                            }
                        }
                        catch (Exception ex) { log.Append("    diag EX: ").Append(ex.Message).Append('\n'); }
                    }
                    if (!_gpuEngineCounters.ContainsKey(name) && _gpuEngineCounters.Count < 128 && _hPdhQuery != IntPtr.Zero)
                    {
                        try
                        {
                            int addRes = PdhAddEnglishCounterW(_hPdhQuery, instPath, IntPtr.Zero, out IntPtr h);
                            log.Append("    add res=").Append(addRes).Append('\n');
                            if (addRes == 0 && h != IntPtr.Zero)
                                _gpuEngineCounters[name] = h;
                        }
                        catch (Exception ex) { log.Append("    add EX: ").Append(ex.Message).Append('\n'); }
                    }
                }
                var dead = new List<string>();
                foreach (string k in _gpuEngineCounters.Keys) if (!seen.Contains(k)) dead.Add(k);
                foreach (string k in dead)
                {
                    try { PdhRemoveCounter(_gpuEngineCounters[k]); } catch { }
                    _gpuEngineCounters.Remove(k);
                }
                log.Append("tracked=").Append(_gpuEngineCounters.Count).Append('\n');
            }
            catch (Exception ex) { log.Append("EX ").Append(ex.Message).Append('\n'); }
            WriteGpuDebugLog(log.ToString());
        }

        private static void WriteGpuDebugLog(string text)
        {
            try { File.AppendAllText("gpu-engines.log", "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + text + "\n"); }
            catch { }
        }

        private static int GpuEngineSortOrder(string engType) => engType switch
        {
            "3D" => 0,
            "Copy" => 1,
            "Compute" => 2,
            "VideoEncode" => 3,
            "VideoDecode" => 4,
            "VideoProcessing" => 5,
            _ => 9,
        };

        private static string GpuEngineBaseLabel(string engType) => engType switch
        {
            "3D" => "3D",
            "Copy" => "Copy",
            "Compute" => "Compute",
            "VideoDecode" => "Video Decode",
            "VideoEncode" => "Video Encode",
            "VideoProcessing" => "Video Processing",
            _ => engType,
        };

        private void RebuildGpuEngineCards()
        {
            if (_gpuEnginesGrid == null) return;
            _gpuEnginesGrid.Children.Clear();
            _gpuEnginesGrid.RowDefinitions.Clear();
            _gpuEnginesGrid.ColumnDefinitions.Clear();

            // 4 fixed slots like Task Manager (2x2 grid)
            for (int c = 0; c < 2; c++)
                _gpuEnginesGrid.ColumnDefinitions.Add(new ColumnDefinition(1, GridUnitType.Star));
            for (int r = 0; r < 2; r++)
                _gpuEnginesGrid.RowDefinitions.Add(new RowDefinition(1, GridUnitType.Star));

            var cardBg = new SolidColorBrush(_isDark ? Color.Parse("#191919") : Color.Parse("#FFFFFF"));
            var cardBorder = new SolidColorBrush(_isDark ? Color.Parse("#2A5A84") : Color.Parse("#70A5CC"));
            var textMid = new SolidColorBrush(_isDark ? Color.Parse("#A0A0A0") : Color.Parse("#555555"));

            for (int slot = 0; slot < 4; slot++)
            {
                string engineKey = _gpuEngineSlots[slot];
                _gpuEngines.TryGetValue(engineKey, out var eng);

                var card = new Border
                {
                    BorderThickness = new Thickness(1),
                    Margin = new Thickness(0, 0, 6, 6),
                    Background = cardBg,
                    BorderBrush = cardBorder,
                };
                var grid = new Grid();
                grid.RowDefinitions.Add(new RowDefinition(0, GridUnitType.Auto));
                grid.RowDefinitions.Add(new RowDefinition(1, GridUnitType.Star));

                var header = new Grid { Margin = new Thickness(2, 0, 2, 0) };
                header.ColumnDefinitions.Add(new ColumnDefinition(1, GridUnitType.Star));
                header.ColumnDefinitions.Add(new ColumnDefinition(0, GridUnitType.Auto));

                // Dropdown button ("v") + engine name
                var dropBtn = new Button
                {
                    Content = "v " + (eng?.Label ?? engineKey),
                    FontSize = 11,
                    Margin = new Thickness(2, 2, 0, 2),
                    Foreground = textMid,
                    Background = Avalonia.Media.Brushes.Transparent,
                    BorderThickness = new Thickness(0),
                    Padding = new Thickness(0),
                    Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
                };
                int slotIdx = slot; // capture for closure
                dropBtn.Flyout = CreateEngineFlyout(slotIdx);

                var pct = new TextBlock { Text = $"{eng?.LastValue ?? 0:F0}%", FontSize = 11, Margin = new Thickness(0, 2, 2, 2), Foreground = textMid };
                Grid.SetColumn(pct, 1);
                header.Children.Add(dropBtn);
                header.Children.Add(pct);

                var canvas = new Canvas { ClipToBounds = true };
                Grid.SetRow(canvas, 1);
                grid.Children.Add(header);
                grid.Children.Add(canvas);
                card.Child = grid;

                Grid.SetRow(card, slot / 2);
                Grid.SetColumn(card, slot % 2);
                _gpuEnginesGrid.Children.Add(card);

                if (eng != null)
                {
                    eng.Card = card;
                    eng.Canvas = canvas;
                    eng.PctText = pct;
                    // NameText now points to the button's content via a wrapper
                    eng.NameText = null; // not used for slot-based cards
                }
                // Store slot->UI mapping for graph updates
                _gpuSlotCanvases[slot] = canvas;
                _gpuSlotPcts[slot] = pct;
                _gpuSlotButtons[slot] = dropBtn;
            }
        }

        // Per-slot UI elements for graph updates
        private readonly Canvas?[] _gpuSlotCanvases = new Canvas?[4];
        private readonly TextBlock?[] _gpuSlotPcts = new TextBlock?[4];
        private readonly Button?[] _gpuSlotButtons = new Button?[4];

        private void UpdateSlotEngine(int slotIdx, string newKey)
        {
            // Update in-place: no rebuild, no flicker, history preserved
            _gpuEngineSlots[slotIdx] = newKey;
            _gpuEngines.TryGetValue(newKey, out var eng);
            string label = eng?.Label ?? newKey;
            if (_gpuSlotButtons[slotIdx] != null)
                _gpuSlotButtons[slotIdx]!.Content = "v " + label;
            // Redraw immediately so the new engine's history shows right away
            RedrawGpuCharts();
        }

        private Flyout CreateEngineFlyout(int slotIdx)
        {
            // Task Manager-style dropdown: white popup list directly below the header
            var listBg = new SolidColorBrush(_isDark ? Color.Parse("#2D2D2D") : Color.Parse("#FFFFFF"));
            var listBorder = new SolidColorBrush(_isDark ? Color.Parse("#555555") : Color.Parse("#999999"));
            var textColor = new SolidColorBrush(_isDark ? Color.Parse("#FFFFFF") : Color.Parse("#222222"));
            var hoverBg = new SolidColorBrush(_isDark ? Color.Parse("#3D3D3D") : Color.Parse("#E5F3FF"));

            var listBox = new ListBox
            {
                Background = listBg,
                BorderBrush = listBorder,
                BorderThickness = new Thickness(1),
                MinWidth = 160,
                MaxHeight = 300,
            };

            // List all known engines, sorted by sort order
            var sorted = _gpuKnownEngines
                .Where(k => _gpuEngines.ContainsKey(k))
                .OrderBy(k => _gpuEngines[k].SortOrder)
                .ToList();
            // Always include the 4 defaults even if no data yet
            foreach (var def in new[] { "3D", "Copy", "Compute_0", "Compute_1" })
                if (!sorted.Contains(def)) sorted.Add(def);

            string currentKey = _gpuEngineSlots[slotIdx];

            foreach (string key in sorted)
            {
                string label = _gpuEngines.TryGetValue(key, out var e) ? e.Label : key;
                var item = new ListBoxItem
                {
                    Content = label,
                    Tag = key, // store engine key for SelectionChanged
                    FontSize = 12,
                    Foreground = textColor,
                    Padding = new Thickness(8, 4, 8, 4),
                    Background = Avalonia.Media.Brushes.Transparent,
                };
                // Highlight current selection
                if (key == currentKey)
                {
                    item.Background = hoverBg;
                    item.IsSelected = true;
                }
                listBox.Items.Add(item);
            }

            var flyout = new Flyout
            {
                Content = listBox,
                Placement = PlacementMode.Bottom,
                ShowMode = FlyoutShowMode.Standard,
            };

            // Use SelectionChanged - reliable with ListBox
            bool handling = false;
            listBox.SelectionChanged += (s, e) =>
            {
                if (handling) return;
                handling = true;
                try
                {
                    if (listBox.SelectedItem is ListBoxItem selected && selected.Tag is string k)
                    {
                        flyout.Hide();
                        UpdateSlotEngine(slotIdx, k);
                    }
                }
                finally { handling = false; }
            };

            return flyout;
        }

        private static bool TryGetDxgiAdapterMemory(out ulong dedicatedBytes, out ulong sharedBytes, out ulong hwReservedBytes)
        {
            dedicatedBytes = 0;
            sharedBytes = 0;
            hwReservedBytes = 0;
            IntPtr factory = IntPtr.Zero;
            IntPtr adapter = IntPtr.Zero;
            try
            {
                var iid = new Guid("7b7166ec-21c7-44ae-b21a-c9ae321ae369"); // IID_IDXGIFactory
                if (CreateDXGIFactory(ref iid, out factory) != 0 || factory == IntPtr.Zero)
                    return false;
                IntPtr fVtbl = Marshal.ReadIntPtr(factory);
                var enumAdapters = Marshal.GetDelegateForFunctionPointer<DxgiEnumAdaptersDelegate>(Marshal.ReadIntPtr(fVtbl, 7 * IntPtr.Size));
                if (enumAdapters(factory, 0, out adapter) != 0 || adapter == IntPtr.Zero)
                    return false;
                IntPtr aVtbl = Marshal.ReadIntPtr(adapter);
                var getDesc = Marshal.GetDelegateForFunctionPointer<DxgiAdapterGetDescDelegate>(Marshal.ReadIntPtr(aVtbl, 8 * IntPtr.Size));
                if (getDesc(adapter, out DXGI_ADAPTER_DESC desc) != 0)
                    return false;
                dedicatedBytes = desc.DedicatedVideoMemory.ToUInt64();
                sharedBytes = desc.SharedSystemMemory.ToUInt64();
                hwReservedBytes = desc.DedicatedSystemMemory.ToUInt64();
                return dedicatedBytes > 0 || sharedBytes > 0;
            }
            catch { return false; }
            finally
            {
                if (adapter != IntPtr.Zero) Marshal.Release(adapter);
                if (factory != IntPtr.Zero) Marshal.Release(factory);
            }
        }

        private static string DetectDirectXVersion()
        {
            try
            {
                var iid = new Guid("189819f1-1db6-4b57-be54-1821339b85f7"); // IID_ID3D12Device
                var levels = new (uint fl, string label)[]
                {
                    (0xc200, "12 (FL 12.2)"),
                    (0xc100, "12 (FL 12.1)"),
                    (0xc000, "12 (FL 12.0)"),
                    (0xb100, "11.1"),
                    (0xb000, "11.0"),
                };
                foreach (var (fl, label) in levels)
                {
                    int hr = D3D12CreateDevice(IntPtr.Zero, fl, ref iid, out IntPtr dev);
                    if (hr == 0 && dev != IntPtr.Zero)
                    {
                        try { Marshal.Release(dev); } catch { }
                        return label;
                    }
                }
            }
            catch (DllNotFoundException) { }
            catch { }
            return "\u2014";
        }

        private bool TryGetGpuTemperature(out double celsius)
        {
            celsius = double.NaN;
            try
            {
                if (!_adlInit)
                {
                    _adlInit = true;
                    try
                    {
                        if (ADL_Main_Control_Create(_adlAlloc, 1) == 0)
                        {
                            _adlTempAdapter = FindAdlTempAdapter(IntPtr.Zero); // Overdrive5
                            _adlOk = _adlTempAdapter >= 0;
                            if (!_adlOk && ADL2_Main_Control_Create(_adlAlloc, 1, out IntPtr ctx) == 0 && ctx != IntPtr.Zero)
                            {
                                _adl2Context = ctx;
                                _adl2TempAdapter = FindAdlTempAdapter(ctx); // Overdrive6
                            }
                        }
                    }
                    catch { }
                }
                var t = new ADLTemperature { iSize = Marshal.SizeOf<ADLTemperature>() };
                if (_adlOk && ADL_Overdrive5_Temperature_Get(_adlTempAdapter, 0, ref t) == 0 && AdlTempSane(t.iTemperature))
                {
                    celsius = t.iTemperature / 1000.0;
                    return true;
                }
                if (_adl2TempAdapter >= 0 && _adl2Context != IntPtr.Zero)
                {
                    t = new ADLTemperature { iSize = Marshal.SizeOf<ADLTemperature>() };
                    if (ADL2_Overdrive6_Temperature_Get(_adl2Context, _adl2TempAdapter, ref t) == 0 && AdlTempSane(t.iTemperature))
                    {
                        celsius = t.iTemperature / 1000.0;
                        return true;
                    }
                }
            }
            catch (DllNotFoundException) { }
            catch { }
            // Last resort: ACPI thermal zone (on an iGPU this is the same die)
            try
            {
                if (TryGetThermalZoneTemp(out double tz))
                {
                    celsius = tz;
                    return true;
                }
            }
            catch { }
            return false;
        }

        private static bool AdlTempSane(int milliC) => milliC > 1000 && milliC < 120000;

        private bool TryGetGpuActivity(out double percent)
        {
            percent = double.NaN;
            try
            {
                // Modern API first: ADL2 OverdriveN (RDNA+). iGPUActivityPercent
                // is at offset 24 of the 72-byte ADLODNPerformanceStatus struct.
                if (TryGetAdl2Activity(out percent)) return true;
                // Legacy fallback: Overdrive5 (pre-RDNA).
                if (!_adlInit)
                {
                    double dummy;
                    TryGetGpuTemperature(out dummy);
                }
                int adapter = _adlOk ? _adlTempAdapter : _adl2TempAdapter;
                if (adapter < 0) return false;
                var act = new ADLPMActivity { iSize = Marshal.SizeOf<ADLPMActivity>() };
                if (ADL_Overdrive5_CurrentActivity_Get(adapter, ref act) == 0
                    && act.iActivityPercent >= 0 && act.iActivityPercent <= 100)
                {
                    percent = act.iActivityPercent;
                    return true;
                }
            }
            catch { }
            return false;
        }

        private bool TryGetAdl2Activity(out double percent)
        {
            percent = double.NaN;
            try
            {
                if (_adl2Context == IntPtr.Zero)
                {
                    try
                    {
                        if (ADL2_Main_Control_Create(_adlAlloc, 1, out IntPtr ctx) == 0 && ctx != IntPtr.Zero)
                            _adl2Context = ctx;
                    }
                    catch { }
                }
                if (_adl2Context == IntPtr.Zero) return false;
                int adapter = _adl2TempAdapter >= 0 ? _adl2TempAdapter : (_adlOk ? _adlTempAdapter : 0);
                IntPtr buf = Marshal.AllocHGlobal(72);
                try
                {
                    Marshal.WriteInt32(buf, 0, 72); // iSize
                    if (ADL2_OverdriveN_PerformanceStatus_Get(_adl2Context, adapter, buf) == 0)
                    {
                        int activity = Marshal.ReadInt32(buf, 24); // iGPUActivityPercent
                        if (activity >= 0 && activity <= 100)
                        {
                            percent = activity;
                            return true;
                        }
                    }
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            catch { }
            return false;
        }

        private static bool TryGetThermalZoneTemp(out double celsius)
        {
            celsius = double.NaN;
            try
            {
                using var searcher = new ManagementObjectSearcher(@"root\WMI", "SELECT CurrentTemperature FROM MSAcpi_ThermalZoneTemperature");
                using var results = searcher.Get();
                double best = double.NaN;
                foreach (ManagementObject mo in results)
                {
                    try
                    {
                        var v = mo["CurrentTemperature"];
                        if (v == null) continue;
                        double c = Convert.ToDouble(v) / 10.0 - 273.15;
                        if (c > 5 && c < 110 && (double.IsNaN(best) || c > best)) best = c;
                    }
                    catch { }
                }
                if (!double.IsNaN(best)) { celsius = best; return true; }
            }
            catch { }
            return false;
        }

        // Walks ADL adapters and returns the index whose temperature reads sane, or -1.
        // adl2Context == IntPtr.Zero -> Overdrive5; otherwise Overdrive6 via ADL2.
        private int FindAdlTempAdapter(IntPtr adl2Context)
        {
            try
            {
                int count = 0;
                if (ADL_Adapter_NumberOfAdapters_Get(ref count) != 0 || count <= 0) return -1;
                int infoSize = Marshal.SizeOf<ADLAdapterInfo>();
                IntPtr buf = Marshal.AllocHGlobal(infoSize * count);
                try
                {
                    if (ADL_Adapter_AdapterInfo_Get(buf, infoSize * count) != 0) return -1;
                    for (int i = 0; i < count; i++)
                    {
                        var ai = Marshal.PtrToStructure<ADLAdapterInfo>(IntPtr.Add(buf, i * infoSize));
                        if (ai.iPresent == 0) continue;
                        if (_adlPciBus < 0) { _adlPciBus = ai.iBusNumber; _adlPciDevice = ai.iDeviceNumber; _adlPciFunction = ai.iFunctionNumber; }
                        var t = new ADLTemperature { iSize = Marshal.SizeOf<ADLTemperature>() };
                        int rc = adl2Context == IntPtr.Zero
                            ? ADL_Overdrive5_Temperature_Get(ai.iAdapterIndex, 0, ref t)
                            : ADL2_Overdrive6_Temperature_Get(adl2Context, ai.iAdapterIndex, ref t);
                        if (rc == 0 && AdlTempSane(t.iTemperature)) return ai.iAdapterIndex;
                    }
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            catch { }
            return -1;
        }

        private void WireNetworkGpuTiles()
        {
            var hand = new Cursor(StandardCursorType.Hand);
            if (_wifiTileBorder != null)
            {
                _wifiTileBorder.Cursor = hand;
                _wifiTileBorder.PointerPressed += (s, e) => ShowNetworkPanel("wifi");
            }
            if (_eth1TileBorder != null)
            {
                _eth1TileBorder.Cursor = hand;
                _eth1TileBorder.PointerPressed += (s, e) => ShowNetworkPanel("eth1");
            }
            if (_eth2TileBorder != null)
            {
                _eth2TileBorder.Cursor = hand;
                _eth2TileBorder.PointerPressed += (s, e) => ShowNetworkPanel("eth2");
            }
            if (_gpuTileBorder != null)
            {
                _gpuTileBorder.Cursor = hand;
                _gpuTileBorder.PointerPressed += (s, e) => ShowGpuPanel();
            }
        }

        private void SetupNetworkGpuContextMenus()
        {
            var netMenu = new ContextMenu();
            var netCopy = new MenuItem { Header = "Copy" };
            netCopy.Click += (s, e) => CopyNetworkStatsToClipboard();
            netMenu.Items.Add(netCopy);
            if (_netGraphBorder != null) _netGraphBorder.ContextMenu = netMenu;

            var gpuMenu = new ContextMenu();
            var gpuCopy = new MenuItem { Header = "Copy" };
            gpuCopy.Click += (s, e) => CopyGpuStatsToClipboard();
            gpuMenu.Items.Add(gpuCopy);
            if (_gpuDedMemBorder != null) _gpuDedMemBorder.ContextMenu = gpuMenu;
            if (_gpuSharedMemBorder != null) _gpuSharedMemBorder.ContextMenu = gpuMenu;
            if (_gpuEnginesGrid != null) _gpuEnginesGrid.ContextMenu = gpuMenu;
        }

        // ================= Panel switching =================

        private void ShowNetworkPanel(string key)
        {
            if (!_isInitialized) return;
            var t = _netAdapters.FirstOrDefault(a => a.Key == key);
            if (t == null || !t.Present) return;
            _activePanel = PerformancePanel.Network;
            _activeNetKey = key;

            if (_cpuView != null) _cpuView.IsVisible = false;
            if (_memoryView != null) _memoryView.IsVisible = false;
            if (_diskView != null) _diskView.IsVisible = false;
            if (_gpuView != null) _gpuView.IsVisible = false;
            if (_networkView != null) _networkView.IsVisible = true;
            if (_menuChangeGraphRoot != null) _menuChangeGraphRoot.IsEnabled = false;

            ClearMainTileHighlights();
            HighlightNetGpuTiles(key, false);

            if (_netBigHeader != null) _netBigHeader.Text = t.IsWifi ? "Wi-Fi" : (key == "eth2" ? "Ethernet 2" : "Ethernet");
            if (_netAdapterText != null) _netAdapterText.Text = t.Description;
            SetText(_metaNetAdapterName, t.Name);

            string ipv4 = GetAdapterIpv4(t);
            if (t.IsWifi)
            {
                SetText(_metaNetConnType, t.WifiPhy);
                SetText(_labelNetRow3, "SSID:");
                SetText(_labelNetRow4, "Signal strength:");
                SetText(_labelNetRow5, "IPv4 address:");
                SetText(_labelNetRow6, "Link speed (Receive/Transmit):");
                SetText(_metaNetRow5, ipv4);
                double mbps = t.LinkSpeedBps / 1_000_000.0;
                SetText(_metaNetRow6, mbps > 0 ? $"{mbps:F1}/{mbps:F1} (Mbps)" : "\u2014");
                RefreshWifiDetails(t);
            }
            else
            {
                SetText(_metaNetConnType, "Ethernet");
                SetText(_labelNetRow3, "IPv4 address:");
                SetText(_labelNetRow4, "IPv6 address:");
                SetText(_labelNetRow5, "Speed:");
                SetText(_labelNetRow6, "DNS servers:");
                SetText(_metaNetRow3, ipv4);
                SetText(_metaNetRow4, GetAdapterIpv6(t));
                SetText(_metaNetRow5, FormatLinkSpeed(t.LinkSpeedBps));
                SetText(_metaNetRow6, GetAdapterDns(t));
            }

            UpdateNetworkDetailStats(t);
            Dispatcher.UIThread.Post(() => RedrawAllCharts(), DispatcherPriority.Render);
        }

        private void ShowGpuPanel()
        {
            if (!_isInitialized) return;
            _activePanel = PerformancePanel.Gpu;

            if (_cpuView != null) _cpuView.IsVisible = false;
            if (_memoryView != null) _memoryView.IsVisible = false;
            if (_diskView != null) _diskView.IsVisible = false;
            if (_networkView != null) _networkView.IsVisible = false;
            if (_gpuView != null) _gpuView.IsVisible = true;
            if (_menuChangeGraphRoot != null) _menuChangeGraphRoot.IsEnabled = false;

            ClearMainTileHighlights();
            HighlightNetGpuTiles(null, true);

            if (_gpuBigHeader != null) _gpuBigHeader.Text = "GPU";
            if (_gpuNameText != null) _gpuNameText.Text = _gpuFullName;

            SampleGpuStats();
            Dispatcher.UIThread.Post(() => RedrawAllCharts(), DispatcherPriority.Render);
        }

        private void ClearMainTileHighlights()
        {
            // Clear CPU/Memory/Disk tiles when switching to Network/GPU
            // (SetActivePanel handles these, but ShowNetworkPanel/ShowGpuPanel bypass it)
            var trans = Brushes.Transparent;
            if (_cpuTileBorder != null)
            {
                _cpuTileBorder.Background = trans;
                _cpuTileBorder.BorderBrush = trans;
            }
            if (_memTileBorder != null)
            {
                _memTileBorder.Background = trans;
                _memTileBorder.BorderBrush = trans;
            }
            if (_diskTileBorder != null)
            {
                _diskTileBorder.Background = trans;
                _diskTileBorder.BorderBrush = trans;
            }
        }

        private void RefreshNetGpuTileHighlights()
        {
            // Re-apply network/GPU tile highlights after theme change
            // Called from main C# RefreshTileHighlights()
            string? netKey = (_activePanel == PerformancePanel.Network) ? _activeNetKey : null;
            bool gpuActive = (_activePanel == PerformancePanel.Gpu);
            HighlightNetGpuTiles(netKey, gpuActive);
        }

        private void HighlightNetGpuTiles(string? activeNetKey, bool gpuActive)
        {
            var selBg = new SolidColorBrush(_isDark ? Color.Parse("#2B3844") : Color.Parse("#E5F1FB"));
            var selBorder = new SolidColorBrush(_isDark ? Color.Parse("#4CC2FF") : Color.Parse("#70C0E7"));
            var trans = Brushes.Transparent;
            SetTileHighlight(_wifiTileBorder, activeNetKey == "wifi", selBg, selBorder, trans);
            SetTileHighlight(_eth1TileBorder, activeNetKey == "eth1", selBg, selBorder, trans);
            SetTileHighlight(_eth2TileBorder, activeNetKey == "eth2", selBg, selBorder, trans);
            SetTileHighlight(_gpuTileBorder, gpuActive, selBg, selBorder, trans);
        }

        private static void SetTileHighlight(Border? b, bool selected, IBrush selBg, IBrush selBorder, IBrush trans)
        {
            if (b == null) return;
            b.Background = selected ? selBg : trans;
            b.BorderBrush = selected ? selBorder : trans;
        }

        // ================= Sampling =================

        private void SampleNetworkAdapters()
        {
            try
            {
                foreach (var t in _netAdapters)
                {
                    if (!t.Present) continue;
                    var nic = FindNic(t);
                    if (nic == null) continue;
                    long sent, recv;
                    try
                    {
                        var st = nic.GetIPv4Statistics();
                        sent = st.BytesSent;
                        recv = st.BytesReceived;
                    }
                    catch { continue; }

                    DateTime now = DateTime.UtcNow;
                    if (t.HasPrev)
                    {
                        double sec = (now - t.PrevTime).TotalSeconds;
                        if (sec >= 0.4)
                        {
                            double sendBps = Math.Max(0.0, (sent - t.PrevSent) * 8.0 / sec);
                            double recvBps = Math.Max(0.0, (recv - t.PrevRecv) * 8.0 / sec);
                            t.LastSendBps = sendBps;
                            t.LastRecvBps = recvBps;
                            t.SendHist.Add(sendBps / 8.0);
                            t.RecvHist.Add(recvBps / 8.0);
                            if (t.SendHist.Count > 60) t.SendHist.RemoveAt(0);
                            if (t.RecvHist.Count > 60) t.RecvHist.RemoveAt(0);

                            double load = t.LinkSpeedBps > 0
                                ? Math.Clamp(((sendBps + recvBps) / t.LinkSpeedBps) * 100.0, 0.0, 100.0)
                                : 0.0;

                            if (t.Key == "wifi")
                            {
                                _wifiHistory.Add(load);
                                if (_wifiHistory.Count > 60) _wifiHistory.RemoveAt(0);
                                if (_miniWifiText != null) _miniWifiText.Text = $"S: {FormatBitRate(sendBps)} R: {FormatBitRate(recvBps)}";
                            }
                            else if (t.Key == "eth1")
                            {
                                _eth1History.Add(load);
                                if (_eth1History.Count > 60) _eth1History.RemoveAt(0);
                                if (_miniEth1Text != null) _miniEth1Text.Text = $"S: {FormatBitRate(sendBps)} R: {FormatBitRate(recvBps)}";
                            }
                            else if (t.Key == "eth2")
                            {
                                _eth2History.Add(load);
                                if (_eth2History.Count > 60) _eth2History.RemoveAt(0);
                                if (_miniEth2Text != null) _miniEth2Text.Text = $"S: {FormatBitRate(sendBps)} R: {FormatBitRate(recvBps)}";
                            }

                            if (_activePanel == PerformancePanel.Network && _activeNetKey == t.Key)
                                UpdateNetworkDetailStats(t);
                        }
                    }
                    t.PrevSent = sent;
                    t.PrevRecv = recv;
                    t.PrevTime = now;
                    t.HasPrev = true;
                }

                var wifi = _netAdapters.FirstOrDefault(a => a.Key == "wifi");
                if (wifi != null && wifi.Present
                    && _activePanel == PerformancePanel.Network && _activeNetKey == "wifi")
                    RefreshWifiDetails(wifi);
            }
            catch { }
        }

        // Fallback engine reader: wildcard counter + formatted array API.
        // Used when the provider rejects per-instance counter paths.
        private Dictionary<string, double> ReadGpuEngineWildcardArray(bool logIt)
        {
            var map = new Dictionary<string, double>();
            var log = new StringBuilder();
            try
            {
                if (_hPdhGpuEngineWildcard == IntPtr.Zero) return map;
                uint bufSize = 0;
                uint itemCount = 0;
                int res = PdhGetFormattedCounterArrayW(_hPdhGpuEngineWildcard, PDH_FMT_DOUBLE, ref bufSize, out itemCount, IntPtr.Zero);
                if (logIt) log.Append("array probe res=").Append(res).Append(" bufSize=").Append(bufSize).Append('\n');
                if (res != PDH_MORE_DATA || bufSize == 0) { if (logIt) WriteGpuDebugLog(log.ToString()); return map; }
                IntPtr buf = Marshal.AllocHGlobal((int)bufSize);
                try
                {
                    res = PdhGetFormattedCounterArrayW(_hPdhGpuEngineWildcard, PDH_FMT_DOUBLE, ref bufSize, out itemCount, buf);
                    if (logIt) log.Append("array res=").Append(res).Append(" itemCount=").Append(itemCount).Append('\n');
                    if (res != 0) { if (logIt) WriteGpuDebugLog(log.ToString()); return map; }
                    int itemSize = Marshal.SizeOf<PDH_FMT_COUNTERVALUE_ITEM_DOUBLE>();
                    for (int i = 0; i < itemCount; i++)
                    {
                        var item = Marshal.PtrToStructure<PDH_FMT_COUNTERVALUE_ITEM_DOUBLE>(IntPtr.Add(buf, i * itemSize));
                        if (item.CStatus != 0) continue;
                        string name = Marshal.PtrToStringUni(item.szName) ?? "";
                        if (name.Length == 0) continue;
                        map[name] = Math.Max(0.0, item.doubleValue);
                    }
                    if (logIt) log.Append("array mapped=").Append(map.Count).Append('\n');
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            catch (Exception ex) { if (logIt) log.Append("array EX ").Append(ex.Message).Append('\n'); }
            if (logIt) WriteGpuDebugLog(log.ToString());
            return map;
        }

        private void SampleGpuStats()
        {
            // ---- Per-engine utilization (per-instance PDH counters, else wildcard array) ----
            _gpuEnumTick++;
            if (_gpuEnumTick % 30 == 0) EnumerateGpuEngineInstances();
            // If the driver exposes no per-engine data at all, collapse the empty
            // area after 60s so the panel looks intentional instead of broken.
            if (_gpuEnumTick == 60 && _gpuEngines.Count == 0 && _gpuEnginesGrid != null)
                _gpuEnginesGrid.IsVisible = false;

            var aggregated = new Dictionary<string, (string engType, int engNum, double value)>();
            // Wildcard-only: PDH expands (*) on every collect, picking up current
            // processes automatically. Per-instance counters go stale when PIDs exit.
            // Like Task Manager: 3D instances sum into one "3D"; other engines keep
            // their per-type instance number (Compute 0, Compute 1, ...).
            if (_hPdhGpuEngineWildcard != IntPtr.Zero)
            {
                bool logIt = _gpuEngines.Count == 0;
                var typeInstanceIdx = new Dictionary<string, int>(StringComparer.Ordinal);
                foreach (var kv in ReadGpuEngineWildcardArray(logIt))
                {
                    var m = GpuEngRegex.Match(kv.Key);
                    if (!m.Success) continue;
                    string engType = m.Groups[2].Value;
                    if (engType == "3D" || engType == "Copy")
                    {
                        // Aggregate 3D and Copy (many instances -> one card)
                        if (aggregated.TryGetValue(engType, out var cur))
                            aggregated[engType] = (engType, 0, cur.value + kv.Value);
                        else
                            aggregated[engType] = (engType, 0, kv.Value);
                    }
                    else
                    {
                        if (!typeInstanceIdx.TryGetValue(engType, out int idx)) idx = 0;
                        typeInstanceIdx[engType] = idx + 1;
                        string key = engType + "_" + idx;
                        aggregated[key] = (engType, idx, kv.Value);
                    }
                }
            }

            // If per-engine PDH data is unavailable (broken provider), fall back to
            // a single total-utilization tracker from ADL so the panel isn't blank.
            if (aggregated.Count == 0 && TryGetGpuActivity(out double totalAct))
            {
                aggregated["GPU_Total"] = ("GPU", 0, totalAct);
            }

            // Filter to Task Manager-relevant engine types only. Hide driver-internal
            // engines (Timer, Security, High, etc.) that TM doesn't display.
            var tmEngines = new Dictionary<string, (string engType, int engNum, double value)>();
            foreach (var kv in aggregated)
            {
                string t = kv.Value.engType;
                if (t == "3D" || t == "Copy" || t == "Compute" ||
                    t == "VideoDecode" || t == "VideoEncode" || t == "VideoProcessing" ||
                    t == "Video")
                {
                    tmEngines[kv.Key] = kv.Value;
                }
            }
            // Limit to 4 engines max (TM default), prioritized by sort order
            var orderedKeys = tmEngines.Keys.OrderBy(k => GpuEngineSortOrder(tmEngines[k].engType)).Take(4).ToList();
            var limited = new Dictionary<string, (string engType, int engNum, double value)>();
            foreach (var k in orderedKeys) limited[k] = tmEngines[k];

            bool setChanged = limited.Count != _gpuEngines.Count;
            if (!setChanged)
            {
                foreach (var k in limited.Keys)
                {
                    if (!_gpuEngines.ContainsKey(k)) { setChanged = true; break; }
                }
            }

            double totalUtil = 0.0;
            foreach (var kv in limited)
            {
                // Task Manager's definition: busiest engine = overall utilization
                totalUtil = Math.Max(totalUtil, kv.Value.value);
                _gpuKnownEngines.Add(kv.Key);
                if (!_gpuEngines.TryGetValue(kv.Key, out var eng))
                {
                    string baseLabel = GpuEngineBaseLabel(kv.Value.engType);
                    string label = (kv.Value.engType == "3D" || kv.Value.engType == "Copy")
                        ? baseLabel
                        : baseLabel + " " + kv.Value.engNum;
                    eng = new GpuEngineTracker
                    {
                        Key = kv.Key,
                        Label = label,
                        SortOrder = GpuEngineSortOrder(kv.Value.engType) * 100 + kv.Value.engNum,
                    };
                    for (int i = 0; i < 60; i++) eng.History.Add(0.0);
                    _gpuEngines[kv.Key] = eng;
                }
                eng.LastValue = Math.Clamp(kv.Value.value, 0.0, 100.0);
                eng.History.Add(eng.LastValue);
                if (eng.History.Count > 60) eng.History.RemoveAt(0);
            }
            // Keep idle engines visible at 0% (like Task Manager) instead of removing them.
            // Only rebuild if the set of engines actually changed (new engine appeared).
            foreach (var k in _gpuEngines.Keys.ToList())
            {
                if (!limited.ContainsKey(k))
                {
                    // Engine no longer in top 4 or filtered out: remove it
                    _gpuEngines.Remove(k);
                    setChanged = true;
                }
                else
                {
                    var eng = _gpuEngines[k];
                    // If not in current sample, show 0 (idle)
                    if (!limited.TryGetValue(k, out var cur) || cur.value == 0)
                    {
                        // Keep existing value from history; don't force to 0 here
                        // (the value was already set above if present)
                    }
                }
            }
            if (setChanged) RebuildGpuEngineCards();
            if (_gpuEngines.Count > 0 && _gpuEnginesGrid != null && !_gpuEnginesGrid.IsVisible)
                _gpuEnginesGrid.IsVisible = true;

            double util = Math.Clamp(totalUtil, 0.0, 100.0);
            _gpuHistory.Add(util);
            if (_gpuHistory.Count > 60) _gpuHistory.RemoveAt(0);

            // ---- Memory ----
            double dedBytes = Math.Max(0.0, PdhReadWildcardSum(_hPdhGpuDedUsage));
            double sharedBytes = Math.Max(0.0, PdhReadWildcardSum(_hPdhGpuSharedUsage));
            if (_gpuDedLimitBytes <= 0.0 && _hPdhGpuDedLimit != IntPtr.Zero)
            {
                double lim = PdhReadWildcardSum(_hPdhGpuDedLimit);
                if (lim > 0.0) _gpuDedLimitBytes = lim;
            }
            if (_gpuSharedLimitBytes <= 0.0 && _hPdhGpuSharedLimit != IntPtr.Zero)
            {
                double lim = PdhReadWildcardSum(_hPdhGpuSharedLimit);
                if (lim > 0.0) _gpuSharedLimitBytes = lim;
            }
            _gpuDedHistory.Add(dedBytes);
            if (_gpuDedHistory.Count > 60) _gpuDedHistory.RemoveAt(0);
            _gpuSharedHistory.Add(sharedBytes);
            if (_gpuSharedHistory.Count > 60) _gpuSharedHistory.RemoveAt(0);

            // ---- Temperature (best effort, AMD ADL) ----
            if (TryGetGpuTemperature(out double tempC)) _gpuTempC = tempC;

            if (_miniGpuText != null)
                _miniGpuText.Text = !double.IsNaN(_gpuTempC)
                    ? $"{_gpuName}\n{util:F0}% ({_gpuTempC:F0} \u00B0C)"
                    : $"{_gpuName}\n{util:F0}%";

            if (_activePanel == PerformancePanel.Gpu)
            {
                if (_statGpuUtil != null) _statGpuUtil.Text = $"{util:F0}%";
                double memUsed = dedBytes + sharedBytes;
                double memTotal = _gpuDedLimitBytes + _gpuSharedLimitBytes;
                if (_statGpuMem != null)
                    _statGpuMem.Text = memTotal > 0.0
                        ? FormatGbPair(memUsed, memTotal)
                        : $"{memUsed / (1024.0*1024.0*1024.0):F1} GB";
                if (_statGpuDedicated != null)
                    _statGpuDedicated.Text = _gpuDedLimitBytes > 0.0
                        ? FormatGbPair(dedBytes, _gpuDedLimitBytes)
                        : $"{dedBytes / (1024.0*1024.0*1024.0):F1} GB";
                if (_statGpuShared != null)
                    _statGpuShared.Text = _gpuSharedLimitBytes > 0.0
                        ? FormatGbPair(sharedBytes, _gpuSharedLimitBytes)
                        : $"{sharedBytes / (1024.0*1024.0*1024.0):F1} GB";
                if (_statGpuTemp != null)
                    _statGpuTemp.Text = !double.IsNaN(_gpuTempC) ? $"{_gpuTempC:F0} \u00B0C" : "\u2014";
                if (_metaGpuLocation != null && _metaGpuLocation.Text == "\u2014" && _adlPciBus >= 0)
                    _metaGpuLocation.Text = $"PCI bus {_adlPciBus}, device {_adlPciDevice}, function {_adlPciFunction}";
            }
        }


        private void UpdateNetworkDetailStats(NetAdapterTracker t)
        {
            if (_statNetSend != null) _statNetSend.Text = FormatBitRate(t.LastSendBps);
            if (_statNetReceive != null) _statNetReceive.Text = FormatBitRate(t.LastRecvBps);
        }

        // ================= WLAN details =================

        private void RefreshWifiDetails(NetAdapterTracker t)
        {
            if (!(_activePanel == PerformancePanel.Network && _activeNetKey == t.Key && t.IsWifi)) return;
            try
            {
                if (TryGetWifiConnection(out string ssid, out uint signal, out uint phyType))
                {
                    SetText(_metaNetRow3, string.IsNullOrEmpty(ssid) ? "\u2014" : ssid);
                    SetText(_metaNetRow4, $"{signal}%");
                    t.WifiPhy = MapPhyType(phyType);
                    SetText(_metaNetConnType, t.WifiPhy);
                }
            }
            catch { }
        }

        private bool TryGetWifiConnection(out string ssid, out uint signalQuality, out uint phyType)
        {
            ssid = "";
            signalQuality = 0;
            phyType = 0;
            try
            {
                if (_wlanHandle == IntPtr.Zero)
                {
                    if (WlanOpenHandle(2, IntPtr.Zero, out _, out IntPtr h) != 0) return false;
                    _wlanHandle = h;
                }
                if (WlanEnumInterfaces(_wlanHandle, IntPtr.Zero, out IntPtr listPtr) != 0 || listPtr == IntPtr.Zero)
                    return false;
                try
                {
                    uint count = (uint)Marshal.ReadInt32(listPtr, 0);
                    int infoSize = Marshal.SizeOf<WLAN_INTERFACE_INFO>();
                    const int baseOffset = 8; // dwNumberOfItems + dwIndex
                    for (uint i = 0; i < count; i++)
                    {
                        IntPtr itemPtr = IntPtr.Add(listPtr, baseOffset + (int)i * infoSize);
                        var info = Marshal.PtrToStructure<WLAN_INTERFACE_INFO>(itemPtr);
                        if (info.isState != 1) continue; // wlan_interface_state_connected
                        Guid g = info.InterfaceGuid;
                        if (WlanQueryInterface(_wlanHandle, ref g, WLAN_INTF_OPCODE.wlan_intf_opcode_current_connection,
                                IntPtr.Zero, out _, out IntPtr dataPtr, IntPtr.Zero) != 0 || dataPtr == IntPtr.Zero)
                            continue;
                        try
                        {
                            var conn = Marshal.PtrToStructure<WLAN_CONNECTION_ATTRIBUTES>(dataPtr);
                            var dot11 = conn.wlanAssociationAttributes.dot11Ssid;
                            int len = (int)Math.Min(dot11.uSSIDLength, 32u);
                            if (len > 0 && dot11.ucSSID != null)
                                ssid = Encoding.UTF8.GetString(dot11.ucSSID, 0, len);
                            signalQuality = conn.wlanAssociationAttributes.wlanSignalQuality;
                            phyType = conn.wlanAssociationAttributes.dot11PhyType;
                            return true;
                        }
                        finally { WlanFreeMemory(dataPtr); }
                    }
                }
                finally { WlanFreeMemory(listPtr); }
            }
            catch { }
            return false;
        }

        private static string MapPhyType(uint phyType)
        {
            return phyType switch
            {
                4 => "802.11a",
                5 => "802.11b",
                6 => "802.11g",
                7 => "802.11n",
                8 => "802.11ac",
                10 => "802.11ax",
                _ => "802.11",
            };
        }

        // ================= Adapter info helpers =================

        private static NetworkInterface? FindNic(NetAdapterTracker t)
        {
            if (!t.Present) return null;
            try { return NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n => n.Id == t.NicId); }
            catch { return null; }
        }

        private static string GetAdapterIpv4(NetAdapterTracker t)
        {
            try
            {
                var props = FindNic(t)?.GetIPProperties();
                if (props != null)
                {
                    foreach (var ua in props.UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily == AddressFamily.InterNetwork)
                            return ua.Address.ToString();
                    }
                }
            }
            catch { }
            return "\u2014";
        }

        private static string GetAdapterIpv6(NetAdapterTracker t)
        {
            try
            {
                var props = FindNic(t)?.GetIPProperties();
                if (props != null)
                {
                    foreach (var ua in props.UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily == AddressFamily.InterNetworkV6 && !ua.Address.IsIPv6LinkLocal)
                            return ua.Address.ToString();
                    }
                }
            }
            catch { }
            return "\u2014";
        }

        private static string GetAdapterDns(NetAdapterTracker t)
        {
            try
            {
                var props = FindNic(t)?.GetIPProperties();
                if (props != null)
                {
                    foreach (var d in props.DnsAddresses)
                    {
                        if (d.AddressFamily == AddressFamily.InterNetwork)
                            return d.ToString();
                    }
                    foreach (var d in props.DnsAddresses)
                        return d.ToString();
                }
            }
            catch { }
            return "\u2014";
        }

        // ================= Drawing =================

        private void RedrawNetworkCharts()
        {
            var t = _netAdapters.FirstOrDefault(a => a.Key == _activeNetKey);
            if (t == null) return;

            double peakBytes = 0.0;
            foreach (var v in t.SendHist) peakBytes = Math.Max(peakBytes, v);
            foreach (var v in t.RecvHist) peakBytes = Math.Max(peakBytes, v);
            var (maxBytes, label) = GetNetScale(peakBytes * 8.0);
            if (_netGraphScaleMax != null) _netGraphScaleMax.Text = label;
            if (_netGraphScaleTime != null)
                _netGraphScaleTime.Text = _updateIntervalSec == 4 ? "4 minutes" : "60 seconds";

            var sendNorm = new List<double>();
            var recvNorm = new List<double>();
            foreach (var b in t.SendHist) sendNorm.Add(Math.Clamp(b / maxBytes * 100.0, 0.0, 100.0));
            foreach (var b in t.RecvHist) recvNorm.Add(Math.Clamp(b / maxBytes * 100.0, 0.0, 100.0));

            Color recvLine = _isDark ? Color.Parse("#E8A33D") : Color.Parse("#D08836");
            Color recvFill = _isDark ? Color.FromArgb(0x30, 0xE8, 0xA3, 0x3D) : Color.FromArgb(0x28, 0xD0, 0x88, 0x36);
            Color sendLine = _isDark ? Color.Parse("#C47A35") : Color.Parse("#8E5A23");
            DrawDualChart(_netGraphCanvas, sendNorm, recvNorm, sendLine, recvLine, recvFill);
        }

        private void RedrawGpuCharts()
        {
            Color line = _isDark ? Color.Parse("#4CC2FF") : Color.Parse("#1070B8");
            Color fill = _isDark ? Color.FromArgb(0x25, 0x4C, 0xC2, 0xFF) : Color.FromArgb(0x1F, 0x10, 0x70, 0xB8);

            // Slot-based engine rendering (4 fixed slots like Task Manager)
            for (int slot = 0; slot < 4; slot++)
            {
                string key = _gpuEngineSlots[slot];
                _gpuEngines.TryGetValue(key, out var eng);
                double val = eng?.LastValue ?? 0.0;
                var hist = eng?.History;
                if (_gpuSlotPcts[slot] != null) _gpuSlotPcts[slot]!.Text = $"{val:F0}%";
                if (_gpuSlotCanvases[slot] != null)
                {
                    if (hist != null && hist.Count > 0)
                        DrawChart(_gpuSlotCanvases[slot]!, hist, null, line, fill, isMini: false);
                    else
                        DrawChart(_gpuSlotCanvases[slot]!, new List<double>(), null, line, fill, isMini: false);
                }
            }

            double dedPeak = 0.0;
            foreach (var b in _gpuDedHistory) dedPeak = Math.Max(dedPeak, b);
            double dedScale = _gpuDedLimitBytes > 0.0 ? _gpuDedLimitBytes : Math.Max(dedPeak, 1.0);
            if (_gpuDedMemScaleMax != null) _gpuDedMemScaleMax.Text = FormatBytesShort(dedScale);
            var dedNorm = new List<double>();
            foreach (var b in _gpuDedHistory) dedNorm.Add(Math.Clamp(b / dedScale * 100.0, 0.0, 100.0));
            DrawChart(_gpuDedMemCanvas, dedNorm, null, line, fill, isMini: false);

            double sharedPeak = 0.0;
            foreach (var b in _gpuSharedHistory) sharedPeak = Math.Max(sharedPeak, b);
            double sharedScale = _gpuSharedLimitBytes > 0.0 ? _gpuSharedLimitBytes : Math.Max(sharedPeak, 1.0);
            if (_gpuSharedMemScaleMax != null) _gpuSharedMemScaleMax.Text = FormatBytesShort(sharedScale);
            var sharedNorm = new List<double>();
            foreach (var b in _gpuSharedHistory) sharedNorm.Add(Math.Clamp(b / sharedScale * 100.0, 0.0, 100.0));
            DrawChart(_gpuSharedMemCanvas, sharedNorm, null, line, fill, isMini: false);
        }


        private void DrawDualChart(Canvas? canvas, List<double> sendNorm, List<double> recvNorm,
            Color sendLine, Color recvLine, Color recvFill)
        {
            if (canvas == null) return;
            canvas.Children.Clear();
            double w = canvas.Bounds.Width;
            double h = canvas.Bounds.Height;
            if (double.IsNaN(w) || w <= 4) w = 500;
            if (double.IsNaN(h) || h <= 4) h = 220;

            var gridBrush = new SolidColorBrush(_isDark ? Color.Parse("#3A2E1F") : Color.Parse("#F3EAD9"));
            for (int i = 1; i < 10; i++)
            {
                double y = Math.Round(h * (i / 10.0)) + 0.5;
                canvas.Children.Add(new Line { StartPoint = new Point(0, y), EndPoint = new Point(w, y), Stroke = gridBrush, StrokeThickness = 1 });
            }
            for (int i = 1; i < 10; i++)
            {
                double x = Math.Round(w * (i / 10.0)) + 0.5;
                canvas.Children.Add(new Line { StartPoint = new Point(x, 0), EndPoint = new Point(x, h), Stroke = gridBrush, StrokeThickness = 1 });
            }

            int n = Math.Max(sendNorm.Count, recvNorm.Count);
            if (n == 0) return;
            double step = w / 59.0;
            double startX = w - ((n - 1) * step);

            if (recvNorm.Count > 0)
            {
                var recvFillPts = new Avalonia.Collections.AvaloniaList<Point>();
                var recvLinePts = new Avalonia.Collections.AvaloniaList<Point>();
                recvFillPts.Add(new Point(startX, h));
                for (int i = 0; i < recvNorm.Count; i++)
                {
                    double x = startX + (i * step);
                    double y = (h - 1.0) - (Math.Clamp(recvNorm[i], 0.0, 100.0) / 100.0 * (h - 2.0));
                    recvLinePts.Add(new Point(x, y));
                    recvFillPts.Add(new Point(x, y));
                }
                recvFillPts.Add(new Point(startX + ((recvNorm.Count - 1) * step), h));
                canvas.Children.Add(new Polygon { Points = recvFillPts, Fill = new SolidColorBrush(recvFill) });
                canvas.Children.Add(new Polyline { Points = recvLinePts, Stroke = new SolidColorBrush(recvLine), StrokeThickness = 1.2 });
            }

            if (sendNorm.Count > 0)
            {
                var sendPts = new Avalonia.Collections.AvaloniaList<Point>();
                for (int i = 0; i < sendNorm.Count; i++)
                {
                    double x = startX + (i * step);
                    double y = (h - 1.0) - (Math.Clamp(sendNorm[i], 0.0, 100.0) / 100.0 * (h - 2.0));
                    sendPts.Add(new Point(x, y));
                }
                canvas.Children.Add(new Polyline { Points = sendPts, Stroke = new SolidColorBrush(sendLine), StrokeThickness = 1.0 });
            }
        }

        private static (double maxBytes, string label) GetNetScale(double peakBps)
        {
            double[] thresholds = { 100e3, 1e6, 10e6, 100e6, 1e9, 10e9 };
            string[] labels = { "100 Kbps", "1 Mbps", "10 Mbps", "100 Mbps", "1 Gbps", "10 Gbps" };
            for (int i = 0; i < thresholds.Length; i++)
            {
                if (peakBps <= thresholds[i])
                    return (thresholds[i] / 8.0, labels[i]);
            }
            double g = Math.Ceiling(peakBps / 1e9);
            return (g * 1e9 / 8.0, $"{g:F0} Gbps");
        }

        private static string FormatBitRate(double bps)
        {
            if (bps < 1000.0) return $"{Math.Round(bps)} bps";
            if (bps < 1_000_000.0) return $"{bps / 1000.0:F1} Kbps";
            if (bps < 1_000_000_000.0) return $"{bps / 1_000_000.0:F1} Mbps";
            return $"{bps / 1_000_000_000.0:F2} Gbps";
        }

        private static string FormatBytesShort(double bytes)
        {
            if (bytes < 1024.0) return $"{Math.Round(bytes)} B";
            if (bytes < 1024.0 * 1024.0) return $"{bytes / 1024.0:F1} KB";
            if (bytes < 1024.0 * 1024.0 * 1024.0) return $"{bytes / (1024.0 * 1024.0):F1} MB";
            return $"{bytes / (1024.0 * 1024.0 * 1024.0):F1} GB";
        }

        // Task Manager style: "1.3/4.5 GB" (unit only at end, values in GB)
        private static string FormatGbPair(double usedBytes, double totalBytes)
        {
            const double GB = 1024.0 * 1024.0 * 1024.0;
            return $"{usedBytes / GB:F1}/{totalBytes / GB:F1} GB";
        }

        private static string FormatLinkSpeed(double bps)
        {
            if (bps >= 1_000_000_000.0) return $"{bps / 1_000_000_000.0:F1} Gbps";
            if (bps >= 1_000_000.0) return $"{bps / 1_000_000.0:F0} Mbps";
            if (bps >= 1_000.0) return $"{bps / 1_000.0:F0} Kbps";
            return "\u2014";
        }

        // ================= Clipboard =================

        private async void CopyNetworkStatsToClipboard()
        {
            try
            {
                var t = _netAdapters.FirstOrDefault(a => a.Key == _activeNetKey);
                if (t == null) return;
                string info = $"{_netBigHeader?.Text}\r\n\r\n{t.Description}\r\n\r\n" +
                              $"Adapter name:\t{t.Name}\r\n" +
                              $"Connection type:\t{_metaNetConnType?.Text}\r\n" +
                              $"{_labelNetRow3?.Text}\t{_metaNetRow3?.Text}\r\n" +
                              $"{_labelNetRow4?.Text}\t{_metaNetRow4?.Text}\r\n" +
                              $"{_labelNetRow5?.Text}\t{_metaNetRow5?.Text}\r\n" +
                              $"{_labelNetRow6?.Text}\t{_metaNetRow6?.Text}\r\n\r\n" +
                              $"Send\t{_statNetSend?.Text}\r\n" +
                              $"Receive\t{_statNetReceive?.Text}";

                var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
                if (clipboard != null) await clipboard.SetTextAsync(info);
            }
            catch { }
        }

        private async void CopyGpuStatsToClipboard()
        {
            try
            {
                string info = $"GPU\r\n\r\n{_gpuFullName}\r\n\r\n" +
                              $"Dedicated GPU memory:\t{_statGpuDedicated?.Text}\r\n" +
                              $"Shared GPU memory:\t{_statGpuShared?.Text}\r\n" +
                              $"Driver version:\t{_metaGpuDriverVer?.Text}\r\n" +
                              $"Driver date:\t{_metaGpuDriverDate?.Text}\r\n" +
                              $"DirectX version:\t{_metaGpuDx?.Text}\r\n" +
                              $"Physical location:\t{_metaGpuLocation?.Text}\r\n" +
                              $"Hardware reserved memory:\t{_metaGpuHwReserved?.Text}\r\n\r\n" +
                              $"Utilization\t{_statGpuUtil?.Text}\r\n" +
                              $"GPU Memory\t{_statGpuMem?.Text}";

                var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
                if (clipboard != null) await clipboard.SetTextAsync(info);
            }
            catch { }
        }


        private void ApplyNetworkGpuTheme()
        {
            var textHigh = new SolidColorBrush(_isDark ? Color.Parse("#FFFFFF") : Color.Parse("#000000"));
            var textMid = new SolidColorBrush(_isDark ? Color.Parse("#A0A0A0") : Color.Parse("#555555"));
            var mainBg = new SolidColorBrush(_isDark ? Color.Parse("#191919") : Color.Parse("#FFFFFF"));
            var netBorder = new SolidColorBrush(_isDark ? Color.Parse("#A86C2B") : Color.Parse("#8E5A23"));
            var gpuBorder = new SolidColorBrush(_isDark ? Color.Parse("#2A5A84") : Color.Parse("#70A5CC"));

            SetFg(_netBigHeader, textHigh);
            foreach (var tb in new TextBlock?[]
            {
                _netAdapterText, _netGraphHeaderLabel, _netGraphScaleMax, _netGraphScaleTime, _netGraphScaleZero,
                _labelNetSend, _labelNetReceive, _labelNetAdapterName, _labelNetConnType,
                _labelNetRow3, _labelNetRow4, _labelNetRow5, _labelNetRow6
            }) SetFg(tb, textMid);
            foreach (var tb in new TextBlock?[]
            {
                _statNetSend, _statNetReceive, _metaNetAdapterName, _metaNetConnType,
                _metaNetRow3, _metaNetRow4, _metaNetRow5, _metaNetRow6
            }) SetFg(tb, textHigh);
            if (_netGraphBorder != null)
            {
                _netGraphBorder.Background = mainBg;
                _netGraphBorder.BorderBrush = netBorder;
            }

            SetFg(_gpuBigHeader, textHigh);
            foreach (var tb in new TextBlock?[]
            {
                _gpuNameText, _gpuDedMemHeaderLabel, _gpuDedMemScaleMax,
                _gpuSharedMemHeaderLabel, _gpuSharedMemScaleMax,
                _labelGpuUtil, _labelGpuMem, _labelGpuDedicated, _labelGpuShared, _labelGpuTemp,
                _labelGpuDriverVer, _labelGpuDriverDate, _labelGpuDx, _labelGpuLocation, _labelGpuHwReserved
            }) SetFg(tb, textMid);
            foreach (var tb in new TextBlock?[]
            {
                _statGpuUtil, _statGpuMem, _statGpuDedicated, _statGpuShared, _statGpuTemp,
                _metaGpuDriverVer, _metaGpuDriverDate, _metaGpuDx, _metaGpuLocation, _metaGpuHwReserved
            }) SetFg(tb, textHigh);
            if (_gpuDedMemBorder != null)
            {
                _gpuDedMemBorder.Background = mainBg;
                _gpuDedMemBorder.BorderBrush = gpuBorder;
            }
            if (_gpuSharedMemBorder != null)
            {
                _gpuSharedMemBorder.Background = mainBg;
                _gpuSharedMemBorder.BorderBrush = gpuBorder;
            }
            foreach (var eng in _gpuEngines.Values)
            {
                if (eng.Card != null)
                {
                    eng.Card.Background = mainBg;
                    eng.Card.BorderBrush = gpuBorder;
                }
            }
            // Slot-based pct labels
            for (int slot = 0; slot < 4; slot++)
            {
                if (_gpuSlotPcts[slot] != null) _gpuSlotPcts[slot]!.Foreground = textMid;
            }

        }

        private static void SetFg(TextBlock? tb, IBrush brush)
        {
            if (tb != null) tb.Foreground = brush;
        }

        private static void SetText(TextBlock? tb, string s)
        {
            if (tb != null) tb.Text = s;
        }
    }
}

'@
Set-Content -LiteralPath (Join-Path $Dir 'MainWindow.axaml.cs') -Value $mwCs.Replace('__APPNAME__', $Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'MainWindow.NetworkGpu.cs') -Value $mwNetGpuCs.Replace('__APPNAME__', $Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'MainWindow.Processes.cs') -Value $mwProcCs.Replace('__APPNAME__', $Name) -Encoding UTF8
}

function New-Project([string]$ExePath, [string]$Name, [string]$Dir) {
    Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('new', 'console', '-n', $Name, '-o', $Dir)
    if (-not (Test-Path -LiteralPath (Join-Path $Dir ($Name + '.csproj')))) {
        Throw-Code 4 'The template reported success but the project workspace could not be created.'
    }
}

function Publish-Project([string]$ExePath, [string]$Dir, [string]$Out) {
    Write-Warn2 'Avalonia packages (~100 MB) download on first restore; this may take 2-5 minutes.'
    Write-Info 'Restoring packages...'
    Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('restore', $Dir, '-r', 'win-x64', '--interactive', 'false')
    Write-Info 'Compiling and publishing self-contained binary...'
    Invoke-DotNet -ExePath $ExePath -FailCode 5 -CliArgs @('publish', $Dir, '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-o', $Out, '/p:UseSharedCompilation=false', '/p:NodeReuse=false')
}

function Start-PublishedApp([string]$Exe, [string]$WorkDir) {
    try {
        Start-Process -FilePath $Exe -WorkingDirectory $WorkDir
        return $true
    } catch {
        Write-Warn2 "Auto-launch failed: $($_.Exception.Message)"
        Write-Warn2 "Start manually by double-clicking: $Exe"
        return $false
    }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $ProjectName = Get-SafeName $ProjectName
    if ([string]::IsNullOrWhiteSpace($BaseDir)) {
        if ($PSScriptRoot) { $BaseDir = $PSScriptRoot } else { $BaseDir = (Get-Location).Path }
    }
    if ($BaseDir.EndsWith('\') -and $BaseDir.Length -gt 3) { $BaseDir = $BaseDir.TrimEnd('\') }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Throw-Code 1 'The LOCALAPPDATA environment variable is not set.' }

    $ProjectDir = Join-Path $BaseDir $ProjectName
    $PublishDir = Join-Path $ProjectDir 'publish'

    # Terminate any running instance of the app so it doesn't lock the executable
    Get-Process -Name $ProjectName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host "  Bootstrap: building '$ProjectName' (Authentic Win10 Task Manager)" -ForegroundColor Cyan
    Write-Host '================================================================' -ForegroundColor Cyan

    Initialize-Tls
    $Script:StageName = 'Environment checks'
    Write-Stage '1/8' 'Initializing TLS and checking free disk space'
    Write-Info "Running on Windows PowerShell $($PSVersionTable.PSVersion); TLS 1.2+ enforced; target framework net8.0."
    Test-DiskSpace -Path $BaseDir

    $Script:StageName = 'Clean slate'
    Write-Stage '2/8' "Preparing clean workspace: $ProjectDir"
    if (Test-Path -LiteralPath $ProjectDir) {
        Write-Info 'Existing project folder found; destroying it...'
        if (-not (Remove-Folder -Path $ProjectDir)) {
            Write-Err2 "Could not delete '$ProjectDir' after repeated attempts."
            exit 7
        }
        Write-Ok 'Old project folder removed and verified gone.'
    }

    try { [void][IO.Directory]::CreateDirectory($BaseDir) } catch { Throw-Code 7 "Could not create base directory '$BaseDir': $($_.Exception.Message)" }
    try { [void][IO.Directory]::CreateDirectory($ProjectDir) } catch { Throw-Code 7 "Could not create project directory '$ProjectDir': $($_.Exception.Message)" }
    if (-not (Test-Path -LiteralPath $ProjectDir)) { Throw-Code 7 "Project directory '$ProjectDir' could not be created." }
    Write-Ok 'Fresh project directory is ready.'

    $Script:StageName = '.NET SDK detection/install'
    Write-Stage '3/8' 'Detecting or installing .NET 8 SDK (user-local, zero elevation)'
    $DotNetExe = Find-DotNetSdk
    if ($DotNetExe) {
        $sdkSource = 'pre-existing .NET 8 SDK'
        Write-Ok "Using verified 8.x SDK: $DotNetExe"
    } else {
        Write-Info "No functional .NET 8 SDK detected; installing user-local copy under: $($Script:DotnetDir)"
        Install-DotNetSdk
        Set-DotNetEnv -Dir $Script:DotnetDir
        $DotNetExe = Join-Path $Script:DotnetDir 'dotnet.exe'
        if (-not (Test-SdkWorks -DotNetPath $DotNetExe)) {
            Write-Warn2 'SDK verification failed. Wiping directory and reinstalling once...'
            if (-not (Remove-Folder -Path $Script:DotnetDir)) { Throw-Code 3 "Could not delete SDK directory '$($Script:DotnetDir)'." }
            Install-DotNetSdk
            Set-DotNetEnv -Dir $Script:DotnetDir
            if (-not (Test-SdkWorks -DotNetPath $DotNetExe)) { Throw-Code 3 'The .NET 8 SDK was installed but still fails verification.' }
        }
        $sdkSource = 'freshly installed user-local SDK'
    }

    Set-DotNetEnv -Dir (Split-Path $DotNetExe)
    $v = (& $DotNetExe --version)
    if ($LASTEXITCODE -ne 0) { Throw-Code 3 "dotnet --version failed with exit code $LASTEXITCODE." }
    Write-Ok "Verified .NET SDK version: $v ($sdkSource)"

    $Script:StageName = 'Project creation'
    Write-Stage '4/8' 'Initializing project workspace structure'
    New-Project -ExePath $DotNetExe -Name $ProjectName -Dir $ProjectDir
    Write-Ok 'Workspace initialized.'

    $Script:StageName = 'Writing sources'
    Write-Stage '5/8' 'Writing authentic Win10 Task Manager source files'
    Write-SourceFiles -Dir $ProjectDir -Name $ProjectName
    Write-Ok 'All Task Manager source files written.'

    $Script:StageName = 'Restore/build/publish'
    Write-Stage '6/8' 'Restoring Win32 Avalonia packages and publishing self-contained executable'
    Publish-Project -ExePath $DotNetExe -Dir $ProjectDir -Out $PublishDir
    Write-Ok 'Publish completed.'

    $Script:StageName = 'Artifact verification'
    Write-Stage '7/8' 'Verifying published artifact executable'
    $exe = Join-Path $PublishDir ($ProjectName + '.exe')
    if (-not (Test-Path -LiteralPath $exe)) { Start-Sleep -Seconds 3 }
    if (-not (Test-Path -LiteralPath $exe)) { Throw-Code 5 "Publish reported success but '$exe' was not found. Antivirus may have quarantined it." }
    $size = (Get-Item -LiteralPath $exe).Length
    if ($size -lt 1MB) { Throw-Code 5 "Published exe is only $size bytes (too small for self-contained binary)." }
    $sizeMb = [math]::Round($size / 1MB, 1)
    Write-Ok "Executable verified: $exe ($sizeMb MB)"

    $Script:StageName = 'Launch'
    if ($NoLaunch) {
        Write-Stage '8/8' 'Auto-launch skipped (-NoLaunch provided)'
        Write-Info "Run the app by double-clicking: $exe"
    } else {
        Write-Stage '8/8' 'Launching freshly built Task Manager application'
        if (-not (Start-PublishedApp -Exe $exe -WorkDir $PublishDir)) { exit 6 }
    }

    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Green
    Write-Host '  SUCCESS - application built, verified, and ready' -ForegroundColor Green
    Write-Host '================================================================' -ForegroundColor Green
    Write-Ok "Project workspace : $ProjectDir"
    Write-Ok "Publish directory : $PublishDir"
    Write-Ok "Self-contained EXE: $exe ($sizeMb MB)"
    Write-Ok "SDK source        : $sdkSource"
    Write-Ok ("Build time        : {0:hh\:mm\:ss}" -f $sw.Elapsed)
    exit 0
}
catch {
    $code = 1
    if ($_.Exception.Message -match '^\[(\d+)\]') { $code = [int]$Matches[1] }
    Write-Host ''
    Write-Err2 "FAILED during stage: $($Script:StageName)"
    Write-Err2 "Error: $($_.Exception.Message)"
    Write-Err2 'Next step: address the error above and re-run.'
    exit $code
}
finally {
    if ($Script:InstallerPath -and (Test-Path -LiteralPath $Script:InstallerPath)) {
        Remove-Item -LiteralPath $Script:InstallerPath -Force -ErrorAction SilentlyContinue
    }
}
