# MISSION
Write ONE complete, self-contained PowerShell script (save-as .ps1) that, when run on any Windows 10/11 machine, generates, builds, publishes, and launches a .NET 8 WinForms "Control Showcase" application — 13 tabs, 80+ controls/components, written 100% in code with zero designer files and zero NuGet packages. Tagline: "One window. Every control. Zero designers."

Output the ENTIRE script in a single code block, ready to save and run.

# POWERSHELL LAYER (the scaffold)
- param block: $ProjectName (default 'WinFormsShowcase'), [ValidateSet('Auto','WinForms')]$ProjectType (default 'WinForms'), $BaseDir, -NoLaunch switch, $MaxRetries (default 3)
- $ErrorActionPreference='Stop'; colored Write helpers (Info=Cyan, Ok=Green, Warn=Yellow, Err=Red); Write-Stage section headers; Throw-Code numbered failures with actionable, cause-suggesting messages
- Required functions and behaviors:
  - Initialize-Tls (force TLS 1.2/1.3)
  - Get-SafeName: strip invalid chars, prefix leading digits, PascalCase, guard against ~80 C# keywords
  - Remove-Folder: 3 retries, reset file attributes, cmd rd /s /q fallback, warn if still present
  - Find-DotNetSdk / Test-SdkWorks: check %LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe then PATH dotnet.exe; must expose an 8.x SDK
  - Save-FileWithRetry: MaxRetries attempts, HTML-error-page detection, optional $env:HTTPS_PROXY, backoff sleeps
  - Install-DotNetSdk: download dotnet-install.ps1 (dot.net, then raw.githubusercontent.com fallback), install .NET 8 SDK user-local (no elevation) to %LOCALAPPDATA%\Microsoft\dotnet
  - Set-DotNetEnv (DOTNET_ROOT, MULTILEVEL_LOOKUP=0, path prepend), Invoke-DotNet (nonzero exit -> Throw-Code), Test-DiskSpace (hard fail < 0.5 GB, warn < 2 GB)
- Main flow: sanitize name -> default BaseDir to Documents\WinFormsShowcase -> write sources -> delete stale bin/obj -> locate/install SDK -> dotnet publish -c Release -o <proj>\publish -> verify exe exists -> Start-Process unless -NoLaunch -> exit 0, or red FAILED + exit 1 in catch
- All C# embedded in single-quoted here-strings (@' ... '@) with a __APPNAME__ placeholder replaced per file. CRITICAL: no line inside any here-string may start with '@.

# GENERATED APP - PROJECT + PROGRAM
- .csproj: net8.0-windows, OutputType WinExe, UseWindowsForms true, ImplicitUsings enable, Nullable disable, SelfContained, RuntimeIdentifier win-x64, PublishSingleFile, IncludeNativeLibrariesForSelfExtract, EnableCompressionInSingleFile, DebugType embedded, RootNamespace/AssemblyName = app name, SatelliteResourceLanguages en
- Program.cs: [STAThread], EnableVisualStyles, SetCompatibleTextRenderingDefault(false), SetHighDpiMode(PerMonitorV2), Application.ThreadException + AppDomain.UnhandledException message-box handlers, Application.Run(new MainForm()) wrapped in try/catch

# GENERATED APP - MAIN WINDOW CHROME
- MainForm: ClientSize 1180x780, MinimumSize 960x640, CenterScreen, KeyPreview, Segoe UI 9pt, SystemIcons.Application icon
- MenuStrip: File (New/Ctrl+N, Open.../Ctrl+O, Save As.../Ctrl+S, Exit/Alt+F4), View (auto-generated "Go to tab N" item per tab after BuildTabs), Help > About
- ToolStrip: New/Open/Save buttons (SystemIcons.ToBitmap, ImageAndText), Find label + ToolStripTextBox (Enter handled) + ToolStripComboBox, ToolStripDropDownButton, ToolStripSplitButton, ToolStripProgressBar, marquee toggle button
- StatusStrip: spring status label, ToolStripProgressBar, bordered clock label driven by a 1s WinForms Timer
- NotifyIcon: Information icon, context menu (balloon, restore, exit), double-click restore, hidden+disposed on FormClosed
- ToolTip component (AutoPopDelay 8000/InitialDelay 400/ReshowDelay 150), ErrorProvider, HelpProvider, runtime-built ImageList (16x16 GDI+ colored circles)
- Layout helpers: Grid2() = auto-size 2-column TableLayoutPanel; AddHeader/AddRow/AddFillRow (left label column + right control column, ToolTips applied to both); Flow() = wrapping FlowLayoutPanel
- Helper classes: Person (Category/Description attributes for PropertyGrid, one Browsable(false) property), LabeledSlider : UserControl, AboutBox : Form (modal dialog), [ComVisible] WebBridge (wraps an Action<string> callback), DoubleBufferPanel : Panel, PaintCanvas : Panel (custom animated OnPaint), MdiPlayground : Form (MDI parent)
- Status bar text on startup: "Ready - 13 tabs, 80+ controls. Hover for ToolTips, press F1 for HelpProvider, right-click things."

