// 右上角"当前用户"：头像（点击上传）、名称（点击修改）、设备信息。不是登录，只是展示
// 头像存在 avatar.png，名称存在 profile.json（都只在本机，不上传）
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using Microsoft.Win32;

namespace WatchDog
{
    partial class Monitor
    {
        BufferedPanel profile;
        Bitmap avatar;                 // 缩到 128×128 后的头像，只有一张
        string userName = Environment.UserName;
        string osName = "", cpuName = "", gpuName = "", diskTxt = "";
        DateTime lastDiskInfo = DateTime.MinValue;
        const int ProfileH = 180, AvX = 14, AvY = 36, AvS = 72;

        string AvatarPath { get { return Path.Combine(RulesDir, "avatar.png"); } }
        string ProfilePath { get { return Path.Combine(RulesDir, "profile.json"); } }

        void BuildProfile()
        {
            profile = new BufferedPanel(); profile.Dock = DockStyle.Top; profile.Height = ProfileH; profile.Cursor = Cursors.Hand;
            profile.Paint += PaintProfile; profile.MouseClick += ProfileClick;
        }

        // 设备信息只在启动时读一次（磁盘每 10 分钟更新一次）
        void LoadProfile()
        {
            try
            {
                if (File.Exists(ProfilePath))
                {
                    Dictionary<string, object> d = Json.Parse(Json.ReadFile(ProfilePath)) as Dictionary<string, object>;
                    string n = d != null ? Json.Str(d, "name") : null;
                    if (!string.IsNullOrEmpty(n)) userName = n;
                }
            }
            catch { }
            try { if (File.Exists(AvatarPath)) SetAvatar(AvatarPath, false); } catch { }
            osName = ReadOs(); cpuName = ReadCpu(); gpuName = ReadGpu();
            UpdateDiskInfo();
        }

        static string Reg(string key, string name)
        {
            try { using (RegistryKey k = Registry.LocalMachine.OpenSubKey(key)) { object v = k == null ? null : k.GetValue(name); return v == null ? null : v.ToString().Trim(); } }
            catch { return null; }
        }
        static string ReadOs()
        {
            const string k = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
            string name = Reg(k, "ProductName") ?? "Windows", ver = Reg(k, "DisplayVersion"), build = Reg(k, "CurrentBuild");
            int b; if (int.TryParse(build, out b) && b >= 22000) name = name.Replace("Windows 10", "Windows 11");   // 注册表里 Win11 仍写着 Windows 10
            name = name.Replace("Pro for Workstations", "Pro 工作站版").Replace("Windows ", "Win ");
            return name + (ver != null ? " " + ver : "") + (build != null ? "（" + build + "）" : "");
        }
        static string ReadCpu()
        {
            string n = Reg(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString") ?? "?";
            n = n.Replace("(R)", "").Replace("(TM)", "").Replace(" CPU", "");
            while (n.Contains("  ")) n = n.Replace("  ", " ");
            return n + " · " + Environment.ProcessorCount + " 线程";
        }
        static string ReadGpu()
        {
            // 显卡类设备；跳过微软基本显示 / 远程桌面这类虚拟设备，独立显卡排在前面
            List<string> all = new List<string>();
            const string cls = @"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}";
            try
            {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(cls))
                    if (k != null)
                        foreach (string sub in k.GetSubKeyNames())
                        {
                            string d = Reg(cls + "\\" + sub, "DriverDesc");
                            if (d == null || d.StartsWith("Microsoft") || d.Contains("Remote") || d.Contains("Virtual") || all.Contains(d)) continue;
                            all.Add(d);
                        }
            }
            catch { }
            all = all.OrderBy(d => d.Contains("NVIDIA") || d.Contains("Radeon RX") || d.Contains("Arc") ? 0 : 1).ToList();
            return all.Count == 0 ? "?" : string.Join(" + ", all.Take(2));
        }
        void UpdateDiskInfo()
        {
            if ((DateTime.Now - lastDiskInfo).TotalMinutes < 10) return;
            lastDiskInfo = DateTime.Now;
            double total = 0, free = 0; int n = 0;
            try
            {
                foreach (DriveInfo d in DriveInfo.GetDrives())
                {
                    try { if (d.DriveType != DriveType.Fixed || !d.IsReady) continue; total += d.TotalSize; free += d.AvailableFreeSpace; n++; }
                    catch { }
                }
            }
            catch { }
            diskTxt = string.Format("共 {0} · 可用 {1}", FmtSize(total), FmtSize(free));
        }
        static string FmtSize(double b) { return b >= 1e12 ? string.Format("{0:N1} TB", b / 1099511627776.0) : string.Format("{0:N0} GB", b / 1073741824.0); }
        static string Span(TimeSpan t)
        {
            return t.TotalDays >= 1 ? string.Format("{0} 天 {1} 小时", (int)t.TotalDays, t.Hours) : t.TotalHours >= 1 ? string.Format("{0} 小时 {1} 分", (int)t.TotalHours, t.Minutes) : string.Format("{0} 分钟", (int)t.TotalMinutes);
        }

