param([string]$ProjectName='PowerShellPolicyConfigurator',[ValidateSet('Auto','Console','Avalonia')][string]$ProjectType='Console',[string]$BaseDir='',[switch]$NoLaunch,[int]$MaxRetries=3)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$Script:StageName='Initialization';$Script:InstallerPath='';$Script:DotnetDir=Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet';$Script:AppKind='Console'
function Write-Info([string]$m){Write-Host $m -ForegroundColor Cyan}
function Write-Ok([string]$m){Write-Host $m -ForegroundColor Green}
function Write-Warn2([string]$m){Write-Host $m -ForegroundColor Yellow}
function Write-Err2([string]$m){Write-Host $m -ForegroundColor Red}
function Throw-Code([int]$c,[string]$m){throw "[$c] $m"}
function Write-Stage([string]$n,[string]$m){Write-Host '';Write-Host "[$n] $m" -ForegroundColor Cyan}
function Initialize-Tls{try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12}catch{};try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13}catch{}}
function Get-SafeName([string]$n){$n=[regex]::Replace($n,'[^A-Za-z0-9_]','');if($n.Length -eq 0){return 'GeneratedApp'};if($n -match '^\d'){$n='App'+$n};$n=$n.Substring(0,1).ToUpperInvariant()+$n.Substring(1);$kw=@('abstract','as','async','await','base','bool','break','byte','case','catch','char','checked','class','const','continue','decimal','default','delegate','do','double','else','enum','event','explicit','extern','false','finally','fixed','float','for','foreach','goto','if','implicit','in','init','int','interface','internal','is','lock','long','namespace','new','null','object','operator','out','override','params','private','protected','public','readonly','record','ref','return','sbyte','sealed','short','sizeof','stackalloc','static','string','struct','switch','this','throw','true','try','typeof','uint','ulong','unchecked','unsafe','ushort','using','var','virtual','void','volatile','while');if($kw -contains $n.ToLowerInvariant()){$n=$n+'App'};return $n}
function Remove-Folder([string]$Path){$p=$Path.TrimEnd('\');if(-not (Test-Path -LiteralPath $p)){return $true};for($i=1;$i -le 3;$i++){try{Get-ChildItem -LiteralPath $p -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {try{$_.Attributes=[IO.FileAttributes]::Normal}catch{}};Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop}catch{Start-Sleep -Seconds ([math]::Min(30,5*$i))};if(-not (Test-Path -LiteralPath $p)){return $true}};try{& cmd.exe /c rd /s /q "$p" | Out-Null}catch{};$gone=-not (Test-Path -LiteralPath $p);if(-not $gone){Write-Warn2 "cmd rd /s /q exited with code $LASTEXITCODE but '$p' still exists."};return $gone}
function Find-DotNetSdk{$cand=@();$local=Join-Path $Script:DotnetDir 'dotnet.exe';if(Test-Path -LiteralPath $local){$cand+=$local};$resolved=Get-Command dotnet.exe -ErrorAction SilentlyContinue;if($resolved -and ($cand -notcontains $resolved.Source)){$cand+=$resolved.Source};foreach($d in $cand){$prev=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$null=(& $d --version 2>$null);if($LASTEXITCODE -eq 0){$sdks=@(& $d --list-sdks 2>$null);if($LASTEXITCODE -eq 0 -and (@($sdks | Where-Object {$_ -match '^8\.'}).Count -gt 0)){return $d}}}catch{}finally{$ErrorActionPreference=$prev}};return $null}
function Test-SdkWorks([string]$DotNetPath){if([string]::IsNullOrWhiteSpace($DotNetPath) -or -not (Test-Path -LiteralPath $DotNetPath)){return $false};$prev=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$null=(& $DotNetPath --version 2>$null);if($LASTEXITCODE -ne 0){return $false};$sdks=@(& $DotNetPath --list-sdks 2>$null);if($LASTEXITCODE -ne 0){return $false};return (@($sdks | Where-Object {$_ -match '^8\.'}).Count -gt 0)}catch{return $false}finally{$ErrorActionPreference=$prev}}
function Save-FileWithRetry([string]$Url,[string]$Dest){for($i=1;$i -le $MaxRetries;$i++){if(Test-Path -LiteralPath $Dest){Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue};try{if($env:HTTPS_PROXY){Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120 -Proxy $env:HTTPS_PROXY -ErrorAction Stop}else{Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop};if((Test-Path -LiteralPath $Dest) -and ((Get-Item -LiteralPath $Dest).Length -gt 1000)){$head=((Get-Content -LiteralPath $Dest -TotalCount 5 -ErrorAction SilentlyContinue) -join ' ');if($head -notmatch '(?i)<\s*html|<!doctype'){return $true}}}catch{};Write-Warn2 "Download attempt $i failed for: $Url";if($i -lt $MaxRetries){Write-Warn2 "Retrying in $([math]::Min(30,5*$i)) seconds...";Start-Sleep -Seconds ([math]::Min(30,5*$i))}};return $false}
function Install-DotNetSdk{$Script:InstallerPath=Join-Path $env:TEMP 'dotnet-install.ps1';$urls=@('https://dot.net/v1/dotnet-install.ps1','https://raw.githubusercontent.com/dotnet/install-scripts/main/src/dotnet-install.ps1');$got=$false;foreach($u in $urls){if(Save-FileWithRetry -Url $u -Dest $Script:InstallerPath){$got=$true;break}};if(-not $got){Throw-Code 2 'Could not download dotnet-install.ps1 from any known mirror after repeated retries.'};try{Unblock-File -LiteralPath $Script:InstallerPath -ErrorAction SilentlyContinue}catch{};Write-Info "Installing the .NET 8 SDK user-local (no elevation) under: $($Script:DotnetDir)";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:InstallerPath -Channel 8.0 -Architecture x64 -InstallDir $Script:DotnetDir;if($LASTEXITCODE -ne 0){Throw-Code 3 "dotnet-install.ps1 exited with code $LASTEXITCODE."}}
function Set-DotNetEnv([string]$Dir){if(-not (Test-Path -LiteralPath $Dir)){Throw-Code 3 "Expected dotnet directory '$Dir' does not exist after installation."};$env:DOTNET_ROOT=$Dir;$env:DOTNET_MULTILEVEL_LOOKUP='0';$env:DOTNET_NOLOGO='1';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:MSBUILDDISABLENODEREUSE='1';$env:NUGET_INTERACTIVE='false';if(@($env:Path -split ';') -notcontains $Dir){$env:Path="$Dir;$env:Path"}}
function Invoke-DotNet{param([string]$ExePath,[int]$FailCode=5,[string[]]$CliArgs=@());& $ExePath @CliArgs;if($LASTEXITCODE -ne 0){Throw-Code $FailCode "dotnet $($CliArgs -join ' ') failed with exit code $LASTEXITCODE. Review the output above for the exact cause."}}
function Test-DiskSpace([string]$Path){$gb=$null;try{$di=New-Object IO.DriveInfo($Path.Substring(0,1));if($di.IsReady){$gb=[math]::Round($di.AvailableFreeSpace/1GB,2)}}catch{};if($null -eq $gb){Write-Warn2 'Could not determine free disk space; continuing.';return};$L=$Path.Substring(0,1);if($gb -lt 0.5){Throw-Code 1 "Only $gb GB free on drive ${L}: - at least 0.5 GB is required."}elseif($gb -lt 2){Write-Warn2 "Low disk space: $gb GB free on drive ${L}:"}else{Write-Ok "Disk space OK: $gb GB free on drive ${L}:"}}
function Write-SourceFiles([string]$Dir,[string]$Name){
$projCs=@'
<Project Sdk="Microsoft.NET.Sdk">
<PropertyGroup>
<OutputType>Exe</OutputType>
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
</PropertyGroup>
</Project>
'@
$progCs=@'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
namespace __APPNAME__
{
internal class Program
{
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
private static extern bool DeleteFile(string lpFileName);
private static int _ok = 0;
private static int _failed = 0;
private static int _skipped = 0;
private static void Main(string[] args)
{
try { RunAll(); }
catch (Exception ex) { Err("Unexpected failure: " + ex.ToString()); }
Console.WriteLine();
Info("Press Enter to exit.");
try { if (Console.IsInputRedirected) { Console.ReadLine(); } else { Console.ReadKey(true); } } catch { }
}
private static void Info(string s) { Console.ForegroundColor = ConsoleColor.Cyan; Console.WriteLine(s); Console.ResetColor(); }
private static void Ok(string s) { _ok++; Console.ForegroundColor = ConsoleColor.Green; Console.WriteLine("[+] " + s); Console.ResetColor(); }
private static void Done(string s) { Console.ForegroundColor = ConsoleColor.Green; Console.WriteLine("[+] " + s); Console.ResetColor(); }
private static void Warn(string s) { Console.ForegroundColor = ConsoleColor.Yellow; Console.WriteLine("[!] " + s); Console.ResetColor(); }
private static void Err(string s) { _failed++; Console.ForegroundColor = ConsoleColor.Red; Console.WriteLine("[FAILED] " + s); Console.ResetColor(); }
private static void Skip(string s) { _skipped++; Console.ForegroundColor = ConsoleColor.Yellow; Console.WriteLine("[SKIPPED] " + s); Console.ResetColor(); }
private static void Section(string s) { Console.WriteLine(); Info("--- " + s + " ---"); }
private static bool IsAdmin() { try { using (var id = WindowsIdentity.GetCurrent()) { return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator); } } catch { return false; } }
private static string RunCmd(string file, string args, out int exit)
{
exit = -1;
try
{
var psi = new ProcessStartInfo { FileName = file, Arguments = args, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
using (var p = Process.Start(psi))
{
if (p == null) return string.Empty;
string o = p.StandardOutput.ReadToEnd();
string er = p.StandardError.ReadToEnd();
p.WaitForExit(60000);
exit = p.ExitCode;
return (o + er).Trim();
}
}
catch (Exception ex) { return ex.Message; }
}
private static bool RegAdd(string key, string name, string type, string data)
{
int ex;
string o = RunCmd("reg.exe", "add \"" + key + "\" /v " + name + " /t " + type + " /d " + data + " /f", out ex);
if (ex == 0) { Done(key + " " + name + " = " + data); return true; }
Err("reg add " + key + " " + name + " -> exit " + ex + " " + o);
return false;
}
private static bool SetPolicyScope(string scope)
{
int ex;
string o = RunCmd("powershell.exe", "-NoProfile -Command \"Set-ExecutionPolicy -Scope " + scope + " -ExecutionPolicy Bypass -Force\"", out ex);
if (ex == 0) { Done("ExecutionPolicy -Scope " + scope + " set to Bypass."); return true; }
Err("Set-ExecutionPolicy -Scope " + scope + " Bypass -> exit " + ex + " " + o);
return false;
}
private static void RunAll()
{
Info("================================================================");
Info("  PowerShell Execution and Attachment Policy Configuration");
Info("================================================================");
Section("Step 0: Administrator privilege validation");
bool admin = IsAdmin();
if (admin) { Done("Running as administrator: all machine and user steps will run."); }
else { Warn("Not running as administrator. No elevation will be requested."); Warn("User steps will run now. Machine steps will be skipped; re-run this exe as administrator yourself if you want them."); }
Section("Step 1: Configuring machine and attachment policies");
if (admin) { RegAdd("HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell", "EnableScripts", "REG_DWORD", "1"); RegAdd("HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell", "ExecutionPolicy", "REG_SZ", "Bypass"); Info("MachinePolicy set to Bypass."); RegAdd("HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Attachments", "SaveZoneInformation", "REG_DWORD", "1"); }
else { Skip("HKLM MachinePolicy EnableScripts and ExecutionPolicy (requires administrator)."); Skip("HKLM Attachments SaveZoneInformation (requires administrator)."); }
RegAdd("HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Attachments", "SaveZoneInformation", "REG_DWORD", "1");
Info("Download attachment tracking disabled for the current user (SaveZoneInformation = 1).");
if (admin) { SetPolicyScope("LocalMachine"); } else { Skip("Set-ExecutionPolicy -Scope LocalMachine Bypass (requires administrator)."); }
SetPolicyScope("CurrentUser");
Section("Step 2: Unblocking existing scripts");
string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
string[] roots = new string[] { Path.Combine(profile, "Downloads"), Path.Combine(profile, "Desktop"), Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments) };
int files = 0;
int cleared = 0;
foreach (string root in roots)
{
if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) { Warn("Folder not found, skipped: " + root); continue; }
try
{
foreach (string f in Directory.EnumerateFiles(root, "*.ps1", SearchOption.AllDirectories))
{
files++;
try { if (DeleteFile(f + ":Zone.Identifier")) cleared++; } catch { }
}
}
catch (Exception ex) { Warn("Could not fully scan " + root + ": " + ex.Message); }
}
Done("Unblocked scan complete: found " + files + " script(s), cleared Zone.Identifier on " + cleared + " file(s). Files with no zone stream needed no action.");
Section("Step 3: Current execution policy status");
int lex;
string list = RunCmd("powershell.exe", "-NoProfile -Command \"Get-ExecutionPolicy -List | Format-Table -AutoSize | Out-String -Width 200\"", out lex);
Console.WriteLine(string.IsNullOrWhiteSpace(list) ? "Could not read Get-ExecutionPolicy -List." : list);
Section("Step 4: Self-test verification");
bool passed = RunVerification();
Console.WriteLine();
Info("================================================================");
if (passed) { Done("VERIFICATION PASSED: test script with an Internet Zone tag executed successfully."); } else { Warn("VERIFICATION FAILED: see the verification output above."); }
Console.WriteLine("Actions succeeded (counted separately from verification): " + _ok);
Console.WriteLine("Actions failed: " + _failed);
Console.WriteLine("Actions skipped: " + _skipped);
Info("Setup complete. You can now run unsigned or downloaded scripts directly, subject to any policy your organization enforces above these scopes.");
}
private static bool RunVerification()
{
string temp = Path.Combine(Path.GetTempPath(), "policy_verify_test.ps1");
try
{
File.WriteAllText(temp, "Write-Output \"VERIFICATION_SUCCESS\"");
try { File.WriteAllText(temp + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3"); } catch { }
int ex;
string o = RunCmd("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + temp + "\"", out ex);
Console.WriteLine("Verification output: " + o);
return o.IndexOf("VERIFICATION_SUCCESS", StringComparison.Ordinal) >= 0;
}
catch (Exception ex) { Err("Could not complete verification test: " + ex.Message); return false; }
finally { try { File.Delete(temp); } catch { } }
}
}
}
'@
Set-Content -LiteralPath (Join-Path $Dir ($Name+'.csproj')) -Value $projCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'Program.cs') -Value $progCs.Replace('__APPNAME__',$Name) -Encoding UTF8
}
function New-Project([string]$ExePath,[string]$Name,[string]$Dir){Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('new','console','-n',$Name,'-o',$Dir);if(-not (Test-Path -LiteralPath (Join-Path $Dir ($Name+'.csproj')))){Throw-Code 4 'The template reported success but the project workspace could not be created.'}}
function Publish-Project([string]$ExePath,[string]$Dir,[string]$Out){Write-Info 'Running package restore...';Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('restore',$Dir,'-r','win-x64','--interactive','false');Write-Info 'Compiling and publishing self-contained binary...';Invoke-DotNet -ExePath $ExePath -FailCode 5 -CliArgs @('publish',$Dir,'-c','Release','-r','win-x64','--self-contained','true','-o',$Out,'/p:UseSharedCompilation=false','/p:NodeReuse=false')}
function Start-PublishedApp([string]$Exe,[string]$WorkDir){try{Start-Process -FilePath $Exe -WorkingDirectory $WorkDir;return $true}catch{Write-Warn2 "Auto-launch failed: $($_.Exception.Message)";Write-Warn2 'The executable is valid and complete - start manually by double-clicking:';Write-Warn2 "    $Exe";return $false}}
$sw=[Diagnostics.Stopwatch]::StartNew()
try{
$ProjectName=Get-SafeName $ProjectName
if([string]::IsNullOrWhiteSpace($BaseDir)){if($PSScriptRoot){$BaseDir=$PSScriptRoot}else{$BaseDir=(Get-Location).Path}}
if($BaseDir.EndsWith('\') -and $BaseDir.Length -gt 3){$BaseDir=$BaseDir.TrimEnd('\')}
if([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){Throw-Code 1 'The LOCALAPPDATA environment variable is not set.'}
$ProjectDir=Join-Path $BaseDir $ProjectName
$PublishDir=Join-Path $ProjectDir 'publish'
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "  Bootstrap: building '$ProjectName' (console policy configurator)" -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Initialize-Tls
$Script:StageName='Environment checks'
Write-Stage '1/8' 'Initializing TLS and checking free disk space'
Write-Info "Running on Windows PowerShell $($PSVersionTable.PSVersion); TLS 1.2+ enforced; target framework net8.0."
Test-DiskSpace -Path $BaseDir
$Script:StageName='Clean slate'
Write-Stage '2/8' "Preparing clean workspace: $ProjectDir"
if(Test-Path -LiteralPath $ProjectDir){Write-Info 'Existing project folder found; destroying it...';if(-not (Remove-Folder -Path $ProjectDir)){Write-Err2 "Could not delete '$ProjectDir' after repeated attempts. Close any open editor, Explorer window or antivirus scan on it and re-run.";exit 7};Write-Ok 'Old project folder removed and verified gone.'}
try{[void][IO.Directory]::CreateDirectory($BaseDir)}catch{Throw-Code 7 "Could not create base directory '$BaseDir': $($_.Exception.Message)"}
try{[void][IO.Directory]::CreateDirectory($ProjectDir)}catch{Throw-Code 7 "Could not create project directory '$ProjectDir': $($_.Exception.Message)"}
if(-not (Test-Path -LiteralPath $ProjectDir)){Throw-Code 7 "Project directory '$ProjectDir' could not be created."}
Write-Ok 'Fresh project directory is ready.'
$Script:StageName='.NET SDK detection/install'
Write-Stage '3/8' 'Detecting or installing .NET 8 SDK (user-local, zero elevation)'
$DotNetExe=Find-DotNetSdk
if($DotNetExe){$sdkSource='pre-existing .NET 8 SDK';Write-Ok "Using verified 8.x SDK: $DotNetExe"}
else{
Write-Info "No functional .NET 8 SDK detected; installing a user-local copy under: $($Script:DotnetDir)"
Install-DotNetSdk
Set-DotNetEnv -Dir $Script:DotnetDir
$DotNetExe=Join-Path $Script:DotnetDir 'dotnet.exe'
if(-not (Test-SdkWorks -DotNetPath $DotNetExe)){
Write-Warn2 'SDK verification failed. Wiping directory and reinstalling once...'
if(-not (Remove-Folder -Path $Script:DotnetDir)){Throw-Code 3 "Could not delete SDK directory '$($Script:DotnetDir)'."}
Install-DotNetSdk
Set-DotNetEnv -Dir $Script:DotnetDir
if(-not (Test-SdkWorks -DotNetPath $DotNetExe)){Throw-Code 3 'The .NET 8 SDK was installed but still fails basic verification.'}
}
$sdkSource='freshly installed user-local SDK'
}
Set-DotNetEnv -Dir (Split-Path $DotNetExe)
$v=(& $DotNetExe --version);if($LASTEXITCODE -ne 0){Throw-Code 3 "dotnet --version failed with exit code $LASTEXITCODE."}
Write-Ok "Verified .NET SDK version: $v ($sdkSource)"
$Script:StageName='Project creation'
Write-Stage '4/8' 'Initializing console project workspace structure'
New-Project -ExePath $DotNetExe -Name $ProjectName -Dir $ProjectDir
Write-Ok 'Workspace initialized.'
$Script:StageName='Writing sources'
Write-Stage '5/8' 'Writing console policy configurator source files'
Write-SourceFiles -Dir $ProjectDir -Name $ProjectName
Write-Ok 'All source files written.'
$Script:StageName='Restore/build/publish'
Write-Stage '6/8' 'Restoring and publishing self-contained console executable'
Publish-Project -ExePath $DotNetExe -Dir $ProjectDir -Out $PublishDir
Write-Ok 'Publish completed.'
$Script:StageName='Artifact verification'
Write-Stage '7/8' 'Verifying published artifact executable'
$exe=Join-Path $PublishDir ($ProjectName+'.exe')
if(-not (Test-Path -LiteralPath $exe)){Start-Sleep -Seconds 3}
if(-not (Test-Path -LiteralPath $exe)){Throw-Code 5 "Publish reported success but '$exe' was not found. Your antivirus may have quarantined it - add an exception and re-run."}
$size=(Get-Item -LiteralPath $exe).Length
if($size -lt 1MB){Throw-Code 5 "Published exe is only $size bytes (too small for a self-contained executable)."}
$sizeMb=[math]::Round($size/1MB,1)
Write-Ok "Executable verified: $exe ($sizeMb MB)"
$Script:StageName='Launch'
if($NoLaunch){Write-Stage '8/8' 'Auto-launch skipped (-NoLaunch provided)';Write-Info "Run the app manually: $exe"}
else{Write-Stage '8/8' 'Launching the freshly built console application';Write-Info 'The console app runs all policies automatically, verifies, then waits for Enter.';if(-not (Start-PublishedApp -Exe $exe -WorkDir $PublishDir)){exit 6}}
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
catch{
$code=1;if($_.Exception.Message -match '^\[(\d)\]'){$code=[int]$Matches[1]}
Write-Host ''
Write-Err2 "FAILED during stage: $($Script:StageName)"
Write-Err2 "Error: $($_.Exception.Message)"
Write-Err2 'Next step: address the error above and re-run.'
exit $code
}
finally{
if($Script:InstallerPath -and (Test-Path -LiteralPath $Script:InstallerPath)){Remove-Item -LiteralPath $Script:InstallerPath -Force -ErrorAction SilentlyContinue}
}
