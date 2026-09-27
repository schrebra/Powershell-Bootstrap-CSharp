param([string]$ProjectName='CalculatorApp',[ValidateSet('Auto','Console','WinForms')][string]$ProjectType='WinForms',[string]$BaseDir='',[switch]$NoLaunch,[int]$MaxRetries=3)
 $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
 $Script:StageName='Initialization';$Script:InstallerPath='';$Script:DotnetDir=Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet';$Script:AppKind='WinForms'
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
function Write-SourceFiles([string]$Dir,[string]$Name,[string]$Kind){
 $projWf=@'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>WinExe</OutputType><TargetFramework>net8.0-windows</TargetFramework><Nullable>enable</Nullable><ImplicitUsings>enable</ImplicitUsings><UseWindowsForms>true</UseWindowsForms><SelfContained>true</SelfContained><RuntimeIdentifier>win-x64</RuntimeIdentifier><PublishSingleFile>true</PublishSingleFile><IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract><EnableCompressionInSingleFile>true</EnableCompressionInSingleFile><DebugType>embedded</DebugType><RootNamespace>__APPNAME__</RootNamespace><AssemblyName>__APPNAME__</AssemblyName><SatelliteResourceLanguages>en</SatelliteResourceLanguages></PropertyGroup></Project>
'@
 $progWfCs=@'
using System;
using System.Drawing;
using System.Windows.Forms;
namespace __APPNAME__
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false); Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            Application.ThreadException += (s, e) => { try { MessageBox.Show("An unexpected error occurred:\r\n\r\n" + e.Exception.Message + "\r\n\r\nThe application will keep running.", "__APPNAME__", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { } };
            AppDomain.CurrentDomain.UnhandledException += (s, e) => { try { MessageBox.Show("Fatal error:\r\n\r\n" + ((Exception)e.ExceptionObject).Message, "__APPNAME__", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { } };
            try { Application.Run(new MainForm()); }
            catch (Exception ex) { try { MessageBox.Show("Startup failure - the window could not be created:\r\n\r\n" + ex.ToString(), "__APPNAME__", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { } Environment.ExitCode = 1; }
        }
    }
}
'@
 $mainCs=@'
using System;
using System.Drawing;
using System.Windows.Forms;
namespace __APPNAME__
{
    public class MainForm : Form
    {
        private TextBox display; private Label expressionLabel;
        private string currentEntry = "0"; private string previousEntry = ""; private string operation = ""; private bool justEvaluated = false;
        public MainForm()
        {
            Text = "Modern Calculator"; Font = new Font("Segoe UI", 9F); StartPosition = FormStartPosition.CenterScreen; ClientSize = new Size(340, 520); MinimumSize = new Size(320, 480); BackColor = Color.White; KeyPreview = true;
            TableLayoutPanel grid = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, RowCount = 6, Padding = new Padding(10), BackColor = Color.White };
            for (int i = 0; i < 4; i++) grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25F));
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 120F));
            for (int i = 0; i < 5; i++) grid.RowStyles.Add(new RowStyle(SizeType.Percent, 20F));
            Panel displayPanel = new Panel { Dock = DockStyle.Fill, BackColor = Color.FromArgb(248, 248, 248), Margin = new Padding(4, 4, 4, 12), Padding = new Padding(6) };
            expressionLabel = new Label { Dock = DockStyle.Top, Text = "", Font = new Font("Segoe UI", 10F), ForeColor = Color.Gray, TextAlign = ContentAlignment.MiddleRight, Height = 26, Margin = new Padding(0, 0, 0, 4) };
            display = new TextBox { Dock = DockStyle.Fill, ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = Color.FromArgb(248, 248, 248), Font = new Font("Segoe UI Semibold", 26F), ForeColor = Color.FromArgb(30, 30, 30), TextAlign = HorizontalAlignment.Right, Text = "0" };
            displayPanel.Controls.Add(display); displayPanel.Controls.Add(expressionLabel);
            grid.Controls.Add(displayPanel, 0, 0); grid.SetColumnSpan(displayPanel, 4);
            Color digitColor = Color.FromArgb(250, 250, 250); Color funcColor = Color.FromArgb(235, 235, 235); Color opColor = Color.FromArgb(0, 120, 215); Color eqColor = Color.FromArgb(0, 153, 76);
            Color digitText = Color.Black; Color opText = Color.White;
            AddButton(grid, "C", 1, 0, "ClearAll", funcColor, digitText); AddButton(grid, "CE", 1, 1, "ClearEntry", funcColor, digitText); AddButton(grid, "<-", 1, 2, "Backspace", funcColor, digitText); AddButton(grid, "/", 1, 3, "Op", opColor, opText);
            AddButton(grid, "7", 2, 0, "Digit", digitColor, digitText); AddButton(grid, "8", 2, 1, "Digit", digitColor, digitText); AddButton(grid, "9", 2, 2, "Digit", digitColor, digitText); AddButton(grid, "*", 2, 3, "Op", opColor, opText);
            AddButton(grid, "4", 3, 0, "Digit", digitColor, digitText); AddButton(grid, "5", 3, 1, "Digit", digitColor, digitText); AddButton(grid, "6", 3, 2, "Digit", digitColor, digitText); AddButton(grid, "-", 3, 3, "Op", opColor, opText);
            AddButton(grid, "1", 4, 0, "Digit", digitColor, digitText); AddButton(grid, "2", 4, 1, "Digit", digitColor, digitText); AddButton(grid, "3", 4, 2, "Digit", digitColor, digitText); AddButton(grid, "+", 4, 3, "Op", opColor, opText);
            AddButton(grid, "+/-", 5, 0, "Negate", funcColor, digitText); AddButton(grid, "0", 5, 1, "Digit", digitColor, digitText); AddButton(grid, ".", 5, 2, "Decimal", digitColor, digitText); AddButton(grid, "=", 5, 3, "Equals", eqColor, opText);
            Controls.Add(grid); KeyDown += OnKeyDown;
        }
        private void AddButton(TableLayoutPanel p, string t, int r, int c, string act, Color bg, Color fg)
        {
            Button b = new Button { Text = t, Dock = DockStyle.Fill, Font = new Font("Segoe UI Semibold", 14F), FlatStyle = FlatStyle.Flat, BackColor = bg, ForeColor = fg, Margin = new Padding(4), Cursor = Cursors.Hand };
            b.FlatAppearance.BorderSize = 0; b.Click += (s, e) => HandleAction(act, t); p.Controls.Add(b, c, r);
        }
        private void OnKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Shift && e.KeyCode == Keys.D8) { HandleAction("Op", "*"); e.SuppressKeyPress = true; }
            else if (e.Shift && e.KeyCode == Keys.Oemplus) { HandleAction("Op", "+"); e.SuppressKeyPress = true; }
            else if (e.KeyCode >= Keys.D0 && e.KeyCode <= Keys.D9) { HandleAction("Digit", ((int)e.KeyCode - (int)Keys.D0).ToString()); e.SuppressKeyPress = true; }
            else if (e.KeyCode >= Keys.NumPad0 && e.KeyCode <= Keys.NumPad9) { HandleAction("Digit", ((int)e.KeyCode - (int)Keys.NumPad0).ToString()); e.SuppressKeyPress = true; }
            else if (e.KeyCode == Keys.Add) { HandleAction("Op", "+"); e.SuppressKeyPress = true; }
            else if (e.KeyCode == Keys.Subtract || e.KeyCode == Keys.OemMinus) { HandleAction("Op", "-"); e.SuppressKeyPress = true; }
            else if (e.KeyCode == Keys.Multiply) { HandleAction("Op", "*"); e.SuppressKeyPress = true; }
            else if (e.KeyCode == Keys.Divide || e.KeyCode == Keys.Oem2) { HandleAction("Op", "/"); e.SuppressKeyPress = true; }
            else if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Return || (e.KeyCode == Keys.Oemplus && !e.Shift)) { HandleAction("Equals", "="); e.SuppressKeyPress = true; }
            else if (e.KeyCode == Keys.Back) { HandleAction("Backspace", "<-"); e.SuppressKeyPress = true; }
            else if (e.KeyCode == Keys.Escape) { HandleAction("ClearAll", "C"); e.SuppressKeyPress = true; }
            else if (e.KeyCode == Keys.Decimal || e.KeyCode == Keys.OemPeriod) { HandleAction("Decimal", "."); e.SuppressKeyPress = true; }
        }
        private void HandleAction(string action, string text)
        {
            try
            {
                switch (action)
                {
                    case "Digit": if (justEvaluated || currentEntry == "Error") { currentEntry = "0"; justEvaluated = false; } if (currentEntry == "0") currentEntry = text; else if (currentEntry == "-0") currentEntry = "-" + text; else currentEntry += text; break;
                    case "Decimal": if (justEvaluated || currentEntry == "Error") { currentEntry = "0"; justEvaluated = false; } if (!currentEntry.Contains(".")) currentEntry += "."; break;
                    case "ClearAll": currentEntry = "0"; previousEntry = ""; operation = ""; justEvaluated = false; expressionLabel.Text = ""; break;
                    case "ClearEntry": currentEntry = "0"; justEvaluated = false; break;
                    case "Backspace": if (justEvaluated || currentEntry == "Error") { currentEntry = "0"; justEvaluated = false; } else if (currentEntry.Length > 1 && currentEntry != "-0") { currentEntry = currentEntry.Substring(0, currentEntry.Length - 1); if (currentEntry == "-") currentEntry = "0"; } else currentEntry = "0"; break;
                    case "Negate": if (currentEntry != "0" && currentEntry != "Error") { if (currentEntry.StartsWith("-")) currentEntry = currentEntry.Substring(1); else currentEntry = "-" + currentEntry; } break;
                    case "Op": if (currentEntry == "Error") break; if (!string.IsNullOrEmpty(operation) && !string.IsNullOrEmpty(previousEntry) && !justEvaluated) { Evaluate(); } if (currentEntry == "Error") break; previousEntry = currentEntry; operation = text; justEvaluated = true; expressionLabel.Text = FormatNumber(double.Parse(currentEntry, System.Globalization.CultureInfo.InvariantCulture)) + " " + text; break;
                    case "Equals": Evaluate(); break;
                }
                display.Text = currentEntry;
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Error: " + ex.Message, "Calculator", MessageBoxButtons.OK, MessageBoxIcon.Error);
                currentEntry = "0"; previousEntry = ""; operation = ""; justEvaluated = false; expressionLabel.Text = ""; display.Text = currentEntry;
            }
        }
        private void Evaluate()
        {
            if (string.IsNullOrEmpty(operation) || string.IsNullOrEmpty(previousEntry)) return;
            double prev = double.Parse(previousEntry, System.Globalization.CultureInfo.InvariantCulture);
            double curr = double.Parse(currentEntry, System.Globalization.CultureInfo.InvariantCulture);
            double result = 0;
            switch (operation)
            {
                case "+": result = prev + curr; break;
                case "-": result = prev - curr; break;
                case "*": result = prev * curr; break;
                case "/": if (curr == 0) throw new DivideByZeroException("Cannot divide by zero."); result = prev / curr; break;
            }
            string calcText = FormatNumber(prev) + " " + operation + " " + FormatNumber(curr) + " = " + FormatNumber(result);
            currentEntry = FormatNumber(result); previousEntry = ""; operation = ""; justEvaluated = true; expressionLabel.Text = calcText;
        }
        private string FormatNumber(double value)
        {
            if (double.IsNaN(value) || double.IsInfinity(value)) return "Error";
            return value.ToString("G15", System.Globalization.CultureInfo.InvariantCulture);
        }
    }
}
'@
 $projCon=@'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><Nullable>enable</Nullable><ImplicitUsings>enable</ImplicitUsings><SelfContained>true</SelfContained><RuntimeIdentifier>win-x64</RuntimeIdentifier><PublishSingleFile>true</PublishSingleFile><IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract><EnableCompressionInSingleFile>true</EnableCompressionInSingleFile><DebugType>embedded</DebugType><RootNamespace>__APPNAME__</RootNamespace><AssemblyName>__APPNAME__</AssemblyName><SatelliteResourceLanguages>en</SatelliteResourceLanguages></PropertyGroup></Project>
