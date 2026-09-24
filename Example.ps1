#requires -Version 5.1
<#
=====================================================================================
 bootstrap.ps1 -- single-file C# console-app project bootstrap
                    (Windows PowerShell 5.1 ONLY -- PS 6/7 is rejected on purpose)
=====================================================================================
 WHAT IT DOES, IN ORDER
   1. Resolves the project root:  C:\temp\<ProjectName>
      (aborts on 32-bit Windows -- a 64-bit target could never run there)
   2. IDEMPOTENT CLEAN: wipes any existing project tree on every run, so each
      execution recreates the entire structure from scratch.
   3. SCAFFOLDS a C# 5 / .NET Framework 4.x console app, INCLUDING a standalone
      launcher script (run.ps1). The exe is a STANDALONE program: double-
      clicking it in Explorer keeps its console open until Enter is pressed
      (the exe's own --no-pause flag opts out; redirected stdin also skips the
      pause). Automated callers (smoke test, isolation test, run.ps1) pass
      --no-pause so no automated step ever blocks on a keypress.
   4. COMPILES a 64-BIT SELF-CONTAINED exe: /platform:x64 via the in-box csc.exe
      -> build\bin\<ProjectName>.exe (+ .pdb). The exe references only the
      framework (mscorlib); no NuGet, no satellite DLLs, no ILMerge.
   5. VERIFIES the output is a genuine 64-bit PE (AMD64 machine type, PE32+
      header) by parsing the exe header directly. FATAL if it is not 64-bit.
   6. PROVES self-containment: copies the exe ALONE into a bare temp folder and
      runs it there (isolation test). If it needs any file beside it, that is
      logged as an error.
   7. SMOKE-TESTS the compiled executable with --no-pause, capturing output +
      exit code (build verification only -- this is not the auto-launch).
   8. AUTO-LAUNCH (EXTERNAL): this script NEVER runs the program itself. It
      spawns run.ps1 in a brand-new Windows PowerShell 5.1 console window via
      Start-Process (no -Wait). Skip with -NoLaunch. Result: two windows --
      build (paused) + app (runs, then paused). run.ps1 also runs manually.
   9. LOGS every step (DEBUG/INFO/WARN/ERROR) to the console AND to
      <project>\build\logs\bootstrap.log. The launcher writes its own
      build\logs\run.log + run-transcript.txt.
  10. NEVER closes the window automatically -- a Read-Host holds it open at the
      end (and on every abort path).

 HOW TO RUN (from a Windows PowerShell 5.1 console):
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -ProjectName MyTool
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -NoLaunch

 TIP: keep bootstrap.ps1 OUTSIDE the project folder (e.g. directly in C:\temp),
      because every run wipes C:\temp\<ProjectName> completely. run.ps1 is
      INSIDE the project on purpose and is regenerated on every run.

 NOTE ON "SELF-CONTAINED": under these constraints (PS 5.1, in-box csc.exe, no
      SDK, no internet) the .NET Framework CLR cannot be statically linked into
      the exe. "Self-contained" therefore means: the exe requires ZERO files
      beside it (proven by the isolation test) and runs on any 64-bit Windows
      machine, where .NET Framework 4.x is an inbox OS component (4.8 ships with
      Windows 10 1903+/11). This is the maximum achievable without breaking the
      no-SDK rule; a true single-file publish would need the .NET SDK + PS 6+.
=====================================================================================
#>

[CmdletBinding()]
param(
    [string] $ProjectName = 'HelloBuild',   # project name -> C:\temp\<ProjectName>
    [string] $BasePath    = 'C:\temp',      # parent directory that receives the project
    [switch]  $NoLaunch                   # skip spawning the separate launcher window at the end
)

#=== 0) HARD GUARD: Windows PowerShell 5.x ONLY (pwsh 6/7 rejected) ================
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Host ''
    Write-Host ' ERROR: this bootstrap targets Windows PowerShell 5.1 exclusively.' -ForegroundColor Red
    Write-Host (' Detected : PowerShell {0}' -f $PSVersionTable.PSVersion) -ForegroundColor Red
    Write-Host ' Launch it with powershell.exe (5.1), not pwsh (6/7).' -ForegroundColor Yellow
    $null = Read-Host ' Press Enter to exit'
    exit 1
}

 $ErrorActionPreference = 'Continue'   # critical cmdlets opt into -ErrorAction Stop
 $script:LogPath    = $null            # switched on once build\logs exists
 $script:Failures   = 0
 $script:LastStepOk = $true
 $script:PeVerified            = $false   # set once the exe header proves AMD64/PE32+
 $script:SelfContainedVerified = $false   # set once the isolation test passes

