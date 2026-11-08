// WatchDog 监控窗口：内存 / CPU / 磁盘 监控面板
// 和任务管理器的区别：不只看"现在谁占得多"，而是看"谁在变坏、为什么、怎么修"——
//   1. 稳定性评级：窗口打开 10 分钟后用实时数据给出初步判断；看门狗记录满 1 小时后给出长期判断（含疑似泄漏）
//   2. 问题规则库：rules.json（公共）+ rules.local.json（自己的）写明"症状 → 原因 → 修复方法"，命中就给出修复按钮
// 每 5 秒刷新一次；点关闭缩到托盘，在后台继续记录。
// 实时数据存在固定大小的环形缓存里（每条最多 1 小时 / 720 个点，最多 150 条），不会越用越大。
//
// 自测：WatchDog.exe --selftest --loops N [--report 文件] [--snapshot x.png] [--select 程序名]
//        [--chart mem|cpu|disk|dog|proc] [--range 30m|1h|3h|12h|24h] [--sim 分钟] [--rising 程序名] [--data 目录]
//   在屏幕外显示窗口，连续刷新并完整重绘 N 次，记录自身内存 / GDI / 句柄，看有没有泄漏
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace WatchDog
{
    static class Program
    {
        [STAThread]
        static int Main(string[] argv)
        {
            Dictionary<string, string> a = ParseArgs(argv);
            string toolDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            string dataDir = Get(a, "data", Path.Combine(toolDir, "data"));
            bool selfTest = a.ContainsKey("selftest");
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            if (selfTest) return SelfTest(a, toolDir, dataDir);
            // --exit：让正在运行的 WatchDog 存好数据后退出（重新编译前用）
            if (a.ContainsKey("exit"))
            {
                try { using (EventWaitHandle ev = EventWaitHandle.OpenExisting("Local\\yifanwow.WatchDog.Exit")) ev.Set(); } catch { return 0; }
                for (int i = 0; i < 50; i++)
                {
                    Thread.Sleep(200);
                    try { using (Mutex m = Mutex.OpenExisting("Local\\yifanwow.WatchDog")) { } } catch { return 0; }   // 已经退出
                }
                return 1;
            }

            // 只开一个：已经在运行（可能在托盘里）时，把它叫出来，自己退出
            bool own;
            using (Mutex mutex = new Mutex(false, "Local\\yifanwow.WatchDog"))
            {
                try { own = mutex.WaitOne(0); } catch (AbandonedMutexException) { own = true; }   // 上次被强制结束
                if (!own)
                {
                    try
                    {
                        using (EventWaitHandle ev = EventWaitHandle.OpenExisting("Local\\yifanwow.WatchDog.Show"))
                        { Native.AllowSetForegroundWindow(-1); ev.Set(); }   // 让已经开着的那个可以把窗口提到最前
                    }
                    catch { }
                    return 0;
                }
                using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\yifanwow.WatchDog.Show"))
                using (EventWaitHandle exit = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\yifanwow.WatchDog.Exit"))
                using (Monitor form = new Monitor(toolDir, dataDir, false, null, Get(a, "chart", "mem"), Get(a, "range", "30m")))
                {
                    form.Prepare(true);
                    form.StartTimer();
                    form.ListenForShow(show, exit);
                    Application.Run(form);
                }
                mutex.ReleaseMutex();
            }
            return 0;
        }

        static Dictionary<string, string> ParseArgs(string[] argv)
        {
            Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < argv.Length; i++)
            {
                if (!argv[i].StartsWith("--")) continue;
                string k = argv[i].Substring(2);
                if (i + 1 < argv.Length && !argv[i + 1].StartsWith("--")) { d[k] = argv[i + 1]; i++; } else d[k] = "";
            }
            return d;
        }
        static string Get(Dictionary<string, string> a, string k, string def) { string v; return a.TryGetValue(k, out v) && v.Length > 0 ? v : def; }

        static int SelfTest(Dictionary<string, string> a, string toolDir, string dataDir)
        {
            int loops = int.Parse(Get(a, "loops", "1"));
            int sim = int.Parse(Get(a, "sim", "0"));
            string report = Get(a, "report", Path.Combine(toolDir, "selftest.txt"));
            string snapshot = Get(a, "snapshot", null);
            StringBuilder outp = new StringBuilder();
            using (Monitor form = new Monitor(toolDir, dataDir, true, Get(a, "select", null), Get(a, "chart", "mem"), Get(a, "range", "30m")))
            {
                form.Prepare(sim == 0);   // 用模拟数据时不读真实记录，也不存，免得混在一起
                Thread.Sleep(800);
                // 在屏幕外真实显示窗口，让所有控件都按正常流程创建和绘制
                form.StartPosition = FormStartPosition.Manual; form.Location = new Point(-5000, -5000); form.ShowInTaskbar = false;
                form.Show(); Application.DoEvents();
                if (sim > 0) form.Simulate(sim, Get(a, "rising", ""));
                using (Bitmap bmp = new Bitmap(form.Width, form.Height))
                {
                    Rectangle rect = new Rectangle(0, 0, form.Width, form.Height);
                    List<string> mem = new List<string>();
                    for (int i = 1; i <= loops; i++)
                    {
                        form.RefreshAll();
                        Application.DoEvents();        // 处理重绘消息
                        form.DrawToBitmap(bmp, rect);  // 再完整画一遍，检查绘制有没有泄漏
                        if (i == Math.Min(20, loops) || i == loops || i % 150 == 0)
                        {
                            GC.Collect(); GC.WaitForPendingFinalizers();
                            using (Process me = Process.GetCurrentProcess())
                                mem.Add(string.Format("第 {0} 次刷新+重绘后：本程序 {1:N1} MB，托管堆 {2:N1} MB，句柄 {3}，GDI 对象 {4}，USER 对象 {5}，图标缓存 {6}，实时数据 {7} 条",
                                    i, me.PrivateMemorySize64 / 1048576.0, GC.GetTotalMemory(true) / 1048576.0, me.HandleCount,
                                    Native.GetGuiResources(me.Handle, 0), Native.GetGuiResources(me.Handle, 1), form.IconCount, form.SeriesCount));
                        }
                    }
                    if (snapshot != null) bmp.Save(snapshot, System.Drawing.Imaging.ImageFormat.Png);
                    form.Report(outp);
                    outp.AppendLine("--- 自身资源 ---");
                    foreach (string s in mem) outp.AppendLine(s);
                }
                if (sim == 0) form.SaveLiveNow();
                form.ForceClose();
            }
            File.WriteAllText(report, outp.ToString(), new UTF8Encoding(true));
            return 0;
        }
    }

    partial class Monitor
    {
        public int IconCount { get { return icons.Count; } }
        public int SeriesCount { get { return series.Count; } }
        public void SaveLiveNow() { SaveLive(); }
        public void ForceClose() { reallyExit = true; Close(); }

        // 仅自测：预先填入最近 N 分钟的模拟实时数据
        public void Simulate(int minutes, string rising)
        {
            List<ProcRow> rows0 = SampleProcesses().Where(r => r.Name != "Idle").OrderByDescending(r => r.PrivMB).Take(40).ToList();
            int n = Math.Min(RingSize, minutes * 12); DateTime t0 = DateTime.UtcNow.AddMinutes(-minutes);
            Random rnd = new Random(7);
            for (int i = 0; i < n; i++)
            {
                DateTime t = t0.AddSeconds(i * 5); double f = i / (double)Math.Max(1, n - 1);
                foreach (ProcRow r in rows0) Record(r.Name, r.Name == rising ? r.PrivMB - 250 * (1 - f) : r.PrivMB * (1 + (rnd.NextDouble() - 0.5) * 0.02), t);
                Record("sys:mem", 19 + f + rnd.NextDouble() * 0.3, t); Record("sys:cpu", 20 + 15 * Math.Sin(i / 20.0) + rnd.NextDouble() * 8, t);
                Record("sys:dr", Math.Max(0, rnd.NextDouble() * 3 - 1), t); Record("sys:dw", Math.Max(0, rnd.NextDouble() * 6 - 2 + (i % 90 < 5 ? 40 : 0)), t);
                Record("sys:self", 40 + rnd.NextDouble() * 4, t);
            }
        }

        // 自测报告：卡片、结论、问题、评级
        public void Report(StringBuilder o)
        {
            foreach (BufferedPanel c in cardList) { CardData d = (CardData)c.Tag; o.AppendFormat("{0}: {1} [{2}] {3}\r\n", d.Tag, d.Value, d.Badge, d.Sub); }
            o.AppendFormat("WATCHDOG: {0} [{1}] {2}\r\n", dog.Value, dog.Badge, dog.Sub);
            o.AppendFormat("内存 TOP: {0}\r\n", string.Join("，", ((CardData)cardMem.Tag).Top.Select(t => t.Key + " " + (int)t.Value)));
            o.AppendFormat("结论: {0} | {1}\r\n", verdict[0], verdict[2]);
            foreach (Issue i in issues) o.AppendFormat("  - [{0}] {1} | {2} | -> {3}\r\n", i.Level, i.Title, i.Sub, i.Target);
            o.AppendLine("评级:");
            foreach (KeyValuePair<string, Rating> kv in ratings)
                if (kv.Value.Text != "数据不足") o.AppendFormat("  {0}: {1}(级别 {2}) | {3} | {4} | {5}\r\n", kv.Key, kv.Value.Text, kv.Value.Level, kv.Value.Trend, kv.Value.Note, kv.Value.Forecast);
            o.AppendLine("主按钮: " + btnPrimary.Text);
            o.AppendFormat("规则 {0} 条，监控 {1} 个，忽略 {2} 项，看门狗任务 {3}，历史记录 {4} 个程序 / 整机 {5} 条\r\n",
                rules.Count, watched.Count, ActiveIgnores().Count, taskInstalled ? "已安装" : "未安装", hist.Count, sys.Count);
        }
    }
}
