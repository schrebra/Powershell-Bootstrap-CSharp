param([string]$ProjectName='WinFormsShowcase',[ValidateSet('Auto','WinForms')][string]$ProjectType='WinForms',[string]$BaseDir='',[switch]$NoLaunch,[int]$MaxRetries=3)
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
function Write-SourceFiles([string]$Dir,[string]$Name){
 $projWf=@'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>WinExe</OutputType><TargetFramework>net8.0-windows</TargetFramework><Nullable>disable</Nullable><ImplicitUsings>enable</ImplicitUsings><UseWindowsForms>true</UseWindowsForms><SelfContained>true</SelfContained><RuntimeIdentifier>win-x64</RuntimeIdentifier><PublishSingleFile>true</PublishSingleFile><IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract><EnableCompressionInSingleFile>true</EnableCompressionInSingleFile><DebugType>embedded</DebugType><RootNamespace>__APPNAME__</RootNamespace><AssemblyName>__APPNAME__</AssemblyName><SatelliteResourceLanguages>en</SatelliteResourceLanguages></PropertyGroup></Project>
'@
 $progCs=@'
using System;
using System.Windows.Forms;
namespace __APPNAME__
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false); Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            Application.ThreadException += (s, e) => { try { MessageBox.Show("Unexpected error:\r\n\r\n" + e.Exception.Message + "\r\n\r\n" + e.Exception.StackTrace, "__APPNAME__", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { } };
            AppDomain.CurrentDomain.UnhandledException += (s, e) => { try { MessageBox.Show("Fatal error:\r\n\r\n" + ((Exception)e.ExceptionObject).Message, "__APPNAME__", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { } };
            try { Application.Run(new MainForm()); }
            catch (Exception ex) { try { MessageBox.Show("Startup failure - the window could not be created:\r\n\r\n" + ex.ToString(), "__APPNAME__", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { } Environment.ExitCode = 1; }
        }
    }
}
'@
 $mainCs=@'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Data;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Printing;
using System.IO;
using System.Media;
using System.Threading;
using System.Windows.Forms;
namespace __APPNAME__
{
    public class Person
    {
        public Person(string n, int a, string c){ Name = n; Age = a; City = c; }
        [Category("Identity"), Description("Display name")] public string Name { get; set; }
        [Category("Vitals"), Description("Age in years")] public int Age { get; set; }
        [Category("Identity"), Description("Home city")] public string City { get; set; }
        [Browsable(false)] public string Secret { get; set; }
    }
    public class LabeledSlider : UserControl
    {
        private Label lbl; private TrackBar bar;
        public event EventHandler SliderMoved;
        public LabeledSlider(string title, int min, int max, int val)
        {
            lbl = new Label { Text = title + ": " + val, Dock = DockStyle.Top, AutoSize = true };
            bar = new TrackBar { Dock = DockStyle.Fill, Minimum = min, Maximum = max, Value = val, TickFrequency = (max - min) / 4 };
            bar.ValueChanged += (s, e) => { lbl.Text = title + ": " + bar.Value; if (SliderMoved != null) SliderMoved(this, EventArgs.Empty); };
            Controls.Add(bar); Controls.Add(lbl); Size = new Size(210, 70);
        }
        public int Value { get { return bar.Value; } }
    }
    public class AboutBox : Form
    {
        public AboutBox()
        {
            Text = "About WinForms Control Showcase"; FormBorderStyle = FormBorderStyle.FixedDialog; StartPosition = FormStartPosition.CenterParent; MinimizeBox = false; MaximizeBox = false; ShowInTaskbar = false; ClientSize = new Size(400, 190);
            Label t = new Label { Text = "WinForms Control Showcase", Font = new Font("Segoe UI", 14F, FontStyle.Bold), AutoSize = true, Location = new Point(20, 18) };
            Label d = new Label { Text = "One window. Every control. Zero designers.\r\nBuilt with .NET 8 and System.Windows.Forms.", AutoSize = true, Location = new Point(22, 60) };
            Button ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Location = new Point(300, 150), Size = new Size(80, 28) };
            Controls.Add(t); Controls.Add(d); Controls.Add(ok); AcceptButton = ok; CancelButton = ok;
        }
    }
    [System.Runtime.InteropServices.ComVisible(true)]
    public class WebBridge
    {
        private readonly Action<string> _report;
        public WebBridge(Action<string> report) { _report = report; }
        public void Report(string message) { Action<string> r = _report; if (r != null) { try { r(message); } catch { } } }
    }
    public class DoubleBufferPanel : Panel
    {
        public DoubleBufferPanel() { DoubleBuffered = true; }
    }
    public class PaintCanvas : Panel
    {
        private Color c1, c2; private Random r = new Random();
        private float ang; private int ballX = 40, ballY = 40, dx = 4, dy = 3;
        private System.Windows.Forms.Timer anim = new System.Windows.Forms.Timer { Interval = 30 };
        public bool AnimationOn { get { return anim.Enabled; } set { anim.Enabled = value; } }
        public PaintCanvas()
        {
            DoubleBuffered = true; ResizeRedraw = true; c1 = Color.MidnightBlue; c2 = Color.LightSkyBlue;
            anim.Tick += (s, e) =>
            {
                ballX += dx; ballY += dy;
                if (ballX < 10 || ballX > Math.Max(11, Width - 10)) { dx = -dx; }
                if (ballY < 10 || ballY > Math.Max(11, Height - 10)) { dy = -dy; }
                Invalidate();
            };
            Disposed += (s, e) => { anim.Stop(); anim.Dispose(); };
        }
        public void Randomize() { c1 = Color.FromArgb(r.Next(256), r.Next(256), r.Next(256)); c2 = Color.FromArgb(r.Next(256), r.Next(256), r.Next(256)); }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            Rectangle rc = ClientRectangle;
            if (rc.Width < 4 || rc.Height < 4) { return; }
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (LinearGradientBrush lg = new LinearGradientBrush(rc, c1, c2, LinearGradientMode.ForwardDiagonal)) { g.FillRectangle(lg, rc); }
            using (HatchBrush hb = new HatchBrush(HatchStyle.WideUpwardDiagonal, Color.FromArgb(140, Color.White), Color.Transparent)) { g.FillEllipse(hb, rc.Width / 8, rc.Height / 8, rc.Width / 4, rc.Height / 4); }
            using (Pen dash = new Pen(Color.White, 2F)) { dash.DashStyle = DashStyle.Dash; g.DrawBezier(dash, 10, rc.Height - 20, rc.Width / 3, 10, (2 * rc.Width) / 3, rc.Height - 40, rc.Width - 10, 20); }
            using (Pen arc = new Pen(Color.Gold, 4F)) { g.DrawArc(arc, rc.Width / 2 - 60, rc.Height / 2 - 60, 120, 120, ang, 300F); }
            ang = (ang + 5F) % 360F;
            g.TranslateTransform(rc.Width - 110, rc.Height - 46); g.RotateTransform(-25F);
            using (Font f = new Font("Segoe UI", 11F, FontStyle.Bold)) { g.DrawString("Rotated text", f, Brushes.White, 0, 0); }
            g.ResetTransform();
            using (SolidBrush bb = new SolidBrush(Color.OrangeRed)) { g.FillEllipse(bb, ballX - 8, ballY - 8, 16, 16); }
            g.DrawEllipse(Pens.Black, ballX - 8, ballY - 8, 16, 16);
        }
    }
    public class MdiPlayground : Form
    {
        private int childCount = 0;
        private ToolStripStatusLabel info;
        private Color[] palette = new Color[] { Color.FromArgb(222, 231, 247), Color.FromArgb(229, 245, 231), Color.FromArgb(252, 241, 212), Color.FromArgb(246, 222, 236) };
        public MdiPlayground()
        {
            Text = "MDI Playground - Form.IsMdiContainer"; IsMdiContainer = true;
            StartPosition = FormStartPosition.CenterParent; ClientSize = new Size(760, 480); MinimumSize = new Size(480, 320);
            MenuStrip mm = new MenuStrip();
            ToolStripMenuItem miNew = new ToolStripMenuItem("&New child", null, (s, e) => NewChild());
            miNew.ShortcutKeys = Keys.Control | Keys.N;
            ToolStripMenuItem miCloseAll = new ToolStripMenuItem("Close &all children", null, (s, e) => { Form[] kids = MdiChildren; foreach (Form f in kids) { f.Close(); } });
            ToolStripMenuItem fileM = new ToolStripMenuItem("&File");
            fileM.DropDownItems.AddRange(new ToolStripItem[] { miNew, new ToolStripSeparator(), miCloseAll, new ToolStripSeparator(), new ToolStripMenuItem("E&xit", null, (s, e) => Close()) });
            ToolStripMenuItem winM = new ToolStripMenuItem("&Window");
            winM.DropDownItems.Add(new ToolStripMenuItem("Cascade", null, (s, e) => LayoutMdi(MdiLayout.Cascade)));
            winM.DropDownItems.Add(new ToolStripMenuItem("Tile Horizontal", null, (s, e) => LayoutMdi(MdiLayout.TileHorizontal)));
            winM.DropDownItems.Add(new ToolStripMenuItem("Tile Vertical", null, (s, e) => LayoutMdi(MdiLayout.TileVertical)));
            winM.DropDownItems.Add(new ToolStripMenuItem("Arrange Icons", null, (s, e) => LayoutMdi(MdiLayout.ArrangeIcons)));
            winM.DropDownOpening += (s, e) =>
            {
                winM.DropDownItems.Clear();
                winM.DropDownItems.Add(new ToolStripMenuItem("Cascade", null, (s2, e2) => LayoutMdi(MdiLayout.Cascade)));
                winM.DropDownItems.Add(new ToolStripMenuItem("Tile Horizontal", null, (s2, e2) => LayoutMdi(MdiLayout.TileHorizontal)));
                winM.DropDownItems.Add(new ToolStripMenuItem("Tile Vertical", null, (s2, e2) => LayoutMdi(MdiLayout.TileVertical)));
                winM.DropDownItems.Add(new ToolStripMenuItem("Arrange Icons", null, (s2, e2) => LayoutMdi(MdiLayout.ArrangeIcons)));
                if (MdiChildren.Length > 0)
                {
                    winM.DropDownItems.Add(new ToolStripSeparator());
                    foreach (Form f in MdiChildren)
                    {
                        Form ff = f;
                        winM.DropDownItems.Add(new ToolStripMenuItem(ff.Text, null, (s2, e2) => ff.Activate()) { Checked = (ff == ActiveMdiChild) });
                    }
                }
            };
            mm.Items.AddRange(new ToolStripItem[] { fileM, winM });
            MainMenuStrip = mm;
            StatusStrip st = new StatusStrip();
            info = new ToolStripStatusLabel { Spring = true, Text = "Use File > New child (Ctrl+N) to spawn MDI children, then arrange them via the Window menu." };
            st.Items.Add(info);
            Controls.Add(st); Controls.Add(mm);
            MdiChildActivate += (s, e) => UpdateInfo();
            Shown += (s, e) => { if (MdiChildren.Length == 0) { NewChild(); NewChild(); } };
        }
        private void NewChild()
        {
            childCount++;
            Form c = new Form { Text = "Child " + childCount, MdiParent = this, ClientSize = new Size(260, 170), BackColor = palette[childCount % palette.Length] };
            c.Controls.Add(new Label { Text = "Child #" + childCount + "\r\nMdiParent = playground\r\n\r\nDrag, minimize, maximize me -\r\nthen try Window > Tile Vertical.", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter });
            c.FormClosed += (s, e) => UpdateInfo();
            c.Show();
            UpdateInfo();
        }
        private void UpdateInfo() { if (info != null) { info.Text = "MDI children open: " + MdiChildren.Length + "   (open the Window menu - children are listed with the active one check-marked)"; } }
    }
    public class MainForm : Form
    {
        private TabControl tabs; private MenuStrip menu; private ToolStrip toolbar; private StatusStrip status;
        private ToolStripStatusLabel stLeft; private ToolStripStatusLabel stClock; private ToolStripProgressBar stProg;
        private System.Windows.Forms.Timer clock; private NotifyIcon tray; private ToolTip tips; private ErrorProvider err; private HelpProvider hp;
        private ImageList icons; private BackgroundWorker worker; private ProgressBar workerBar; private ProgressBar demoProg;
        private Button workerBtn; private Button cancelBtn; private Label workerState; private Random rng; private int ticks;
        public MainForm()
        {
            rng = new Random(); clock = new System.Windows.Forms.Timer { Interval = 1000 }; ticks = 0;
            Text = "WinForms Control Showcase - Every Control, One Window";
            Font = new Font("Segoe UI", 9F); StartPosition = FormStartPosition.CenterScreen; ClientSize = new Size(1180, 780); MinimumSize = new Size(960, 640);
            Icon = SystemIcons.Application; KeyPreview = true;
            tips = new ToolTip { AutoPopDelay = 8000, InitialDelay = 400, ReshowDelay = 150 }; err = new ErrorProvider(); hp = new HelpProvider();
            BuildIcons(); BuildTabs(); BuildStatus(); BuildToolbar(); BuildMenu();
            clock.Tick += (s, e) => { ticks++; stClock.Text = "Clock: " + DateTime.Now.ToLongTimeString(); };
            clock.Start();
            BuildTray(); BuildWorker();
            SetStatus("Ready - 13 tabs, 80+ controls. Hover for ToolTips, press F1 for HelpProvider, right-click things.");
        }
        private void SetStatus(string m){ if (stLeft != null) stLeft.Text = m; }
        private void BuildIcons()
        {
            icons = new ImageList { ImageSize = new Size(16, 16), ColorDepth = ColorDepth.Depth32Bit };
            Color[] cols = new Color[] { Color.Firebrick, Color.SeaGreen, Color.RoyalBlue, Color.DarkOrange, Color.MediumPurple, Color.Teal };
            for (int i = 0; i < cols.Length; i++)
            {
                Bitmap b = new Bitmap(16, 16);
                using (Graphics g = Graphics.FromImage(b))
                {
                    using (SolidBrush br = new SolidBrush(cols[i])) { g.FillEllipse(br, 1, 1, 13, 13); }
                    g.DrawEllipse(Pens.Black, 1, 1, 13, 13);
                }
                icons.Images.Add(b);
            }
        }
        private void BuildTabs()
        {
            tabs = new TabControl { Dock = DockStyle.Fill };
            tabs.TabPages.Add(TabBasics()); tabs.TabPages.Add(TabSelection()); tabs.TabPages.Add(TabDateTime()); tabs.TabPages.Add(TabContainers()); tabs.TabPages.Add(TabData()); tabs.TabPages.Add(TabMenus()); tabs.TabPages.Add(TabDialogs()); tabs.TabPages.Add(TabBackground()); tabs.TabPages.Add(TabGraphics());
            tabs.TabPages.Add(TabWebMedia()); tabs.TabPages.Add(TabLayoutScroll()); tabs.TabPages.Add(TabComponents()); tabs.TabPages.Add(TabGridMdi());
            tabs.SelectedIndexChanged += (s, e) => { if (tabs.SelectedTab != null) SetStatus("Tab: " + tabs.SelectedTab.Text); };
            Controls.Add(tabs);
        }
        private void BuildStatus()
        {
            status = new StatusStrip { SizingGrip = true };
            stLeft = new ToolStripStatusLabel { Spring = true, TextAlign = ContentAlignment.MiddleLeft, Text = "Starting..." };
            stClock = new ToolStripStatusLabel("Clock: --:--:--") { BorderSides = ToolStripStatusLabelBorderSides.All };
            stProg = new ToolStripProgressBar();
            status.Items.Add(stLeft); status.Items.Add(new ToolStripStatusLabel("  ")); status.Items.Add(stProg); status.Items.Add(stClock);
            Controls.Add(status);
        }
        private void BuildToolbar()
        {
            toolbar = new ToolStrip { GripStyle = ToolStripGripStyle.Visible };
            ToolStripButton b1 = new ToolStripButton("New", SystemIcons.Application.ToBitmap(), (s, e) => SetStatus("Toolbar: New"));
            ToolStripButton b2 = new ToolStripButton("Open", SystemIcons.Information.ToBitmap(), (s, e) => ShowOpenDialog());
            ToolStripButton b3 = new ToolStripButton("Save", SystemIcons.Shield.ToBitmap(), (s, e) => ShowSaveDialog());
            foreach (ToolStripButton b in new ToolStripButton[] { b1, b2, b3 }) { b.DisplayStyle = ToolStripItemDisplayStyle.ImageAndText; }
            ToolStripLabel tl = new ToolStripLabel("Find:");
            ToolStripTextBox tst = new ToolStripTextBox { ToolTipText = "ToolStripTextBox - type and press Enter" };
            tst.KeyPress += (s, e) => { if (e.KeyChar == (char)13) { SetStatus("Toolbar search: " + tst.Text); e.Handled = true; } };
            ToolStripComboBox tcm = new ToolStripComboBox { DropDownStyle = ComboBoxStyle.DropDownList, DropDownWidth = 160 };
            tcm.Items.AddRange(new object[] { "Red", "Green", "Blue" });
            tcm.SelectedIndexChanged += (s, e) => SetStatus("Toolbar combo: " + tcm.Text);
            ToolStripDropDownButton dd = new ToolStripDropDownButton("Actions");
            dd.DropDownItems.Add(new ToolStripMenuItem("Refresh", null, (s, e) => SetStatus("Action: Refresh")));
            dd.DropDownItems.Add(new ToolStripMenuItem("Rebuild", null, (s, e) => SetStatus("Action: Rebuild")));
            ToolStripSplitButton sp = new ToolStripSplitButton("Split");
            sp.ButtonClick += (s, e) => SetStatus("SplitButton main area");
            sp.DropDownItems.Add(new ToolStripMenuItem("Option A", null, (s, e) => SetStatus("SplitButton: Option A")));
            ToolStripProgressBar tp = new ToolStripProgressBar { Value = 40 };
            ToolStripButton mq = new ToolStripButton("Toggle marquee", null, (s, e) => { if (demoProg == null) { SetStatus("Open tab 8 first - the marquee lives there"); return; } if (demoProg.Style == ProgressBarStyle.Marquee) { demoProg.Style = ProgressBarStyle.Blocks; demoProg.Value = 60; } else { demoProg.Value = 0; demoProg.Style = ProgressBarStyle.Marquee; demoProg.MarqueeAnimationSpeed = 30; } SetStatus("ProgressBar style: " + demoProg.Style); });
            toolbar.Items.AddRange(new ToolStripItem[] { b1, b2, b3, new ToolStripSeparator(), tl, tst, tcm, new ToolStripSeparator(), dd, sp, new ToolStripSeparator(), tp, mq });
            Controls.Add(toolbar);
        }
        private void BuildMenu()
        {
            menu = new MenuStrip();
            ToolStripMenuItem miNew = new ToolStripMenuItem("&New", null, (s, e) => { SetStatus("File > New"); MessageBox.Show(this, "A brand new document was created (fictionally).", "File > New", MessageBoxButtons.OK, MessageBoxIcon.Information); });
            miNew.ShortcutKeys = Keys.Control | Keys.N;
            ToolStripMenuItem miOpen = new ToolStripMenuItem("&Open...", null, (s, e) => ShowOpenDialog());
            miOpen.ShortcutKeys = Keys.Control | Keys.O;
            ToolStripMenuItem miSave = new ToolStripMenuItem("Save &As...", null, (s, e) => ShowSaveDialog());
            miSave.ShortcutKeys = Keys.Control | Keys.S;
            ToolStripMenuItem miExit = new ToolStripMenuItem("E&xit", null, (s, e) => Close());
            miExit.ShortcutKeys = Keys.Alt | Keys.F4;
            ToolStripMenuItem file = new ToolStripMenuItem("&File");
            file.DropDownItems.AddRange(new ToolStripItem[] { miNew, miOpen, miSave, new ToolStripSeparator(), miExit });
            ToolStripMenuItem view = new ToolStripMenuItem("&View");
            for (int i = 0; i < tabs.TabPages.Count; i++)
            {
                int idx = i;
                view.DropDownItems.Add(new ToolStripMenuItem("Go to tab " + (i + 1) + ": " + tabs.TabPages[i].Text, null, (s, e) => { tabs.SelectedIndex = idx; SetStatus("View menu jumped to: " + tabs.TabPages[idx].Text); }));
            }
            ToolStripMenuItem help = new ToolStripMenuItem("&Help");
            help.DropDownItems.Add(new ToolStripMenuItem("&About...", null, (s, e) => ShowAbout()));
            menu.Items.AddRange(new ToolStripItem[] { file, view, help });
            MainMenuStrip = menu;
            Controls.Add(menu);
        }
        private TableLayoutPanel Grid2(){ TableLayoutPanel t = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, Padding = new Padding(8) }; t.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); return t; }
        private int AddHeader(TableLayoutPanel t, string text){ int r = t.RowCount; t.RowCount++; t.RowStyles.Add(new RowStyle(SizeType.AutoSize)); Label h = new Label { Text = text, AutoSize = true, Font = new Font("Segoe UI", 10F, FontStyle.Bold), ForeColor = Color.Navy, Margin = new Padding(2, 10, 2, 4) }; t.Controls.Add(h, 0, r); t.SetColumnSpan(h, 2); return r; }
        private int AddRow(TableLayoutPanel t, string text, Control c, string tip)
        {
            int r = t.RowCount; t.RowCount++;
            t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            Label l = new Label { Text = text, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(2, 6, 6, 2) };
            t.Controls.Add(l, 0, r);
            c.Dock = DockStyle.Fill; c.Margin = new Padding(2);
            t.Controls.Add(c, 1, r);
            if (!string.IsNullOrEmpty(tip)) { tips.SetToolTip(c, tip); tips.SetToolTip(l, tip); }
            return r;
        }
        private int AddFillRow(TableLayoutPanel t, string text, Control c, int minH, string tip){ int r = AddRow(t, text, c, tip); t.RowStyles[r] = new RowStyle(SizeType.Percent, 100); c.MinimumSize = new Size(0, minH); return r; }
        private FlowLayoutPanel Flow(params Control[] cs){ FlowLayoutPanel f = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = true, Margin = new Padding(2) }; foreach (Control c in cs) { c.Margin = new Padding(2); f.Controls.Add(c); } return f; }
        private TabPage TabBasics()
        {
            TabPage p = new TabPage("1. Basics");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "Labels, text input and buttons - the bread and butter");
            Label l1 = new Label { Text = "Plain Label", AutoSize = true };
            Label l2 = new Label { Text = "Fixed3D Label", AutoSize = true, BorderStyle = BorderStyle.Fixed3D, Padding = new Padding(3) };
            Label l3 = new Label { Text = "FixedSingle Label", AutoSize = true, BorderStyle = BorderStyle.FixedSingle, Padding = new Padding(3), BackColor = Color.LemonChiffon };
            LinkLabel link = new LinkLabel { Text = "LinkLabel - click me (nothing leaves this window)", AutoSize = true, LinkBehavior = LinkBehavior.HoverUnderline };
            link.LinkClicked += (s, e) => SetStatus("LinkLabel clicked at " + DateTime.Now.ToLongTimeString());
            AddRow(t, "Labels / LinkLabel:", Flow(l1, l2, l3, link), "Label variations and a LinkLabel");
            TextBox tb = new TextBox { PlaceholderText = "TextBox with PlaceholderText" };
            tb.TextChanged += (s, e) => SetStatus("TextBox length: " + tb.Text.Length);
            AddRow(t, "TextBox:", tb, "Single-line TextBox with placeholder text");
            Label maskState = new Label { Text = "Mask not complete", AutoSize = true, ForeColor = Color.Firebrick, Anchor = AnchorStyles.Left };
            MaskedTextBox mtb = new MaskedTextBox("(999) 000-0000") { Width = 150 };
            mtb.TextChanged += (s, e) => { bool ok = mtb.MaskCompleted; maskState.Text = ok ? "Mask complete - valid so far" : "Mask not complete"; maskState.ForeColor = ok ? Color.SeaGreen : Color.Firebrick; };
            AddRow(t, "MaskedTextBox:", Flow(mtb, maskState), "MaskedTextBox enforces input format");
            TextBox tbMulti = new TextBox { Multiline = true, ScrollBars = ScrollBars.Both, WordWrap = true, AcceptsReturn = true, Height = 60 };
            AddRow(t, "Multi-line TextBox:", tbMulti, "Multiline TextBox with scrollbars");
            RichTextBox rtb = new RichTextBox { ReadOnly = true, BackColor = Color.White, BorderStyle = BorderStyle.FixedSingle };
            rtb.Rtf = BuildRtf();
            AddFillRow(t, "RichTextBox (RTF):", rtb, 90, "RichTextBox rendering hand-written RTF");
            Button btnMsg = new Button { Text = "MessageBox gallery", AutoSize = true };
            btnMsg.Click += (s, e) => ShowMsgGallery();
            Button btnFlat = new Button { Text = "FlatStyle.Flat", FlatStyle = FlatStyle.Flat, BackColor = Color.MistyRose, AutoSize = true };
            btnFlat.Click += (s, e) => SetStatus("Flat button clicked");
            Button btnPop = new Button { Text = "Popup", FlatStyle = FlatStyle.Popup, AutoSize = true };
            btnPop.Click += (s, e) => SetStatus("Popup button clicked");
            TextBox tbDrop = new TextBox { Width = 220, AllowDrop = true, PlaceholderText = "Drag text or files onto me" };
            tbDrop.DragEnter += (s, e) => { if (e.Data.GetDataPresent(DataFormats.Text) || e.Data.GetDataPresent(DataFormats.FileDrop)) e.Effect = DragDropEffects.Copy; };
            tbDrop.DragDrop += (s, e) => { if (e.Data.GetDataPresent(DataFormats.FileDrop)) { string[] fs = (string[])e.Data.GetData(DataFormats.FileDrop); tbDrop.Text = string.Join(" | ", fs); } else { tbDrop.Text = (string)e.Data.GetData(DataFormats.Text); } SetStatus("Drop received!"); };
            AddRow(t, "Buttons / Drag-Drop:", Flow(btnMsg, btnFlat, btnPop, tbDrop), "Button styles; the TextBox accepts drag and drop of text or files");
            hp.SetHelpString(t, "Tab 1 shows Label, LinkLabel, TextBox, MaskedTextBox, RichTextBox, Button and drag & drop."); hp.SetShowHelp(t, true);
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabSelection()
        {
            TabPage p = new TabPage("2. Selection");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "Choices: check it, radio it, drop it down or slide it");
            CheckBox chk3 = new CheckBox { Text = "ThreeState", ThreeState = true, CheckState = CheckState.Indeterminate, AutoSize = true };
            chk3.CheckStateChanged += (s, e) => SetStatus("ThreeState checkbox: " + chk3.CheckState);
            CheckBox chkBtn = new CheckBox { Text = "Appearance.Button", Appearance = Appearance.Button, AutoSize = true, Width = 150, Height = 28 };
            chkBtn.CheckedChanged += (s, e) => SetStatus("Button checkbox: " + chkBtn.Checked);
            CheckBox chkAuto = new CheckBox { Text = "Checked by default", Checked = true, AutoSize = true };
            AddRow(t, "CheckBoxes:", Flow(chk3, chkBtn, chkAuto), "ThreeState, button-look and normal CheckBox");
            GroupBox grp = new GroupBox { Text = "RadioButtons (mutually exclusive)", AutoSize = true, Padding = new Padding(6) };
            FlowLayoutPanel gf = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
            RadioButton r1 = new RadioButton { Text = "Alpha", AutoSize = true, Checked = true };
            RadioButton r2 = new RadioButton { Text = "Beta", AutoSize = true };
            RadioButton r3 = new RadioButton { Text = "Gamma", AutoSize = true };
            r1.CheckedChanged += (s, e) => { if (r1.Checked) SetStatus("Radio: Alpha"); };
            r2.CheckedChanged += (s, e) => { if (r2.Checked) SetStatus("Radio: Beta"); };
            r3.CheckedChanged += (s, e) => { if (r3.Checked) SetStatus("Radio: Gamma"); };
            gf.Controls.AddRange(new Control[] { r1, r2, r3 });
            grp.Controls.Add(gf);
            AddRow(t, "RadioButton group:", grp, "RadioButtons inside a GroupBox");
            ComboBox cmb = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 200 };
            cmb.Items.AddRange(new object[] { "DropDownList style", "Fixed text entry", "No typing allowed" });
            cmb.SelectedIndexChanged += (s, e) => SetStatus("ComboBox: " + cmb.Text);
            AddRow(t, "ComboBox (list):", cmb, "DropDownList ComboBox");
            ComboBox cmbA = new ComboBox { Width = 220, AutoCompleteMode = AutoCompleteMode.SuggestAppend, AutoCompleteSource = AutoCompleteSource.ListItems };
            cmbA.Items.AddRange(new object[] { "Apple", "Apricot", "Banana", "Blueberry", "Cherry", "Cranberry", "Grape", "Kiwi", "Mango", "Peach", "Pear", "Pineapple", "Plum", "Raspberry", "Strawberry" });
            AddRow(t, "ComboBox (autocomplete):", cmbA, "Type 'ap' or 'st' to see SuggestAppend");
            ListBox lb = new ListBox { SelectionMode = SelectionMode.MultiExtended, Height = 70 };
            lb.Items.AddRange(new object[] { "Multi", "Select", "With", "Ctrl", "And", "Shift" });
            lb.SelectedIndexChanged += (s, e) => SetStatus("ListBox selected: " + lb.SelectedItems.Count + " item(s)");
            AddRow(t, "ListBox:", lb, "MultiExtended selection: Ctrl and Shift work");
            CheckedListBox clb = new CheckedListBox { Height = 70, CheckOnClick = true };
            clb.Items.AddRange(new object[] { "Eggs", "Milk", "Bread", "Coffee", "Noodles", "Sauce" });
            clb.ItemCheck += (s, e) => SetStatus("CheckedListBox will have " + (clb.CheckedItems.Count + (e.NewValue == CheckState.Checked ? 1 : -1)) + " checked");
            AddRow(t, "CheckedListBox:", clb, "ListBox with built-in checkboxes");
            DomainUpDown dud = new DomainUpDown { Width = 170 };
            foreach (string day in new string[] { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday" }) { dud.Items.Add(day); }
            dud.TextChanged += (s, e) => SetStatus("DomainUpDown: " + dud.Text);
            AddRow(t, "DomainUpDown:", dud, "Spin through a string list");
            Label nudLbl = new Label { Text = "Value: 42.5", AutoSize = true, Anchor = AnchorStyles.Left };
            NumericUpDown nud = new NumericUpDown { Minimum = 0, Maximum = 1000, Value = 42.5M, Increment = 0.5M, DecimalPlaces = 1, ThousandsSeparator = true, Width = 120 };
            nud.ValueChanged += (s, e) => nudLbl.Text = "Value: " + nud.Value;
            AddRow(t, "NumericUpDown:", Flow(nud, nudLbl), "Decimal numeric input with spinner");
            Label trkLbl = new Label { Text = "0", AutoSize = true, Anchor = AnchorStyles.Left, Width = 40 };
            TrackBar trk = new TrackBar { Minimum = 0, Maximum = 100, TickFrequency = 10, TickStyle = TickStyle.Both, Width = 260 };
            trk.ValueChanged += (s, e) => trkLbl.Text = trk.Value.ToString();
            AddRow(t, "TrackBar:", Flow(trk, trkLbl), "Slider with ticks on both sides");
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabDateTime()
        {
            TabPage p = new TabPage("3. Date & Time");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "Picking moments in time");
            DateTimePicker dtpLong = new DateTimePicker { Format = DateTimePickerFormat.Long, Width = 240 };
            dtpLong.ValueChanged += (s, e) => SetStatus("DTP long: " + dtpLong.Value.ToLongDateString());
            AddRow(t, "DateTimePicker (long):", dtpLong, "Standard drop-down calendar");
            DateTimePicker dtpCustom = new DateTimePicker { Format = DateTimePickerFormat.Custom, CustomFormat = "dddd, dd MMM yyyy  HH:mm", ShowUpDown = true, Width = 260 };
            dtpCustom.ValueChanged += (s, e) => SetStatus("DTP custom: " + dtpCustom.Value);
            AddRow(t, "DateTimePicker (custom):", dtpCustom, "CustomFormat with ShowUpDown spinner instead of calendar");
            Label calLbl = new Label { Text = "Selected: (click the calendar)", AutoSize = true, ForeColor = Color.Navy };
            MonthCalendar cal = new MonthCalendar { MaxSelectionCount = 7, ShowTodayCircle = true, FirstDayOfWeek = Day.Monday };
            cal.DateSelected += (s, e) => { calLbl.Text = "Selected: " + cal.SelectionStart.ToShortDateString() + "  to  " + cal.SelectionEnd.ToShortDateString(); SetStatus("MonthCalendar range updated"); };
            DateTime today = DateTime.Today;
            cal.BoldedDates = new DateTime[] { today.AddDays(1), today.AddDays(3), today.AddDays(7) };
            AddRow(t, "MonthCalendar:", cal, "Multi-select calendar with bolded dates");
            AddRow(t, "Calendar result:", calLbl, null);
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabContainers()
        {
            TabPage p = new TabPage("4. Containers");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "Containers that hold other controls (and each other)");
            SplitContainer sc = new SplitContainer { Dock = DockStyle.Fill, Height = 130, Panel1MinSize = 40, Panel2MinSize = 40 };
            bool scSet = false;
            sc.Resize += (s, e) => { if (!scSet && sc.Width > 240) { try { sc.SplitterDistance = sc.Width / 3; scSet = true; } catch { } } };
            sc.Panel1.BackColor = Color.AliceBlue;
            ListBox lbIn = new ListBox { Dock = DockStyle.Fill };
            lbIn.Items.AddRange(new object[] { "Inside", "The", "SplitContainer" });
            sc.Panel1.Controls.Add(lbIn);
            TextBox tbIn = new TextBox { Dock = DockStyle.Fill, Multiline = true, Text = "Panel2 - drag the splitter between the panels!" };
            sc.Panel2.Controls.Add(tbIn);
            AddRow(t, "SplitContainer:", sc, "Two resizable panels with a draggable splitter");
            FlowLayoutPanel flp = new FlowLayoutPanel { Dock = DockStyle.Fill, Height = 84, BorderStyle = BorderStyle.FixedSingle, BackColor = Color.WhiteSmoke };
            for (int i = 1; i <= 10; i++) { Button b = new Button { Text = "Btn " + i, AutoSize = true }; int n = i; b.Click += (s, e) => SetStatus("FlowLayoutPanel button " + n); flp.Controls.Add(b); }
            AddRow(t, "FlowLayoutPanel:", flp, "Controls flow and wrap automatically");
            TableLayoutPanel tlp = new TableLayoutPanel { Dock = DockStyle.Fill, Height = 110, ColumnCount = 3, RowCount = 3 };
            for (int c = 0; c < 3; c++) tlp.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33.3F));
            for (int r = 0; r < 3; r++) tlp.RowStyles.Add(new RowStyle(SizeType.Percent, 33.3F));
            string[] names = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" };
            for (int i = 0; i < 9; i++) { Label cell = new Label { Text = names[i], Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, BackColor = (i % 2 == 0) ? Color.Honeydew : Color.MintCream, BorderStyle = BorderStyle.FixedSingle, Margin = new Padding(1) }; tlp.Controls.Add(cell, i % 3, i / 3); }
            AddRow(t, "TableLayoutPanel:", tlp, "3x3 percentage-based grid");
            Panel scr = new Panel { Dock = DockStyle.Fill, Height = 90, AutoScroll = true, BorderStyle = BorderStyle.FixedSingle };
            for (int i = 1; i <= 20; i++) { Label li = new Label { Text = "Scrollable item " + i, Location = new Point(6, 4 + (i - 1) * 24), AutoSize = true }; scr.Controls.Add(li); }
            AddRow(t, "Panel (AutoScroll):", scr, "Panel shows scrollbars when content overflows");
            TabControl inner = new TabControl { Dock = DockStyle.Fill, Height = 100 };
            inner.TabPages.Add(new TabPage("Inner A")); inner.TabPages.Add(new TabPage("Inner B")); inner.TabPages.Add(new TabPage("Inner C"));
            inner.TabPages[0].Controls.Add(new Label { Text = "TabControl inside a TabControl - recursion is fun.", AutoSize = true, Padding = new Padding(8) });
            AddRow(t, "TabControl (nested):", inner, "Tabs can nest");
            GroupBox gb = new GroupBox { Text = "GroupBox", AutoSize = true, Padding = new Padding(6) };
            FlowLayoutPanel gbf = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
            for (int i = 1; i <= 4; i++) { Button b = new Button { Text = "G" + i, AutoSize = true }; gbf.Controls.Add(b); }
            gb.Controls.Add(gbf);
            AddRow(t, "GroupBox:", gb, "Grouped controls with a caption");
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabData()
        {
            TabPage p = new TabPage("5. Data Views");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "Presenting collections: ListView, TreeView, DataGridView, PropertyGrid");
            ListView lv = new ListView { Height = 140, View = View.Details, FullRowSelect = true, CheckBoxes = true, GridLines = true };
            lv.Columns.Add("Name", 150); lv.Columns.Add("Type", 90); lv.Columns.Add("Size (KB)", 80);
            ListViewGroup g1 = new ListViewGroup("Documents"); ListViewGroup g2 = new ListViewGroup("Media");
            lv.Groups.Add(g1); lv.Groups.Add(g2);
            ListViewItem a = new ListViewItem("report.docx", 0) { Group = g1 }; a.SubItems.Add("Document"); a.SubItems.Add("34");
            ListViewItem b = new ListViewItem("notes.txt", 1) { Group = g1 }; b.SubItems.Add("Text"); b.SubItems.Add("2");
            ListViewItem c = new ListViewItem("song.mp3", 2) { Group = g2 }; c.SubItems.Add("Audio"); c.SubItems.Add("5120");
            ListViewItem d = new ListViewItem("clip.avi", 3) { Group = g2 }; d.SubItems.Add("Video"); d.SubItems.Add("98304");
            lv.Items.AddRange(new ListViewItem[] { a, b, c, d });
            lv.SelectedIndexChanged += (s, e) => { if (lv.SelectedItems.Count > 0) SetStatus("ListView: " + lv.SelectedItems[0].Text); };
            AddFillRow(t, "ListView:", lv, 130, "Details view with groups, checkboxes and columns");
            FlowLayoutPanel lvBtns = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
            foreach (View v in new View[] { View.LargeIcon, View.SmallIcon, View.List, View.Details })
            { Button vb = new Button { Text = v.ToString(), AutoSize = true }; View vv = v; vb.Click += (s, e) => { lv.View = vv; SetStatus("ListView view: " + vv); }; lvBtns.Controls.Add(vb); }
            AddRow(t, "ListView views:", lvBtns, "Switch ListView View modes");
            TreeView tv = new TreeView { Height = 120, CheckBoxes = true, ImageList = icons, ItemHeight = 20 };
            TreeNode root = new TreeNode("Devices", 0, 0);
            TreeNode pc = new TreeNode("This PC", 1, 1);
            pc.Nodes.Add(new TreeNode("Drive C:", 2, 2)); pc.Nodes.Add(new TreeNode("Drive D:", 2, 2));
            TreeNode net = new TreeNode("Network", 3, 3);
            net.Nodes.Add(new TreeNode("Server-01", 4, 4)); net.Nodes.Add(new TreeNode("NAS", 4, 4));
            root.Nodes.Add(pc); root.Nodes.Add(net);
            tv.Nodes.Add(root); root.Expand(); pc.Expand();
            tv.AfterSelect += (s, e) => SetStatus("TreeView selected: " + e.Node.FullPath);
            tv.AfterCheck += (s, e) => SetStatus("TreeView check: " + e.Node.Text + " = " + e.Node.Checked);
            AddRow(t, "TreeView:", tv, "Hierarchy with checkboxes and ImageList icons");
            DataTable dt = new DataTable("People");
            dt.Columns.Add("Name", typeof(string)); dt.Columns.Add("Age", typeof(int)); dt.Columns.Add("City", typeof(string));
            dt.Rows.Add("Ada Lovelace", 36, "London"); dt.Rows.Add("Alan Turing", 41, "Wilmslow"); dt.Rows.Add("Grace Hopper", 85, "Arlington"); dt.Rows.Add("Linus T", 54, "Portland");
            BindingSource bs = new BindingSource { DataSource = dt };
            BindingNavigator nav = new BindingNavigator(true) { Dock = DockStyle.Top };
            nav.BindingSource = bs;
            DataGridView grid = new DataGridView { Dock = DockStyle.Fill, DataSource = bs, AllowUserToAddRows = true, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, Height = 120 };
            grid.DataError += (s, e) => SetStatus("Grid data error: " + e.Exception.Message);
            Panel gridHost = new Panel { Dock = DockStyle.Fill, Height = 160 };
            gridHost.Controls.Add(grid); gridHost.Controls.Add(nav);
            AddFillRow(t, "DataGridView + BindingNavigator:", gridHost, 150, "Data-bound grid with a navigator strip (add/delete rows)");
            PropertyGrid pg = new PropertyGrid { Dock = DockStyle.Fill, Height = 150, SelectedObject = new Person("Ada Lovelace", 36, "London") };
            AddFillRow(t, "PropertyGrid:", pg, 150, "Reflects public properties of a Person object");
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabMenus()
        {
            TabPage p = new TabPage("6. Menus & Toolbars");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "The MenuStrip, ToolStrip and StatusStrip are live at the top and bottom of this window");
            AddRow(t, "MenuStrip:", new Label { Text = "MenuStrip: File / View / Help with shortcuts (try Ctrl+O, Ctrl+S, Alt+F4).", AutoSize = true, Anchor = AnchorStyles.Left, ForeColor = Color.DarkSlateGray }, null);
            ContextMenuStrip ctx = new ContextMenuStrip();
            ctx.Items.Add(new ToolStripMenuItem("Cut", null, (s, e) => SetStatus("Context: Cut")));
            ctx.Items.Add(new ToolStripMenuItem("Copy", null, (s, e) => SetStatus("Context: Copy")));
            ctx.Items.Add(new ToolStripMenuItem("Paste", null, (s, e) => SetStatus("Context: Paste")));
            ctx.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem ctxCheck = new ToolStripMenuItem("Snap to grid");
            ctxCheck.CheckOnClick = true; ctxCheck.Checked = true;
            ctxCheck.Click += (s, e) => SetStatus("Snap to grid = " + ctxCheck.Checked);
            ctx.Items.Add(ctxCheck);
            Panel ctxHost = new Panel { Dock = DockStyle.Fill, Height = 110, BackColor = Color.Ivory, BorderStyle = BorderStyle.FixedSingle, ContextMenuStrip = ctx };
            ctxHost.Controls.Add(new Label { Text = "Right-click anywhere in this bordered panel", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = Color.Gray });
            AddFillRow(t, "ContextMenuStrip:", ctxHost, 100, "ContextMenuStrip - right-click the panel");
            ToolStrip inner = new ToolStrip { GripStyle = ToolStripGripStyle.Hidden, Dock = DockStyle.Top, BackColor = Color.WhiteSmoke };
            ToolStripDropDownButton ddb = new ToolStripDropDownButton("DropDownButton");
            ddb.DropDownItems.Add(new ToolStripMenuItem("Nested level 1", null, (s, e) => SetStatus("Nested 1")));
            ToolStripMenuItem lvl2 = new ToolStripMenuItem("Nested level 2");
            lvl2.DropDownItems.Add(new ToolStripMenuItem("Deepest item", null, (s, e) => SetStatus("Deepest!")));
            ddb.DropDownItems.Add(lvl2);
            ToolStripSplitButton spb = new ToolStripSplitButton("SplitButton");
            spb.ButtonClick += (s, e) => SetStatus("SplitButton main area");
            spb.DropDownItems.Add(new ToolStripMenuItem("Alt option", null, (s, e) => SetStatus("SplitButton alt")));
            ToolStripTextBox tst2 = new ToolStripTextBox { ToolTipText = "Type here" };
            tst2.KeyPress += (s, e) => { if (e.KeyChar == (char)13) { SetStatus("Inner strip text: " + tst2.Text); e.Handled = true; } };
            ToolStripComboBox tcmb = new ToolStripComboBox { DropDownStyle = ComboBoxStyle.DropDownList };
            tcmb.Items.AddRange(new object[] { "Small", "Medium", "Large" });
            tcmb.SelectedIndexChanged += (s, e) => SetStatus("Inner combo: " + tcmb.Text);
            ToolStripProgressBar tpp = new ToolStripProgressBar { Value = 65 };
            inner.Items.AddRange(new ToolStripItem[] { ddb, new ToolStripSeparator(), spb, new ToolStripSeparator(), new ToolStripLabel("Type:"), tst2, tcmb, new ToolStripSeparator(), tpp });
            AddRow(t, "ToolStrip items:", inner, "DropDownButton, SplitButton, ToolStripTextBox, ToolStripComboBox, ToolStripProgressBar");
            StatusStrip mini = new StatusStrip { Dock = DockStyle.Bottom, SizingGrip = false };
            ToolStripStatusLabel m1 = new ToolStripStatusLabel { Spring = true, Text = "A StatusStrip inside a tab", TextAlign = ContentAlignment.MiddleLeft };
            ToolStripStatusLabel m2 = new ToolStripStatusLabel("v8.0") { BorderSides = ToolStripStatusLabelBorderSides.All };
            mini.Items.AddRange(new ToolStripItem[] { m1, m2 });
            Panel miniHost = new Panel { Dock = DockStyle.Fill, Height = 40 };
            miniHost.Controls.Add(mini);
            AddRow(t, "StatusStrip (mini):", miniHost, "Another StatusStrip instance");
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabDialogs()
        {
            TabPage p = new TabPage("7. Dialogs");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "Common dialogs: files, folders, colors, fonts, printing, message boxes and a custom dialog");
            Label lblPainted = new Label { Text = "Target for Color / Font dialogs", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, BackColor = Color.PapayaWhip, BorderStyle = BorderStyle.FixedSingle, Font = new Font("Segoe UI", 11F), MinimumSize = new Size(0, 46) };
            AddRow(t, "Sample label:", lblPainted, "ColorDialog and FontDialog apply here");
            Button btnOpen = new Button { Text = "OpenFileDialog...", AutoSize = true }; btnOpen.Click += (s, e) => ShowOpenDialog();
            Button btnSave = new Button { Text = "SaveFileDialog...", AutoSize = true }; btnSave.Click += (s, e) => ShowSaveDialog();
            AddRow(t, "File dialogs:", Flow(btnOpen, btnSave), "Standard open and save dialogs (no files are harmed)");
            Button btnFolder = new Button { Text = "FolderBrowserDialog...", AutoSize = true };
            btnFolder.Click += (s, e) => { using (FolderBrowserDialog fb = new FolderBrowserDialog { Description = "Pick any folder", ShowNewFolderButton = true }) { if (fb.ShowDialog(this) == DialogResult.OK) SetStatus("Folder: " + fb.SelectedPath); else SetStatus("Folder dialog cancelled"); } };
            AddRow(t, "Folder dialog:", btnFolder, null);
            Button btnColor = new Button { Text = "ColorDialog...", AutoSize = true };
            btnColor.Click += (s, e) => { using (ColorDialog cd = new ColorDialog { FullOpen = true }) { if (cd.ShowDialog(this) == DialogResult.OK) { lblPainted.BackColor = cd.Color; SetStatus("Color applied: " + cd.Color.Name); } } };
            Button btnFont = new Button { Text = "FontDialog...", AutoSize = true };
            btnFont.Click += (s, e) => { using (FontDialog fd = new FontDialog()) { if (fd.ShowDialog(this) == DialogResult.OK) { lblPainted.Font = fd.Font; SetStatus("Font applied: " + fd.Font.Name + " " + fd.Font.SizeInPoints + "pt"); } } };
            AddRow(t, "Color / Font:", Flow(btnColor, btnFont), null);
            Button btnPrint = new Button { Text = "PrintPreviewDialog...", AutoSize = true };
            btnPrint.Click += (s, e) => ShowPrintPreview();
            Button btnMsgs = new Button { Text = "MessageBox gallery...", AutoSize = true };
            btnMsgs.Click += (s, e) => ShowMsgGallery();
            AddRow(t, "Print / MessageBox:", Flow(btnPrint, btnMsgs), null);
            Button btnAbout = new Button { Text = "Custom dialog (AboutBox)...", AutoSize = true };
            btnAbout.Click += (s, e) => { using (AboutBox ab = new AboutBox()) { DialogResult dr = ab.ShowDialog(this); SetStatus("Custom dialog returned: " + dr); } };
            AddRow(t, "Custom Form dialog:", btnAbout, "A second Form shown with ShowDialog");
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabBackground()
        {
            TabPage p = new TabPage("8. Background & Components");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "Non-visual components: Timer, BackgroundWorker, NotifyIcon, ErrorProvider, HelpProvider");
            Label clockLbl = new Label { Text = "Timer tick: 0", AutoSize = true, Anchor = AnchorStyles.Left, Font = new Font("Consolas", 10F, FontStyle.Bold), ForeColor = Color.SeaGreen };
            clock.Tick += (s, e) => clockLbl.Text = "Timer tick: " + ticks + "   " + DateTime.Now.ToLongTimeString();
            AddRow(t, "Timer (1s):", clockLbl, "System.Windows.Forms.Timer ticking every second");
            demoProg = new ProgressBar { Minimum = 0, Maximum = 100, Value = 30, Height = 22 };
            Button btnMarquee = new Button { Text = "Toggle marquee", AutoSize = true };
            btnMarquee.Click += (s, e) => { if (demoProg.Style == ProgressBarStyle.Marquee) { demoProg.Style = ProgressBarStyle.Blocks; demoProg.Value = 60; } else { demoProg.Value = 0; demoProg.Style = ProgressBarStyle.Marquee; demoProg.MarqueeAnimationSpeed = 30; } SetStatus("ProgressBar style: " + demoProg.Style); };
            AddRow(t, "ProgressBar:", Flow(demoProg, btnMarquee), "Blocks and Marquee styles");
            workerBtn = new Button { Text = "Start BackgroundWorker", AutoSize = true };
            cancelBtn = new Button { Text = "Cancel", AutoSize = true, Enabled = false };
            workerBar = new ProgressBar { Minimum = 0, Maximum = 100, Width = 200, Height = 22 };
            workerState = new Label { Text = "idle", AutoSize = true, Anchor = AnchorStyles.Left, ForeColor = Color.DimGray };
            workerBtn.Click += (s, e) => { if (!worker.IsBusy) { workerBar.Value = 0; workerState.Text = "running..."; workerBtn.Enabled = false; cancelBtn.Enabled = true; worker.RunWorkerAsync("demo payload"); } };
            cancelBtn.Click += (s, e) => { worker.CancelAsync(); SetStatus("Cancellation requested"); };
            AddRow(t, "BackgroundWorker:", Flow(workerBtn, cancelBtn, workerBar, workerState), "Reports progress to the UI thread; supports cancellation");
            Button btnBalloon = new Button { Text = "NotifyIcon balloon tip", AutoSize = true };
            btnBalloon.Click += (s, e) => { tray.ShowBalloonTip(3000, "WinForms Showcase", "I am living in your system tray right now!", ToolTipIcon.Info); SetStatus("Balloon tip shown"); };
            AddRow(t, "NotifyIcon:", btnBalloon, "Also watch the tray icon near the clock");
            TextBox tbNumeric = new TextBox { Width = 120, Text = "42" };
            tbNumeric.TextChanged += (s, e) => { int n; if (int.TryParse(tbNumeric.Text, out n)) { err.SetError(tbNumeric, ""); SetStatus("Valid number: " + n); } else { err.SetError(tbNumeric, "Must be a whole number!"); } };
            AddRow(t, "ErrorProvider:", Flow(tbNumeric, new Label { Text = "type a non-number to see the icon", AutoSize = true, ForeColor = Color.DimGray }), "ErrorProvider flags invalid input with a blinking red icon and tooltip");
            Button helpBtn = new Button { Text = "Click me, then press F1", AutoSize = true };
            hp.SetHelpString(helpBtn, "HelpProvider: this popup appears because the button had focus when F1 was pressed - no CHM file or help namespace needed.");
            hp.SetShowHelp(helpBtn, true);
            helpBtn.Click += (s, e) => SetStatus("Button focused - now press F1");
            AddRow(t, "HelpProvider:", helpBtn, "Pop-up help on F1, wired entirely in code");
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabGraphics()
        {
            TabPage p = new TabPage("9. Graphics");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "GDI+ painting: gradients, hatches, transforms, double buffering and mouse drawing");
            PaintCanvas canvas = new PaintCanvas { Dock = DockStyle.Fill, BorderStyle = BorderStyle.FixedSingle };
            Button shuffle = new Button { Text = "Randomize palette", AutoSize = true };
            shuffle.Click += (s, e) => { canvas.Randomize(); canvas.Invalidate(); SetStatus("PaintCanvas repainted with a fresh random palette"); };
            CheckBox anim = new CheckBox { Text = "Bounce the ball", AutoSize = true };
            anim.CheckedChanged += (s, e) => { canvas.AnimationOn = anim.Checked; SetStatus("PaintCanvas animation: " + anim.Checked); };
            AddFillRow(t, "PaintCanvas (OnPaint):", canvas, 200, "A Panel subclass drawing a gradient, hatch ellipse, dashed Bezier, rotating arc and animated ball in OnPaint with double buffering");
            DoubleBufferPanel pad = new DoubleBufferPanel { Dock = DockStyle.Fill, BackColor = Color.White, BorderStyle = BorderStyle.FixedSingle };
            List<List<Point>> strokes = new List<List<Point>>(); bool drawing = false;
            pad.MouseDown += (s2, e2) => { drawing = true; strokes.Add(new List<Point>()); strokes[strokes.Count - 1].Add(e2.Location); };
            pad.MouseMove += (s2, e2) => { if (drawing) { strokes[strokes.Count - 1].Add(e2.Location); pad.Invalidate(); } };
            pad.MouseUp += (s2, e2) => { drawing = false; SetStatus("Scribble pad: " + strokes.Count + " stroke(s) drawn with the mouse"); };
            pad.Paint += (s2, e2) => { e2.Graphics.SmoothingMode = SmoothingMode.AntiAlias; foreach (List<Point> st in strokes) { if (st.Count > 1) { using (Pen pen = new Pen(Color.FromArgb(160 + (st.Count % 90), 60, 120), 3F)) { e2.Graphics.DrawLines(pen, st.ToArray()); } } } };
            Button clearPad = new Button { Text = "Clear pad", AutoSize = true };
            clearPad.Click += (s, e) => { strokes.Clear(); pad.Invalidate(); SetStatus("Scribble pad cleared"); };
            AddFillRow(t, "Scribble pad (mouse):", pad, 110, "Draw with the left mouse button - repainting happens in the Paint event, never with CreateGraphics");
            AddRow(t, "Canvas actions:", Flow(shuffle, anim, clearPad, new Label { Text = "Resize the window - ResizeRedraw keeps the canvas correct", AutoSize = true, ForeColor = Color.DimGray }), null);
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabWebMedia()
        {
            TabPage p = new TabPage("10. Web/Media");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "WebBrowser, PictureBox, SoundPlayer and SystemSounds - media with zero media files");
            string html =
                "<html><head><style>" +
                "body{font-family:'Segoe UI';background:#f4f4ff;padding:10px}" +
                "h2{color:indigo;margin:0 0 6px 0}p{font-size:13px}button{padding:4px 12px}" +
                "</style></head><body>" +
                "<h2>Hello from an embedded WebBrowser</h2>" +
                "<p>This HTML was injected from C# through <b>DocumentText</b> - no internet involved.</p>" +
                "<p id='output'>C# can write into this paragraph...</p>" +
                "<button onclick=\"window.external.Report('JavaScript called C# at ' + new Date().toLocaleTimeString())\">Call C# from JavaScript</button>" +
                "</body></html>";
            WebBrowser web = new WebBrowser { Dock = DockStyle.Fill, MinimumSize = new Size(0, 150), ScriptErrorsSuppressed = true, AllowWebBrowserDrop = false };
            web.ObjectForScripting = new WebBridge(m => BeginInvoke((Action)(() => SetStatus("WebBrowser ObjectForScripting: " + m))));
            bool htmlSet = false;
            web.HandleCreated += (s2, e2) => { if (!htmlSet) { htmlSet = true; web.DocumentText = html; } };
            web.DocumentCompleted += (s2, e2) => SetStatus("WebBrowser document loaded: " + web.DocumentTitle);
            AddFillRow(t, "WebBrowser:", web, 160, "IE-engine browser fed with in-memory HTML; the page's button calls back into C# via ObjectForScripting (page loads when you first open this tab)");
            Button wbWrite = new Button { Text = "C# writes into the page", AutoSize = true };
            wbWrite.Click += (s, e) =>
            {
                HtmlElement el = (web.Document == null) ? null : web.Document.GetElementById("output");
                if (el == null) { SetStatus("Page not loaded yet - reopen this tab, then try again"); return; }
                el.InnerText = "Hello page - written from C# at " + DateTime.Now.ToLongTimeString();
                SetStatus("DOM element updated from C#");
            };
            Button wbReload = new Button { Text = "Reload HTML", AutoSize = true };
            wbReload.Click += (s, e) => { web.DocumentText = html; SetStatus("DocumentText re-assigned"); };
            AddRow(t, "WebBrowser actions:", Flow(wbWrite, wbReload), "Two-way DOM access: C# into the page, JavaScript back into C#");
            PictureBox pb = new PictureBox { Dock = DockStyle.Fill, BackColor = Color.White, BorderStyle = BorderStyle.FixedSingle, SizeMode = PictureBoxSizeMode.Zoom, Image = BuildDemoBitmap(360, 220), Margin = new Padding(2) };
            AddFillRow(t, "PictureBox:", pb, 130, "The bitmap is drawn at runtime with GDI+ - no image file on disk");
            FlowLayoutPanel pbModes = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
            foreach (PictureBoxSizeMode m in new PictureBoxSizeMode[] { PictureBoxSizeMode.Normal, PictureBoxSizeMode.StretchImage, PictureBoxSizeMode.CenterImage, PictureBoxSizeMode.Zoom, PictureBoxSizeMode.AutoSize })
            {
                PictureBoxSizeMode mm = m; Button b = new Button { Text = m.ToString(), AutoSize = true };
                b.Click += (s, e) => { pb.SizeMode = mm; SetStatus("PictureBox SizeMode: " + mm); };
                pbModes.Controls.Add(b);
            }
            AddRow(t, "PictureBox SizeMode:", pbModes, "Normal, StretchImage, CenterImage, Zoom, AutoSize");
            Button tone1 = new Button { Text = "Tone 440 Hz", AutoSize = true };
            tone1.Click += (s, e) => PlayTone(440, 440, 400, 0.35);
            Button tone2 = new Button { Text = "Tone 880 Hz", AutoSize = true };
            tone2.Click += (s, e) => PlayTone(880, 880, 400, 0.35);
            Button tone3 = new Button { Text = "Rising chirp", AutoSize = true };
            tone3.Click += (s, e) => PlayTone(220, 1760, 900, 0.35);
            AddRow(t, "SoundPlayer:", Flow(tone1, tone2, tone3), "A WAV file is synthesized into a MemoryStream and played - no audio files");
            Button sb1 = new Button { Text = "Beep", AutoSize = true }; sb1.Click += (s, e) => { SystemSounds.Beep.Play(); SetStatus("SystemSounds.Beep"); };
            Button sb2 = new Button { Text = "Asterisk", AutoSize = true }; sb2.Click += (s, e) => { SystemSounds.Asterisk.Play(); SetStatus("SystemSounds.Asterisk"); };
            Button sb3 = new Button { Text = "Exclamation", AutoSize = true }; sb3.Click += (s, e) => { SystemSounds.Exclamation.Play(); SetStatus("SystemSounds.Exclamation"); };
            Button sb4 = new Button { Text = "Hand", AutoSize = true }; sb4.Click += (s, e) => { SystemSounds.Hand.Play(); SetStatus("SystemSounds.Hand"); };
            Button sb5 = new Button { Text = "Question", AutoSize = true }; sb5.Click += (s, e) => { SystemSounds.Question.Play(); SetStatus("SystemSounds.Question"); };
            AddRow(t, "SystemSounds:", Flow(sb1, sb2, sb3, sb4, sb5), "The five Windows system sounds (silent if your sound scheme is 'No Sounds')");
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabLayoutScroll()
        {
            TabPage p = new TabPage("11. Layout & Scroll");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "HScrollBar / VScrollBar, an Anchor + Dock playground, ToolStripContainer and the legacy Splitter");
            Label swatchLbl = new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = Color.White, Text = "#B43C32  18 pt", Font = new Font("Segoe UI", 18F, FontStyle.Bold) };
            Panel swatch = new Panel { Size = new Size(200, 64), BorderStyle = BorderStyle.FixedSingle, BackColor = Color.FromArgb(180, 60, 50) };
            swatch.Controls.Add(swatchLbl);
            HScrollBar hsR = new HScrollBar { Minimum = 0, Maximum = 270, LargeChange = 16, SmallChange = 4, Value = 180, Width = 150 };
            HScrollBar hsG = new HScrollBar { Minimum = 0, Maximum = 270, LargeChange = 16, SmallChange = 4, Value = 60, Width = 150 };
            HScrollBar hsB = new HScrollBar { Minimum = 0, Maximum = 270, LargeChange = 16, SmallChange = 4, Value = 50, Width = 150 };
            VScrollBar vsFont = new VScrollBar { Minimum = 8, Maximum = 87, LargeChange = 16, SmallChange = 2, Value = 18, Height = 64 };
            EventHandler mix = delegate
            {
                swatch.BackColor = Color.FromArgb(hsR.Value, hsG.Value, hsB.Value);
                swatchLbl.ForeColor = (hsR.Value + hsG.Value + hsB.Value > 400) ? Color.Black : Color.White;
                swatchLbl.Text = string.Format("#{0:X2}{1:X2}{2:X2}  {3} pt", hsR.Value, hsG.Value, hsB.Value, vsFont.Value);
                swatchLbl.Font = new Font("Segoe UI", (float)vsFont.Value, FontStyle.Bold);
                SetStatus(string.Format("HScrollBar RGB {0},{1},{2} - VScrollBar font size {3}", hsR.Value, hsG.Value, hsB.Value, vsFont.Value));
            };
            hsR.ValueChanged += mix; hsG.ValueChanged += mix; hsB.ValueChanged += mix; vsFont.ValueChanged += mix;
            AddRow(t, "HScrollBar / VScrollBar:", Flow(new Label { Text = "R", AutoSize = true }, hsR, new Label { Text = "G", AutoSize = true }, hsG, new Label { Text = "B", AutoSize = true }, hsB, vsFont, swatch), "Three HScrollBars mix a color; the VScrollBar drives the preview font size");
            Panel stage = new Panel { Size = new Size(340, 110), BorderStyle = BorderStyle.FixedSingle, BackColor = Color.White, Margin = new Padding(2) };
            Button probe = new Button { Text = "Probe", AutoSize = true, Location = new Point(12, 12) };
            stage.Controls.Add(probe);
            int r0 = t.RowCount; t.RowCount++; t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            t.Controls.Add(new Label { Text = "Anchor / Dock playground:", AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(2, 6, 6, 2) }, 0, r0);
            t.Controls.Add(stage, 1, r0);
            tips.SetToolTip(stage, "Pick an Anchor (or Dock = Fill), then resize the white stage with the + and - buttons");
            RadioButton aTL = new RadioButton { Text = "Top,Left", Checked = true, AutoSize = true };
            RadioButton aAll = new RadioButton { Text = "All", AutoSize = true };
            RadioButton aBR = new RadioButton { Text = "Bottom,Right", AutoSize = true };
            RadioButton aNone = new RadioButton { Text = "None", AutoSize = true };
            CheckBox dockFill = new CheckBox { Text = "Dock = Fill", AutoSize = true };
            Button grow = new Button { Text = "Stage +", AutoSize = true };
            Button shrink = new Button { Text = "Stage -", AutoSize = true };
            Action applyAnchor = delegate
            {
                if (dockFill.Checked) { probe.Dock = DockStyle.Fill; }
                else
                {
                    probe.Dock = DockStyle.None;
                    probe.Anchor = aTL.Checked ? (AnchorStyles.Top | AnchorStyles.Left) : aAll.Checked ? (AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right) : aBR.Checked ? (AnchorStyles.Bottom | AnchorStyles.Right) : AnchorStyles.None;
                }
                SetStatus("Probe Anchor = " + probe.Anchor + (dockFill.Checked ? " (docked)" : string.Empty));
            };
            EventHandler ap = (s2, e2) => applyAnchor();
            aTL.CheckedChanged += ap; aAll.CheckedChanged += ap; aBR.CheckedChanged += ap; aNone.CheckedChanged += ap; dockFill.CheckedChanged += ap;
            grow.Click += (s, e) => { stage.Width += 30; stage.Height += 24; applyAnchor(); };
            shrink.Click += (s, e) => { if (stage.Width > 160) { stage.Width -= 30; } if (stage.Height > 70) { stage.Height -= 24; } applyAnchor(); };
            AddRow(t, "Anchor presets:", Flow(aTL, aAll, aBR, aNone, dockFill, grow, shrink), "Anchor and Dock are the two WinForms layout mechanics - watch the Probe react");
            ToolStripContainer tsc = new ToolStripContainer { Dock = DockStyle.Fill, Height = 150 };
            ToolStrip stripTop = new ToolStrip();
            stripTop.Items.Add(new ToolStripButton("Cut", null, (s, e) => SetStatus("ToolStripContainer strip: Cut")) { DisplayStyle = ToolStripItemDisplayStyle.Text });
            stripTop.Items.Add(new ToolStripButton("Copy", null, (s, e) => SetStatus("ToolStripContainer strip: Copy")) { DisplayStyle = ToolStripItemDisplayStyle.Text });
            stripTop.Items.Add(new ToolStripButton("Paste", null, (s, e) => SetStatus("ToolStripContainer strip: Paste")) { DisplayStyle = ToolStripItemDisplayStyle.Text });
            stripTop.Items.Add(new ToolStripLabel("Grab my grip and drag me to another edge!"));
            tsc.TopToolStripPanel.Join(stripTop);
            ToolStrip stripSide = new ToolStrip();
            stripSide.Items.Add(new ToolStripButton("Side", null, (s, e) => SetStatus("ToolStripContainer right panel")) { DisplayStyle = ToolStripItemDisplayStyle.Text });
            tsc.RightToolStripPanel.Join(stripSide);
            RichTextBox tscBody = new RichTextBox { Dock = DockStyle.Fill, Text = "This RichTextBox lives in the ToolStripContainer's ContentPanel.\r\n\r\nThe container exposes four ToolStripPanels (top, bottom, left, right). Drag the toolstrips between them at runtime - that is the whole point of ToolStripContainer." };
            tsc.ContentPanel.Controls.Add(tscBody);
            AddFillRow(t, "ToolStripContainer:", tsc, 140, "Four edge panels that toolbars can be dragged between at runtime");
            Panel legacyHost = new Panel { Dock = DockStyle.Fill, Height = 90 };
            Panel legacyLeft = new Panel { Dock = DockStyle.Left, Width = 110, BackColor = Color.AliceBlue };
            legacyLeft.Controls.Add(new Label { Text = "Docked Left", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter });
            Splitter legacy = new Splitter { Dock = DockStyle.Left, Width = 5, MinSize = 30, MinExtra = 30, BackColor = Color.SteelBlue };
            Panel legacyFill = new Panel { Dock = DockStyle.Fill, BackColor = Color.MintCream };
            legacyFill.Controls.Add(new Label { Text = "Fill area - drag the blue bar", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter });
            legacyHost.Controls.Add(legacyFill); legacyHost.Controls.Add(legacy); legacyHost.Controls.Add(legacyLeft);
            AddFillRow(t, "Splitter (legacy):", legacyHost, 85, "The .NET 1.x Splitter control - ancestor of SplitContainer - still resizes panels");
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabComponents()
        {
            TabPage p = new TabPage("12. Components & Print");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "FileSystemWatcher, Process, System.Timers.Timer and printing with PrintDialog / PageSetupDialog / PrintPreviewControl");
            ListBox fswLog = new ListBox { Dock = DockStyle.Fill, IntegralHeight = false };
            string watchDir = Path.Combine(Path.GetTempPath(), "WinFormsShowcase_FSW");
            try { Directory.CreateDirectory(watchDir); } catch { watchDir = Path.GetTempPath(); }
            FileSystemWatcher fsw = new FileSystemWatcher(watchDir, "*.txt") { NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite };
            Action<string> post = m => { try { BeginInvoke((Action)(() => { fswLog.Items.Insert(0, m); if (fswLog.Items.Count > 60) { fswLog.Items.RemoveAt(60); } SetStatus(m); })); } catch { } };
            fsw.Created += (s2, e2) => post("FSW Created: " + e2.Name);
            fsw.Changed += (s2, e2) => post("FSW Changed: " + e2.Name);
            fsw.Deleted += (s2, e2) => post("FSW Deleted: " + e2.Name);
            fsw.Renamed += (s2, e2) => post("FSW Renamed: " + e2.OldName + " -> " + e2.Name);
            FormClosed += (s2, e2) => { try { fsw.EnableRaisingEvents = false; fsw.Dispose(); } catch { } };
            Button fswCreate = new Button { Text = "Create file", AutoSize = true };
            fswCreate.Click += (s, e) => { try { File.WriteAllText(Path.Combine(watchDir, "note_" + (DateTime.Now.Ticks % 100000) + ".txt"), "written " + DateTime.Now); } catch (Exception ex) { SetStatus("Create failed: " + ex.Message); } };
            Button fswModify = new Button { Text = "Modify file", AutoSize = true };
            fswModify.Click += (s, e) => { try { string[] files = Directory.GetFiles(watchDir, "*.txt"); if (files.Length == 0) { SetStatus("Create a file first"); return; } File.AppendAllText(files[0], "\r\nupdated " + DateTime.Now); } catch (Exception ex) { SetStatus("Modify failed: " + ex.Message); } };
            Button fswDelete = new Button { Text = "Delete all", AutoSize = true };
            fswDelete.Click += (s, e) => { try { foreach (string f in Directory.GetFiles(watchDir, "*.txt")) { File.Delete(f); } } catch (Exception ex) { SetStatus("Delete failed: " + ex.Message); } };
            CheckBox fswOn = new CheckBox { Text = "EnableRaisingEvents", AutoSize = true };
            fswOn.CheckedChanged += (s, e) => { fsw.EnableRaisingEvents = fswOn.Checked; SetStatus("FileSystemWatcher watching: " + watchDir); };
            fswOn.Checked = true;
            AddRow(t, "FileSystemWatcher:", Flow(fswOn, fswCreate, fswModify, fswDelete), "Watches a folder under %TEMP%; events arrive on threadpool threads and are marshalled to the UI thread with BeginInvoke");
            AddFillRow(t, "FSW event log:", fswLog, 80, null);
            Label procInfo = new Label { Dock = DockStyle.Fill, AutoSize = true, MaximumSize = new Size(560, 0), Text = "Process output appears here.", ForeColor = Color.DarkSlateGray };
            Button procSelf = new Button { Text = "Inspect this process", AutoSize = true };
            procSelf.Click += (s, e) =>
            {
                try
                {
                    System.Diagnostics.Process cur = System.Diagnostics.Process.GetCurrentProcess();
                    procInfo.Text = string.Format("Id={0}  Name={1}  WorkingSet={2:0.0} MB  Threads={3}  Handles={4}", cur.Id, cur.ProcessName, cur.WorkingSet64 / 1048576.0, cur.Threads.Count, cur.HandleCount);
                    SetStatus("Process.GetCurrentProcess(): " + cur.ProcessName);
                }
                catch (Exception ex) { SetStatus("Process info failed: " + ex.Message); }
            };
            Button procCmd = new Button { Text = "Run hidden cmd.exe", AutoSize = true };
            procCmd.Click += (s, e) =>
            {
                try
                {
                    System.Diagnostics.ProcessStartInfo psi = new System.Diagnostics.ProcessStartInfo("cmd.exe", "/c echo Hello from a hidden child process & ver") { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
                    using (System.Diagnostics.Process cp = System.Diagnostics.Process.Start(psi))
                    {
                        string output = cp.StandardOutput.ReadToEnd();
                        if (!cp.WaitForExit(5000)) { cp.Kill(); }
                        procInfo.Text = "cmd.exe said:\r\n" + output.Trim();
                        SetStatus("Process.Start captured " + output.Length + " characters");
                    }
                }
                catch (Exception ex) { SetStatus("cmd.exe failed: " + ex.Message); }
            };
            Button procShell = new Button { Text = "Shell-open Notepad", AutoSize = true };
            procShell.Click += (s, e) => { try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("notepad.exe") { UseShellExecute = true }); SetStatus("Process.Start launched notepad.exe"); } catch (Exception ex) { SetStatus("Launch failed: " + ex.Message); } };
            AddRow(t, "Process component:", Flow(procSelf, procCmd, procShell), "Inspect yourself, spawn a hidden console and capture its output, or shell-open an app");
            AddRow(t, "Process output:", procInfo, null);
            Label serverTimerLbl = new Label { Text = "System.Timers.Timer idle", AutoSize = true, Anchor = AnchorStyles.Left, Font = new Font("Consolas", 9.75F), ForeColor = Color.SeaGreen };
            System.Timers.Timer serverTimer = new System.Timers.Timer(500) { SynchronizingObject = this, Enabled = false };
            serverTimer.Elapsed += (s2, e2) => serverTimerLbl.Text = "System.Timers.Timer: " + e2.SignalTime.ToString("HH:mm:ss.fff");
            CheckBox serverOn = new CheckBox { Text = "Server timer (500 ms)", AutoSize = true };
            serverOn.CheckedChanged += (s, e) => { serverTimer.Enabled = serverOn.Checked; SetStatus("System.Timers.Timer enabled = " + serverOn.Checked); };
            FormClosed += (s2, e2) => { try { serverTimer.Dispose(); } catch { } };
            AddRow(t, "System.Timers.Timer:", Flow(serverOn, serverTimerLbl), "A threadpool timer whose Elapsed is marshalled to the UI thread via SynchronizingObject");
            PrintDocument pdoc = new PrintDocument { DocumentName = "WinFormsShowcase" };
            int printPage = 0;
            pdoc.BeginPrint += (s2, e2) => printPage = 0;
            pdoc.PrintPage += (s2, e2) => { printPage++; DrawShowcasePage(e2.Graphics, e2.MarginBounds, printPage); e2.HasMorePages = printPage < 2; };
            PrintPreviewControl ppc = new PrintPreviewControl { Dock = DockStyle.Fill, Document = pdoc, AutoZoom = true };
            AddFillRow(t, "PrintPreviewControl:", ppc, 190, "The engine behind PrintPreviewDialog, embedded live, drawing from a PrintDocument (two pages)");
            Button btnPrn = new Button { Text = "PrintDialog...", AutoSize = true };
            btnPrn.Click += (s, e) =>
            {
                using (PrintDialog pd = new PrintDialog { Document = pdoc, UseEXDialog = true })
                {
                    if (pd.ShowDialog(this) == DialogResult.OK)
                    {
                        try { pdoc.Print(); SetStatus("Document sent to the printer"); }
                        catch (Exception ex) { SetStatus("Print failed: " + ex.Message); }
                    }
                    else { SetStatus("PrintDialog cancelled"); }
                }
            };
            Button btnPage = new Button { Text = "PageSetupDialog...", AutoSize = true };
            btnPage.Click += (s, e) =>
            {
                using (PageSetupDialog psd = new PageSetupDialog { Document = pdoc })
                {
                    try { if (psd.ShowDialog(this) == DialogResult.OK) { ppc.InvalidatePreview(); SetStatus("Page setup applied - preview refreshed"); } }
                    catch (Exception ex) { SetStatus("PageSetupDialog: " + ex.Message); }
                }
            };
            Button btnPrev = new Button { Text = "Refresh preview", AutoSize = true };
            btnPrev.Click += (s, e) => { ppc.InvalidatePreview(); SetStatus("PrintPreviewControl refreshed"); };
            AddRow(t, "Printing dialogs:", Flow(btnPrn, btnPage, btnPrev), "PrintDialog and PageSetupDialog share the same PrintDocument as the preview");
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabGridMdi()
        {
            TabPage p = new TabPage("13. Grid, Binding & MDI");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "Every DataGridView column type, simple DataBindings, Form effects and a full MDI playground");
            DataGridView dg = new DataGridView { Dock = DockStyle.Fill, AllowUserToAddRows = false, AllowUserToDeleteRows = false, RowHeadersVisible = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill };
            DataGridViewTextBoxColumn cText = new DataGridViewTextBoxColumn { HeaderText = "Text column" };
            DataGridViewComboBoxColumn cCombo = new DataGridViewComboBoxColumn { HeaderText = "ComboBox column" };
            cCombo.Items.AddRange(new object[] { "Admin", "Developer", "Tester", "Guest" });
            DataGridViewCheckBoxColumn cCheck = new DataGridViewCheckBoxColumn { HeaderText = "CheckBox column" };
            DataGridViewButtonColumn cButton = new DataGridViewButtonColumn { HeaderText = "Button column", Text = "Ping", UseColumnTextForButtonValue = true };
            DataGridViewLinkColumn cLink = new DataGridViewLinkColumn { HeaderText = "Link column", Text = "details", UseColumnTextForLinkValue = true };
            DataGridViewImageColumn cImage = new DataGridViewImageColumn { HeaderText = "Image column", ImageLayout = DataGridViewImageCellLayout.Zoom };
            dg.Columns.AddRange(cText, cCombo, cCheck, cButton, cLink, cImage);
            dg.Rows.Add("Ada Lovelace", "Developer", true, null, null, icons.Images[0]);
            dg.Rows.Add("Alan Turing", "Tester", false, null, null, icons.Images[1]);
            dg.Rows.Add("Grace Hopper", "Admin", true, null, null, icons.Images[2]);
            dg.CellClick += (s2, e2) => { if (e2.RowIndex >= 0 && e2.ColumnIndex == cButton.Index) SetStatus("Grid Button cell on row " + e2.RowIndex + ": " + dg.Rows[e2.RowIndex].Cells[cText.Index].Value); };
            dg.CellContentClick += (s2, e2) => { if (e2.RowIndex >= 0 && e2.ColumnIndex == cLink.Index) SetStatus("Grid Link cell clicked: " + dg.Rows[e2.RowIndex].Cells[cText.Index].Value); };
            dg.CellValueChanged += (s2, e2) => { if (e2.RowIndex >= 0 && e2.ColumnIndex == cCheck.Index) SetStatus("Grid CheckBox cell: " + dg.Rows[e2.RowIndex].Cells[cText.Index].Value + " active = " + dg.Rows[e2.RowIndex].Cells[cCheck.Index].Value); };
            AddFillRow(t, "DataGridView column types:", dg, 130, "Text, ComboBox, CheckBox, Button, Link and Image columns in one unbound grid - toggle a checkbox, click a button or a link");
            Person bound = new Person("Grace Hopper", 85, "Arlington");
            TextBox bName = new TextBox { Width = 150 }; bName.DataBindings.Add("Text", bound, "Name");
            NumericUpDown bAge = new NumericUpDown { Minimum = 0, Maximum = 130, Width = 80 }; bAge.DataBindings.Add("Value", bound, "Age");
            TextBox bCity = new TextBox { Width = 150 }; bCity.DataBindings.Add("Text", bound, "City");
            Button bRead = new Button { Text = "Read object back", AutoSize = true };
            bRead.Click += (s, e) => SetStatus(string.Format("Bound Person now: {0}, {1}, {2}", bound.Name, bound.Age, bound.City));
            AddRow(t, "DataBindings:", Flow(bName, bAge, bCity, bRead), "Two-way bindings to a plain object - edit the boxes, then read the object back");
            Button fxOp = new Button { Text = "Opacity 60%", AutoSize = true };
            fxOp.Click += (s, e) => { Form f = new Form { Text = "Form.Opacity demo", StartPosition = FormStartPosition.CenterParent, Opacity = 0.6D, ClientSize = new Size(320, 130) }; f.Controls.Add(new Label { Text = "This window is 60% opaque.", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter }); f.ShowDialog(this); };
            Button fxTop = new Button { Text = "TopMost window", AutoSize = true };
            fxTop.Click += (s, e) => { Form f = new Form { Text = "Form.TopMost demo", TopMost = true, StartPosition = FormStartPosition.Manual, Location = new Point(Left + 40, Bottom + 8), ClientSize = new Size(320, 110) }; f.Controls.Add(new Label { Text = "I float above every window.", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter }); f.Show(this); };
            Button fxNone = new Button { Text = "Borderless form", AutoSize = true };
            fxNone.Click += (s, e) => { Form f = new Form { Text = "Borderless", FormBorderStyle = FormBorderStyle.None, BackColor = Color.FromArgb(32, 32, 48), StartPosition = FormStartPosition.CenterParent, ClientSize = new Size(340, 150) }; Label l = new Label { Text = "FormBorderStyle.None\r\n(double-click to close)", Dock = DockStyle.Fill, ForeColor = Color.White, TextAlign = ContentAlignment.MiddleCenter }; l.DoubleClick += (s2, e2) => f.Close(); f.Controls.Add(l); f.ShowDialog(this); };
            Button fxMdi = new Button { Text = "MDI playground...", AutoSize = true };
            fxMdi.Click += (s, e) => { MdiPlayground pf = new MdiPlayground(); pf.Show(this); SetStatus("MDI playground opened - try File > New child and the Window menu"); };
            AddRow(t, "Form extras & MDI:", Flow(fxOp, fxTop, fxNone, fxMdi), "Form Opacity, TopMost, borderless windows, and classic MDI with IsMdiContainer");
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private static Bitmap BuildDemoBitmap(int w, int h)
        {
            Bitmap bmp = new Bitmap(w, h);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                using (LinearGradientBrush lg = new LinearGradientBrush(new Rectangle(0, 0, w, h), Color.MidnightBlue, Color.LightSkyBlue, LinearGradientMode.Vertical)) { g.FillRectangle(lg, 0, 0, w, h); }
                Random r = new Random(7);
                for (int i = 0; i < 28; i++)
                {
                    int d = 8 + r.Next(24); int x = r.Next(w - d); int y = r.Next(h - d);
                    using (SolidBrush b = new SolidBrush(Color.FromArgb(150 + r.Next(105), r.Next(256), r.Next(256), r.Next(256)))) { g.FillEllipse(b, x, y, d, d); }
                }
                using (Font f = new Font("Segoe UI", 11F, FontStyle.Bold)) { g.DrawString("Runtime-generated bitmap", f, Brushes.White, 8, h - 30); }
                g.DrawRectangle(Pens.White, 1, 1, w - 3, h - 3);
            }
            return bmp;
        }
        private void PlayTone(double startHz, double endHz, int milliseconds, double volume)
        {
            try
            {
                SoundPlayer sp = new SoundPlayer(BuildToneWav(startHz, endHz, milliseconds, volume));
                sp.Play();
                SetStatus("SoundPlayer: " + startHz.ToString("0") + " Hz tone, " + milliseconds + " ms");
            }
            catch (Exception ex) { SetStatus("Sound failed: " + ex.Message); }
        }
        private static MemoryStream BuildToneWav(double startHz, double endHz, int milliseconds, double volume)
        {
            const int rate = 8000;
            int n = Math.Max(1, (int)(rate * milliseconds / 1000.0));
            MemoryStream wav = new MemoryStream();
            using (BinaryWriter w = new BinaryWriter(wav, System.Text.Encoding.ASCII, true))
            {
                w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + n * 2);
                w.Write(System.Text.Encoding.ASCII.GetBytes("WAVE"));
                w.Write(System.Text.Encoding.ASCII.GetBytes("fmt ")); w.Write(16); w.Write((short)1); w.Write((short)1);
                w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
                w.Write(System.Text.Encoding.ASCII.GetBytes("data")); w.Write(n * 2);
                double phase = 0;
                for (int i = 0; i < n; i++)
                {
                    double frac = (double)i / n;
                    double f = startHz + (endHz - startHz) * frac;
                    phase += 2.0 * Math.PI * f / rate;
                    double smp = Math.Sin(phase) * volume;
                    if (frac < 0.04) { smp *= frac / 0.04; }
                    if (frac > 0.96) { smp *= (1.0 - frac) / 0.04; }
                    w.Write((short)(smp * 32767.0));
                }
            }
            wav.Position = 0;
            return wav;
        }
        private void DrawShowcasePage(Graphics g, Rectangle area, int pageNo)
        {
            using (Font title = new Font("Segoe UI", 17F, FontStyle.Bold))
            using (Font body = new Font("Segoe UI", 10F))
            using (Font small = new Font("Segoe UI", 8F, FontStyle.Italic))
            {
                g.DrawString("WinForms Showcase - page " + pageNo + " of 2", title, Brushes.Indigo, area.Left, area.Top);
                g.DrawString("Drawn by PrintDocument.PrintPage at " + DateTime.Now, small, Brushes.Gray, area.Left, area.Top + 34);
                float y = area.Top + 72;
                if (pageNo == 1)
                {
                    string[] names = new string[] { "Ada Lovelace", "Alan Turing", "Grace Hopper", "Linus Torvalds" };
                    int[] ages = new int[] { 36, 41, 85, 54 };
                    string[] cities = new string[] { "London", "Wilmslow", "Arlington", "Portland" };
                    using (Pen lp = new Pen(Color.Gray)) { g.DrawLine(lp, area.Left, y - 6, area.Right, y - 6); }
                    for (int i = 0; i < names.Length; i++)
                    {
                        g.DrawString(names[i], body, Brushes.Black, area.Left, y);
                        g.DrawString(ages[i].ToString(), body, Brushes.Black, area.Left + 230, y);
                        g.DrawString(cities[i], body, Brushes.Black, area.Left + 290, y);
                        y += 24;
                    }
                }
                else
                {
                    g.DrawString("This is page 2 - it exists because PrintPageEventArgs.HasMorePages was true.", body, Brushes.Black, area.Left, y);
                    g.DrawEllipse(Pens.Indigo, area.Left + 40, y + 40, 180, 110);
                    g.DrawString("GDI+ works on paper too", small, Brushes.Indigo, area.Left + 40, y + 160);
                }
                g.DrawString("Footer - WinForms Control Showcase", small, Brushes.Gray, area.Left, area.Bottom - 24);
            }
        }
        private void BuildTray()
        {
            tray = new NotifyIcon { Icon = SystemIcons.Information, Text = "WinForms Control Showcase", Visible = true };
            ContextMenuStrip trayMenu = new ContextMenuStrip();
            trayMenu.Items.Add(new ToolStripMenuItem("Show balloon", null, (s, e) => tray.ShowBalloonTip(3000, "WinForms Showcase", "Straight from the NotifyIcon context menu.", ToolTipIcon.Info)));
            trayMenu.Items.Add(new ToolStripMenuItem("Restore window", null, (s, e) => { if (WindowState == FormWindowState.Minimized) { WindowState = FormWindowState.Normal; } Activate(); }));
            trayMenu.Items.Add(new ToolStripSeparator());
            trayMenu.Items.Add(new ToolStripMenuItem("Exit", null, (s, e) => Close()));
            tray.ContextMenuStrip = trayMenu;
            tray.DoubleClick += (s, e) => { if (WindowState == FormWindowState.Minimized) { WindowState = FormWindowState.Normal; } Activate(); };
            FormClosed += (s, e) => { try { tray.Visible = false; tray.Dispose(); } catch { } };
        }
        private void BuildWorker()
        {
            worker = new BackgroundWorker { WorkerReportsProgress = true, WorkerSupportsCancellation = true };
            worker.DoWork += (s, e) =>
            {
                string payload = (string)e.Argument;
                for (int i = 1; i <= 100; i++)
                {
                    if (worker.CancellationPending) { e.Cancel = true; return; }
                    Thread.Sleep(40);
                    int pct = i;
                    string stage = payload;
                    worker.ReportProgress(pct, stage);
                }
                e.Result = payload.ToUpperInvariant();
            };
            worker.ProgressChanged += (s, e) => { workerBar.Value = e.ProgressPercentage; workerState.Text = e.UserState + " - " + e.ProgressPercentage + "%"; stProg.Value = e.ProgressPercentage; };
            worker.RunWorkerCompleted += (s, e) =>
            {
                workerBtn.Enabled = true; cancelBtn.Enabled = false; stProg.Value = 0;
                if (e.Error != null) { workerState.Text = "error: " + e.Error.Message; SetStatus("BackgroundWorker error: " + e.Error.Message); }
                else if (e.Cancelled) { workerState.Text = "cancelled"; SetStatus("BackgroundWorker cancelled"); }
                else { workerState.Text = "done: " + e.Result; SetStatus("BackgroundWorker finished: " + e.Result); }
            };
        }
        private void ShowOpenDialog()
        {
            using (OpenFileDialog ofd = new OpenFileDialog { Title = "Open a file (nothing is actually loaded)", Filter = "Text files (*.txt)|*.txt|Rich text (*.rtf)|*.rtf|All files (*.*)|*.*", RestoreDirectory = true })
            {
                if (ofd.ShowDialog(this) == DialogResult.OK) { SetStatus("OpenFileDialog picked: " + ofd.FileName); }
                else { SetStatus("OpenFileDialog cancelled"); }
            }
        }
        private void ShowSaveDialog()
        {
            using (SaveFileDialog sfd = new SaveFileDialog { Title = "Save a file (nothing is actually written)", Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*", OverwritePrompt = true, AddExtension = true })
            {
                if (sfd.ShowDialog(this) == DialogResult.OK) { SetStatus("SaveFileDialog target: " + sfd.FileName); }
                else { SetStatus("SaveFileDialog cancelled"); }
            }
        }
        private void ShowAbout(){ using (AboutBox ab = new AboutBox()) { ab.ShowDialog(this); } }
        private void ShowMsgGallery()
        {
            MessageBox.Show(this, "A plain OK information box.", "MessageBox gallery", MessageBoxButtons.OK, MessageBoxIcon.Information);
            DialogResult r = MessageBox.Show(this, "Yes / No / Cancel with the Question icon.", "MessageBox gallery", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            SetStatus("MessageBox returned: " + r);
            MessageBox.Show(this, "Exclamation warning.", "MessageBox gallery", MessageBoxButtons.OK, MessageBoxIcon.Exclamation);
            DialogResult r2 = MessageBox.Show(this, "Abort / Retry / Ignore with the Error icon and Button3 as default.", "MessageBox gallery", MessageBoxButtons.AbortRetryIgnore, MessageBoxIcon.Error, MessageBoxDefaultButton.Button3);
            SetStatus("Final MessageBox returned: " + r2);
        }
        private void ShowPrintPreview()
        {
            PrintDocument pd = new PrintDocument { DocumentName = "WinFormsShowcase" };
            int page = 0;
            pd.BeginPrint += (s, e) => page = 0;
            pd.PrintPage += (s, e) => { page++; DrawShowcasePage(e.Graphics, e.MarginBounds, page); e.HasMorePages = page < 2; };
            using (PrintPreviewDialog ppd = new PrintPreviewDialog { Document = pd, Width = 760, Height = 520, StartPosition = FormStartPosition.CenterParent })
            {
                ppd.ShowDialog(this);
            }
            SetStatus("PrintPreviewDialog closed");
        }
        private string BuildRtf()
        {
            return @"{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Segoe UI;}}{\colortbl;\red180\green30\blue30;\red30\green110\blue50;\red40\green70\blue180;}\f0\fs20 This is a \b RichTextBox\b0  rendering \i hand-written RTF\i0  built entirely from a C# string.\par {\cf1 Warm red}, {\cf2 forest green} and {\cf3 deep blue} runs.\par\fs28 A bigger line\par\fs16 a smaller line\par\fs20\tab A tab stop, and\line a forced line break.\par}";
        }
    }
}
'@
 $projWf=$projWf.Replace('__APPNAME__',$Name)
 $progCs=$progCs.Replace('__APPNAME__',$Name)
 $mainCs=$mainCs.Replace('__APPNAME__',$Name)
 $projDir=Join-Path $Dir $Name
 New-Item -ItemType Directory -Force -Path $projDir | Out-Null
 [IO.File]::WriteAllText((Join-Path $projDir ($Name+'.csproj')),$projWf)
 [IO.File]::WriteAllText((Join-Path $projDir 'Program.cs'),$progCs)
 [IO.File]::WriteAllText((Join-Path $projDir 'MainForm.cs'),$mainCs)
 Write-Ok "Source written: $projDir"
 return $projDir
}