#=== 1) LOGGING: timestamped, color-coded, console + file sink =====================
function Write-Log {
    param(
        [Parameter(Mandatory = $true)] [string] $Message,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line  = '[{0}] [{1,-5}] {2}' -f $stamp, $Level, $Message
    switch ($Level) {
        'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
        'INFO'  { Write-Host $line -ForegroundColor Gray     }
        'WARN'  { Write-Host $line -ForegroundColor Yellow   }
        'ERROR' { Write-Host $line -ForegroundColor Red      }
    }
    if ($script:LogPath) {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

#=== 2) STEP RUNNER: traps and logs every error per step ==========================
function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)] [string]      $Name,
        [Parameter(Mandatory = $true)] [scriptblock] $Action,
        [switch] $Fatal
    )
    Write-Log ("STEP start  : {0}" -f $Name) 'DEBUG'
    try {
        & $Action
        $script:LastStepOk = $true
        Write-Log ("STEP finish : {0}" -f $Name) 'DEBUG'
    }
    catch {
        $script:LastStepOk = $false
        $script:Failures++
        Write-Log ("STEP failed : {0} -> {1}" -f $Name, $_.Exception.Message) 'ERROR'
        Write-Log ("  stack     : {0}" -f $_.ScriptStackTrace) 'DEBUG'
        if ($Fatal) { Stop-Bootstrap ("required step '{0}' failed" -f $Name) }
    }
}

#=== 3) FATAL EXIT: log it, hold the window open, then exit ========================
function Stop-Bootstrap {
    param([string] $Reason)
    Write-Log ("FATAL: {0}" -f $Reason) 'ERROR'
    Write-Host ''
    Write-Host ' Bootstrap aborted -- the window stays open so you can inspect it.' -ForegroundColor Yellow
    $null = Read-Host ' Press Enter to exit'
    exit 1
}

#=== 4) FILE WRITER: writes one project file and logs it ==========================
function Write-ProjectFile {
    param(
        [Parameter(Mandatory = $true)] [string] $RelativePath,
        [Parameter(Mandatory = $true)] [string] $Content
    )
    $full = Join-Path $ProjectRoot $RelativePath
    Invoke-Step -Name ("write file {0}" -f $RelativePath) -Fatal -Action {
        Set-Content -LiteralPath $full -Value $Content -Encoding UTF8 -ErrorAction Stop
        $size = (Get-Item -LiteralPath $full).Length
        Write-Log ("  + file   : {0}  ({1} bytes)" -f $RelativePath, $size) 'DEBUG'
    }
}

#====================================================================================
# MAIN
#====================================================================================
 $script:StartedAt = Get-Date
try { $host.UI.RawUI.WindowTitle = ('Bootstrap :: {0}' -f $ProjectName) } catch { }

Write-Host ''
Write-Host ('=' * 80) -ForegroundColor DarkCyan
Write-Host ('  C# CONSOLE APP BOOTSTRAP  |  Windows PowerShell {0}  |  .NET {1}' -f $PSVersionTable.PSVersion, [Environment]::Version)
Write-Host ('  Project : {0}' -f $ProjectName)
Write-Host ('  Base    : {0}' -f $BasePath)
Write-Host '  Target  : 64-bit self-contained exe (/platform:x64, zero files beside it)'
Write-Host '  Runtime : exe stays open on double-click until Enter (--no-pause opts out)'
Write-Host ('=' * 80) -ForegroundColor DarkCyan
Write-Log 'bootstrap session started' 'DEBUG'

#--- validate parameters + environment -------------------------------------------------
Invoke-Step -Name 'validate parameters and environment' -Fatal -Action {
    # 64-bit OS is mandatory: a /platform:x64 exe cannot run on 32-bit Windows.
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw '32-bit Windows detected - the /platform:x64 output could never run here, aborting.'
    }
    Write-Log ('  OS is 64-bit       : {0}' -f [Environment]::Is64BitOperatingSystem) 'DEBUG'
    Write-Log ('  PowerShell is 64-bit process : {0}' -f [Environment]::Is64BitProcess) 'DEBUG'
    if (-not [Environment]::Is64BitProcess) {
        Write-Log '  running under 32-bit PowerShell (WOW64) - still fine: the 64-bit csc.exe and the x64 exe both launch correctly from here' 'WARN'
    }
    if ([string]::IsNullOrWhiteSpace($ProjectName)) { throw 'ProjectName is empty.' }
    if ($ProjectName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw ('ProjectName has characters that are invalid in a folder name: "{0}"' -f $ProjectName)
    }
    if (-not (Test-Path -LiteralPath $BasePath -PathType Container)) {
        New-Item -ItemType Directory -Path $BasePath -Force -ErrorAction Stop | Out-Null
        Write-Log ("  base directory created: {0}" -f $BasePath)
    }
}

#--- resolve every path we need -------------------------------------------------------
 $ProjectRoot = Join-Path $BasePath $ProjectName
 $SrcDir      = Join-Path $ProjectRoot 'src'
 $PropsDir    = Join-Path $ProjectRoot 'src\Properties'
 $BuildDir    = Join-Path $ProjectRoot 'build'
 $BinDir      = Join-Path $ProjectRoot 'build\bin'
 $LogDir      = Join-Path $ProjectRoot 'build\logs'
 $DocsDir     = Join-Path $ProjectRoot 'docs'
 $TestsDir    = Join-Path $ProjectRoot 'tests'
 $RunScript   = Join-Path $ProjectRoot 'run.ps1'
Write-Log ("project root resolved : {0}" -f $ProjectRoot)

