param([string]$ProjectName='FileIntegrityMonitor',[ValidateSet('Auto','Console','WPF')][string]$ProjectType='Console',[string]$BaseDir='',[switch]$NoLaunch,[int]$MaxRetries=3)
 $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
 $Script:StageName='Initialization';$Script:InstallerPath='';$Script:DotnetDir=Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet';$Script:AppKind='Console'
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
 $projCon=@'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><Nullable>enable</Nullable><ImplicitUsings>enable</ImplicitUsings><SelfContained>true</SelfContained><RuntimeIdentifier>win-x64</RuntimeIdentifier><PublishSingleFile>true</PublishSingleFile><IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract><EnableCompressionInSingleFile>true</EnableCompressionInSingleFile><DebugType>embedded</DebugType><RootNamespace>__APPNAME__</RootNamespace><AssemblyName>__APPNAME__</AssemblyName><SatelliteResourceLanguages>en</SatelliteResourceLanguages></PropertyGroup></Project>
'@
 $progCs=@'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace __APPNAME__
{
    internal sealed class FileEntry
    {
        public string Path { get; set; } = string.Empty;
        public long Size { get; set; }
        public DateTime Modified { get; set; }
        public string? Hash { get; set; }
    }

    internal sealed class ScanResult
    {
        public List<FileEntry> Added { get; set; } = new List<FileEntry>();
        public List<FileEntry> Modified { get; set; } = new List<FileEntry>();
        public List<FileEntry> Deleted { get; set; } = new List<FileEntry>();
        public int Unchanged { get; set; }
    }

    internal static class Program
    {
        private static readonly Dictionary<string, FileEntry> Baseline = new Dictionary<string, FileEntry>(StringComparer.OrdinalIgnoreCase);
        private static readonly Dictionary<string, FileEntry> Current = new Dictionary<string, FileEntry>(StringComparer.OrdinalIgnoreCase);
        private static readonly List<string> Excludes = new List<string>();
        private static string? loadedBaselinePath;
        private static string? scanRoot;
        private static bool hashFiles = true;

        private static int Main()
        {
            PrintBanner();
            int exitCode = 0;
            try { RunLoop(); } catch (Exception ex) { Console.ForegroundColor = ConsoleColor.Red; Console.Error.WriteLine("Unexpected failure: " + ex.Message); Console.ResetColor(); exitCode = 1; }
            Console.WriteLine();
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("Finished. Press Enter (or any key) to close this window...");
            Console.ResetColor();
            if (Console.IsInputRedirected) { Console.ReadLine(); } else { Console.ReadKey(true); }
            return exitCode;
        }

        private static void PrintBanner()
        {
            Console.ForegroundColor = ConsoleColor.Cyan;
            Console.WriteLine("==========================================================");
            Console.WriteLine("  __APPNAME__ - File Integrity Monitor & Baseline Scanner");
            Console.WriteLine("==========================================================");
            Console.ResetColor();
            Console.WriteLine("Recursively hashes files, tracks changes against a baseline, exports CSV/JSON.");
            Console.WriteLine("Type 'help' for the command list, 'quit' to exit.");
        }

        private static void RunLoop()
        {
            while (true)
            {
                Console.ForegroundColor = ConsoleColor.Yellow;
                Console.Write("fim> ");
                Console.ResetColor();
                string? line = Console.ReadLine();
                if (line == null) { Console.WriteLine(); return; }
                string input = line.Trim();
                if (input.Length == 0) continue;
                string[] parts = SplitArgs(input);
                string cmd = parts[0].ToLowerInvariant();
                string rest = parts.Length > 1 ? input.Substring(parts[0].Length).Trim() : string.Empty;
                try
                {
                    switch (cmd)
                    {
                        case "quit": case "exit": return;
                        case "help": case "?": PrintHelp(); break;
                        case "scan": CmdScan(rest); break;
                        case "exclude": CmdExclude(rest); break;
                        case "hash": CmdHash(rest); break;
                        case "save": CmdSave(rest); break;
                        case "load": CmdLoad(rest); break;
                        case "compare": CmdCompare(rest); break;
                        case "list": CmdList(rest); break;
                        case "stats": CmdStats(); break;
                        case "export": CmdExport(rest); break;
                        case "clear": CmdClear(); break;
                        case "status": CmdStatus(); break;
                        case "verify": CmdVerify(rest); break;
                        case "find": CmdFind(rest); break;
                        case "du": case "diskusage": CmdDiskUsage(rest); break;
                        default: WriteError("Unknown command '" + cmd + "'. Type 'help' to see available commands."); break;
                    }
                }
                catch (Exception ex) { WriteError("Command failed: " + ex.Message); }
            }
        }

        private static void PrintHelp()
        {
            Console.WriteLine("Commands:");
            Console.WriteLine("  scan <dir>             Recursively scan <dir> and populate the current snapshot.");
            Console.WriteLine("  exclude <pattern>     Add a wildcard exclude pattern, e.g. *.log or bin.");
            Console.WriteLine("  hash on|off            Toggle SHA-256 hashing (off = faster, size+mtime only).");
            Console.WriteLine("  save [file]            Save the current snapshot as a baseline JSON file.");
            Console.WriteLine("  load [file]            Load a baseline JSON file for comparison.");
            Console.WriteLine("  compare                Diff current snapshot vs loaded baseline.");
            Console.WriteLine("  verify                 Re-hash every file in the current snapshot and flag changes.");
            Console.WriteLine("  list [filter]          List current entries, optionally filtered by substring.");
            Console.WriteLine("  find <pattern>         Find files whose path matches a wildcard pattern.");
            Console.WriteLine("  du                     Show disk usage grouped by top-level subdirectory.");
            Console.WriteLine("  stats                  Show snapshot statistics (count, size, hash time).");
            Console.WriteLine("  export <csv>           Export the current snapshot to a CSV file.");
            Console.WriteLine("  status                 Show current configuration and state.");
            Console.WriteLine("  clear                  Clear the current snapshot (keeps the baseline).");
            Console.WriteLine("  help                   Show this command list.");
            Console.WriteLine("  quit                   Leave the application.");
        }

        private static void CmdScan(string args)
        {
            if (args.Length == 0) { WriteError("Usage: scan <dir>"); return; }
            string dir = ExpandPath(args);
            if (!Directory.Exists(dir)) { WriteError("Directory does not exist: " + dir); return; }
            Current.Clear();
            scanRoot = dir;
            int count = 0; long bytes = 0; int skipped = 0; int errors = 0;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            Console.ForegroundColor = ConsoleColor.Cyan; Console.Write("Scanning "); Console.ResetColor();
            EnumerateFiles(dir, (file, rel) =>
            {
                try
                {
                    var fi = new FileInfo(file);
                    var e = new FileEntry { Path = rel, Size = fi.Length, Modified = fi.LastWriteTimeUtc };
                    if (hashFiles && fi.Length > 0)
                    {
                        try { using var s = fi.OpenRead(); using var sha = SHA256.Create(); e.Hash = BytesToHex(sha.ComputeHash(s)); }
                        catch (IOException) { e.Hash = "<unreadable>"; errors++; }
                        catch (UnauthorizedAccessException) { e.Hash = "<denied>"; errors++; }
                    }
                    Current[rel] = e;
                    count++; bytes += fi.Length;
                    if (count % 250 == 0) { Console.ForegroundColor = ConsoleColor.DarkCyan; Console.Write("."); Console.ResetColor(); }
                }
                catch (FileNotFoundException) { skipped++; }
                catch (UnauthorizedAccessException) { skipped++; }
                catch (IOException) { skipped++; }
            });
            sw.Stop();
            Console.WriteLine();
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("Scanned " + count + " files (" + FormatBytes(bytes) + ") in " + sw.Elapsed.TotalSeconds.ToString("0.00", CultureInfo.InvariantCulture) + "s" + (skipped > 0 ? "; skipped " + skipped + " inaccessible" : "") + (errors > 0 ? "; " + errors + " hashing errors" : "") + ".");
            Console.ResetColor();
        }

        private static void EnumerateFiles(string root, Action<string, string> emit)
        {
            Stack<string> dirs = new Stack<string>();
            dirs.Push(root);
            while (dirs.Count > 0)
            {
                string current = dirs.Pop();
                string[] subdirs;
                try { subdirs = Directory.GetDirectories(current); } catch (UnauthorizedAccessException) { subdirs = Array.Empty<string>(); } catch (IOException) { subdirs = Array.Empty<string>(); }
                foreach (var sd in subdirs)
                {
                    string name = System.IO.Path.GetFileName(sd);
                    if (MatchesAny(name)) continue;
                    dirs.Push(sd);
                }
                string[] files;
                try { files = Directory.GetFiles(current); } catch (UnauthorizedAccessException) { files = Array.Empty<string>(); } catch (IOException) { files = Array.Empty<string>(); }
                foreach (var f in files)
                {
                    string fn = System.IO.Path.GetFileName(f);
                    if (MatchesAny(fn)) continue;
                    string rel = System.IO.Path.GetRelativePath(root, f).Replace('\\', '/');
                    emit(f, rel);
                }
            }
        }

        private static bool MatchesAny(string name)
        {
            foreach (var p in Excludes) if (MatchesGlob(name, p)) return true;
            return false;
        }

        private static bool MatchesGlob(string name, string pattern)
        {
            if (pattern.Length == 0) return false;
            if (pattern.IndexOfAny(new char[] { '*', '?' }) < 0) return string.Equals(name, pattern, StringComparison.OrdinalIgnoreCase);
            string regex = "^" + Regex.Escape(pattern).Replace("\\*", ".*").Replace("\\?", ".") + "$";
            return Regex.IsMatch(name, regex, RegexOptions.IgnoreCase);
        }

        private static void CmdExclude(string args)
        {
            if (args.Length == 0)
            {
                if (Excludes.Count == 0) { Console.WriteLine("No exclude patterns set."); return; }
                Console.WriteLine("Exclude patterns:");
                foreach (var p in Excludes) Console.WriteLine("  " + p);
                return;
            }
            string[] items = SplitArgs(args);
            foreach (var it in items) Excludes.Add(it);
            Console.WriteLine("Added " + items.Length + " exclude pattern(s). Total: " + Excludes.Count);
        }

        private static void CmdHash(string args)
        {
            if (args.Length == 0) { Console.WriteLine("Hashing is currently " + (hashFiles ? "ON" : "OFF") + "."); return; }
            string v = args.ToLowerInvariant();
            if (v == "on" || v == "true" || v == "1") { hashFiles = true; Console.WriteLine("Hashing enabled."); }
            else if (v == "off" || v == "false" || v == "0") { hashFiles = false; Console.WriteLine("Hashing disabled."); }
            else WriteError("Usage: hash on|off");
        }

        private static void CmdSave(string args)
        {
            if (Current.Count == 0) { WriteError("Nothing to save - scan a directory first."); return; }
            string path = args.Length > 0 ? ExpandPath(args) : DefaultBaselinePath();
            try
            {
                var opts = new JsonSerializerOptions { WriteIndented = true };
                string json = JsonSerializer.Serialize(new { root = scanRoot, hashed = hashFiles, generatedAt = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture), fileCount = Current.Count, files = Current.Values.OrderBy(e => e.Path, StringComparer.OrdinalIgnoreCase).ToList() }, opts);
                File.WriteAllText(path, json);
                loadedBaselinePath = path;
                Baseline.Clear();
                foreach (var e in Current.Values) Baseline[e.Path] = e;
                Console.ForegroundColor = ConsoleColor.Green;
                Console.WriteLine("Saved " + Current.Count + " entries to baseline: " + path);
                Console.ResetColor();
            }
            catch (Exception ex) { WriteError("Save failed: " + ex.Message); }
        }

        private static void CmdLoad(string args)
        {
            string path = args.Length > 0 ? ExpandPath(args) : DefaultBaselinePath();
            if (!File.Exists(path)) { WriteError("Baseline file not found: " + path); return; }
            try
            {
                string json = File.ReadAllText(path);
                using var doc = JsonDocument.Parse(json);
                Baseline.Clear();
                if (doc.RootElement.TryGetProperty("files", out var arr))
                {
                    foreach (var fe in arr.EnumerateArray())
                    {
                        var e = new FileEntry();
                        if (fe.TryGetProperty("path", out var p)) e.Path = p.GetString() ?? string.Empty;
                        if (fe.TryGetProperty("size", out var s)) e.Size = s.GetInt64();
                        if (fe.TryGetProperty("modified", out var m)) e.Modified = m.GetDateTime();
                        if (fe.TryGetProperty("hash", out var h) && h.ValueKind == JsonValueKind.String) e.Hash = h.GetString();
                        if (e.Path.Length > 0) Baseline[e.Path] = e;
                    }
                }
                loadedBaselinePath = path;
                Console.ForegroundColor = ConsoleColor.Green;
                Console.WriteLine("Loaded " + Baseline.Count + " baseline entries from: " + path);
                Console.ResetColor();
            }
            catch (Exception ex) { WriteError("Load failed: " + ex.Message); }
        }

        private static void CmdCompare(string args)
        {
            if (Baseline.Count == 0) { WriteError("No baseline loaded. Use 'load <file>' first (or 'save' to create one from the current snapshot)."); return; }
            if (Current.Count == 0) { WriteError("No current snapshot. Use 'scan <dir>' first."); return; }
            var result = new ScanResult();
            foreach (var kv in Current)
            {
                if (!Baseline.TryGetValue(kv.Key, out var b)) result.Added.Add(kv.Value);
                else if (!EntriesEqual(b, kv.Value)) result.Modified.Add(kv.Value);
                else result.Unchanged++;
            }
            foreach (var kv in Baseline) if (!Current.ContainsKey(kv.Key)) result.Deleted.Add(kv.Value);
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("Comparison complete: " + result.Unchanged + " unchanged, " + result.Added.Count + " added, " + result.Modified.Count + " modified, " + result.Deleted.Count + " deleted.");
            Console.ResetColor();
            int maxShow = 25;
            if (result.Added.Count > 0) { Console.ForegroundColor = ConsoleColor.Green; Console.WriteLine("Added:"); Console.ResetColor(); foreach (var e in result.Added.Take(maxShow)) Console.WriteLine("  + " + e.Path + "  (" + FormatBytes(e.Size) + ")"); if (result.Added.Count > maxShow) Console.WriteLine("  ... and " + (result.Added.Count - maxShow) + " more"); }
            if (result.Modified.Count > 0) { Console.ForegroundColor = ConsoleColor.Yellow; Console.WriteLine("Modified:"); Console.ResetColor(); foreach (var e in result.Modified.Take(maxShow)) Console.WriteLine("  ~ " + e.Path + "  (" + FormatBytes(e.Size) + ")"); if (result.Modified.Count > maxShow) Console.WriteLine("  ... and " + (result.Modified.Count - maxShow) + " more"); }
            if (result.Deleted.Count > 0) { Console.ForegroundColor = ConsoleColor.Red; Console.WriteLine("Deleted:"); Console.ResetColor(); foreach (var e in result.Deleted.Take(maxShow)) Console.WriteLine("  - " + e.Path + "  (" + FormatBytes(e.Size) + ")"); if (result.Deleted.Count > maxShow) Console.WriteLine("  ... and " + (result.Deleted.Count - maxShow) + " more"); }
        }

        private static void CmdVerify(string args)
        {
            if (Current.Count == 0) { WriteError("No current snapshot. Use 'scan <dir>' first."); return; }
            if (scanRoot == null || !Directory.Exists(scanRoot)) { WriteError("Scan root is missing or no longer exists."); return; }
            int changed = 0; int missing = 0; int rehashed = 0;
            Console.ForegroundColor = ConsoleColor.Cyan; Console.Write("Verifying "); Console.ResetColor();
            foreach (var kv in Current.Values.ToList())
            {
                string full = System.IO.Path.Combine(scanRoot, kv.Path.Replace('/', System.IO.Path.DirectorySeparatorChar));
                if (!File.Exists(full)) { missing++; continue; }
                try
                {
                    var fi = new FileInfo(full);
                    bool diff = false;
                    if (fi.Length != kv.Size) diff = true;
                    if (fi.LastWriteTimeUtc != kv.Modified) diff = true;
                    if (hashFiles && fi.Length > 0)
                    {
                        using var s = fi.OpenRead(); using var sha = SHA256.Create();
                        string h = BytesToHex(sha.ComputeHash(s));
                        rehashed++;
                        if (!string.Equals(h, kv.Hash, StringComparison.OrdinalIgnoreCase)) diff = true;
                    }
                    if (diff) { changed++; Console.ForegroundColor = ConsoleColor.Yellow; Console.WriteLine(); Console.WriteLine("  CHANGED: " + kv.Path); Console.ResetColor(); }
                }
                catch (Exception ex) { changed++; Console.ForegroundColor = ConsoleColor.Red; Console.WriteLine(); Console.WriteLine("  ERROR reading " + kv.Path + ": " + ex.Message); Console.ResetColor(); }
                if (rehashed % 250 == 0 && rehashed > 0) { Console.ForegroundColor = ConsoleColor.DarkCyan; Console.Write("."); Console.ResetColor(); }
            }
            Console.WriteLine();
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("Verified " + rehashed + " files; " + changed + " changed, " + missing + " missing.");
            Console.ResetColor();
        }

        private static void CmdList(string args)
        {
            if (Current.Count == 0) { WriteError("No current snapshot. Use 'scan <dir>' first."); return; }
            IEnumerable<FileEntry> entries = Current.Values.OrderBy(e => e.Path, StringComparer.OrdinalIgnoreCase);
            if (args.Length > 0) { string f = args.ToLowerInvariant(); entries = entries.Where(e => e.Path.ToLowerInvariant().Contains(f)); }
            int shown = 0; int max = 50; int total = entries.Count();
            foreach (var e in entries)
            {
                if (shown >= max) { Console.WriteLine("... (" + (total - max) + " more, refine with a filter)"); break; }
                Console.WriteLine("  " + e.Path + "  " + FormatBytes(e.Size) + "  " + e.Modified.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + (e.Hash != null ? "  " + e.Hash.Substring(0, Math.Min(12, e.Hash.Length)) + "..." : ""));
                shown++;
            }
            Console.ForegroundColor = ConsoleColor.DarkGray;
            Console.WriteLine("Showing " + Math.Min(shown, max) + " of " + total + " entries.");
            Console.ResetColor();
        }

        private static void CmdFind(string args)
        {
            if (Current.Count == 0) { WriteError("No current snapshot. Use 'scan <dir>' first."); return; }
            if (args.Length == 0) { WriteError("Usage: find <pattern>   (e.g. find *.cs)"); return; }
            string[] patterns = SplitArgs(args);
            var matches = Current.Values.Where(e => { foreach (var p in patterns) if (MatchesGlob(System.IO.Path.GetFileName(e.Path), p) || MatchesGlob(e.Path, p)) return true; return false; }).OrderBy(e => e.Path, StringComparer.OrdinalIgnoreCase).ToList();
            if (matches.Count == 0) { Console.WriteLine("No matching files."); return; }
            long total = matches.Sum(e => e.Size);
            foreach (var e in matches.Take(100)) Console.WriteLine("  " + e.Path + "  (" + FormatBytes(e.Size) + ")");
            if (matches.Count > 100) Console.WriteLine("  ... and " + (matches.Count - 100) + " more");
            Console.ForegroundColor = ConsoleColor.DarkGray;
            Console.WriteLine(matches.Count + " files matched, " + FormatBytes(total) + " total.");
            Console.ResetColor();
        }

        private static void CmdDiskUsage(string args)
        {
            if (Current.Count == 0 || scanRoot == null) { WriteError("No current snapshot. Use 'scan <dir>' first."); return; }
            var groups = Current.Values.GroupBy(e => { int i = e.Path.IndexOf('/'); return i < 0 ? "(root files)" : e.Path.Substring(0, i); }).Select(g => new { Dir = g.Key, Count = g.Count(), Bytes = g.Sum(e => e.Size) }).OrderByDescending(x => x.Bytes).ToList();
            long totalBytes = Current.Values.Sum(e => e.Size);
            Console.ForegroundColor = ConsoleColor.Cyan; Console.WriteLine("Disk usage by top-level subdirectory under: " + scanRoot); Console.ResetColor();
            foreach (var g in groups)
            {
                double pct = totalBytes > 0 ? 100.0 * g.Bytes / totalBytes : 0;
                string bar = new string('#', (int)Math.Round(pct / 2.0));
                Console.WriteLine("  " + g.Dir.PadRight(28).Substring(0, Math.Min(28, g.Dir.Length)) + "  " + FormatBytes(g.Bytes).PadLeft(10) + "  " + g.Count.ToString(CultureInfo.InvariantCulture).PadLeft(6) + " files  " + pct.ToString("0.0", CultureInfo.InvariantCulture).PadLeft(5) + "%  " + bar);
            }
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("  " + "TOTAL".PadRight(28) + "  " + FormatBytes(totalBytes).PadLeft(10) + "  " + Current.Count.ToString(CultureInfo.InvariantCulture).PadLeft(6) + " files");
            Console.ResetColor();
        }

        private static void CmdStats()
        {
            if (Current.Count == 0) { WriteError("No current snapshot."); return; }
            long totalBytes = Current.Values.Sum(e => e.Size);
            var byExt = Current.Values.GroupBy(e => { int i = e.Path.LastIndexOf('.'); return i >= 0 ? e.Path.Substring(i).ToLowerInvariant() : "(none)"; }).OrderByDescending(g => g.Count()).Take(10);
            Console.ForegroundColor = ConsoleColor.Cyan; Console.WriteLine("Snapshot statistics"); Console.ResetColor();
            Console.WriteLine("  Root             : " + (scanRoot ?? "(none)"));
            Console.WriteLine("  Total files      : " + Current.Count.ToString(CultureInfo.InvariantCulture));
            Console.WriteLine("  Total size       : " + FormatBytes(totalBytes));
            Console.WriteLine("  Largest          : " + FormatBytes(Current.Values.Max(e => e.Size)));
            Console.WriteLine("  Smallest         : " + FormatBytes(Current.Values.Min(e => e.Size)));
            Console.WriteLine("  Average          : " + FormatBytes(Current.Count > 0 ? totalBytes / Current.Count : 0));
            Console.WriteLine("  Hashing          : " + (hashFiles ? "ON" : "OFF"));
            Console.WriteLine("  Baseline loaded  : " + (loadedBaselinePath ?? "(none)"));
            Console.WriteLine("  Exclude patterns : " + Excludes.Count.ToString(CultureInfo.InvariantCulture));
            Console.WriteLine("  Top extensions   :");
            foreach (var g in byExt) Console.WriteLine("    " + g.Key.PadRight(10) + " " + g.Count().ToString(CultureInfo.InvariantCulture).PadLeft(6) + " files, " + FormatBytes(g.Sum(e => e.Size)));
        }

        private static void CmdExport(string args)
        {
            if (Current.Count == 0) { WriteError("Nothing to export - scan a directory first."); return; }
            if (args.Length == 0) { WriteError("Usage: export <csv>"); return; }
            string path = ExpandPath(args);
            try
            {
                var sb = new StringBuilder();
                sb.Append("Path,SizeBytes,ModifiedUtc,SHA256").Append(Environment.NewLine);
                foreach (var e in Current.Values.OrderBy(e => e.Path, StringComparer.OrdinalIgnoreCase))
                {
                    sb.Append(EscapeCsv(e.Path)).Append(',').Append(e.Size.ToString(CultureInfo.InvariantCulture)).Append(',').Append(e.Modified.ToString("o", CultureInfo.InvariantCulture)).Append(',').Append(e.Hash ?? string.Empty).Append(Environment.NewLine);
                }
                File.WriteAllText(path, sb.ToString());
                Console.ForegroundColor = ConsoleColor.Green;
                Console.WriteLine("Exported " + Current.Count + " entries to: " + path);
                Console.ResetColor();
            }
            catch (Exception ex) { WriteError("Export failed: " + ex.Message); }
        }

        private static void CmdClear() { Current.Clear(); scanRoot = null; Console.WriteLine("Current snapshot cleared."); }

        private static void CmdStatus()
        {
            Console.WriteLine("  Current snapshot : " + Current.Count + " files (" + (scanRoot ?? "(none)") + ")");
            Console.WriteLine("  Baseline        : " + Baseline.Count + " files (" + (loadedBaselinePath ?? "(none)") + ")");
            Console.WriteLine("  Hashing         : " + (hashFiles ? "ON" : "OFF"));
            Console.WriteLine("  Excludes        : " + (Excludes.Count == 0 ? "(none)" : string.Join(", ", Excludes)));
        }

        private static bool EntriesEqual(FileEntry a, FileEntry b)
        {
            if (a.Size != b.Size) return false;
            if (a.Modified != b.Modified) return false;
            if (!string.IsNullOrEmpty(a.Hash) && !string.IsNullOrEmpty(b.Hash) && !string.Equals(a.Hash, b.Hash, StringComparison.OrdinalIgnoreCase)) return false;
            return true;
        }

        private static string DefaultBaselinePath() { return System.IO.Path.Combine(Environment.CurrentDirectory, "baseline.json"); }

        private static string ExpandPath(string p) { if (p.StartsWith("~", StringComparison.Ordinal)) p = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + p.Substring(1); return System.IO.Path.GetFullPath(p); }

        private static string[] SplitArgs(string text) { return text.Split((char[])null, StringSplitOptions.RemoveEmptyEntries); }

        private static string BytesToHex(byte[] bytes) { var sb = new StringBuilder(bytes.Length * 2); foreach (var b in bytes) sb.Append(b.ToString("x2", CultureInfo.InvariantCulture)); return sb.ToString(); }

        private static string FormatBytes(long bytes)
        {
            if (bytes < 1024) return bytes.ToString(CultureInfo.InvariantCulture) + " B";
            if (bytes < 1024L * 1024) return (bytes / 1024.0).ToString("0.0", CultureInfo.InvariantCulture) + " KB";
            if (bytes < 1024L * 1024 * 1024) return (bytes / (1024.0 * 1024)).ToString("0.0", CultureInfo.InvariantCulture) + " MB";
            return (bytes / (1024.0 * 1024 * 1024)).ToString("0.00", CultureInfo.InvariantCulture) + " GB";
        }

        private static string EscapeCsv(string s) { if (s.IndexOfAny(new char[] { ',', '"', '\n', '\r' }) >= 0) return "\"" + s.Replace("\"", "\"\"") + "\""; return s; }

        private static void WriteError(string m) { Console.ForegroundColor = ConsoleColor.Red; Console.Error.WriteLine("ERROR: " + m); Console.ResetColor(); }
    }
}
'@
Set-Content -LiteralPath (Join-Path $Dir ($Name+'.csproj')) -Value $projCon.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'Program.cs') -Value $progCs.Replace('__APPNAME__',$Name) -Encoding UTF8
}
function New-Project([string]$ExePath,[string]$Name,[string]$Dir,[string]$Kind){
 $tpl='console'
Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('new',$tpl,'-n',$Name,'-o',$Dir)
if(-not (Test-Path -LiteralPath (Join-Path $Dir ($Name+'.csproj')))){Throw-Code 4 'The template reported success but the .csproj file is missing from the project directory.'}}
function Publish-Project([string]$ExePath,[string]$Dir,[string]$Out){
Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('restore',$Dir)
Invoke-DotNet -ExePath $ExePath -FailCode 5 -CliArgs @('publish',$Dir,'-c','Release','-r','win-x64','--self-contained','true','-o',$Out)}
function Start-PublishedApp([string]$Exe,[string]$WorkDir){
try{Start-Process -FilePath $Exe -WorkingDirectory $WorkDir;return $true}catch{Write-Warn2 "Auto-launch failed: $($_.Exception.Message)";Write-Warn2 'The executable itself is valid and complete - start it manually by double-clicking:';Write-Warn2 "    $Exe";return $false}}
 $sw=[Diagnostics.Stopwatch]::StartNew()
