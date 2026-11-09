// 内核 / 驱动泄漏 + 句柄 / 图形资源（GDI、USER）泄漏的检测
//   内核：驱动申请的内存在"内核内存池"里（分页池 / 非分页池），任务管理器的进程列表看不到。
//         每 5 秒记一次池的大小；每 10 分钟拍一次按"标签"分开的明细，涨了就能看出是哪个标签（哪个驱动）在涨。
//   句柄 / GDI / USER：每个程序都记。GDI、USER 单个进程上限 1 万个，用完了窗口、菜单就画不出来。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace WatchDog
{
    class TagStat { public int Tag; public string Name; public double MB, NpMB, GrowMB; }

    partial class Monitor
    {
        // 判断标准
        const double NpWarnMB = 2048, NpBadMB = 4096, PgWarnMB = 4096, PgBadMB = 8192;   // 内核池绝对值
        const int GuiWarn = 5000, GuiBad = 8000;                                          // 单个进程 GDI 或 USER（上限 10000）
        const int HndWarn = 50000, HndBad = 100000;                                       // 单个进程句柄

        double kPaged, kNonpaged, kHandles;
        int kLevel; string kBadge = "...", kWhy = "";
        Issue kernelIssue;
        Dictionary<string, Issue> resIssues = new Dictionary<string, Issue>();   // 程序名 -> 句柄 / 图形资源问题

        // 内存池快照：只存排好序的数组（每张约 40 KB），窗口打开时一张 + 最近 1 小时内每 10 分钟一张
        class PoolSnap { public DateTime T; public int[] Tags; public long[] Bytes; }
        PoolSnap poolBase; List<PoolSnap> poolSnaps = new List<PoolSnap>();
        DateTime lastPool = DateTime.MinValue;
        List<TagStat> poolBig = new List<TagStat>(), poolGrow = new List<TagStat>();

        // 标签 -> 驱动文件（后台线程在已加载的驱动里搜出来的；空字符串 = 没找到）
        static readonly object tagLock = new object();
        static readonly Dictionary<int, string> tagDriver = new Dictionary<int, string>();
        static readonly HashSet<int> tagScanning = new HashSet<int>();

        // ---------- 采样（每 5 秒） ----------
        void SampleKernel(DateTime nowU)
        {
            double[] k = Native.Kernel();
            if (k != null)
            {
                kPaged = k[0]; kNonpaged = k[1]; kHandles = k[2];
                Record("sys:kp", kPaged, nowU); Record("sys:kn", kNonpaged, nowU); Record("sys:hnd", kHandles, nowU);
            }
            if ((nowU - lastPool).TotalMinutes >= 10) { lastPool = nowU; TakePoolSnap(nowU); }
        }

        void TakePoolSnap(DateTime nowU)
        {
            Dictionary<int, long[]> d = Native.PoolTags();
            if (d == null) return;
            PoolSnap s = new PoolSnap(); s.T = nowU;
            s.Tags = d.Keys.ToArray(); Array.Sort(s.Tags);
            s.Bytes = new long[s.Tags.Length];
            for (int i = 0; i < s.Tags.Length; i++) s.Bytes[i] = d[s.Tags[i]][0];
            if (poolBase == null) poolBase = s;
            poolSnaps.Add(s);
            while (poolSnaps.Count > 7) poolSnaps.RemoveAt(0);
            // 占用最多的 3 个标签
            poolBig = d.OrderByDescending(kv => kv.Value[0]).Take(3)
                .Select(kv => new TagStat { Tag = kv.Key, Name = Native.TagText(kv.Key), MB = kv.Value[0] / 1048576.0, NpMB = kv.Value[1] / 1048576.0 }).ToList();
            // 涨得最多的 3 个：和窗口打开时比（慢泄漏要很久才看得出来），至少涨了 20 MB
            List<TagStat> grow = new List<TagStat>();
            if (poolBase != s)
                foreach (KeyValuePair<int, long[]> kv in d)
                {
                    double g = (kv.Value[0] - SnapBytes(poolBase, kv.Key)) / 1048576.0;
                    if (g >= 20) grow.Add(new TagStat { Tag = kv.Key, Name = Native.TagText(kv.Key), MB = kv.Value[0] / 1048576.0, NpMB = kv.Value[1] / 1048576.0, GrowMB = g });
                }
            poolGrow = grow.OrderByDescending(t => t.GrowMB).Take(3).ToList();
        }
        static long SnapBytes(PoolSnap s, int tag) { int i = Array.BinarySearch(s.Tags, tag); return i >= 0 ? s.Bytes[i] : 0; }

        // ---------- 内核判断 ----------
        void EvalKernel()
        {
            int lvl = 0; string badge = "正常", why = "", title = null;
            // 1. 长期（看门狗记录，本次开机以来，至少 3 小时）
            DateTime boot = DateTime.Now - TimeSpan.FromMilliseconds(Native.GetTickCount64());
            List<SysRow> rowsK = sys.Where(x => x.HasKernel && x.T >= boot.AddMinutes(10)).ToList();
            Trend tn = Analyze(rowsK.Select(x => new HistPt { T = x.T, MB = x.PoolN }).ToList());
            Trend tp = Analyze(rowsK.Select(x => new HistPt { T = x.T, MB = x.PoolP }).ToList());
            Func<string, Trend, string> desc = (pool, t) => string.Format("{0} {1:N1} 小时 +{2:N0} MB（约 {3:N0} MB/小时）", pool, t.Span, t.Growth, t.Slope);
            if (tn != null && tn.Span >= 3 && tn.Slope >= 15 && tn.Growth >= 150 && tn.R2 >= 0.75) { lvl = 2; badge = "疑似泄漏"; title = "内核内存疑似泄漏（驱动）"; why = desc("非分页池", tn); }
            else if (tp != null && tp.Span >= 3 && tp.Slope >= 40 && tp.Growth >= 400 && tp.R2 >= 0.75) { lvl = 2; badge = "疑似泄漏"; title = "内核内存疑似泄漏（驱动）"; why = desc("分页池", tp); }
            else if (tn != null && tn.Span >= 3 && tn.Slope >= 6 && tn.Growth >= 80 && tn.R2 >= 0.6) { lvl = 1; badge = "缓慢上涨"; title = "内核内存在缓慢上涨"; why = desc("非分页池", tn); }
            else if (tp != null && tp.Span >= 3 && tp.Slope >= 15 && tp.Growth >= 200 && tp.R2 >= 0.6) { lvl = 1; badge = "缓慢上涨"; title = "内核内存在缓慢上涨"; why = desc("分页池", tp); }
            // 2. 实时（窗口的数据，至少 30 分钟）：只说"在涨，观察中"
            if (lvl == 0)
            {
                double[] sn = Stats("sys:kn"), sp = Stats("sys:kp");
                if (sn != null && sn[3] >= 0.5 && sn[2] >= 150 && sn[0] >= 150 && sn[1] >= 0.85) { lvl = 1; badge = "上涨中"; title = "内核内存在上涨（观察中）"; why = string.Format("非分页池 {0:N0} 分钟 +{1:N0} MB", sn[3] * 60, sn[2]); }
                else if (sp != null && sp[3] >= 0.5 && sp[2] >= 300 && sp[0] >= 300 && sp[1] >= 0.85) { lvl = 1; badge = "上涨中"; title = "内核内存在上涨（观察中）"; why = string.Format("分页池 {0:N0} 分钟 +{1:N0} MB", sp[3] * 60, sp[2]); }
            }
            // 3. 绝对值
            int abs = kNonpaged >= NpBadMB || kPaged >= PgBadMB ? 2 : kNonpaged >= NpWarnMB || kPaged >= PgWarnMB ? 1 : 0;
            if (abs > lvl)
            {
                lvl = abs; badge = abs == 2 ? "过高" : "偏高"; title = "内核内存占用" + badge;
                why = string.Format("分页池 {0:N1} GB · 非分页池 {1:N1} GB", kPaged / 1024, kNonpaged / 1024);
            }
            kLevel = lvl; kBadge = badge; kWhy = why;
            kernelIssue = null;
            if (title != null && IsIgnored("kernel") == null)
            {
                TagStat top = poolGrow.FirstOrDefault();
                string sub = why + (top != null ? " · 涨最多：" + top.Name : "");
                kernelIssue = NewIssue(title, sub, lvl, null, "kernel");
                // 找出涨得最多的标签属于哪个驱动（后台线程，只搜一次）
                foreach (TagStat t in poolGrow.Take(2)) if (TagDesc(t.Name) == null) FindDriver(t.Tag);
            }
        }
        double[] Stats(string key) { Ring r; return series.TryGetValue(key, out r) ? r.Stats(GapSec) : null; }

        // ---------- 每个程序的句柄 / 图形资源 ----------
        void EvalResources(List<ProcRow> real)
        {
            Dictionary<string, Issue> res = new Dictionary<string, Issue>();
            foreach (ProcRow r in real)
            {
                if (IsIgnored("res:" + r.Name) != null) continue;
                int lvl = 0; string title = null, sub = null; string label = r.Name;   // 标题只用程序名，说明太长会被截断
                string gui = string.Format("GDI {0:N0} · USER {1:N0}", r.Gdi, r.User);
                string fix = Protected.Contains(r.Name) ? "通常是驱动引起的，重启电脑可以收回" : "重启它可以释放";
                // GDI / USER：单个进程上限 1 万个
                if (r.GuiMax >= GuiWarn)
                {
                    lvl = r.GuiMax >= GuiBad ? 2 : 1; title = label + " 的图形资源快用完了";
                    sub = gui + "（单个进程上限 1 万，用完会画不出窗口和菜单）· " + fix;
                }
                double[] sg = Stats("gdi:" + r.Name), su = Stats("usr:" + r.Name);
                double[] sgu = sg != null && (su == null || sg[2] >= su[2]) ? sg : su;
                if (sgu != null && sgu[3] >= 1.0 / 3 && sgu[2] >= 500 && sgu[0] >= 500 && sgu[1] >= 0.85)
                {
                    int l = r.GuiMax >= 3000 ? 2 : 1;
                    if (l > lvl) { lvl = l; title = label + " 的图形资源在一直涨"; sub = string.Format("近 {0:N0} 分钟 +{1:N0} 个，现在 {2}（上限 1 万）· {3}", sgu[3] * 60, sgu[2], gui, fix); }
                }
                // 句柄：长期记录（看门狗）
                Trend a; List<HistPt> hl;
                if (analysisH.TryGetValue(r.Name, out a) && histH.TryGetValue(r.Name, out hl) && hl.Count > 0 && r.Handles >= 0.6 * hl[hl.Count - 1].MB && a.Span >= 2)
                {
                    int l = a.Slope >= 500 && a.Growth >= 3000 && a.R2 >= 0.7 ? 2 : a.Slope >= 200 && a.Growth >= 1500 && a.R2 >= 0.6 ? 1 : 0;
                    if (l > lvl) { lvl = l; title = label + (l == 2 ? " 疑似句柄泄漏" : " 的句柄在缓慢上涨"); sub = string.Format("近 {0:N1} 小时 +{1:N0} 个（约 {2:N0} 个/小时），现在 {3:N0} 个 · {4}", a.Span, a.Growth, a.Slope, r.Handles, fix); }
                }
                // 句柄：实时
                double[] sh = Stats("hnd:" + r.Name);
                if (lvl == 0 && sh != null && sh[3] >= 1.0 / 3 && sh[2] >= 3000 && sh[0] >= 3000 && sh[1] >= 0.85)
                { lvl = 1; title = label + " 的句柄在一直涨（观察中）"; sub = string.Format("近 {0:N0} 分钟 +{1:N0} 个，现在 {2:N0} 个", sh[3] * 60, sh[2], r.Handles); }
                // 句柄：绝对值
                int ah = r.HMax >= HndBad ? 2 : r.HMax >= HndWarn ? 1 : 0;
                if (ah > lvl) { lvl = ah; title = label + " 的句柄数异常多"; sub = string.Format("单个进程 {0:N0} 个，正常程序一般在几千以内 · {1}", r.HMax, fix); }
                if (lvl > 0) res[r.Name] = NewIssue(title, sub, lvl, r.Name, "res:" + r.Name);
            }
            resIssues = res;
        }
        int ResLevel(string name) { Issue i; return resIssues.TryGetValue(name, out i) ? i.Level : 0; }

        // 每个程序的句柄 / GDI / USER 实时数据：句柄最多的 15 个、图形资源最多的 15 个、有问题的、选中的
        void RecordResources(List<ProcRow> real, DateTime nowU)
        {
            HashSet<string> h = new HashSet<string>(real.OrderByDescending(r => r.Handles).Take(15).Select(r => r.Name));
            HashSet<string> gu = new HashSet<string>(real.Where(r => r.Gdi + r.User > 0).OrderByDescending(r => r.Gdi + r.User).Take(15).Select(r => r.Name));
            foreach (string n in resIssues.Keys) { h.Add(n); gu.Add(n); }
            if (selected != null) { h.Add(selected); gu.Add(selected); }
            foreach (ProcRow r in real)
            {
                if (h.Contains(r.Name)) Record("hnd:" + r.Name, r.Handles, nowU);
                if (gu.Contains(r.Name)) { Record("gdi:" + r.Name, r.Gdi, nowU); Record("usr:" + r.Name, r.User, nowU); }
            }
        }

        // ---------- 标签说明 ----------
        // 常见的 Windows 自带标签（按前缀）。不认识的标签去已加载的驱动文件里搜
        static readonly string[][] KnownTags = {
            new[] { "MmSt", "文件映射，正常" }, new[] { "Mm", "内存管理" },
            new[] { "Ntf", "NTFS 文件系统" }, new[] { "NtF", "NTFS 文件系统" }, new[] { "FM", "文件过滤驱动，杀毒 / 同步盘" },
            new[] { "File", "文件对象" }, new[] { "Cont", "连续内存，显卡等驱动" }, new[] { "Etw", "事件跟踪" },
            new[] { "NV", "NVIDIA 显卡驱动" }, new[] { "Amd", "AMD 驱动" }, new[] { "AMD", "AMD 驱动" }, new[] { "Dx", "DirectX 图形内核" },
            new[] { "Vi", "显卡 / 显示相关" }, new[] { "CM", "注册表" }, new[] { "Afd", "网络连接" }, new[] { "Tcp", "TCP/IP 网络" },
            new[] { "Nd", "网卡驱动" }, new[] { "ND", "网卡驱动" }, new[] { "Wfp", "Windows 防火墙过滤" },
            new[] { "Proc", "进程对象" }, new[] { "Thre", "线程对象" }, new[] { "Toke", "安全令牌" }, new[] { "Even", "事件对象" },
            new[] { "Alpc", "进程通信" }, new[] { "Ob", "对象管理" }, new[] { "Se", "安全子系统" }, new[] { "Io", "I/O 管理" },
            new[] { "Irp", "I/O 请求" }, new[] { "Usb", "USB" }, new[] { "Hid", "输入设备" }, new[] { "Wdf", "驱动框架 WDF" },
            new[] { "sm", "内存压缩" }, new[] { "Ps", "进程管理" }, new[] { "Key", "注册表" }, new[] { "Vad", "内存管理" } };
        static string TagDesc(string tag)
        {
            foreach (string[] k in KnownTags) if (tag.StartsWith(k[0], StringComparison.Ordinal)) return k[1];
            return null;
        }
        string TagLabel(TagStat t)
        {
            string d = TagDesc(t.Name);
            if (d == null) lock (tagLock) { string drv; if (tagDriver.TryGetValue(t.Tag, out drv) && drv.Length > 0) d = drv; }
            return d != null ? t.Name + "（" + d + "）" : t.Name;
        }

        // 在已加载的驱动文件里找这个标签（和微软文档里 findstr 的办法一样）。后台线程，每个标签只搜一次
        static void FindDriver(int tag)
        {
            lock (tagLock) { if (tagDriver.ContainsKey(tag) || tagScanning.Contains(tag)) return; tagScanning.Add(tag); }
            ThreadPool.QueueUserWorkItem(delegate
            {
                string found = "";
                try { found = ScanDrivers(tag); } catch { }
                lock (tagLock) { tagDriver[tag] = found; tagScanning.Remove(tag); }
            });
        }
        // 驱动文件列表：注册表里的驱动服务（内核驱动 / 文件系统驱动，没被禁用的）。
        // 不用 EnumDeviceDrivers：没有管理员权限时 Windows 不给驱动地址，拿不到路径
        static List<string> DriverFiles()
        {
            List<string> list = new List<string>();
            string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            using (Microsoft.Win32.RegistryKey svc = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services"))
            {
                if (svc == null) return list;
                foreach (string name in svc.GetSubKeyNames())
                    try
                    {
                        using (Microsoft.Win32.RegistryKey k = svc.OpenSubKey(name))
                        {
                            if (k == null) continue;
                            object type = k.GetValue("Type"), start = k.GetValue("Start"), img = k.GetValue("ImagePath");
                            if (!(type is int) || ((int)type != 1 && (int)type != 2) || !(start is int) || (int)start == 4) continue;
                            string p = img as string ?? @"System32\drivers\" + name + ".sys";
                            p = Environment.ExpandEnvironmentVariables(p.Trim('"'));
                            if (p.StartsWith(@"\SystemRoot\", StringComparison.OrdinalIgnoreCase)) p = Path.Combine(win, p.Substring(12));
                            else if (p.StartsWith(@"\??\")) p = p.Substring(4);
                            else if (p.StartsWith(@"\")) p = Path.Combine(Path.GetPathRoot(win), p.TrimStart('\\'));   // \Windows\... 没写盘符
                            else if (!Path.IsPathRooted(p)) p = Path.Combine(win, p);
                            if (File.Exists(p) && !list.Contains(p, StringComparer.OrdinalIgnoreCase)) list.Add(p);
                        }
                    }
                    catch { }
            }
            return list;
        }
        static string ScanDrivers(int tag)
        {
            byte[] pat = BitConverter.GetBytes(tag);
            List<string> mine = new List<string>(), ms = new List<string>();
            byte[] buf = new byte[1 << 20];
            foreach (string f in DriverFiles())
            {
                bool hit = false;
                try
                {
                    using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    {
                        int keep = 0, n;
                        while (!hit && (n = fs.Read(buf, keep, buf.Length - keep)) > 0)
                        {
                            int len = keep + n;
                            for (int i = 0; i + 3 < len; i++)
                                if (buf[i] == pat[0] && buf[i + 1] == pat[1] && buf[i + 2] == pat[2] && buf[i + 3] == pat[3]) { hit = true; break; }
                            keep = Math.Min(3, len); Buffer.BlockCopy(buf, len - keep, buf, 0, keep);
                        }
                    }
                }
                catch { }
                if (!hit) continue;
                string company = "";
                try { company = FileVersionInfo.GetVersionInfo(f).CompanyName ?? ""; } catch { }
                string label = Path.GetFileName(f) + (company.Length > 0 ? " · " + company.Trim() : "");
                if (company.IndexOf("Microsoft", StringComparison.OrdinalIgnoreCase) >= 0) ms.Add(label); else mine.Add(label);
            }
            // 第三方驱动更可能是元凶；太多文件都含这个标签就说明它太常见，不下结论
            List<string> pick = mine.Count > 0 ? mine : ms;
            if (pick.Count == 0 || pick.Count > 4) return "";
            return "可能是 " + string.Join(" / ", pick.Take(2));
        }
    }
}