#--- if the console currently sits INSIDE the project dir, step out so the wipe works
try {
    $cwd = (Get-Location).ProviderPath
    if ($cwd -and $cwd.StartsWith($ProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Log 'current location is inside the project folder - stepping out so the wipe can succeed' 'WARN'
        Set-Location -LiteralPath $BasePath -ErrorAction Stop
    }
} catch { }

#--- IDEMPOTENT CLEAN: wipe whatever exists so every run starts from scratch ----------
if (Test-Path -LiteralPath $ProjectRoot) {
    Write-Log ("existing project detected at {0} -- wiping it for a from-scratch rebuild" -f $ProjectRoot) 'WARN'
    Invoke-Step -Name 'remove previous project tree' -Fatal -Action {
        # strip ReadOnly/Hidden/System attributes so -Force removal cannot be blocked
        Get-ChildItem -LiteralPath $ProjectRoot -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                try { $_.Attributes = [System.IO.FileAttributes]::Normal } catch { }
            }
        $maxAttempts = 3
        for ($i = 1; $i -le $maxAttempts; $i++) {
            try {
                Remove-Item -LiteralPath $ProjectRoot -Recurse -Force -ErrorAction Stop
                break
            }
            catch {
                Write-Log ("  delete attempt {0}/{1} failed: {2}" -f $i, $maxAttempts, $_.Exception.Message) 'WARN'
                Start-Sleep -Milliseconds 500
                if ($i -eq $maxAttempts) { throw }
            }
        }
    }
    if (Test-Path -LiteralPath $ProjectRoot) {
        Stop-Bootstrap ("old project directory could not be removed: {0}" -f $ProjectRoot)
    }
    Write-Log 'previous project tree fully removed -- clean slate guaranteed'
}
else {
    Write-Log 'no existing project tree found (first run)'
}

#--- create the folder structure -------------------------------------------------------
 $Folders = @($SrcDir, $PropsDir, $BuildDir, $BinDir, $LogDir, $DocsDir, $TestsDir)
Invoke-Step -Name 'create folder structure' -Fatal -Action {
    foreach ($dir in $Folders) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        Write-Log ("  + folder : {0}" -f $dir) 'DEBUG'
    }
}
 $script:LogPath = Join-Path $LogDir 'bootstrap.log'
Write-Log ("file logging activated: {0}" -f $script:LogPath) 'DEBUG'

#--- file templates (C# 5 = newest syntax the in-box csc.exe understands) -------------
 $SafeNamespace = ($ProjectName -replace '[^A-Za-z0-9_]', '')
if ([string]::IsNullOrWhiteSpace($SafeNamespace)) { $SafeNamespace = 'HelloBuild' }
if ([char]::IsDigit($SafeNamespace[0]))           { $SafeNamespace = '_' + $SafeNamespace }
Write-Log ("C# namespace derived from project name: {0}" -f $SafeNamespace) 'DEBUG'

 $ProgramCsTemplate = @'
// ---------------------------------------------------------------------------
// Program.cs - entry point for the __PROJECT__ console application.
// Compiled as a 64-bit self-contained exe (/platform:x64): this binary needs
// ZERO files beside it - no DLLs, no config - only the .NET Framework CLR,
// which is an inbox component of 64-bit Windows.
//
// STANDALONE BEHAVIOR: double-clicking this exe in Explorer keeps the console
// open until Enter is pressed. A raw console app would otherwise vanish the
// instant Main returns, because Windows owns the window - Explorer does not
// hold it open. The pause is skipped ONLY when explicitly requested
// (--no-pause) or when stdin is redirected (piped/automated callers can
// never press Enter).
//
// Deliberately C# 5.0: the in-box .NET Framework compiler (csc.exe) that ships
// with every Windows PowerShell 5.1 machine stops at C# 5, so this source
// builds anywhere without any SDK installed.
// ---------------------------------------------------------------------------
using System;

namespace __NAMESPACE__
{
    public sealed class Greeter
    {
        private readonly string _name;

        public Greeter(string name)
        {
            _name = String.IsNullOrWhiteSpace(name) ? "World" : name;
        }

        public string Name
        {
            get { return _name; }
        }

        public string BuildGreeting()
        {
            return String.Format("Hello, {0}! I was scaffolded and compiled by bootstrap.ps1.", _name);
        }
    }

    public static class Program
    {
        // Parses the command line: strips the --no-pause control flag and
        // returns the first remaining token as the display name.
        private static string ParseArguments(string[] args, out bool pauseOnExit)
        {
            pauseOnExit = true;
            string name = null;

            if (args != null)
            {
                foreach (string arg in args)
                {
                    if (String.Equals(arg, "--no-pause", StringComparison.OrdinalIgnoreCase))
                    {
                        pauseOnExit = false;
                    }
                    else if (name == null)
                    {
                        name = arg;
                    }
                }
            }

            return name;
        }

        // Keeps the console window open so double-click users can actually read
        // the output. Skipped ONLY when explicitly requested (--no-pause) or
        // when stdin is redirected. Console.IsInputRedirected is .NET 4.5+,
        // which Windows PowerShell 5.1 itself requires, so it is safe here.
        private static void PauseBeforeExit(bool pauseOnExit)
        {
            if (!pauseOnExit)
            {
                return;
            }

            if (Console.IsInputRedirected)
            {
                return; // piped input: no interactive user to press Enter
            }

            Console.WriteLine();
            Console.Write("Press Enter to exit... ");
            try
            {
                Console.ReadLine(); // returns null at end-of-stream; that is fine
            }
            catch
            {
                // A broken stdin must never crash the program on the way out.
            }
        }