try{
 $Script:AppKind=$ProjectType
 $ProjectName=Get-SafeName $ProjectName
if([string]::IsNullOrWhiteSpace($BaseDir)){if($PSScriptRoot){$BaseDir=$PSScriptRoot}else{$BaseDir=(Get-Location).Path}}
if($BaseDir.EndsWith('\') -and $BaseDir.Length -gt 3){$BaseDir=$BaseDir.TrimEnd('\')}
if([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){Throw-Code 1 'The LOCALAPPDATA environment variable is not set on this machine, so no user-local install location can be determined. Check the user profile environment and re-run.'}
 $ProjectDir=Join-Path $BaseDir $ProjectName
 $PublishDir=Join-Path $ProjectDir 'publish'
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "  Bootstrap: building '$ProjectName' ($($Script:AppKind) app, .NET 8, single-file exe)" -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Initialize-Tls
 $Script:StageName='Environment checks'
Write-Stage '1/8' 'Initializing TLS and checking free disk space'
Write-Info "Running on Windows PowerShell $($PSVersionTable.PSVersion); TLS 1.2+ enforced; target framework net8.0."
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
Write-Ok 'Template scaffolded.'
 $Script:StageName='Writing sources'
Write-Stage '5/8' "Writing application source files ($($Script:AppKind))"
Write-SourceFiles -Dir $ProjectDir -Name $ProjectName -Kind $Script:AppKind
Write-Ok "All application source files written for the $($Script:AppKind) template."
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
