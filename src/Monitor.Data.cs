// 数据部分：采样、历史记录、规则、稳定性评级、忽略设置、实时数据存盘
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;

namespace WatchDog
{
    class ProcRow { public string Name; public int Pid; public double PrivMB, CpuMs, IoB, CpuPct, IoMBs; public int Count; }
    class Rating
    {
        public string Text, Note, Forecast, Trend; public int Level, Score;
        public Rating(string text, int level, int score, string note, string forecast, string trend)
        { Text = text; Level = level; Score = score; Note = note ?? ""; Forecast = forecast ?? ""; Trend = trend ?? ""; }
    }
    class Rule
    {
        public Dictionary<string, object> Raw;
        public string Id, Title, Target, Cause, Process, File, FixType, FixLabel, FixService, FixScript;
        public double MinMB, MinFileMB; public bool Auto;
        public static Rule From(Dictionary<string, object> d)
        {
            Rule r = new Rule(); r.Raw = d;
            r.Id = Json.Str(d, "id") ?? ""; r.Title = Json.Str(d, "title") ?? r.Id; r.Cause = Json.Str(d, "cause") ?? "";
            Dictionary<string, object> w = Json.Obj(d, "when"), f = Json.Obj(d, "fix");
            r.Process = Json.Str(w, "process"); r.File = Json.Str(w, "file");
            r.MinMB = Json.Num(w, "minMB"); r.MinFileMB = Json.Num(w, "minFileMB");
            r.FixType = Json.Str(f, "type") ?? "none"; r.FixLabel = Json.Str(f, "label") ?? "";
            r.FixService = Json.Str(f, "service"); r.FixScript = Json.Str(f, "script");
            r.Auto = Json.Bool(d, "auto");
            r.Target = Json.Str(d, "target") ?? r.Process;
            return r;
        }
    }
    class Hit { public Rule Rule; public string Why, Target; }
    class Issue { public string Title, Sub, Target, Key; public int Level; }
    class HistPt { public DateTime T; public double MB; }
    class Trend { public double Slope, R2, Growth, Span, Cv; }
    class SysRow { public DateTime T; public double UsedMB, CpuPct, RunMs, SelfCpuSec, SelfPeakMB, DiskR, DiskW; public bool HasDisk, HasSelf; }
    class IgnoreEntry { public string Key, Label, Type, Until; }

    partial class Monitor
    {
        // ---------- 设置 ----------
        string ToolDir, DataDir, RulesDir, LogFile, LiveFile;

        // 系统关键进程：不允许在界面里结束或重启
        static readonly HashSet<string> Protected = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "System", "Idle", "Registry", "smss", "csrss", "wininit", "winlogon", "services", "lsass", "LsaIso", "svchost",
            "dwm", "Memory Compression", "MemCompression", "fontdrvhost", "MsMpEng", "audiodg", "sihost", "ctfmon", "spoolsv",
            "SecurityHealthService", "Secure System", "NVDisplay.Container" };