        public static int Main(string[] args)
        {
            bool pauseOnExit;
            string name = ParseArguments(args, out pauseOnExit);

            try
            {
                Greeter greeter = new Greeter(name);

                Console.WriteLine(greeter.BuildGreeting());
                Console.WriteLine();
                Console.WriteLine("  Machine     : {0}", Environment.MachineName);
                Console.WriteLine("  User        : {0}", Environment.UserName);
                Console.WriteLine("  CLR runtime : {0}", Environment.Version);
                Console.WriteLine("  OS          : {0}", Environment.OSVersion);
                Console.WriteLine("  64-bit proc : {0}", Environment.Is64BitProcess);
                Console.WriteLine();

                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("Unhandled exception:");
                Console.Error.WriteLine(ex.ToString());
                return 1;
            }
            finally
            {
                // Runs on BOTH the success and the crash path, so the window
                // stays open long enough to read even an error message.
                PauseBeforeExit(pauseOnExit);
            }
        }
    }
}
'@
 $ProgramCs = $ProgramCsTemplate.Replace('__NAMESPACE__', $SafeNamespace).Replace('__PROJECT__', $ProjectName)

 $AssemblyInfoCsTemplate = @'
using System;
using System.Reflection;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("__PROJECT__")]
[assembly: AssemblyDescription("64-bit self-contained console app (stays open standalone until Enter; --no-pause opts out), scaffolded by bootstrap.ps1 (Windows PowerShell 5.1).")]
[assembly: AssemblyConfiguration("Debug")]
[assembly: AssemblyCompany("Example Corp")]
[assembly: AssemblyProduct("__PROJECT__")]
[assembly: AssemblyCopyright("Copyright (c) Example Corp")]
[assembly: AssemblyTrademark("")]
[assembly: AssemblyCulture("")]
[assembly: ComVisible(false)]
[assembly: Guid("1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
'@
 $AssemblyInfoCs = $AssemblyInfoCsTemplate.Replace('__PROJECT__', $ProjectName)

 $AppConfig = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <startup>
    <supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.5" />
  </startup>
</configuration>
'@

#--- run.ps1: the STANDALONE launcher, regenerated fresh on every bootstrap run ------
# The exe filename (__PROJECT__.exe) is baked in at generation time. This script
# is what actually launches the program -- OUTSIDE the build script -- in its
# own console window.
 $RunPs1Template = @'
#requires -Version 5.1
<#
=====================================================================================
 run.ps1 -- STANDALONE launcher for __PROJECT__  (regenerated by bootstrap.ps1)
=====================================================================================
 Runs the 64-bit self-contained build\bin\__PROJECT__.exe in THIS window, logs
 to build\logs\run.log plus a full console transcript
 (build\logs\run-transcript.txt), and never closes itself without a keypress.

 The exe is invoked with --no-pause because THIS script supplies the window's
 pause itself (one keypress total, and the exit code is logged before it).
 Double-clicking the exe DIRECTLY also stays open: the exe pauses itself
 unless told not to.

 Usage (from a Windows PowerShell 5.1 console):
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run.ps1
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 Alice

 The bootstrap normally spawns this script automatically in its own new window
 when a build finishes (-NoLaunch on the bootstrap suppresses that).
=====================================================================================
#>

[CmdletBinding()]
param(
    # everything after the script name is passed straight through to the exe
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $AppArgs
)

#--- guard: Windows PowerShell 5.x only (pwsh 6/7 rejected) --------------------------
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Host ' ERROR: run.ps1 targets Windows PowerShell 5.1 only (powershell.exe, not pwsh 6/7).' -ForegroundColor Red
    $null = Read-Host ' Press Enter to exit'
    exit 1
}

 $ProjectRoot = $PSScriptRoot
 $LogDir      = Join-Path $ProjectRoot 'build\logs'
 $script:LogPath = Join-Path $LogDir 'run.log'
 $ExePath     = Join-Path $ProjectRoot 'build\bin\__PROJECT__.exe'

#--- logging (console + run.log), same style as the bootstrap ------------------------
function Write-Log {
    param(
        [Parameter(Mandatory = $true)] [string] $Message,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line  = '[{0}] [{1,-5}] {2}' -f $stamp, $Level, $Message
    switch ($Level) {
        'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
        'INFO'  { Write-Host $line -ForegroundColor Gray     }
        'WARN'  { Write-Host $line -ForegroundColor Yellow   }
        'ERROR' { Write-Host $line -ForegroundColor Red      }
    }
    if ($script:LogPath) {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

try { New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null } catch { }

#--- transcript: captures EVERYTHING this window prints, including the exe output ----
 $TranscriptPath = Join-Path $LogDir 'run-transcript.txt'
try { Start-Transcript -Path $TranscriptPath -Force -ErrorAction Stop | Out-Null } catch { }

Write-Log ('launcher started  : {0}' -f $ProjectRoot) 'INFO'
Write-Log ('target executable : {0}' -f $ExePath) 'DEBUG'
if (Test-Path -LiteralPath $ExePath -PathType Leaf) {
    Write-Log ('target size       : {0} bytes' -f (Get-Item -LiteralPath $ExePath).Length) 'DEBUG'
}
if ($AppArgs) { Write-Log ('passthrough args  : {0}' -f ($AppArgs -join ' ')) 'DEBUG' }

#--- verify the exe exists -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    Write-Log ('executable not found - run bootstrap.ps1 first: {0}' -f $ExePath) 'ERROR'
    try { Stop-Transcript | Out-Null } catch { }
    $null = Read-Host ' Press Enter to exit'
    exit 1
}

#--- run the program (output appears live in this window; no redirection) --------------
# --no-pause is APPENDED on purpose: the exe would otherwise wait for Enter
# before returning, and this script pauses the window itself afterwards.
# One keypress closes the window; the exit code is logged in between.
 $EffectiveArgs = @('--no-pause')
if ($AppArgs) {
    $EffectiveArgs = @($AppArgs) + @('--no-pause')
}
Write-Log ('exe invocation    : {0}' -f ($EffectiveArgs -join ' ')) 'DEBUG'

 $AppExit = 0
try {
    & $ExePath @EffectiveArgs
    $AppExit = $LASTEXITCODE
}
catch {
    $AppExit = -1
    Write-Log ('failed to start the executable: {0}' -f $_.Exception.Message) 'ERROR'
}

if ($AppExit -eq 0) {
    Write-Log 'program exited cleanly (code 0)' 'INFO'
}
else {
    Write-Log ('program exited with code {0}' -f $AppExit) 'ERROR'
}

try { Stop-Transcript | Out-Null } catch { }

#--- keep this window open ---------------------------------------------------------------
Write-Host ''
Write-Host '  This launcher window is intentionally NOT closed.' -ForegroundColor Cyan
 $null = Read-Host '  Press Enter to close this window'
exit $AppExit
'@
 $RunPs1 = $RunPs1Template.Replace('__PROJECT__', $ProjectName)

 $ReadmeTemplate = @'
# __PROJECT__

A minimal 64-bit self-contained C# console application, scaffolded, compiled,
verified, and smoke-tested by bootstrap.ps1 under Windows PowerShell 5.1. The
program is launched by the SEPARATE run.ps1 script (never by the build script
itself).

**Idempotent:** rerunning the bootstrap deletes this whole folder and recreates
everything from scratch, so the tree is always reproducible.

## Standalone / double-click

Double-click `build\bin\__PROJECT__.exe` in Explorer and the console STAYS
OPEN, showing the output, until you press Enter. A bare console app would
otherwise vanish the instant it finishes, because Windows owns the window -
Explorer does not hold it open. The pause also covers the crash path, so even
an unhandled exception remains readable.

The pause is skipped ONLY when:

- you pass `--no-pause` (case-insensitive, may appear anywhere in the
  arguments) - the explicit opt-out; or
- stdin is redirected (piped/automated callers that can never press Enter).

Automated callers all use the flag: the bootstrap's smoke test and isolation
test, and run.ps1 (which supplies its own window pause, so the launcher window
still takes exactly one keypress to close).

## Why C# 5 / .NET Framework?

Windows PowerShell 5.1 runs on .NET Framework 4.x, and every machine that has
PowerShell 5.1 also ships the matching in-box C# compiler (`csc.exe`), which
supports language versions up to C# 5. Targeting C# 5 means this project builds
on ANY PowerShell 5.1 machine - no Visual Studio, no SDK, no internet needed.

## 64-bit, self-contained

- Compiled with `/platform:x64`: the exe is a genuine 64-bit image (PE32+,
  AMD64 machine type, verified by the bootstrap by parsing the PE header) and
  requires 64-bit Windows. The bootstrap refuses to run on 32-bit Windows.
- "Self-contained" here means: the exe needs NOTHING beside it - no DLLs, no
  config, no satellite files. The bootstrap proves this by copying the exe
  ALONE into a bare temp folder and running it (isolation test); if it needed
  any companion file, that would surface as a build error.
- Its only runtime requirement is the .NET Framework 4.x CLR, which is an
  inbox component of Windows 10/11 (4.8 ships with the OS) - an OS component,
  not a file dependency.
- Honest limitation: .NET Framework assemblies cannot be statically linked
  into one file. Under this project's constraints (Windows PowerShell 5.1,
  in-box csc.exe, no SDK, no internet) this is the maximum self-containment
  achievable. A .NET Core "single-file self-contained" publish would require
  the .NET SDK and PowerShell 6+, both forbidden here.

## Layout

    __PROJECT__\
        run.ps1                       standalone launcher (regenerated every run)
        src\
            Program.cs               entry point (Greeter demo, standalone-safe)
            App.config               runtime configuration (optional at runtime)
            Properties\
                AssemblyInfo.cs      assembly metadata
        build\
            bin\                     compiled 64-bit exe / pdb / exe.config
            logs\                    bootstrap.log, run.log, run-transcript.txt
        docs\                        this file
        tests\                       placeholder for future tests

## Rebuild (from anywhere)

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1

    The bootstrap spawns run.ps1 in a new window at the end (add -NoLaunch to
    suppress that) but never runs the program itself.

## Launch separately (anytime)

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 [name]
    build\bin\__PROJECT__.exe [name]              (stays open until Enter)
    build\bin\__PROJECT__.exe --no-pause          (exits immediately)
'@
 $ReadmeMd = $ReadmeTemplate.Replace('__PROJECT__', $ProjectName)

 $TestsReadme = @'
# Tests (placeholder)

No test framework ships with this minimal scaffold on purpose. Add xUnit/NUnit
projects here later; the bootstrap can be extended to build and run them.
'@

 $Gitignore = @'
# Regenerated on every bootstrap run - never commit these
build/bin/
build/logs/

# IDE cruft
.vs/
*.user
*.suo
obj/
bin/
'@

#--- write all project files (run.ps1 included -- it is a scaffolded project file) ----
Write-Log 'writing project files' 'INFO'
Write-ProjectFile -RelativePath 'run.ps1'                      -Content $RunPs1
Write-ProjectFile -RelativePath 'src\Program.cs'               -Content $ProgramCs
Write-ProjectFile -RelativePath 'src\Properties\AssemblyInfo.cs' -Content $AssemblyInfoCs
Write-ProjectFile -RelativePath 'src\App.config'               -Content $AppConfig
Write-ProjectFile -RelativePath 'docs\README.md'               -Content $ReadmeMd
Write-ProjectFile -RelativePath 'tests\README.md'              -Content $TestsReadme
Write-ProjectFile -RelativePath '.gitignore'                   -Content $Gitignore

#--- locate the in-box C# compiler -------------------------------------------------------
Write-Log 'locating the in-box .NET Framework C# compiler (csc.exe)' 'DEBUG'
 $CscPath = $null
 $CscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
foreach ($candidate in $CscCandidates) {
    Write-Log ("  probing {0}" -f $candidate) 'DEBUG'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $CscPath = $candidate
        break
    }
}
if (-not $CscPath) {
    Stop-Bootstrap 'csc.exe not found under \Microsoft.NET\Framework(64)\v4.0.30319 - is .NET Framework 4.x installed?'
}
 $CompilerFileVersion = (Get-Item -LiteralPath $CscPath).VersionInfo.FileVersion
Write-Log ("compiler found : {0} (file version {1})" -f $CscPath, $CompilerFileVersion)
Write-Log '  note: the compiler process bitness does NOT decide the output bitness - /platform:x64 does' 'DEBUG'

#--- compile (64-bit self-contained target) ----------------------------------------------
 $OutExe  = Join-Path $BinDir ($ProjectName + '.exe')
 $OutPdb  = Join-Path $BinDir ($ProjectName + '.pdb')
 $OutCfg  = Join-Path $BinDir ($ProjectName + '.exe.config')
 $Sources = @(
    (Join-Path $SrcDir   'Program.cs'),
    (Join-Path $PropsDir 'AssemblyInfo.cs')
)
 $CscArgs = @(
    '/nologo',
    '/target:exe',
    '/platform:x64',      # force a genuine 64-bit (PE32+/AMD64) image - refuses to run on 32-bit Windows
    ('/out:' + $OutExe),
    '/debug:full',        # full debug info -> .pdb beside the exe (pdb is optional at runtime)
    '/optimize-',         # optimization off while iterating (flip for release)
    '/warn:4',
    '/warnaserror-',
    '/define:DEBUG;TRACE'
)
 $AllArgs = $CscArgs + $Sources

Write-Log 'compiling project with csc.exe (64-bit target)' 'INFO'
Write-Log ("  command line: csc.exe {0}" -f ($AllArgs -join ' ')) 'DEBUG'

 $CompilerOutput = $null
 $CompilerExit   = $null
try {
    # NOTE: $ErrorActionPreference stays 'Continue' for native calls so a redirected
    # stderr line can never become a terminating NativeCommandError (PS 5.1 quirk).
    $CompilerOutput = & $CscPath @AllArgs 2>&1
    $CompilerExit   = $LASTEXITCODE
}
catch {
    $CompilerOutput = @($_)
    $CompilerExit   = -1
}
if ($CompilerOutput) {
    foreach ($line in @($CompilerOutput)) { Write-Log ("  csc| {0}" -f $line) 'DEBUG' }
}
if ($CompilerExit -ne 0) {
    foreach ($line in @($CompilerOutput)) { Write-Log ("  csc| {0}" -f $line) 'ERROR' }
    Stop-Bootstrap ("compilation failed, csc.exe exited with code {0}" -f $CompilerExit)
}
Write-Log ("compilation succeeded -> {0}" -f $OutExe) 'INFO'

#--- VERIFY 64-BIT PE HEADER (fatal if not a genuine AMD64 / PE32+ image) ---------------
# Read raw bytes with the .NET API on purpose: Get-Content -AsByteStream is
# PowerShell 6/7-only and therefore forbidden here.
Invoke-Step -Name 'verify 64-bit PE header (AMD64 / PE32+)' -Fatal -Action {
    $bytes = [System.IO.File]::ReadAllBytes($OutExe)
    if ($bytes.Length -lt 256) { throw 'exe is too small to contain a valid PE header' }
    if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'missing MZ DOS signature (not a Windows PE executable)' }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or (($peOffset + 26) -ge $bytes.Length)) { throw ('invalid e_lfanew PE offset: {0}' -f $peOffset) }
    if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45) { throw 'missing PE signature at the e_lfanew offset' }
    $machine   = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    $optMagic  = [BitConverter]::ToUInt16($bytes, $peOffset + 24)
    $machineHex   = '0x{0:X4}' -f $machine
    $optMagicHex  = '0x{0:X4}' -f $optMagic
    Write-Log ("  PE machine type       : {0}" -f $machineHex) 'DEBUG'
    Write-Log ("  optional header magic : {0}" -f $optMagicHex) 'DEBUG'
    if ($machine -ne 0x8664) {
        throw ('PE machine type {0} is not AMD64 (0x8664) - the compiler did not honor /platform:x64' -f $machineHex)
    }
    if ($optMagic -ne 0x20B) {
        throw ('optional header magic {0} is not PE32+ (0x20B) - the image is not a 64-bit layout' -f $optMagicHex)
    }
    $script:PeVerified = $true
    Write-Log '  exe CONFIRMED as a genuine 64-bit binary (AMD64 machine type, PE32+ header)' 'INFO'
}