'@
 $progConCs=@'
using System;
using System.Linq;
namespace __APPNAME__
{
    internal static class Program
    {
        private static int Main(){ Console.ForegroundColor = ConsoleColor.Cyan; Console.WriteLine("=============================================="); Console.WriteLine("  __APPNAME__ - System Information Reporter"); Console.WriteLine("=============================================="); Console.ResetColor(); Console.WriteLine("Commands: os, machine, memory, disks, time, all, help, quit"); int code = 0; try { RunLoop(); } catch (Exception ex) { Console.ForegroundColor = ConsoleColor.Red; Console.WriteLine(); Console.WriteLine("Unexpected failure: " + ex.Message); Console.ResetColor(); code = 1; } Console.WriteLine(); Console.ForegroundColor = ConsoleColor.Green; Console.WriteLine("Finished. Press any key to close this window..."); Console.ResetColor(); if (Console.IsInputRedirected) { Console.ReadLine(); } else { Console.ReadKey(true); } return code; }
        private static void RunLoop(){ bool running = true; while (running) { Console.ForegroundColor = ConsoleColor.Yellow; Console.Write("> "); Console.ResetColor(); string? line = Console.ReadLine(); if (line == null) { running = false; break; } string cmd = line.Trim().ToLowerInvariant(); switch (cmd) { case "": break; case "quit": case "exit": running = false; break; case "help": PrintHelp(); break; case "os": PrintOs(); break; case "machine": PrintMachine(); break; case "memory": PrintMemory(); break; case "disks": PrintDisks(); break; case "time": PrintTime(); break; case "all": PrintOs(); PrintMachine(); PrintMemory(); PrintDisks(); PrintTime(); break; default: Console.WriteLine("Unknown command '" + cmd + "'. Type 'help' for the command list."); break; } } }
        private static void PrintHelp(){ Console.WriteLine("  os      - operating system and runtime details"); Console.WriteLine("  machine - machine and user identity"); Console.WriteLine("  memory  - managed memory and GC information"); Console.WriteLine("  disks   - fixed drives and free space"); Console.WriteLine("  time    - local and UTC time"); Console.WriteLine("  all     - run every report"); Console.WriteLine("  quit    - leave the application"); }
        private static void PrintOs(){ Console.WriteLine($"OS             : {Environment.OSVersion.VersionString}"); Console.WriteLine($"OS is 64-bit   : {Environment.Is64BitOperatingSystem}"); Console.WriteLine($"Process 64-bit : {Environment.Is64BitProcess}"); Console.WriteLine($"Logical CPUs   : {Environment.ProcessorCount}"); Console.WriteLine($".NET runtime   : {Environment.Version}"); }
        private static void PrintMachine(){ Console.WriteLine($"Machine name : {Environment.MachineName}"); Console.WriteLine($"User         : {Environment.UserDomainName}\\{Environment.UserName}"); Console.WriteLine($"System dir   : {Environment.SystemDirectory}"); Console.WriteLine($"Current dir  : {Environment.CurrentDirectory}"); }
        private static void PrintMemory(){ Console.WriteLine($"Managed memory in use : {GC.GetTotalMemory(false) / 1024} KB"); Console.WriteLine($"Process working set   : {Environment.WorkingSet / 1024} KB"); Console.WriteLine($"Gen2 GC collections   : {GC.CollectionCount(2)}"); }
        private static void PrintDisks(){ foreach (DriveInfo d in DriveInfo.GetDrives().Where(x => x.IsReady && x.DriveType == DriveType.Fixed)) { Console.WriteLine($"{d.Name,-5} {d.VolumeLabel,-14} {d.AvailableFreeSpace / (1024 * 1024 * 1024),8} GB free of {d.TotalSize / (1024 * 1024 * 1024)} GB"); } }
        private static void PrintTime(){ Console.WriteLine($"Local time : {DateTime.Now}"); Console.WriteLine($"UTC time   : {DateTime.UtcNow} ({TimeZoneInfo.Local.DisplayName})"); }
    }
}
'@
if($Kind -eq 'WinForms'){
Set-Content -LiteralPath (Join-Path $Dir ($Name+'.csproj')) -Value $projWf.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'Program.cs') -Value $progWfCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'MainForm.cs') -Value $mainCs.Replace('__APPNAME__',$Name) -Encoding UTF8
}else{
Set-Content -LiteralPath (Join-Path $Dir ($Name+'.csproj')) -Value $projCon.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'Program.cs') -Value $progConCs.Replace('__APPNAME__',$Name) -Encoding UTF8
}}
function New-Project([string]$ExePath,[string]$Name,[string]$Dir,[string]$Kind){
 $tpl='winforms';if($Kind -eq 'Console'){$tpl='console'}
Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('new',$tpl,'-n',$Name,'-o',$Dir)
if(-not (Test-Path -LiteralPath (Join-Path $Dir ($Name+'.csproj')))){Throw-Code 4 'The template reported success but the .csproj file is missing from the project directory.'}
if($Kind -ne 'Console'){Get-ChildItem -LiteralPath $Dir -Filter '*.cs' -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue}}
function Publish-Project([string]$ExePath,[string]$Dir,[string]$Out){
Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('restore',$Dir)
Invoke-DotNet -ExePath $ExePath -FailCode 5 -CliArgs @('publish',$Dir,'-c','Release','-r','win-x64','--self-contained','true','-o',$Out)}
function Start-PublishedApp([string]$Exe,[string]$WorkDir){
try{Start-Process -FilePath $Exe -WorkingDirectory $WorkDir;return $true}catch{Write-Warn2 "Auto-launch failed: $($_.Exception.Message)";Write-Warn2 'The executable itself is valid and complete - start it manually by double-clicking:';Write-Warn2 "    $Exe";return $false}}
 $sw=[Diagnostics.Stopwatch]::StartNew()