        void SetAvatar(string file, bool save)
        {
            Bitmap b = new Bitmap(128, 128);
            using (Image src = Image.FromFile(file))
            using (Graphics g = Graphics.FromImage(b))
            {
                // 居中裁成正方形再缩小
                int s = Math.Min(src.Width, src.Height);
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.DrawImage(src, new Rectangle(0, 0, 128, 128), new Rectangle((src.Width - s) / 2, (src.Height - s) / 2, s, s), GraphicsUnit.Pixel);
            }
            if (save) b.Save(AvatarPath, ImageFormat.Png);
            Bitmap old = avatar; avatar = b; if (old != null) old.Dispose();
        }

        void ProfileClick(object s, MouseEventArgs e)
        {
            if (e.X >= AvX && e.X < AvX + AvS && e.Y >= AvY && e.Y < AvY + AvS)
            {
                using (OpenFileDialog dlg = new OpenFileDialog())
                {
                    dlg.Title = "选一张头像图片"; dlg.Filter = "图片|*.png;*.jpg;*.jpeg;*.bmp;*.gif";
                    if (dlg.ShowDialog(this) != DialogResult.OK) return;
                    try { SetAvatar(dlg.FileName, true); } catch (Exception ex) { Say("这张图片打不开：" + ex.Message); return; }
                }
                profile.Invalidate();
                return;
            }
            if (e.Y >= AvY && e.Y < AvY + 26 && e.X > AvX + AvS)
            {
                string ans = Microsoft.VisualBasic.Interaction.InputBox("显示的名称：", "WATCHDOG // 当前用户", userName);
                if (string.IsNullOrWhiteSpace(ans)) return;
                userName = ans.Trim().Length > 24 ? ans.Trim().Substring(0, 24) : ans.Trim();
                Dictionary<string, object> d = new Dictionary<string, object>(); d["name"] = userName;
                try { Json.WriteFile(ProfilePath, d); } catch (Exception ex) { Say("没能保存：" + ex.Message); }
                profile.Invalidate();
            }
        }

        void PaintProfile(object s, PaintEventArgs e)
        {
            Graphics g = e.Graphics; int w = profile.Width, h = profile.Height;
            Frame(g, w, h, "OPERATOR", "当前用户", false);
            // 头像：切角框 + 扫描线 + 荧光蓝边
            PointF[] cut = CutPoly(AvX, AvY, AvS, AvS, 14);
            using (GraphicsPath path = new GraphicsPath())
            {
                path.AddPolygon(cut);
                g.FillPath(bDeep, path);
                Region keep = g.Clip;
                g.SetClip(path, CombineMode.Intersect);
                if (avatar != null) { g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.DrawImage(avatar, AvX, AvY, AvS, AvS); }
                else
                {
                    g.FillEllipse(bDimLine, AvX + 24, AvY + 12, 24, 24);
                    g.FillEllipse(bDimLine, AvX + 10, AvY + 42, 52, 44);
                }
                for (int y = AvY + 1; y < AvY + AvS; y += 3) g.DrawLine(pScan, AvX, y, AvX + AvS, y);
                g.Clip = keep; keep.Dispose();
                g.DrawPolygon(pCyanThin, cut);
            }
            if (avatar == null) Txt(g, "点击上传", fCN, cGray, AvX, AvY + AvS - 20, AvS, 16, tfC);

            int x = AvX + AvS + 14, tw = w - x - 14;
            Txt(g, userName, fCNbig, cCyan, x, AvY - 2, tw - 70, 26);
            Badge(g, "ONLINE", 0, w - 84, AvY, 70, 18);
            TimeSpan up = TimeSpan.FromMilliseconds(Native.GetTickCount64());
            DateTime boot = DateTime.Now - up;
            Row(g, "OS", osName, x, AvY + 26, tw);
            Row(g, "BOOT", boot.ToString("MM-dd HH:mm") + " 开机", x, AvY + 44, tw);
            Row(g, "UP", "已运行 " + Span(up), x, AvY + 62, tw);
            int y2 = AvY + AvS + 8;
            g.FillRectangle(bDimLine, 14, y2 - 4, w - 28, 1);
            Row(g, "CPU", cpuName, 14, y2, w - 28);
            Row(g, "GPU", gpuName, 14, y2 + 18, w - 28);
            double ramGB = Native.Mem().ullTotalPhys / 1073741824.0;
            Row(g, "MEM", string.Format("{0:N0} GB 内存   ", Math.Round(ramGB)), 14, y2 + 36, 130);
            Row(g, "DISK", diskTxt, 150, y2 + 36, w - 164);
        }
        // 一行设备信息：左边小标签，右边内容
        void Row(Graphics g, string tag, string text, int x, int y, int w)
        {
            Txt(g, tag, fMono, cAccent, x, y, 38, 17);
            Txt(g, text, fCN, cText, x + 38, y, w - 38, 17);
        }
    }
}