#--- stage the runtime config beside the exe (optional at runtime; csc does not copy it) -
Invoke-Step -Name 'stage runtime config beside the exe' -Fatal -Action {
    Copy-Item -LiteralPath (Join-Path $SrcDir 'App.config') -Destination $OutCfg -Force -ErrorAction Stop
    Write-Log ("  + file   : {0}  (optional at runtime - the isolation test proves the exe runs without it)" -f $OutCfg) 'DEBUG'
}

#--- verify build artifacts ------------------------------------------------------------------
# NOTE: only the .exe is a runtime requirement. The .pdb and .exe.config are
# conveniences; the isolation test below proves the exe needs neither.
 $missing = 0
foreach ($artifact in @($OutExe, $OutPdb, $OutCfg)) {
    if (Test-Path -LiteralPath $artifact -PathType Leaf) {
        $size = (Get-Item -LiteralPath $artifact).Length
        Write-Log ("  artifact OK     : {0}  ({1} bytes)" -f $artifact, $size) 'DEBUG'
    }
    else {
        $missing++
        Write-Log ("  artifact MISSING: {0}" -f $artifact) 'ERROR'
    }
}
if ($missing -gt 0) { Stop-Bootstrap 'build artifacts are missing - cannot smoke test' }

#--- smoke test the executable (build verification ONLY -- this is not the launch) ------------
# --no-pause is REQUIRED here: the exe's stdin is this console (not redirected),
# so redirect detection alone cannot tell the exe that this is an automated run.
Write-Log ("smoke-testing the executable: {0} --no-pause" -f $OutExe) 'INFO'
 $RunOutput = $null
 $RunExit   = $null
