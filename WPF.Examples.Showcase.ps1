param([string]$ProjectName='ControlGallery',[ValidateSet('Auto','Console','WPF')][string]$ProjectType='WPF',[string]$BaseDir='',[switch]$NoLaunch,[int]$MaxRetries=3)
 $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
 $Script:StageName='Initialization';$Script:InstallerPath='';$Script:DotnetDir=Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet';$Script:AppKind='WPF'
function Write-Info([string]$m){Write-Host $m -ForegroundColor Cyan}
function Write-Ok([string]$m){Write-Host $m -ForegroundColor Green}
function Write-Warn2([string]$m){Write-Host $m -ForegroundColor Yellow}
function Write-Err2([string]$m){Write-Host $m -ForegroundColor Red}
function Throw-Code([int]$c,[string]$m){throw "[$c] $m"}
function Write-Stage([string]$n,[string]$m){Write-Host '';Write-Host "[$n] $m" -ForegroundColor Cyan}
function Initialize-Tls{try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12}catch{};try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13}catch{}}
function Get-SafeName([string]$n){
 $n=[regex]::Replace($n,'[^A-Za-z0-9_]','');if($n.Length -eq 0){return 'GeneratedApp'};if($n -match '^\d'){$n='App'+$n};$n=$n.Substring(0,1).ToUpperInvariant()+$n.Substring(1)
 $kw=@('abstract','as','async','await','base','bool','break','byte','case','catch','char','checked','class','const','continue','decimal','default','delegate','do','double','else','enum','event','explicit','extern','false','finally','fixed','float','for','foreach','goto','if','implicit','in','init','int','interface','internal','is','lock','long','namespace','new','null','object','operator','out','override','params','private','protected','public','readonly','record','ref','return','sbyte','sealed','short','sizeof','stackalloc','static','string','struct','switch','this','throw','true','try','typeof','uint','ulong','unchecked','unsafe','ushort','using','var','virtual','void','volatile','while');if($kw -contains $n.ToLowerInvariant()){$n=$n+'App'}
return $n}
function Remove-Folder([string]$Path){
 $p=$Path.TrimEnd('\');if(-not (Test-Path -LiteralPath $p)){return $true}
for($i=1;$i -le 3;$i++){try{Get-ChildItem -LiteralPath $p -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {try{$_.Attributes=[IO.FileAttributes]::Normal}catch{}};Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop}catch{Start-Sleep -Seconds ([math]::Min(30,5*$i))};if(-not (Test-Path -LiteralPath $p)){return $true}}
try{& cmd.exe /c rd /s /q "$p" | Out-Null}catch{}
 $gone=-not (Test-Path -LiteralPath $p);if(-not $gone){Write-Warn2 "cmd rd /s /q exited with code $LASTEXITCODE but '$p' still exists."}
return $gone}
function Find-DotNetSdk{
 $cand=@();$local=Join-Path $Script:DotnetDir 'dotnet.exe';if(Test-Path -LiteralPath $local){$cand+=$local};$resolved=Get-Command dotnet.exe -ErrorAction SilentlyContinue;if($resolved -and ($cand -notcontains $resolved.Source)){$cand+=$resolved.Source}
foreach($d in $cand){$prev=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$null=(& $d --version 2>$null);if($LASTEXITCODE -eq 0){$sdks=@(& $d --list-sdks 2>$null);if($LASTEXITCODE -eq 0 -and (@($sdks | Where-Object {$_ -match '^8\.'}).Count -gt 0)){return $d}}}catch{}finally{$ErrorActionPreference=$prev}}
return $null}
function Test-SdkWorks([string]$DotNetPath){
if([string]::IsNullOrWhiteSpace($DotNetPath) -or -not (Test-Path -LiteralPath $DotNetPath)){return $false}
 $prev=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$null=(& $DotNetPath --version 2>$null);if($LASTEXITCODE -ne 0){return $false};$sdks=@(& $DotNetPath --list-sdks 2>$null);if($LASTEXITCODE -ne 0){return $false};return (@($sdks | Where-Object {$_ -match '^8\.'}).Count -gt 0)}catch{return $false}finally{$ErrorActionPreference=$prev}}