        // 常见程序的中文说明
        static readonly Dictionary<string, string> Desc = new Dictionary<string, string> {
            { "NVDisplay.Container", "NVIDIA 显示驱动容器" }, { "nvcontainer", "NVIDIA App 后台（即时重放等）" },
            { "NVIDIA Overlay", "NVIDIA 覆盖层（Alt+Z）" }, { "svchost", "Windows 系统服务（多个合计）" },
            { "svc:Audiosrv", "Windows 音频服务" }, { "svc:LightingService", "华硕 Aura 灯效服务" },
            { "svc:NVDisplay.ContainerLocalSystem", "NVIDIA 显示驱动容器（服务）" },
            { "lghub_system_tray", "罗技 G HUB 托盘" }, { "lghub_agent", "罗技 G HUB 后台（管设备）" }, { "lghub", "罗技 G HUB 主窗口" },
            { "steamwebhelper", "Steam 内置浏览器" }, { "steam", "Steam" }, { "Weixin", "微信" }, { "WeChatAppEx", "微信小程序 / 文章" },
            { "claude", "Claude" }, { "vivaldi", "Vivaldi 浏览器" }, { "msedge", "Edge 浏览器" }, { "chrome", "Chrome 浏览器" },
            { "msedgewebview2", "其他软件内嵌的网页" }, { "MsMpEng", "Windows Defender 杀毒" }, { "dwm", "桌面窗口管理器" },
            { "explorer", "资源管理器 / 任务栏" }, { "BongoCat", "BongoCat 桌宠" }, { "HueSync", "Philips Hue 灯光同步" },
            { "LightingService", "华硕 Aura 灯效" }, { "RazerAppEngine", "雷蛇 Synapse" }, { "iCUE", "海盗船 iCUE" },
            { "Corsair.Service", "海盗船后台服务" }, { "Discord", "Discord" }, { "wallpaper32", "Wallpaper Engine 壁纸" },
            { "wallpaperui", "Wallpaper Engine 界面" }, { "lw", "Live2DViewerEX" }, { "SAO Utils", "SAO Utils 桌面" },
            { "StreamDeck", "Stream Deck" }, { "QQ", "QQ" }, { "QQMusic", "QQ 音乐" }, { "qmbrowser", "QQ 音乐内置浏览器" },
            { "ArmouryCrate", "华硕奥创中心" }, { "ROGLiveService", "ROG Live 服务" }, { "audiodg", "Windows 音频引擎" },
            { "powershell", "PowerShell" }, { "WatchDog", "WatchDog 监控窗口（本程序）" }, { "MemCompression", "Windows 内存压缩（正常）" },
            { "System", "Windows 内核" }, { "SearchIndexer", "Windows 搜索索引" }, { "Taskmgr", "任务管理器" } };

        // 稳定性判断标准
        // 长期（看门狗记录 ≥ 1 小时）
        const double LeakSlopeMBh = 50, LeakGrowthMB = 100, LeakR2 = 0.6;    // 疑似泄漏
        const double RiseSlopeMBh = 15, RiseGrowthMB = 40, RiseR2 = 0.5;     // 缓慢上涨
        // 短期（窗口实时数据 ≥ 10 分钟）：只给初步判断，不下"泄漏"结论
        const double ShortMinHours = 10.0 / 60;
        const double ShortSlopeMBh = 60, ShortGrowthMB = 30, ShortR2 = 0.8;  // 短时上涨
        const double WobbleCv = 0.15;   // 波动大：波动幅度超过平均值的 15%
        const double HeavyIoMBs = 30;   // 单个程序读写超过这个速度会提示
        const int RingSize = 720;       // 每条实时数据最多 720 个点（5 秒一个 = 1 小时）
        const double GapSec = 1800;     // 实时数据中断超过 30 分钟，当作程序重启过，只看中断之后的数据
        const int MaxSeries = 240;      // 最多同时记录 240 条（每个程序 内存 / CPU / 读写 各一条）
        const int MaxIcons = 150;

        // ---------- 状态（每次刷新都整体替换，不累积） ----------
        Dictionary<int, double> prevCpu = new Dictionary<int, double>();
        Dictionary<int, long> prevIo = new Dictionary<int, long>();
        HashSet<int> denied = new HashSet<int>();
        DateTime prevTime = DateTime.MinValue;
        Queue<double> cpuHist = new Queue<double>();
        Dictionary<string, List<HistPt>> hist = new Dictionary<string, List<HistPt>>();
        Dictionary<string, Trend> analysis = new Dictionary<string, Trend>();
        List<SysRow> sys = new List<SysRow>();
        string histSig = "", rulesSig = "";
        long ignoreSig = -1;
        DateTime lastSlow = DateTime.MinValue, forceSlowAt = DateTime.MaxValue;
        Dictionary<int, string> svcPid = new Dictionary<int, string>();
        bool taskInstalled;
        string lastAction = "";
        List<Rule> rules = new List<Rule>();
        Dictionary<string, Rule> watched = new Dictionary<string, Rule>();
        Dictionary<string, double?> fileMB = new Dictionary<string, double?>();
        List<Hit> hits = new List<Hit>();
        Dictionary<string, Hit> hitByTarget = new Dictionary<string, Hit>();
        Dictionary<string, ProcRow> rows = new Dictionary<string, ProcRow>();
        Dictionary<string, Rating> ratings = new Dictionary<string, Rating>();
        Dictionary<string, Ring> series = new Dictionary<string, Ring>();      // 程序内存，以及 sys:mem / sys:cpu / sys:dr / sys:dw / sys:self
        Dictionary<string, Bitmap> icons = new Dictionary<string, Bitmap>();   // 程序名 -> 图标（或 null），上限 150 个
        Dictionary<string, IgnoreEntry> ignores = new Dictionary<string, IgnoreEntry>();
        List<Issue> issues = new List<Issue>();
        string[] verdict = { "正在检查…", "-1", "" };
        double selfMB, selfCpu; uint selfGdi; double selfPrevCpuMs = -1; DateTime selfPrevT;
        double[] disk = { 0, 0, 0 };
        int tick;

