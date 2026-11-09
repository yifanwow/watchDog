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
    class CardData
    {
        public string Code, Tag, Title, Mode, Value = "--", Badge = "...", Sub = "", Extra = "";
        public int Level = -1; public double Pct = -1;
        public List<KeyValuePair<string, double>> Top = new List<KeyValuePair<string, double>>();   // 内存卡片右侧：占用最多的程序
    }
    class Line { public long[] T; public double[] V; public int Level; public string Name; public PointF? LastPt; public bool Right; }   // Right = 用右侧 0–100% 刻度
    class ChartData { public string Title = "", Unit = "", Note = "", Msg; public double FixedMax; public bool Zero; public List<Line> Lines = new List<Line>(); }

    partial class Monitor : Form
    {
        // ---------- 主题 ----------
        static readonly Color cBg = Color.FromArgb(14, 9, 12), cPanel = Color.FromArgb(32, 13, 17), cRowA = Color.FromArgb(19, 10, 13),
            cRowB = Color.FromArgb(26, 12, 16), cCyan = Color.FromArgb(94, 246, 255), cYellow = Color.FromArgb(245, 217, 10),
            cRed = Color.FromArgb(255, 40, 60), cAccent = Color.FromArgb(255, 95, 87), cRedDim = Color.FromArgb(92, 30, 33),
            cText = Color.FromArgb(236, 220, 214), cGray = Color.FromArgb(160, 116, 112), cDim = Color.FromArgb(58, 24, 28);
        static Color LevelColor(int l) { return l == 0 ? cCyan : l == 1 ? cYellow : l == 2 ? cRed : cGray; }
        static int Lx(int l) { return l == -1 ? 3 : Math.Max(0, Math.Min(2, l)); }   // 等级 -> 数组下标

        Font fCN, fCNb, fCNbig, fTagB, fNum, fNumBig, fNumS, fHead, fSmall, fMono;
        SolidBrush bBg, bPanel, bRowA, bRowB, bDim, bSel, bRow2, bRow1, bDimLine, bAcc, bDeep, bCyanDim, bRed;
        Brush bHaz;
        Pen pAcc, pAccDim, pCyan, pScan, pGrid, pCyanThin, pCyanDash, pPulse, pPulseGlow;
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
            fNum = Keep(new Font("Bahnschrift SemiBold", 20)); fNumBig = Keep(new Font("Bahnschrift SemiBold", 26)); fNumS = Keep(new Font("Bahnschrift SemiBold", 17));
            fHead = Keep(new Font("Bahnschrift SemiBold", 18)); fSmall = Keep(new Font("Bahnschrift", 8.5f)); fMono = Keep(new Font("Consolas", 8.5f));
            bDeep = Keep(new SolidBrush(Color.FromArgb(9, 6, 8))); bCyanDim = Keep(new SolidBrush(Color.FromArgb(38, 94, 246, 255))); bRed = Keep(new SolidBrush(cRed));
            bHaz = Keep(new HatchBrush(HatchStyle.WideUpwardDiagonal, cYellow, cBg));   // 黄黑警示条
            pCyanThin = Keep(new Pen(cCyan, 1)); pCyanDash = Keep(new Pen(Color.FromArgb(110, 94, 246, 255), 1)); pCyanDash.DashStyle = DashStyle.Dash;
            pPulse = Keep(new Pen(cCyan, 1.5f)); pPulseGlow = Keep(new Pen(Color.FromArgb(60, 94, 246, 255), 5)); pPulseGlow.LineJoin = LineJoin.Round;
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
            Deco(g, w, h);
            if (tag != null)
            {
                Txt(g, "// " + tag, fTagB, cAccent, 12, 8, 160, 22);
                Txt(g, title, fCNb, cGray, 18 + TxtW(g, "// " + tag, fTagB), 8, 160, 22);
            }
        }

        // 赛博朋克小装饰：左侧导轨、右下角荧光蓝角标、底边刻度
        void Deco(Graphics g, int w, int h)
        {
            g.FillRectangle(bAcc, 3, 34, 2, 22);
            g.FillRectangle(bDimLine, 3, 60, 2, 6); g.FillRectangle(bDimLine, 3, 70, 2, 3);
            g.DrawLine(pCyanThin, w - 7, h - 18, w - 7, h - 7); g.DrawLine(pCyanThin, w - 7, h - 7, w - 18, h - 7);
            for (int i = 0; i < 4; i++) g.FillRectangle(bDimLine, 18 + i * 7, h - 6, 4, 2);
        }
        // 平行四边形标签（徽章）
        void Badge(Graphics g, string text, int li, int x, int y, int w, int h)
        {
            g.FillPolygon(bLv[li], new[] { new PointF(x + 8, y), new PointF(x + w, y), new PointF(x + w - 8, y + h), new PointF(x, y + h) });
            Txt(g, text, fCNb, cBg, x, y, w, h, tfC);
        }

        // ---------- 控件 ----------
        BufferedPanel header, cards, diag, detail, actions, chart, status;
        Panel side;
        BufferedPanel cardMem, cardCpu, cardDisk, cardKernel;
        BufferedPanel[] cardList;
        CardData dog = new CardData { Tag = "WATCHDOG", Title = "看门狗", Mode = "dog" };   // 画在体检结论的上半部分
        const int DogY = 34, DogH = 88;
        BufferedListView lv;
        ImageList rowH;
        ContextMenuStrip menu, trayMenu;
        ToolStripMenuItem menuFix, menuWatch, menuWatchA, menuUnwatch, menuSnooze, menuNormal, menuRestore, menuNote;
        Button btnPrimary, btnKill, btnOpen, btnInstall, btnIgnored;
        NotifyIcon tray;
        Timer timer, showTimer;
        Icon formIcon;

        string selected, chartMode, chartRange, sortMode = "issue";
        bool updating, reallyExit, trayTipShown;
        FormWindowState lastState = FormWindowState.Normal;
        List<object[]> issueRects = new List<object[]>();   // [y0, y1, target, key, title, bx1, bx2]
        List<object[]> rangeRects = new List<object[]>();   // [x0, x1, key]
        List<object[]> metricRects = new List<object[]>();  // [x0, x1, mem|cpu|io]
        string procMetric = "mem";
        bool memPct;                                         // 整机内存走势上是否显示黄色百分比线                           // 选中程序时走势图看哪一项
        static readonly string[][] ProcMetrics = { new[] { "mem", "内存" }, new[] { "cpu", "CPU" }, new[] { "io", "读写" }, new[] { "hnd", "句柄" }, new[] { "gui", "GDI" } };
        string kernelMetric = "pool";                        // 内核走势图看内存池还是句柄总数
        static readonly string[][] KernelMetrics = { new[] { "pool", "内存池" }, new[] { "total", "句柄" } };

        // 走势图可选的时间范围（小时）。默认近 30 分钟
        static readonly string[] RangeKeys = { "30m", "1h", "3h", "12h", "24h" };
        static readonly Dictionary<string, double> RangeHours = new Dictionary<string, double> { { "30m", 0.5 }, { "1h", 1 }, { "3h", 3 }, { "12h", 12 }, { "24h", 24 } };
        static readonly Dictionary<string, string> RangeLabel = new Dictionary<string, string> { { "30m", "30 分钟" }, { "1h", "1 小时" }, { "3h", "3 小时" }, { "12h", "12 小时" }, { "24h", "24 小时" } };
        const int ColCount = 10;
        static readonly int[] RightCols = { 2, 3, 4, 5, 6 };
        static readonly Dictionary<string, int> SortCol = new Dictionary<string, int> { { "mem", 2 }, { "cpu", 3 }, { "io", 4 }, { "hnd", 5 }, { "gui", 6 }, { "issue", 7 } };

        void BuildUI()
        {
            Text = "WATCHDOG // 内存 · CPU · 磁盘 监控";
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;   // 屏幕够高就开高一点，右侧栏更宽松
            Size = new Size(Math.Min(1480, wa.Width), Math.Max(920, Math.Min(1060, wa.Height))); MinimumSize = new Size(1150, 920);
            StartPosition = FormStartPosition.CenterScreen;
            Font = fCN; BackColor = cBg; ForeColor = cText;
            try { formIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); Icon = formIcon; } catch { }

            // 顶部标题条
            header = new BufferedPanel(); header.Dock = DockStyle.Top; header.Height = 50;
            header.Paint += PaintHeader;
            header.MouseMove += delegate(object s, MouseEventArgs e)
            {
                string hit = LinkAt(e.Location);
                if (hit != hoverLink) { hoverLink = hit; header.Cursor = hit != null ? Cursors.Hand : Cursors.Default; header.Invalidate(); }
            };
            header.MouseLeave += delegate { if (hoverLink != null) { hoverLink = null; header.Cursor = Cursors.Default; header.Invalidate(); } };
            header.MouseClick += delegate(object s, MouseEventArgs e) { string url = LinkAt(e.Location); if (url != null) StartShell(url, ""); };

            // 四张卡片（点击切换下方走势图）：内存最宽，CPU、磁盘、内核平分剩下的
            cards = new BufferedPanel(); cards.Dock = DockStyle.Top; cards.Height = 136; cards.BackColor = cBg;
            cardMem = NewCard("MEMORY", "内存", "MEM-01 // 0x4D45", "mem");
            cardCpu = NewCard("CPU", "处理器", "CPU-02 // 0x4350", "cpu");
            cardDisk = NewCard("DISK", "磁盘", "DSK-03 // 0x4453", "disk");
            cardKernel = NewCard("KERNEL", "内核", "KRN-06 // 0x4B52", "kernel");
            cardList = new[] { cardMem, cardCpu, cardDisk, cardKernel };
            cards.Resize += delegate
            {
                int all = cards.ClientSize.Width - 36, wm = (int)(all * 0.4), ws = (all - wm) / 3;
                cardMem.SetBounds(0, 0, wm, 136);
                cardCpu.SetBounds(wm + 12, 0, ws, 136);
                cardDisk.SetBounds(wm + 24 + ws, 0, ws, 136);
                cardKernel.SetBounds(wm + 36 + 2 * ws, 0, cards.ClientSize.Width - (wm + 36 + 2 * ws), 136);
            };

            // 右侧栏（从标题条一直到底）：当前用户 / 体检结论（含看门狗，按内容定高度）/ 选中程序（占剩下的）/ 操作。不会出现滚动条
            side = new Panel(); side.Dock = DockStyle.Right; side.Width = 372; side.BackColor = cBg; side.Padding = new Padding(0, 0, 12, 0);
            BuildProfile();
            diag = new BufferedPanel(); diag.Dock = DockStyle.Top; diag.Height = 300; diag.Cursor = Cursors.Hand;
            diag.Paint += PaintDiag; diag.MouseClick += DiagClick;
            detail = new BufferedPanel(); detail.Dock = DockStyle.Fill;
            detail.Paint += PaintDetail;
            detail.Resize += delegate { LayoutDetailButtons(); };
            actions = new BufferedPanel(); actions.Dock = DockStyle.Bottom; actions.Height = 178;
            actions.Paint += delegate(object s, PaintEventArgs e) { Frame(e.Graphics, actions.Width, actions.Height, "ACTIONS", "操作", false); };
            side.Controls.Add(detail);
            side.Controls.Add(Spacer(10));
            side.Controls.Add(diag);
            side.Controls.Add(Spacer(10));
            side.Controls.Add(profile);
            side.Controls.Add(Spacer(10, DockStyle.Bottom));
            side.Controls.Add(actions);
            side.Resize += delegate { LayoutSide(); };

            // 主区域：卡片 + 走势图 + 程序列表
            Panel main = new Panel(); main.Dock = DockStyle.Fill; main.BackColor = cBg; main.Padding = new Padding(12, 0, 12, 0);
            BuildList();
            chart = new BufferedPanel(); chart.Dock = DockStyle.Top; chart.Height = 210;   // 走势图在列表上方
            chart.Paint += PaintChart; chart.MouseClick += ChartClick;
            main.Controls.Add(lv);
            main.Controls.Add(Spacer(8));
            main.Controls.Add(chart);
            main.Controls.Add(Spacer(10));
            main.Controls.Add(cards);
            lv.BringToFront();

            // 底部状态栏
            status = new BufferedPanel(); status.Dock = DockStyle.Bottom; status.Height = 28;
            status.Paint += PaintStatus;

            Controls.Add(main);
            Controls.Add(side);
            Controls.Add(Spacer(8));
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

        static readonly string[][] Links = { new[] { "YIFANOVO.COM", "https://yifanovo.com" }, new[] { "WATCHDOG.YIFANOVO.COM", "https://watchdog.yifanovo.com" } };
        List<object[]> linkRects = new List<object[]>();   // [x0, x1, url]
        string hoverLink;
        string LinkAt(Point p)
        {
            if (p.Y < 12 || p.Y > 36) return null;
            foreach (object[] r in linkRects) if (p.X >= (int)r[0] && p.X < (int)r[1]) return (string)r[2];
            return null;
        }
        Panel Spacer(int h, DockStyle dock = DockStyle.Top) { Panel p = new Panel(); p.Dock = dock; p.Height = h; p.BackColor = cBg; return p; }

        // ---------- 标题条 ----------
        // 小狗 logo：按网站图标（favicon.svg，64×64）画出来，只画一次缓存成位图
        Bitmap logo;
        static Bitmap DogLogo(int size)
        {
            Bitmap b = new Bitmap(size, size);
            using (Graphics g = Graphics.FromImage(b))
            using (GraphicsPath bg = new GraphicsPath())
            using (SolidBrush fill = new SolidBrush(Color.FromArgb(11, 14, 19)))
            using (Pen red = new Pen(Color.FromArgb(250, 76, 89), 3.2f))
            using (Pen cyan = new Pen(Color.FromArgb(150, 250, 255), 3f))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.ScaleTransform(size / 64f, size / 64f);
                const float r = 22;   // 圆角 rx = 11
                bg.AddArc(0, 0, r, r, 180, 90); bg.AddArc(64 - r, 0, r, r, 270, 90);
                bg.AddArc(64 - r, 64 - r, r, r, 0, 90); bg.AddArc(0, 64 - r, r, r, 90, 90); bg.CloseFigure();
                g.FillPath(fill, bg);
                red.LineJoin = LineJoin.Bevel; cyan.LineJoin = LineJoin.Bevel;
                g.DrawPolygon(red, new[] { new PointF(10, 26), new PointF(10, 10), new PointF(24, 20), new PointF(40, 20), new PointF(54, 10), new PointF(54, 26), new PointF(47, 51), new PointF(17, 51) });
                g.DrawLines(cyan, new[] { new PointF(21, 33), new PointF(31, 38), new PointF(21, 42) });
                g.DrawLines(cyan, new[] { new PointF(43, 33), new PointF(33, 38), new PointF(43, 42) });
                g.DrawLine(cyan, 30, 48, 34, 48);
            }
            return b;
        }
        void PaintHeader(object s, PaintEventArgs e)
        {
            Graphics g = e.Graphics; int w = header.Width, h = header.Height;
            g.FillRectangle(bBg, 0, 0, w, h);
            Scanlines(g, w, h);
            // 小狗 logo（和网站 watchdog.yifanovo.com 的图标一样）
            if (logo == null) logo = DogLogo(32);
            g.DrawImage(logo, 12, 8, 32, 32);
            // 标题：红色错位的"故障"重影 + 荧光蓝本体
            const int tx = 50, dx = tx - 16;   // logo 占的宽度，后面的东西整体右移
            if (tick % 6 == 3) Txt(g, "WATCHDOG", fHead, cRed, tx + 3, 8, 200, 34);
            else Txt(g, "WATCHDOG", fHead, cRedDim, tx + 2, 7, 200, 34);
            Txt(g, "WATCHDOG", fHead, cCyan, tx, 6, 200, 34);
            Txt(g, "// Which dream is your want", fTagB, cAccent, 152 + dx, 6, 260, 34);
            // 条形码 + 信号格（条形码每次刷新变一点，像在传数据）
            int bx = 420 + dx; uint seed = (uint)(tick * 2654435761u);
            for (int i = 0; i < 26; i++)
            {
                seed = seed * 1103515245u + 12345u; int bw = 1 + (int)((seed >> 16) % 3);
                if (bx + bw > 520 + dx) break;
                g.FillRectangle(i % 5 == 0 ? bAcc : bDimLine, bx, 12, bw, 24); bx += bw + 2;
            }
            Txt(g, string.Format("0x{0:X4}", (seed >> 8) & 0xFFFF), fMono, cRedDim, 420 + dx, 36, 100, 12);
            int[] sig = { 6, 10, 14, 18, 22 };
            int lit = 3 + tick % 3;
            for (int i = 0; i < sig.Length; i++) g.FillRectangle(i < lit ? bLv[0] : bDim, 534 + dx + i * 7, 36 - sig[i], 4, sig[i]);
            string selfTxt = string.Format("本窗口 {0:N0} MB · CPU {1:N1}%", selfMB, selfCpu);
            // 两个跳转链接：个人主页 / 软件主页
            int lx = 596 + dx; List<object[]> lr = new List<object[]>();
            foreach (string[] k in Links)
            {
                int lw = TxtW(g, k[0], fTagB) + 30;
                bool hot = hoverLink == k[1];
                g.FillPolygon(hot ? bLv[0] : bDeep, new[] { new PointF(lx + 6, 12), new PointF(lx + lw, 12), new PointF(lx + lw - 6, 36), new PointF(lx, 36) });
                g.DrawPolygon(hot ? pCyanThin : pAcc, new[] { new PointF(lx + 6, 12), new PointF(lx + lw, 12), new PointF(lx + lw - 6, 36), new PointF(lx, 36) });
                Txt(g, "↗", fCN, hot ? cBg : cAccent, lx + 9, 12, 14, 24);
                Txt(g, k[0], fTagB, hot ? cBg : cCyan, lx + 22, 12, lw - 24, 24);
                lr.Add(new object[] { lx, lx + lw, k[1] }); lx += lw + 8;
            }
            linkRects = lr;
            int rx = w - 262, rw = Math.Max(120, rx - lx - 10);
            Txt(g, "SELF // 自身占用", fSmall, cRedDim, rx - rw, 6, rw - 4, 16, tfR);
            Txt(g, selfTxt, fCN, cCyan, rx - rw, 22, rw - 4, 18, tfR);
            g.FillRectangle(bDimLine, rx + 4, 12, 1, 26);
            g.FillRectangle(tick % 2 == 0 ? bLv[2] : bPanel, w - 250, 17, 8, 8);
            Txt(g, "LIVE  " + DateTime.Now.ToString("HH:mm"), fTagB, cCyan, w - 234, 6, 90, 28);
            Txt(g, "SYS.MON v8 // 0x5744", fSmall, cRedDim, w - 200, 6, 186, 28, tfR);
            g.FillRectangle(bAcc, 0, h - 3, w, 1);
            g.FillPolygon(bAcc, new[] { new PointF(0, h - 6), new PointF(220, h - 6), new PointF(226, h - 2), new PointF(0, h - 2) });
            g.FillRectangle(bHaz, w - 140, h - 7, 128, 4);
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
            bool big = d.Mode == "mem";
            Txt(g, active ? "▼ 走势显示中" : d.Code, fSmall, active ? cCyan : cRedDim, w - 160, h - 17, 148, 14, tfR);
            if (!string.IsNullOrEmpty(d.Badge)) { int bwid = big ? 104 : w < 230 ? 72 : 84; Badge(g, d.Badge, li, w - bwid - 14, 10, bwid, 22); }
            // 大卡片（内存）：左边数值 + 进度条，右边"占用最多"。窗口窄时数值换小一号字
            int lw = big ? (int)(w * 0.54) : w;
            bool bigNum = big && lw >= 215;
            Txt(g, d.Value, bigNum ? fNumBig : fNumS, cCyan, 10, bigNum ? 30 : 36, lw - 20, bigNum ? 44 : 32);
            if (d.Pct >= 0)
            {
                int n = big ? 30 : 16; float gap = 3, bw = (lw - 24 - gap * (n - 1)) / n;
                int on = (int)Math.Round(n * Math.Min(100, d.Pct) / 100);
                for (int i = 0; i < n; i++) g.FillRectangle(i < on ? bLv[li] : bDim, 12 + i * (bw + gap), 76, bw, 8);
            }
            Txt(g, d.Sub, fCN, cGray, 12, 90, lw - 24, 20);
            if (d.Extra.Length > 0) Txt(g, d.Extra, fCN, cGray, 12, 108, lw - 24, 18);
            if (big && d.Top.Count > 0)
            {
                int x0 = lw + 4, tw = w - x0 - 16;
                g.FillRectangle(bDimLine, lw - 6, 40, 1, 72);
                Txt(g, "TOP // 占用最多", fSmall, cAccent, x0, 38, tw, 14);
                double max = Math.Max(1, d.Top.Max(t => t.Value));
                for (int i = 0; i < d.Top.Count && i < 3; i++)
                {
                    int y = 56 + i * 20;
                    g.FillRectangle(bCyanDim, x0, y + 2, (float)(tw * d.Top[i].Value / max), 15);
                    g.FillRectangle(bLv[0], x0, y + 2, 2, 15);
                    Txt(g, d.Top[i].Key, fCNb, cText, x0 + 8, y, tw - 80, 19);
                    Txt(g, string.Format("{0:N0} MB", d.Top[i].Value), fTagB, cCyan, x0 + tw - 84, y, 80, 19, tfR);
                }
            }
        }
        // 只在内容真的变了时重绘
        static bool SetData(CardData d, string value, string badge, int level, string sub, double pct)
        {
            if (d.Value == value && d.Badge == badge && d.Level == level && d.Sub == sub && (int)d.Pct == (int)pct) return false;
            d.Value = value; d.Badge = badge; d.Level = level; d.Sub = sub; d.Pct = pct;
            return true;
        }
        void SetCard(BufferedPanel card, string value, string badge, int level, string sub, double pct)
        {
            if (SetData((CardData)card.Tag, value, badge, level, sub, pct)) card.Invalidate();
        }
        void SetMemExtra(string extra, List<KeyValuePair<string, double>> top)
        {
            CardData d = (CardData)cardMem.Tag;
            string a = string.Join("|", d.Top.Select(t => t.Key + ((int)t.Value))), b = string.Join("|", top.Select(t => t.Key + ((int)t.Value)));
            if (a == b && d.Extra == extra) return;
            d.Top = top; d.Extra = extra; cardMem.Invalidate();
        }
        void SetCardExtra(BufferedPanel card, string extra)
        {
            CardData d = (CardData)card.Tag;
            if (d.Extra != extra) { d.Extra = extra; card.Invalidate(); }
        }
        void SetDog(string value, string badge, int level, string sub, double pct)
        {
            if (SetData(dog, value, badge, level, sub, pct)) diag.Invalidate(new Rectangle(0, DogY, diag.Width, DogH));
        }
        void SetChartMode(string mode)
        {
            chartMode = mode;   // 时间范围保持用户上次选的
            foreach (BufferedPanel c in cardList) c.Invalidate();
            diag.Invalidate(new Rectangle(0, DogY, diag.Width, DogH));
            chart.Invalidate();
        }

        // ---------- 体检结论 ----------
        void PaintDiag(object s, PaintEventArgs e)
        {
            Graphics g = e.Graphics; int w = diag.Width, h = diag.Height;
            Frame(g, w, h, "DIAGNOSIS", "体检结论 · 看门狗", false);
            PaintDog(g, 12, DogY, w - 26, DogH);
            int vy = DogY + DogH + 8;
            Txt(g, verdict[0], fCNbig, LevelColor(int.Parse(verdict[1])), 14, vy, w - 28, 24);
            Txt(g, verdict[2], fCN, cGray, 14, vy + 24, w - 28, 18);
            int y = vy + 48; List<object[]> rects = new List<object[]>();
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
            // 剩下的空间：看门狗最近几次检查的记录（终端风格）
            y += 6;
            if (sys.Count > 0 && y + 40 < h - 10)
            {
                g.FillRectangle(bDimLine, 14, y, w - 28, 1);
                Txt(g, "// LOG 最近的后台检查", fSmall, cAccent, 14, y + 4, w - 28, 14);
                y += 22;
                for (int i = sys.Count - 1; i >= Math.Max(0, sys.Count - 5) && y + 16 < h - 10; i--, y += 17)
                {
                    SysRow r = sys[i];
                    Txt(g, r.T.ToString("MM-dd HH:mm"), fMono, cRedDim, 16, y, 84, 16);
                    Txt(g, string.Format("巡检 {0:N1}s · 内存 {1:N1} GB · CPU {2:N0}%", r.RunMs / 1000, r.UsedMB / 1024, r.CpuPct), fCN, i == sys.Count - 1 ? cText : cGray, 102, y, w - 116, 16);
                }
            }
        }
        // 看门狗：终端风格的小面板。左边黄黑警示条，中间是"心跳"——最近 90 分钟每次后台检查是一个脉冲（越高 = 那次跑得越久）
        void PaintDog(Graphics g, int x, int y, int w, int h)
        {
            bool active = chartMode == "dog";
            g.FillRectangle(bDeep, x, y, w, h);
            g.FillRectangle(bHaz, x, y, 7, h);
            g.DrawRectangle(active ? pCyanThin : pAccDim, x, y, w - 1, h - 1);
            int cx = x + 14, li = Lx(dog.Level);
            Txt(g, "> WDG-04", fMono, cYellow, cx, y + 5, 64, 16);
            Txt(g, "看门狗 · 后台巡检", fCN, cGray, cx + 62, y + 4, w - 170, 18);
            Badge(g, dog.Badge, li, x + w - 84, y + 4, 76, 18);
            Txt(g, dog.Value, fCNbig, LevelColor(dog.Level), cx, y + 24, 140, 26);
            // 心跳线
            int px = cx + 146, pw = x + w - 10 - px, base0 = y + 44, amp = 16;
            g.DrawLine(pGrid, px, base0, px + pw, base0);
            DateTime now = DateTime.Now, from = now.AddMinutes(-90);
            List<SysRow> runs = sys.Where(r => r.T >= from).ToList();
            if (runs.Count > 0)
            {
                double maxMs = Math.Max(1, runs.Max(r => r.RunMs));
                List<PointF> pts = new List<PointF>(); pts.Add(new PointF(px, base0));
                foreach (SysRow r in runs)
                {
                    float rx = px + (float)(pw * (r.T - from).TotalMinutes / 90.0), a = amp * (float)(0.35 + 0.65 * r.RunMs / maxMs);
                    if (rx - 4 < pts[pts.Count - 1].X) continue;
                    pts.Add(new PointF(rx - 4, base0)); pts.Add(new PointF(rx - 1.5f, base0 - a)); pts.Add(new PointF(rx + 1.5f, base0 + a * 0.4f)); pts.Add(new PointF(rx + 4, base0));
                }
                pts.Add(new PointF(px + pw, base0));
                PointF[] arr = pts.ToArray();
                g.DrawLines(pPulseGlow, arr); g.DrawLines(pPulse, arr);
                float lx = px + (float)(pw * (runs[runs.Count - 1].T - from).TotalMinutes / 90.0);
                g.FillEllipse(tick % 2 == 0 ? bLv[0] : bCyanDim, lx - 3, base0 - 3, 6, 6);
            }
            Txt(g, "-90m", fMono, cRedDim, px, y + 46, 34, 12);
            Txt(g, "now", fMono, cRedDim, px + pw - 30, y + 46, 30, 12, tfR);
            // 距离下次检查的进度
            if (dog.Pct >= 0)
            {
                int n = 30; float gap = 2, bw = (w - 24 - gap * (n - 1)) / n;
                int on = (int)Math.Round(n * Math.Min(100, dog.Pct) / 100);
                for (int i = 0; i < n; i++) g.FillRectangle(i < on ? bLv[li] : bDim, cx + i * (bw + gap), y + 60, bw, 4);
            }
            Txt(g, dog.Sub, fCN, cGray, cx, y + 67, w - 24 - (active ? 76 : 0), 18);
            if (active) Txt(g, "▼ 走势显示中", fSmall, cCyan, x + w - 84, y + 69, 76, 14, tfR);
        }
        void DiagClick(object s, MouseEventArgs e)
        {
            if (e.Y >= DogY && e.Y < DogY + DogH) { SetChartMode("dog"); return; }
            // 内核问题没有对应的程序：点它切到内核走势图
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
                if (e.Y >= (int)r[0] && e.Y < (int)r[1])
                {
                    if (r[2] != null) SelectTarget((string)r[2]);
                    else if ((string)r[3] == "kernel") { kernelMetric = "pool"; SetChartMode("kernel"); }
                    break;
                }
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
            string sub = (HasNote(name) ? "✎ " : "") + (DescOf(name) ?? "-") + (r.Count > 1 ? " · " + r.Count + " 个进程" : "");
            Rule wr;
            if (watched.TryGetValue(name, out wr)) sub += string.Format("  ·  ◉ 看门狗监控中（超过 {0} MB {1}）", wr.MinMB, wr.Auto ? "自动重启" : "提醒");
            Txt(g, sub, fCN, cGray, 56, 58, w - 70, 18);
            Issue ri; resIssues.TryGetValue(name, out ri);
            string[,] cols = { { "内存", string.Format("{0:N0} MB", r.PrivMB) }, { "CPU", string.Format("{0:N1}%", r.CpuPct) }, { "读写", string.Format("{0:N1} MB/s", r.IoMBs) },
                { "句柄", string.Format("{0:N0}", r.Handles) }, { "GDI/USER", r.Gdi + "/" + r.User } };
            float[] cw = { 0.22f, 0.15f, 0.22f, 0.17f, 0.24f };
            float cx = 14;
            for (int i = 0; i < 5; i++)
            {
                float ww = (w - 28) * cw[i];
                Txt(g, cols[i, 0], fCN, cGray, cx, 80, ww, 16);
                Txt(g, cols[i, 1], fTagB, i >= 3 && ri != null ? LevelColor(ri.Level) : cText, cx, 96, ww, 20);
                cx += ww;
            }
            Rating rt = GetRating(name, r.PrivMB);
            Txt(g, "稳定性：" + rt.Text, fCNb, LevelColor(rt.Level), 14, 122, 130, 18);
            Txt(g, rt.Text == "已知问题" ? rt.Trend : rt.Note, fCN, cGray, 140, 122, w - 154, 18);
            Hit hit;
            if (hitByTarget.TryGetValue(name, out hit))
            {
                Txt(g, "已知问题：" + hit.Rule.Title, fCNb, LevelColor(rt.Level), 14, 144, w - 28, 18);
                Txt(g, hit.Why + "。" + hit.Rule.Cause, fCN, cGray, 14, 164, w - 28, Math.Max(18, h - 48 - 164), tfW);
            }
            else if (ri != null)
            {
                // 句柄 / 图形资源问题
                Txt(g, ShortTitle(ri, name), fCNb, LevelColor(ri.Level), 14, 144, w - 28, 18);
                // 空间够才显示说明（够两行就折行），不然会压到下面的按钮；体检结论里有完整说明
                int room = h - 50 - 164;
                if (room >= 18) Txt(g, ri.Sub, fCN, cGray, 14, 164, w - 28, room >= 60 ? 36 : 18, room >= 60 ? tfW : tfL);
            }
            else if (rt.Forecast.Length > 0) Txt(g, rt.Forecast, fCNb, LevelColor(rt.Level), 14, 144, w - 28, 18);
            // 剩下的空间：近 30 分钟的小走势 + 统计
            int top = hit != null ? 200 : ri != null ? (h - 50 - 164 >= 60 ? 204 : 186) : rt.Forecast.Length > 0 ? 170 : 148, bottom = h - 50;
            if (bottom - top >= 40) PaintMini(g, name, 14, top, w - 28, bottom - top);
        }
        void PaintMini(Graphics g, string name, int x, int y, int w, int h)
        {
            Ring mem, cpu, io;
            if (!series.TryGetValue(name, out mem) || mem.Count < 2) return;
            series.TryGetValue("cpu:" + name, out cpu); series.TryGetValue("io:" + name, out io);
            long from = DateTime.UtcNow.AddMinutes(-30).Ticks;
            double lo = double.MaxValue, hi = 0; int first = -1;
            for (int i = 0; i < mem.Count; i++) { if (mem.TimeAt(i) < from) continue; if (first < 0) first = i; double v = mem.ValueAt(i); lo = Math.Min(lo, v); hi = Math.Max(hi, v); }
            if (first < 0 || mem.Count - first < 2) return;
            g.FillRectangle(bDimLine, x, y, w, 1);
            Txt(g, "// 近 30 分钟", fSmall, cAccent, x, y + 4, 90, 14);
            Txt(g, string.Format("内存 {0:N0} – {1:N0} MB", lo, hi), fCN, cText, x + 88, y + 2, w - 88, 18);
            Txt(g, string.Format("CPU 平均 {0:N1}% · 读写平均 {1:N1} MB/s", Avg(cpu, from), Avg(io, from)), fCN, cGray, x + 88, y + 20, w - 88, 18);
            int cy = y + 42, ch = h - 44;
            if (ch < 16) return;
            g.FillRectangle(bDeep, x, cy, w, ch);
            double span = Math.Max(hi - lo, Math.Max(hi * 0.02, 1));
            List<PointF> pts = new List<PointF>();
            long now = DateTime.UtcNow.Ticks, len = now - from;
            for (int i = first; i < mem.Count; i++)
                pts.Add(new PointF(x + (float)(w * (double)(mem.TimeAt(i) - from) / len), cy + ch - 3 - (float)((ch - 6) * (mem.ValueAt(i) - lo) / span)));
            PointF[] arr = pts.ToArray();
            g.DrawLines(pPulseGlow, arr); g.DrawLines(pPulse, arr);
            g.FillRectangle(bLv[0], arr[arr.Length - 1].X - 2, arr[arr.Length - 1].Y - 2, 4, 4);
        }
        // 内核走势图下面的说明：有问题时给处理办法，平时列出占用最多 / 涨得最多的标签
        // 句柄 / 图形资源问题去掉程序名后的简短说明（列表和右侧栏里程序名已经显示了）
        static string ShortTitle(Issue i, string name) { return i.Title.Replace(name, "").Trim().TrimStart('的').Trim(); }
        string KernelNote()
        {
            TagStat grow = poolGrow.FirstOrDefault();
            string g = grow != null ? string.Format("窗口打开后涨最多：{0} +{1:N0} MB", TagLabel(grow), grow.GrowMB) : "";
            if (kernelIssue != null)
                return "处理：更新或回退最近装 / 更新过的驱动（显卡、网卡、杀毒、灯效、外设），重启电脑可以立即收回" + (g.Length > 0 ? " · " + g : "");
            string big = string.Join("，", poolBig.Select(t => string.Format("{0} {1:N0} MB", TagLabel(t), t.MB)));
            return (big.Length > 0 ? "占用最多：" + big : "每个驱动申请内存时带一个 4 字母标签，10 分钟后显示明细") + (g.Length > 0 ? " · " + g : "");
        }
        static double Avg(Ring r, long from)
        {
            if (r == null) return 0;
            double sum = 0; int n = 0;
            for (int i = 0; i < r.Count; i++) if (r.TimeAt(i) >= from) { sum += r.ValueAt(i); n++; }
            return n == 0 ? 0 : sum / n;
        }

        // ---------- 程序列表 ----------
        void BuildList()
        {
            lv = new BufferedListView();
            lv.Dock = DockStyle.Fill; lv.View = View.Details; lv.FullRowSelect = true; lv.HideSelection = false; lv.MultiSelect = false;
            lv.OwnerDraw = true; lv.BackColor = cRowA; lv.ForeColor = cText; lv.BorderStyle = BorderStyle.None;
            rowH = new ImageList(); rowH.ImageSize = new Size(1, 28); lv.SmallImageList = rowH;
            object[,] cols = { { "程序", 160 }, { "说明", 112 }, { "内存 MB", 76 }, { "CPU %", 56 }, { "读写 MB/s", 74 }, { "句柄", 62 }, { "GDI/USER", 82 }, { "稳定性", 74 }, { "变化", 112 }, { "判断 / 预测", 170 } };
            for (int i = 0; i < cols.GetLength(0); i++) lv.Columns.Add((string)cols[i, 0], (int)cols[i, 1]);
            lv.DrawColumnHeader += delegate(object s, DrawListViewColumnHeaderEventArgs e)
            {
                Graphics g = e.Graphics; Rectangle r = e.Bounds;
                g.FillRectangle(bBg, r);
                g.FillRectangle(bAcc, r.X, r.Bottom - 2, r.Width, 2);
                bool sorted = SortCol[sortMode] == e.ColumnIndex;
                if (sorted)
                {
                    // 当前排序的列：荧光蓝文字 + 底部荧光蓝条 + 左边小三角（不占文字位置，窄列也不会被截断）
                    g.FillRectangle(bLv[0], r.X, r.Bottom - 3, r.Width, 3);
                    float cy = r.Y + r.Height / 2f;
                    g.FillPolygon(bLv[0], new[] { new PointF(r.X + 3, cy - 3), new PointF(r.X + 11, cy - 3), new PointF(r.X + 7, cy + 2) });
                }
                Txt(g, e.Header.Text, fCNb, sorted ? cCyan : cAccent, r.X + (sorted ? 13 : 8), r.Y, r.Width - (sorted ? 19 : 16), r.Height, RightCols.Contains(e.ColumnIndex) ? tfR : tfL);
            };
            lv.ColumnClick += delegate(object s, ColumnClickEventArgs e)
            {
                sortMode = e.Column == 2 ? "mem" : e.Column == 3 ? "cpu" : e.Column == 4 ? "io" : e.Column == 5 ? "hnd" : e.Column == 6 ? "gui" : "issue";
                RefreshAll(); lv.Invalidate();
                // 列标题是单独的子窗口，lv.Invalidate() 不会重画它，旧的排序标记会留着：手动让它整个重画
                IntPtr hdr = Native.SendMessage(lv.Handle, 0x101F, IntPtr.Zero, IntPtr.Zero);   // LVM_GETHEADER
                if (hdr != IntPtr.Zero) Native.InvalidateRect(hdr, IntPtr.Zero, true);
            };
            lv.DrawItem += delegate { };
            lv.DrawSubItem += DrawSubItem;
            lv.Resize += delegate { FitColumns(); };
            // 自绘 + 整行选中时，Windows 只重画第一列；选中变化时手动重画整行，否则旧高亮会留到鼠标划过才消失
            lv.ItemSelectionChanged += delegate(object s, ListViewItemSelectionChangedEventArgs e) { lv.Invalidate(e.Item.Bounds); };
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
            int rl = ResLevel(it.Text); Rating mr; int ml = ratings.TryGetValue(it.Text, out mr) ? mr.Level : -1;   // 稳定性一栏只看内存
            Color c = col == 1 ? (HasNote(it.Text) ? cText : cGray) : col == 8 ? cGray : col == 4 ? (io >= HeavyIoMBs ? cYellow : cText)
                : col == 5 || col == 6 ? (rl >= 1 ? LevelColor(rl) : cGray) : col == 7 ? LevelColor(ml) : col == 9 ? (lvl >= 1 ? LevelColor(lvl) : cGray) : cText;
            Txt(g, e.SubItem.Text, col == 7 ? fCNb : fCN, c, r.X + 8, r.Y, r.Width - 16, r.Height, RightCols.Contains(col) ? tfR : tfL);
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
                    if (memPct)
                    {
                        // 黄色线：占总内存的百分比，用右侧固定的 0–100% 刻度，一眼看出离满还有多远
                        double totalGB = Native.Mem().ullTotalPhys / 1073741824.0;
                        Line pl = lng ? HistLine(sys, x => x.T, x => x.UsedMB / 1024 / totalGB * 100, 1, "占比") : RingLine("sys:mem", 1, "占比");
                        if (pl != null) { if (!lng) for (int i = 0; i < pl.V.Length; i++) pl.V[i] = pl.V[i] / totalGB * 100; pl.Right = true; d.Lines.Add(pl); }
                    }
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
                case "kernel":
                    {
                        List<SysRow> k = sys.Where(x => x.HasKernel).ToList();
                        if (lng && k.Count < 2) d.Msg = "看门狗从这个版本才开始记录内核内存和句柄总数（每 10 分钟一次），过一段时间就有了；可以先看\"30 分钟 / 1 小时\"的实时数据。";
                        if (kernelMetric == "total")
                        {
                            d.Title = "全系统句柄总数"; d.Unit = "万"; d.Note = lng ? rec : live;
                            Line hl2 = lng ? HistLine(k, x => x.T, x => x.Handles / 10000, 0, "句柄") : RingLine("sys:hnd", 0, "句柄");
                            if (!lng && hl2 != null) for (int i = 0; i < hl2.V.Length; i++) hl2.V[i] /= 10000;
                            d.Lines.Add(hl2);
                            break;
                        }
                        d.Title = "内核内存池（驱动用的内存）"; d.Unit = "MB"; d.Note = KernelNote();
                        d.Lines.Add(lng ? HistLine(k, x => x.T, x => x.PoolP, 0, "分页池") : RingLine("sys:kp", 0, "分页池"));
                        d.Lines.Add(lng ? HistLine(k, x => x.T, x => x.PoolN, 1, "非分页池") : RingLine("sys:kn", 1, "非分页池"));
                        break;
                    }
                default:
                    if (selected == null) { d.Note = "点选列表里的程序看它的内存走势；点上面的卡片看整机内存 / CPU / 磁盘 / 内核 / 看门狗"; break; }
                    string desc = DescOf(selected) ?? "-";
                    d.Title = selected + "  ·  " + desc; d.Note = lng ? rec : live;
                    if (procMetric == "hnd")
                    {
                        d.Unit = "个"; List<HistPt> hh; histH.TryGetValue(selected, out hh);
                        if (lng && (hh == null || hh.Count < 2)) d.Msg = "看门狗只记录内存前 30 和句柄最多的 10 个程序的句柄数（从这个版本开始），这个程序还没有长期记录；请选\"30 分钟\"或\"1 小时\"。";
                        d.Lines.Add(lng ? HistLine(hh, x => x.T, x => x.MB, 0, "句柄") : RingLine("hnd:" + selected, 0, "句柄"));
                        break;
                    }
                    if (procMetric == "gui")
                    {
                        d.Unit = "个"; d.Note = live + " · GDI / USER 单个进程上限各 1 万个";
                        if (lng) d.Msg = "看门狗的记录里没有 GDI / USER（要额外开销），只有窗口的实时数据，请选\"30 分钟\"或\"1 小时\"。";
                        else { d.Lines.Add(RingLine("gdi:" + selected, 0, "GDI")); d.Lines.Add(RingLine("usr:" + selected, 1, "USER")); }
                        break;
                    }
                    if (procMetric == "cpu" || procMetric == "io")
                    {
                        // 看门狗的记录里每个程序只有内存，CPU / 读写只有窗口的实时数据
                        bool cpu = procMetric == "cpu";
                        d.Unit = cpu ? "%" : "MB/s"; d.Zero = true; d.Note = live;
                        if (lng) d.Msg = "看门狗的记录里每个程序只记了内存；程序的 CPU 和读写只有窗口的实时数据，请选\"30 分钟\"或\"1 小时\"。";
                        else d.Lines.Add(RingLine((cpu ? "cpu:" : "io:") + selected, 0, cpu ? "CPU" : "读写"));
                        break;
                    }
                    d.Unit = "MB";
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
            int titleEnd = x - 34;
            // 选中程序时：内存 / CPU / 读写 切换；整机内存时：显示 / 隐藏百分比线
            List<object[]> mrects = new List<object[]>();
            if (chartMode == "mem")
            {
                int mw = 76, mx = x - 40 - mw;
                if (memPct) { g.FillRectangle(bLv[1], mx, 7, mw, 20); Txt(g, "% 占比 ON", fCNb, cBg, mx, 7, mw, 20, tfC); }
                else { g.DrawRectangle(pAccDim, mx, 7, mw, 20); Txt(g, "% 占比", fCN, cYellow, mx, 7, mw, 20, tfC); }
                mrects.Add(new object[] { mx, mx + mw, "pct" });
                titleEnd = mx - 10;
            }
            string[][] tabs = chartMode == "proc" && selected != null ? ProcMetrics : chartMode == "kernel" ? KernelMetrics : null;
            if (tabs != null)
            {
                string cur = chartMode == "kernel" ? kernelMetric : procMetric;
                int mw = chartMode == "kernel" ? 60 : 48, mx = x - 40 - tabs.Length * (mw + 4);
                titleEnd = mx - 10;
                foreach (string[] m in tabs)
                {
                    if (cur == m[0]) { g.FillRectangle(bAcc, mx, 7, mw, 20); Txt(g, m[1], fCNb, cBg, mx, 7, mw, 20, tfC); }
                    else { g.DrawRectangle(pAccDim, mx, 7, mw, 20); Txt(g, m[1], fCN, cAccent, mx, 7, mw, 20, tfC); }
                    mrects.Add(new object[] { mx, mx + mw, m[0] }); mx += mw + 4;
                }
            }
            metricRects = mrects;
            Txt(g, data.Title, fCNb, cText, 84, 8, titleEnd - 84, 20);
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
            bool right = lines.Any(l => l.Right);
            const int L = 70, T = 36, B = 42;
            int R = right ? 54 : 24;
            int pw = w - L - R, ph = h - T - B;
            Txt(g, data.Note, fCN, cGray, 14, h - 22, w - 200, 16);
            if (lines.Count == 0)
            {
                string msg = data.Msg != null ? data.Msg : chartMode == "proc" && selected == null ? data.Note
                    : RangeHours[range] <= 1 ? "实时数据还不够：窗口每 5 秒记录一个点，稍等片刻；或者选\"3 小时\"以上，看看门狗的记录。"
                    : "这段时间还没有看门狗的记录（每 10 分钟记录一次）。可以先看\"30 分钟 / 1 小时\"的实时数据，或者选更长的时间。";
                Txt(g, msg, fCN, cGray, 14, 44, w - 28, 40, tfW);
                return;
            }
            double max = 0, min = double.MaxValue;
            foreach (Line ln in lines) for (int i = 0; i < ln.V.Length; i++) { if (ln.T[i] < begin || ln.Right) continue; max = Math.Max(max, ln.V[i]); min = Math.Min(min, ln.V[i]); }
            if (min == double.MaxValue) min = 0;
            double lo, hi;
            if (data.FixedMax > 0) { lo = 0; hi = data.FixedMax; }
            else if (data.Zero) { lo = 0; hi = Math.Max(max * 1.15, 1); }
            else { double pad = Math.Max((max - min) * 0.15, Math.Max(max * 0.02, 0.5)); lo = Math.Max(0, min - pad); hi = max + pad; }
            string fmt = hi - lo < 10 ? "{0:N1}" : "{0:N0}";   // 范围小时多显示一位小数，免得刻度重复
            for (int i = 0; i <= 3; i++)
            {
                float y = T + ph * i / 3f;
                g.DrawLine(pGrid, L, y, L + pw, y);
                Txt(g, string.Format(fmt, hi - (hi - lo) * i / 3) + " " + data.Unit, fSmall, cGray, 4, y - 9, L - 10, 18, tfR);
                if (right) Txt(g, string.Format("{0:N0}%", 100 - 100 * i / 3.0), fSmall, cYellow, L + pw + 6, y - 9, R - 8, 18);
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
                    double fy = ln.Right ? ln.V[i] / 100 : (ln.V[i] - lo) / (hi - lo);
                    pts.Add(new PointF((float)(L + pw * (double)(ln.T[i] - begin) / spanT), (float)(T + ph * (1 - fy))));
                }
                if (pts.Count < 2) continue;
                PointF[] arr = pts.ToArray();
                if (lines.Count(l => !l.Right) == 1 && !ln.Right)
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
                string txt = ln.Right ? string.Format("{0:N1} %", ln.V[ln.V.Length - 1]) : string.Format(fmt, ln.V[ln.V.Length - 1]) + " " + data.Unit;
                if (lines.Count > 1) { Txt(g, ln.Name + " " + txt, fTagB, LevelColor(ln.Level), L + 8, ly, 160, 18); ly += 18; }
                else Txt(g, txt, fTagB, LevelColor(ln.Level), lp.X - 130, lp.Y - 26, 124, 20, tfR);
                g.DrawLine(pCyanDash, lp.X, lp.Y + 6, lp.X, T + ph);   // 末端准星线
            }
            Txt(g, "TRND-05 // 0x5452", fSmall, cRedDim, w - 180, h - 22, 166, 16, tfR);
        }
        void ChartClick(object s, MouseEventArgs e)
        {
            if (e.Y < 4 || e.Y > 30) return;
            foreach (object[] r in metricRects)
                if (e.X >= (int)r[0] && e.X < (int)r[1])
                {
                    if ((string)r[2] == "pct") memPct = !memPct; else if (chartMode == "kernel") kernelMetric = (string)r[2]; else procMetric = (string)r[2];
                    chart.Invalidate(); return;
                }
            foreach (object[] r in rangeRects)
                if (e.X >= (int)r[0] && e.X < (int)r[1]) { chartRange = (string)r[2]; chart.Invalidate(); break; }
        }

        // ---------- 状态栏 ----------
        void PaintStatus(object s, PaintEventArgs e)
        {
            Graphics g = e.Graphics; int w = status.Width, h = status.Height;
            g.FillRectangle(bBg, 0, 0, w, h);
            g.DrawLine(pAccDim, 0, 0, w, 0);
            g.FillRectangle(bHaz, 12, 9, 22, 10);
            string txt = string.Format("每 5 秒刷新 · 点关闭缩到托盘、后台继续记录 · 本窗口：内存 {0:N0} MB / CPU {1:N2}% / GDI {2} · 实时数据 {3} 条 · 点卡片 / 看门狗切换走势图 · 点列标题切换排序 · 右键程序可写备注、让看门狗监控它",
                selfMB, selfCpu, selfGdi, series.Count);
            Txt(g, txt, fCN, cGray, 42, 0, w - 54, h);
        }

        // ---------- 按钮 ----------
        Button NewBtn(Control parent, string text, int x, int y, int w, EventHandler onClick, bool primary)
        {
            Button b = new Button();
            b.Text = text; b.SetBounds(x, y, w, 28);
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
            // 选中程序的三个按钮排一行，贴在面板底部（面板高度会变）
            btnPrimary = NewBtn(detail, "重启这个程序", 14, 0, 174, delegate { FixSelected(); }, true);
            btnKill = NewBtn(detail, "结束", 194, 0, 72, delegate { KillTarget(selected); }, false);
            btnOpen = NewBtn(detail, "打开位置", 272, 0, 76, delegate { OpenLocation(selected); }, false);
            LayoutDetailButtons();
            // 操作区按钮（两列）
            int ax = 14, half = 163, full = 334, ay = 34, step = 34;
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
        void LayoutDetailButtons()
        {
            if (btnPrimary == null) return;
            int y = Math.Max(150, detail.Height - 42);
            foreach (Button b in new[] { btnPrimary, btnKill, btnOpen }) if (b.Top != y) b.Top = y;
        }
        // 体检结论按内容定高度（问题数 + 最近 5 次检查），剩下的高度都给"选中的程序"
        void LayoutSide()
        {
            if (side == null || diag == null) return;
            int logLines = Math.Min(5, sys.Count);
            int need = DogY + DogH + 8 + 48 + issues.Count * 38 + (logLines > 0 ? 6 + 22 + logLines * 17 + 2 : 0) + 12;
            int max = side.ClientSize.Height - ProfileH - 10 - 10 - 10 - actions.Height - 214;   // "选中的程序"至少留 214
            int hgt = Math.Max(DogY + DogH + 8 + 48 + 50, Math.Min(need, max));
            if (diag.Height != hgt) diag.Height = hgt;
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
            menuNote = MenuItem(menu, "✎ 写备注说明…", delegate { EditNote(selected); });
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
                menuNote.Text = HasNote(n) ? "✎ 修改备注说明…" : "✎ 写备注说明…";
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
                if (avatar != null) avatar.Dispose();
                if (logo != null) logo.Dispose();
            }
            base.Dispose(disposing);
            if (disposing) { foreach (IDisposable o in gdi) o.Dispose(); gdi.Clear(); }   // 控件都释放后再释放字体和画刷
        }
    }
}