# THE 13 TABS (complete inventory - include every listed item)
1. Basics: Label (plain/Fixed3D/FixedSingle), LinkLabel (HoverUnderline), TextBox with PlaceholderText, MaskedTextBox "(999) 000-0000" + live MaskCompleted indicator, multiline TextBox with scrollbars, RichTextBox rendering hand-written RTF (colors, sizes, tab, forced line break), Button FlatStyle.Flat + Popup, MessageBox gallery launcher, drag-drop TextBox accepting text and FileDrop
2. Selection: ThreeState CheckBox, Appearance.Button CheckBox, RadioButton trio inside GroupBox, DropDownList ComboBox, AutoComplete SuggestAppend ComboBox (fruit list), MultiExtended ListBox, CheckedListBox (CheckOnClick), DomainUpDown, NumericUpDown (DecimalPlaces, Increment 0.5, ThousandsSeparator), TrackBar (TickStyle.Both)
3. Date & Time: DateTimePicker Long; DateTimePicker Custom "dddd, dd MMM yyyy  HH:mm" + ShowUpDown; MonthCalendar (MaxSelectionCount 7, FirstDayOfWeek Monday, BoldedDates, DateSelected -> live range label)
4. Containers: SplitContainer (draggable splitter, SplitterDistance set on first resize, ListBox + multiline TextBox inside), FlowLayoutPanel (10 wrapping buttons), TableLayoutPanel 3x3 percent grid, AutoScroll Panel (20 labels), nested TabControl (3 inner pages), GroupBox
5. Data Views: ListView Details (3 columns, ListViewGroups Documents/Media, CheckBoxes, FullRowSelect, GridLines) + buttons switching all four View modes; TreeView (ImageList icons, CheckBoxes, AfterSelect shows FullPath, AfterCheck); DataTable + BindingSource + BindingNavigator + DataGridView (AllowUserToAddRows, DataError handler); PropertyGrid showing Person
6. Menus & Toolbars: ContextMenuStrip host panel (Cut/Copy/Paste, separator, CheckOnClick "Snap to grid", right-click to open); inner ToolStrip with nested ToolStripDropDownButton (2 levels deep), ToolStripSplitButton, ToolStripTextBox, ToolStripComboBox, ToolStripProgressBar; mini StatusStrip (spring label + bordered version label)
7. Dialogs: target Label receiving ColorDialog/FontDialog results; OpenFileDialog; SaveFileDialog; FolderBrowserDialog; ColorDialog (FullOpen); FontDialog; PrintPreviewDialog; MessageBox gallery (OK, YesNoCancel, Exclamation, AbortRetryIgnore with Button3 default); custom modal AboutBox (DialogResult reported)
8. Background & Components: 1s Timer label (tick count + wall clock); ProgressBar Blocks/Marquee toggle; BackgroundWorker (RunWorkerAsync with payload, ReportProgress updating two progress bars + state label, CancelAsync, RunWorkerCompleted distinguishing error/cancel/result); NotifyIcon balloon button; ErrorProvider on a numeric TextBox; HelpProvider button ("click me then press F1" popup help, wired with SetHelpString only)
9. Graphics: PaintCanvas : Panel, double-buffered, ResizeRedraw — draws LinearGradient background, HatchBrush ellipse, dashed Bezier, thick gold arc, rotated/translated text, and a bouncing-ball animated by an internal Timer (checkbox to toggle); scribble pad using MouseDown/MouseMove/MouseUp into List<List<Point>> rendered only in the Paint event with per-stroke colors; Randomize-palette and Clear buttons
10. Web/Media: WebBrowser fed in-memory HTML via DocumentText (assign inside HandleCreated - tab child handles are created lazily), ObjectForScripting = ComVisible WebBridge that BeginInvokes messages to the status bar (page button calls window.external.Report), plus a C# button writing into a DOM element by id, and a Reload button; PictureBox showing a runtime GDI+-generated bitmap with buttons for all five SizeModes; SoundPlayer playing WAVs synthesized at runtime into a MemoryStream (16-bit mono 8kHz sine tones: 440 Hz, 880 Hz, rising chirp, with attack/decay envelope - no audio files); five SystemSounds buttons (Beep/Asterisk/Exclamation/Hand/Question)
11. Layout & Scroll: three HScrollBars as an RGB mixer + one VScrollBar driving preview font size, live hex-colored swatch label; Anchor/Dock playground - white stage Panel + Probe Button, radio presets Top-Left / All / Bottom-Right / None, Dock=Fill checkbox, Stage+/- resize buttons, live Anchor readout in status bar; ToolStripContainer (strips in top and right panels with visible grips, draggable between panels at runtime, RichTextBox in the ContentPanel); legacy Splitter control (docked-left panel + blue splitter bar + fill panel)
12. Components & Print: FileSystemWatcher watching %TEMP%\WinFormsShowcase_FSW for *.txt (Created/Changed/Deleted/Renamed), events marshalled to the UI thread with BeginInvoke into a capped ListBox log, EnableRaisingEvents checkbox, Create/Modify/Delete-all buttons, disposed on FormClosed; Process component - current-process stats, hidden cmd.exe run with RedirectStandardOutput + WaitForExit + Kill timeout + output shown, shell-open notepad; System.Timers.Timer at 500ms with SynchronizingObject=this and enable checkbox; PrintDocument rendering two GDI+ pages (title/table page + shapes page), embedded PrintPreviewControl, PrintDialog (UseEXDialog), PageSetupDialog that calls InvalidatePreview
13. Grid, Binding & MDI: unbound DataGridView with ALL six column types (Text, ComboBox, CheckBox, Button "Ping", Link "details", Image from the ImageList) and CellClick/CellContentClick/CellValueChanged handlers; DataBindings - a Person two-way bound to two TextBoxes + a NumericUpDown with a "read object back" button; Form effects - 60% Opacity dialog, TopMost floating window, borderless double-click-to-close form; MDI playground form - IsMdiContainer, MenuStrip with File > New child (Ctrl+N) / Close all / Exit, Window menu, colored children spawned on Shown, status label counting open children