        // ---------- 看门狗历史（10 分钟一个点）的趋势，至少 1 小时 ----------
        static Trend Analyze(List<HistPt> pts)
        {
            int n = pts.Count;
            if (n < 6) return null;
            int start = 0;
            for (int i = 1; i < n; i++)
                if (pts[i].MB < 0.6 * pts[i - 1].MB || (pts[i].T - pts[i - 1].T).TotalMinutes > 60) start = i;
            int m = n - start;
            if (m < 6) return null;
            DateTime t0 = pts[start].T;
            double span = (pts[n - 1].T - t0).TotalHours;
            if (span < 1) return null;
            double sx = 0, sy = 0, sxx = 0, sxy = 0, syy = 0;
            for (int i = start; i < n; i++)
            {
                double x = (pts[i].T - t0).TotalHours, y = pts[i].MB;
                sx += x; sy += y; sxx += x * x; sxy += x * y; syy += y * y;
            }
            double den = m * sxx - sx * sx;
            if (den <= 0) return null;
            double num = m * sxy - sx * sy, vy = m * syy - sy * sy;
            double r2 = vy > 0 ? (num * num) / (den * vy) : 0;
            double mean = sy / m;
            double cv = mean > 0 ? Math.Sqrt(Math.Max(0, syy / m - mean * mean)) / mean : 0;
            Trend t = new Trend(); t.Slope = num / den; t.R2 = r2; t.Growth = pts[n - 1].MB - pts[start].MB; t.Span = span; t.Cv = cv;
            return t;
        }

