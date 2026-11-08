// 启动、每 5 秒刷新、各个操作（修复 / 重启 / 结束 / 监控 / 忽略）
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace WatchDog
{
    partial class Monitor
    {
        readonly bool selfTest;

        public Monitor(string toolDir, string dataDir, bool selfTest, string select, string startChart, string startRange)
        {
            ToolDir = toolDir; DataDir = dataDir; RulesDir = toolDir;
            LogFile = Path.Combine(toolDir, "MemWatchdog.log");
            LiveFile = Path.Combine(dataDir, "live.bin");
            this.selfTest = selfTest;
            selected = string.IsNullOrEmpty(select) ? null : select;
            chartMode = startChart; chartRange = startRange;
            CreateTheme();
            BuildUI();
            if (!selfTest) BuildTray();
        }

        // 窗口出现前：读回实时数据，取一次基准（CPU / 磁盘 / 读写速度要两次之间的差值）
        public void Prepare(bool loadLive)
        {
            if (loadLive) LoadLive();
            DiskPerf.Open();
            Native.Cpu(); SampleProcesses();
        }

        public void StartTimer()
        {
            timer = new Timer(); timer.Interval = 5000;
            timer.Tick += delegate { RefreshAll(); };
            Shown += delegate { RefreshAll(); timer.Start(); };
            FormClosed += delegate { timer.Stop(); SaveLive(); DiskPerf.Close(); };
        }

        // 再次双击 WatchDog.exe 时，新开的那个会发信号过来：把窗口从托盘里叫出来
        public void ListenForShow(System.Threading.EventWaitHandle ev)
        {
            showTimer = new Timer(); showTimer.Interval = 400;
            showTimer.Tick += delegate { if (ev.WaitOne(0)) ShowFromTray(); };
            showTimer.Start();
        }

        // ---------- 刷新 ----------
        public void RefreshAll()
        {
            // 缩到托盘（窗口隐藏）时照常记录；只有"最小化但没进托盘"的一瞬间跳过
            if (Visible && WindowState == FormWindowState.Minimized) return;
            tick++;
            if (tick % 60 == 0 && !selfTest) SaveLive();   // 每 5 分钟存一次盘，防止意外关机丢数据
            DateTime now = DateTime.Now, nowU = DateTime.UtcNow;
            if (now >= forceSlowAt) { forceSlowAt = DateTime.MaxValue; lastSlow = DateTime.MinValue; histSig = ""; rulesSig = ""; ignoreSig = -1; }
            if ((now - lastSlow).TotalSeconds >= 60) { lastSlow = now; UpdateSlow(); }
            SetText(btnInstall, taskInstalled ? "卸载看门狗" : "安装看门狗");

            // 内存
            Native.MEMSTAT m = Native.Mem();
            double totalGB = m.ullTotalPhys / 1073741824.0, usedGB = (m.ullTotalPhys - m.ullAvailPhys) / 1073741824.0;
            double pct = 100 * usedGB / totalGB;
            double commitGB = (m.ullTotalPageFile - m.ullAvailPageFile) / 1073741824.0, limitGB = m.ullTotalPageFile / 1073741824.0;
            double worst = Math.Max(pct, 100 * commitGB / limitGB);
            int lvl = worst < 70 ? 0 : worst < 85 ? 1 : 2;
            SetCard(cardMem, string.Format("{0:N1} / {1:N0} GB", usedGB, totalGB), string.Format("{0}  {1:N0}%", new[] { "正常", "偏高", "紧张" }[lvl], pct), lvl,
                string.Format("已提交 {0:N1} / {1:N0} GB · 70% 以下都算正常", commitGB, limitGB), pct);
            Record("sys:mem", usedGB, nowU);
            if (tray != null) tray.Text = string.Format("WatchDog · 内存 {0:N1} / {1:N0} GB ({2:N0}%)", usedGB, totalGB, pct);

            // 进程采样 + 规则
            double cpuNow = Native.Cpu();
            cpuHist.Enqueue(cpuNow);
            while (cpuHist.Count > 6) cpuHist.Dequeue();
            double cpuAvg = cpuHist.Average();
            Record("sys:cpu", cpuNow, nowU);
            List<ProcRow> all = SampleProcesses().Where(r => r.Name != "Idle" && r.Name != "Memory Compression").ToList();
            Dictionary<string, ProcRow> byName = new Dictionary<string, ProcRow>();
            foreach (ProcRow r in all) byName[r.Name] = r;
            rows = byName;
            List<ProcRow> real = all.Where(r => !r.Name.StartsWith("svc:")).ToList();
            // 实时数据：内存前 40 + 规则 / 监控涉及的 + 选中的
            Dictionary<string, ProcRow> rec = new Dictionary<string, ProcRow>();
            foreach (ProcRow r in real.OrderByDescending(r => r.PrivMB).Take(40)) rec[r.Name] = r;
            foreach (Rule r in rules) if (r.Process != null && byName.ContainsKey(r.Process)) rec[r.Process] = byName[r.Process];
            if (selected != null && byName.ContainsKey(selected)) rec[selected] = byName[selected];
            foreach (ProcRow r in rec.Values) Record(r.Name, r.PrivMB, nowU);
            EvalRules();
            Dictionary<string, Rating> rts = new Dictionary<string, Rating>();
            foreach (ProcRow r in all) rts[r.Name] = GetRating(r.Name, r.PrivMB);
            ratings = rts;

            // CPU（最近 30 秒平均）
            lvl = cpuAvg < 50 ? 0 : cpuAvg < 85 ? 1 : 2;
            SetCard(cardCpu, string.Format("{0:N0} %", cpuAvg), new[] { "正常", "较忙", "很忙" }[lvl], lvl,
                "最忙：" + string.Join("，", real.OrderByDescending(r => r.CpuPct).Take(2).Select(r => string.Format("{0} {1:N1}%", r.Name, r.CpuPct))), cpuAvg);

            // 磁盘
            disk = DiskPerf.Read();
            double rd = disk[0] / 1048576, wr = disk[1] / 1048576, busyPct = disk[2];
            Record("sys:dr", rd, nowU); Record("sys:dw", wr, nowU);
            ProcRow topIo = real.OrderByDescending(r => r.IoMBs).FirstOrDefault();
            lvl = busyPct < 60 ? 0 : busyPct < 90 ? 1 : 2;
            SetCard(cardDisk, string.Format("R {0:N1}  W {1:N1} MB/s", rd, wr), string.Format("{0}  {1:N0}%", new[] { "正常", "较忙", "很忙" }[lvl], busyPct), lvl,
                topIo != null && topIo.IoMBs >= 0.1 ? string.Format("读写最多：{0} {1:N1} MB/s", topIo.Name, topIo.IoMBs) : "没有程序在大量读写", busyPct);

            // 本窗口自己的占用
            using (Process me = Process.GetCurrentProcess())
            {
                selfMB = me.PrivateMemorySize64 / 1048576.0;
                selfGdi = Native.GetGuiResources(me.Handle, 0);
                double c = me.TotalProcessorTime.TotalMilliseconds;
                if (selfPrevCpuMs >= 0) selfCpu = 100 * (c - selfPrevCpuMs) / Math.Max(1, (nowU - selfPrevT).TotalMilliseconds) / Environment.ProcessorCount;
                selfPrevCpuMs = c; selfPrevT = nowU;
            }
            Record("sys:self", selfMB, nowU);

            // 看门狗 + 自身占用
            SysRow last = sys.Count > 0 ? sys[sys.Count - 1] : null;
            string selfTxt = string.Format("本窗口 {0:N0} MB · CPU {1:N1}%", selfMB, selfCpu);
            if (!taskInstalled) SetCard(cardDog, "未安装", "离线", 1, selfTxt + " · 看门狗未安装", -1);
            else if (last == null) SetCard(cardDog, "等待首次检查", "待命", 1, selfTxt + " · 等待第一次检查", -1);
            else
            {
                double mins = (now - last.T).TotalMinutes; bool ok = mins <= 25;
                SetCard(cardDog, "上次 " + Ago(last.T), ok ? "运行中" : "可能停了", ok ? 0 : 2, string.Format("{0} · 后台每次 {1:N1} 秒", selfTxt, last.RunMs / 1000), Math.Min(100, mins * 10));
            }

            BuildIssues(all, real);

            // 程序列表：内存前 25 + 有问题 / 需要留意 / 大量读写 / 被监控的；按当前排序方式排
            List<ProcRow> list = real.OrderByDescending(r => r.PrivMB).Take(25).ToList();
            HashSet<string> inList = new HashSet<string>(list.Select(r => r.Name));
            foreach (ProcRow r in all)
                if (!inList.Contains(r.Name) && (ratings[r.Name].Level >= 1 || r.IoMBs >= HeavyIoMBs || watched.ContainsKey(r.Name))) { list.Add(r); inList.Add(r.Name); }
            switch (sortMode)
            {
                case "mem": list = list.OrderByDescending(r => r.PrivMB).ToList(); break;
                case "cpu": list = list.OrderByDescending(r => r.CpuPct).ToList(); break;
                case "io": list = list.OrderByDescending(r => r.IoMBs).ToList(); break;
                default: list = list.OrderByDescending(r => ratings[r.Name].Score + (r.IoMBs >= HeavyIoMBs ? 40 : 0)).ThenByDescending(r => r.PrivMB).ToList(); break;
            }
            // 原地更新列表（不清空重建）：只改变了的格子，滚动位置和选中都保留，不闪
            updating = true;
            try
            {
                while (lv.Items.Count > list.Count) lv.Items.RemoveAt(lv.Items.Count - 1);
                for (int i = 0; i < list.Count; i++)
                {
                    ProcRow r = list[i]; Rating rt = ratings[r.Name];
                    ListViewItem it;
                    if (i < lv.Items.Count) it = lv.Items[i];
                    else { it = new ListViewItem(""); for (int k = 1; k < 8; k++) it.SubItems.Add(""); lv.Items.Add(it); }
                    string desc; Desc.TryGetValue(r.Name, out desc);
                    string[] vals = { r.Name, desc ?? "", string.Format("{0:N0}", r.PrivMB), string.Format("{0:N1}", r.CpuPct), string.Format("{0:N1}", r.IoMBs),
                        rt.Text, rt.Trend, rt.Forecast.Length > 0 ? rt.Forecast : rt.Note };
                    for (int k = 0; k < 8; k++) if (it.SubItems[k].Text != vals[k]) it.SubItems[k].Text = vals[k];
                    if (!(it.Tag is int) || (int)it.Tag != rt.Level) { it.Tag = rt.Level; lv.Invalidate(it.Bounds); }
                    bool sel = r.Name == selected;
                    if (it.Selected != sel) it.Selected = sel;
                }
            }
            finally { updating = false; }
            FitColumns();
            UpdateDetailButtons();
            int nIg = ActiveIgnores().Count;
            SetText(btnIgnored, nIg > 0 ? "已忽略的问题（" + nIg + "）" : "已忽略的问题");

            header.Invalidate(); status.Invalidate(); chart.Invalidate(); detail.Invalidate();
        }

        // 体检结论：规则命中 + 稳定性问题 + 大量读写
        void BuildIssues(List<ProcRow> all, List<ProcRow> real)
        {
            List<Issue> list = new List<Issue>(); HashSet<string> seen = new HashSet<string>();
            foreach (Hit h in hits)
            {
                list.Add(NewIssue(h.Rule.Title, h.Why, h.Rule.FixType == "none" ? 1 : 2, h.Target, "rule:" + h.Rule.Id));
                if (h.Target != null) seen.Add(h.Target);
            }
            foreach (ProcRow r in all)
            {
                if (seen.Contains(r.Name)) continue;
                Rating rt = ratings[r.Name];
                if (rt.Level < 1) continue;   // 正常的、或已被忽略 / 确认正常的
                string label = Label(r.Name);
                if (rt.Text == "疑似泄漏") list.Add(NewIssue(label + " 疑似内存泄漏", rt.Note, 2, r.Name, "prog:" + r.Name));
                else if (rt.Text == "缓慢上涨") list.Add(NewIssue(label + " 在缓慢上涨", rt.Forecast, 1, r.Name, "prog:" + r.Name));
                else if (rt.Text == "短时上涨")
                {
                    Ring ring; double[] st = series.TryGetValue(r.Name, out ring) ? ring.Stats(GapSec) : null;
                    if (st != null && st[2] >= 100) list.Add(NewIssue(label + " 在上涨（观察中）", rt.Note, 1, r.Name, "prog:" + r.Name));
                }
            }
            foreach (ProcRow r in real.Where(x => x.IoMBs >= HeavyIoMBs).OrderByDescending(x => x.IoMBs).Take(2))
            {
                if (IsIgnored("io:" + r.Name) != null || seen.Contains(r.Name)) continue;
                list.Add(NewIssue(Label(r.Name) + " 正在大量读写", string.Format("{0:N1} MB/s，长时间这样会拖慢硬盘；如果它不该这么忙，可以重启它", r.IoMBs), 1, r.Name, "io:" + r.Name));
            }
            list = list.OrderByDescending(i => i.Level).ToList();
            int nBad = list.Count(i => i.Level == 2), nWarn = list.Count(i => i.Level == 1);
            int nLong = analysis.Count, nShort = ratings.Values.Count(x => x.Trend.EndsWith("分钟"));
            string basis = string.Format("已评级 {0} 个程序（长期 {1} · 实时 {2}）· 规则 {3} 条", nLong + nShort, nLong, nShort, rules.Count);
            verdict = nBad > 0 ? new[] { "发现 " + nBad + " 个问题", "2", basis }
                : nWarn > 0 ? new[] { "有 " + nWarn + " 项需要留意", "1", basis }
                : nLong + nShort == 0 ? new[] { "数据收集中", "1", "窗口打开满 10 分钟后给出初步判断" }
                : new[] { "电脑健康", "0", basis };
            if (lastAction.Length > 0 && list.Count < 3) list.Add(NewIssue("看门狗最近一次动作", lastAction, -1, null, null));
            issues = list;
            diag.Invalidate();
        }
        static Issue NewIssue(string title, string sub, int level, string target, string key)
        {
            Issue i = new Issue(); i.Title = title; i.Sub = sub; i.Level = level; i.Target = target; i.Key = key; return i;
        }
        static string Label(string name) { string d; return Desc.TryGetValue(name, out d) ? name + "（" + d + "）" : name; }

        // ---------- 操作 ----------
        bool Ask(string msg) { return MessageBox.Show(this, msg, "WATCHDOG", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes; }
        void Say(string msg) { MessageBox.Show(this, msg, "WATCHDOG", MessageBoxButtons.OK, MessageBoxIcon.Information); }
        static void StartShell(string file, string args)
        {
            try { Process.Start(new ProcessStartInfo(file, args) { UseShellExecute = true }).Dispose(); } catch { }
        }
        // 看门狗、修复脚本仍是 PowerShell 脚本（只在需要时运行几秒）
        void RunTool(string file, string args)
        {
            StartShell("powershell.exe", string.Format("-NoProfile -ExecutionPolicy Bypass -File \"{0}\" {1}", Path.Combine(ToolDir, file), args));
        }
        bool RunElevated(string file, string args)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", string.Format("-NoProfile -ExecutionPolicy Bypass -File \"{0}\" {1}", Path.Combine(ToolDir, file), args));
                psi.UseShellExecute = true; psi.Verb = "runas"; psi.WindowStyle = ProcessWindowStyle.Hidden;
                Process.Start(psi).Dispose(); return true;
            }
            catch { return false; }   // 用户在管理员确认窗口点了"否"
        }
        void ReloadSoon(int sec) { forceSlowAt = DateTime.Now.AddSeconds(sec); }
        string PathOf(string name) { ProcRow r; return name != null && rows.TryGetValue(name, out r) ? Native.ImagePath(r.Pid) : null; }

        void SelectTarget(string name)
        {
            selected = name;
            updating = true;
            try { foreach (ListViewItem it in lv.Items) { bool sel = it.Text == name; if (it.Selected != sel) it.Selected = sel; if (sel) it.EnsureVisible(); } }
            finally { updating = false; }
            UpdateDetailButtons(); SetChartMode("proc"); detail.Invalidate();
        }

        static Process[] ByName(string name) { try { return Process.GetProcessesByName(name); } catch { return new Process[0]; } }
        static void DisposeAll(Process[] ps) { foreach (Process p in ps) p.Dispose(); }

        // 重启一个程序（或服务）。noAsk 用于"一键修复"时已统一确认过。
        bool RestartTarget(string name, bool noAsk)
        {
            if (name == null) { Say("先在列表里选一个程序。"); return false; }
            if (name.StartsWith("svc:"))
            {
                string svc = name.Substring(4);
                if (!noAsk && !Ask("将重启系统服务 " + svc + "（需要管理员权限，会弹出确认窗口）。确定吗？")) return false;
                bool ok = RunElevated("Restart-ServiceHard.ps1", "-Name " + svc); ReloadSoon(8); return ok;
            }
            if (Protected.Contains(name)) { Say(name + " 是系统关键进程，不能在这里重启。"); return false; }
            Process[] procs = ByName(name);
            try
            {
                if (procs.Length == 0) { Say(name + " 已经不在运行了。"); return false; }
                int me = Process.GetCurrentProcess().Id;
                if (procs.Any(p => p.Id == me)) { Say("这是监控窗口自己。"); return false; }
                string path = PathOf(name);
                if (path == null) { Say("拿不到 " + name + " 的程序路径（可能是管理员或系统进程），无法自动重新打开。"); return false; }
                if (!noAsk && !Ask(string.Format("将结束 {0}（{1} 个进程）并重新打开：\n{2}\n\n这个程序里没保存的内容可能会丢失。确定吗？", name, procs.Length, path))) return false;
                int failed = 0;
                foreach (Process p in procs) try { p.Kill(); } catch { failed++; }
                if (failed > 0) { Say(name + " 有 " + failed + " 个进程结束失败（可能需要管理员权限）。"); return false; }
                System.Threading.Thread.Sleep(2000);
                Process[] again = ByName(name);
                if (again.Length == 0)
                    try { Process.Start(new ProcessStartInfo(path) { WorkingDirectory = Path.GetDirectoryName(path), UseShellExecute = true }).Dispose(); } catch { }
                DisposeAll(again);
                ReloadSoon(8); return true;
            }
            finally { DisposeAll(procs); }
        }
        // 按规则修复
        bool ApplyFix(Hit hit, bool noAsk)
        {
            Rule r = hit.Rule;
            switch (r.FixType)
            {
                case "restartProcess": return RestartTarget(r.Process, noAsk);
                case "restartService":
                    if (!noAsk && !Ask(string.Format("{0}\n\n{1}\n\n将执行：{2}（需要管理员权限）。确定吗？", r.Title, r.Cause, r.FixLabel))) return false;
                    { bool ok = RunElevated("Restart-ServiceHard.ps1", "-Name " + r.FixService); ReloadSoon(8); return ok; }
                case "script":
                    if (!noAsk && !Ask(string.Format("{0}\n\n{1}\n\n将执行：{2}（需要管理员权限）。确定吗？", r.Title, r.Cause, r.FixLabel))) return false;
                    RunTool(r.FixScript, "-Quiet"); ReloadSoon(8); return true;
                default:
                    Say(string.Format("{0}\n\n{1}\n\n建议：{2}", r.Title, r.Cause, r.FixLabel)); return false;
            }
        }
        void FixSelected()
        {
            Hit hit = null; if (selected != null) hitByTarget.TryGetValue(selected, out hit);
            if (hit != null) ApplyFix(hit, false); else RestartTarget(selected, false);
        }
        void KillTarget(string name)
        {
            if (name == null) { Say("先在列表里选一个程序。"); return; }
            if (name.StartsWith("svc:") || Protected.Contains(name)) { Say(name + " 是系统服务或关键进程，不能在这里结束。"); return; }
            Process[] procs = ByName(name);
            try
            {
                if (procs.Length == 0) return;
                int me = Process.GetCurrentProcess().Id;
                if (procs.Any(p => p.Id == me)) { Say("这是监控窗口自己。要退出请右键托盘图标 → 退出。"); return; }
                if (!Ask(string.Format("将结束 {0}（{1} 个进程），不会自动重新打开。没保存的内容可能会丢失。确定吗？", name, procs.Length))) return;
                int failed = 0;
                foreach (Process p in procs) try { p.Kill(); } catch { failed++; }
                if (failed > 0) Say("有 " + failed + " 个进程结束失败（可能需要管理员权限）。");
            }
            finally { DisposeAll(procs); }
        }
        void OpenLocation(string name)
        {
            string path = PathOf(name);
            if (path != null) StartShell("explorer.exe", "/select,\"" + path + "\""); else Say("拿不到这个程序的路径。");
        }
        // 一键修复：所有命中规则且有修复方法的问题 + 没有规则但疑似泄漏的程序（重启它）
        void FixAll()
        {
            List<KeyValuePair<string, object>> todo = new List<KeyValuePair<string, object>>(); HashSet<string> seen = new HashSet<string>();
            foreach (Hit h in hits)
                if (h.Rule.FixType != "none" && !seen.Contains(h.Target ?? "")) { todo.Add(new KeyValuePair<string, object>(h.Rule.FixLabel, h)); seen.Add(h.Target ?? ""); }
            foreach (ProcRow r in rows.Values)
            {
                if (seen.Contains(r.Name) || Protected.Contains(r.Name)) continue;
                Rating rt; if (ratings.TryGetValue(r.Name, out rt) && rt.Text == "疑似泄漏" && rt.Level >= 2) { todo.Add(new KeyValuePair<string, object>("重启 " + r.Name + "（疑似泄漏）", r.Name)); seen.Add(r.Name); }
            }
            if (todo.Count == 0) { Say("现在没有需要修复的问题。"); return; }
            if (!Ask("将依次执行：\n\n  " + string.Join("\n  ", todo.Select(t => t.Key)) + "\n\n相关程序里没保存的内容可能会丢失；部分操作需要管理员权限。确定吗？")) return;
            int ok = 0;
            foreach (KeyValuePair<string, object> t in todo)
                if (t.Value is string ? RestartTarget((string)t.Value, true) : ApplyFix((Hit)t.Value, true)) ok++;
            Say("已执行 " + ok + " / " + todo.Count + " 项。");
        }
        void RunCheckNow()
        {
            if (taskInstalled && RunTask("MemWatchdog")) Say("已开始检查，大约 5 秒后完成，结果会自动刷新到界面上。");
            else RunElevated("MemWatchdog.ps1", "");
            ReloadSoon(8);
        }
        static bool RunTask(string name)
        {
            object svc = null;
            try
            {
                Type t = Type.GetTypeFromProgID("Schedule.Service"); svc = Activator.CreateInstance(t);
                t.InvokeMember("Connect", System.Reflection.BindingFlags.InvokeMethod, null, svc, new object[0]);
                object folder = t.InvokeMember("GetFolder", System.Reflection.BindingFlags.InvokeMethod, null, svc, new object[] { "\\" });
                object task = folder.GetType().InvokeMember("GetTask", System.Reflection.BindingFlags.InvokeMethod, null, folder, new object[] { name });
                object run = task.GetType().InvokeMember("Run", System.Reflection.BindingFlags.InvokeMethod, null, task, new object[] { null });
                if (run != null) System.Runtime.InteropServices.Marshal.ReleaseComObject(run);
                System.Runtime.InteropServices.Marshal.ReleaseComObject(task);
                System.Runtime.InteropServices.Marshal.ReleaseComObject(folder);
                return true;
            }
            catch { return false; }
            finally { if (svc != null) System.Runtime.InteropServices.Marshal.ReleaseComObject(svc); }
        }

        // ---- 个人规则文件（rules.local.json）读写：右键"用看门狗监控"就是往这里加一条规则 ----
        string LocalRulesPath { get { return Path.Combine(RulesDir, "rules.local.json"); } }
        List<Dictionary<string, object>> ReadLocalRules()
        {
            if (!File.Exists(LocalRulesPath)) return new List<Dictionary<string, object>>();
            try { return Json.Objects(Json.Parse(Json.ReadFile(LocalRulesPath))); }
            catch (Exception ex) { throw new Exception("rules.local.json 格式有误：" + ex.Message); }
        }
        void WriteLocalRules(List<Dictionary<string, object>> list)
        {
            Json.WriteFile(LocalRulesPath, list);
            rulesSig = ""; LoadRules();
        }
        void AddWatch(string name, bool auto)
        {
            if (name == null) return;
            ProcRow r; double cur = rows.TryGetValue(name, out r) ? r.PrivMB : 0;
            int def = (int)(Math.Ceiling(Math.Max(cur * 1.5, cur + 300) / 100) * 100);
            string what = auto ? "自动重启它" : "提醒你";
            string ans = Microsoft.VisualBasic.Interaction.InputBox(
                string.Format("让看门狗监控 {0}（现在 {1:N0} MB）。\n\n内存超过多少 MB 时{2}？\n\n看门狗每 10 分钟检查一次，也会专门记录它的内存走势。", name, cur, what),
                "WATCHDOG · 监控这个程序", def.ToString());
            if (string.IsNullOrEmpty(ans)) return;
            int limit;
            if (!int.TryParse(ans.Trim(), out limit) || limit <= 0) { Say("请输入一个正整数（单位 MB）。"); return; }
            List<Dictionary<string, object>> list;
            try { list = ReadLocalRules().Where(d => Json.Str(d, "id") != "watch-" + name).ToList(); } catch (Exception ex) { Say(ex.Message); return; }
            Dictionary<string, object> fix = new Dictionary<string, object>();
            if (name.StartsWith("svc:")) { fix["type"] = auto ? "restartService" : "none"; fix["service"] = name.Substring(4); fix["label"] = "重启服务 " + name.Substring(4); }
            else { fix["type"] = auto ? "restartProcess" : "none"; fix["label"] = auto ? "重启 " + name : "方便时手动重启 " + name; }
            Dictionary<string, object> when = new Dictionary<string, object>(); when["process"] = name; when["minMB"] = limit;
            Dictionary<string, object> rule = new Dictionary<string, object>();
            rule["id"] = "watch-" + name; rule["title"] = name + " 超过监控上限"; rule["target"] = name; rule["when"] = when;
            rule["cause"] = "你在监控窗口里设置的：内存超过 " + limit + " MB 时" + what + "。"; rule["fix"] = fix; rule["auto"] = auto;
            list.Add(rule);
            try { WriteLocalRules(list); } catch (Exception ex) { Say("保存 rules.local.json 失败：" + ex.Message); return; }
            Say(string.Format("已加入看门狗监控：{0} 超过 {1} MB 时{2}。\n规则保存在 rules.local.json，可以随时在右键菜单里取消。", name, limit, what));
            RefreshAll();
        }
        void RemoveWatch(string name)
        {
            List<Dictionary<string, object>> list;
            try { list = ReadLocalRules().Where(d => Json.Str(d, "id") != "watch-" + name).ToList(); } catch (Exception ex) { Say(ex.Message); return; }
            try { WriteLocalRules(list); } catch (Exception ex) { Say("保存 rules.local.json 失败：" + ex.Message); return; }
            RefreshAll();
        }
        void EditRules()
        {
            if (!File.Exists(LocalRulesPath))
            {
                File.WriteAllText(LocalRulesPath, "[]", new System.Text.UTF8Encoding(false));
                StartShell("notepad.exe", "\"" + Path.Combine(RulesDir, "rules.local.example.json") + "\"");
            }
            StartShell("notepad.exe", "\"" + LocalRulesPath + "\"");
            ReloadSoon(20);
        }

        // 选中程序当前的问题：[key, 标题]；没有问题返回 null
        string[] IssueOf(string name)
        {
            if (name == null) return null;
            Hit hit; if (hitByTarget.TryGetValue(name, out hit)) return new[] { "rule:" + hit.Rule.Id, hit.Rule.Title };
            Rating rt; if (ratings.TryGetValue(name, out rt) && rt.Level >= 1) return new[] { "prog:" + name, name + " " + rt.Text };
            ProcRow r; if (rows.TryGetValue(name, out r) && r.IoMBs >= HeavyIoMBs && IsIgnored("io:" + name) == null) return new[] { "io:" + name, name + " 正在大量读写" };
            return null;
        }
        void ShowIgnored()
        {
            List<IgnoreEntry> list = ActiveIgnores();
            if (list.Count == 0) { Say("现在没有被忽略或确认正常的问题。"); return; }
            string lines = string.Join("\n", list.Select(i => string.Format("  · {0}（{1}）", i.Label, i.Type == "normal" ? "已确认正常" : "忽略到 " + UntilOf(i).ToString("MM-dd HH:mm"))));
            if (Ask("下面这些问题现在不会提醒：\n\n" + lines + "\n\n要全部恢复提醒吗？")) { ignores.Clear(); SaveIgnores(); RefreshAll(); }
        }
    }
}
