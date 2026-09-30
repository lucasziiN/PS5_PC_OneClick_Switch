// PS5 / PC switch tray app.
// Built by Install.ps1 with the .NET Framework C# compiler that ships with Windows (C# 5, no SDK needed).
// It only watches the PS5 and launches the PowerShell switches (PS5-Mode.ps1 / PC-Mode.ps1 / Toggle.ps1),
// so PowerShell runs only while a switch is in progress.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static void Main()
    {
        bool isOnlyInstance;
        using (new Mutex(true, @"Local\PS5PCTray", out isOnlyInstance))
        {
            if (!isOnlyInstance) return;
            Application.EnableVisualStyles();
            TrayApp app;
            try
            {
                app = new TrayApp(AppDomain.CurrentDomain.BaseDirectory);
            }
            catch (Exception error)
            {
                MessageBox.Show("PS5 / PC switch can't start:\n\n" + error.Message, "PS5 / PC switch",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            Application.Run(app);
        }
    }
}

sealed class TrayApp : ApplicationContext
{
    const int TickMs = 100;             // replies are read every tick
    const int ProbeEveryTicks = 5;      // one PS5 status probe every 500 ms
    const int ReplyStaleSeconds = 5;    // no reply for this long -> PS5 shown as "not answering"
    const int DiscoveryPort = 9302;     // PS5 discovery service; same query as 'ps5-remoteplay status'
    const string StandbyStatusCode = "620";
    const int SioUdpConnReset = -1744830452;  // stops Windows reporting ICMP "port unreachable" as a receive error
    const string SwitchMutexName = @"Local\PS5PCOneClickSwitch";  // held by Common.ps1 while a switch runs
    static readonly byte[] DiscoveryProbe =
        Encoding.ASCII.GetBytes("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n");

    readonly string root, configFile, stateFile, logFile, startupShortcut;
    readonly NotifyIcon notifyIcon = new NotifyIcon();
    readonly ToolStripMenuItem statusItem, ps5Item, pcItem, autoWakeItem, autoRestItem, autostartItem;
    readonly Icon pcIcon, ps5Icon, busyIcon;
    readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    readonly UdpClient udp;
    readonly IPEndPoint ps5Endpoint;

    string mode = "PC";                 // from state.txt, written by every switch
    string ps5State;                    // last definite PS5 reply: "Awake" or "Standby"
    DateTime lastReplyUtc = DateTime.MinValue;
    DateTime stateFileStamp = DateTime.MinValue;
    Process switchProcess;              // running switch started by this app
    int tick;
    string displayKey = "";             // last icon/tooltip shown; avoids redundant shell updates
    string lastTickError = "";          // last status-check error; logged once, not every tick

    public TrayApp(string rootDirectory)
    {
        root = rootDirectory;
        configFile = Path.Combine(root, "config.json");
        stateFile = Path.Combine(root, "state.txt");
        logFile = Path.Combine(root, @"logs\switch.log");
        startupShortcut = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "PS5 PC Switch.lnk");

        if (!File.Exists(configFile)) throw new FileNotFoundException("config.json not found in " + root + ". Run Install.ps1 first.");
        Dictionary<string, object> config = ReadConfig();
        object ps5Ip;
        if (!config.TryGetValue("PS5IP", out ps5Ip)) throw new InvalidDataException("config.json has no PS5IP. Run Install.ps1.");
        ps5Endpoint = new IPEndPoint(IPAddress.Parse(ps5Ip.ToString()), DiscoveryPort);
        udp = new UdpClient(0);
        udp.Client.IOControl(SioUdpConnReset, new byte[] { 0, 0, 0, 0 }, null);

        pcIcon = MakeIcon("PC", Color.FromArgb(0x2E, 0x8B, 0x57));
        ps5Icon = MakeIcon("PS5", Color.FromArgb(0x00, 0x43, 0x9C));
        busyIcon = MakeIcon("...", Color.FromArgb(0xD9, 0x8C, 0x00));

        var menu = new ContextMenuStrip();
        statusItem = AddItem(menu, "Now: ...", null);
        statusItem.Enabled = false;
        menu.Items.Add(new ToolStripSeparator());
        ps5Item = AddItem(menu, "Switch to PS5 mode", delegate { StartSwitch("PS5-Mode.ps1", ""); });
        pcItem = AddItem(menu, "Switch to PC mode", delegate { StartSwitch("PC-Mode.ps1", ""); });
        menu.Items.Add(new ToolStripSeparator());
        autoWakeItem = AddCheckItem(menu, "Switch to PS5 mode when the PS5 turns on",
            ConfigFlag(config, "AutoPS5OnWake", true), delegate { SaveOption("AutoPS5OnWake", autoWakeItem.Checked); });
        autoRestItem = AddCheckItem(menu, "Switch to PC mode when the PS5 goes to Rest Mode",
            ConfigFlag(config, "AutoPCOnStandby", false), delegate { SaveOption("AutoPCOnStandby", autoRestItem.Checked); });
        autostartItem = AddCheckItem(menu, "Start with Windows", File.Exists(startupShortcut),
            delegate { SetAutostart(autostartItem.Checked); });
        menu.Items.Add(new ToolStripSeparator());
        AddItem(menu, "Open log", delegate { if (File.Exists(logFile)) Process.Start("notepad.exe", Quote(logFile)); });
        AddItem(menu, "Run diagnostics", delegate {
            Process.Start("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File " + Quote(Path.Combine(root, "Diagnostics.ps1")));
        });
        menu.Items.Add(new ToolStripSeparator());
        AddItem(menu, "Exit", delegate { ExitThread(); });

        notifyIcon.ContextMenuStrip = menu;
        notifyIcon.DoubleClick += delegate { Safely("Toggle", delegate { StartSwitch("Toggle.ps1", ""); }); };
        notifyIcon.Icon = pcIcon;
        notifyIcon.Visible = true;

        bool isFirstRun = !File.Exists(logFile) || !File.ReadAllText(logFile).Contains("Tray started");
        UpdateModeFromStateFile();
        Log("Tray started: " + mode + " mode, watching PS5 at " + ps5Endpoint.Address + ".");
        UpdateDisplay();
        if (isFirstRun)
            notifyIcon.ShowBalloonTip(6000, "PS5 / PC switch", "Running in the tray. Right-click for options, double-click to toggle.", ToolTipIcon.Info);

        timer.Interval = TickMs;
        timer.Tick += delegate { OnTimerTick(); };
        timer.Start();
    }

    // ---------------------------------------------------------------- watching

    void OnTimerTick()
    {
        try
        {
            tick++;
            string state = ReadPS5Replies();
            if (state != null)
            {
                lastReplyUtc = DateTime.UtcNow;
                if (state != ps5State)
                {
                    string previous = ps5State;
                    ps5State = state;
                    if (previous == null) Log("PS5 state: " + state);
                    else OnPS5Transition(previous, state);
                }
            }
            if (tick % ProbeEveryTicks == 0)
            {
                udp.Send(DiscoveryProbe, DiscoveryProbe.Length, ps5Endpoint);
                UpdateModeFromStateFile();
            }
            if (switchProcess != null && switchProcess.HasExited)
            {
                switchProcess.Dispose();
                switchProcess = null;
                UpdateModeFromStateFile();
            }
            UpdateDisplay();
            lastTickError = "";
        }
        catch (Exception error)
        {
            // Runs 10x per second: log a failure once, not on every tick.
            if (error.Message != lastTickError)
            {
                lastTickError = error.Message;
                Log("Tray: status check failed: " + error.Message, "WARN");
            }
        }
    }

    // Reads every discovery reply that has arrived; returns the newest state or null. Never blocks.
    string ReadPS5Replies()
    {
        string state = null;
        var sender = new IPEndPoint(IPAddress.Any, 0);
        while (udp.Available > 0)
        {
            byte[] reply = udp.Receive(ref sender);
            if (!sender.Address.Equals(ps5Endpoint.Address)) continue;
            string statusLine = Encoding.UTF8.GetString(reply).Split('\n')[0].Trim();  // "HTTP/1.1 620 Server Standby"
            if (!statusLine.StartsWith("HTTP")) continue;
            string[] parts = statusLine.Split(' ');
            state = parts.Length > 1 && parts[1] == StandbyStatusCode ? "Standby" : "Awake";
        }
        return state;
    }

    void OnPS5Transition(string previous, string current)
    {
        Log("PS5 state: " + previous + " -> " + current);
        // A switch that is already running (from here, a shortcut or a console) caused or handles this change.
        if (switchProcess != null || IsSwitchRunning()) { Log("A switch is already running; leaving it to that."); return; }
        Dictionary<string, object> config = ReadConfig();  // re-read so option changes apply immediately

        if (previous == "Standby" && current == "Awake")
        {
            if (!ConfigFlag(config, "AutoPS5OnWake", true)) { Log("PS5 woke up; AutoPS5OnWake is off."); return; }
            Log("PS5 woke up; running PS5 mode.");
            StartSwitch("PS5-Mode.ps1", "");
        }
        else if (previous == "Awake" && current == "Standby")
        {
            if (!ConfigFlag(config, "AutoPCOnStandby", false)) { Log("PS5 entered Rest Mode; AutoPCOnStandby is off."); return; }
            // PC-Mode.ps1 checks the real display state itself and does nothing if already in PC mode.
            Log("PS5 entered Rest Mode; running PC mode if in PS5 mode.");
            StartSwitch("PC-Mode.ps1", " -OnlyIfPS5Mode");
        }
    }

    static bool IsSwitchRunning()
    {
        using (var mutex = new Mutex(false, SwitchMutexName))
        {
            bool free;
            try { free = mutex.WaitOne(0); }
            catch (AbandonedMutexException) { free = true; }
            if (free) mutex.ReleaseMutex();
            return !free;
        }
    }

    // ---------------------------------------------------------------- actions

    void StartSwitch(string script, string extraArguments)
    {
        if (switchProcess != null) return;
        var start = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Quote(Path.Combine(root, script)) + extraArguments);
        start.UseShellExecute = false;
        start.CreateNoWindow = true;  // no console flash; error message boxes still appear
        start.WorkingDirectory = root;
        switchProcess = Process.Start(start);
        UpdateDisplay();
    }

    void SaveOption(string key, bool value)
    {
        Dictionary<string, object> config = ReadConfig();
        config[key] = value;
        File.WriteAllText(configFile, ToJson(config), Encoding.UTF8);  // UTF-8 with BOM, as PowerShell 5.1 expects
        Log("Tray: " + key + " set to " + value);
    }

    void SetAutostart(bool enabled)
    {
        if (!enabled) { File.Delete(startupShortcut); return; }
        dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
        dynamic shortcut = shell.CreateShortcut(startupShortcut);
        shortcut.TargetPath = Application.ExecutablePath;
        shortcut.WorkingDirectory = root;
        shortcut.Description = "PS5 / PC switch tray app";
        shortcut.Save();
    }

    // ---------------------------------------------------------------- display

    void UpdateDisplay()
    {
        bool busy = switchProcess != null;
        string modeText = busy ? "switching..." : mode + " mode";
        string ps5Text = (DateTime.UtcNow - lastReplyUtc).TotalSeconds > ReplyStaleSeconds ? "not answering"
            : ps5State == "Standby" ? "Rest Mode" : "on";
        string key = busy + "|" + modeText + "|" + ps5Text;
        if (key == displayKey) return;
        displayKey = key;

        notifyIcon.Icon = busy ? busyIcon : mode == "PS5" ? ps5Icon : pcIcon;
        notifyIcon.Text = "PS5 / PC switch: " + modeText + ", PS5 " + ps5Text;  // tooltip max 63 chars
        statusItem.Text = "Now: " + modeText + "   |   PS5: " + ps5Text;
        ps5Item.Enabled = !busy;
        pcItem.Enabled = !busy;
    }

    void UpdateModeFromStateFile()
    {
        if (!File.Exists(stateFile)) return;
        DateTime stamp = File.GetLastWriteTimeUtc(stateFile);
        if (stamp == stateFileStamp) return;
        stateFileStamp = stamp;
        string value = File.ReadAllText(stateFile).Trim();
        if (value == "PC" || value == "PS5") mode = value;
    }

    static Icon MakeIcon(string label, Color color)
    {
        using (var bitmap = new Bitmap(32, 32))
        {
            using (Graphics graphics = Graphics.FromImage(bitmap))
            using (var brush = new SolidBrush(color))
            using (var font = new Font("Segoe UI", 11, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var format = new StringFormat())
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                graphics.Clear(Color.Transparent);
                graphics.FillEllipse(brush, 0, 0, 31, 31);
                format.Alignment = StringAlignment.Center;
                format.LineAlignment = StringAlignment.Center;
                graphics.DrawString(label, font, Brushes.White, new RectangleF(0, 0, 32, 32), format);
            }
            return Icon.FromHandle(bitmap.GetHicon());
        }
    }

    // ---------------------------------------------------------------- helpers

    ToolStripMenuItem AddItem(ContextMenuStrip menu, string text, Action onClick)
    {
        var item = new ToolStripMenuItem(text);
        if (onClick != null) item.Click += delegate { Safely(text, onClick); };
        menu.Items.Add(item);
        return item;
    }

    ToolStripMenuItem AddCheckItem(ContextMenuStrip menu, string text, bool isChecked, Action onClick)
    {
        ToolStripMenuItem item = AddItem(menu, text, onClick);
        item.CheckOnClick = true;
        item.Checked = isChecked;
        return item;
    }

    void Safely(string what, Action action)
    {
        try { action(); }
        catch (Exception error)
        {
            Log("Tray: " + what + " failed: " + error.Message, "WARN");
            notifyIcon.ShowBalloonTip(5000, "PS5 / PC switch", what + " failed: " + error.Message, ToolTipIcon.Warning);
        }
    }

    Dictionary<string, object> ReadConfig()
    {
        var config = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(configFile)) as Dictionary<string, object>;
        if (config == null) throw new InvalidDataException("config.json is not a JSON object.");
        return config;
    }

    static bool ConfigFlag(Dictionary<string, object> config, string key, bool fallback)
    {
        object value;
        return config.TryGetValue(key, out value) && value is bool ? (bool)value : fallback;
    }

    // config.json is flat; written in the same layout PowerShell's ConvertTo-Json uses.
    static string ToJson(Dictionary<string, object> values)
    {
        var serializer = new JavaScriptSerializer();
        var json = new StringBuilder("{\r\n");
        int index = 0;
        foreach (KeyValuePair<string, object> pair in values)
        {
            json.Append("    ").Append(serializer.Serialize(pair.Key)).Append(":  ").Append(serializer.Serialize(pair.Value));
            if (++index < values.Count) json.Append(',');
            json.Append("\r\n");
        }
        return json.Append("}\r\n").ToString();
    }

    static string Quote(string path) { return "\"" + path + "\""; }

    void Log(string message, string level = "INFO")
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(logFile));
            File.AppendAllText(logFile, string.Format("{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}\r\n", DateTime.Now, level, message));
        }
        catch (IOException) { }  // a switch script may be writing at the same moment; the log is best-effort
    }

    protected override void ExitThreadCore()
    {
        timer.Stop();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        udp.Close();
        Log("Tray stopped.");
        base.ExitThreadCore();
    }
}