function Save-FileWithRetry([string]$Url,[string]$Dest){
for($i=1;$i -le $MaxRetries;$i++){if(Test-Path -LiteralPath $Dest){Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue}
try{if($env:HTTPS_PROXY){Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120 -Proxy $env:HTTPS_PROXY -ErrorAction Stop}else{Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop};if((Test-Path -LiteralPath $Dest) -and ((Get-Item -LiteralPath $Dest).Length -gt 1000)){$head=((Get-Content -LiteralPath $Dest -TotalCount 5 -ErrorAction SilentlyContinue) -join ' ');if($head -notmatch '(?i)<\s*html|<!doctype'){return $true}}}catch{}
Write-Warn2 "Download attempt $i failed for: $Url";if($i -lt $MaxRetries){Write-Warn2 "Retrying in $([math]::Min(30,5*$i)) seconds...";Start-Sleep -Seconds ([math]::Min(30,5*$i))}}
return $false}
function Install-DotNetSdk{
 $Script:InstallerPath=Join-Path $env:TEMP 'dotnet-install.ps1';$urls=@('https://dot.net/v1/dotnet-install.ps1','https://raw.githubusercontent.com/dotnet/install-scripts/main/src/dotnet-install.ps1');$got=$false
foreach($u in $urls){if(Save-FileWithRetry -Url $u -Dest $Script:InstallerPath){$got=$true;break}}
if(-not $got){Throw-Code 2 "Could not download dotnet-install.ps1 from any known mirror (dot.net or raw.githubusercontent.com) after repeated retries. This machine has no usable .NET 8 SDK, so internet access is required. Check connectivity, proxy and firewall settings, then re-run."}
try{Unblock-File -LiteralPath $Script:InstallerPath -ErrorAction SilentlyContinue}catch{}
Write-Info "Installing the .NET 8 SDK user-local (no elevation) under: $($Script:DotnetDir)"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:InstallerPath -Channel 8.0 -Architecture x64 -InstallDir $Script:DotnetDir
if($LASTEXITCODE -ne 0){Throw-Code 3 "dotnet-install.ps1 exited with code $LASTEXITCODE. Likely causes: proxy or TLS interception blocking the download, antivirus interference, or insufficient disk space. Address the cause and re-run."}}
function Set-DotNetEnv([string]$Dir){
if(-not (Test-Path -LiteralPath $Dir)){Throw-Code 3 "Expected dotnet directory '$Dir' does not exist after installation."}
 $env:DOTNET_ROOT=$Dir;$env:DOTNET_MULTILEVEL_LOOKUP='0';$env:DOTNET_NOLOGO='1';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';if(@($env:Path -split ';') -notcontains $Dir){$env:Path="$Dir;$env:Path"}}
function Invoke-DotNet{param([string]$ExePath,[int]$FailCode=5,[string[]]$CliArgs=@());& $ExePath @CliArgs;if($LASTEXITCODE -ne 0){Throw-Code $FailCode "dotnet $($CliArgs -join ' ') failed with exit code $LASTEXITCODE. Review the template/compiler output above for the exact cause."}}
function Test-DiskSpace([string]$Path){
 $gb=$null;try{$di=New-Object IO.DriveInfo($Path.Substring(0,1));if($di.IsReady){$gb=[math]::Round($di.AvailableFreeSpace/1GB,2)}}catch{}
if($null -eq $gb){Write-Warn2 'Could not determine free disk space for this path (unusual or network location); continuing.';return}
 $L=$Path.Substring(0,1);if($gb -lt 0.5){Throw-Code 1 "Only $gb GB free on drive ${L}: - at least 0.5 GB is required to build and publish. Free up disk space and re-run."}elseif($gb -lt 2){Write-Warn2 "Low disk space: $gb GB free on drive ${L}: - the build could fail."}else{Write-Ok "Disk space OK: $gb GB free on drive ${L}:"}}
function Write-SourceFiles([string]$Dir,[string]$Name){
 $proj=@'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>WinExe</OutputType><TargetFramework>net8.0-windows</TargetFramework><Nullable>enable</Nullable><ImplicitUsings>enable</ImplicitUsings><UseWPF>true</UseWPF><ApplicationManifest>app.manifest</ApplicationManifest><SelfContained>true</SelfContained><RuntimeIdentifier>win-x64</RuntimeIdentifier><PublishSingleFile>true</PublishSingleFile><IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract><EnableCompressionInSingleFile>true</EnableCompressionInSingleFile><DebugType>embedded</DebugType><RootNamespace>__APPNAME__</RootNamespace><AssemblyName>__APPNAME__</AssemblyName><SatelliteResourceLanguages>en</SatelliteResourceLanguages></PropertyGroup></Project>
'@
 $manifest=@'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="1.0.0.0" name="__APPNAME__.app"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2">
    <security>
      <requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
    </windowsSettings>
  </application>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>
      <supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}"/>
      <supportedOS Id="{35138b9a-5d96-4fbd-8e2d-a2440225f93a}"/>
      <supportedOS Id="{e2011457-1546-43c5-a5fe-008deee3d3f0}"/>
    </application>
  </compatibility>
</assembly>
'@
 $appXaml=@'
<Application x:Class="__APPNAME__.App" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" StartupUri="MainWindow.xaml"><Application.Resources></Application.Resources></Application>
'@
 $appCs=@'
using System.Windows;
namespace __APPNAME__
{
    public partial class App : Application
    {
        public App(){ this.DispatcherUnhandledException += OnDispatcherException; }
        private void OnDispatcherException(object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e){ MessageBox.Show("An unexpected error occurred:\r\n\r\n" + e.Exception.Message + "\r\n\r\nThe application will keep running.", "__APPNAME__", MessageBoxButton.OK, MessageBoxImage.Error); e.Handled = true; }
    }
}
'@
 $asmCs=@'
using System.Windows;
[assembly: ThemeInfo(ResourceDictionaryLocation.None, ResourceDictionaryLocation.SourceAssembly)]
'@
 $page1Xaml=@'
<Page x:Class="__APPNAME__.GalleryPage1" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Frame page 1" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
    <StackPanel Margin="18">
        <TextBlock Text="Frame page 1 - Overview" FontSize="18" FontWeight="Bold" Foreground="#FF312E81"/>
        <TextBlock Text="The Frame hosts Page objects and keeps a navigation journal, just like a browser. Use the built-in back and forward arrows in the frame chrome above, or the buttons on the main page." TextWrapping="Wrap" Margin="0,8,0,12"/>
        <Button Content="Continue to page 2" Padding="10,6" MinWidth="120" HorizontalAlignment="Left" Click="GoPage2_Click"/>
    </StackPanel>
</Page>
'@
 $page1Cs=@'
using System;
using System.Windows;
using System.Windows.Controls;
namespace __APPNAME__
{
    public partial class GalleryPage1 : Page
    {
        public GalleryPage1(){ InitializeComponent(); }
        private void GoPage2_Click(object sender, RoutedEventArgs e){ NavigationService.Navigate(new GalleryPage2()); }
    }
}
'@
 $page2Xaml=@'
<Page x:Class="__APPNAME__.GalleryPage2" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Frame page 2" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
    <StackPanel Margin="18">
        <TextBlock Text="Frame page 2 - Details" FontSize="18" FontWeight="Bold" Foreground="#FF831843"/>
        <TextBlock Text="Navigation history is automatic: GoBack, GoForward, CanGoBack and CanGoForward are all managed by the Frame for you." TextWrapping="Wrap" Margin="0,8,0,12"/>
        <Button Content="Back to page 1" Padding="10,6" MinWidth="120" HorizontalAlignment="Left" Click="GoBack_Click"/>
    </StackPanel>
</Page>
'@
 $page2Cs=@'
using System;
using System.Windows;
using System.Windows.Controls;
namespace __APPNAME__
{
    public partial class GalleryPage2 : Page
    {
        public GalleryPage2(){ InitializeComponent(); }
        private void GoBack_Click(object sender, RoutedEventArgs e){ if (NavigationService.CanGoBack) { NavigationService.GoBack(); } }
    }
}
'@
 $mwXaml=@'
<Window x:Class="__APPNAME__.MainWindow" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib" Title="WPF Control Gallery - Kitchen Sink Edition (15 sections + popouts)" Width="1220" Height="800" MinWidth="1020" MinHeight="680" WindowStartupLocation="CenterScreen" WindowState="Maximized" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
    <Window.ContextMenu>
        <ContextMenu>
            <MenuItem Header="Jump to section (right-click menu)" IsEnabled="False"/>
            <MenuItem Header="2. Buttons and Toggles" Tag="1" Click="WinCtx_Click"/>
            <MenuItem Header="5. Layout Panels" Tag="5" Click="WinCtx_Click"/>
            <MenuItem Header="7. Shapes, Brushes and 3D" Tag="6" Click="WinCtx_Click"/>
            <MenuItem Header="9. Data and Validation" Tag="8" Click="WinCtx_Click"/>
            <MenuItem Header="13. Documents and Web" Tag="12" Click="WinCtx_Click"/>
            <MenuItem Header="15. System and Kitchen Sink" Tag="14" Click="WinCtx_Click"/>
        </ContextMenu>
    </Window.ContextMenu>
    <Window.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFF8FAFF" Offset="0"/><GradientStop Color="#FFEDE9FB" Offset="1"/></LinearGradientBrush>
    </Window.Background>
    <Window.Resources>
        <SolidColorBrush x:Key="CardBg" Color="White"/><SolidColorBrush x:Key="CardFg" Color="#FF312E81"/><SolidColorBrush x:Key="AccentBrush" Color="#FF4F46E5"/>
        <BooleanToVisibilityConverter x:Key="B2V"/>
        <XmlDataProvider x:Key="XmlTeams" XPath="Teams">
            <x:XData>
                <Teams xmlns="">
                    <Team Name="Alpha Rockets" City="Berlin"/>
                    <Team Name="Bravo Bandits" City="Oslo"/>
                    <Team Name="Charlie Comets" City="Lima"/>
                    <Team Name="Delta Dragons" City="Kyoto"/>
                </Teams>
            </x:XData>
        </XmlDataProvider>
        <Style x:Key="ValidatedBox" TargetType="TextBox"><Style.Triggers><Trigger Property="Validation.HasError" Value="True"><Setter Property="BorderBrush" Value="Red"/><Setter Property="BorderThickness" Value="2"/></Trigger></Style.Triggers></Style>
        <Style x:Key="BasePill" TargetType="Button"><Setter Property="Padding" Value="14,7"/><Setter Property="Background" Value="#FFE0E7FF"/><Setter Property="BorderThickness" Value="0"/></Style>
        <Style x:Key="AccentPill" TargetType="Button" BasedOn="{StaticResource BasePill}"><Setter Property="Background" Value="#FF4F46E5"/><Setter Property="Foreground" Value="White"/></Style>
        <Style TargetType="GroupBox"><Setter Property="Margin" Value="0,0,14,14"/><Setter Property="MinWidth" Value="320"/><Setter Property="Background" Value="White"/></Style>
        <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="12,9"/></Style>
        <Style TargetType="Button"><Setter Property="Padding" Value="10,6"/><Setter Property="Margin" Value="0,0,8,8"/><Setter Property="MinWidth" Value="90"/></Style>
        <Style x:Key="FancyButton" TargetType="Button"><Setter Property="Padding" Value="12,7"/><Setter Property="Background" Value="#FFEEF2FF"/><Setter Property="BorderBrush" Value="#FF6366F1"/><Setter Property="BorderThickness" Value="1"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF6366F1"/><Setter Property="Foreground" Value="White"/></Trigger></Style.Triggers></Style>
        <Style x:Key="DangerButton" TargetType="Button"><Setter Property="Padding" Value="12,7"/><Setter Property="Background" Value="#FFFEF2F2"/><Setter Property="BorderBrush" Value="#FFDC2626"/><Setter Property="BorderThickness" Value="1"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FFDC2626"/><Setter Property="Foreground" Value="White"/></Trigger></Style.Triggers></Style>
        <Style x:Key="GradientButton" TargetType="Button"><Setter Property="Foreground" Value="White"/><Setter Property="Padding" Value="12,7"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FF4F46E5" Offset="0"/><GradientStop Color="#FF9333EA" Offset="1"/></LinearGradientBrush></Setter.Value></Setter></Style>
    </Window.Resources>
    <DockPanel>
        <Border DockPanel.Dock="Top" x:Name="HeaderBar">
            <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#FF4338CA" Offset="0"/><GradientStop Color="#FF7C3AED" Offset="0.55"/><GradientStop Color="#FFDB2777" Offset="1"/></LinearGradientBrush></Border.Background>
            <Grid Margin="22,14">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel>
                    <TextBlock Text="WPF CONTROL GALLERY - KITCHEN SINK EDITION" FontSize="24" FontWeight="Bold" Foreground="White"/>
                    <TextBlock Text="130+ controls, 3D textures, video, adorners, path animations - plus popout windows for the big-screen demos. Right-click anywhere to jump." Foreground="#FFE9E5FF" FontSize="13" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock x:Name="ClockText" Foreground="White" FontSize="17" FontWeight="SemiBold" HorizontalAlignment="Right"/>
                    <TextBlock Text="DispatcherTimer clock, ticking live" Foreground="#FFE9E5FF" FontSize="11" HorizontalAlignment="Right" Margin="0,2,0,0"/>
                </StackPanel>
            </Grid>
        </Border>
        <StatusBar DockPanel.Dock="Bottom" Background="#FFF1F5F9">
            <StatusBarItem><TextBlock x:Name="StatusText" Text="Booting..."/></StatusBarItem>
            <Separator/>
            <StatusBarItem><TextBlock Text="Hover any control for its ToolTip"/></StatusBarItem>
        </StatusBar>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="245"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="White" BorderBrush="#FFE2E6F0" BorderThickness="0,0,1,0">
                <DockPanel>
                    <TextBlock DockPanel.Dock="Top" Text="SECTIONS" FontSize="12" FontWeight="Bold" Foreground="#FF6B7280" Margin="16,14,0,10"/>
                    <ListBox x:Name="NavList" Background="Transparent" BorderThickness="0" SelectionChanged="NavList_SelectionChanged">
                        <ListBoxItem Content="1. Welcome"/><ListBoxItem Content="2. Buttons and Toggles"/><ListBoxItem Content="3. Text Input"/><ListBoxItem Content="4. Lists, Menus and Trees"/><ListBoxItem Content="5. Sliders, Dates and Commands"/><ListBoxItem Content="6. Layout Panels"/><ListBoxItem Content="7. Shapes, Brushes and 3D"/><ListBoxItem Content="8. Ink, Images, Sound and Video"/><ListBoxItem Content="9. Data and Validation"/><ListBoxItem Content="10. Styles and Animation"/><ListBoxItem Content="11. Custom, Adorners and Runtime XAML"/><ListBoxItem Content="12. Dialogs and Printing"/><ListBoxItem Content="13. Documents and Web"/><ListBoxItem Content="14. Drag, Drop and Virtualization"/><ListBoxItem Content="15. System and Kitchen Sink"/>
                    </ListBox>
                </DockPanel>
            </Border>
            <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto" Padding="18,16">
                <Grid>
                    <StackPanel x:Name="SecWelcome">
                        <Border Background="White" CornerRadius="12" Padding="28" Margin="0,0,0,16">
                            <Border.Effect><DropShadowEffect BlurRadius="22" ShadowDepth="2" Opacity="0.16"/></Border.Effect>
                            <StackPanel>
                                <TextBlock Text="Welcome to the Kitchen Sink Edition" FontSize="30" FontWeight="Bold" Foreground="#FF312E81">
                                    <TextBlock.Triggers><EventTrigger RoutedEvent="TextBlock.Loaded"><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetProperty="Opacity" From="0" To="1" Duration="0:0:1.2"/></Storyboard></BeginStoryboard></EventTrigger></TextBlock.Triggers>
                                </TextBlock>
                                <TextBlock Text="Fifteen sections covering essentially everything WPF has: a textured spinning 3D cube, synthesized sound, video playback, fixed and flow documents, adorners, matrix path animations, live OS theme brushes, routed commands, XML data providers, two kinds of validation, virtualization with 10,000 rows, runtime XAML, printing and PNG snapshots. The big demos - the 3D cube, ink, plasma, the DataGrid and the fixed document - can pop out into their own resizable windows. Right-click anywhere for quick navigation." FontSize="14" Foreground="#FF4B5563" Margin="0,10,0,18" TextWrapping="Wrap"/>
                                <WrapPanel>
                                    <Button Content="Start the tour" Click="TourStart_Click"/>
                                    <Button Content="Jump to the DataGrid" Click="TourData_Click"/>
                                    <Button Content="Show me the 3D cube" Click="TourCube_Click"/>
                                    <Button Content="DEPLOY KITCHEN SINK" Style="{StaticResource GradientButton}" Click="SinkBtn_Click"/>
                                    <Button Content="Surprise me" Click="TourRandom_Click"/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                        <WrapPanel>
                            <GroupBox Header="Popout theater (own windows)">
                                <StackPanel>
                                    <TextBlock Text="Any demo that deserves the big screen opens into its own resizable window:" TextWrapping="Wrap"/>
                                    <WrapPanel Margin="0,10,0,0">
                                        <Button Content="3D theater" Click="PopCube_Click"/>
                                        <Button Content="Ink studio" Click="PopInk_Click"/>
                                        <Button Content="Plasma lab" Click="PopPlasma_Click"/>
                                        <Button Content="DataGrid theater" Click="PopData_Click"/>
                                        <Button Content="Document theater" Click="PopDoc_Click"/>
                                    </WrapPanel>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="What is inside">
                                <StackPanel>
                                    <TextBlock Text="Buttons, toggles, text, passwords, rich text, lists, trees, menus, tabs, toolbars, sliders, calendars, progress, panels, splitters, shapes, brushes, effects, images, ink, sound, video, 3D, DataGrid, grouping, binding, converters, two kinds of validation, commands, key bindings, styles, templates, themes, keyframes, path animations, adorners, custom controls, XamlReader, snapshots, dialogs, printing, flow and fixed documents, frames, a browser, popups, thumbs, drag and drop, virtualization and live OS integration." TextWrapping="Wrap"/>
                                    <TextBlock x:Name="FactText" Margin="0,10,0,0" FontWeight="SemiBold" Foreground="#FF4F46E5" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="How to use it">
                                <StackPanel>
                                    <TextBlock Text="Pick a section on the left (or right-click anywhere). Every action is reported in the status bar, so nothing you click is ever silent." TextWrapping="Wrap"/>
                                    <CheckBox x:Name="FunCheck" Content="Fun mode (paint the background)" Margin="0,12,0,0" Click="Fun_Toggled"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Runtime check">
                                <StackPanel>
                                    <TextBlock Text="This app verifies its own runtime:"/>
                                    <TextBlock x:Name="RuntimeText" Margin="0,8,0,0" TextWrapping="Wrap" Foreground="#FF047857"/>
                                    <Button Content="Re-check runtime" Margin="0,12,0,0" Click="RuntimeCheck_Click"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                    </StackPanel>
                    <StackPanel x:Name="SecButtons" Visibility="Collapsed">
                        <TextBlock Text="Buttons, Toggles and Selection" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Click everything - results appear here and in the status bar." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <WrapPanel>
                            <GroupBox Header="Button">
                                <StackPanel>
                                    <Button Content="Plain button" Click="BtnPlain_Click"/>
                                    <Button Content="Gradient button" Style="{StaticResource GradientButton}" Click="BtnPlain_Click"/>
                                    <Button Content="Disabled button" IsEnabled="False"/>
                                    <TextBlock x:Name="BtnResult" Margin="0,10,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="RepeatButton">
                                <StackPanel>
                                    <TextBlock Text="Fires Click continuously while held:" TextWrapping="Wrap"/>
                                    <RepeatButton Content="Hold to count" Margin="0,10,0,0" Click="RepeatBtn_Click"/>
                                    <TextBlock x:Name="RepeatCountText" Text="Clicks: 0" FontWeight="Bold" Margin="0,10,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="ToggleButton and CheckBox">
                                <StackPanel>
                                    <ToggleButton x:Name="DemoToggle" Content="Toggle me" Click="DemoToggle_Click"/>
                                    <CheckBox x:Name="ChkNews" Content="Subscribe to news" Margin="0,10,0,0" Click="ChkAny_Click"/>
                                    <CheckBox x:Name="ChkTips" Content="Send me tips" Click="ChkAny_Click"/>
                                    <CheckBox x:Name="ChkTri" Content="Three-state option" IsThreeState="True" Click="ChkAny_Click"/>
                                    <TextBlock x:Name="ChkSummary" Margin="0,10,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="RadioButton groups">
                                <StackPanel>
                                    <TextBlock Text="Size:"/>
                                    <RadioButton GroupName="Size" Content="Small" Margin="0,6,0,0" Click="Radio_Click"/>
                                    <RadioButton GroupName="Size" Content="Medium" IsChecked="True" Click="Radio_Click"/>
                                    <RadioButton GroupName="Size" Content="Large" Click="Radio_Click"/>
                                    <TextBlock Text="Color:" Margin="0,12,0,0"/>
                                    <RadioButton GroupName="Color" Content="Blue" IsChecked="True" Margin="0,6,0,0" Click="Radio_Click"/>
                                    <RadioButton GroupName="Color" Content="Red" Click="Radio_Click"/>
                                    <TextBlock x:Name="RadioSummary" Margin="0,10,0,0" Foreground="#FF047857"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Styles and triggers">
                                <StackPanel>
                                    <Button Content="Hover recolors me" Style="{StaticResource FancyButton}" Click="BtnFancy_Click" Margin="0"/>
                                    <Button Content="Danger zone" Style="{StaticResource DangerButton}" Click="BtnDanger_Click" Margin="0,8,0,0"/>
                                    <TextBlock Text="Colors come from Style triggers, not code." Margin="0,10,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Style inheritance (BasedOn)">
                                <StackPanel>
                                    <Button Content="BasePill style" Style="{StaticResource BasePill}" Click="BtnPlain_Click" Margin="0" HorizontalAlignment="Left"/>
                                    <Button Content="AccentPill (BasedOn BasePill)" Style="{StaticResource AccentPill}" Click="BtnPlain_Click" Margin="0,8,0,0" HorizontalAlignment="Left"/>
                                    <TextBlock Text="AccentPill inherits padding and borderless chrome from BasePill and overrides the colors." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,10,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="AccessText and disabled tooltips" Width="340">
                                <StackPanel>
                                    <Button HorizontalAlignment="Left" MinWidth="130"><AccessText>_Access key (Alt+A)</AccessText></Button>
                                    <Button Content="Disabled but explained" IsEnabled="False" Margin="0,8,0,0" ToolTip="ToolTipService.ShowOnDisabled lets even disabled controls explain themselves." ToolTipService.ShowOnDisabled="True"/>
                                    <TextBlock Text="AccessText draws the mnemonic underline; hover the disabled button - the tooltip still appears." Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                    </StackPanel>
                    <StackPanel x:Name="SecText" Visibility="Collapsed">
                        <TextBlock Text="Text Input and Formatting" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Type, hide, format - all the text controls." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <WrapPanel>
                            <GroupBox Header="TextBox">
                                <StackPanel>
                                    <TextBlock Text="First name, then press Enter:"/>
                                    <TextBox x:Name="NameBox" Margin="0,6,0,0" ToolTip="Type and press Enter" KeyDown="NameBox_KeyDown" TextChanged="JoinInputs_Changed"/>
                                    <TextBlock x:Name="EchoText" Margin="0,10,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Multiline TextBox">
                                <StackPanel>
                                    <TextBox x:Name="MultiBox" AcceptsReturn="True" TextWrapping="Wrap" Height="92" VerticalScrollBarVisibility="Auto" TextChanged="MultiBox_TextChanged" Text="Type here..."/>
                                    <TextBlock x:Name="MultiCountText" Margin="0,8,0,0" Foreground="#FF047857"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="PasswordBox">
                                <StackPanel>
                                    <PasswordBox x:Name="PwdBox" PasswordChanged="PwdBox_PasswordChanged" ToolTip="Type a secret"/>
                                    <CheckBox x:Name="ShowPwd" Content="Reveal password" Margin="0,10,0,0" Click="ShowPwd_Click"/>
                                    <TextBlock x:Name="PwdInfoText" Margin="0,10,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Constrained TextBox">
                                <StackPanel>
                                    <TextBox MaxLength="10" CharacterCasing="Upper" ToolTip="Max 10 characters, auto-uppercased"/>
                                    <TextBlock Text="MaxLength=10 and CharacterCasing=Upper enforce input rules at the control level." Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                        <GroupBox Header="ToolBar + RichTextBox" MinWidth="700">
                            <StackPanel>
                                <ToolBar>
                                    <Button Content="B" FontWeight="Bold" MinWidth="34" Click="RichBold_Click" ToolTip="Bold"/>
                                    <Button Content="I" FontStyle="Italic" MinWidth="34" Click="RichItalic_Click" ToolTip="Italic"/>
                                    <Button MinWidth="34" Click="RichUnderline_Click" ToolTip="Underline"><TextBlock Text="U" TextDecorations="Underline"/></Button>
                                    <Separator/>
                                    <ToggleButton x:Name="RichRo" Content="Read-only" Click="RichRo_Click" ToolTip="Lock the document"/>
                                    <Button Content="Clear" Click="RichClear_Click" ToolTip="Wipe the document"/>
                                </ToolBar>
                                <RichTextBox x:Name="DemoRich" Height="110" Margin="0,8,0,0">
                                    <FlowDocument><Paragraph><Run Text="Rich text editing with live formatting. Select some text and hit B, I or U in the toolbar above."/></Paragraph></FlowDocument>
                                </RichTextBox>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="Inline runs (rich text in one TextBlock)" MinWidth="700">
                            <TextBlock TextWrapping="Wrap" MaxWidth="660"><Bold>Bold inline,</Bold> <Italic>italic inline,</Italic> <Underline>underlined,</Underline> <Run Foreground="#FFDC2626">colored,</Run> <Run FontFamily="Consolas">monospace</Run> and a <Hyperlink NavigateUri="https://learn.microsoft.com/dotnet/desktop/wpf/" RequestNavigate="DocLink_RequestNavigate">hyperlink</Hyperlink> all inside one TextBlock.<LineBreak/>A LineBreak starts a fresh line without a second control.</TextBlock>
                        </GroupBox>
                        <GroupBox Header="TextTrimming" MinWidth="700">
                            <StackPanel>
                                <TextBlock Width="250" HorizontalAlignment="Left" TextTrimming="CharacterEllipsis" Text="This long sentence gets trimmed with an ellipsis instead of wrapping." ToolTip="The full text, available on hover"/>
                                <TextBlock Text="TextTrimming ellipsizes overflow text; hover to read the whole thing." Foreground="#FF6B7280" Margin="0,8,0,0"/>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="TextBlock typography" MinWidth="700">
                            <StackPanel>
                                <TextBlock FontSize="20" FontWeight="Bold" Foreground="#FF312E81">Bold Segoe heading</TextBlock>
                                <TextBlock FontFamily="Georgia" FontStyle="Italic" FontSize="16" Margin="0,8,0,0">Georgia italic - elegant serif prose for long-form reading.</TextBlock>
                                <TextBlock FontFamily="Consolas" Margin="0,8,0,0">Consolas monospace: 0123456789</TextBlock>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>
                    <StackPanel x:Name="SecLists" Visibility="Collapsed">
                        <TextBlock Text="Lists, Menus and Trees" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Selection controls, bound trees, XML data, styled combos and toolbars." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <GroupBox Header="Menu with accelerators, icons and gestures" MinWidth="700">
                            <StackPanel>
                                <Menu>
                                    <MenuItem Header="_File">
                                        <MenuItem Header="_New" InputGestureText="Ctrl+N" Click="MenuNew_Click"/>
                                        <MenuItem Header="_Open" Click="MenuOpen_Click"/>
                                        <Separator/>
                                        <MenuItem Header="E_xit" Click="MenuExit_Click"/>
                                    </MenuItem>
                                    <MenuItem Header="_Edit">
                                        <MenuItem Header="Cu_t" Click="MenuCut_Click"/>
                                        <MenuItem Header="_Copy" InputGestureText="Ctrl+C" Click="MenuCopy_Click"><MenuItem.Icon><Ellipse Width="12" Height="12" Fill="#FF4F46E5"/></MenuItem.Icon></MenuItem>
                                        <MenuItem Header="_Paste" InputGestureText="Ctrl+V" Click="MenuPaste_Click"><MenuItem.Icon><Ellipse Width="12" Height="12" Fill="#FFEC4899"/></MenuItem.Icon></MenuItem>
                                    </MenuItem>
                                    <MenuItem Header="_Help">
                                        <MenuItem Header="_About" Click="MenuAbout_Click"/>
                                    </MenuItem>
                                </Menu>
                                <TextBlock Text="MenuItem.Icon hosts any visual; InputGestureText displays the shortcut." Margin="0,6,0,0" Foreground="#FF6B7280"/>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="ToolBarTray with two ToolBars" MinWidth="700">
                            <ToolBarTray Background="#FFF1F5F9">
                                <ToolBar Band="0" BandIndex="0"><Button Content="Save" Click="ToolBtn_Click"/><Button Content="Undo" Click="ToolBtn_Click"/></ToolBar>
                                <ToolBar Band="0" BandIndex="1"><ToggleButton Content="Wrap"/><Button Content="Zoom in" Click="ToolBtn_Click"/></ToolBar>
                            </ToolBarTray>
                        </GroupBox>
                        <WrapPanel>
                            <GroupBox Header="ListBox with ContextMenu">
                                <StackPanel>
                                    <ListBox x:Name="FruitsList" Height="110" SelectionChanged="FruitsList_SelectionChanged">
                                        <ListBox.ContextMenu>
                                            <ContextMenu>
                                                <MenuItem Header="Say hello to the selection" Click="CtxHello_Click"/>
                                                <MenuItem Header="Count all items" Click="CtxCount_Click"/>
                                            </ContextMenu>
                                        </ListBox.ContextMenu>
                                        <ListBoxItem Content="Apple"/><ListBoxItem Content="Banana"/><ListBoxItem Content="Cherry"/><ListBoxItem Content="Durian"/><ListBoxItem Content="Elderberry"/>
                                    </ListBox>
                                    <TextBlock x:Name="FruitResult" Margin="0,8,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="XmlDataProvider + XPath binding">
                                <StackPanel>
                                    <ListBox x:Name="XmlList" Height="96" Width="230" ItemsSource="{Binding Source={StaticResource XmlTeams}, XPath=Team}" DisplayMemberPath="@Name" SelectionChanged="XmlList_SelectionChanged"/>
                                    <TextBlock x:Name="XmlResult" Margin="0,8,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                    <TextBlock Text="The data is inline XML in the resources, queried with XPath." Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="TreeView bound with HierarchicalDataTemplate" Width="340">
                                <StackPanel>
                                    <TreeView x:Name="TreeBound" Height="160" SelectedItemChanged="TreeBound_Selected">
                                        <TreeView.ItemTemplate>
                                            <HierarchicalDataTemplate ItemsSource="{Binding Kids}">
                                                <StackPanel Orientation="Horizontal">
                                                    <CheckBox IsChecked="{Binding Done}" VerticalAlignment="Center"/>
                                                    <TextBlock Text="{Binding Title}" Margin="5,0,0,0"/>
                                                </StackPanel>
                                            </HierarchicalDataTemplate>
                                        </TreeView.ItemTemplate>
                                    </TreeView>
                                    <TextBlock Text="ItemsSource + HierarchicalDataTemplate - check tasks right inside the tree." Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Static TreeView">
                                <StackPanel>
                                    <TreeView x:Name="TreeDemo" Height="160" SelectedItemChanged="TreeDemo_SelectedItemChanged">
                                        <TreeViewItem Header="Animals" IsExpanded="True">
                                            <TreeViewItem Header="Mammals" IsExpanded="True">
                                                <TreeViewItem Header="Dog"/><TreeViewItem Header="Cat"/>
                                            </TreeViewItem>
                                            <TreeViewItem Header="Birds">
                                                <TreeViewItem Header="Parrot"/><TreeViewItem Header="Owl"/>
                                            </TreeViewItem>
                                        </TreeViewItem>
                                        <TreeViewItem Header="Plants" IsExpanded="True">
                                            <TreeViewItem Header="Fern"/><TreeViewItem Header="Cactus"/>
                                        </TreeViewItem>
                                    </TreeView>
                                    <TextBlock x:Name="TreeResult" Margin="0,8,0,0" Foreground="#FF047857"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                        <WrapPanel>
                            <GroupBox Header="ComboBox with data">
                                <StackPanel>
                                    <ComboBox x:Name="TeamCombo" Width="220" Margin="0,0,0,8"/>
                                    <TextBlock Text="Font for the sample text:"/>
                                    <ComboBox x:Name="FontCombo" SelectedIndex="0" Margin="0,6,0,0" SelectionChanged="FontCombo_SelectionChanged">
                                        <ComboBoxItem Content="Segoe UI"/><ComboBoxItem Content="Consolas"/><ComboBoxItem Content="Georgia"/><ComboBoxItem Content="Comic Sans MS"/><ComboBoxItem Content="Times New Roman"/>
                                    </ComboBox>
                                    <TextBlock x:Name="FontSample" Text="The quick brown fox jumps over the lazy dog" FontSize="16" Margin="0,10,0,0" TextWrapping="Wrap"/>
                                    <TextBlock Text="Editable combo - type and press Enter (it also feeds the join demo in section 9):" Margin="0,12,0,0" TextWrapping="Wrap"/>
                                    <ComboBox x:Name="EditCombo" IsEditable="True" Margin="0,6,0,0" KeyDown="EditCombo_KeyDown" SelectionChanged="EditComboSel_Changed">
                                        <ComboBoxItem Content="Preexisting choice"/>
                                    </ComboBox>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="AlternationCount striping">
                                <StackPanel>
                                    <ListBox x:Name="AltList" Height="130" AlternationCount="3">
                                        <ListBox.ItemContainerStyle>
                                            <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="8,5"/><Setter Property="Background" Value="White"/><Style.Triggers><Trigger Property="ItemsControl.AlternationIndex" Value="1"><Setter Property="Background" Value="#FFEEF2FF"/></Trigger><Trigger Property="ItemsControl.AlternationIndex" Value="2"><Setter Property="Background" Value="#FFF0FDF4"/></Trigger></Style.Triggers></Style>
                                        </ListBox.ItemContainerStyle>
                                    </ListBox>
                                    <TextBlock Text="AlternationIndex drives the striped backgrounds - no code." Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="TabControl docked left">
                                <TabControl TabStripPlacement="Left" Height="120" Width="260">
                                    <TabItem Header="A"><TextBlock Text="Tabs can dock to any edge - this one is on the left." Margin="10" TextWrapping="Wrap"/></TabItem>
                                    <TabItem Header="B"><TextBlock Text="Second left-docked tab." Margin="10" TextWrapping="Wrap"/></TabItem>
                                </TabControl>
                            </GroupBox>
                        </WrapPanel>
                        <GroupBox Header="Raw ScrollBar control" MinWidth="700">
                            <StackPanel>
                                <ScrollBar x:Name="RawScroll" Orientation="Horizontal" Maximum="100" SmallChange="1" LargeChange="10" Width="220" HorizontalAlignment="Left" ValueChanged="RawScroll_ValueChanged"/>
                                <TextBlock x:Name="RawLabel" Text="Value: 0" Margin="0,6,0,0" Foreground="#FF047857"/>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="ListView with GridView columns" MinWidth="700">
                            <StackPanel>
                                <ListView x:Name="FileList" Height="140" SelectionChanged="FileList_SelectionChanged">
                                    <ListView.View>
                                        <GridView>
                                            <GridViewColumn Header="Name" Width="230" DisplayMemberBinding="{Binding Name}"/>
                                            <GridViewColumn Header="Size (KB)" Width="90" DisplayMemberBinding="{Binding SizeKb}"/>
                                            <GridViewColumn Header="Type" Width="150" DisplayMemberBinding="{Binding Type}"/>
                                            <GridViewColumn Header="Modified" Width="150" DisplayMemberBinding="{Binding Modified}"/>
                                        </GridView>
                                    </ListView.View>
                                </ListView>
                                <TextBlock x:Name="FileResult" Margin="0,8,0,0" Foreground="#FF047857"/>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="TabControl (top docked)" MinWidth="700">
                            <TabControl x:Name="DemoTabs" Height="150" SelectionChanged="DemoTabs_SelectionChanged">
                                <TabItem Header="Overview">
                                    <StackPanel Margin="12">
                                        <TextBlock Text="Tab 1 - Overview" FontWeight="Bold" FontSize="15"/>
                                        <TextBlock Text="Each TabItem hosts its own page of content." Margin="0,8,0,0" TextWrapping="Wrap"/>
                                    </StackPanel>
                                </TabItem>
                                <TabItem Header="Options">
                                    <StackPanel Margin="12">
                                        <CheckBox Content="Enable verbose output" IsChecked="True"/>
                                        <CheckBox Content="Remember window position"/>
                                    </StackPanel>
                                </TabItem>
                                <TabItem Header="Palette">
                                    <WrapPanel Margin="12">
                                        <Ellipse Width="34" Height="34" Fill="#FFEF4444" Margin="4"/><Ellipse Width="34" Height="34" Fill="#FFF59E0B" Margin="4"/><Ellipse Width="34" Height="34" Fill="#FF22C55E" Margin="4"/><Ellipse Width="34" Height="34" Fill="#FF3B82F6" Margin="4"/><Ellipse Width="34" Height="34" Fill="#FF8B5CF6" Margin="4"/>
                                    </WrapPanel>
                                </TabItem>
                            </TabControl>
                        </GroupBox>
                    </StackPanel>
                    <StackPanel x:Name="SecInput" Visibility="Collapsed">
                        <TextBlock Text="Sliders, Dates, Events and Commands" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Analog input, calendars, routed events and routed commands." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <WrapPanel>
                            <GroupBox Header="Slider drives ProgressBar">
                                <StackPanel>
                                    <Slider x:Name="SizeSlider" Minimum="0" Maximum="100" Value="40" TickFrequency="5" IsSnapToTickEnabled="True" IsSelectionRangeEnabled="True" SelectionStart="20" SelectionEnd="80" ValueChanged="SizeSlider_ValueChanged"/>
                                    <ProgressBar x:Name="DemoProgress" Height="18" Margin="0,12,0,0"/>
                                    <TextBlock x:Name="SizeLabel" Margin="0,10,0,0" FontWeight="SemiBold" Foreground="#FF047857"/>
                                    <CheckBox x:Name="IndetCheck" Content="Indeterminate (marquee) mode" Margin="0,12,0,0" Click="IndetCheck_Click"/>
                                    <TextBlock Text="The shaded band is the slider's selection range (20-80)." Foreground="#FF6B7280" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Calendar">
                                <StackPanel>
                                    <Calendar x:Name="DemoCal" SelectedDatesChanged="DemoCal_SelectedDatesChanged"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="DatePicker + BlackoutDates" Width="340">
                                <StackPanel>
                                    <DatePicker x:Name="DemoDate" SelectedDateChanged="DemoDate_SelectedDateChanged"/>
                                    <Button Content="Set to today" Margin="0,10,0,0" Click="TodayBtn_Click"/>
                                    <TextBlock x:Name="DateResult" Margin="0,10,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                    <TextBlock Text="Second picker: past dates and the week after next are blacked out (from code):" Margin="0,12,0,0" TextWrapping="Wrap"/>
                                    <DatePicker x:Name="BlockDatePick" Margin="0,6,0,0" SelectedDateChanged="BlockPick_Changed"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Routed events: tunneling vs bubbling" Width="360">
                                <StackPanel>
                                    <Border x:Name="TunOuter" Background="#FFDBEAFE" Padding="16" MouseDown="TunOuterBubble" PreviewMouseDown="TunOuterPreview">
                                        <StackPanel>
                                            <TextBlock Text="Outer border"/>
                                            <Border x:Name="TunInner" Background="#FFFECACA" Padding="14" Margin="0,10,0,0" MouseDown="TunInnerBubble" PreviewMouseDown="TunInnerPreview">
                                                <TextBlock Text="Inner border - click here"/>
                                            </Border>
                                        </StackPanel>
                                    </Border>
                                    <TextBlock x:Name="TunnelLog" Margin="0,8,0,0" FontFamily="Consolas" FontSize="11" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="RoutedCommand + KeyBinding" Width="360">
                                <StackPanel>
                                    <Button x:Name="BoostBtn" Content="Boost (also Ctrl+B)" Click="BoostBtn_Click"/>
                                    <TextBlock Text="A CommandBinding enables and executes the Boost command; a KeyBinding maps Ctrl+B to the same command." Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="BoostLog" Margin="0,8,0,0" Foreground="#FF047857"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Built-in ApplicationCommands" Width="360">
                                <StackPanel>
                                    <WrapPanel>
                                        <Button Content="Cut" Command="Cut" CommandTarget="{Binding ElementName=CmdBox}"/>
                                        <Button Content="Copy" Command="Copy" CommandTarget="{Binding ElementName=CmdBox}"/>
                                        <Button Content="Paste" Command="Paste" CommandTarget="{Binding ElementName=CmdBox}"/>
                                        <Button Content="Undo" Command="Undo" CommandTarget="{Binding ElementName=CmdBox}"/>
                                        <Button Content="Redo" Command="Redo" CommandTarget="{Binding ElementName=CmdBox}"/>
                                    </WrapPanel>
                                    <TextBox x:Name="CmdBox" Margin="0,8,0,0" Text="Select text here, then use the buttons - WPF built-in command routing does the work, including undo/redo." TextWrapping="Wrap"/>
                                    <TextBlock Text="These buttons use Command=Cut/Copy/Paste/Undo/Redo with a CommandTarget; the TextBox implements the commands itself." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Keyboard + ScrollViewer">
                                <StackPanel>
                                    <TextBlock Text="Press any key while this box has focus:" TextWrapping="Wrap"/>
                                    <TextBox x:Name="KeyCaptureBox" Margin="0,8,0,0" KeyDown="KeyCapture_KeyDown"/>
                                    <TextBlock x:Name="KeyInfoText" Margin="0,10,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                    <ScrollViewer Height="70" Margin="0,12,0,0" VerticalScrollBarVisibility="Auto" Background="#FFF8FAFC">
                                        <TextBlock Text="ScrollViewer wraps any content taller or wider than itself and adds scrollbars. Scroll me!" TextWrapping="Wrap" Padding="8"/>
                                    </ScrollViewer>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                    </StackPanel>
                    <StackPanel x:Name="SecLayout" Visibility="Collapsed">
                        <TextBlock Text="Layout and Panels" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="The building blocks of every WPF screen - resize the window and watch them reflow." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <WrapPanel>
                            <GroupBox Header="Grid + GridSplitter (drag the divider)" Width="330" Height="185">
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <Border Grid.Column="0" Background="#FFDBEAFE" CornerRadius="6"><TextBlock Text="Left pane" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                                    <GridSplitter Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Background="#FF94A3B8" ResizeBehavior="PreviousAndNext" ResizeDirection="Columns"/>
                                    <Border Grid.Column="2" Background="#FFDCFCE7" CornerRadius="6"><TextBlock Text="Right pane" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                                </Grid>
                            </GroupBox>
                            <GroupBox Header="SharedSizeGroup across grids" Width="330" Height="185">
                                <StackPanel Grid.IsSharedSizeScope="True" VerticalAlignment="Center">
                                    <Grid><Grid.ColumnDefinitions><ColumnDefinition SharedSizeGroup="Lbl"/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock Text="Name:"/><TextBlock Grid.Column="1" Text="Ada"/></Grid>
                                    <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition SharedSizeGroup="Lbl"/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock Text="Occupation:"/><TextBlock Grid.Column="1" Text="Analytical engines"/></Grid>
                                    <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition SharedSizeGroup="Lbl"/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock Text="Note:"/><TextBlock Grid.Column="1" Text="Both label columns share one width"/></Grid>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="DockPanel (docked edges + fill)" Width="330" Height="185">
                                <DockPanel>
                                    <Border DockPanel.Dock="Top" Background="#FFE0E7FF" Padding="8"><TextBlock Text="Top docked"/></Border>
                                    <Border DockPanel.Dock="Bottom" Background="#FFE0E7FF" Padding="8"><TextBlock Text="Bottom docked"/></Border>
                                    <Border DockPanel.Dock="Left" Background="#FFFCE7F3" Padding="8"><TextBlock Text="Left"/></Border>
                                    <Border DockPanel.Dock="Right" Background="#FFFCE7F3" Padding="8"><TextBlock Text="Right"/></Border>
                                    <Border Background="#FFF0FDF4" Padding="8"><TextBlock Text="Fill (last child)" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                                </DockPanel>
                            </GroupBox>
                            <GroupBox Header="WrapPanel (reflows on resize)">
                                <WrapPanel>
                                    <Button Content="1" Click="Chip_Click"/><Button Content="2" Click="Chip_Click"/><Button Content="3" Click="Chip_Click"/><Button Content="4" Click="Chip_Click"/><Button Content="5" Click="Chip_Click"/><Button Content="6" Click="Chip_Click"/><Button Content="7" Click="Chip_Click"/><Button Content="8" Click="Chip_Click"/>
                                </WrapPanel>
                            </GroupBox>
                            <GroupBox Header="Vertical WrapPanel">
                                <WrapPanel Orientation="Vertical" Height="86" Width="230">
                                    <Button Content="V1" MinWidth="60" Click="Chip_Click"/><Button Content="V2" MinWidth="60" Click="Chip_Click"/><Button Content="V3" MinWidth="60" Click="Chip_Click"/><Button Content="V4" MinWidth="60" Click="Chip_Click"/><Button Content="V5" MinWidth="60" Click="Chip_Click"/><Button Content="V6" MinWidth="60" Click="Chip_Click"/>
                                </WrapPanel>
                            </GroupBox>
                            <GroupBox Header="UniformGrid (3 by 3)">
                                <UniformGrid Rows="3" Columns="3">
                                    <Border Background="#FFEFF6FF" Margin="2"><TextBlock Text="1" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/></Border>
                                    <Border Background="#FFFAF5FF" Margin="2"><TextBlock Text="2" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/></Border>
                                    <Border Background="#FFEFF6FF" Margin="2"><TextBlock Text="3" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/></Border>
                                    <Border Background="#FFFAF5FF" Margin="2"><TextBlock Text="4" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/></Border>
                                    <Border Background="#FFEFF6FF" Margin="2"><TextBlock Text="5" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/></Border>
                                    <Border Background="#FFFAF5FF" Margin="2"><TextBlock Text="6" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/></Border>
                                    <Border Background="#FFEFF6FF" Margin="2"><TextBlock Text="7" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/></Border>
                                    <Border Background="#FFFAF5FF" Margin="2"><TextBlock Text="8" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/></Border>
                                    <Border Background="#FFEFF6FF" Margin="2"><TextBlock Text="9" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/></Border>
                                </UniformGrid>
                            </GroupBox>
                            <GroupBox Header="Canvas + ZIndex buttons">
                                <StackPanel>
                                    <WrapPanel>
                                        <Button Content="Shuffle shapes" Click="ShuffleShapes_Click" Margin="0,0,8,8"/>
                                        <Button Content="Pink to front" Click="ZFront_Click" Margin="0,0,8,8"/>
                                        <Button Content="Pink to back" Click="ZBack_Click" Margin="0,0,0,8"/>
                                    </WrapPanel>
                                    <Canvas x:Name="DemoCanvas" Height="110" Background="#FFF8FAFC">
                                        <Ellipse Canvas.Left="20" Canvas.Top="18" Width="46" Height="46" Fill="#FF6366F1"/>
                                        <Rectangle Canvas.Left="90" Canvas.Top="34" Width="70" Height="40" Fill="#FF22C55E" RadiusX="6" RadiusY="6"/>
                                        <Polygon Points="200,10 250,56 150,56" Fill="#FFF59E0B"/>
                                        <Ellipse x:Name="ZA" Canvas.Left="30" Canvas.Top="66" Width="40" Height="40" Fill="#FFEC4899"/>
                                        <Rectangle x:Name="ZB" Canvas.Left="120" Canvas.Top="70" Width="90" Height="30" Fill="#FF0EA5E9" RadiusX="15" RadiusY="15"/>
                                    </Canvas>
                                    <Expander Header="Why Canvas?" Margin="0,10,0,0" Expanded="DemoExp_Expanded" Collapsed="DemoExp_Collapsed">
                                        <TextBlock Text="Canvas positions children by absolute coordinates (Canvas.Left and Canvas.Top); Panel.SetZIndex controls stacking. Hit the buttons to see both." TextWrapping="Wrap" Margin="0,6,0,0"/>
                                    </Expander>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Horizontal Expander">
                                <StackPanel>
                                    <Expander ExpandDirection="Left" Header="Open me" HorizontalAlignment="Left">
                                        <Border Background="#FFFEF9C3" Padding="10"><TextBlock Text="I expand toward the left edge." Width="120" TextWrapping="Wrap"/></Border>
                                    </Expander>
                                    <TextBlock Text="ExpandDirection Left/Right/Up/Down." Margin="0,10,0,0" Foreground="#FF6B7280"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Viewbox (auto-scaling)">
                                <StackPanel>
                                    <Border x:Name="ScaleHost" Width="240" HorizontalAlignment="Left" Background="#FFEEF2FF" CornerRadius="8" Padding="4">
                                        <Viewbox Stretch="Uniform"><TextBlock Text="SCALE" FontWeight="Bold" FontSize="40" Foreground="#FF4F46E5"/></Viewbox>
                                    </Border>
                                    <Slider x:Name="ScaleSlider" Minimum="140" Maximum="320" Value="240" Margin="0,10,0,0" ValueChanged="ScaleSlider_ValueChanged"/>
                                    <TextBlock x:Name="ScaleLabel" Text="Host width: 240"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                    </StackPanel>
                    <StackPanel x:Name="SecGraphics" Visibility="Collapsed">
                        <TextBlock Text="Shapes, Brushes and 3D" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Vector shapes, every brush type, effects and a textured 3D cube." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <WrapPanel>
                            <GroupBox Header="Shapes and brushes" Width="340">
                                <StackPanel>
                                    <Rectangle Width="150" Height="42" RadiusX="21" RadiusY="21" HorizontalAlignment="Left">
                                        <Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#FF4F46E5" Offset="0"/><GradientStop Color="#FFEC4899" Offset="1"/></LinearGradientBrush></Rectangle.Fill>
                                    </Rectangle>
                                    <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                                        <Ellipse Width="52" Height="52" Margin="0,0,10,0"><Ellipse.Fill><RadialGradientBrush><GradientStop Color="#FFBAE6FD" Offset="0"/><GradientStop Color="#FF0284C7" Offset="1"/></RadialGradientBrush></Ellipse.Fill></Ellipse>
                                        <Polygon Points="0,44 26,0 52,44" Fill="#FF10B981" Margin="0,0,10,0" VerticalAlignment="Center"/>
                                        <Rectangle Width="52" Height="52" RadiusX="10" RadiusY="10" Fill="#FFF59E0B"/>
                                    </StackPanel>
                                    <Line X1="0" Y1="0" X2="200" Y2="24" Stroke="#FFEF4444" StrokeThickness="3" Margin="0,12,0,0" HorizontalAlignment="Left"/>
                                    <Polyline Points="0,26 34,6 68,24 102,8 136,22" Stroke="#FF3B82F6" StrokeThickness="3" Margin="0,10,0,0" HorizontalAlignment="Left"/>
                                    <Path Data="M 0,40 C 40,-10 90,-10 130,40" Stroke="#FF9333EA" StrokeThickness="3" Margin="0,10,0,0" HorizontalAlignment="Left"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="PathGeometry gallery" Width="340">
                                <StackPanel>
                                    <Path Stroke="#FF4F46E5" StrokeThickness="3" HorizontalAlignment="Left" Data="M 10,60 C 40,10 90,10 120,60 C 150,110 200,110 230,60"/>
                                    <Path Fill="#FFEF4444" Stroke="#FF7F1D1D" StrokeThickness="2" HorizontalAlignment="Left" Margin="0,10,0,0" Data="M 60,20 A 30,30 0 1,1 59.9,20 Z M 90,50 A 20,20 0 1,0 90.1,50 Z"/>
                                    <Path Stroke="#FF10B981" StrokeThickness="3" HorizontalAlignment="Left" Margin="0,10,0,0" Data="M 10,40 L 40,10 L 70,40 L 100,10 L 130,40"/>
                                    <TextBlock Text="Cubic Bezier waves, an even-odd donut built from two arcs, and a zigzag line geometry - all inside the Data attribute." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Brushes and effects lab" Width="360">
                                <StackPanel>
                                    <Border x:Name="MiniCard" Width="180" HorizontalAlignment="Left" Background="#FF4F46E5" CornerRadius="10" Padding="12">
                                        <StackPanel><TextBlock Text="LIVE SOURCE" Foreground="White" FontWeight="Bold"/><TextBlock Text="The rectangle below is a VisualBrush mirror of this card." Foreground="#FFC7D2FE" FontSize="11" TextWrapping="Wrap"/></StackPanel>
                                    </Border>
                                    <Rectangle Height="70" Width="180" HorizontalAlignment="Left" Margin="0,8,0,0"><Rectangle.Fill><VisualBrush Visual="{Binding ElementName=MiniCard}" Stretch="Uniform"/></Rectangle.Fill></Rectangle>
                                    <Rectangle Height="46" Width="180" HorizontalAlignment="Left" Margin="0,10,0,0">
                                        <Rectangle.Fill><DrawingBrush TileMode="Tile" Viewport="0,0,20,20" ViewportUnits="Absolute"><DrawingBrush.Drawing><DrawingGroup><GeometryDrawing Brush="#FF334155"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,20,20"/></GeometryDrawing.Geometry></GeometryDrawing><GeometryDrawing Brush="#FF94A3B8"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,10,10"/></GeometryDrawing.Geometry></GeometryDrawing><GeometryDrawing Brush="#FF94A3B8"><GeometryDrawing.Geometry><RectangleGeometry Rect="10,10,10,10"/></GeometryDrawing.Geometry></GeometryDrawing></DrawingGroup></DrawingBrush.Drawing></DrawingBrush></Rectangle.Fill>
                                    </Rectangle>
                                    <TextBlock Text="FADING MASK" FontSize="26" FontWeight="Bold" HorizontalAlignment="Left" Margin="0,10,0,0"><TextBlock.OpacityMask><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#FF000000" Offset="0"/><GradientStop Color="#00000000" Offset="1"/></LinearGradientBrush></TextBlock.OpacityMask></TextBlock>
                                    <StackPanel Orientation="Horizontal" Margin="0,10,0,0"><Ellipse x:Name="BlurTarget" Width="40" Height="40" Fill="#FF22C55E" VerticalAlignment="Center"/><Button Content="Toggle BlurEffect" Click="BlurBtn_Click" Margin="10,0,0,0" VerticalAlignment="Center"/></StackPanel>
                                    <TextBlock Text="VisualBrush (live mirror), DrawingBrush (tiled checker), OpacityMask and BlurEffect." Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                        <GroupBox Header="Viewport3D - a rotating cube textured with generated pixels" MinWidth="700">
                            <StackPanel>
                                <Border Background="#FF0F172A" CornerRadius="8" Padding="4">
                                    <Viewport3D Height="190">
                                        <Viewport3D.Camera><PerspectiveCamera Position="2.4,2.2,4.6" LookDirection="-2.4,-2.2,-4.6" UpDirection="0,1,0"/></Viewport3D.Camera>
                                        <ModelVisual3D>
                                            <ModelVisual3D.Content>
                                                <Model3DGroup>
                                                    <AmbientLight Color="#FF505050"/>
                                                    <DirectionalLight Color="White" Direction="-0.4,-0.6,-1"/>
                                                    <GeometryModel3D x:Name="CubeModel">
                                                        <GeometryModel3D.Geometry><MeshGeometry3D Positions="-1,-1,-1 1,-1,-1 1,1,-1 -1,1,-1 -1,-1,1 1,-1,1 1,1,1 -1,1,1" TextureCoordinates="0,0 1,0 1,1 0,1 0,0 1,0 1,1 0,1" TriangleIndices="0,1,2 0,2,3 4,5,6 4,6,7 0,4,5 0,5,1 1,5,6 1,6,2 2,6,7 2,7,3 3,7,4 3,4,0"/></GeometryModel3D.Geometry>
                                                        <GeometryModel3D.Material><DiffuseMaterial Brush="#FF6366F1"/></GeometryModel3D.Material>
                                                        <GeometryModel3D.BackMaterial><DiffuseMaterial Brush="#FFDB2777"/></GeometryModel3D.BackMaterial>
                                                        <GeometryModel3D.Transform><RotateTransform3D><RotateTransform3D.Rotation><AxisAngleRotation3D x:Name="CubeSpin" Axis="0,1,0" Angle="0"/></RotateTransform3D.Rotation></RotateTransform3D></GeometryModel3D.Transform>
                                                    </GeometryModel3D>
                                                </Model3DGroup>
                                            </ModelVisual3D.Content>
                                        </ModelVisual3D>
                                    </Viewport3D>
                                </Border>
                                <WrapPanel Margin="0,8,0,0">
                                    <Button Content="Pause cube" Click="PauseCube_Click"/>
                                    <Button Content="Resume cube" Click="ResumeCube_Click"/>
                                    <Button Content="Pop out 3D theater (drag to rotate)" Click="PopCube_Click"/>
                                </WrapPanel>
                                <TextBlock x:Name="CubeInfo" Text="MeshGeometry3D + PerspectiveCamera + ambient and directional lights; pink faces are the BackMaterial." Margin="0,6,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>
                    <StackPanel x:Name="SecMedia" Visibility="Collapsed">
                        <TextBlock Text="Ink, Images, Sound and Video" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Ink drawing, pixel-generated bitmaps, synthesized audio and video playback." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <WrapPanel>
                            <GroupBox Header="Image - load it, or drop a file here" Width="340">
                                <StackPanel>
                                    <Grid x:Name="ImageZone" Height="150" Background="#FFF1F5F9" AllowDrop="True" Drop="ImageZone_Drop">
                                        <Rectangle Stroke="#FF94A3B8" StrokeDashArray="3 2" StrokeThickness="1.5" RadiusX="8" RadiusY="8" Fill="#FFFAFBFF"/>
                                        <TextBlock x:Name="ImageHint" Text="No image yet - load one or drop a picture file onto this area" Foreground="#FF64748B" HorizontalAlignment="Center" VerticalAlignment="Center" TextAlignment="Center" Margin="20,0"/>
                                        <Image x:Name="DemoImage" Stretch="Uniform" Margin="6"/>
                                    </Grid>
                                    <WrapPanel Margin="0,10,0,0">
                                        <Button Content="Load image..." Click="LoadImage_Click"/>
                                        <Button Content="Clear" Click="ClearImage_Click"/>
                                    </WrapPanel>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="WriteableBitmap - pixels from code" Width="340">
                                <StackPanel>
                                    <Image x:Name="PlasmaImage" Height="120" Stretch="Fill"/>
                                    <WrapPanel Margin="0,8,0,0">
                                        <Button Content="Regenerate" Click="GenBitmap_Click"/>
                                        <Button Content="Pop out Plasma lab" Click="PopPlasma_Click"/>
                                    </WrapPanel>
                                    <TextBlock Text="A WriteableBitmap written pixel-by-pixel from code; the popout animates it live with an FPS counter." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Sound synthesis and system sounds" Width="340">
                                <StackPanel>
                                    <WrapPanel>
                                        <Button Content="Play 440 Hz tone" Click="ToneA_Click"/>
                                        <Button Content="Play 880 Hz tone" Click="ToneB_Click"/>
                                        <Button Content="System sounds" Click="SysSounds_Click"/>
                                    </WrapPanel>
                                    <TextBlock Text="Tones are synthesized into WAV bytes in memory and played with System.Media.SoundPlayer - no audio files shipped." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="MediaElement - play local video or audio" Width="360">
                                <StackPanel>
                                    <MediaElement x:Name="DemoMedia" Height="140" LoadedBehavior="Manual" UnloadedBehavior="Stop" Stretch="Uniform" MediaOpened="DemoMedia_Opened" MediaFailed="DemoMedia_Failed"/>
                                    <WrapPanel Margin="0,8,0,0">
                                        <Button Content="Open media..." Click="MediaOpen_Click"/>
                                        <Button Content="Play" Click="MediaPlay_Click"/>
                                        <Button Content="Pause" Click="MediaPause_Click"/>
                                        <Button Content="Stop" Click="MediaStop_Click"/>
                                    </WrapPanel>
                                    <TextBlock Text="Pick any video or audio file on disk (mp4, wmv, mp3, wav...). Codec support comes from Windows itself; failures are reported, never fatal." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                        <GroupBox Header="InkCanvas - draw with the mouse" MinWidth="700">
                            <StackPanel>
                                <WrapPanel>
                                    <TextBlock Text="Color:" VerticalAlignment="Center"/>
                                    <ComboBox x:Name="InkColor" SelectedIndex="0" Width="120" Margin="6,0,12,0" SelectionChanged="InkColor_SelectionChanged">
                                        <ComboBoxItem Content="Black"/><ComboBoxItem Content="Blue"/><ComboBoxItem Content="Red"/><ComboBoxItem Content="Green"/><ComboBoxItem Content="Purple"/>
                                    </ComboBox>
                                    <TextBlock Text="Mode:" VerticalAlignment="Center"/>
                                    <ComboBox x:Name="InkMode" SelectedIndex="0" Width="140" Margin="6,0,12,0" SelectionChanged="InkMode_SelectionChanged">
                                        <ComboBoxItem Content="Draw"/><ComboBoxItem Content="Select"/><ComboBoxItem Content="Erase strokes"/>
                                    </ComboBox>
                                    <Button Content="Clear ink" Click="InkClear_Click"/>
                                    <Button Content="Pop out Ink studio (full window)" Click="PopInk_Click"/>
                                    <TextBlock x:Name="StrokeCount" VerticalAlignment="Center" Text="Strokes: 0" Margin="6,0,0,0"/>
                                </WrapPanel>
                                <InkCanvas x:Name="DemoInk" Height="180" Margin="0,10,0,0" Background="#FFFEFCE8" StrokeCollected="DemoInk_StrokeCollected" StrokeErased="DemoInk_StrokeErased"/>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>
                    <StackPanel x:Name="SecData" Visibility="Collapsed">
                        <TextBlock Text="Data, Binding and Validation" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Typed DataGrid columns, row details, grouping, converters and two kinds of validation." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <GroupBox Header="DataGrid: typed columns + row details" MinWidth="700">
                            <StackPanel>
                                <WrapPanel>
                                    <Button Content="Add row" Click="AddPerson_Click"/>
                                    <Button Content="Delete selected row" Click="RemovePerson_Click"/>
                                    <Button Content="Pop out DataGrid theater" Click="PopData_Click"/>
                                    <TextBlock x:Name="PeopleCount" VerticalAlignment="Center" Text="Rows: 0"/>
                                </WrapPanel>
                                <DataGrid x:Name="PeopleGrid" Height="190" Margin="0,10,0,0" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False" SelectionMode="Single" RowDetailsVisibilityMode="VisibleWhenSelected">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="140"/>
                                        <DataGridTextColumn Header="Age" Binding="{Binding Age}" Width="60"/>
                                        <DataGridTextColumn Header="City" Binding="{Binding City}" Width="110"/>
                                        <DataGridCheckBoxColumn Header="Active" Binding="{Binding Active}" Width="70"/>
                                        <DataGridTextColumn Header="Email" Binding="{Binding Email}" Width="170"/>
                                        <DataGridTemplateColumn Header="Score" Width="120">
                                            <DataGridTemplateColumn.CellTemplate>
                                                <DataTemplate><ProgressBar Value="{Binding Score}" Minimum="0" Maximum="100" Height="14" Width="90" VerticalAlignment="Center"/></DataTemplate>
                                            </DataGridTemplateColumn.CellTemplate>
                                        </DataGridTemplateColumn>
                                    </DataGrid.Columns>
                                    <DataGrid.RowDetailsTemplate>
                                        <DataTemplate>
                                            <Border Background="#FFF8FAFC" Padding="8">
                                                <StackPanel>
                                                    <TextBlock Text="{Binding City, StringFormat=Office: {0}}"/>
                                                    <TextBlock Text="Row details are visible while the row is selected." FontSize="11" Foreground="#FF6B7280"/>
                                                </StackPanel>
                                            </Border>
                                        </DataTemplate>
                                    </DataGrid.RowDetailsTemplate>
                                </DataGrid>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="CollectionViewSource: grouping, sorting, filtering" MinWidth="700">
                            <StackPanel>
                                <WrapPanel>
                                    <TextBox x:Name="FilterBox" Width="200" TextChanged="FilterBox_TextChanged" ToolTip="Live filter on product name"/>
                                    <Button Content="Sort by name" Click="SortName_Click"/>
                                    <Button Content="Sort by price" Click="SortPrice_Click"/>
                                    <TextBlock x:Name="ProductInfo" VerticalAlignment="Center" TextWrapping="Wrap"/>
                                </WrapPanel>
                                <ListView x:Name="ProductsList" Height="160" Margin="0,8,0,0">
                                    <ListView.View>
                                        <GridView>
                                            <GridViewColumn Header="Product" Width="210" DisplayMemberBinding="{Binding Name}"/>
                                            <GridViewColumn Header="Category" Width="130" DisplayMemberBinding="{Binding Category}"/>
                                            <GridViewColumn Header="Price" Width="90" DisplayMemberBinding="{Binding Price, StringFormat={}{0:N2}}"/>
                                        </GridView>
                                    </ListView.View>
                                    <ListView.GroupStyle>
                                        <GroupStyle>
                                            <GroupStyle.HeaderTemplate>
                                                <DataTemplate>
                                                    <StackPanel Orientation="Horizontal">
                                                        <TextBlock Text="{Binding Name}" FontWeight="Bold" Foreground="#FF4F46E5"/>
                                                        <TextBlock Text="{Binding ItemCount, StringFormat={}{0} item(s)}" FontWeight="Bold" Foreground="#FF4F46E5" Margin="6,0,0,0"/>
                                                    </StackPanel>
                                                </DataTemplate>
                                            </GroupStyle.HeaderTemplate>
                                        </GroupStyle>
                                    </ListView.GroupStyle>
                                </ListView>
                            </StackPanel>
                        </GroupBox>
                        <WrapPanel>
                            <GroupBox Header="Two-way data binding (INotifyPropertyChanged)" Width="360">
                                <StackPanel>
                                    <TextBlock Text="Name:"/>
                                    <TextBox Text="{Binding Vm.Name, UpdateSourceTrigger=PropertyChanged}" Margin="0,4,0,10"/>
                                    <TextBlock Text="Age (drag the slider):"/>
                                    <Slider Minimum="1" Maximum="120" Value="{Binding Vm.Age}" IsSnapToTickEnabled="True" TickFrequency="1" Margin="0,4,0,10"/>
                                    <TextBlock Text="{Binding Vm.Greeting}" FontWeight="Bold" Foreground="#FF4F46E5" TextWrapping="Wrap"/>
                                    <Button Content="Reset to defaults" Margin="0,12,0,0" Click="ResetVm_Click"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="IValueConverter + live cross-section join" Width="360">
                                <StackPanel>
                                    <TextBlock Text="Move the slider - an IValueConverter formats it:"/>
                                    <Slider x:Name="ConvSlider" Minimum="0" Maximum="1024" Value="512" ValueChanged="JoinSlider_ValueChanged"/>
                                    <TextBlock x:Name="ConvLabel" FontWeight="Bold" Foreground="#FF047857" Margin="0,6,0,10"/>
                                    <TextBlock Text="Three controls from three different sections, joined live:"/>
                                    <TextBlock x:Name="ComboJoinText" FontWeight="SemiBold" Foreground="#FF4F46E5" Margin="0,4,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="ValidationRule (score must be 0-100)" Width="360">
                                <StackPanel>
                                    <TextBlock Text="Score:"/>
                                    <TextBox x:Name="ScoreBox" Style="{StaticResource ValidatedBox}" Margin="0,4,0,0"/>
                                    <TextBlock x:Name="ScoreErr" Text="Type a score between 0 and 100." Margin="0,6,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                    <TextBlock Text="A custom ValidationRule rejects bad values; the Validation.HasError style trigger paints the box red." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="IDataErrorInfo validation (ViewModel-driven)" Width="360">
                                <StackPanel>
                                    <TextBlock Text="Name (leave empty to see the error):"/>
                                    <TextBox Text="{Binding Vm.Name, UpdateSourceTrigger=PropertyChanged, ValidatesOnDataErrors=True}" Style="{StaticResource ValidatedBox}" Margin="0,4,0,0"/>
                                    <TextBlock Text="{Binding Vm.Error}" Foreground="#FFB91C1C" TextWrapping="Wrap" Margin="0,6,0,0"/>
                                    <TextBlock Text="The ViewModel implements IDataErrorInfo; ValidatesOnDataErrors asks it for errors on every keystroke." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="FindAncestor, x:Array, TargetNullValue" Width="380">
                                <StackPanel>
                                    <ListBox Height="70" Tag="read from ListBox.Tag via FindAncestor">
                                        <ListBox.ItemTemplate>
                                            <DataTemplate>
                                                <StackPanel Orientation="Horizontal">
                                                    <TextBlock Text="{Binding}" FontWeight="SemiBold"/>
                                                    <TextBlock Text="{Binding Tag, RelativeSource={RelativeSource AncestorType=ListBox}}" Foreground="#FF6B7280" Margin="8,0,0,0"/>
                                                </StackPanel>
                                            </DataTemplate>
                                        </ListBox.ItemTemplate>
                                        <sys:String>Alpha</sys:String>
                                        <sys:String>Bravo</sys:String>
                                    </ListBox>
                                    <TextBlock Text="x:Array feeds this combo without any C#:" Margin="0,8,0,0"/>
                                    <ComboBox x:Name="ArrayCombo" SelectedIndex="0" Margin="0,4,0,0">
                                        <ComboBox.ItemsSource>
                                            <x:Array Type="sys:String"><sys:String>North</sys:String><sys:String>East</sys:String><sys:String>South</sys:String><sys:String>West</sys:String></x:Array>
                                        </ComboBox.ItemsSource>
                                    </ComboBox>
                                    <TextBlock Text="{Binding SelectedItem, ElementName=ArrayCombo, TargetNullValue=(pick a direction)}" Margin="0,4,0,0"/>
                                    <TextBlock Text="{Binding Vm.Nickname, TargetNullValue=(Nickname is null - TargetNullValue supplied this text)}" FontStyle="Italic" Foreground="#FFB45309" Margin="0,8,0,0" TextWrapping="Wrap"/>
                                    <TextBlock Text="RelativeSource FindAncestor walks the tree up; x:Array builds an array in pure XAML; TargetNullValue handles null bindings." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="BooleanToVisibilityConverter + FallbackValue" Width="360">
                                <StackPanel>
                                    <CheckBox x:Name="VisCheck" Content="Show the secret panel" IsChecked="True"/>
                                    <Border Background="#FFFEF9C3" CornerRadius="8" Padding="12" Margin="0,8,0,0" Visibility="{Binding IsChecked, ElementName=VisCheck, Converter={StaticResource B2V}}">
                                        <TextBlock Text="Secret panel: Visibility is bound to the CheckBox through the built-in BooleanToVisibilityConverter." TextWrapping="Wrap"/>
                                    </Border>
                                    <TextBlock Margin="0,10,0,0" TextWrapping="Wrap" FontStyle="Italic" Foreground="#FF6B7280" Text="{Binding Vm.NoSuchProperty, FallbackValue='FallbackValue demo: the binding path does not exist, so this fallback text is displayed instead.'}"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="ItemsControl with DataTemplate + DataTrigger" Width="360">
                                <StackPanel>
                                    <ItemsControl x:Name="TeamList">
                                        <ItemsControl.ItemTemplate>
                                            <DataTemplate>
                                                <Border CornerRadius="8" Padding="10" Margin="0,0,0,8">
                                                    <Border.Style>
                                                        <Style TargetType="Border">
                                                            <Setter Property="Background" Value="#FFEEF2FF"/>
                                                            <Style.Triggers>
                                                                <DataTrigger Binding="{Binding Role}" Value="Team lead">
                                                                    <Setter Property="BorderBrush" Value="#FFF59E0B"/>
                                                                    <Setter Property="BorderThickness" Value="2"/>
                                                                </DataTrigger>
                                                            </Style.Triggers>
                                                        </Style>
                                                    </Border.Style>
                                                    <StackPanel Orientation="Horizontal">
                                                        <Ellipse Width="34" Height="34" Fill="{Binding Color}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                                                        <StackPanel VerticalAlignment="Center">
                                                            <TextBlock Text="{Binding Name}" FontWeight="SemiBold"/>
                                                            <TextBlock Text="{Binding Role}" FontSize="12" Foreground="#FF6B7280"/>
                                                        </StackPanel>
                                                    </StackPanel>
                                                </Border>
                                            </DataTemplate>
                                        </ItemsControl.ItemTemplate>
                                    </ItemsControl>
                                    <TextBlock Text="The DataTrigger gives team leads a gold border - appearance driven by the data itself." Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                    </StackPanel>
                    <StackPanel x:Name="SecStyles" Visibility="Collapsed">
                        <TextBlock Text="Styles, Themes and Animation" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Live theming, keyframes, path animations, gradient breathing, triggers and transforms." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <WrapPanel>
                            <GroupBox Header="DynamicResource live theming" Width="360">
                                <StackPanel>
                                    <Border Background="{DynamicResource CardBg}" CornerRadius="10" Padding="14" BorderBrush="{DynamicResource AccentBrush}" BorderThickness="2">
                                        <StackPanel>
                                            <TextBlock Text="Themed card" FontWeight="Bold" FontSize="16" Foreground="{DynamicResource CardFg}"/>
                                            <ProgressBar Value="65" Height="14" Foreground="{DynamicResource AccentBrush}" Margin="0,8,0,0"/>
                                            <Button Content="I follow AccentBrush" Background="{DynamicResource AccentBrush}" Foreground="White" BorderThickness="0" Margin="0,10,0,0" Click="ThemedBtn_Click"/>
                                        </StackPanel>
                                    </Border>
                                    <Button Content="Swap the palette" Margin="0,10,0,0" Click="ThemeToggle_Click"/>
                                    <TextBlock Text="DynamicResource bindings re-evaluate the moment the brushes are swapped from code." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="MultiDataTrigger (two conditions)" Width="360">
                                <StackPanel>
                                    <CheckBox x:Name="TrigA" Content="Condition A"/>
                                    <CheckBox x:Name="TrigB" Content="Condition B" Margin="0,6,0,0"/>
                                    <Rectangle Width="140" Height="36" RadiusX="9" RadiusY="9" Margin="0,10,0,0" HorizontalAlignment="Left">
                                        <Rectangle.Style>
                                            <Style TargetType="Rectangle">
                                                <Setter Property="Fill" Value="#FFCBD5E1"/>
                                                <Style.Triggers>
                                                    <MultiDataTrigger>
                                                        <MultiDataTrigger.Conditions>
                                                            <Condition Binding="{Binding IsChecked, ElementName=TrigA}" Value="True"/>
                                                            <Condition Binding="{Binding IsChecked, ElementName=TrigB}" Value="True"/>
                                                        </MultiDataTrigger.Conditions>
                                                        <Setter Property="Fill" Value="#FF22C55E"/>
                                                    </MultiDataTrigger>
                                                </Style.Triggers>
                                            </Style>
                                        </Rectangle.Style>
                                    </Rectangle>
                                    <TextBlock Text="The rectangle turns green only when BOTH checkboxes are checked - pure XAML." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Animated GradientStop (breathing gradient)" Width="360">
                                <StackPanel>
                                    <Rectangle Height="44" RadiusX="10" RadiusY="10">
                                        <Rectangle.Fill>
                                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                                <GradientStop x:Name="GlowA" Color="#FF4F46E5" Offset="0"/>
                                                <GradientStop x:Name="GlowB" Color="#FFEC4899" Offset="1"/>
                                            </LinearGradientBrush>
                                        </Rectangle.Fill>
                                    </Rectangle>
                                    <Button Content="Toggle the breathing gradient" Margin="0,10,0,0" Click="GlowBtn_Click"/>
                                    <TextBlock Text="ColorAnimation on the GradientStops of a live brush - the endpoints breathe forever." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Glow, TransformGroup, pure-XAML animation" Width="360">
                                <StackPanel>
                                    <TextBlock Text="NEON GLOW" FontSize="30" FontWeight="Bold" Foreground="#FF22D3EE" HorizontalAlignment="Left">
                                        <TextBlock.Effect><DropShadowEffect Color="#FF22D3EE" BlurRadius="18" ShadowDepth="0"/></TextBlock.Effect>
                                    </TextBlock>
                                    <TextBlock Text="TRANSFORMED" FontSize="18" FontWeight="Bold" Foreground="#FF9333EA" HorizontalAlignment="Left" Margin="0,10,0,0">
                                        <TextBlock.RenderTransform>
                                            <TransformGroup><RotateTransform Angle="-8"/><SkewTransform AngleX="12"/><ScaleTransform ScaleX="1.12"/></TransformGroup>
                                        </TextBlock.RenderTransform>
                                    </TextBlock>
                                    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                        <Button Content="Grow (pure XAML)" MinWidth="140" VerticalAlignment="Center">
                                            <Button.Triggers>
                                                <EventTrigger RoutedEvent="Button.Click">
                                                    <BeginStoryboard>
                                                        <Storyboard>
                                                            <DoubleAnimation Storyboard.TargetName="XamlAnimRect" Storyboard.TargetProperty="Width" To="210" Duration="0:0:0.7" AutoReverse="True"/>
                                                            <DoubleAnimation Storyboard.TargetName="XamlAnimRect" Storyboard.TargetProperty="Height" To="64" Duration="0:0:0.7" AutoReverse="True"/>
                                                        </Storyboard>
                                                    </BeginStoryboard>
                                                </EventTrigger>
                                            </Button.Triggers>
                                        </Button>
                                        <Rectangle x:Name="XamlAnimRect" Width="90" Height="34" RadiusX="8" RadiusY="8" Fill="#FF0EA5E9" Margin="10,0,0,0" VerticalAlignment="Center"/>
                                    </StackPanel>
                                    <TextBlock Text="DropShadowEffect glow, a TransformGroup (rotate + skew + scale) and a Storyboard declared 100 percent in XAML - the grow button has no C# handler." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="MatrixAnimationUsingPath (follow the curve)" Width="360">
                                <StackPanel>
                                    <Canvas x:Name="RocketCanvas" Height="120" Background="#FFF8FAFC">
                                        <Path Stroke="#FF94A3B8" StrokeThickness="2" StrokeDashArray="3 2" Data="M 16,80 C 90,0 200,160 300,50"/>
                                        <Polygon x:Name="Rocket" Points="-9,-6 12,0 -9,6 -5,0" Fill="#FFDC2626"/>
                                    </Canvas>
                                    <Button Content="Launch along the curve" Margin="0,10,0,0" Click="RocketBtn_Click"/>
                                    <TextBlock Text="MatrixAnimationUsingPath with DoesRotateWithTangent - the arrow follows the dashed Bezier and points along it." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Keyframe animation" Width="360">
                                <StackPanel>
                                    <Grid Height="60" Background="#FFF8FAFC">
                                        <Ellipse x:Name="KeyCircle" Width="34" Height="34" Fill="#FF0EA5E9" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="10,0,0,0"/>
                                    </Grid>
                                    <Button Content="Run keyframes" Margin="0,10,0,0" Click="Keyframes_Click"/>
                                    <TextBlock Text="DoubleAnimationUsingKeyFrames: an easing keyframe, a discrete hold, then a linear return - one timeline." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="LayoutTransform vs RenderTransform" Width="360">
                                <StackPanel>
                                    <Button Content="LayoutTransform scales LAYOUT" HorizontalAlignment="Left">
                                        <Button.LayoutTransform><ScaleTransform ScaleX="1.5" ScaleY="1.5"/></Button.LayoutTransform>
                                    </Button>
                                    <Button Content="RenderTransform scales VISUALS only" HorizontalAlignment="Left" Margin="0,10,0,0" RenderTransformOrigin="0,0.5">
                                        <Button.RenderTransform><ScaleTransform ScaleX="1.5" ScaleY="1.5"/></Button.RenderTransform>
                                    </Button>
                                    <TextBlock Text="LayoutTransform re-runs layout so neighbors move; RenderTransform just redraws pixels in place." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                        <GroupBox Header="Animations driven from code" MinWidth="700">
                            <StackPanel>
                                <WrapPanel>
                                    <Button Content="Grow and shrink" Click="AnimSize_Click"/>
                                    <Button Content="Flash the box" Click="AnimColor_Click"/>
                                    <Button Content="Spin forever" Click="AnimSpin_Click"/>
                                    <Button Content="Pulse" Click="AnimPulse_Click"/>
                                    <Button Content="Fade the stage" Click="AnimFade_Click"/>
                                    <Button Content="Stop all motion" Click="AnimStop_Click"/>
                                </WrapPanel>
                                <Grid x:Name="AnimStage" Height="170" Margin="0,10,0,0" Background="#FFF8FAFC">
                                    <Ellipse x:Name="AnimEllipse" Width="60" Height="60" Fill="#FF6366F1" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="20"/>
                                    <Rectangle x:Name="AnimRect" Width="100" Height="64" RadiusX="12" RadiusY="12" Fill="#FF22C55E" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    <Ellipse x:Name="AnimSpinner" Width="52" Height="52" Fill="#FFEC4899" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="20" RenderTransformOrigin="0.5,0.5"/>
                                </Grid>
                                <TextBlock Text="DoubleAnimation, ColorAnimation, ScaleTransform and RotateTransform - all started from C# event handlers." Margin="0,10,0,0" Foreground="#FF6B7280"/>
                            </StackPanel>
                        </GroupBox>
                        <WrapPanel>
                            <GroupBox Header="ControlTemplate (re-templated button)" Width="360">
                                <StackPanel>
                                    <Button Content="I am a rounded template button" Click="BtnRounded_Click" Margin="0,0,0,10" HorizontalAlignment="Left">
                                        <Button.Template>
                                            <ControlTemplate TargetType="Button">
                                                <Border x:Name="bd" Background="#FF4F46E5" CornerRadius="22" Padding="18,10" Cursor="Hand">
                                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" TextElement.Foreground="White"/>
                                                </Border>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#FF7C3AED"/></Trigger>
                                                    <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#FF312E81"/></Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Button.Template>
                                    </Button>
                                    <TextBlock Text="The whole visual tree of this button is replaced by one Border - triggers repaint it on hover and press." Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Modern animated switch" Width="360">
                                <StackPanel>
                                    <ToggleButton x:Name="SwitchDemo" Width="78" Height="30" HorizontalAlignment="Left" Click="SwitchDemo_Click">
                                        <ToggleButton.Template>
                                            <ControlTemplate TargetType="ToggleButton">
                                                <Border x:Name="track" Background="#FFCBD5E1" CornerRadius="15">
                                                    <Grid>
                                                        <TextBlock Text="OFF" Foreground="White" FontWeight="Bold" FontSize="11" Margin="10,0,0,0" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                                                        <TextBlock Text="ON" Foreground="White" FontWeight="Bold" FontSize="11" Margin="0,0,10,0" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                                                        <Border Width="22" Height="22" Background="White" CornerRadius="11" HorizontalAlignment="Left" Margin="4,0,0,0" VerticalAlignment="Center">
                                                            <Border.RenderTransform><TranslateTransform x:Name="knobT" X="0"/></Border.RenderTransform>
                                                        </Border>
                                                    </Grid>
                                                </Border>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsChecked" Value="True">
                                                        <Setter TargetName="track" Property="Background" Value="#FF22C55E"/>
                                                        <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="knobT" Storyboard.TargetProperty="X" To="46" Duration="0:0:0.15"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
                                                        <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="knobT" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.15"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </ToggleButton.Template>
                                    </ToggleButton>
                                    <TextBlock x:Name="SwitchState" Text="Switch is OFF" Margin="0,10,0,0" Foreground="#FF047857"/>
                                    <TextBlock Text="A ToggleButton re-skinned into a sliding switch with an animated knob." Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="ToolTip timing and Hyperlink" Width="360">
                                <StackPanel>
                                    <Button Content="Hover me first, then click" ToolTip="A ToolTip can hold any content - even whole panels." Click="TipBtn_Click" Margin="0"/>
                                    <Button Content="Slow tooltip (1.5 s delay)" ToolTip="I appear after 1.5 seconds - ToolTipService.InitialShowDelay in action." ToolTipService.InitialShowDelay="1500" ToolTipService.BetweenShowDelay="0" Margin="0,8,0,0"/>
                                    <Button Content="Hover for a rich ToolTip" Click="TipRich_Click" Margin="0,8,0,0">
                                        <Button.ToolTip>
                                            <StackPanel>
                                                <TextBlock Text="Rich ToolTip" FontWeight="Bold" FontSize="14"/>
                                                <TextBlock Text="A ToolTip is a full ContentPresenter: panels, shapes, whatever you like." MaxWidth="220" TextWrapping="Wrap"/>
                                            </StackPanel>
                                        </Button.ToolTip>
                                    </Button>
                                    <TextBlock Margin="0,12,0,0" TextWrapping="Wrap">Full WPF docs live at <Hyperlink NavigateUri="https://learn.microsoft.com/dotnet/desktop/wpf/" RequestNavigate="DocLink_RequestNavigate">learn.microsoft.com</Hyperlink> - clicking opens your default browser.</TextBlock>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                    </StackPanel>
                    <StackPanel x:Name="SecCustom" Visibility="Collapsed">
                        <TextBlock Text="Custom Controls, Adorners and Runtime XAML" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Hand-written controls, a UserControl, adorners, live XAML parsing and PNG snapshots." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <WrapPanel>
                            <GroupBox Header="Custom control: Gauge (DependencyProperty + OnRender)" Width="340">
                                <StackPanel>
                                    <Grid x:Name="GaugeHost" Height="140"/>
                                    <Slider x:Name="GaugeSlider" Minimum="0" Maximum="100" Value="65" Margin="0,8,0,0"/>
                                    <TextBlock Text="The gauge is a hand-written FrameworkElement: Value is a DependencyProperty with AffectsRender, painted entirely in OnRender." TextWrapping="Wrap" Margin="0,8,0,0" Foreground="#FF6B7280"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="UserControl: RatingStars" Width="340">
                                <StackPanel>
                                    <ContentControl x:Name="RatingHost"/>
                                    <TextBlock x:Name="RatingLabel" Text="Rate this gallery:" Margin="0,8,0,0"/>
                                    <TextBlock Text="A code-only UserControl hosting five ToggleButtons and raising a Rated event." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Adorner layer (drawn OVER the control)" Width="340">
                                <StackPanel>
                                    <Border x:Name="AdornTarget" Background="#FFEEF2FF" BorderBrush="#FF6366F1" BorderThickness="1" CornerRadius="8" Padding="16" HorizontalAlignment="Left">
                                        <TextBlock Text="I can wear an adorner ring" FontWeight="SemiBold"/>
                                    </Border>
                                    <Button Content="Toggle ring adorner" Margin="0,10,0,0" Click="AdornBtn_Click"/>
                                    <TextBlock x:Name="AdornInfo" Text="Adorners draw in a layer above the control without touching its layout." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="RenderTargetBitmap snapshot" Width="340">
                                <StackPanel>
                                    <TextBlock Text="Renders this entire window into a PNG via RenderTargetBitmap and copies it to the clipboard." TextWrapping="Wrap"/>
                                    <Button Content="Take snapshot" Margin="0,10,0,0" Click="SnapshotBtn_Click"/>
                                    <TextBlock x:Name="SnapshotResult" Margin="0,8,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                        <GroupBox Header="Runtime XAML playground (XamlReader.Parse)" MinWidth="700">
                            <StackPanel>
                                <TextBox x:Name="XamlBox" AcceptsReturn="True" Height="100" TextWrapping="Wrap" FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto"/>
                                <WrapPanel Margin="0,8,0,0">
                                    <Button Content="Render the XAML" Click="XamlRender_Click"/>
                                    <Button Content="Reset sample" Click="XamlReset_Click"/>
                                </WrapPanel>
                                <ContentControl x:Name="XamlHost" Margin="0,8,0,0"/>
                                <TextBlock x:Name="XamlErr" Foreground="#FFB91C1C" TextWrapping="Wrap"/>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="Glyphs - raw glyph runs" MinWidth="700">
                            <StackPanel>
                                <Canvas x:Name="GlyphCanvas" Height="34" Background="#FFF8FAFC"/>
                                <TextBlock x:Name="GlyphInfo" Margin="0,8,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>
                    <StackPanel x:Name="SecDialogs" Visibility="Collapsed">
                        <TextBlock Text="Dialogs, Files and Printing" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Real modal dialogs - message boxes, file pickers and the print dialog." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <WrapPanel>
                            <GroupBox Header="MessageBox variants" Width="360">
                                <StackPanel>
                                    <WrapPanel>
                                        <Button Content="Info" Click="MsgInfo_Click"/>
                                        <Button Content="Warning" Click="MsgWarn_Click"/>
                                        <Button Content="Error" Click="MsgError_Click"/>
                                        <Button Content="Yes / No" Click="MsgYesNo_Click"/>
                                    </WrapPanel>
                                    <TextBlock x:Name="DialogMsgResult" Margin="0,8,0,0" Foreground="#FF047857" TextWrapping="Wrap" Text="Last MessageBox result appears here."/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Open and save files" Width="360">
                                <StackPanel>
                                    <WrapPanel>
                                        <Button Content="Open a file..." Click="OpenFileBtn_Click"/>
                                        <Button Content="Open images (multi)..." Click="OpenMultiBtn_Click"/>
                                        <Button Content="Save a note..." Click="SaveFileBtn_Click"/>
                                    </WrapPanel>
                                    <TextBlock Text="These are the WPF (Microsoft.Win32) dialogs - no WinForms anywhere in this app." Margin="0,4,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="DialogFileResult" Margin="0,10,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="PrintDialog" Width="360">
                                <StackPanel>
                                    <Button Content="Print a sample card..." Click="PrintBtn_Click"/>
                                    <TextBlock Text="Builds a card visual in memory and sends it with PrintVisual after you pick a printer." Margin="0,4,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="PrintResult" Margin="0,10,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                    </StackPanel>
                    <StackPanel x:Name="SecDocs" Visibility="Collapsed">
                        <TextBlock Text="Documents, Frames and Web" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Frame navigation, the three flow viewers, a fixed document and the browser host." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <GroupBox Header="Frame with navigation journal" MinWidth="700">
                            <StackPanel>
                                <Frame x:Name="DemoFrame" Height="140" NavigationUIVisibility="Visible" Source="GalleryPage1.xaml" Background="White"/>
                                <WrapPanel Margin="0,10,0,0">
                                    <Button Content="Go to page 2" Click="FramePage2_Click"/>
                                    <Button Content="Back" Click="FrameBack_Click"/>
                                    <Button Content="Forward" Click="FrameFwd_Click"/>
                                </WrapPanel>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="FlowDocumentScrollViewer with a hosted Floater" MinWidth="700">
                            <StackPanel>
                                <FlowDocumentScrollViewer Height="190">
                                    <FlowDocument FontFamily="Segoe UI" PagePadding="6">
                                        <Paragraph FontSize="18" FontWeight="Bold" Foreground="#FF312E81">A real flow document</Paragraph>
                                        <Paragraph>FlowDocumentScrollViewer reflows rich content like a reader: paragraphs, lists, tables and hyperlinks, with zoom and scroll built in.</Paragraph>
                                        <Paragraph>
                                            <Floater Width="150" Background="#FFEEF2FF" BorderBrush="#FF6366F1" BorderThickness="1" Padding="8">
                                                <Paragraph FontSize="11">A Floater must live inside a Paragraph - it is an inline element that floats beside the running text like a margin note.</Paragraph>
                                            </Floater>
                                            This paragraph hosts the Floater above: margin notes float beside the running text while the document reflows around them.
                                        </Paragraph>
                                        <List><ListItem><Paragraph>Bullet item one</Paragraph></ListItem><ListItem><Paragraph>Bullet item two</Paragraph></ListItem></List>
                                        <Table CellSpacing="0">
                                            <TableRowGroup>
                                                <TableRow><TableCell BorderBrush="#FF94A3B8" BorderThickness="1"><Paragraph FontWeight="Bold">Column A</Paragraph></TableCell><TableCell BorderBrush="#FF94A3B8" BorderThickness="1"><Paragraph FontWeight="Bold">Column B</Paragraph></TableCell></TableRow>
                                                <TableRow><TableCell BorderBrush="#FF94A3B8" BorderThickness="1"><Paragraph>Cell one</Paragraph></TableCell><TableCell BorderBrush="#FF94A3B8" BorderThickness="1"><Paragraph>Cell two</Paragraph></TableCell></TableRow>
                                            </TableRowGroup>
                                        </Table>
                                        <Section Background="#FFF0FDF4" Padding="8"><Paragraph>This paragraph lives in a Section block with its own background - flow documents nest blocks arbitrarily.</Paragraph></Section>
                                    </FlowDocument>
                                </FlowDocumentScrollViewer>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="FlowDocumentReader (search + view modes)" MinWidth="700">
                            <FlowDocumentReader Height="170">
                                <FlowDocument FontFamily="Segoe UI" PagePadding="8">
                                    <Paragraph FontSize="16" FontWeight="Bold">Reader mode</Paragraph>
                                    <Paragraph>FlowDocumentReader offers page view, two-page view and scrolling view plus a live search box in its chrome. Try the magnifier.</Paragraph>
                                    <List><ListItem><Paragraph>Mode switching</Paragraph></ListItem><ListItem><Paragraph>Full-text search</Paragraph></ListItem><ListItem><Paragraph>Zoom</Paragraph></ListItem></List>
                                </FlowDocument>
                            </FlowDocumentReader>
                        </GroupBox>
                        <GroupBox Header="FlowDocumentPageViewer" MinWidth="700">
                            <FlowDocumentPageViewer Height="120">
                                <FlowDocument PagePadding="10">
                                    <Paragraph>PageViewer lays the flow content out like printed pages with page navigation at the bottom.</Paragraph>
                                    <Paragraph>Same FlowDocument engine, different chrome.</Paragraph>
                                </FlowDocument>
                            </FlowDocumentPageViewer>
                        </GroupBox>
                        <GroupBox Header="DocumentViewer with a code-built FixedDocument" MinWidth="700">
                            <StackPanel>
                                <DocumentViewer x:Name="FixedViewer" Height="200"/>
                                <TextBlock x:Name="FixedInfo" Margin="0,8,0,0" Foreground="#FF047857" TextWrapping="Wrap"/>
                                <Button Content="Pop out Document theater" Click="PopDoc_Click" Margin="0,10,0,0" HorizontalAlignment="Left"/>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="WebBrowser" MinWidth="700">
                            <StackPanel>
                                <WrapPanel>
                                    <Button Content="Load sample page" Click="DemoWebLoad_Click"/>
                                    <TextBlock Text="Static HTML generated in memory - no internet needed." Margin="6,4,0,0" Foreground="#FF6B7280" VerticalAlignment="Center"/>
                                </WrapPanel>
                                <WebBrowser x:Name="DemoWeb" Height="140" Margin="0,10,0,0"/>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>
                    <StackPanel x:Name="SecDrag" Visibility="Collapsed">
                        <TextBlock Text="Drag, Drop, Popups and Virtualization" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Floating surfaces, draggable thumbs, drag-and-drop and a 10,000-row virtualized list." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <WrapPanel>
                            <GroupBox Header="Popup" Width="340">
                                <StackPanel>
                                    <ToggleButton x:Name="PopupToggle" Content="Open the popup" Click="PopupToggle_Click"/>
                                    <Popup x:Name="DemoPopup" AllowsTransparency="True" PopupAnimation="Fade" Placement="Bottom" PlacementTarget="{Binding ElementName=PopupToggle}" StaysOpen="False" Closed="DemoPopup_Closed">
                                        <Border Background="White" BorderBrush="#FF6366F1" BorderThickness="1" CornerRadius="10" Padding="16" Margin="0,6,8,8">
                                            <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.3"/></Border.Effect>
                                            <StackPanel>
                                                <TextBlock Text="Hello from a Popup" FontWeight="Bold" Foreground="#FF312E81"/>
                                                <TextBlock Text="A Popup floats above everything and closes when you click away." Margin="0,6,0,0" TextWrapping="Wrap" Width="210"/>
                                            </StackPanel>
                                        </Border>
                                    </Popup>
                                    <TextBlock Text="Popup is a floating surface anchored to any element." Margin="0,10,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Thumb - drag me" Width="340">
                                <StackPanel>
                                    <Canvas x:Name="DragCanvas" Height="140" Background="#FFF8FAFC">
                                        <TextBlock Text="Drag the shapes with the mouse" Foreground="#FF94A3B8" Canvas.Left="8" Canvas.Top="120"/>
                                        <Thumb Canvas.Left="24" Canvas.Top="18" Width="60" Height="60" Cursor="SizeAll" DragStarted="DragThumb_DragStarted" DragDelta="DragThumb_DragDelta">
                                            <Thumb.Template><ControlTemplate TargetType="Thumb"><Ellipse Fill="#FF6366F1" Stroke="White" StrokeThickness="2"/></ControlTemplate></Thumb.Template>
                                        </Thumb>
                                        <Thumb Canvas.Left="130" Canvas.Top="34" Width="60" Height="60" Cursor="SizeAll" DragStarted="DragThumb_DragStarted" DragDelta="DragThumb_DragDelta">
                                            <Thumb.Template><ControlTemplate TargetType="Thumb"><Rectangle Fill="#FFEC4899" RadiusX="10" RadiusY="10" Stroke="White" StrokeThickness="2"/></ControlTemplate></Thumb.Template>
                                        </Thumb>
                                    </Canvas>
                                    <TextBlock x:Name="DragState" Margin="0,8,0,0" Foreground="#FF047857"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Drag and drop between lists" Width="340">
                                <StackPanel>
                                    <StackPanel Orientation="Horizontal">
                                        <ListBox x:Name="DragListA" Width="130" Height="120" MouseMove="DragSrc_MouseMove" AllowDrop="True" Drop="DragTgt_Drop" DragOver="DragTgt_Over"/>
                                        <ListBox x:Name="DragListB" Width="130" Height="120" Margin="10,0,0,0" MouseMove="DragSrc_MouseMove" AllowDrop="True" Drop="DragTgt_Drop" DragOver="DragTgt_Over"/>
                                    </StackPanel>
                                    <TextBlock Text="Drag an item from one list to the other with the left mouse button." Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="GridSplitter rows" Width="340">
                                <Grid Height="140">
                                    <Grid.RowDefinitions><RowDefinition/><RowDefinition Height="8"/><RowDefinition/></Grid.RowDefinitions>
                                    <Border Grid.Row="0" Background="#FFDBEAFE" CornerRadius="6"><TextBlock Text="Top row" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                                    <GridSplitter Grid.Row="1" Height="8" HorizontalAlignment="Stretch" VerticalAlignment="Center" ResizeDirection="Rows" ResizeBehavior="PreviousAndNext" Background="#FF94A3B8"/>
                                    <Border Grid.Row="2" Background="#FFDCFCE7" CornerRadius="6"><TextBlock Text="Bottom row" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                                </Grid>
                            </GroupBox>
                            <GroupBox Header="Extended ListBox selection" Width="340">
                                <StackPanel>
                                    <ListBox x:Name="MultiList" Height="110" SelectionMode="Extended" SelectionChanged="MultiList_SelectionChanged">
                                        <ListBoxItem Content="Red"/><ListBoxItem Content="Green"/><ListBoxItem Content="Blue"/><ListBoxItem Content="Yellow"/><ListBoxItem Content="Magenta"/>
                                    </ListBox>
                                    <TextBlock Text="Ctrl+click and Shift+click to select several items." Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="MultiResult" Margin="0,6,0,0" Foreground="#FF047857"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Checkable menu" Width="340">
                                <StackPanel>
                                    <Menu>
                                        <MenuItem Header="_View">
                                            <MenuItem Header="Status bar" IsCheckable="True" IsChecked="True" Checked="CheckMenu_Click" Unchecked="CheckMenu_Click"/>
                                            <MenuItem Header="Toolbar" IsCheckable="True" Checked="CheckMenu_Click" Unchecked="CheckMenu_Click"/>
                                            <Separator/>
                                            <MenuItem Header="_Refresh now" Click="MenuRefresh_Click"/>
                                        </MenuItem>
                                    </Menu>
                                    <TextBlock Text="Menu items can be plain, checkable or hierarchical." Margin="0,8,0,0" Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                        <GroupBox Header="VirtualizingStackPanel - 10,000 rows" MinWidth="700">
                            <StackPanel>
                                <WrapPanel>
                                    <Button Content="Generate 10,000 rows" Click="BigListGen_Click"/>
                                    <TextBlock x:Name="BigListInfo" VerticalAlignment="Center" TextWrapping="Wrap"/>
                                </WrapPanel>
                                <ListBox x:Name="BigList" Height="150" Margin="0,8,0,0" VirtualizingPanel.VirtualizationMode="Recycling" ScrollViewer.CanContentScroll="True"/>
                                <TextBlock Text="Only the visible rows are realized; recycling reuses the containers while you scroll." Foreground="#FF6B7280" Margin="0,6,0,0"/>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>
                    <StackPanel x:Name="SecSystem" Visibility="Collapsed">
                        <TextBlock Text="System, OS Integration and the Kitchen Sink" FontSize="22" FontWeight="Bold" Foreground="#FF312E81" Margin="0,0,0,2"/>
                        <TextBlock Text="Live OS theme brushes, machine facts, running processes and one button that triggers everything." Foreground="#FF6B7280" Margin="0,0,0,14"/>
                        <WrapPanel>
                            <GroupBox Header="SystemColors - live Windows palette" Width="360">
                                <StackPanel>
                                    <WrapPanel>
                                        <StackPanel Margin="0,0,10,8" Width="86"><Border Height="30" Background="{x:Static SystemColors.HighlightBrush}" CornerRadius="4"/><TextBlock Text="Highlight" FontSize="11" Margin="0,3,0,0"/></StackPanel>
                                        <StackPanel Margin="0,0,10,8" Width="86"><Border Height="30" Background="{x:Static SystemColors.ActiveCaptionBrush}" CornerRadius="4"/><TextBlock Text="ActiveCaption" FontSize="11" Margin="0,3,0,0"/></StackPanel>
                                        <StackPanel Margin="0,0,10,8" Width="86"><Border Height="30" Background="{x:Static SystemColors.ControlBrush}" CornerRadius="4"/><TextBlock Text="Control" FontSize="11" Margin="0,3,0,0"/></StackPanel>
                                        <StackPanel Margin="0,0,10,8" Width="86"><Border Height="30" Background="{x:Static SystemColors.WindowBrush}" CornerRadius="4"/><TextBlock Text="Window" FontSize="11" Margin="0,3,0,0"/></StackPanel>
                                        <StackPanel Margin="0,0,10,8" Width="86"><Border Height="30" Background="{x:Static SystemColors.InfoBrush}" CornerRadius="4"/><TextBlock Text="Info" FontSize="11" Margin="0,3,0,0"/></StackPanel>
                                    </WrapPanel>
                                    <TextBlock Text="These brushes come from the live Windows theme - change your accent color in Settings and they follow." Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Machine facts (SystemParameters + render tier)" Width="360">
                                <StackPanel>
                                    <TextBlock x:Name="SysInfoText" TextWrapping="Wrap"/>
                                    <TextBlock Text="SystemParameters reads the real desktop; RenderCapability.Tier reports hardware acceleration (2 = GPU)." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Swatch strip (Brush list + ItemsPanelTemplate)" Width="360">
                                <StackPanel>
                                    <ListBox x:Name="SwatchList" Height="66" Background="Transparent" BorderThickness="0">
                                        <ListBox.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ListBox.ItemsPanel>
                                        <ListBox.ItemTemplate><DataTemplate><Rectangle Width="30" Height="30" Fill="{Binding}" Margin="3" RadiusX="4" RadiusY="4" Stroke="#FFCBD5E1"/></DataTemplate></ListBox.ItemTemplate>
                                    </ListBox>
                                    <TextBlock Text="ItemsSource is a plain List of Brush objects; a DataTemplate paints each one as a rounded chip." Foreground="#FF6B7280" TextWrapping="Wrap"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="Running processes" Width="360">
                                <StackPanel>
                                    <ListBox x:Name="ProcList" Height="150"/>
                                    <TextBlock Text="A dozen live processes via System.Diagnostics - names, PIDs and working sets." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,8,0,0"/>
                                </StackPanel>
                            </GroupBox>
                            <GroupBox Header="THE KITCHEN SINK" Width="360">
                                <StackPanel>
                                    <Button Content="DEPLOY THE KITCHEN SINK" FontWeight="Bold" Style="{StaticResource GradientButton}" Click="SinkBtn_Click" Margin="0" HorizontalAlignment="Left"/>
                                    <TextBlock Text="Fires every animation, resumes the cube, generates the 10,000 rows, plays a tone, enables fun mode and teleports you to a random section - simultaneously." Foreground="#FF6B7280" TextWrapping="Wrap" Margin="0,10,0,0"/>
                                </StackPanel>
                            </GroupBox>
                        </WrapPanel>
                    </StackPanel>
                </Grid>
            </ScrollViewer>
        </Grid>
    </DockPanel>
</Window>
'@
 $mwCs=@'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Media.Media3D;
using System.Windows.Navigation;
using System.Windows.Shapes;

namespace __APPNAME__
{
    public partial class MainWindow : Window
    {
        public static readonly RoutedCommand BoostCommand = new RoutedCommand();
        private int repeatCount;
        private bool spinning;
        private bool cubeOn;
        private bool darkTheme;
        private bool glowOn;
        private bool stageFaded;
        private DoubleAnimation? cubeAnim;
        private RingAdorner? ringAdorner;
        private WriteableBitmap? plasmaBmp;
        private readonly Random rnd = new Random();
        private Brush? defaultBackground;
        private readonly System.Windows.Threading.DispatcherTimer clock = new System.Windows.Threading.DispatcherTimer();
        private readonly ObservableCollection<Person> people = new ObservableCollection<Person>();
        private readonly ObservableCollection<Product> products = new ObservableCollection<Product>();
        private readonly List<System.Media.SoundPlayer> tonePlayers = new List<System.Media.SoundPlayer>();
        private ICollectionView? productsView;

        public GalleryVm Vm { get; } = new GalleryVm();
        public List<HNode> TreeRoots { get; } = new List<HNode>();

        public MainWindow()
        {
            InitializeComponent();
            DataContext = this;
            people.Add(new Person { Name = "Ada Lovelace", Age = 36, City = "London", Email = "ada@example.com", Active = true, Score = 91 });
            people.Add(new Person { Name = "Alan Turing", Age = 41, City = "Wilmslow", Email = "alan@example.com", Active = true, Score = 88 });
            people.Add(new Person { Name = "Grace Hopper", Age = 85, City = "Arlington", Email = "grace@example.com", Active = false, Score = 97 });
            people.Add(new Person { Name = "Linus Torvalds", Age = 54, City = "Portland", Email = "linus@example.com", Active = true, Score = 76 });
            PeopleGrid.ItemsSource = people;
            people.CollectionChanged += (s, e) => PeopleCount.Text = "Rows: " + people.Count;
            PeopleCount.Text = "Rows: " + people.Count;
            FileList.ItemsSource = new List<FileRow> { new FileRow { Name = "Report.pdf", SizeKb = 842.5, Type = "PDF document", Modified = "Today, 09:14" }, new FileRow { Name = "Holiday.jpg", SizeKb = 2410.0, Type = "JPEG image", Modified = "Yesterday, 18:02" }, new FileRow { Name = "Setup.msi", SizeKb = 15400.0, Type = "Installer", Modified = "12 Mar 2024" }, new FileRow { Name = "Notes.txt", SizeKb = 3.2, Type = "Text document", Modified = "01 Jan 2024" } };
            List<TeamMember> team = new List<TeamMember> { new TeamMember { Name = "Ava Cado", Role = "Team lead", Color = Brushes.Indigo }, new TeamMember { Name = "Ben Ova", Role = "Developer", Color = Brushes.RoyalBlue }, new TeamMember { Name = "Cara Mel", Role = "Designer", Color = Brushes.HotPink }, new TeamMember { Name = "Dan Druff", Role = "Tester", Color = Brushes.SeaGreen } };
            TeamList.ItemsSource = team;
            TeamCombo.ItemsSource = team;
            TeamCombo.DisplayMemberPath = "Name";
            AltList.ItemsSource = new List<string> { "Mercury", "Venus", "Earth", "Mars", "Jupiter", "Saturn", "Uranus" };
            SwatchList.ItemsSource = new List<Brush> { new SolidColorBrush(Color.FromRgb(99, 102, 241)), new SolidColorBrush(Color.FromRgb(236, 72, 153)), new SolidColorBrush(Color.FromRgb(34, 197, 94)), new SolidColorBrush(Color.FromRgb(14, 165, 233)), new SolidColorBrush(Color.FromRgb(245, 158, 11)), new SolidColorBrush(Color.FromRgb(239, 68, 68)), new SolidColorBrush(Color.FromRgb(139, 92, 246)), new SolidColorBrush(Color.FromRgb(20, 184, 166)) };
            DragListA.Items.Add("Alpha"); DragListA.Items.Add("Bravo"); DragListA.Items.Add("Charlie"); DragListA.Items.Add("Delta"); DragListA.Items.Add("Echo");
            TreeRoots.Add(new HNode { Title = "Project Alpha", Done = true, Kids = new ObservableCollection<HNode> { new HNode { Title = "Design", Done = true, Kids = new ObservableCollection<HNode>() }, new HNode { Title = "Build", Done = false, Kids = new ObservableCollection<HNode> { new HNode { Title = "Compile", Done = false, Kids = new ObservableCollection<HNode>() }, new HNode { Title = "Test", Done = false, Kids = new ObservableCollection<HNode>() } } } } });
            TreeRoots.Add(new HNode { Title = "Project Beta", Done = false, Kids = new ObservableCollection<HNode> { new HNode { Title = "Spike", Done = false, Kids = new ObservableCollection<HNode>() }, new HNode { Title = "Polish", Done = false, Kids = new ObservableCollection<HNode>() } } });
            TreeBound.ItemsSource = TreeRoots;
            products.Add(new Product { Name = "Mechanical keyboard", Category = "Peripherals", Price = 129.90 });
            products.Add(new Product { Name = "Wireless mouse", Category = "Peripherals", Price = 49.50 });
            products.Add(new Product { Name = "USB-C dock", Category = "Peripherals", Price = 189.00 });
            products.Add(new Product { Name = "27-inch monitor", Category = "Displays", Price = 349.00 });
            products.Add(new Product { Name = "Portable projector", Category = "Displays", Price = 599.00 });
            products.Add(new Product { Name = "Noise-cancelling headset", Category = "Audio", Price = 219.99 });
            products.Add(new Product { Name = "Desktop microphone", Category = "Audio", Price = 89.00 });
            products.Add(new Product { Name = "Studio speakers", Category = "Audio", Price = 259.00 });
            ProductsList.ItemsSource = products;
            productsView = CollectionViewSource.GetDefaultView(products);
            productsView.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            UpdateProductInfo();
            Gauge gauge = new Gauge();
            Binding gb = new Binding("Value") { Source = GaugeSlider };
            gauge.SetBinding(Gauge.ValueProperty, gb);
            GaugeHost.Children.Add(gauge);
            RatingStars rs = new RatingStars();
            rs.Rated += (s, v) => { RatingLabel.Text = "You rated the gallery " + v + " / 5. Thank you!"; SetStatus("UserControl rating event: " + v + "/5."); };
            RatingHost.Content = rs;
            Binding kb = new Binding("Value") { Source = ConvSlider, Converter = new KiloFormatter(), Mode = BindingMode.OneWay };
            ConvLabel.SetBinding(TextBlock.TextProperty, kb);
            Binding sb = new Binding("Score") { Source = Vm, UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged };
            sb.ValidationRules.Add(new RangeRule(0, 100));
            ScoreBox.SetBinding(TextBox.TextProperty, sb);
            ScoreBox.TextChanged += (s, e2) => { ReadOnlyObservableCollection<ValidationError> errs = Validation.GetErrors(ScoreBox); if (errs.Count > 0) { ScoreErr.Text = (errs[0].ErrorContent as string) ?? "Invalid value."; ScoreErr.Foreground = Brushes.Red; } else { ScoreErr.Text = "Score is valid."; ScoreErr.Foreground = new SolidColorBrush(Color.FromRgb(4, 120, 87)); } };
            CommandBindings.Add(new CommandBinding(BoostCommand, OnBoostExecuted, OnBoostCanExecute));
            InputBindings.Add(new KeyBinding(BoostCommand, Key.B, ModifierKeys.Control));
            BoostBtn.Command = BoostCommand;
            try { BlockDatePick.BlackoutDates.AddDatesInPast(); BlockDatePick.BlackoutDates.Add(new CalendarDateRange(DateTime.Today.AddDays(7), DateTime.Today.AddDays(14))); } catch { }
            try { Glyphs gl = new Glyphs { FontUri = new Uri(@"C:\Windows\Fonts\segoeui.ttf"), UnicodeString = "Glyphs: a raw glyph run rendered directly", FontRenderingEmSize = 22, OriginX = 6, OriginY = 26, Fill = new SolidColorBrush(Color.FromRgb(49, 46, 129)) }; GlyphCanvas.Children.Add(gl); GlyphInfo.Text = "The Glyphs control paints raw glyph runs from a font file (segoeui.ttf)."; } catch (Exception ex) { GlyphInfo.Text = "Glyphs unavailable on this machine: " + ex.Message; }
            ResetXamlSample();
            GenPlasma();
            try { if (plasmaBmp != null) { ImageBrush tex = new ImageBrush(plasmaBmp); CubeModel.Material = new DiffuseMaterial(tex); CubeInfo.Text = "The cube is textured with the generated plasma bitmap (MeshGeometry3D TextureCoordinates + ImageBrush); ambient and directional lights are active. Pop it out to drag-rotate it."; } } catch { }
            UpdateJoinText();
            try { SysInfoText.Text = "Primary screen: " + SystemParameters.PrimaryScreenWidth.ToString("0") + " x " + SystemParameters.PrimaryScreenHeight.ToString("0") + "   Virtual desktop: " + SystemParameters.VirtualScreenWidth.ToString("0") + " x " + SystemParameters.VirtualScreenHeight.ToString("0") + "   Graphics render tier: " + (RenderCapability.Tier >> 16) + "   IsSlowMachine: " + SystemParameters.IsSlowMachine; } catch { }
            try { List<string> procs = new List<string>(); foreach (Process p in Process.GetProcesses().OrderBy(p => p.ProcessName, StringComparer.OrdinalIgnoreCase).Take(12)) { string mem = "?"; try { mem = (p.WorkingSet64 / (1024 * 1024)) + " MB"; } catch { } procs.Add(p.ProcessName + "  (PID " + p.Id + ", " + mem + ")"); } ProcList.ItemsSource = procs; } catch { ProcList.ItemsSource = new List<string> { "Process enumeration is not available in this session." }; }
            BuildFixedDoc();
            cubeAnim = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(7)) { RepeatBehavior = RepeatBehavior.Forever };
            CubeSpin.BeginAnimation(AxisAngleRotation3D.AngleProperty, cubeAnim);
            cubeOn = true;
            DemoProgress.Value = SizeSlider.Value;
            SizeLabel.Text = "ProgressBar value: " + SizeSlider.Value.ToString("0");
            UpdateMultiCount();
            UpdatePwd();
            RuntimeCheck_Click(this, new RoutedEventArgs());
            clock.Interval = TimeSpan.FromSeconds(1);
            clock.Tick += (s, e) => ClockText.Text = DateTime.Now.ToLongTimeString();
            clock.Start();
            ClockText.Text = DateTime.Now.ToLongTimeString();
            NavList.SelectedIndex = 0;
            FactText.Text = "130+ live controls and techniques - 15 sections - 5 popout windows - 3D textures, video, fixed documents, adorners - one single-file exe";
            SetStatus("Welcome! Right-click anywhere to jump, and try the Popout theater on this page - the 3D cube opens in its own drag-to-rotate window.");
        }

        private void SetStatus(string message){ if (StatusText != null) { StatusText.Text = message; } }
        private void NavList_SelectionChanged(object sender, SelectionChangedEventArgs e){ if (SecSystem == null || NavList == null) { return; } try { StackPanel[] pages = { SecWelcome, SecButtons, SecText, SecLists, SecInput, SecLayout, SecGraphics, SecMedia, SecData, SecStyles, SecCustom, SecDialogs, SecDocs, SecDrag, SecSystem }; int i = NavList.SelectedIndex; if (i < 0) { i = 0; } for (int p = 0; p < pages.Length; p++) { pages[p].Visibility = p == i ? Visibility.Visible : Visibility.Collapsed; } } catch (Exception ex) { SetStatus("Section switch problem: " + ex.Message); } }
        private void WinCtx_Click(object sender, RoutedEventArgs e){ if (sender is MenuItem mi && int.TryParse(mi.Tag?.ToString(), out int idx) && idx >= 0 && idx < NavList.Items.Count) { NavList.SelectedIndex = idx; SetStatus("Right-click menu jumped to section " + (idx + 1) + "."); } }
        private void PopCube_Click(object sender, RoutedEventArgs e){ new CubeWindow(plasmaBmp).Show(); SetStatus("3D theater popped out - drag inside the new window to rotate the cube."); }
        private void PopInk_Click(object sender, RoutedEventArgs e){ new InkWindow().Show(); SetStatus("Ink studio popped out into its own full-size window."); }
        private void PopPlasma_Click(object sender, RoutedEventArgs e){ new PlasmaWindow().Show(); SetStatus("Plasma lab popped out - it animates a WriteableBitmap in real time with an FPS counter."); }
        private void PopData_Click(object sender, RoutedEventArgs e){ new DataWindow(people).Show(); SetStatus("DataGrid theater popped out - it shares the live collection with section 9."); }
        private void PopDoc_Click(object sender, RoutedEventArgs e){ new DocWindow(MakeFixedDoc()).Show(); SetStatus("Document theater popped out with a fresh FixedDocument."); }
        private void TourStart_Click(object sender, RoutedEventArgs e){ NavList.SelectedIndex = 1; SetStatus("Tour started - section 2: Buttons and Toggles."); }
        private void TourData_Click(object sender, RoutedEventArgs e){ NavList.SelectedIndex = 8; SetStatus("Jumped to section 9: Data and Validation."); }
        private void TourCube_Click(object sender, RoutedEventArgs e){ NavList.SelectedIndex = 6; SetStatus("Jumped to section 7: watch the textured 3D cube spin."); }
        private void TourRandom_Click(object sender, RoutedEventArgs e){ int i = rnd.Next(1, NavList.Items.Count); NavList.SelectedIndex = i; SetStatus("Surprise: section " + (i + 1) + " of " + NavList.Items.Count + "."); }
        private void Fun_Toggled(object sender, RoutedEventArgs e){ if (FunCheck == null) { return; } if (FunCheck.IsChecked == true) { defaultBackground = Background; LinearGradientBrush g = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) }; g.GradientStops.Add(new GradientStop(Colors.White, 0)); g.GradientStops.Add(new GradientStop(Color.FromRgb(255, 228, 243), 0.5)); g.GradientStops.Add(new GradientStop(Color.FromRgb(224, 231, 255), 1)); Background = g; SetStatus("Fun mode ON - the window background is now a gradient."); } else { if (defaultBackground != null) { Background = defaultBackground; } SetStatus("Fun mode OFF - calm background restored."); } }
        private void RuntimeCheck_Click(object sender, RoutedEventArgs e){ RuntimeText.Text = ".NET " + Environment.Version + " on " + Environment.OSVersion.VersionString + (Environment.Is64BitProcess ? " (64-bit process)" : " (32-bit process)"); SetStatus("Runtime verified: " + Environment.Version + " - zero external prerequisites."); }
        private void BtnPlain_Click(object sender, RoutedEventArgs e){ string label = (sender as Button)?.Content?.ToString() ?? "button"; BtnResult.Text = "Last button clicked: " + label; SetStatus("Button clicked: " + label); }
        private void BtnFancy_Click(object sender, RoutedEventArgs e){ SetStatus("Fancy button clicked - the hover color came from a Style trigger."); }
        private void BtnDanger_Click(object sender, RoutedEventArgs e){ MessageBox.Show(this, "This is the WPF MessageBox wearing its warning icon.", "Danger zone", MessageBoxButton.OK, MessageBoxImage.Warning); SetStatus("Danger button acknowledged."); }
        private void RepeatBtn_Click(object sender, RoutedEventArgs e){ repeatCount++; RepeatCountText.Text = "Clicks: " + repeatCount; }
        private void DemoToggle_Click(object sender, RoutedEventArgs e){ bool on = DemoToggle.IsChecked == true; DemoToggle.Content = on ? "I am ON" : "Toggle me"; SetStatus("ToggleButton is now " + (on ? "ON" : "OFF") + "."); }
        private void ChkAny_Click(object sender, RoutedEventArgs e){ string tri = ChkTri.IsChecked == true ? "checked" : ChkTri.IsChecked == false ? "unchecked" : "indeterminate"; ChkSummary.Text = "news=" + (ChkNews.IsChecked == true) + ", tips=" + (ChkTips.IsChecked == true) + ", three-state=" + tri; SetStatus("CheckBox state updated."); }
        private void Radio_Click(object sender, RoutedEventArgs e){ RadioButton rb = (RadioButton)sender; RadioSummary.Text = rb.GroupName + " selected: " + rb.Content; SetStatus("RadioButton: " + rb.GroupName + " = " + rb.Content); }
        private void NameBox_KeyDown(object sender, KeyEventArgs e){ if (e.Key == Key.Enter) { string n = NameBox.Text.Trim(); EchoText.Text = n.Length == 0 ? "Type a name first, then press Enter." : "Hello, " + n + "! Welcome to the gallery."; SetStatus("TextBox Enter pressed."); e.Handled = true; } }
        private void MultiBox_TextChanged(object sender, TextChangedEventArgs e){ UpdateMultiCount(); }
        private void UpdateMultiCount(){ if (MultiCountText == null || MultiBox == null) { return; } string t = MultiBox.Text; int words = t.Length == 0 ? 0 : System.Text.RegularExpressions.Regex.Matches(t, @"\S+").Count; int lines = t.Length == 0 ? 0 : t.Replace("\r\n", "\n").Split('\n').Length; MultiCountText.Text = "Characters: " + t.Length + "   Words: " + words + "   Lines: " + lines; }
        private void PwdBox_PasswordChanged(object sender, RoutedEventArgs e){ UpdatePwd(); }
        private void ShowPwd_Click(object sender, RoutedEventArgs e){ UpdatePwd(); }
        private void UpdatePwd(){ if (PwdInfoText == null || PwdBox == null || ShowPwd == null) { return; } string p = PwdBox.Password; string reveal = ShowPwd.IsChecked == true && p.Length > 0 ? " - it reads: " + p : ""; PwdInfoText.Text = "Password length: " + p.Length + " characters" + reveal; }
        private void RichBold_Click(object sender, RoutedEventArgs e){ bool on = DemoRich.Selection.GetPropertyValue(TextElement.FontWeightProperty).Equals(FontWeights.Bold); DemoRich.Selection.ApplyPropertyValue(TextElement.FontWeightProperty, on ? FontWeights.Normal : FontWeights.Bold); SetStatus("Bold toggled " + (on ? "off" : "on") + " for the selection."); }
        private void RichItalic_Click(object sender, RoutedEventArgs e){ bool on = DemoRich.Selection.GetPropertyValue(TextElement.FontStyleProperty).Equals(FontStyles.Italic); DemoRich.Selection.ApplyPropertyValue(TextElement.FontStyleProperty, on ? FontStyles.Normal : FontStyles.Italic); SetStatus("Italic toggled " + (on ? "off" : "on") + " for the selection."); }
        private void RichUnderline_Click(object sender, RoutedEventArgs e){ bool on = DemoRich.Selection.GetPropertyValue(Inline.TextDecorationsProperty) != null; DemoRich.Selection.ApplyPropertyValue(Inline.TextDecorationsProperty, on ? null : TextDecorations.Underline); SetStatus("Underline toggled " + (on ? "off" : "on") + " for the selection."); }
        private void RichRo_Click(object sender, RoutedEventArgs e){ DemoRich.IsReadOnly = RichRo.IsChecked == true; SetStatus("RichTextBox is now " + (DemoRich.IsReadOnly ? "read-only" : "editable") + "."); }
        private void RichClear_Click(object sender, RoutedEventArgs e){ DemoRich.Document.Blocks.Clear(); DemoRich.Document.Blocks.Add(new Paragraph(new Run("Document cleared - type something new."))); SetStatus("RichTextBox document cleared."); }
        private void MenuNew_Click(object sender, RoutedEventArgs e){ SetStatus("File > New - demo command acknowledged."); }
        private void MenuOpen_Click(object sender, RoutedEventArgs e){ SetStatus("File > Open - for a real dialog see the Dialogs and Printing section."); }
        private void MenuExit_Click(object sender, RoutedEventArgs e){ Close(); }
        private void MenuCut_Click(object sender, RoutedEventArgs e){ string t = NameBox.Text; if (t.Length > 0) { try { Clipboard.SetText(t); NameBox.Text = ""; SetStatus("Edit > Cut - the name field moved to the clipboard."); } catch (Exception ex) { SetStatus("Clipboard refused: " + ex.Message); } } else { SetStatus("The name field is empty - nothing to cut."); } }
        private void MenuCopy_Click(object sender, RoutedEventArgs e){ if (NameBox.Text.Length > 0) { try { Clipboard.SetText(NameBox.Text); SetStatus("Edit > Copy - name field copied to the clipboard."); } catch (Exception ex) { SetStatus("Clipboard refused: " + ex.Message); } } else { SetStatus("The name field is empty - nothing to copy."); } }
        private void MenuPaste_Click(object sender, RoutedEventArgs e){ try { if (Clipboard.ContainsText()) { NameBox.Text = Clipboard.GetText(); SetStatus("Edit > Paste - clipboard text placed in the name field."); } else { SetStatus("The clipboard currently holds no text."); } } catch (Exception ex) { SetStatus("Clipboard refused: " + ex.Message); } }
        private void MenuAbout_Click(object sender, RoutedEventArgs e){ MessageBox.Show(this, "WPF Control Gallery - Kitchen Sink Edition\r\nA .NET 8 showcase application.\r\nEvery control in this window is standard WPF - no third-party libraries.", "About", MessageBoxButton.OK, MessageBoxImage.Information); SetStatus("Help > About shown."); }
        private void ToolBtn_Click(object sender, RoutedEventArgs e){ string label = (sender as ContentControl)?.Content?.ToString() ?? "?"; SetStatus("ToolBar item '" + label + "' clicked."); }
        private void FruitsList_SelectionChanged(object sender, SelectionChangedEventArgs e){ string pick = FruitsList.SelectedItem is ListBoxItem li ? (li.Content as string ?? "(item)") : "(nothing)"; FruitResult.Text = "You picked: " + pick; SetStatus("ListBox selection: " + pick); }
        private void CtxHello_Click(object sender, RoutedEventArgs e){ string pick = FruitsList.SelectedItem is ListBoxItem li ? (li.Content as string ?? "(item)") : "(nothing)"; MessageBox.Show(this, "Hello, " + pick + "! Right-click menus are alive too.", "ContextMenu", MessageBoxButton.OK, MessageBoxImage.Information); SetStatus("ContextMenu said hello to: " + pick); }
        private void CtxCount_Click(object sender, RoutedEventArgs e){ SetStatus("The ListBox holds " + FruitsList.Items.Count + " items."); }
        private void XmlList_SelectionChanged(object sender, SelectionChangedEventArgs e){ System.Xml.XmlElement? el = XmlList.SelectedItem as System.Xml.XmlElement; if (el != null) { XmlResult.Text = el.GetAttribute("Name") + " - " + el.GetAttribute("City"); SetStatus("XML item selected: " + el.GetAttribute("Name")); } }
        private void TreeBound_Selected(object sender, RoutedPropertyChangedEventArgs<object> e){ if (TreeBound.SelectedItem is HNode n) { SetStatus("Bound tree selection: " + n.Title + (n.Done ? " (done)" : " (open)")); } }
        private void FontCombo_SelectionChanged(object sender, SelectionChangedEventArgs e){ if (FontCombo == null || FontCombo.SelectedItem == null || FontSample == null) { return; } if (FontCombo.SelectedItem is ComboBoxItem ci) { string fam = ci.Content as string ?? "Segoe UI"; FontSample.FontFamily = new FontFamily(fam); SetStatus("FontFamily changed to " + fam + "."); } }
        private void EditComboSel_Changed(object sender, SelectionChangedEventArgs e){ UpdateJoinText(); }
        private void EditCombo_KeyDown(object sender, KeyEventArgs e){ if (e.Key != Key.Enter) { return; } string t = EditCombo.Text.Trim(); if (t.Length == 0) { SetStatus("The editable combo is empty - type something first."); return; } bool exists = false; foreach (object it in EditCombo.Items) { if (it is ComboBoxItem ci && string.Equals(ci.Content as string, t, StringComparison.OrdinalIgnoreCase)) { exists = true; break; } } if (!exists) { EditCombo.Items.Add(t); SetStatus("Editable combo: added new item '" + t + "'."); } else { SetStatus("Editable combo: '" + t + "' is already in the list."); } UpdateJoinText(); e.Handled = true; }
        private void FileList_SelectionChanged(object sender, SelectionChangedEventArgs e){ if (FileList.SelectedItem is FileRow f) { FileResult.Text = "Selected: " + f.Name + " (" + f.SizeKb.ToString("0.#") + " KB, " + f.Type + ")"; SetStatus("ListView row selected: " + f.Name); } }
        private void TreeDemo_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e){ if (TreeDemo == null || TreeResult == null) { return; } object sel = TreeDemo.SelectedItem; string label = sel is TreeViewItem tvi ? (tvi.Header as string ?? "(node)") : (sel as string ?? "(none)"); TreeResult.Text = "Selected node: " + label; SetStatus("TreeView selection: " + label); }
        private void DemoTabs_SelectionChanged(object sender, SelectionChangedEventArgs e){ if (DemoTabs == null) { return; } if (DemoTabs.SelectedItem is TabItem ti) { SetStatus("Tab selected: " + ti.Header); } }
        private void RawScroll_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e){ if (RawLabel == null) { return; } RawLabel.Text = "Value: " + RawScroll.Value.ToString("0"); }
        private void SizeSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e){ if (DemoProgress == null || SizeLabel == null || SizeSlider == null) { return; } DemoProgress.Value = SizeSlider.Value; SizeLabel.Text = "ProgressBar value: " + SizeSlider.Value.ToString("0"); SetStatus("Slider moved to " + SizeSlider.Value.ToString("0") + "."); }
        private void IndetCheck_Click(object sender, RoutedEventArgs e){ DemoProgress.IsIndeterminate = IndetCheck.IsChecked == true; SetStatus("ProgressBar indeterminate mode: " + (DemoProgress.IsIndeterminate ? "on" : "off")); }
        private void DemoCal_SelectedDatesChanged(object sender, SelectionChangedEventArgs e){ if (DemoCal == null) { return; } int n = DemoCal.SelectedDates.Count; SetStatus("Calendar: " + n + " date(s) selected" + (n > 0 ? " - first: " + DemoCal.SelectedDates[0].ToLongDateString() : "")); }
        private void DemoDate_SelectedDateChanged(object sender, SelectionChangedEventArgs e){ if (DemoDate == null || DateResult == null) { return; } DateResult.Text = DemoDate.SelectedDate.HasValue ? "Picked date: " + DemoDate.SelectedDate.Value.ToLongDateString() : "No date picked yet."; SetStatus("DatePicker changed: " + DateResult.Text); }
        private void BlockPick_Changed(object sender, SelectionChangedEventArgs e){ if (BlockDatePick == null) { return; } SetStatus("Blackout picker: " + (BlockDatePick.SelectedDate.HasValue ? BlockDatePick.SelectedDate.Value.ToLongDateString() : "cleared")); }
        private void TodayBtn_Click(object sender, RoutedEventArgs e){ DemoDate.SelectedDate = DateTime.Today; SetStatus("DatePicker set to today."); }
        private void TunOuterPreview(object sender, MouseButtonEventArgs e){ LogTunnel("1. Preview (tunneling) reached the OUTER border"); }
        private void TunInnerPreview(object sender, MouseButtonEventArgs e){ LogTunnel("2. Preview (tunneling) reached the INNER border"); }
        private void TunInnerBubble(object sender, MouseButtonEventArgs e){ LogTunnel("3. Bubble reached the INNER border"); }
        private void TunOuterBubble(object sender, MouseButtonEventArgs e){ LogTunnel("4. Bubble reached the OUTER border - full route above"); }
        private void LogTunnel(string line){ string[] parts = (TunnelLog.Text.Length == 0 ? "" : TunnelLog.Text + "\n").Split('\n'); var keep = parts.Where(x => x.Length > 0); string all = string.Join("\n", keep.Concat(new[] { line })); string[] ls = all.Split('\n'); if (ls.Length > 6) { all = string.Join("\n", ls.Skip(ls.Length - 6)); } TunnelLog.Text = all; }
        private void OnBoostCanExecute(object sender, CanExecuteRoutedEventArgs e){ e.CanExecute = true; }
        private void OnBoostExecuted(object sender, ExecutedRoutedEventArgs e){ BoostLog.Text = "Boost executed at " + DateTime.Now.ToLongTimeString(); SetStatus("Boost command executed (button or Ctrl+B)."); }
        private void BoostBtn_Click(object sender, RoutedEventArgs e){ BoostCommand.Execute(null, this); }
        private void KeyCapture_KeyDown(object sender, KeyEventArgs e){ KeyInfoText.Text = "Last key: " + e.Key; SetStatus("KeyDown captured: " + e.Key); }
        private void Chip_Click(object sender, RoutedEventArgs e){ Button b = (Button)sender; SetStatus("Chip " + b.Content + " clicked - the panel reflows these as the window resizes."); }
        private void ShuffleShapes_Click(object sender, RoutedEventArgs e){ foreach (object child in DemoCanvas.Children) { FrameworkElement fe = (FrameworkElement)child; double w = double.IsNaN(fe.Width) ? 50 : fe.Width; double h = double.IsNaN(fe.Height) ? 50 : fe.Height; double maxX = Math.Max(0, DemoCanvas.ActualWidth - w); double maxY = Math.Max(0, DemoCanvas.ActualHeight - h); Canvas.SetLeft(fe, rnd.NextDouble() * maxX); Canvas.SetTop(fe, rnd.NextDouble() * maxY); } SetStatus("Canvas shapes moved to new random coordinates."); }
        private void ZFront_Click(object sender, RoutedEventArgs e){ Panel.SetZIndex(ZA, 2); Panel.SetZIndex(ZB, 1); SetStatus("Pink shape raised via Panel.SetZIndex."); }
        private void ZBack_Click(object sender, RoutedEventArgs e){ Panel.SetZIndex(ZA, 0); Panel.SetZIndex(ZB, 1); SetStatus("Pink shape lowered via Panel.SetZIndex."); }
        private void DemoExp_Expanded(object sender, RoutedEventArgs e){ SetStatus("Expander expanded - hidden content revealed."); }
        private void DemoExp_Collapsed(object sender, RoutedEventArgs e){ SetStatus("Expander collapsed - content tucked away."); }
        private void ScaleSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e){ if (ScaleHost == null || ScaleLabel == null || ScaleSlider == null) { return; } ScaleHost.Width = ScaleSlider.Value; ScaleLabel.Text = "Host width: " + ScaleSlider.Value.ToString("0"); }
        private void BlurBtn_Click(object sender, RoutedEventArgs e){ if (BlurTarget.Effect == null) { BlurTarget.Effect = new BlurEffect { Radius = 10 }; SetStatus("BlurEffect applied (Radius 10)."); } else { BlurTarget.Effect = null; SetStatus("BlurEffect removed."); } }
        private void PauseCube_Click(object sender, RoutedEventArgs e){ CubeSpin.BeginAnimation(AxisAngleRotation3D.AngleProperty, null); cubeOn = false; SetStatus("3D cube rotation paused."); }
        private void ResumeCube_Click(object sender, RoutedEventArgs e){ if (cubeAnim != null && !cubeOn) { CubeSpin.BeginAnimation(AxisAngleRotation3D.AngleProperty, cubeAnim); cubeOn = true; SetStatus("3D cube rotation resumed."); } }
        private void LoadImage_Click(object sender, RoutedEventArgs e){ Microsoft.Win32.OpenFileDialog dlg = new Microsoft.Win32.OpenFileDialog { Title = "Pick an image file", Filter = "Image files (*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.png;*.jpg;*.jpeg;*.bmp;*.gif|All files (*.*)|*.*" }; if (dlg.ShowDialog() == true) { TryLoadImage(dlg.FileName); } }
        private void ClearImage_Click(object sender, RoutedEventArgs e){ DemoImage.Source = null; ImageHint.Visibility = Visibility.Visible; SetStatus("Image cleared - drop or load another one."); }
        private void TryLoadImage(string path){ try { BitmapImage bmp = new BitmapImage(); bmp.BeginInit(); bmp.CacheOption = BitmapCacheOption.OnLoad; bmp.UriSource = new Uri(path); bmp.EndInit(); DemoImage.Source = bmp; ImageHint.Visibility = Visibility.Collapsed; SetStatus("Image loaded: " + path); } catch (Exception ex) { MessageBox.Show(this, "That file could not be read as an image:\r\n" + ex.Message, "Image load failed", MessageBoxButton.OK, MessageBoxImage.Warning); } }
        private void ImageZone_Drop(object sender, DragEventArgs e){ if (e.Data.GetDataPresent(DataFormats.FileDrop)) { string[]? files = e.Data.GetData(DataFormats.FileDrop) as string[]; if (files != null && files.Length > 0) { TryLoadImage(files[0]); } } e.Handled = true; }
        private void GenBitmap_Click(object sender, RoutedEventArgs e){ GenPlasma(); SetStatus("WriteableBitmap regenerated from raw pixel data."); }
        private void GenPlasma(){ try { int w = 176, h = 96; WriteableBitmap wb = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgr32, null); byte[] px = new byte[w * h * 4]; double ph = rnd.NextDouble() * 6.28; for (int y = 0; y < h; y++) { for (int x = 0; x < w; x++) { double v = Math.Sin(x * 0.11 + ph) + Math.Sin(y * 0.13) + Math.Sin((x + y) * 0.07 + ph) + Math.Sqrt((x - w / 2.0) * (x - w / 2.0) + (y - h / 2.0) * (y - h / 2.0)) * 0.04; int c = (int)((v + 4) / 8.0 * 255); if (c < 0) { c = 0; } if (c > 255) { c = 255; } int i = (y * w + x) * 4; px[i] = (byte)c; px[i + 1] = (byte)(c * 7 / 10); px[i + 2] = (byte)(255 - c / 2); px[i + 3] = 255; } } wb.WritePixels(new Int32Rect(0, 0, w, h), px, w * 4, 0); plasmaBmp = wb; PlasmaImage.Source = wb; } catch (Exception ex) { SetStatus("Plasma generation failed: " + ex.Message); } }
        private static byte[] MakeToneBytes(double freq){ int rate = 22050; int n = rate; MemoryStream ms = new MemoryStream(); BinaryWriter w = new BinaryWriter(ms); w.Write("RIFF".ToCharArray()); w.Write(36 + n * 2); w.Write("WAVE".ToCharArray()); w.Write("fmt ".ToCharArray()); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16); w.Write("data".ToCharArray()); w.Write(n * 2); for (int i = 0; i < n; i++) { w.Write((short)(Math.Sin(2 * Math.PI * freq * i / rate) * 8000)); } w.Flush(); return ms.ToArray(); }
        private void PlayTone(double freq){ try { byte[] b = MakeToneBytes(freq); System.Media.SoundPlayer sp = new System.Media.SoundPlayer(new MemoryStream(b)); tonePlayers.Add(sp); sp.Play(); SetStatus("Playing a synthesized " + freq + " Hz tone."); } catch (Exception ex) { SetStatus("Sound failed: " + ex.Message); } }
        private void ToneA_Click(object sender, RoutedEventArgs e){ PlayTone(440); }
        private void ToneB_Click(object sender, RoutedEventArgs e){ PlayTone(880); }
        private void SysSounds_Click(object sender, RoutedEventArgs e){ try { System.Media.SystemSounds.Asterisk.Play(); System.Media.SystemSounds.Beep.Play(); SetStatus("System sounds played."); } catch (Exception ex) { SetStatus("System sounds failed: " + ex.Message); } }
        private void MediaOpen_Click(object sender, RoutedEventArgs e){ Microsoft.Win32.OpenFileDialog dlg = new Microsoft.Win32.OpenFileDialog { Title = "Pick a video or audio file", Filter = "Media files (*.mp4;*.wmv;*.avi;*.mp3;*.wav;*.wma;*.m4a)|*.mp4;*.wmv;*.avi;*.mp3;*.wav;*.wma;*.m4a|All files (*.*)|*.*" }; if (dlg.ShowDialog() == true) { try { DemoMedia.Source = new Uri(dlg.FileName); DemoMedia.Play(); SetStatus("MediaElement playing: " + dlg.FileName); } catch (Exception ex) { SetStatus("Could not open media: " + ex.Message); } } }
        private void MediaPlay_Click(object sender, RoutedEventArgs e){ try { DemoMedia.Play(); SetStatus("Media playing."); } catch (Exception ex) { SetStatus("Play failed: " + ex.Message); } }
        private void MediaPause_Click(object sender, RoutedEventArgs e){ try { DemoMedia.Pause(); SetStatus("Media paused."); } catch { } }
        private void MediaStop_Click(object sender, RoutedEventArgs e){ try { DemoMedia.Stop(); SetStatus("Media stopped."); } catch { } }
        private void DemoMedia_Opened(object sender, RoutedEventArgs e){ SetStatus("Media opened successfully - duration " + DemoMedia.NaturalDuration + "."); }
        private void DemoMedia_Failed(object sender, ExceptionRoutedEventArgs e){ SetStatus("Media failed: " + e.ErrorException.Message + " (the codec may be missing on this machine)."); }
        private void InkColor_SelectionChanged(object sender, SelectionChangedEventArgs e){ if (DemoInk == null || InkColor == null || InkColor.SelectedItem == null) { return; } string name = (InkColor.SelectedItem as ComboBoxItem)?.Content as string ?? "Black"; try { DemoInk.DefaultDrawingAttributes.Color = (Color)ColorConverter.ConvertFromString(name); SetStatus("Ink color set to " + name + "."); } catch (Exception ex) { SetStatus("Color problem: " + ex.Message); } }
        private void InkMode_SelectionChanged(object sender, SelectionChangedEventArgs e){ if (DemoInk == null || InkMode == null || InkMode.SelectedItem == null) { return; } string m = (InkMode.SelectedItem as ComboBoxItem)?.Content as string ?? "Draw"; DemoInk.EditingMode = m == "Draw" ? InkCanvasEditingMode.Ink : m == "Select" ? InkCanvasEditingMode.Select : InkCanvasEditingMode.EraseByStroke; SetStatus("InkCanvas mode: " + m + "."); }
        private void InkClear_Click(object sender, RoutedEventArgs e){ DemoInk.Strokes.Clear(); StrokeCount.Text = "Strokes: 0"; SetStatus("Ink canvas cleared."); }
        private void DemoInk_StrokeCollected(object sender, InkCanvasStrokeCollectedEventArgs e){ StrokeCount.Text = "Strokes: " + DemoInk.Strokes.Count; }
        private void DemoInk_StrokeErased(object sender, EventArgs e){ StrokeCount.Text = "Strokes: " + DemoInk.Strokes.Count; }
        private void AddPerson_Click(object sender, RoutedEventArgs e){ Person p = new Person { Name = "Newcomer " + (people.Count + 1), Age = rnd.Next(18, 81), City = "Springfield", Email = "user" + (people.Count + 1) + "@example.com", Active = rnd.NextDouble() > 0.5, Score = rnd.Next(40, 100) }; people.Add(p); PeopleGrid.SelectedItem = p; PeopleGrid.ScrollIntoView(p); SetStatus("DataGrid row added: " + p.Name); }
        private void RemovePerson_Click(object sender, RoutedEventArgs e){ if (PeopleGrid.SelectedItem is Person p) { people.Remove(p); SetStatus("DataGrid row deleted: " + p.Name); } else { SetStatus("Select a DataGrid row first."); } }
        private void ResetVm_Click(object sender, RoutedEventArgs e){ Vm.Name = "Ada Lovelace"; Vm.Age = 36; SetStatus("ViewModel reset - every bound control updated itself."); }
        private void UpdateProductInfo(){ if (productsView == null || ProductInfo == null) { return; } int vis = 0; foreach (object o in productsView) { vis++; } ProductInfo.Text = vis + " of " + products.Count + " shown"; }
        private void SortName_Click(object sender, RoutedEventArgs e){ if (productsView == null) { return; } productsView.SortDescriptions.Clear(); productsView.SortDescriptions.Add(new SortDescription("Name", ListSortDirection.Ascending)); UpdateProductInfo(); SetStatus("Products sorted by name."); }
        private void SortPrice_Click(object sender, RoutedEventArgs e){ if (productsView == null) { return; } productsView.SortDescriptions.Clear(); productsView.SortDescriptions.Add(new SortDescription("Price", ListSortDirection.Ascending)); UpdateProductInfo(); SetStatus("Products sorted by price."); }
        private void FilterBox_TextChanged(object sender, TextChangedEventArgs e){ if (productsView == null || FilterBox == null) { return; } string f = FilterBox.Text; productsView.Filter = o => { Product p = (Product)o; return p.Name.IndexOf(f, StringComparison.OrdinalIgnoreCase) >= 0; }; UpdateProductInfo(); }
        private void UpdateJoinText(){ if (ComboJoinText == null || NameBox == null || EditCombo == null || ConvSlider == null) { return; } ComboJoinText.Text = NameBox.Text + " " + EditCombo.Text + " (" + ConvSlider.Value.ToString("0") + " units)"; }
        private void JoinInputs_Changed(object sender, TextChangedEventArgs e){ UpdateJoinText(); }
        private void JoinSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e){ UpdateJoinText(); }
        private void ThemeToggle_Click(object sender, RoutedEventArgs e){ darkTheme = !darkTheme; Resources["CardBg"] = new SolidColorBrush(darkTheme ? Color.FromRgb(30, 41, 59) : Colors.White); Resources["CardFg"] = new SolidColorBrush(darkTheme ? Colors.White : Color.FromRgb(49, 46, 129)); Resources["AccentBrush"] = new SolidColorBrush(darkTheme ? Color.FromRgb(34, 211, 238) : Color.FromRgb(79, 70, 229)); SetStatus("Palette swapped at runtime - DynamicResource bindings re-evaluated instantly."); }
        private void ThemedBtn_Click(object sender, RoutedEventArgs e){ SetStatus("Themed button clicked - its colors are DynamicResource references."); }
        private void GlowBtn_Click(object sender, RoutedEventArgs e){ glowOn = !glowOn; ColorAnimation c1 = new ColorAnimation { To = glowOn ? Color.FromRgb(14, 165, 233) : Color.FromRgb(79, 70, 229), Duration = TimeSpan.FromSeconds(1.2), AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever }; ColorAnimation c2 = new ColorAnimation { To = glowOn ? Color.FromRgb(250, 204, 21) : Color.FromRgb(236, 72, 153), Duration = TimeSpan.FromSeconds(1.2), AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever }; try { GlowA.BeginAnimation(GradientStop.ColorProperty, c1); GlowB.BeginAnimation(GradientStop.ColorProperty, c2); SetStatus(glowOn ? "Gradient endpoints breathing forever." : "Gradient retargeted to the calm palette."); } catch (Exception ex) { SetStatus("Gradient animation failed: " + ex.Message); } }
        private void RocketBtn_Click(object sender, RoutedEventArgs e){ try { PathGeometry pg = (PathGeometry)Geometry.Parse("M 16,80 C 90,0 200,160 300,50"); MatrixTransform mt = new MatrixTransform(); Rocket.RenderTransform = mt; MatrixAnimationUsingPath ma = new MatrixAnimationUsingPath { PathGeometry = pg, Duration = TimeSpan.FromSeconds(4), DoesRotateWithTangent = true }; mt.BeginAnimation(MatrixTransform.MatrixProperty, ma); SetStatus("Rocket launched along the Bezier path, rotating with the tangent."); } catch (Exception ex) { SetStatus("Path animation failed: " + ex.Message); } }
        private void Keyframes_Click(object sender, RoutedEventArgs e){ TranslateTransform tt = new TranslateTransform(); KeyCircle.RenderTransform = tt; DoubleAnimationUsingKeyFrames kf = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(2) }; kf.KeyFrames.Add(new EasingDoubleKeyFrame(220, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(1))) { EasingFunction = new CircleEase() }); kf.KeyFrames.Add(new DiscreteDoubleKeyFrame(220, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(1.4)))); kf.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(2)))); tt.BeginAnimation(TranslateTransform.XProperty, kf); SetStatus("Keyframe timeline running: easing, discrete hold, linear return."); }
        private void AnimSize_Click(object sender, RoutedEventArgs e){ DoubleAnimation da = new DoubleAnimation { From = 40, To = 170, Duration = TimeSpan.FromMilliseconds(900), AutoReverse = true, EasingFunction = new ElasticEase() }; AnimEllipse.BeginAnimation(Ellipse.WidthProperty, da); AnimEllipse.BeginAnimation(Ellipse.HeightProperty, da); SetStatus("Elastic size animation started."); }
        private void AnimColor_Click(object sender, RoutedEventArgs e){ SolidColorBrush b = new SolidColorBrush(Color.FromRgb(34, 197, 94)); AnimRect.Fill = b; ColorAnimation ca = new ColorAnimation { To = Color.FromRgb(147, 51, 234), Duration = TimeSpan.FromSeconds(1), AutoReverse = true }; b.BeginAnimation(SolidColorBrush.ColorProperty, ca); SetStatus("Color animation on the rectangle's brush."); }
        private void AnimSpin_Click(object sender, RoutedEventArgs e){ if (spinning) { return; } RotateTransform rt = new RotateTransform(); AnimSpinner.RenderTransform = rt; DoubleAnimation da = new DoubleAnimation { From = 0, To = 360, Duration = TimeSpan.FromSeconds(1.6), RepeatBehavior = RepeatBehavior.Forever }; rt.BeginAnimation(RotateTransform.AngleProperty, da); spinning = true; SetStatus("Spinner rotating forever."); }
        private void AnimPulse_Click(object sender, RoutedEventArgs e){ ScaleTransform st = new ScaleTransform(); AnimRect.RenderTransform = st; AnimRect.RenderTransformOrigin = new Point(0.5, 0.5); DoubleAnimation da = new DoubleAnimation { From = 1, To = 1.35, Duration = TimeSpan.FromMilliseconds(500), AutoReverse = true }; st.BeginAnimation(ScaleTransform.ScaleXProperty, da); st.BeginAnimation(ScaleTransform.ScaleYProperty, da); SetStatus("Pulse animation on the rectangle."); }
        private void AnimFade_Click(object sender, RoutedEventArgs e){ stageFaded = !stageFaded; DoubleAnimation da = new DoubleAnimation { To = stageFaded ? 0.12 : 1.0, Duration = TimeSpan.FromMilliseconds(700) }; AnimStage.BeginAnimation(UIElement.OpacityProperty, da); SetStatus("Stage opacity animated to " + (stageFaded ? "12 percent" : "100 percent") + "."); }
        private void AnimStop_Click(object sender, RoutedEventArgs e){ AnimEllipse.BeginAnimation(Ellipse.WidthProperty, null); AnimEllipse.BeginAnimation(Ellipse.HeightProperty, null); AnimRect.Fill = new SolidColorBrush(Color.FromRgb(34, 197, 94)); AnimSpinner.RenderTransform = Transform.Identity; AnimRect.RenderTransform = Transform.Identity; AnimStage.BeginAnimation(UIElement.OpacityProperty, null); AnimStage.Opacity = 1; stageFaded = false; spinning = false; SetStatus("All animations stopped."); }
        private void BtnRounded_Click(object sender, RoutedEventArgs e){ SetStatus("Template button clicked - ControlTemplate triggers repainted it on hover and press."); }
        private void TipBtn_Click(object sender, RoutedEventArgs e){ SetStatus("ToolTip button clicked - did you spot the ToolTip on hover?"); }
        private void TipRich_Click(object sender, RoutedEventArgs e){ SetStatus("Rich ToolTip button clicked - hover it to see a whole panel as the tooltip."); }
        private void SwitchDemo_Click(object sender, RoutedEventArgs e){ bool on = SwitchDemo.IsChecked == true; SwitchState.Text = "Switch is " + (on ? "ON" : "OFF"); SetStatus("Re-templated switch: " + (on ? "ON" : "OFF") + "."); }
        private void AdornBtn_Click(object sender, RoutedEventArgs e){ AdornerLayer? layer = AdornerLayer.GetAdornerLayer(AdornTarget); if (layer == null) { AdornInfo.Text = "No adorner layer is available for this element."; return; } if (ringAdorner == null) { ringAdorner = new RingAdorner(AdornTarget); layer.Add(ringAdorner); AdornInfo.Text = "Ring adorner added - it floats in the adorner layer above the border."; } else { layer.Remove(ringAdorner); ringAdorner = null; AdornInfo.Text = "Ring adorner removed."; } SetStatus("Adorner toggled."); }
        private void DocLink_RequestNavigate(object sender, RequestNavigateEventArgs e){ try { Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true }); SetStatus("Opened " + e.Uri.AbsoluteUri + " in your browser."); } catch (Exception ex) { SetStatus("Could not open the browser: " + ex.Message); } e.Handled = true; }
        private void ResetXamlSample(){ XamlBox.Text = "<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><Border Background='#FF4F46E5' CornerRadius='10' Padding='14' Margin='0,0,0,6'><TextBlock Text='Hello from runtime XAML!' Foreground='White' FontSize='16' FontWeight='Bold'/></Border><TextBlock Text='Edit the markup above and render again.'/><Ellipse Width='60' Height='24' Fill='#FF22C55E' Margin='0,6,0,0' HorizontalAlignment='Left'/></StackPanel>"; }
        private void XamlRender_Click(object sender, RoutedEventArgs e){ try { object? parsed = System.Windows.Markup.XamlReader.Parse(XamlBox.Text); XamlHost.Content = parsed; XamlErr.Text = ""; SetStatus("XamlReader.Parse succeeded - the visual was built from your markup at runtime."); } catch (Exception ex) { XamlErr.Text = "XAML error: " + ex.Message; SetStatus("XAML parse failed - fix the markup and try again."); } }
        private void XamlReset_Click(object sender, RoutedEventArgs e){ ResetXamlSample(); XamlHost.Content = null; XamlErr.Text = ""; SetStatus("Sample XAML restored."); }
        private void SnapshotBtn_Click(object sender, RoutedEventArgs e){ try { double w = Math.Max(16, ActualWidth), h = Math.Max(16, ActualHeight); RenderTargetBitmap rtb = new RenderTargetBitmap((int)w, (int)h, 96, 96, PixelFormats.Pbgra32); rtb.Render(this); PngBitmapEncoder enc = new PngBitmapEncoder(); enc.Frames.Add(BitmapFrame.Create(rtb)); string p = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "WpfGallerySnapshot.png"); using (FileStream fs = new FileStream(p, FileMode.Create)) { enc.Save(fs); } try { Clipboard.SetImage(rtb); } catch { } SnapshotResult.Text = "Saved " + p + " and copied to the clipboard."; SetStatus("RenderTargetBitmap snapshot saved."); } catch (Exception ex) { SnapshotResult.Text = "Snapshot failed: " + ex.Message; } }
        private void MsgInfo_Click(object sender, RoutedEventArgs e){ MessageBox.Show(this, "Everything you see runs from one self-contained .NET 8 executable.", "Information", MessageBoxButton.OK, MessageBoxImage.Information); DialogMsgResult.Text = "Last MessageBox: Information / OK"; SetStatus("MessageBox (Information) shown."); }
        private void MsgWarn_Click(object sender, RoutedEventArgs e){ MessageBox.Show(this, "This is a warning-styled MessageBox - still pure WPF.", "Warning", MessageBoxButton.OK, MessageBoxImage.Warning); DialogMsgResult.Text = "Last MessageBox: Warning / OK"; SetStatus("MessageBox (Warning) shown."); }
        private void MsgError_Click(object sender, RoutedEventArgs e){ MessageBox.Show(this, "This is an error-styled MessageBox - nobody was harmed.", "Error", MessageBoxButton.OK, MessageBoxImage.Error); DialogMsgResult.Text = "Last MessageBox: Error / OK"; SetStatus("MessageBox (Error) shown."); }
        private void MsgYesNo_Click(object sender, RoutedEventArgs e){ MessageBoxResult r = MessageBox.Show(this, "Are you enjoying the gallery so far?", "Question", MessageBoxButton.YesNo, MessageBoxImage.Question); DialogMsgResult.Text = "You answered: " + r; SetStatus("MessageBox answered: " + r); }
        private void OpenFileBtn_Click(object sender, RoutedEventArgs e){ Microsoft.Win32.OpenFileDialog dlg = new Microsoft.Win32.OpenFileDialog { Title = "Pick any file", Filter = "All files (*.*)|*.*" }; if (dlg.ShowDialog() == true) { DialogFileResult.Text = "Opened: " + dlg.FileName; SetStatus("File picked: " + dlg.FileName); } else { SetStatus("Open dialog cancelled."); } }
        private void OpenMultiBtn_Click(object sender, RoutedEventArgs e){ Microsoft.Win32.OpenFileDialog dlg = new Microsoft.Win32.OpenFileDialog { Title = "Pick images (multiselect)", Filter = "Image files (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg|All files (*.*)|*.*", Multiselect = true }; if (dlg.ShowDialog() == true) { string[] fs = dlg.FileNames; DialogFileResult.Text = fs.Length + " file(s) picked: " + string.Join(", ", fs.Take(3)) + (fs.Length > 3 ? " ..." : ""); SetStatus("Multiselect open dialog returned " + fs.Length + " file(s)."); } else { SetStatus("Multiselect dialog cancelled."); } }
        private void SaveFileBtn_Click(object sender, RoutedEventArgs e){ Microsoft.Win32.SaveFileDialog dlg = new Microsoft.Win32.SaveFileDialog { Title = "Save a sample note", Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*", FileName = "gallery-note.txt" }; if (dlg.ShowDialog() == true) { try { File.WriteAllText(dlg.FileName, "Written by the WPF Control Gallery on " + DateTime.Now + Environment.NewLine); DialogFileResult.Text = "Saved: " + dlg.FileName; SetStatus("File written successfully."); } catch (Exception ex) { MessageBox.Show(this, "Could not write the file:\r\n" + ex.Message, "Save failed", MessageBoxButton.OK, MessageBoxImage.Error); } } else { SetStatus("Save dialog cancelled."); } }
        private Border MakePrintCard(){ Border b = new Border { Background = Brushes.White, BorderBrush = new SolidColorBrush(Color.FromRgb(79, 70, 229)), BorderThickness = new Thickness(2), Padding = new Thickness(30), Width = 480 }; StackPanel sp = new StackPanel(); sp.Children.Add(new TextBlock { Text = "WPF Control Gallery - Kitchen Sink Edition", FontSize = 20, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(Color.FromRgb(49, 46, 129)) }); sp.Children.Add(new TextBlock { Text = "This card was built in memory and printed with PrintDialog.PrintVisual.", Margin = new Thickness(0, 8, 0, 0), TextWrapping = TextWrapping.Wrap }); sp.Children.Add(new TextBlock { Text = "Printed on " + DateTime.Now.ToLongDateString() + " at " + DateTime.Now.ToLongTimeString(), Margin = new Thickness(0, 8, 0, 0), Foreground = Brushes.Gray }); b.Child = sp; return b; }
        private void PrintBtn_Click(object sender, RoutedEventArgs e){ System.Windows.Controls.PrintDialog pd = new System.Windows.Controls.PrintDialog(); bool? ok = pd.ShowDialog(); if (ok != true) { PrintResult.Text = "Print cancelled - nothing was sent to a printer."; SetStatus("Print dialog cancelled."); return; } try { Border card = MakePrintCard(); card.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); card.Arrange(new Rect(new Point(0, 0), card.DesiredSize)); pd.PrintVisual(card, "WPF Control Gallery sample card"); PrintResult.Text = "Sent one card to the selected printer."; SetStatus("PrintVisual sent the card to the printer."); } catch (Exception ex) { PrintResult.Text = "Printing failed: " + ex.Message; SetStatus("Printing failed: " + ex.Message); } }
        private void FramePage2_Click(object sender, RoutedEventArgs e){ DemoFrame.Navigate(new GalleryPage2()); SetStatus("Frame navigated to page 2."); }
        private void FrameBack_Click(object sender, RoutedEventArgs e){ if (DemoFrame.CanGoBack) { DemoFrame.GoBack(); SetStatus("Frame went back one page."); } else { SetStatus("Nothing earlier in the frame journal."); } }
        private void FrameFwd_Click(object sender, RoutedEventArgs e){ if (DemoFrame.CanGoForward) { DemoFrame.GoForward(); SetStatus("Frame went forward one page."); } else { SetStatus("Nothing later in the frame journal."); } }
        private void DemoWebLoad_Click(object sender, RoutedEventArgs e){ DemoWeb.NavigateToString("<html><body style='font-family:Segoe UI;margin:14px;color:#1f2937'><h2 style='margin:0 0 6px 0'>WebBrowser control</h2><p>This page was generated at runtime with NavigateToString - no network required.</p></body></html>"); SetStatus("WebBrowser loaded an in-memory HTML page."); }
        private void PopupToggle_Click(object sender, RoutedEventArgs e){ DemoPopup.IsOpen = PopupToggle.IsChecked == true; SetStatus("Popup " + (DemoPopup.IsOpen ? "opened - click outside to dismiss." : "closed.")); }
        private void DemoPopup_Closed(object sender, EventArgs e){ PopupToggle.IsChecked = false; }
        private void DragThumb_DragStarted(object sender, DragStartedEventArgs e){ DragState.Text = "Dragging..."; SetStatus("Thumb drag started."); }
        private void DragThumb_DragDelta(object sender, DragDeltaEventArgs e){ Thumb t = (Thumb)sender; double x = Canvas.GetLeft(t) + e.HorizontalChange; double y = Canvas.GetTop(t) + e.VerticalChange; double maxX = Math.Max(0, DragCanvas.ActualWidth - t.ActualWidth); double maxY = Math.Max(0, DragCanvas.ActualHeight - t.ActualHeight); Canvas.SetLeft(t, Math.Min(Math.Max(0, x), maxX)); Canvas.SetTop(t, Math.Min(Math.Max(0, y), maxY)); DragState.Text = "Position: " + Canvas.GetLeft(t).ToString("0") + ", " + Canvas.GetTop(t).ToString("0"); }
        private void DragSrc_MouseMove(object sender, MouseEventArgs e){ if (e.LeftButton == MouseButtonState.Pressed && sender is ListBox lb && lb.SelectedItem != null) { string item = lb.SelectedItem as string ?? ""; if (item.Length > 0) { DragDrop.DoDragDrop(lb, item, DragDropEffects.Move); } } }
        private void DragTgt_Over(object sender, DragEventArgs e){ e.Effects = e.Data.GetDataPresent(DataFormats.StringFormat) ? DragDropEffects.Move : DragDropEffects.None; e.Handled = true; }
        private void DragTgt_Drop(object sender, DragEventArgs e){ if (e.Data.GetDataPresent(DataFormats.StringFormat)) { string s = (string)e.Data.GetData(DataFormats.StringFormat); ListBox tgt = (ListBox)sender; ListBox src = ReferenceEquals(tgt, DragListA) ? DragListB : DragListA; if (!tgt.Items.Contains(s)) { src.Items.Remove(s); tgt.Items.Add(s); SetStatus("Moved '" + s + "' between lists with drag and drop."); } } e.Handled = true; }
        private void MultiList_SelectionChanged(object sender, SelectionChangedEventArgs e){ if (MultiList == null || MultiResult == null) { return; } MultiResult.Text = MultiList.SelectedItems.Count + " item(s) selected."; SetStatus("Extended selection: " + MultiList.SelectedItems.Count + " item(s)."); }
        private void CheckMenu_Click(object sender, RoutedEventArgs e){ if (sender is MenuItem mi) { SetStatus("Menu item '" + mi.Header + "' is now " + (mi.IsChecked ? "checked" : "unchecked") + "."); } }
        private void MenuRefresh_Click(object sender, RoutedEventArgs e){ SetStatus("View > Refresh acknowledged."); }
        private void BigListGen_Click(object sender, RoutedEventArgs e){ Stopwatch sw = Stopwatch.StartNew(); List<string> rows = new List<string>(10000); for (int i = 1; i <= 10000; i++) { rows.Add("Row " + i + " - payload " + (i * 7)); } BigList.ItemsSource = rows; sw.Stop(); BigListInfo.Text = "10,000 rows bound in " + sw.ElapsedMilliseconds + " ms"; SetStatus("Generated 10,000 virtualized rows in " + sw.ElapsedMilliseconds + " ms - scroll smoothly."); }
        private void SinkBtn_Click(object sender, RoutedEventArgs e){ try { if (FunCheck.IsChecked != true) { FunCheck.IsChecked = true; Fun_Toggled(FunCheck, new RoutedEventArgs()); } } catch { } try { AnimSize_Click(this, new RoutedEventArgs()); } catch { } try { AnimSpin_Click(this, new RoutedEventArgs()); } catch { } try { AnimPulse_Click(this, new RoutedEventArgs()); } catch { } try { Keyframes_Click(this, new RoutedEventArgs()); } catch { } try { RocketBtn_Click(this, new RoutedEventArgs()); } catch { } try { GlowBtn_Click(this, new RoutedEventArgs()); } catch { } try { ResumeCube_Click(this, new RoutedEventArgs()); } catch { } try { if (BigList.Items.Count == 0) { BigListGen_Click(this, new RoutedEventArgs()); } } catch { } try { PlayTone(660); } catch { } try { NavList.SelectedIndex = rnd.Next(1, NavList.Items.Count); } catch { } SetStatus("KITCHEN SINK DEPLOYED - every animation, the cube, a synthesized tone and a random section, all at once."); }
        private FixedDocument MakeFixedDoc(){ FixedDocument fd = new FixedDocument(); fd.DocumentPaginator.PageSize = new Size(792, 1008); for (int i = 1; i <= 2; i++) { FixedPage fp = new FixedPage { Width = 792, Height = 1008, Background = Brushes.White }; StackPanel sp = new StackPanel { Margin = new Thickness(70, 70, 70, 0) }; sp.Children.Add(new TextBlock { Text = "Fixed layout page " + i + " of 2", FontSize = 28, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(Color.FromRgb(49, 46, 129)) }); sp.Children.Add(new TextBlock { Text = "DocumentViewer shows FixedDocuments: pixel-exact, paginated, zoomable and printable - the format XPS is built on.", TextWrapping = TextWrapping.Wrap, FontSize = 14, Margin = new Thickness(0, 14, 0, 0) }); if (i == 1) { sp.Children.Add(new Rectangle { Height = 60, Fill = new LinearGradientBrush(Color.FromRgb(79, 70, 229), Color.FromRgb(236, 72, 153), 0), Margin = new Thickness(0, 16, 0, 0) }); sp.Children.Add(new TextBlock { Text = "A linear gradient drawn on page one.", Margin = new Thickness(0, 10, 0, 0) }); } else { sp.Children.Add(new TextBlock { Text = "Page two proves real pagination - use the viewer chrome to flip pages and zoom.", Margin = new Thickness(0, 16, 0, 0), TextWrapping = TextWrapping.Wrap }); } fp.Children.Add(sp); PageContent pc = new PageContent(); pc.Child = fp; fd.Pages.Add(pc); } return fd; }
        private void BuildFixedDoc(){ try { FixedViewer.Document = MakeFixedDoc(); FixedInfo.Text = "A two-page FixedDocument was assembled entirely in code and loaded into the DocumentViewer - pop it out for the big-screen version."; } catch (Exception ex) { FixedInfo.Text = "FixedDocument unavailable: " + ex.Message; } }
    }

    public class Person { public string Name { get; set; } = ""; public int Age { get; set; } public string City { get; set; } = ""; public string Email { get; set; } = ""; public bool Active { get; set; } public double Score { get; set; } }
    public class FileRow { public string Name { get; set; } = ""; public double SizeKb { get; set; } public string Type { get; set; } = ""; public string Modified { get; set; } = ""; }
    public class TeamMember { public string Name { get; set; } = ""; public string Role { get; set; } = ""; public Brush Color { get; set; } = Brushes.Transparent; }
    public class Product { public string Name { get; set; } = ""; public string Category { get; set; } = ""; public double Price { get; set; } }
    public class HNode { public string Title { get; set; } = ""; public bool Done { get; set; } public ObservableCollection<HNode>? Kids { get; set; } }
    public class RangeRule : ValidationRule
    {
        private readonly double min; private readonly double max;
        public RangeRule(double min, double max){ this.min = min; this.max = max; }
        public override ValidationResult Validate(object value, CultureInfo cultureInfo){ if (double.TryParse(value as string ?? "", NumberStyles.Any, CultureInfo.InvariantCulture, out double d) && d >= min && d <= max) { return ValidationResult.ValidResult; } return new ValidationResult(false, "Enter a number between " + min + " and " + max + "."); }
    }
    public class KiloFormatter : IValueConverter
    {
        public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture){ try { double d = System.Convert.ToDouble(value); return d.ToString("0") + " KB"; } catch { return "?"; } }
        public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture){ return Binding.DoNothing; }
    }
    public class RingAdorner : Adorner
    {
        public RingAdorner(UIElement adornedElement) : base(adornedElement) { }
        protected override void OnRender(DrawingContext dc){ Rect r = new Rect(AdornedElement.RenderSize); r.Inflate(7, 7); Pen p = new Pen(new SolidColorBrush(Color.FromRgb(220, 38, 38)), 2) { DashStyle = DashStyles.Dash }; dc.DrawRoundedRectangle(null, p, r, 10, 10); }
    }
    public class Gauge : FrameworkElement
    {
        public static readonly DependencyProperty ValueProperty = DependencyProperty.Register("Value", typeof(double), typeof(Gauge), new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
        public double Value { get { return (double)GetValue(ValueProperty); } set { SetValue(ValueProperty, value); } }
        protected override Size MeasureOverride(Size availableSize){ double w = double.IsInfinity(availableSize.Width) ? 150 : availableSize.Width; double h = double.IsInfinity(availableSize.Height) ? 110 : availableSize.Height; return new Size(w, h); }
        private static Point Pt(double cx, double cy, double r, double deg){ double rad = deg * Math.PI / 180.0; return new Point(cx + r * Math.Cos(rad), cy + r * Math.Sin(rad)); }
        protected override void OnRender(DrawingContext dc)
        {
            double w = Math.Max(10, ActualWidth), h = Math.Max(10, ActualHeight);
            double cx = w / 2.0, cy = h * 0.58, r = Math.Min(w / 2.3, h / 1.9);
            dc.DrawEllipse(Brushes.White, new Pen(new SolidColorBrush(Color.FromRgb(226, 232, 240)), 2), new Point(cx, cy), r, r);
            double start = -220, end = 40, frac = Math.Max(0, Math.Min(100, Value)) / 100.0, sweep = start + (end - start) * frac;
            if (frac > 0.005)
            {
                Pen arcPen = new Pen(new SolidColorBrush(Color.FromRgb(79, 70, 229)), 9) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
                PathFigure fig = new PathFigure(Pt(cx, cy, r, start), new PathSegment[] { new ArcSegment(Pt(cx, cy, r, sweep), new Size(r, r), 0, (sweep - start) > 180, SweepDirection.Clockwise, false) }, false);
                dc.DrawGeometry(null, arcPen, new PathGeometry(new PathFigure[] { fig }));
            }
            dc.PushTransform(new RotateTransform(sweep, cx, cy));
            dc.DrawLine(new Pen(Brushes.Indigo, 3) { EndLineCap = PenLineCap.Round }, new Point(cx, cy), new Point(cx + r * 0.78, cy));
            dc.Pop();
            dc.DrawEllipse(Brushes.Indigo, null, new Point(cx, cy), 5, 5);
            FormattedText ft = new FormattedText("Gauge: " + Value.ToString("0"), CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 12, Brushes.Gray, VisualTreeHelper.GetDpi(this).PixelsPerDip);
            dc.DrawText(ft, new Point(cx - ft.Width / 2, Math.Min(h - ft.Height, cy + r + 4)));
        }
    }
    public class RatingStars : UserControl
    {
        private readonly ToggleButton[] stars = new ToggleButton[5];
        public event EventHandler<int>? Rated;
        public RatingStars()
        {
            StackPanel sp = new StackPanel { Orientation = Orientation.Horizontal };
            for (int i = 0; i < 5; i++)
            {
                int v = i + 1;
                ToggleButton b = new ToggleButton { Content = "*", Width = 36, Height = 30, FontSize = 16, Margin = new Thickness(0, 0, 4, 0) };
                b.Click += (s, e) => { SetRating(v); if (Rated != null) { Rated(this, v); } };
                stars[i] = b;
                sp.Children.Add(b);
            }
            Content = sp;
        }
        public void SetRating(int v){ for (int j = 0; j < 5; j++) { stars[j].IsChecked = j < v; } }
    }
    public class CubeWindow : Window
    {
        private readonly AxisAngleRotation3D yaw = new AxisAngleRotation3D(new Vector3D(0, 1, 0), 25);
        private readonly AxisAngleRotation3D pitch = new AxisAngleRotation3D(new Vector3D(1, 0, 0), 15);
        private readonly Button spinBtn = new Button { Content = "Auto-spin: OFF", Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(0, 0, 8, 0) };
        private readonly Button resetBtn = new Button { Content = "Reset view", Padding = new Thickness(10, 6, 10, 6) };
        private readonly TextBlock hint = new TextBlock { Margin = new Thickness(0, 10, 0, 0), Foreground = Brushes.LightGray, TextWrapping = TextWrapping.Wrap };
        private bool auto;
        private bool dragging;
        private Point last;
        public CubeWindow(ImageSource? texture)
        {
            Title = "3D Theater - drag to rotate the cube"; Width = 980; Height = 700; WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = new SolidColorBrush(Color.FromRgb(0x0F, 0x17, 0x2A));
            Viewport3D vp = BuildViewport(texture);
            spinBtn.Click += (s, e) => { auto = !auto; spinBtn.Content = "Auto-spin: " + (auto ? "ON" : "OFF"); ApplyAuto(); };
            resetBtn.Click += (s, e) => { auto = false; spinBtn.Content = "Auto-spin: OFF"; yaw.BeginAnimation(AxisAngleRotation3D.AngleProperty, null); yaw.Angle = 25; pitch.Angle = 15; };
            hint.Text = "Drag with the left mouse button to rotate the cube. The material is textured with the plasma bitmap generated in the main window when available; the pink faces are the BackMaterial.";
            StackPanel row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(spinBtn); row.Children.Add(resetBtn);
            StackPanel top = new StackPanel { Margin = new Thickness(12) };
            top.Children.Add(row); top.Children.Add(hint);
            DockPanel dp = new DockPanel();
            DockPanel.SetDock(top, Dock.Top);
            dp.Children.Add(top); dp.Children.Add(vp);
            Content = dp;
            vp.MouseLeftButtonDown += (s, e) => { dragging = true; last = e.GetPosition(vp); vp.CaptureMouse(); if (auto) { auto = false; spinBtn.Content = "Auto-spin: OFF"; yaw.BeginAnimation(AxisAngleRotation3D.AngleProperty, null); yaw.Angle = 25; } };
            vp.MouseMove += (s, e) => { if (!dragging) { return; } Point p = e.GetPosition(vp); yaw.Angle += (p.X - last.X) * 0.6; pitch.Angle = Math.Max(-89, Math.Min(89, pitch.Angle + (p.Y - last.Y) * 0.6)); last = p; };
            vp.MouseLeftButtonUp += (s, e) => { dragging = false; vp.ReleaseMouseCapture(); };
        }
        private void ApplyAuto(){ if (auto) { yaw.BeginAnimation(AxisAngleRotation3D.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(6)) { RepeatBehavior = RepeatBehavior.Forever }); } else { yaw.BeginAnimation(AxisAngleRotation3D.AngleProperty, null); } }
        private Viewport3D BuildViewport(ImageSource? texture)
        {
            Viewport3D vp = new Viewport3D();
            vp.Camera = new PerspectiveCamera(new Point3D(0, 0, 6.2), new Vector3D(0, 0, -1), new Vector3D(0, 1, 0), 55);
            MeshGeometry3D mesh = new MeshGeometry3D { Positions = Point3DCollection.Parse("-1,-1,-1 1,-1,-1 1,1,-1 -1,1,-1 -1,-1,1 1,-1,1 1,1,1 -1,1,1"), TextureCoordinates = PointCollection.Parse("0,0 1,0 1,1 0,1 0,0 1,0 1,1 0,1"), TriangleIndices = Int32Collection.Parse("0,1,2 0,2,3 4,5,6 4,6,7 0,4,5 0,5,1 1,5,6 1,6,2 2,6,7 2,7,3 3,7,4 3,4,0") };
            GeometryModel3D gm = new GeometryModel3D { Geometry = mesh };
            gm.Material = texture != null ? new DiffuseMaterial(new ImageBrush(texture)) : new DiffuseMaterial(new SolidColorBrush(Color.FromRgb(0x63, 0x66, 0xF1)));
            gm.BackMaterial = new DiffuseMaterial(new SolidColorBrush(Color.FromRgb(0xDB, 0x27, 0x77)));
            Transform3DGroup tg = new Transform3DGroup();
            tg.Children.Add(new RotateTransform3D(pitch)); tg.Children.Add(new RotateTransform3D(yaw));
            gm.Transform = tg;
            Model3DGroup group = new Model3DGroup();
            group.Children.Add(new AmbientLight(Color.FromRgb(0x50, 0x50, 0x50))); group.Children.Add(new DirectionalLight(Colors.White, new Vector3D(-0.4, -0.6, -1))); group.Children.Add(gm);
            ModelVisual3D mv = new ModelVisual3D { Content = group };
            vp.Children.Add(mv);
            return vp;
        }
    }
    public class InkWindow : Window
    {
        public InkWindow()
        {
            Title = "Ink Studio - draw big"; Width = 1100; Height = 760; WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = Brushes.White;
            InkCanvas ink = new InkCanvas { Background = new SolidColorBrush(Color.FromRgb(0xFE, 0xFC, 0xE8)) };
            ink.DefaultDrawingAttributes.Color = Colors.Black; ink.DefaultDrawingAttributes.Width = 3; ink.DefaultDrawingAttributes.Height = 3;
            ComboBox color = new ComboBox { Width = 110, SelectedIndex = 0 };
            foreach (string n in new[] { "Black", "Blue", "Red", "Green", "Purple", "Orange" }) { color.Items.Add(new ComboBoxItem { Content = n }); }
            Slider size = new Slider { Minimum = 1, Maximum = 30, Value = 3, Width = 140, IsSnapToTickEnabled = true, TickFrequency = 1, VerticalAlignment = VerticalAlignment.Center };
            ComboBox mode = new ComboBox { Width = 130, SelectedIndex = 0 };
            foreach (string m in new[] { "Draw", "Select", "Erase strokes" }) { mode.Items.Add(new ComboBoxItem { Content = m }); }
            Button clear = new Button { Content = "Clear", Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(10, 0, 0, 0) };
            TextBlock count = new TextBlock { Text = "0", VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeights.SemiBold };
            size.ValueChanged += (s, e) => { ink.DefaultDrawingAttributes.Width = size.Value; ink.DefaultDrawingAttributes.Height = size.Value; };
            color.SelectionChanged += (s, e) => { if (color.SelectedItem is ComboBoxItem ci) { try { ink.DefaultDrawingAttributes.Color = (Color)ColorConverter.ConvertFromString(ci.Content as string ?? "Black"); } catch { } } };
            mode.SelectionChanged += (s, e) => { if (mode.SelectedItem is ComboBoxItem ci) { string m = ci.Content as string ?? "Draw"; ink.EditingMode = m == "Draw" ? InkCanvasEditingMode.Ink : m == "Select" ? InkCanvasEditingMode.Select : InkCanvasEditingMode.EraseByStroke; } };
            clear.Click += (s, e) => ink.Strokes.Clear();
            ink.StrokeCollected += (s, e) => count.Text = ink.Strokes.Count.ToString();
            ink.StrokeErased += (s, e) => count.Text = ink.Strokes.Count.ToString();
            StackPanel bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(12, 12, 12, 6) };
            bar.Children.Add(new TextBlock { Text = "Color:", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) });
            bar.Children.Add(color);
            bar.Children.Add(new TextBlock { Text = "  Size:", VerticalAlignment = VerticalAlignment.Center });
            bar.Children.Add(size);
            bar.Children.Add(new TextBlock { Text = "  Mode:", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 6, 0) });
            bar.Children.Add(mode);
            bar.Children.Add(clear);
            bar.Children.Add(new TextBlock { Text = "  Strokes:", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 4, 0) });
            bar.Children.Add(count);
            TextBlock hint = new TextBlock { Text = "Full-window ink surface: color, pen size and editing mode are all live.", Margin = new Thickness(12, 8, 12, 10), Foreground = Brushes.Gray };
            DockPanel dp = new DockPanel();
            DockPanel.SetDock(bar, Dock.Top); DockPanel.SetDock(hint, Dock.Bottom);
            dp.Children.Add(bar); dp.Children.Add(hint); dp.Children.Add(ink);
            Content = dp;
        }
    }
    public class PlasmaWindow : Window
    {
        private const int PW = 220;
        private const int PH = 140;
        private readonly WriteableBitmap bmp = new WriteableBitmap(PW, PH, 96, 96, PixelFormats.Bgr32, null);
        private readonly byte[] px = new byte[PW * PH * 4];
        private readonly TextBlock info = new TextBlock { Margin = new Thickness(12, 10, 12, 10), Foreground = Brushes.LightGray };
        private readonly System.Windows.Threading.DispatcherTimer timer = new System.Windows.Threading.DispatcherTimer();
        private int frame;
        private int fpsCount;
        private double fps;
        private DateTime fpsMark = DateTime.Now;
        public PlasmaWindow()
        {
            Title = "Plasma Lab - animated WriteableBitmap"; Width = 1000; Height = 640; WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = new SolidColorBrush(Color.FromRgb(0x0F, 0x17, 0x2A));
            Image img = new Image { Source = bmp, Stretch = Stretch.Uniform, Margin = new Thickness(12) };
            DockPanel dp = new DockPanel();
            DockPanel.SetDock(info, Dock.Bottom);
            dp.Children.Add(info); dp.Children.Add(img);
            Content = dp;
            timer.Interval = TimeSpan.FromMilliseconds(33);
            timer.Tick += (s, e) => Render();
            timer.Start();
            Closed += (s, e) => timer.Stop();
            Render();
        }
        private void Render()
        {
            double t = frame * 0.05;
            frame++;
            for (int y = 0; y < PH; y++)
            {
                for (int x = 0; x < PW; x++)
                {
                    double v = Math.Sin(x * 0.09 + t) + Math.Sin(y * 0.11 - t * 0.7) + Math.Sin((x + y) * 0.06 + t * 0.5) + Math.Sin(Math.Sqrt(x * x + y * y) * 0.11 - t);
                    int i = (y * PW + x) * 4;
                    px[i] = (byte)(128 + 127 * Math.Sin(v + 4.2));
                    px[i + 1] = (byte)(128 + 127 * Math.Sin(v + 2.1));
                    px[i + 2] = (byte)(128 + 127 * Math.Sin(v));
                    px[i + 3] = 255;
                }
            }
            bmp.WritePixels(new Int32Rect(0, 0, PW, PH), px, PW * 4, 0);
            fpsCount++;
            if ((DateTime.Now - fpsMark).TotalSeconds >= 1)
            {
                fps = fpsCount; fpsCount = 0; fpsMark = DateTime.Now;
                info.Text = "frame " + frame + " - " + fps.ToString("0") + " FPS - every frame recomputes " + (PW * PH) + " pixels on the UI thread";
            }
        }
    }
    public class DataWindow : Window
    {
        public DataWindow(ObservableCollection<Person> source)
        {
            Title = "DataGrid Theater - shared live collection"; Width = 920; Height = 560; WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = Brushes.White;
            DataGrid g = new DataGrid { AutoGenerateColumns = false, CanUserAddRows = false, Margin = new Thickness(12) };
            g.Columns.Add(new DataGridTextColumn { Header = "Name", Binding = new Binding("Name"), Width = new DataGridLength(150) });
            g.Columns.Add(new DataGridTextColumn { Header = "Age", Binding = new Binding("Age"), Width = new DataGridLength(60) });
            g.Columns.Add(new DataGridTextColumn { Header = "City", Binding = new Binding("City"), Width = new DataGridLength(120) });
            g.Columns.Add(new DataGridCheckBoxColumn { Header = "Active", Binding = new Binding("Active"), Width = new DataGridLength(70) });
            g.Columns.Add(new DataGridTextColumn { Header = "Email", Binding = new Binding("Email"), Width = new DataGridLength(200) });
            g.Columns.Add(new DataGridTextColumn { Header = "Score", Binding = new Binding("Score"), Width = new DataGridLength(70) });
            g.ItemsSource = source;
            TextBlock hint = new TextBlock { Text = "This grid binds the SAME ObservableCollection instance as section 9 - add or edit a row in either window and the other updates instantly.", Margin = new Thickness(12, 10, 12, 10), Foreground = Brushes.Gray, TextWrapping = TextWrapping.Wrap };
            DockPanel dp = new DockPanel();
            DockPanel.SetDock(hint, Dock.Bottom);
            dp.Children.Add(hint); dp.Children.Add(g);
            Content = dp;
        }
    }
    public class DocWindow : Window
    {
        public DocWindow(FixedDocument doc)
        {
            Title = "Document Theater - fixed layout pages"; Width = 980; Height = 780; WindowStartupLocation = WindowStartupLocation.CenterScreen;
            DocumentViewer v = new DocumentViewer { Document = doc };
            Content = v;
        }
    }
    public class GalleryVm : INotifyPropertyChanged, IDataErrorInfo
    {
        private string name = "Ada Lovelace";
        private int age = 36;
        private double score = 65;
        public string Name { get { return name; } set { name = value; Raise("Name"); Raise("Greeting"); Raise("Error"); } }
        public int Age { get { return age; } set { age = value; Raise("Age"); Raise("Greeting"); } }
        public double Score { get { return score; } set { score = value; Raise("Score"); } }
        public string? Nickname { get { return null; } }
        public string Greeting { get { return "Hello, " + Name + " - age " + Age + "!"; } }
        public string Error { get { return this["Name"]; } }
        public string this[string property] { get { if (property == "Name" && string.IsNullOrWhiteSpace(name)) { return "Name must not be empty."; } return ""; } }
        public event PropertyChangedEventHandler? PropertyChanged;
        private void Raise(string p) { PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(p)); }
    }
}
'@
Set-Content -LiteralPath (Join-Path $Dir ($Name+'.csproj')) -Value $proj.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'app.manifest') -Value $manifest.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'App.xaml') -Value $appXaml.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'App.xaml.cs') -Value $appCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'AssemblyInfo.cs') -Value $asmCs -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'MainWindow.xaml') -Value $mwXaml.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'MainWindow.xaml.cs') -Value $mwCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'GalleryPage1.xaml') -Value $page1Xaml.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'GalleryPage1.xaml.cs') -Value $page1Cs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'GalleryPage2.xaml') -Value $page2Xaml.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'GalleryPage2.xaml.cs') -Value $page2Cs.Replace('__APPNAME__',$Name) -Encoding UTF8
}
function New-Project([string]$ExePath,[string]$Name,[string]$Dir){
Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('new','wpf','-n',$Name,'-o',$Dir)
if(-not (Test-Path -LiteralPath (Join-Path $Dir ($Name+'.csproj')))){Throw-Code 4 'The template reported success but the .csproj file is missing from the project directory.'}}
function Publish-Project([string]$ExePath,[string]$Dir,[string]$Out){
Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('restore',$Dir)
Invoke-DotNet -ExePath $ExePath -FailCode 5 -CliArgs @('publish',$Dir,'-c','Release','-r','win-x64','--self-contained','true','-o',$Out)}
function Start-PublishedApp([string]$Exe,[string]$WorkDir){
try{Start-Process -FilePath $Exe -WorkingDirectory $WorkDir;return $true}catch{Write-Warn2 "Auto-launch failed: $($_.Exception.Message)";Write-Warn2 'The executable itself is valid and complete - start it manually by double-clicking:';Write-Warn2 "    $Exe";return $false}}
 $sw=[Diagnostics.Stopwatch]::StartNew()