# ---------------- main ----------------
try{
    Initialize-Tls
    if($ProjectType -eq 'Auto'){ $ProjectType='WinForms' }
    $safeName=Get-SafeName -n $ProjectName
    if([string]::IsNullOrWhiteSpace($BaseDir)){ $targetRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WinFormsShowcase' } else { $targetRoot=$BaseDir }
    Write-Stage 'Setup' "Project: $safeName | Type: $ProjectType | Folder: $targetRoot"
    Test-DiskSpace -Path $targetRoot

    $Script:StageName='Writing source'
    $projDir=Write-SourceFiles -Dir $targetRoot -Name $safeName
    $projFile=Join-Path $projDir ($safeName+'.csproj')
    foreach($sub in @('bin','obj')){ $stale=Join-Path $projDir $sub; if(Test-Path -LiteralPath $stale){ [void](Remove-Folder -Path $stale) } }

    $Script:StageName='Locating .NET 8 SDK'
    Write-Stage $Script:StageName 'Looking for an installed .NET 8 SDK...'
    $dotnet=Find-DotNetSdk
    if($dotnet){ Write-Ok "Found .NET 8 SDK: $dotnet" }
    else{
        Write-Warn2 'No usable .NET 8 SDK found - installing it user-local (no admin rights needed).'
        Install-DotNetSdk
        $dotnet=Join-Path $Script:DotnetDir 'dotnet.exe'
    }
    Set-DotNetEnv -Dir (Split-Path -Parent $dotnet)
    if(-not (Test-SdkWorks -DotNetPath $dotnet)){ Throw-Code 4 "The dotnet executable at '$dotnet' did not respond with a working .NET 8 SDK." }

    $Script:StageName='Publishing'
    Write-Stage $Script:StageName 'Publishing a self-contained single-file Release build (first run can take a minute)...'
    $pubDir=Join-Path $projDir 'publish'
    Invoke-DotNet -ExePath $dotnet -FailCode 6 -CliArgs @('publish',$projFile,'-c','Release','-o',$pubDir)
    $exe=Join-Path $pubDir ($safeName+'.exe')
    if(-not (Test-Path -LiteralPath $exe)){ Throw-Code 7 "Publish completed but the exe was not found at '$exe'." }
    Write-Ok "Build OK: $exe"

    if($NoLaunch){
        Write-Info 'NoLaunch was specified - the app was NOT started.'
        Write-Host "  Exe: $exe" -ForegroundColor White
    }else{
        Start-Process -FilePath $exe -WorkingDirectory $pubDir
        Write-Ok "Launched: $safeName.exe"
    }
    Write-Host ''
    Write-Ok 'Done - 13 tabs, 80+ WinForms controls, zero designers, zero NuGet packages.'
    exit 0
}
catch{
    Write-Err2 ("FAILED: "+$_.Exception.Message)
    exit 1
}