try {
    $RunOutput = & $OutExe '--no-pause' 2>&1
    $RunExit   = $LASTEXITCODE
}
catch {
    $RunOutput = @($_)
    $RunExit   = -1
}
 $BitnessConfirmed = $false
if ($RunOutput) {
    foreach ($line in @($RunOutput)) {
        Write-Log ("  exe| {0}" -f $line) 'INFO'
        if (-not $BitnessConfirmed -and (("{0}" -f $line) -match '64-bit proc\s*:\s*True')) {
            $BitnessConfirmed = $true
        }
    }
}
if ($BitnessConfirmed) {
    Write-Log '  exe self-reported running as a 64-bit process' 'DEBUG'
}
else {
    Write-Log '  could not confirm 64-bit execution from exe output (the PE header check is authoritative)' 'WARN'
}
if ($RunExit -eq 0) {
    Write-Log 'smoke test PASSED (exit code 0)' 'INFO'
}
else {
    $script:Failures++
    Write-Log ("smoke test FAILED (exit code {0})" -f $RunExit) 'ERROR'
}

#--- SELF-CONTAINMENT ISOLATION TEST: run the exe ALONE from a bare temp folder -------------
Write-Log 'self-containment test: running the exe ALONE from a bare temporary folder' 'INFO'
 $IsoDir = Join-Path ([System.IO.Path]::GetTempPath()) ('{0}_SelfContainedTest_{1}' -f $ProjectName, [Guid]::NewGuid().ToString('N'))
 $IsoExe = Join-Path $IsoDir ($ProjectName + '.exe')
