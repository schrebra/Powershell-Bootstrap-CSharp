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
using System.Data;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Printing;
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
            SetStatus("Ready - 9 tabs, 50+ controls. Hover for ToolTips, press F1 for HelpProvider, right-click things.");
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
            AddHeader(t, "Non-visual components: Timer, BackgroundWorker, NotifyIcon, ErrorProvider, HelpProvider, sounds");
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
            AddRow(t, "ErrorProvider:", Flow(tbNumeric, new Label { Text = "type a non-number to see the icon", AutoSize = true, ForeColor = Color.Gray, Anchor = AnchorStyles.Left }), "ErrorProvider flags invalid input with a blinking icon");
            Button btnBeep = new Button { Text = "Play SystemSounds.Exclamation", AutoSize = true };
            btnBeep.Click += (s, e) => { SystemSounds.Exclamation.Play(); SetStatus("Beep!"); };
            AddRow(t, "Sound:", btnBeep, "System.Media.SystemSounds");
            hp.SetHelpString(btnBeep, "Press F1 on focused controls to see HelpProvider popups."); hp.SetShowHelp(btnBeep, true);
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private TabPage TabGraphics()
        {
            TabPage p = new TabPage("9. Graphics & Extras");
            TableLayoutPanel t = Grid2();
            AddHeader(t, "Drawing, scrolling, an embedded browser, and a custom UserControl");
            PictureBox pic = new PictureBox { Dock = DockStyle.Fill, BorderStyle = BorderStyle.FixedSingle, SizeMode = PictureBoxSizeMode.Zoom, MinimumSize = new Size(0, 150) };
            pic.Image = MakeArt();
            AddFillRow(t, "PictureBox (programmatic art):", pic, 140, "Bitmap drawn with System.Drawing at runtime");
            Button btnArt = new Button { Text = "Regenerate artwork", AutoSize = true };
            btnArt.Click += (s, e) => { Image old = pic.Image; pic.Image = MakeArt(); if (old != null) old.Dispose(); SetStatus("New artwork generated"); };
            AddRow(t, "Redraw:", btnArt, null);
            Panel sbHost = new Panel { Dock = DockStyle.Fill, Height = 120, BorderStyle = BorderStyle.FixedSingle, BackColor = Color.White };
            Label mover = new Label { Text = "Move me", BackColor = Color.IndianRed, ForeColor = Color.White, TextAlign = ContentAlignment.MiddleCenter, Size = new Size(70, 30), Location = new Point(4, 4) };
            HScrollBar hs = new HScrollBar { Dock = DockStyle.Bottom, Minimum = 0, Maximum = 300, LargeChange = 20, SmallChange = 5 };
            VScrollBar vs = new VScrollBar { Dock = DockStyle.Right, Minimum = 0, Maximum = 150, LargeChange = 20, SmallChange = 5 };
            hs.ValueChanged += (s, e) => { mover.Left = 4 + hs.Value; SetStatus("HScrollBar: " + hs.Value); };
            vs.ValueChanged += (s, e) => { mover.Top = 4 + vs.Value; SetStatus("VScrollBar: " + vs.Value); };
            sbHost.Controls.Add(mover); sbHost.Controls.Add(hs); sbHost.Controls.Add(vs);
            AddRow(t, "HScrollBar + VScrollBar:", sbHost, "Classic scrollbars moving the red box");
            WebBrowser wb = new WebBrowser { Dock = DockStyle.Fill, MinimumSize = new Size(0, 140) };
            wb.DocumentText = "<html><body style='font-family:Segoe UI;background:#f7f9fc'><h2 style='color:#204e8f'>WebBrowser control</h2><p>Rendered from an inline HTML string via <b>DocumentText</b> - no network required.</p><ul><li>Works with the legacy MSHTML engine</li><li>Great for local HTML reports</li></ul><p style='color:gray'>WinForms still ships this veteran control.</p></body></html>";
            AddFillRow(t, "WebBrowser:", wb, 130, "Embedded browser displaying inline HTML");
            LabeledSlider s1 = new LabeledSlider("Width", 10, 100, 50);
            LabeledSlider s2 = new LabeledSlider("Height", 10, 100, 75);
            Label comboLbl = new Label { Text = "Box: 50 x 75", AutoSize = true, Anchor = AnchorStyles.Left };
            EventHandler upd = (s, e) => comboLbl.Text = "Box: " + s1.Value + " x " + s2.Value;
            s1.SliderMoved += upd; s2.SliderMoved += upd;
            AddRow(t, "UserControl (custom):", Flow(s1, s2, comboLbl), "LabeledSlider : UserControl - a composite custom control");
            p.AutoScroll = true; p.Controls.Add(t);
            return p;
        }
        private string BuildRtf()
        {
            return @"{\rtf1\ansi\deff0{\fonttbl{\f0 Segoe UI;}}{\colortbl;\red192\green0\blue0;\red0\green128\blue0;\red0\green0\blue255;}\f0\fs18 RichTextBox can mix \b bold\b0 , \i italic\i0 , \cf1 colors\cf0 , and \cf3 fonts\cf0 .\line \line Bullets too:\line \bullet First item\line \bullet Second item\line \bullet Third item\line \line All written by hand in RTF - no designer required.}";
        }
        private void BuildTray()
        {
            ContextMenuStrip trayMenu = new ContextMenuStrip();
            trayMenu.Items.Add(new ToolStripMenuItem("Show balloon", null, (s, e) => tray.ShowBalloonTip(2000, "Tray menu", "Balloon from the tray context menu", ToolTipIcon.Info)));
            trayMenu.Items.Add(new ToolStripMenuItem("Exit", null, (s, e) => Close()));
            tray = new NotifyIcon { Icon = SystemIcons.Application, Text = "WinForms Control Showcase", Visible = true };
            tray.ContextMenuStrip = trayMenu;
            tray.DoubleClick += (s, e) => { Show(); WindowState = FormWindowState.Normal; Activate(); };
        }
        private void BuildWorker()
        {
            worker = new BackgroundWorker { WorkerReportsProgress = true, WorkerSupportsCancellation = true };
            worker.DoWork += (s, e) =>
            {
                BackgroundWorker w = (BackgroundWorker)s;
                for (int i = 1; i <= 50; i++)
                {
                    if (w.CancellationPending) { e.Cancel = true; return; }
                    Thread.Sleep(80);
                    w.ReportProgress(i * 2, "step " + i);
                }
                e.Result = "all 50 steps completed";
            };
            worker.ProgressChanged += (s, e) => { if (workerBar != null) workerBar.Value = Math.Min(e.ProgressPercentage, 100); SetStatus("BackgroundWorker: " + e.UserState); };
            worker.RunWorkerCompleted += (s, e) => { workerBtn.Enabled = true; cancelBtn.Enabled = false; if (e.Cancelled) { workerState.Text = "cancelled"; SetStatus("BackgroundWorker cancelled"); } else if (e.Error != null) { workerState.Text = "error"; SetStatus("BackgroundWorker failed: " + e.Error.Message); } else { workerBar.Value = 100; workerState.Text = "finished"; SetStatus("BackgroundWorker: " + e.Result); } };
        }
        private void ShowOpenDialog()
        {
            using (OpenFileDialog ofd = new OpenFileDialog { Title = "OpenFileDialog demo", Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*", CheckFileExists = true })
            { DialogResult dr = ofd.ShowDialog(this); SetStatus(dr == DialogResult.OK ? "OpenFileDialog chose: " + ofd.FileName : "OpenFileDialog cancelled"); }
        }
        private void ShowSaveDialog()
        {
            using (SaveFileDialog sfd = new SaveFileDialog { Title = "SaveFileDialog demo", Filter = "Text files (*.txt)|*.txt", FileName = "untitled.txt" })
            { DialogResult dr = sfd.ShowDialog(this); SetStatus(dr == DialogResult.OK ? "SaveFileDialog chose: " + sfd.FileName : "SaveFileDialog cancelled"); }
        }
        private void ShowAbout(){ using (AboutBox ab = new AboutBox()) ab.ShowDialog(this); }
        private void ShowPrintPreview()
        {
            PrintDocument pd = new PrintDocument();
            int page = 0;
            pd.PrintPage += (s, e) => { page++; using (Font f = new Font("Segoe UI", 16)) { e.Graphics.DrawString("PrintDocument + PrintPreviewDialog demo", f, Brushes.Navy, 60, 80); } using (Font f2 = new Font("Consolas", 10)) { e.Graphics.DrawString("Page " + page + " - generated at " + DateTime.Now.ToLongTimeString(), f2, Brushes.Black, 60, 120); } e.HasMorePages = false; };
            using (PrintPreviewDialog ppd = new PrintPreviewDialog { Document = pd, Width = 700, Height = 560 })
            { SetStatus("PrintPreviewDialog opened (no printer required for preview)"); ppd.ShowDialog(this); }
        }
        private void ShowMsgGallery()
        {
            MessageBox.Show(this, "Information icon, OK button.", "Info", MessageBoxButtons.OK, MessageBoxIcon.Information);
            MessageBox.Show(this, "Warning icon - pretend the disk is nearly full.", "Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            DialogResult r = MessageBox.Show(this, "Question with Yes/No - pick one:", "Question", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            MessageBox.Show(this, "You answered: " + r, "Result", MessageBoxButtons.OK, MessageBoxIcon.Error);
            SetStatus("MessageBox gallery done (answer was " + r + ")");
        }
        private Bitmap MakeArt()
        {
            Bitmap bmp = new Bitmap(560, 260);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (LinearGradientBrush lg = new LinearGradientBrush(new Rectangle(0, 0, bmp.Width, bmp.Height), Color.FromArgb(rng.Next(256), rng.Next(256), rng.Next(256)), Color.FromArgb(rng.Next(256), rng.Next(256), rng.Next(256)), 45F)) { g.FillRectangle(lg, 0, 0, bmp.Width, bmp.Height); }
                for (int i = 0; i < 14; i++)
                {
                    using (Pen pen = new Pen(Color.FromArgb(160, rng.Next(256), rng.Next(256), rng.Next(256)), 2F)) { g.DrawArc(pen, rng.Next(bmp.Width), rng.Next(bmp.Height), rng.Next(40, 160), rng.Next(40, 160), rng.Next(360), rng.Next(90, 300)); }
                }
                g.FillEllipse(Brushes.White, 190, 60, 180, 90);
                using (Font f = new Font("Segoe UI", 14, FontStyle.Bold)) { g.DrawString("GDI+ is alive", f, Brushes.MidnightBlue, 205, 88); }
                g.DrawRectangle(Pens.DimGray, 0, 0, bmp.Width - 1, bmp.Height - 1);
            }
            return bmp;
        }
        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (worker != null && worker.IsBusy) { worker.CancelAsync(); }
            if (clock != null) { clock.Stop(); }
            if (tray != null) { tray.Visible = false; tray.Dispose(); tray = null; }
            base.OnFormClosing(e);
        }
    }
}
'@
Set-Content -LiteralPath (Join-Path $Dir ($Name+'.csproj')) -Value $projWf.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'Program.cs') -Value $progCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'MainForm.cs') -Value $mainCs.Replace('__APPNAME__',$Name) -Encoding UTF8
foreach($f in @('Form1.cs','Form1.Designer.cs')){$fp=Join-Path $Dir $f;if(Test-Path -LiteralPath $fp){Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue}}
}
function New-Project([string]$ExePath,[string]$Name,[string]$Dir){
Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('new','winforms','-n',$Name,'-o',$Dir)
if(-not (Test-Path -LiteralPath (Join-Path $Dir ($Name+'.csproj')))){Throw-Code 4 'The template reported success but the .csproj file is missing from the project directory.'}}
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
if($BaseDir.StartsWith($env:windir,[StringComparison]::OrdinalIgnoreCase)){$fb=[Environment]::GetFolderPath('Desktop');if([string]::IsNullOrWhiteSpace($fb)){$fb=Join-Path $env:USERPROFILE 'Documents'};Write-Warn2 "Refusing to build inside the Windows directory; redirecting BaseDir to: $fb";$BaseDir=$fb}
if([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){Throw-Code 1 'The LOCALAPPDATA environment variable is not set on this machine, so no user-local install location can be determined. Check the user profile environment and re-run.'}
 $ProjectDir=Join-Path $BaseDir $ProjectName
 $PublishDir=Join-Path $ProjectDir 'publish'
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "  Bootstrap: building '$ProjectName' (WinForms control showcase, .NET 8, single-file exe)" -ForegroundColor Cyan
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
Write-Stage '4/8' 'Creating the WinForms project from the official template'
New-Project -ExePath $DotNetExe -Name $ProjectName -Dir $ProjectDir
Write-Ok 'Template scaffolded.'
 $Script:StageName='Writing sources'
Write-Stage '5/8' 'Writing WinForms showcase sources (one MainForm, 9 tabs, 50+ controls)'
Write-SourceFiles -Dir $ProjectDir -Name $ProjectName
Write-Ok 'All application source files written (csproj, Program.cs, MainForm.cs).'
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
Write-Ok 'The demo window has 9 tabs with 50+ live controls: menus, toolbars, status bars, ListView, TreeView, DataGridView,'
Write-Ok 'PropertyGrid, MonthCalendar, dialogs, BackgroundWorker, NotifyIcon, WebBrowser, custom UserControl, GDI+ art and more.'
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