# HARD RULES - .NET 8 COMPATIBILITY (these caused real compile failures; do not repeat them)
- ToolStripMenuItem.MdiList does NOT exist in .NET 8 WinForms. In the MDI playground, build the Window menu dynamically in a DropDownOpening handler: clear items, re-add Cascade/TileHorizontal/TileVertical/ArrangeIcons, then a separator, then one item per open MdiChild with Checked=true on ActiveMdiChild and click -> Activate().
- AnchorStyles.All does NOT exist. "All anchors" = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right.
- WebBrowser DocumentText set before the handle exists is ignored - assign it in HandleCreated (guard with a bool so it only happens once).
- FileSystemWatcher and System.Timers.Timer raise events on threadpool threads - marshal to the UI thread (BeginInvoke) or set SynchronizingObject = this; stop/dispose them on FormClosed.
- SoundPlayer requires a real WAV stream - synthesize RIFF/WAVE PCM bytes in code, never reference media files.
- Unbound DataGridView button/link columns: set UseColumnTextForButtonValue / UseColumnTextForLinkValue and Rows.Add(..., null, null, ...) for those cells.
- No async/await, no nullable-reference syntax, no C# keywords colliding with the keyword list in Get-SafeName.

# STYLE
- Construct every control in code with object initializers and lambda event handlers; single-line handlers where short; compact but readable
- Every row gets a ToolTip; every meaningful interaction updates the StatusStrip
- Console output ends with: "Done - 13 tabs, 80+ WinForms controls, zero designers, zero NuGet packages."

# SELF-CHECK BEFORE FINALIZING
1. Mentally compile the C#: verify every member against .NET 8 System.Windows.Forms (no Framework-only APIs like MdiList).
2. Verify no line inside any here-string begins with '@ (would terminate it early).
3. Confirm the View menu, startup status text, About text, and final console message all reference 13 tabs / 80+ controls.
4. Confirm the script is re-runnable: it rewrites sources and cleans bin/obj each run, and never requires admin rights or internet after the SDK is cached.