        static DateTime? ParseTime(Dictionary<string, string> r)
        {
            string s; DateTime t;
            if (r.TryGetValue("Time", out s) && DateTime.TryParseExact(s, "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out t)) return t;
            return null;
        }

        void LoadHistory()
        {
            if (!Directory.Exists(DataDir)) { hist = new Dictionary<string, List<HistPt>>(); analysis = new Dictionary<string, Trend>(); sys = new List<SysRow>(); return; }
            DirectoryInfo di = new DirectoryInfo(DataDir);
            FileInfo[] pf = di.GetFiles("proc-*.csv").OrderBy(f => f.Name).ToArray();
            pf = pf.Skip(Math.Max(0, pf.Length - 2)).ToArray();
            FileInfo[] sf = di.GetFiles("sys*.csv").OrderBy(f => f.LastWriteTime).ToArray();
            sf = sf.Skip(Math.Max(0, sf.Length - 4)).ToArray();
            string sig = string.Join("|", pf.Concat(sf).Select(f => f.Name + ":" + f.Length));
            if (sig == histSig) return;   // 文件没变就不重读
            histSig = sig;
            DateTime cut = DateTime.Now.AddHours(-24);
            Dictionary<string, List<HistPt>> h = new Dictionary<string, List<HistPt>>();
            foreach (FileInfo f in pf)
                foreach (Dictionary<string, string> r in Csv.Read(f.FullName))
                {
                    DateTime? t = ParseTime(r); string name;
                    if (t == null || t.Value < cut || !r.TryGetValue("Name", out name)) continue;
                    List<HistPt> l; if (!h.TryGetValue(name, out l)) { l = new List<HistPt>(); h[name] = l; }
                    HistPt p = new HistPt(); p.T = t.Value; p.MB = Csv.Num(r, "PrivMB", 0); l.Add(p);
                }
            Dictionary<string, Trend> a = new Dictionary<string, Trend>();
            foreach (KeyValuePair<string, List<HistPt>> kv in h) { kv.Value.Sort((x, y) => x.T.CompareTo(y.T)); Trend tr = Analyze(kv.Value); if (tr != null) a[kv.Key] = tr; }
            hist = h; analysis = a;
            // sys-*.csv（旧格式）、sysv2（多了磁盘列）、sysv3（多了看门狗自身占用）合并，按时间排序
            List<SysRow> s = new List<SysRow>();
            foreach (FileInfo f in sf)
                foreach (Dictionary<string, string> r in Csv.Read(f.FullName))
                {
                    DateTime? t = ParseTime(r);
                    if (t == null || t.Value < cut) continue;
                    SysRow x = new SysRow(); x.T = t.Value;
                    x.UsedMB = Csv.Num(r, "UsedMB", 0); x.CpuPct = Csv.Num(r, "CpuPct", 0); x.RunMs = Csv.Num(r, "RunMs", 0);
                    x.HasDisk = Csv.Has(r, "DiskWriteMBs"); x.DiskR = Csv.Num(r, "DiskReadMBs", 0); x.DiskW = Csv.Num(r, "DiskWriteMBs", 0);
                    x.HasSelf = Csv.Has(r, "SelfPeakMB"); x.SelfCpuSec = Csv.Num(r, "SelfCpuSec", 0); x.SelfPeakMB = Csv.Num(r, "SelfPeakMB", 0);
                    s.Add(x);
                }
            s.Sort((x, y) => x.T.CompareTo(y.T));
            sys = s;
        }

        void LoadRules()
        {
            List<string> files = new List<string>();
            foreach (string n in new[] { "rules.json", "rules.local.json" }) { string p = Path.Combine(RulesDir, n); if (File.Exists(p)) files.Add(p); }
            string sig = string.Join("|", files.Select(p => Path.GetFileName(p) + ":" + File.GetLastWriteTimeUtc(p).Ticks));
            if (sig == rulesSig) return;
            rulesSig = sig;
            List<Rule> all = new List<Rule>();
            foreach (string p in files)
                try { foreach (Dictionary<string, object> d in Json.Objects(Json.Parse(Json.ReadFile(p)))) all.Add(Rule.From(d)); } catch { }
            rules = all;
            Dictionary<string, Rule> w = new Dictionary<string, Rule>();
            foreach (Rule r in all) if (r.Id.StartsWith("watch-") && r.Process != null) w[r.Process] = r;
            watched = w;
        }

        // 每分钟一次：规则、忽略设置、历史数据、服务进程号、计划任务状态、最近动作、规则里的文件大小、清理过期的实时数据
        void UpdateSlow()
        {
            LoadRules();
            LoadIgnores();
            LoadHistory();
            Dictionary<int, string> map = new Dictionary<int, string>();
            foreach (string p in rules.Select(r => r.Process).Where(p => p != null && p.StartsWith("svc:")).Distinct())
            {
                int pid = Native.ServicePid(p.Substring(4));
                if (pid > 0) map[pid] = p;
            }
            svcPid = map;
            taskInstalled = TaskExists("MemWatchdog");
            lastAction = "";
            try
            {
                if (File.Exists(LogFile))
                {
                    string[] lines = File.ReadAllLines(LogFile, System.Text.Encoding.UTF8);
                    for (int i = lines.Length - 1; i >= Math.Max(0, lines.Length - 200); i--)
                        if (System.Text.RegularExpressions.Regex.IsMatch(lines[i], "FIX|NOTICE|RESTART|REBUILD|HIGH")) { lastAction = lines[i]; break; }
                }
            }
            catch { }
            Dictionary<string, double?> fm = new Dictionary<string, double?>(StringComparer.OrdinalIgnoreCase);
            foreach (Rule r in rules)
                if (r.File != null && !fm.ContainsKey(r.File))
                {
                    try { fm[r.File] = File.Exists(r.File) ? (double?)(new FileInfo(r.File).Length / 1048576.0) : null; } catch { fm[r.File] = null; }
                }
            fileMB = fm;
            // 15 分钟没出现的程序，丢掉它的实时数据（实时数据存的是 UTC 时间）
            DateTime old = DateTime.UtcNow.AddMinutes(-15);
            foreach (string k in series.Keys.ToList()) if (!k.StartsWith("sys:") && series[k].LastSeen < old) series.Remove(k);
        }

        // 计划任务是否存在（Task Scheduler 的 COM 接口，不用开 PowerShell）
        static bool TaskExists(string name)
        {
            object svc = null;
            try
            {
                Type t = Type.GetTypeFromProgID("Schedule.Service");
                svc = Activator.CreateInstance(t);
                t.InvokeMember("Connect", System.Reflection.BindingFlags.InvokeMethod, null, svc, new object[0]);
                object folder = t.InvokeMember("GetFolder", System.Reflection.BindingFlags.InvokeMethod, null, svc, new object[] { "\\" });
                object task = folder.GetType().InvokeMember("GetTask", System.Reflection.BindingFlags.InvokeMethod, null, folder, new object[] { name });
                System.Runtime.InteropServices.Marshal.ReleaseComObject(task);
                System.Runtime.InteropServices.Marshal.ReleaseComObject(folder);
                return true;
            }
            catch { return false; }
            finally { if (svc != null) System.Runtime.InteropServices.Marshal.ReleaseComObject(svc); }
        }

        void Record(string name, double value, DateTime now)
        {
            Ring r;
            if (!series.TryGetValue(name, out r))
            {
                if (series.Count >= MaxSeries)   // 满了：丢掉最久没出现的那条
                {
                    string oldest = null;
                    foreach (KeyValuePair<string, Ring> kv in series)
                        if (!kv.Key.StartsWith("sys:") && (oldest == null || kv.Value.LastSeen < series[oldest].LastSeen)) oldest = kv.Key;
                    if (oldest != null) series.Remove(oldest);
                }
                r = new Ring(RingSize); series[name] = r;
            }
            r.Add(now, value);
        }

        List<ProcRow> SampleProcesses()
        {
            DateTime now = DateTime.UtcNow;
            double elapsedMs = prevTime != DateTime.MinValue ? (now - prevTime).TotalMilliseconds : 0;
            int cores = Environment.ProcessorCount;
            Dictionary<int, double> cur = new Dictionary<int, double>();
            Dictionary<int, long> curIo = new Dictionary<int, long>();
            HashSet<int> newDenied = new HashSet<int>();
            Dictionary<string, ProcRow> byName = new Dictionary<string, ProcRow>();
            foreach (Process p in Process.GetProcesses())
            {
                try
                {
                    int id = p.Id;
                    double priv = p.PrivateMemorySize64 / 1048576.0;
                    double d = 0, dio = 0;
                    if (!denied.Contains(id))
                    {
                        try
                        {
                            double ms = p.TotalProcessorTime.TotalMilliseconds;
                            cur[id] = ms;
                            double pm; if (prevCpu.TryGetValue(id, out pm)) d = Math.Max(0, ms - pm);
                        }
                        catch { newDenied.Add(id); }
                    }
                    else newDenied.Add(id);
                    long io = Native.IoBytes(id);
                    if (io >= 0) { curIo[id] = io; long pio; if (prevIo.TryGetValue(id, out pio)) dio = Math.Max(0, io - pio); }
                    string svc; svcPid.TryGetValue(id, out svc);
                    foreach (string nm in svc == null ? new[] { p.ProcessName } : new[] { p.ProcessName, svc })
                    {
                        ProcRow e;
                        if (!byName.TryGetValue(nm, out e)) { e = new ProcRow(); e.Name = nm; e.Pid = id; byName[nm] = e; }
                        e.PrivMB += priv; e.CpuMs += d; e.IoB += dio; e.Count++;
                    }
                }
                catch { }
                finally { p.Dispose(); }
            }
            prevCpu = cur; prevIo = curIo; denied = newDenied; prevTime = now;
            if (elapsedMs > 0)
                foreach (ProcRow e in byName.Values)
                {
                    e.CpuPct = Math.Round(100 * e.CpuMs / elapsedMs / cores, 1);
                    e.IoMBs = Math.Round(e.IoB / 1048576.0 / (elapsedMs / 1000), 1);
                }
            return byName.Values.ToList();
        }

        // 规则命中：when 里的条件全部满足才算
        void EvalRules()
        {
            List<Hit> hs = new List<Hit>(); Dictionary<string, Hit> byT = new Dictionary<string, Hit>();
            foreach (Rule r in rules)
            {
                List<string> why = new List<string>();
                if (r.Process != null)
                {
                    ProcRow row; if (!rows.TryGetValue(r.Process, out row)) continue;
                    if (r.MinMB > 0) { if (row.PrivMB < r.MinMB) continue; why.Add(string.Format("现在 {0:N0} MB，超过上限 {1} MB", row.PrivMB, r.MinMB)); }
                }
                if (r.File != null)
                {
                    double? fmb; if (!fileMB.TryGetValue(r.File, out fmb) || fmb == null) continue;
                    if (r.MinFileMB > 0) { if (fmb.Value < r.MinFileMB) continue; why.Add(string.Format("{0} 已经 {1:N0} MB，超过上限 {2} MB", Path.GetFileName(r.File), fmb.Value, r.MinFileMB)); }
                }
                if (why.Count == 0) continue;
                if (IsIgnored("rule:" + r.Id) != null) continue;   // 用户选了忽略 / 确认正常
                Hit h = new Hit(); h.Rule = r; h.Why = string.Join("；", why); h.Target = r.Target;
                hs.Add(h);
                if (h.Target != null && !byT.ContainsKey(h.Target)) byT[h.Target] = h;
            }
            hits = hs; hitByTarget = byT;
        }

        static string FmtMB(double mb) { return mb >= 1024 ? string.Format("{0:N1} GB", mb / 1024) : string.Format("{0:N0} MB", mb); }

        // ---- 忽略 / 确认正常（ignore.json，个人设置，不进 git）----
        // key：rule:<规则 id> / prog:<程序名>（稳定性问题） / io:<程序名>（大量读写）
        // type：snooze = 忽略 24 小时（until 到期后恢复提醒）；normal = 确认正常，不再提醒
        string IgnorePath { get { return Path.Combine(RulesDir, "ignore.json"); } }
        void LoadIgnores()
        {
            string p = IgnorePath;
            long sig = File.Exists(p) ? File.GetLastWriteTimeUtc(p).Ticks : 0;
            if (sig == ignoreSig) return;
            ignoreSig = sig;
            Dictionary<string, IgnoreEntry> m = new Dictionary<string, IgnoreEntry>();
            if (File.Exists(p))
                try
                {
                    foreach (Dictionary<string, object> d in Json.Objects(Json.Parse(Json.ReadFile(p))))
                    {
                        IgnoreEntry e = new IgnoreEntry(); e.Key = Json.Str(d, "key"); e.Label = Json.Str(d, "label") ?? e.Key;
                        e.Type = Json.Str(d, "type") ?? "snooze"; e.Until = Json.Str(d, "until") ?? "";
                        if (e.Key != null) m[e.Key] = e;
                    }
                }
                catch { }
            ignores = m;
        }
        static DateTime UntilOf(IgnoreEntry e)
        {
            DateTime t; return DateTime.TryParse(e.Until, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out t) ? t : DateTime.MinValue;
        }
        void SaveIgnores()
        {
            DateTime now = DateTime.Now;
            List<object> list = new List<object>();
            foreach (IgnoreEntry e in ignores.Values)
            {
                if (e.Type == "snooze" && UntilOf(e) <= now) continue;
                Dictionary<string, object> d = new Dictionary<string, object>();
                d["key"] = e.Key; d["label"] = e.Label; d["type"] = e.Type; d["until"] = e.Until;
                list.Add(d);
            }
            try { Json.WriteFile(IgnorePath, list); } catch (Exception ex) { Say("保存 ignore.json 失败：" + ex.Message); }
            ignoreSig = -1; LoadIgnores();
        }
        IgnoreEntry IsIgnored(string key)
        {
            IgnoreEntry i;
            if (key == null || !ignores.TryGetValue(key, out i)) return null;
            if (i.Type == "snooze" && UntilOf(i) < DateTime.Now) return null;
            return i;
        }
        void IgnoreIssue(string key, string label, bool normal)
        {
            if (key == null) return;
            IgnoreEntry e = new IgnoreEntry(); e.Key = key; e.Label = label;
            e.Type = normal ? "normal" : "snooze";
            e.Until = normal ? "" : DateTime.Now.AddHours(24).ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture);
            ignores[key] = e;
            SaveIgnores(); RefreshAll();
        }
        bool RuleTargets(string key, string name)
        {
            if (!key.StartsWith("rule:")) return false;
            Rule r = rules.FirstOrDefault(x => "rule:" + x.Id == key);
            return r != null && (r.Target == name || r.Process == name);
        }
        void UnignoreName(string name)
        {
            foreach (string k in ignores.Keys.ToList())
                if (k == "prog:" + name || k == "io:" + name || RuleTargets(k, name)) ignores.Remove(k);
            SaveIgnores(); RefreshAll();
        }
        static string IgnoreNote(IgnoreEntry i)
        {
            return i.Type == "normal" ? "你已确认正常，不再提醒" : "已忽略，" + UntilOf(i).ToString("MM-dd HH:mm") + " 后恢复提醒";
        }
        List<IgnoreEntry> ActiveIgnores() { return ignores.Values.Where(i => IsIgnored(i.Key) != null).ToList(); }
        bool HasIgnore(string name)
        {
            foreach (string k in ignores.Keys)
            {
                if (IsIgnored(k) == null) continue;
                if (k == "prog:" + name || k == "io:" + name || RuleTargets(k, name)) return true;
            }
            return false;
        }

        // 稳定性评级（加上用户的忽略设置）
        Rating GetRating(string name, double mb)
        {
            Rating rt = GetRatingRaw(name, mb);
            if (rt.Level >= 1 && rt.Text != "已知问题")
            {
                IgnoreEntry ig = IsIgnored("prog:" + name);
                if (ig != null) return new Rating(rt.Text, -1, 0, IgnoreNote(ig), "", rt.Trend);
            }
            return rt;
        }

        // 稳定性评级。Level：2 = 有问题（红）、1 = 需要留意（黄）、0 = 正常（蓝）、-1 = 中性（灰）。Score 用于"问题优先"排序。
        // 优先用看门狗的长期记录（≥ 1 小时）；没有的话用窗口的实时数据（≥ 10 分钟）给初步判断。
        Rating GetRatingRaw(string name, double mb)
        {
            Hit hit;
            if (hitByTarget.TryGetValue(name, out hit))
            {
                int lvl = hit.Rule.FixType == "none" ? 1 : 2;
                return new Rating("已知问题", lvl, 100 + 5 * lvl, hit.Rule.Title, "", "");
            }
            Trend a; analysis.TryGetValue(name, out a);
            // 现在的占用比最后一条记录低很多 = 刚被重启过，之前的趋势作废
            List<HistPt> hl;
            if (a != null && hist.TryGetValue(name, out hl) && hl.Count > 0 && mb < 0.6 * hl[hl.Count - 1].MB) a = null;
            if (a != null)
            {
                string trend = string.Format("{0:+#,0;-#,0;0} MB / {1:N1} 小时", a.Growth, a.Span);
                string fc = a.Slope > 0 ? "照这个速度，24 小时后约 " + FmtMB(mb + a.Slope * 24) : "";
                string note = string.Format("近 {0:N1} 小时涨了 {1:N0} MB（约 {2:N0} MB/小时）", a.Span, a.Growth, a.Slope);
                if (a.Slope >= LeakSlopeMBh && a.Growth >= LeakGrowthMB && a.R2 >= LeakR2) return new Rating("疑似泄漏", 2, 90, note, fc, trend);
                if (a.Slope >= RiseSlopeMBh && a.Growth >= RiseGrowthMB && a.R2 >= RiseR2) return new Rating("缓慢上涨", 1, 60, note, fc, trend);
                if (a.Cv >= WobbleCv) return new Rating("波动大", -1, 10, "忽高忽低，通常是正常使用（比如开关网页）", "", trend);
                return new Rating("稳定", 0, 0, string.Format("近 {0:N1} 小时平稳", a.Span), "", trend);
            }
            Ring ring; series.TryGetValue(name, out ring);
            double[] st = ring != null ? ring.Stats(GapSec) : null;
            if (st != null && st[3] >= ShortMinHours)
            {
                double mins = st[3] * 60;
                string trend = string.Format("{0:+#,0;-#,0;0} MB / {1:N0} 分钟", st[2], mins);
                if (st[0] >= ShortSlopeMBh && st[2] >= ShortGrowthMB && st[1] >= ShortR2)
                    return new Rating("短时上涨", 1, 50, string.Format("近 {0:N0} 分钟持续上涨 {1:N0} MB，继续观察（满 1 小时才判断是否泄漏）", mins, st[2]),
                        "照这个速度，1 小时后约 " + FmtMB(mb + st[0]), trend);
                if (st[4] >= WobbleCv) return new Rating("波动大", -1, 10, "忽高忽低，通常是正常使用", "", trend);
                return new Rating("稳定", 0, 0, string.Format("近 {0:N0} 分钟平稳（初步，满 1 小时更准）", mins), "", trend);
            }
            return new Rating("数据不足", -1, 0, "窗口打开满 10 分钟后开始判断", "", "—");
        }

        static string Ago(DateTime t)
        {
            int m = (int)(DateTime.Now - t).TotalMinutes;
            if (m < 1) return "刚刚";
            if (m < 60) return m + " 分钟前";
            if (m < 1440) return string.Format("{0:N1} 小时前", m / 60.0);
            return string.Format("{0:N0} 天前", m / 1440.0);
        }

        Bitmap GetIcon(string name)
        {
            Bitmap bmp;
            if (icons.TryGetValue(name, out bmp)) return bmp;
            if (icons.Count >= MaxIcons)   // 上限：满了就整体释放重来
            {
                foreach (Bitmap b in icons.Values) if (b != null) b.Dispose();
                icons.Clear();
            }
            bmp = null;
            ProcRow r;
            if (rows.TryGetValue(name, out r) && !name.StartsWith("svc:"))
            {
                string path = Native.ImagePath(r.Pid);
                if (path != null && File.Exists(path))
                    try { using (Icon ico = Icon.ExtractAssociatedIcon(path)) bmp = ico.ToBitmap(); }   // 图标句柄立即释放，只留位图
                    catch { bmp = null; }
            }
            icons[name] = bmp;
            return bmp;
        }

        // ---------- 实时数据存盘：关掉再打开，之前的记录还在 ----------
        // 格式：'WDL1'、条数，然后每条：名字、点数、每个点（时间 ticks, 值）。先写临时文件再替换，写一半断电也不会坏
        void SaveLive()
        {
            try
            {
                Directory.CreateDirectory(DataDir);
                string tmp = LiveFile + ".tmp";
                using (FileStream fs = File.Create(tmp))
                using (BinaryWriter w = new BinaryWriter(fs))
                {
                    w.Write(0x314C4457); w.Write(series.Count);
                    foreach (KeyValuePair<string, Ring> kv in series) { w.Write(kv.Key); kv.Value.Save(w); }
                }
                if (File.Exists(LiveFile)) File.Delete(LiveFile);
                File.Move(tmp, LiveFile);
            }
            catch { }
        }
        void LoadLive()
        {
            if (!File.Exists(LiveFile)) return;
            long minT = DateTime.UtcNow.AddSeconds(-5 * RingSize).Ticks;   // 只读回最近 1 小时内的点（再早的走势图用看门狗的记录）
            try
            {
                using (FileStream fs = File.OpenRead(LiveFile))
                using (BinaryReader rd = new BinaryReader(fs))
                {
                    if (rd.ReadInt32() != 0x314C4457) return;
                    int cnt = rd.ReadInt32();
                    for (int i = 0; i < cnt; i++)
                    {
                        string name = rd.ReadString(); Ring r = new Ring(RingSize); r.Load(rd, minT);
                        if (r.Count > 0 && series.Count < MaxSeries) series[name] = r;
                    }
                }
            }
            catch { }
        }
    }
}