Invoke-Step -Name 'self-containment isolation test' -Action {
    New-Item -ItemType Directory -Path $IsoDir -Force -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $OutExe -Destination $IsoExe -Force -ErrorAction Stop
    $isoFileCount = @(Get-ChildItem -LiteralPath $IsoDir -Force).Count
    Write-Log ("  isolated folder contains exactly {0} file(s) - the exe and nothing else" -f $isoFileCount) 'DEBUG'
    $isoOutput = $null
    $isoExit   = $null
    try {
        # --no-pause again: automated run, must not wait for a keypress.
        $isoOutput = & $IsoExe '--no-pause' 2>&1
        $isoExit   = $LASTEXITCODE
    }
    catch {
        $isoOutput = @($_)
        $isoExit   = -1
    }
    if ($isoOutput) {
        foreach ($line in @($isoOutput)) { Write-Log ("  iso| {0}" -f $line) 'DEBUG' }
    }
    if ($isoExit -ne 0) {
        throw ('exe failed when launched with NO other files present (exit code {0}) - it has hidden outside file dependencies' -f $isoExit)
    }
    $script:SelfContainedVerified = $true
    Write-Log '  isolation test PASSED - the exe runs standalone; nothing is required beside it' 'INFO'
}
if (Test-Path -LiteralPath $IsoDir) {
    try {
        Remove-Item -LiteralPath $IsoDir -Recurse -Force -ErrorAction Stop
        Write-Log '  isolation test folder removed' 'DEBUG'
    }
    catch {
        Write-Log ("  isolation test folder could not be removed: {0}" -f $_.Exception.Message) 'WARN'
    }
}