try{
if($ProjectType -eq 'Auto'){$Script:AppKind='WinForms'}else{$Script:AppKind=$ProjectType}
 $ProjectName=Get-SafeName $ProjectName
if([string]::IsNullOrWhiteSpace($BaseDir)){if($PSScriptRoot){$BaseDir=$PSScriptRoot}else{$BaseDir=(Get-Location).Path}}
if($BaseDir.EndsWith('\') -and $BaseDir.Length -gt 3){$BaseDir=$BaseDir.TrimEnd('\')}
if([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){Throw-Code 1 'The LOCALAPPDATA environment variable is not set on this machine, so no user-local install location can be determined. Check the user profile environment and re-run.'}
 $ProjectDir=Join-Path $BaseDir $ProjectName
 $PublishDir=Join-Path $ProjectDir 'publish'
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "  Bootstrap: building '$ProjectName' ($($Script:AppKind), .NET 8, single-file exe)" -ForegroundColor Cyan
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
Write-Stage '4/8' "Creating the $($Script:AppKind) project from the official template"
New-Project -ExePath $DotNetExe -Name $ProjectName -Dir $ProjectDir -Kind $Script:AppKind
Write-Ok 'Template scaffolded and template leftovers removed.'
 $Script:StageName='Writing sources'
Write-Stage '5/8' "Writing application source files ($($Script:AppKind))"
Write-SourceFiles -Dir $ProjectDir -Name $ProjectName -Kind $Script:AppKind
Write-Ok 'All application source files written (csproj and C#).'
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
else{Write-Stage '8/8' 'Launching the freshly built application';if(-not (Start-PublishedApp -Exe $exe -WorkDir $PublishDir)){exit 6}}
Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host '  SUCCESS - application built, verified and ready' -ForegroundColor Green
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
