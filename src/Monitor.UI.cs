// 界面：赛博朋克风格（红黑底 + 荧光蓝 + 珊瑚红边框）。所有画笔 / 画刷 / 字体只创建一次，关闭时释放
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace WatchDog
{
    class CardData { public string Code, Tag, Title, Mode, Value = "--", Badge = "...", Sub = ""; public int Level = -1; public double Pct = -1; }
    class Line { public long[] T; public double[] V; public int Level; public string Name; public PointF? LastPt; }
    class ChartData { public string Title = "", Unit = "", Note = ""; public double FixedMax; public List<Line> Lines = new List<Line>(); }

    partial class Monitor : Form
    {
        // ---------- 主题 ----------
        static readonly Color cBg = Color.FromArgb(14, 9, 12), cPanel = Color.FromArgb(32, 13, 17), cRowA = Color.FromArgb(19, 10, 13),
            cRowB = Color.FromArgb(26, 12, 16), cCyan = Color.FromArgb(94, 246, 255), cYellow = Color.FromArgb(245, 217, 10),
            cRed = Color.FromArgb(255, 40, 60), cAccent = Color.FromArgb(255, 95, 87), cRedDim = Color.FromArgb(92, 30, 33),
            cText = Color.FromArgb(236, 220, 214), cGray = Color.FromArgb(160, 116, 112), cDim = Color.FromArgb(58, 24, 28);
        static Color LevelColor(int l) { return l == 0 ? cCyan : l == 1 ? cYellow : l == 2 ? cRed : cGray; }
        static int Lx(int l) { return l == -1 ? 3 : Math.Max(0, Math.Min(2, l)); }   // 等级 -> 数组下标

        Font fCN, fCNb, fCNbig, fTagB, fNum, fNumCN, fHead, fSmall;
        SolidBrush bBg, bPanel, bRowA, bRowB, bDim, bSel, bRow2, bRow1, bDimLine, bAcc;
        Pen pAcc, pAccDim, pCyan, pScan, pGrid;
        SolidBrush[] bLv = new SolidBrush[4], bFill = new SolidBrush[4];
        Pen[] pGlow = new Pen[4], pCore = new Pen[4];
        List<IDisposable> gdi = new List<IDisposable>();

        const TextFormatFlags tfL = TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;
        const TextFormatFlags tfR = TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;
        const TextFormatFlags tfC = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;
        const TextFormatFlags tfW = TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;

        T Keep<T>(T o) where T : IDisposable { gdi.Add(o); return o; }

        void CreateTheme()
        {
            fCN = Keep(new Font("Microsoft YaHei UI", 9)); fCNb = Keep(new Font("Microsoft YaHei UI", 9, FontStyle.Bold));
            fCNbig = Keep(new Font("Microsoft YaHei UI", 12, FontStyle.Bold)); fTagB = Keep(new Font("Bahnschrift SemiBold SemiConden", 10));
            fNum = Keep(new Font("Bahnschrift SemiBold", 20));
            fNumCN = Keep(new Font("Microsoft YaHei UI", 16, FontStyle.Bold));   // 数值里有中文时用它，Bahnschrift 没有中文字形
            fHead = Keep(new Font("Bahnschrift SemiBold", 18)); fSmall = Keep(new Font("Bahnschrift", 8.5f));
            bBg = Keep(new SolidBrush(cBg)); bPanel = Keep(new SolidBrush(cPanel)); bRowA = Keep(new SolidBrush(cRowA)); bRowB = Keep(new SolidBrush(cRowB));
            bDim = Keep(new SolidBrush(cDim)); bSel = Keep(new SolidBrush(Color.FromArgb(12, 46, 54))); bRow2 = Keep(new SolidBrush(Color.FromArgb(78, 14, 22)));
            bRow1 = Keep(new SolidBrush(Color.FromArgb(48, 40, 8))); bDimLine = Keep(new SolidBrush(cRedDim)); bAcc = Keep(new SolidBrush(cAccent));
            pAcc = Keep(new Pen(cAccent, 1)); pAccDim = Keep(new Pen(cRedDim, 1)); pCyan = Keep(new Pen(cCyan, 2));
            pScan = Keep(new Pen(Color.FromArgb(12, 255, 90, 80), 1)); pGrid = Keep(new Pen(Color.FromArgb(150, 92, 30, 33), 1));
            int[] lv = { 0, 1, 2, -1 };
            foreach (int l in lv)
            {
                Color c = LevelColor(l); int i = Lx(l);
                bLv[i] = Keep(new SolidBrush(c));
                pGlow[i] = Keep(new Pen(Color.FromArgb(60, c), 7)); pGlow[i].LineJoin = LineJoin.Round;
                pCore[i] = Keep(new Pen(c, 2));
                bFill[i] = Keep(new SolidBrush(Color.FromArgb(28, c)));
            }
        }

        static void Txt(Graphics g, string s, Font f, Color c, float x, float y, float w, float h, TextFormatFlags flags = tfL)
        {
            TextRenderer.DrawText(g, s ?? "", f, new Rectangle((int)x, (int)y, (int)w, (int)h), c, flags);
        }
        static int TxtW(Graphics g, string s, Font f) { return TextRenderer.MeasureText(g, s, f, new Size(2000, 100), tfL).Width; }

        // 切角多边形（右上大切角，左下小切角）
        static PointF[] CutPoly(float x, float y, float w, float h, float c)
        {
            return new[] { new PointF(x, y), new PointF(x + w - c, y), new PointF(x + w, y + c), new PointF(x + w, y + h), new PointF(x + c / 2, y + h), new PointF(x, y + h - c / 2) };
        }
        void Scanlines(Graphics g, int w, int h) { for (int y = 2; y < h; y += 3) g.DrawLine(pScan, 0, y, w, y); }
        // 面板外框：底色 + 扫描线 + 切角框 + 标题。active = 荧光蓝边框（表示下方走势图正在显示它）
        void Frame(Graphics g, int w, int h, string tag, string title, bool active)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.FillRectangle(bBg, 0, 0, w, h);
            PointF[] poly = CutPoly(1, 1, w - 2.5f, h - 2.5f, 16);
            g.FillPolygon(bPanel, poly);
            Scanlines(g, w, h);
            g.DrawPolygon(active ? pCyan : pAcc, poly);
            g.FillRectangle(active ? bLv[0] : bAcc, 0, 0, 46, 4);
            if (tag != null)
            {
                Txt(g, "// " + tag, fTagB, cAccent, 12, 8, 160, 22);
                Txt(g, title, fCNb, cGray, 18 + TxtW(g, "// " + tag, fTagB), 8, 160, 22);
            }
        }

        // ---------- 控件 ----------
        BufferedPanel header, cards, diag, detail, actions, chart, status;
        BufferedPanel cardMem, cardCpu, cardDisk, cardDog;
        BufferedPanel[] cardList;
        BufferedListView lv;
        ImageList rowH;
        ContextMenuStrip menu, trayMenu;
        ToolStripMenuItem menuFix, menuWatch, menuWatchA, menuUnwatch, menuSnooze, menuNormal, menuRestore;
        Button btnPrimary, btnKill, btnOpen, btnInstall, btnIgnored;
        NotifyIcon tray;
        Timer timer, showTimer;
        Icon formIcon;

        string selected, chartMode, chartRange, sortMode = "issue";
        bool updating, reallyExit, trayTipShown;
        FormWindowState lastState = FormWindowState.Normal;
        List<object[]> issueRects = new List<object[]>();   // [y0, y1, target, key, title, bx1, bx2]
        List<object[]> rangeRects = new List<object[]>();   // [x0, x1, key]

        // 走势图可选的时间范围（小时）。默认近 30 分钟
        static readonly string[] RangeKeys = { "30m", "1h", "3h", "12h", "24h" };
        static readonly Dictionary<string, double> RangeHours = new Dictionary<string, double> { { "30m", 0.5 }, { "1h", 1 }, { "3h", 3 }, { "12h", 12 }, { "24h", 24 } };
        static readonly Dictionary<string, string> RangeLabel = new Dictionary<string, string> { { "30m", "30 分钟" }, { "1h", "1 小时" }, { "3h", "3 小时" }, { "12h", "12 小时" }, { "24h", "24 小时" } };
        static readonly int[] RightCols = { 2, 3, 4 };
        static readonly Dictionary<string, int> SortCol = new Dictionary<string, int> { { "mem", 2 }, { "cpu", 3 }, { "io", 4 }, { "issue", 5 } };

        void BuildUI()
        {
            Text = "WATCHDOG // 内存 · CPU · 磁盘 监控";
            Size = new Size(1340, 980); MinimumSize = new Size(1150, 920);
            StartPosition = FormStartPosition.CenterScreen;
            Font = fCN; BackColor = cBg; ForeColor = cText;
            try { formIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); Icon = formIcon; } catch { }

            // 顶部标题条
            header = new BufferedPanel(); header.Dock = DockStyle.Top; header.Height = 50;
            header.Paint += PaintHeader;

            // 四张卡片（点击切换下方走势图）
            cards = new BufferedPanel(); cards.Dock = DockStyle.Top; cards.Height = 146; cards.BackColor = cBg;
            cardMem = NewCard("MEMORY", "内存", "MEM-01 // 0x4D45", "mem");
            cardCpu = NewCard("CPU", "处理器", "CPU-02 // 0x4350", "cpu");
            cardDisk = NewCard("DISK", "磁盘读写", "DSK-03 // 0x4453", "disk");
            cardDog = NewCard("WATCHDOG", "看门狗 · 自身占用", "WDG-04 // 0x5744", "dog");
            cardList = new[] { cardMem, cardCpu, cardDisk, cardDog };
            cards.Resize += delegate
            {
                int w = (cards.ClientSize.Width - 60) / 4;
                for (int i = 0; i < 4; i++) cardList[i].SetBounds(12 + i * (w + 12), 6, w, 134);
            };

            // 右侧栏：体检结论 / 选中程序 / 操作
            Panel side = new Panel(); side.Dock = DockStyle.Right; side.Width = 372; side.BackColor = cBg; side.Padding = new Padding(0, 0, 12, 0);
            diag = new BufferedPanel(); diag.Dock = DockStyle.Top; diag.Height = 216; diag.Cursor = Cursors.Hand;
            diag.Paint += PaintDiag; diag.MouseClick += DiagClick;
            detail = new BufferedPanel(); detail.Dock = DockStyle.Top; detail.Height = 276;
            detail.Paint += PaintDetail;
            actions = new BufferedPanel(); actions.Dock = DockStyle.Fill; actions.AutoScroll = true;
            actions.Paint += delegate(object s, PaintEventArgs e) { Frame(e.Graphics, actions.Width, actions.Height, "ACTIONS", "操作", false); };
            side.Controls.Add(actions);
            side.Controls.Add(Spacer(10));
            side.Controls.Add(detail);
            side.Controls.Add(Spacer(10));
            side.Controls.Add(diag);

            // 主区域：走势图 + 程序列表
            Panel main = new Panel(); main.Dock = DockStyle.Fill; main.BackColor = cBg; main.Padding = new Padding(12, 0, 12, 0);
            BuildList();
            chart = new BufferedPanel(); chart.Dock = DockStyle.Top; chart.Height = 210;   // 走势图在列表上方
            chart.Paint += PaintChart; chart.MouseClick += ChartClick;
            main.Controls.Add(lv);
            main.Controls.Add(Spacer(8));
            main.Controls.Add(chart);
            lv.BringToFront();

            // 底部状态栏
            status = new BufferedPanel(); status.Dock = DockStyle.Bottom; status.Height = 28;
            status.Paint += PaintStatus;

            Controls.Add(main);
            Controls.Add(side);
            Controls.Add(Spacer(6));
            Controls.Add(cards);
            Controls.Add(header);
            Controls.Add(status);
            main.BringToFront();

            BuildMenu();
            BuildButtons();

            // 深色标题栏（Windows 11）
            HandleCreated += delegate
            {
                Native.Dwm(Handle, 20, 1);
                Native.Dwm(Handle, 35, 0x000C090E);   // 标题栏底色：红黑
                Native.Dwm(Handle, 36, 0x00575FFF);   // 标题文字：珊瑚红
                Native.Dwm(Handle, 34, 0x00575FFF);   // 窗口边框：珊瑚红
            };
        }

        Panel Spacer(int h) { Panel p = new Panel(); p.Dock = DockStyle.Top; p.Height = h; p.BackColor = cBg; return p; }

        // ---------- 标题条 ----------
        void PaintHeader(object s, PaintEventArgs e)
        {
            Graphics g = e.Graphics; int w = header.Width, h = header.Height;
            g.FillRectangle(bBg, 0, 0, w, h);
            Txt(g, "WATCHDOG", fHead, cCyan, 16, 6, 200, 34);
            Txt(g, "// Which dream is your want", fTagB, cAccent, 152, 6, 260, 34);
            // 自身占用：看门狗（最近一次后台检查）+ 本窗口
            SysRow last = sys.Count > 0 ? sys[sys.Count - 1] : null;
            string dogTxt = last == null ? "看门狗 未运行"
                : last.HasSelf ? string.Format("看门狗 每 10 分钟运行 {0:N1} 秒 · CPU {1:N1} 秒 · 峰值 {2:N0} MB，用完即退出", last.RunMs / 1000, last.SelfCpuSec, last.SelfPeakMB)
                : string.Format("看门狗 每 10 分钟运行 {0:N1} 秒，用完即退出", last.RunMs / 1000);
            string selfTxt = string.Format("本窗口 {0:N0} MB · CPU {1:N1}%", selfMB, selfCpu);
            int rx = w - 262, rw = Math.Max(200, rx - 420);
            Txt(g, dogTxt, fCN, cGray, rx - rw, 6, rw, 18, tfR);
            Txt(g, selfTxt, fCN, cCyan, rx - rw, 24, rw, 18, tfR);
            g.FillRectangle(bDimLine, rx + 4, 12, 1, 26);
            g.FillRectangle(tick % 2 == 0 ? bLv[2] : bPanel, w - 250, 17, 8, 8);
            Txt(g, "LIVE  " + DateTime.Now.ToString("HH:mm"), fTagB, cCyan, w - 234, 6, 90, 28);
            Txt(g, "SYS.MON v7 // 0x5744", fSmall, cRedDim, w - 200, 6, 186, 28, tfR);
            g.FillRectangle(bAcc, 0, h - 3, w, 1);
            g.FillPolygon(bAcc, new[] { new PointF(0, h - 6), new PointF(220, h - 6), new PointF(226, h - 2), new PointF(0, h - 2) });
        }

        // ---------- 卡片 ----------
        BufferedPanel NewCard(string tag, string title, string code, string mode)
        {
            BufferedPanel p = new BufferedPanel(); p.Cursor = Cursors.Hand;
            CardData d = new CardData(); d.Code = code; d.Tag = tag; d.Title = title; d.Mode = mode;
            p.Tag = d;
            p.Paint += PaintCard;
            p.Click += delegate { SetChartMode(d.Mode); };
            cards.Controls.Add(p);
            return p;
        }
        void PaintCard(object s, PaintEventArgs e)
        {
            BufferedPanel p = (BufferedPanel)s; CardData d = (CardData)p.Tag;
            Graphics g = e.Graphics; int w = p.Width, h = p.Height;
            bool active = chartMode == d.Mode;
            Frame(g, w, h, d.Tag, d.Title, active);
            int li = Lx(d.Level);
            Txt(g, active ? "▼ 走势显示中" : d.Code, fSmall, active ? cCyan : cRedDim, w - 160, h - 17, 148, 14, tfR);
            if (!string.IsNullOrEmpty(d.Badge))
            {
                int bx = w - 118, by = 10;
                g.FillPolygon(bLv[li], new[] { new PointF(bx + 8, by), new PointF(bx + 104, by), new PointF(bx + 96, by + 22), new PointF(bx, by + 22) });
                Txt(g, d.Badge, fCNb, cBg, bx, by, 104, 22, tfC);
            }
            Font vf = d.Value.Any(c => c > 0x7F) ? fNumCN : fNum;
            Txt(g, d.Value, vf, cCyan, 10, 34, w - 20, 36);
            if (d.Pct >= 0)
            {
                int n = 24; float gap = 3, bw = (w - 24 - gap * (n - 1)) / n;
                int on = (int)Math.Round(n * Math.Min(100, d.Pct) / 100);
                for (int i = 0; i < n; i++) g.FillRectangle(i < on ? bLv[li] : bDim, 12 + i * (bw + gap), 76, bw, 8);
            }
            Txt(g, d.Sub, fCN, cGray, 12, 90, w - 24, 20);
        }
        void SetCard(BufferedPanel card, string value, string badge, int level, string sub, double pct)
        {
            CardData d = (CardData)card.Tag;
            if (d.Value == value && d.Badge == badge && d.Level == level && d.Sub == sub && (int)d.Pct == (int)pct) return;
            d.Value = value; d.Badge = badge; d.Level = level; d.Sub = sub; d.Pct = pct;
            card.Invalidate();
        }
        void SetChartMode(string mode)
        {
            chartMode = mode;   // 时间范围保持用户上次选的
            foreach (BufferedPanel c in cardList) c.Invalidate();
            chart.Invalidate();
        }

        // ---------- 体检结论 ----------
        void PaintDiag(object s, PaintEventArgs e)
        {
            Graphics g = e.Graphics; int w = diag.Width, h = diag.Height;
            Frame(g, w, h, "DIAGNOSIS", "体检结论", false);
            Txt(g, verdict[0], fCNbig, LevelColor(int.Parse(verdict[1])), 14, 32, w - 28, 24);
            Txt(g, verdict[2], fCN, cGray, 14, 56, w - 28, 18);
            int y = 80; List<object[]> rects = new List<object[]>();
            foreach (Issue it in issues)
            {
                if (y + 36 > h - 6) { Txt(g, "…还有更多，见左侧列表（按\"稳定性\"排在最前）", fCN, cGray, 30, y, w - 44, 18); break; }
                Color c = LevelColor(it.Level);
                Txt(g, "▲", fCN, c, 14, y, 14, 18);
                int tw = w - 44;
                if (it.Key != null)
                {
                    // 右侧两个小按钮：忽略 24 小时 / 确认正常
                    int bx1 = w - 112, bx2 = w - 62;
                    g.DrawRectangle(pAcc, bx1, y + 1, 44, 16); Txt(g, "忽略", fCN, cAccent, bx1, y + 1, 44, 16, tfC);
                    g.DrawRectangle(pAcc, bx2, y + 1, 44, 16); Txt(g, "正常", fCN, cAccent, bx2, y + 1, 44, 16, tfC);
                    tw = w - 150;
                }
                Txt(g, it.Title, fCNb, c, 30, y, tw, 18);
                Txt(g, it.Sub, fCN, cGray, 30, y + 17, w - 44, 17);
                rects.Add(new object[] { y, y + 36, it.Target, it.Key, it.Title, w - 112, w - 62 });
                y += 38;
            }
            issueRects = rects;
        }
        void DiagClick(object s, MouseEventArgs e)
        {
            foreach (object[] r in issueRects)
            {
                int y0 = (int)r[0], y1 = (int)r[1]; string key = (string)r[3], title = (string)r[4];
                if (e.Y < y0 || e.Y >= y1 || key == null || e.Y > y0 + 18) continue;
                if (e.X >= (int)r[5] && e.X < (int)r[5] + 44) { IgnoreIssue(key, title, false); return; }
                if (e.X >= (int)r[6] && e.X < (int)r[6] + 44)
                {
                    if (Ask(string.Format("确认「{0}」是正常的？\n\n以后不再提醒这个问题；如果是规则发现的，看门狗也不会再自动处理它。可以随时在右键菜单或\"已忽略的问题\"里恢复。", title))) IgnoreIssue(key, title, true);
                    return;
                }
            }
            foreach (object[] r in issueRects)
                if (e.Y >= (int)r[0] && e.Y < (int)r[1] && r[2] != null) { SelectTarget((string)r[2]); break; }
        }

        // ---------- 选中的程序 ----------
        void PaintDetail(object s, PaintEventArgs e)
        {
            Graphics g = e.Graphics; int w = detail.Width, h = detail.Height;
            Frame(g, w, h, "TARGET", "选中的程序", false);
            string name = selected;
            ProcRow r = null;
            if (name == null || !rows.TryGetValue(name, out r))
            {
                Txt(g, "在左边列表里点选一个程序（或点上面的问题），这里显示它的稳定性、原因和修复方法。右键程序可以让看门狗专门监控它。", fCN, cGray, 14, 40, w - 28, 60, tfW);
                return;
            }
            Bitmap icon = GetIcon(name);
            if (icon != null) { g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.DrawImage(icon, 14, 38, 32, 32); }
            else { g.FillRectangle(bDim, 14, 38, 32, 32); g.DrawRectangle(pAcc, 14, 38, 32, 32); }
            Txt(g, name, fCNbig, cCyan, 56, 36, w - 70, 22);
            string sub; if (!Desc.TryGetValue(name, out sub)) sub = "-";
            Rule wr;
            if (watched.TryGetValue(name, out wr)) sub += string.Format("  ·  ◉ 看门狗监控中（超过 {0} MB {1}）", wr.MinMB, wr.Auto ? "自动重启" : "提醒");
            Txt(g, sub, fCN, cGray, 56, 58, w - 70, 18);
            string[,] cols = { { "内存", string.Format("{0:N0} MB", r.PrivMB) }, { "CPU", string.Format("{0:N1} %", r.CpuPct) }, { "读写", string.Format("{0:N1} MB/s", r.IoMBs) }, { "进程", r.Count.ToString() } };
            float cw = (w - 28) / 4f;
            for (int i = 0; i < 4; i++)
            {
                Txt(g, cols[i, 0], fCN, cGray, 14 + i * cw, 80, cw, 16);
                Txt(g, cols[i, 1], fTagB, cText, 14 + i * cw, 96, cw, 20);
            }
            Rating rt = GetRating(name, r.PrivMB);
            Txt(g, "稳定性：" + rt.Text, fCNb, LevelColor(rt.Level), 14, 122, 130, 18);
            Txt(g, rt.Text == "已知问题" ? rt.Trend : rt.Note, fCN, cGray, 140, 122, w - 154, 18);
            Hit hit;
            if (hitByTarget.TryGetValue(name, out hit))
            {
                Txt(g, "已知问题：" + hit.Rule.Title, fCNb, LevelColor(rt.Level), 14, 144, w - 28, 18);
                Txt(g, hit.Why + "。" + hit.Rule.Cause, fCN, cGray, 14, 164, w - 28, 30, tfW);
            }
            else if (rt.Forecast.Length > 0) Txt(g, rt.Forecast, fCNb, LevelColor(rt.Level), 14, 144, w - 28, 18);
        }

        // ---------- 程序列表 ----------
        void BuildList()
        {
            lv = new BufferedListView();
            lv.Dock = DockStyle.Fill; lv.View = View.Details; lv.FullRowSelect = true; lv.HideSelection = false; lv.MultiSelect = false;
            lv.OwnerDraw = true; lv.BackColor = cRowA; lv.ForeColor = cText; lv.BorderStyle = BorderStyle.None;
            rowH = new ImageList(); rowH.ImageSize = new Size(1, 28); lv.SmallImageList = rowH;
            object[,] cols = { { "程序", 175 }, { "说明", 140 }, { "内存 MB", 80 }, { "CPU %", 58 }, { "读写 MB/s", 78 }, { "稳定性", 78 }, { "变化", 135 }, { "判断 / 预测", 180 } };
            for (int i = 0; i < cols.GetLength(0); i++) lv.Columns.Add((string)cols[i, 0], (int)cols[i, 1]);
            lv.DrawColumnHeader += delegate(object s, DrawListViewColumnHeaderEventArgs e)
            {
                Graphics g = e.Graphics; Rectangle r = e.Bounds;
                g.FillRectangle(bBg, r);
                g.FillRectangle(bAcc, r.X, r.Bottom - 2, r.Width, 2);
                bool sorted = SortCol[sortMode] == e.ColumnIndex;
                Txt(g, sorted ? e.Header.Text + " ▼" : e.Header.Text, fCNb, sorted ? cCyan : cAccent, r.X + 8, r.Y, r.Width - 16, r.Height, RightCols.Contains(e.ColumnIndex) ? tfR : tfL);
            };
            lv.ColumnClick += delegate(object s, ColumnClickEventArgs e)
            {
                sortMode = e.Column == 2 ? "mem" : e.Column == 3 ? "cpu" : e.Column == 4 ? "io" : "issue";
                lv.Invalidate(); RefreshAll();
            };
            lv.DrawItem += delegate { };
            lv.DrawSubItem += DrawSubItem;
            lv.Resize += delegate { FitColumns(); };
            lv.SelectedIndexChanged += delegate
            {
                if (updating) return;
                if (lv.SelectedItems.Count > 0) { selected = lv.SelectedItems[0].Text; UpdateDetailButtons(); SetChartMode("proc"); detail.Invalidate(); }
            };
            lv.HandleCreated += delegate
            {
                Native.SetWindowTheme(lv.Handle, "DarkMode_Explorer", null);
                IntPtr hdr = Native.SendMessage(lv.Handle, 0x101F, IntPtr.Zero, IntPtr.Zero);   // LVM_GETHEADER
                if (hdr != IntPtr.Zero) Native.SetWindowTheme(hdr, "DarkMode_ItemsView", null);
            };
        }
        void DrawSubItem(object s, DrawListViewSubItemEventArgs e)
        {
            Graphics g = e.Graphics; Rectangle r = e.Bounds; ListViewItem it = e.Item;
            int lvl = it.Tag is int ? (int)it.Tag : -1;
            Brush bg = it.Selected ? bSel : lvl == 2 ? bRow2 : lvl == 1 ? bRow1 : it.Index % 2 == 1 ? bRowB : bRowA;
            g.FillRectangle(bg, r);
            int col = e.ColumnIndex;
            if (col == 0)
            {
                Bitmap icon = GetIcon(it.Text);
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                if (icon != null) g.DrawImage(icon, r.X + 8, r.Y + 5, 18, 18); else g.FillRectangle(bDim, r.X + 11, r.Y + 8, 12, 12);
                if (it.Selected) g.FillRectangle(bLv[0], r.X, r.Y + 3, 3, r.Height - 6);
                int tw = r.Width - 40;
                if (watched.ContainsKey(it.Text)) { Txt(g, "◉", fCN, cCyan, r.Right - 20, r.Y, 16, r.Height); tw -= 18; }
                Txt(g, it.Text, fCNb, cText, r.X + 34, r.Y, tw, r.Height);
                return;
            }
            double io; double.TryParse(it.SubItems[4].Text, out io);
            Color c = col == 1 || col == 6 ? cGray : col == 4 ? (io >= HeavyIoMBs ? cYellow : cText) : col == 5 ? LevelColor(lvl) : col == 7 ? (lvl >= 1 ? LevelColor(lvl) : cGray) : cText;
            Txt(g, e.SubItem.Text, col == 5 ? fCNb : fCN, c, r.X + 8, r.Y, r.Width - 16, r.Height, RightCols.Contains(col) ? tfR : tfL);
        }
        void FitColumns()
        {
            int n = lv.Columns.Count, sum = 0;
            for (int i = 0; i < n - 1; i++) sum += lv.Columns[i].Width;
            int want = Math.Max(100, lv.ClientSize.Width - sum - 2);
            if (lv.Columns[n - 1].Width != want) lv.Columns[n - 1].Width = want;
        }

        // ---------- 走势图：内存 / CPU / 磁盘 / 看门狗 / 选中的程序 ----------
        Line RingLine(string key, int level, string label)
        {
            Ring r;
            if (!series.TryGetValue(key, out r) || r.Count < 2) return null;
            Line ln = new Line(); int n = r.Count; ln.T = new long[n]; ln.V = new double[n]; ln.Level = level; ln.Name = label;
            for (int i = 0; i < n; i++) { ln.T[i] = r.TimeAt(i); ln.V[i] = r.ValueAt(i); }
            return ln;
        }
        Line HistLine<TItem>(IList<TItem> items, Func<TItem, DateTime> time, Func<TItem, double> val, int level, string label)
        {
            if (items == null || items.Count < 2) return null;
            Line ln = new Line(); int n = items.Count; ln.T = new long[n]; ln.V = new double[n]; ln.Level = level; ln.Name = label;
            for (int i = 0; i < n; i++) { ln.T[i] = time(items[i]).ToUniversalTime().Ticks; ln.V[i] = val(items[i]); }
            return ln;
        }
        ChartData GetChartData(string range)
        {
            bool lng = RangeHours[range] > 1;   // 1 小时以内用窗口的实时数据（5 秒一个点），更长用看门狗的记录（10 分钟一个点）
            ChartData d = new ChartData();
            const string live = "窗口打开期间每 5 秒一个点", rec = "看门狗每 10 分钟记录一次", inst = "看门狗检查时的瞬间值";
            switch (chartMode)
            {
                case "mem":
                    d.Title = "整机内存占用"; d.Unit = "GB"; d.Note = lng ? rec : live;
                    d.Lines.Add(lng ? HistLine(sys, x => x.T, x => x.UsedMB / 1024, 0, "已用") : RingLine("sys:mem", 0, "已用"));
                    break;
                case "cpu":
                    d.Title = "CPU 占用"; d.Unit = "%"; d.FixedMax = 100; d.Note = lng ? inst : live;
                    d.Lines.Add(lng ? HistLine(sys, x => x.T, x => x.CpuPct, 0, "CPU") : RingLine("sys:cpu", 0, "CPU"));
                    break;
                case "disk":
                    d.Title = "磁盘读写"; d.Unit = "MB/s"; d.Note = lng ? inst : live;
                    if (lng)
                    {
                        List<SysRow> v2 = sys.Where(x => x.HasDisk).ToList();
                        d.Lines.Add(HistLine(v2, x => x.T, x => x.DiskR, 0, "读")); d.Lines.Add(HistLine(v2, x => x.T, x => x.DiskW, 1, "写"));
                    }
                    else { d.Lines.Add(RingLine("sys:dr", 0, "读")); d.Lines.Add(RingLine("sys:dw", 1, "写")); }
                    break;
                case "dog":
                    d.Note = "看门狗做什么：每 10 分钟在后台运行约 5 秒 → ① 按规则检查，超过上限的自动修复  ② 记录各程序内存，用来判断稳定性 → 然后退出，不常驻内存";
                    if (lng) { d.Title = "看门狗每次检查耗时"; d.Unit = "秒"; d.Lines.Add(HistLine(sys, x => x.T, x => x.RunMs / 1000, 0, "耗时")); }
                    else { d.Title = "本监控窗口自身内存"; d.Unit = "MB"; d.Lines.Add(RingLine("sys:self", 0, "本窗口")); }
                    break;
                default:
                    if (selected == null) { d.Note = "点选列表里的程序看它的内存走势；点上面的卡片看整机内存 / CPU / 磁盘 / 看门狗"; break; }
                    string desc; if (!Desc.TryGetValue(selected, out desc)) desc = "-";
                    d.Title = selected + "  ·  " + desc; d.Unit = "MB"; d.Note = lng ? rec : live;
                    List<HistPt> hl; hist.TryGetValue(selected, out hl);
                    d.Lines.Add(lng ? HistLine(hl, x => x.T, x => x.MB, 0, "内存") : RingLine(selected, 0, "内存"));
                    break;
            }
            d.Lines.RemoveAll(l => l == null);
            return d;
        }
        void PaintChart(object s, PaintEventArgs e)
        {
            Graphics g = e.Graphics; int w = chart.Width, h = chart.Height;
            g.FillRectangle(bBg, 0, 0, w, h);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            PointF[] poly = CutPoly(0.5f, 0.5f, w - 1.5f, h - 2, 16);
            g.FillPolygon(bPanel, poly);
            Scanlines(g, w, h);
            g.DrawPolygon(pAcc, poly);
            g.FillRectangle(bAcc, 0, 0, 46, 4);
            string range = RangeHours.ContainsKey(chartRange) ? chartRange : "30m";
            ChartData data = GetChartData(range);
            Txt(g, "// TREND", fTagB, cAccent, 12, 8, 70, 20);
            // 右上角范围切换：近 30 分钟 / 1 / 3 / 12 / 24 小时
            int rw = 64, gap = 4;
            int x = w - 24 - RangeKeys.Length * (rw + gap) + gap;
            Txt(g, "近", fCN, cGray, x - 26, 7, 22, 20, tfR);
            Txt(g, data.Title, fCNb, cText, 84, 8, x - 84 - 34, 20);
            List<object[]> rects = new List<object[]>();
            foreach (string key in RangeKeys)
            {
                if (range == key) { g.FillRectangle(bLv[0], x, 7, rw, 20); Txt(g, RangeLabel[key], fCNb, cBg, x, 7, rw, 20, tfC); }
                else { g.DrawRectangle(pAcc, x, 7, rw, 20); Txt(g, RangeLabel[key], fCN, cAccent, x, 7, rw, 20, tfC); }
                rects.Add(new object[] { x, x + rw, key }); x += rw + gap;
            }
            rangeRects = rects;
            long end = DateTime.UtcNow.Ticks, spanT = TimeSpan.FromHours(RangeHours[range]).Ticks, begin = end - spanT;
            // 只留在这段时间里至少有 2 个点的线
            List<Line> lines = data.Lines.Where(l => l.T.Count(t => t >= begin) >= 2).ToList();
            const int L = 70, R = 24, T = 36, B = 42;
            int pw = w - L - R, ph = h - T - B;
            Txt(g, data.Note, fCN, cGray, 14, h - 22, w - 28, 16);
            if (lines.Count == 0)
            {
                string msg = chartMode == "proc" && selected == null ? data.Note
                    : RangeHours[range] <= 1 ? "实时数据还不够：窗口每 5 秒记录一个点，稍等片刻；或者选\"3 小时\"以上，看看门狗的记录。"
                    : "这段时间还没有看门狗的记录（每 10 分钟记录一次）。可以先看\"30 分钟 / 1 小时\"的实时数据，或者选更长的时间。";
                Txt(g, msg, fCN, cGray, 14, 44, w - 28, 40, tfW);
                return;
            }
            double max = 0, min = double.MaxValue;
            foreach (Line ln in lines) for (int i = 0; i < ln.V.Length; i++) { if (ln.T[i] < begin) continue; max = Math.Max(max, ln.V[i]); min = Math.Min(min, ln.V[i]); }
            if (min == double.MaxValue) min = 0;
            double lo, hi;
            if (data.FixedMax > 0) { lo = 0; hi = data.FixedMax; }
            else { double pad = Math.Max((max - min) * 0.15, Math.Max(max * 0.02, 0.5)); lo = Math.Max(0, min - pad); hi = max + pad; }
            string fmt = hi - lo < 10 ? "{0:N1}" : "{0:N0}";   // 范围小时多显示一位小数，免得刻度重复
            for (int i = 0; i <= 3; i++)
            {
                float y = T + ph * i / 3f;
                g.DrawLine(pGrid, L, y, L + pw, y);
                Txt(g, string.Format(fmt, hi - (hi - lo) * i / 3) + " " + data.Unit, fSmall, cGray, 4, y - 9, L - 10, 18, tfR);
            }
            int ticks = range == "3h" || range == "12h" ? 6 : 4;
            for (int k = 0; k <= ticks; k++)
            {
                float tx = L + pw * k / (float)ticks;
                g.DrawLine(pGrid, tx, T, tx, T + ph);
                DateTime lt = new DateTime(begin + spanT * k / ticks, DateTimeKind.Utc).ToLocalTime();
                Txt(g, lt.ToString("HH:mm"), fSmall, cGray, tx - 20, T + ph + 4, 40, 16, tfC);
            }
            g.SetClip(new RectangleF(L, T, pw, ph));
            foreach (Line ln in lines)
            {
                int li = Lx(ln.Level);
                List<PointF> pts = new List<PointF>();
                for (int i = 0; i < ln.V.Length; i++)
                {
                    if (ln.T[i] < begin) continue;
                    pts.Add(new PointF((float)(L + pw * (double)(ln.T[i] - begin) / spanT), (float)(T + ph * (1 - (ln.V[i] - lo) / (hi - lo)))));
                }
                if (pts.Count < 2) continue;
                PointF[] arr = pts.ToArray();
                if (lines.Count == 1)
                {
                    List<PointF> area = new List<PointF>();
                    area.Add(new PointF(arr[0].X, T + ph)); area.AddRange(arr); area.Add(new PointF(arr[arr.Length - 1].X, T + ph));
                    g.FillPolygon(bFill[li], area.ToArray());
                }
                g.DrawLines(pGlow[li], arr);
                g.DrawLines(pCore[li], arr);
                ln.LastPt = arr[arr.Length - 1];
            }
            g.ResetClip();
            // 末端数值 + 多条线时的图例
            int ly = 50;
            foreach (Line ln in lines)
            {
                if (ln.LastPt == null) continue;
                int li = Lx(ln.Level); PointF lp = ln.LastPt.Value;
                g.FillRectangle(bLv[li], lp.X - 4, lp.Y - 4, 8, 8);
                string txt = string.Format(fmt, ln.V[ln.V.Length - 1]) + " " + data.Unit;
                if (lines.Count > 1) { Txt(g, ln.Name + " " + txt, fTagB, LevelColor(ln.Level), L + 8, ly, 160, 18); ly += 18; }
                else Txt(g, txt, fTagB, LevelColor(ln.Level), lp.X - 130, lp.Y - 26, 124, 20, tfR);
            }
        }
        void ChartClick(object s, MouseEventArgs e)
        {
            if (e.Y < 4 || e.Y > 30) return;
            foreach (object[] r in rangeRects)
                if (e.X >= (int)r[0] && e.X < (int)r[1]) { chartRange = (string)r[2]; chart.Invalidate(); break; }
        }

        // ---------- 状态栏 ----------
        void PaintStatus(object s, PaintEventArgs e)
        {
            Graphics g = e.Graphics; int w = status.Width, h = status.Height;
            g.FillRectangle(bBg, 0, 0, w, h);
            g.DrawLine(pAccDim, 0, 0, w, 0);
            g.FillRectangle(bAcc, 12, 10, 8, 8);
            string txt = string.Format("每 5 秒刷新 · 点关闭缩到托盘、后台继续记录 · 本窗口：内存 {0:N0} MB / CPU {1:N2}% / GDI {2} · 实时数据 {3} 条 · 点卡片切换走势图 · 点列标题切换排序 · 右键程序可让看门狗监控它",
                selfMB, selfCpu, selfGdi, series.Count);
            Txt(g, txt, fCN, cGray, 28, 0, w - 40, h);
        }

        // ---------- 按钮 ----------
        Button NewBtn(Control parent, string text, int x, int y, int w, EventHandler onClick, bool primary)
        {
            Button b = new Button();
            b.Text = text; b.SetBounds(x, y, w, 32);
            b.FlatStyle = FlatStyle.Flat; b.Font = fCNb; b.Cursor = Cursors.Hand;
            b.BackColor = primary ? Color.FromArgb(70, 18, 24) : cPanel;
            b.ForeColor = primary ? cText : cAccent;
            b.FlatAppearance.BorderColor = cAccent; b.FlatAppearance.BorderSize = 1;
            b.FlatAppearance.MouseOverBackColor = Color.FromArgb(12, 46, 54);
            b.FlatAppearance.MouseDownBackColor = Color.FromArgb(20, 70, 82);
            b.Click += onClick;
            parent.Controls.Add(b);
            return b;
        }
        void BuildButtons()
        {
            // 选中程序的按钮：主按钮的文字随规则变化（命中规则时显示对应的修复方法）
            btnPrimary = NewBtn(detail, "重启这个程序", 14, 196, 334, delegate { FixSelected(); }, true);
            btnKill = NewBtn(detail, "结束", 14, 234, 163, delegate { KillTarget(selected); }, false);
            btnOpen = NewBtn(detail, "打开位置", 185, 234, 163, delegate { OpenLocation(selected); }, false);
            // 操作区按钮（两列）
            int ax = 14, half = 163, full = 334, ay = 36, step = 38;
            NewBtn(actions, "一键修复全部问题", ax, ay, full, delegate { FixAll(); }, true); ay += step;
            NewBtn(actions, "立即检查一次", ax, ay, half, delegate { RunCheckNow(); }, false);
            NewBtn(actions, "修复 NVIDIA 数据库", ax + half + 8, ay, half, delegate
            {
                if (Ask("将停止并重建 NVIDIA 的 nvtopps 数据库，屏幕可能闪一下。需要管理员权限。确定吗？")) { RunTool("Fix-NvTopps.ps1", ""); ReloadSoon(8); }
            }, false); ay += step;
            NewBtn(actions, "编辑我的规则", ax, ay, half, delegate { EditRules(); }, false);
            btnIgnored = NewBtn(actions, "已忽略的问题", ax + half + 8, ay, half, delegate { ShowIgnored(); }, false); ay += step;
            btnInstall = NewBtn(actions, "安装看门狗", ax, ay, half, delegate
            {
                if (taskInstalled) { if (Ask("将删除看门狗计划任务，之后不再自动检查。确定吗？")) RunTool("Install-Watchdog.ps1", "-Uninstall"); }
                else RunTool("Install-Watchdog.ps1", "");
                ReloadSoon(15);
            }, false);
            NewBtn(actions, "打开工具文件夹", ax + half + 8, ay, half, delegate { StartShell("explorer.exe", "\"" + ToolDir + "\""); }, false);
        }
        static void SetText(Control c, string text) { if (c.Text != text) c.Text = text; }   // 文字真的变了才改，避免无谓重绘
        void UpdateDetailButtons()
        {
            Hit hit = null; if (selected != null) hitByTarget.TryGetValue(selected, out hit);
            string t = hit != null ? (hit.Rule.FixType == "none" ? "查看建议：" : "修复：") + hit.Rule.FixLabel
                : selected != null && selected.StartsWith("svc:") ? "重启这个服务" : "重启这个程序";
            SetText(btnPrimary, t);
        }

        // ---------- 右键菜单 ----------
        void BuildMenu()
        {
            menu = new ContextMenuStrip();
            menu.Renderer = new ToolStripProfessionalRenderer(new CyberColors());
            menu.Font = fCN; menu.ForeColor = cText;
            menuFix = MenuItem(menu, "修复 / 重启", delegate { FixSelected(); });
            MenuItem(menu, "结束这个程序", delegate { KillTarget(selected); });
            MenuItem(menu, "打开文件位置", delegate { OpenLocation(selected); });
            menu.Items.Add(new ToolStripSeparator());
            menuWatch = MenuItem(menu, "◉ 用看门狗监控（超过上限时提醒）", delegate { AddWatch(selected, false); });
            menuWatchA = MenuItem(menu, "◉ 用看门狗监控（超过上限时自动重启）", delegate { AddWatch(selected, true); });
            menuUnwatch = MenuItem(menu, "取消看门狗监控", delegate { RemoveWatch(selected); });
            menu.Items.Add(new ToolStripSeparator());
            menuSnooze = MenuItem(menu, "忽略这个问题（24 小时内不提醒）", delegate { string[] i = IssueOf(selected); if (i != null) IgnoreIssue(i[0], i[1], false); });
            menuNormal = MenuItem(menu, "确认正常，不再提醒", delegate
            {
                string[] i = IssueOf(selected);
                if (i != null && Ask(string.Format("确认「{0}」是正常的？以后不再提醒；如果是规则发现的，看门狗也不会再自动处理它。", i[1]))) IgnoreIssue(i[0], i[1], true);
            });
            menuRestore = MenuItem(menu, "恢复提醒", delegate { UnignoreName(selected); });
            menu.Opening += delegate(object s, System.ComponentModel.CancelEventArgs e)
            {
                string n = selected;
                if (n == null) { e.Cancel = true; return; }
                menuFix.Text = btnPrimary.Text;
                bool hasIssue = IssueOf(n) != null;
                menuSnooze.Visible = hasIssue; menuNormal.Visible = hasIssue;
                menuRestore.Visible = HasIgnore(n);
                bool isW = watched.ContainsKey(n);
                menuUnwatch.Visible = isW;
                menuWatch.Text = isW ? "◉ 修改监控（超过上限时提醒）" : "◉ 用看门狗监控（超过上限时提醒）";
                menuWatchA.Text = isW ? "◉ 修改监控（超过上限时自动重启）" : "◉ 用看门狗监控（超过上限时自动重启）";
                menuWatchA.Visible = !Protected.Contains(n);
            };
            lv.ContextMenuStrip = menu;
        }
        ToolStripMenuItem MenuItem(ContextMenuStrip m, string text, EventHandler onClick)
        {
            ToolStripMenuItem i = new ToolStripMenuItem(text); i.ForeColor = cText; i.Click += onClick; m.Items.Add(i); return i;
        }

        // ---------- 托盘：点关闭 / 最小化都缩到托盘，在后台继续记录 ----------
        void BuildTray()
        {
            tray = new NotifyIcon(); tray.Icon = formIcon ?? SystemIcons.Application; tray.Text = "WatchDog"; tray.Visible = false;
            trayMenu = new ContextMenuStrip(); trayMenu.Renderer = menu.Renderer; trayMenu.Font = fCN;
            ToolStripMenuItem open = MenuItem(trayMenu, "打开 WatchDog", delegate { ShowFromTray(); }); open.Font = fCNb;
            MenuItem(trayMenu, "退出", delegate { reallyExit = true; Close(); });
            tray.ContextMenuStrip = trayMenu;
            tray.MouseClick += delegate(object s, MouseEventArgs e) { if (e.Button == MouseButtons.Left) ShowFromTray(); };
            Resize += delegate
            {
                if (WindowState == FormWindowState.Minimized) { if (Visible) HideToTray(); }
                else lastState = WindowState;
            };
            // 点右上角关闭 = 缩到托盘；只有托盘菜单的"退出"、关机 / 注销才真正退出
            FormClosing += delegate(object s, FormClosingEventArgs e)
            {
                if (!reallyExit && (e.CloseReason == CloseReason.UserClosing || e.CloseReason == CloseReason.None)) { e.Cancel = true; HideToTray(); }
            };
        }
        void HideToTray()
        {
            Hide(); tray.Visible = true;
            if (!trayTipShown) { trayTipShown = true; tray.ShowBalloonTip(3000, "WatchDog 在托盘里继续记录", "点托盘图标重新打开。要退出：右键托盘图标 → 退出。", ToolTipIcon.Info); }
        }
        void ShowFromTray()
        {
            Show(); WindowState = lastState; Activate();
            if (tray != null) tray.Visible = false;
            RefreshAll();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (timer != null) timer.Dispose();
                if (showTimer != null) showTimer.Dispose();
                if (tray != null) { tray.Visible = false; tray.Dispose(); }   // 不留下"幽灵"托盘图标
                if (trayMenu != null) trayMenu.Dispose();
                if (menu != null) menu.Dispose();
                if (rowH != null) rowH.Dispose();
                foreach (Bitmap b in icons.Values) if (b != null) b.Dispose();
                icons.Clear();
                if (formIcon != null) formIcon.Dispose();
            }
            base.Dispose(disposing);
            if (disposing) { foreach (IDisposable o in gdi) o.Dispose(); gdi.Clear(); }   // 控件都释放后再释放字体和画刷
        }
    }
}