try{
 $Script:AppKind='WPF'
 $ProjectName=Get-SafeName $ProjectName
if([string]::IsNullOrWhiteSpace($BaseDir)){if($PSScriptRoot){$BaseDir=$PSScriptRoot}else{$BaseDir=(Get-Location).Path}}
if($BaseDir.EndsWith('\') -and $BaseDir.Length -gt 3){$BaseDir=$BaseDir.TrimEnd('\')}
if([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){Throw-Code 1 'The LOCALAPPDATA environment variable is not set on this machine, so no user-local install location can be determined. Check the user profile environment and re-run.'}
 $ProjectDir=Join-Path $BaseDir $ProjectName
 $PublishDir=Join-Path $ProjectDir 'publish'
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "  Bootstrap: building '$ProjectName' (WPF kitchen-sink gallery, .NET 8, single-file exe)" -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Initialize-Tls
 $Script:StageName='Environment checks'
Write-Stage '1/8' 'Initializing TLS and checking free disk space'
Write-Info "Running on Windows PowerShell $($PSVersionTable.PSVersion); TLS 1.2+ enforced; target framework net8.0-windows."
Test-DiskSpace -Path $BaseDir
 $Script:StageName='Clean slate'
Write-Stage '2/8' "Preparing a clean workspace: $ProjectDir"
if(Test-Path -LiteralPath $ProjectDir){Write-Info 'Existing project folder found; destroying it completely for a clean slate...';if(-not (Remove-Folder -Path $ProjectDir)){Write-Err2 "Could not delete '$ProjectDir' after repeated attempts.";Write-Err2 'Usual culprits: the folder is open in an editor, terminal or Explorer window, an antivirus scan holds a lock, OneDrive is syncing, or an app from a previous run is still running.';Write-Err2 'Next step: close everything that uses this folder (or reboot) and run the script again.';exit 7}Write-Ok 'Old project folder removed and verified gone.'}
try{[void][IO.Directory]::CreateDirectory($BaseDir)}catch{Throw-Code 7 "Could not create base directory '$BaseDir': $($_.Exception.Message)"}
try{[void][IO.Directory]::CreateDirectory($ProjectDir)}catch{Throw-Code 7 "Could not create project directory '$ProjectDir': $($_.Exception.Message)"}
if(-not (Test-Path -LiteralPath $ProjectDir)){Throw-Code 7 "Project directory '$ProjectDir' could not be created or verified."}
Write-Ok 'Fresh, empty project directory is ready.'
 $Script:StageName='.NET SDK detection/install'
Write-Stage '3/8' 'Detecting or installing the .NET 8 SDK (user-local, zero elevation)'
 $DotNetExe=Find-DotNetSdk
if($DotNetExe){$sdkSource='pre-existing .NET 8 SDK already on this machine';Write-Ok "Using verified 8.x SDK: $DotNetExe"}
else{
Write-Info "No functional .NET 8 SDK detected; installing a user-local copy under: $($Script:DotnetDir)"
Install-DotNetSdk
Set-DotNetEnv -Dir $Script:DotnetDir
 $DotNetExe=Join-Path $Script:DotnetDir 'dotnet.exe'
if(-not (Test-SdkWorks -DotNetPath $DotNetExe)){
Write-Warn2 'SDK verification failed; the installation looks corrupt or incomplete. Wiping it and reinstalling once...'
if(-not (Remove-Folder -Path $Script:DotnetDir)){Throw-Code 3 "Could not delete the corrupt SDK directory '$($Script:DotnetDir)'. Close any running dotnet processes (see Task Manager) and re-run."}
Install-DotNetSdk
Set-DotNetEnv -Dir $Script:DotnetDir
if(-not (Test-SdkWorks -DotNetPath $DotNetExe)){Throw-Code 3 'The .NET 8 SDK was installed but still fails verification (dotnet --version / --list-sdks). Likely causes: antivirus interference or a proxy corrupting downloads. Check both, then re-run.'}
}
 $sdkSource='freshly installed user-local SDK'
}
 $v=(& $DotNetExe --version);if($LASTEXITCODE -ne 0){Throw-Code 3 "dotnet --version failed with exit code $LASTEXITCODE even after verification."}
Write-Ok "Verified .NET SDK version: $v"
Write-Ok "SDK source: $sdkSource"
 $Script:StageName='Project creation'
Write-Stage '4/8' 'Creating the WPF project from the official template'
New-Project -ExePath $DotNetExe -Name $ProjectName -Dir $ProjectDir
Write-Ok 'Template scaffolded.'
 $Script:StageName='Writing sources'
Write-Stage '5/8' 'Writing the kitchen-sink gallery sources (15 sections, popout windows, DPI manifest, XAML and C#)'
Write-SourceFiles -Dir $ProjectDir -Name $ProjectName
Write-Ok 'All application source files written (csproj, app.manifest, XAML and C#).'
 $Script:StageName='Restore/build/publish'
Write-Stage '6/8' 'Publishing: Release / win-x64 / self-contained single-file (this can take several minutes)'
Publish-Project -ExePath $DotNetExe -Dir $ProjectDir -Out $PublishDir
Write-Ok 'Publish completed with exit code 0.'
 $Script:StageName='Artifact verification'
Write-Stage '7/8' 'Verifying the published executable'
 $exe=Join-Path $PublishDir ($ProjectName+'.exe')
if(-not (Test-Path -LiteralPath $exe)){Start-Sleep -Seconds 3}
if(-not (Test-Path -LiteralPath $exe)){Throw-Code 5 "Publish reported success but '$exe' does not exist. If the exe appeared briefly and then vanished, your antivirus has almost certainly quarantined it - add an exclusion for this folder and re-run."}
 $size=(Get-Item -LiteralPath $exe).Length
if($size -lt 1MB){Throw-Code 5 "The published exe is only $size bytes - far too small for a self-contained single-file build (expected tens of MB). Delete the project folder and re-run."}
 $sizeMb=[math]::Round($size/1MB,1)
Write-Ok "Executable verified: $exe ($sizeMb MB)"
 $Script:StageName='Launch'
if($NoLaunch){Write-Stage '8/8' 'Auto-launch skipped (-NoLaunch was provided)';Write-Info "Run the app anytime by double-clicking: $exe"}
else{Write-Stage '8/8' 'Launching the freshly built kitchen-sink gallery (maximized)';if(-not (Start-PublishedApp -Exe $exe -WorkDir $PublishDir)){exit 6}}
Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host '  SUCCESS - kitchen-sink gallery built, verified and ready' -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
Write-Ok "Project folder : $ProjectDir"
Write-Ok "Publish folder : $PublishDir"
Write-Ok "Executable     : $exe ($sizeMb MB)"
Write-Ok "SDK source     : $sdkSource"
Write-Ok ("Elapsed time   : {0:hh\:mm\:ss}" -f $sw.Elapsed)
Write-Ok 'The exe is fully self-contained: it runs on any Windows 10/11/Server 2016+ x64 machine with no .NET prerequisites.'
exit 0
}
catch{
 $code=1;if($_.Exception.Message -match '^\[(\d)\]'){$code=[int]$Matches[1]}
Write-Host ''
Write-Err2 "FAILED during stage: $($Script:StageName)"
Write-Err2 "Error: $($_.Exception.Message)"
Write-Err2 'Likely cause: the issue named above (no internet, proxy/TLS blocking, antivirus, locked folder, missing permissions or low disk space).'
Write-Err2 'Next step: fix that issue and run this script again - it always starts from a clean slate.'
exit $code
}
finally{
if($Script:InstallerPath -and (Test-Path -LiteralPath $Script:InstallerPath)){Remove-Item -LiteralPath $Script:InstallerPath -Force -ErrorAction SilentlyContinue}
}