#--- surface anything PowerShell itself recorded during this console session --------------------
if (@($Error).Count -gt 0) {
    Write-Log ("PowerShell recorded {0} error record(s) this session (newest first):" -f @($Error).Count) 'WARN'
    $recent = @($Error)
    if ($recent.Count -gt 5) { $recent = @($recent[0..4]) }
    foreach ($errRecord in $recent) { Write-Log ("  err -> {0}" -f $errRecord) 'WARN' }
}

#--- show the final tree -------------------------------------------------------------------------
Write-Log 'final project tree (relative to project root)' 'INFO'
 $Everything = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -Force)
foreach ($item in $Everything) {
    $rel = $item.FullName.Substring($ProjectRoot.Length + 1)
    if ($item.PSIsContainer) {
        Write-Log ("  [dir ] {0}" -f $rel) 'DEBUG'
    }
    else {
        Write-Log ("  [file] {0}  ({1} bytes)" -f $rel, $item.Length) 'DEBUG'
    }
}
 $FolderCount = @($Everything | Where-Object { $_.PSIsContainer }).Count
 $FileCount   = @($Everything | Where-Object { -not $_.PSIsContainer }).Count
Write-Log ("project contains {0} folders and {1} files (including build outputs)" -f $FolderCount, $FileCount) 'INFO'

#--- summary -------------------------------------------------------------------------
 $Elapsed = (Get-Date) - $script:StartedAt
Write-Host ''
Write-Host ('=' * 80) -ForegroundColor DarkCyan
if ($script:Failures -eq 0) {
    Write-Host ('  BOOTSTRAP COMPLETED SUCCESSFULLY  |  {0:n1} seconds' -f $Elapsed.TotalSeconds) -ForegroundColor Green
}
else {
    Write-Host ('  BOOTSTRAP FINISHED WITH {0} ERROR(S)  |  {1:n1} seconds' -f $script:Failures, $Elapsed.TotalSeconds) -ForegroundColor Yellow
}
Write-Host ('  Project root : {0}' -f $ProjectRoot)
Write-Host ('  Executable   : {0}' -f $OutExe)
if ($script:PeVerified) {
    Write-Host '  64-bit       : VERIFIED (AMD64 machine type, PE32+ header)' -ForegroundColor Green
}
else {
    Write-Host '  64-bit       : NOT verified' -ForegroundColor Red
}
if ($script:SelfContainedVerified) {
    Write-Host '  Self-contained : VERIFIED (exe runs alone, zero files beside it)' -ForegroundColor Green
}
else {
    Write-Host '  Self-contained : NOT verified' -ForegroundColor Red
}
Write-Host '  Standalone    : double-click stays open until Enter (exe flag --no-pause opts out)'
Write-Host ('  Launcher     : {0}   (separate script -- runs OUTSIDE this one)' -f $RunScript)
Write-Host ('  Build log    : {0}' -f $script:LogPath)
Write-Host ('  Launcher log : {0}' -f (Join-Path $LogDir 'run.log'))
Write-Host ('=' * 80) -ForegroundColor DarkCyan

#--- AUTO-LAUNCH (EXTERNAL): spawn run.ps1 in its own NEW PS 5.1 window ---------------
# This script does NOT run the program. It only starts a separate launcher
# process/window; run.ps1 does the actual launching and logging.
if ($NoLaunch) {
    Write-Log 'external launcher spawn skipped (-NoLaunch was supplied)' 'WARN'
}
elseif (-not (Test-Path -LiteralPath $RunScript -PathType Leaf)) {
    $script:Failures++
    Write-Log ("launcher script missing, cannot spawn: {0}" -f $RunScript) 'ERROR'
}
else {
    # Prefer the exact engine this bootstrap is running under (guaranteed PS 5.x).
    $PowerShellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
        Write-Log 'powershell.exe not found in $PSHOME -- falling back to PATH lookup' 'WARN'
        $PowerShellExe = 'powershell.exe'
    }
    $SpawnArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $RunScript)
    )
    Write-Log ("spawning external launcher (new window, NOT waited on): {0} {1}" -f $PowerShellExe, ($SpawnArgs -join ' ')) 'INFO'
    try {
        # No -Wait on purpose: the app window is fully independent of this
        # build window; run.ps1 pauses itself and logs its own run.log.
        Start-Process -FilePath $PowerShellExe -ArgumentList $SpawnArgs -WorkingDirectory $ProjectRoot -ErrorAction Stop | Out-Null
        Write-Log 'external launcher window started -- the program now runs OUTSIDE this build script' 'INFO'
    }
    catch {
        $script:Failures++
        Write-Log ("failed to spawn external launcher: {0}" -f $_.Exception.Message) 'ERROR'
        Write-Log 'you can still launch manually: powershell.exe -NoProfile -ExecutionPolicy Bypass -File run.ps1' 'WARN'
    }
}

#--- keep the build window open ---------------------------------------------------------------
Write-Host ''
Write-Host '  This window is intentionally NOT closed. Inspect the output above,' -ForegroundColor Cyan
Write-Host '  then press Enter to hand control back to the console.' -ForegroundColor Cyan
 $null = Read-Host '  Press Enter to finish'
