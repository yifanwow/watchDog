// 系统接口和基础部件：内存 / CPU / 进程读写 / 磁盘计数器 / 服务进程号 / 环形缓存 / 双缓冲控件 / 菜单配色
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace WatchDog
{
    static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct MEMSTAT
        {
            public uint dwLength; public uint dwMemoryLoad;
            public ulong ullTotalPhys; public ulong ullAvailPhys;
            public ulong ullTotalPageFile; public ulong ullAvailPageFile;
            public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)]
        struct SERVICE_STATUS_PROCESS { public uint Type, State, Accepted, Exit, SvcExit, Check, Wait, ProcessId, Flags; }

        [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMSTAT m);
        [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern bool GetProcessIoCounters(IntPtr h, out IO_COUNTERS c);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder sb, ref int size);
        [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr h, uint flags);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr h, string app, string id);
        [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
        [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, int flags);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
        [DllImport("user32.dll")] public static extern bool InvalidateRect(IntPtr h, IntPtr rect, bool erase);
        [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern IntPtr OpenSCManager(string machine, string db, uint access);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern IntPtr OpenService(IntPtr scm, string name, uint access);
        [DllImport("advapi32.dll")] static extern bool QueryServiceStatusEx(IntPtr svc, int level, out SERVICE_STATUS_PROCESS buf, int size, out int needed);
        [DllImport("advapi32.dll")] static extern bool CloseServiceHandle(IntPtr h);
        const uint QUERY_LIMITED = 0x1000;

        public static MEMSTAT Mem() { MEMSTAT m = new MEMSTAT(); m.dwLength = (uint)Marshal.SizeOf(m); GlobalMemoryStatusEx(ref m); return m; }

        static long pIdle, pTotal;
        public static double Cpu()
        {
            long i, k, u; GetSystemTimes(out i, out k, out u);
            long t = k + u; double r = 0;
            if (pTotal > 0 && t - pTotal > 0) r = 100.0 * (1.0 - (double)(i - pIdle) / (t - pTotal));
            pIdle = i; pTotal = t;
            return Math.Max(0, Math.Min(100, r));
        }

        // 同时拿读写字节数和 GDI / USER 对象数（只打开一次进程）。拿不到时 io = -1、gdi = user = 0
        public static void IoAndGui(int pid, out long io, out uint gdi, out uint user)
        {
            io = -1; gdi = 0; user = 0;
            IntPtr h = OpenProcess(QUERY_LIMITED, false, pid);
            if (h == IntPtr.Zero) return;
            try
            {
                IO_COUNTERS c; if (GetProcessIoCounters(h, out c)) io = (long)(c.ReadBytes + c.WriteBytes);
                gdi = GetGuiResources(h, 0); user = GetGuiResources(h, 1);
            }
            finally { CloseHandle(h); }
        }

        // 整机：内核分页池 / 非分页池（MB）、句柄总数
        [StructLayout(LayoutKind.Sequential)]
        struct PERF_INFO { public int cb; public IntPtr CommitTotal, CommitLimit, CommitPeak, PhysTotal, PhysAvail, SysCache, KTotal, KPaged, KNonpaged, PageSize; public int Handles, Procs, Threads; }
        [DllImport("psapi.dll")] static extern bool GetPerformanceInfo(out PERF_INFO p, int cb);
        public static double[] Kernel()
        {
            PERF_INFO p;
            if (!GetPerformanceInfo(out p, Marshal.SizeOf(typeof(PERF_INFO)))) return null;
            double pg = (long)p.PageSize / 1048576.0;
            return new double[] { (long)p.KPaged * pg, (long)p.KNonpaged * pg, p.Handles };
        }

        // 内核内存池按"标签"分开的用量（每个驱动分配内存时都会带一个 4 个字母的标签）。不需要管理员权限。
        // 返回 标签 -> 分页 + 非分页 字节数；同时给出每个标签的非分页部分
        [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
        public static Dictionary<int, long[]> PoolTags()
        {
            int len = 256 * 1024;
            for (int attempt = 0; attempt < 3; attempt++)
            {
                IntPtr b = Marshal.AllocHGlobal(len);
                try
                {
                    int ret, st = NtQuerySystemInformation(22, b, len, out ret);   // SystemPoolTagInformation
                    if (st == unchecked((int)0xC0000004)) { len = Math.Max(len * 2, ret + 65536); continue; }   // 缓冲区不够
                    if (st != 0) return null;
                    bool x64 = IntPtr.Size == 8;
                    int n = Marshal.ReadInt32(b), sz = x64 ? 40 : 28, off0 = x64 ? 8 : 4;
                    Dictionary<int, long[]> d = new Dictionary<int, long[]>(n);
                    for (int i = 0; i < n; i++)
                    {
                        IntPtr e = b + off0 + i * sz;
                        int tag = Marshal.ReadInt32(e);
                        long pu = x64 ? Marshal.ReadInt64(e + 16) : Marshal.ReadInt32(e + 12);
                        long nu = x64 ? Marshal.ReadInt64(e + 32) : Marshal.ReadInt32(e + 24);
                        d[tag] = new long[] { pu + nu, nu };
                    }
                    return d;
                }
                finally { Marshal.FreeHGlobal(b); }
            }
            return null;
        }
        public static string TagText(int tag)
        {
            byte[] bs = BitConverter.GetBytes(tag);
            StringBuilder sb = new StringBuilder(4);
            foreach (byte c in bs) sb.Append(c >= 32 && c < 127 ? (char)c : '?');
            return sb.ToString().TrimEnd(' ');
        }

        public static string ImagePath(int pid)
        {
            IntPtr h = OpenProcess(QUERY_LIMITED, false, pid);
            if (h == IntPtr.Zero) return null;
            try { StringBuilder sb = new StringBuilder(1024); int n = sb.Capacity; return QueryFullProcessImageName(h, 0, sb, ref n) ? sb.ToString() : null; }
            finally { CloseHandle(h); }
        }

        // 服务所在的进程号；服务没运行返回 0
        public static int ServicePid(string name)
        {
            IntPtr scm = OpenSCManager(null, null, 0x0001);   // SC_MANAGER_CONNECT
            if (scm == IntPtr.Zero) return 0;
            try
            {
                IntPtr svc = OpenService(scm, name, 0x0004);   // SERVICE_QUERY_STATUS
                if (svc == IntPtr.Zero) return 0;
                try
                {
                    SERVICE_STATUS_PROCESS s; int need;
                    if (!QueryServiceStatusEx(svc, 0, out s, Marshal.SizeOf(typeof(SERVICE_STATUS_PROCESS)), out need)) return 0;
                    return (int)s.ProcessId;
                }
                finally { CloseServiceHandle(svc); }
            }
            finally { CloseServiceHandle(scm); }
        }

        public static void Dwm(IntPtr h, int attr, int val) { try { DwmSetWindowAttribute(h, attr, ref val, 4); } catch { } }
    }

    // 整机磁盘读写（PDH，英文计数器名，不受系统语言影响）。只打开一次，关窗时关闭。
    static class DiskPerf
    {
        [StructLayout(LayoutKind.Explicit)] struct FMT { [FieldOffset(0)] public uint CStatus; [FieldOffset(8)] public double Value; }
        [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhOpenQuery(string src, IntPtr user, out IntPtr q);
        [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhAddEnglishCounter(IntPtr q, string path, IntPtr user, out IntPtr c);
        [DllImport("pdh.dll")] static extern int PdhCollectQueryData(IntPtr q);
        [DllImport("pdh.dll")] static extern int PdhGetFormattedCounterValue(IntPtr c, uint fmt, IntPtr type, out FMT v);
        [DllImport("pdh.dll")] static extern int PdhCloseQuery(IntPtr q);
        static IntPtr q, cr, cw, ci;
        public static bool Open()
        {
            if (PdhOpenQuery(null, IntPtr.Zero, out q) != 0) return false;
            PdhAddEnglishCounter(q, @"\PhysicalDisk(_Total)\Disk Read Bytes/sec", IntPtr.Zero, out cr);
            PdhAddEnglishCounter(q, @"\PhysicalDisk(_Total)\Disk Write Bytes/sec", IntPtr.Zero, out cw);
            PdhAddEnglishCounter(q, @"\PhysicalDisk(_Total)\% Idle Time", IntPtr.Zero, out ci);
            PdhCollectQueryData(q); return true;
        }
        static double Get(IntPtr c) { FMT v; return PdhGetFormattedCounterValue(c, 0x200, IntPtr.Zero, out v) == 0 ? v.Value : 0; }
        // [读 B/s, 写 B/s, 忙碌 %]
        public static double[] Read()
        {
            if (q == IntPtr.Zero) return new double[] { 0, 0, 0 };
            PdhCollectQueryData(q);
            return new double[] { Get(cr), Get(cw), Math.Max(0, Math.Min(100, 100 - Get(ci))) };
        }
        public static void Close() { if (q != IntPtr.Zero) { PdhCloseQuery(q); q = IntPtr.Zero; } }
    }

    // 固定大小的环形缓存：满了就覆盖最旧的点，所以内存占用有上限。时间存 UTC ticks。
    class Ring
    {
        long[] t; float[] v; int head, n, cap;
        public DateTime LastSeen;
        public Ring(int capacity) { cap = capacity; t = new long[cap]; v = new float[cap]; }
        public void Add(DateTime when, double val)
        {
            int i;
            if (n < cap) { i = (head + n) % cap; n++; } else { i = head; head = (head + 1) % cap; }
            t[i] = when.Ticks; v[i] = (float)val; LastSeen = when;
        }
        public int Count { get { return n; } }
        public long TimeAt(int k) { return t[(head + k) % cap]; }
        public float ValueAt(int k) { return v[(head + k) % cap]; }
        public float Last { get { return n > 0 ? ValueAt(n - 1) : 0; } }

        // 存盘 / 读回：关掉窗口再打开，之前的实时记录还在
        public void Save(BinaryWriter w) { w.Write(n); for (int k = 0; k < n; k++) { w.Write(TimeAt(k)); w.Write(ValueAt(k)); } }
        public void Load(BinaryReader r, long minTicks)
        {
            int c = r.ReadInt32();
            for (int k = 0; k < c; k++) { long tt = r.ReadInt64(); float vv = r.ReadSingle(); if (tt >= minTicks) Add(new DateTime(tt, DateTimeKind.Utc), vv); }
        }

        // 内存趋势（只看最近一次重启之后：值骤降 40% 以上或断档超过 gapSec 秒视为重启）
        // 返回 [每小时变化 MB, R², 累计变化, 时长(小时), 波动系数, 点数]；数据不够返回 null
        public double[] Stats(double gapSec)
        {
            if (n < 3) return null;
            int s = 0;
            for (int k = 1; k < n; k++)
                if (ValueAt(k) < 0.6 * ValueAt(k - 1) || (TimeAt(k) - TimeAt(k - 1)) / 1e7 > gapSec) s = k;
            int m = n - s;
            if (m < 3) return null;
            double t0 = TimeAt(s), sx = 0, sy = 0, sxx = 0, sxy = 0, syy = 0;
            for (int k = s; k < n; k++)
            {
                double x = (TimeAt(k) - t0) / 36e9, y = ValueAt(k);
                sx += x; sy += y; sxx += x * x; sxy += x * y; syy += y * y;
            }
            double span = (TimeAt(n - 1) - t0) / 36e9;
            double den = m * sxx - sx * sx;
            if (den <= 0) return null;
            double num = m * sxy - sx * sy, vy = m * syy - sy * sy;
            double r2 = vy > 0 ? (num * num) / (den * vy) : 0;
            double mean = sy / m;
            double cv = mean > 0 ? Math.Sqrt(Math.Max(0, syy / m - mean * mean)) / mean : 0;
            return new double[] { num / den, r2, ValueAt(n - 1) - ValueAt(s), span, cv, m };
        }
    }

    class BufferedPanel : Panel
    {
        public BufferedPanel() { DoubleBuffered = true; ResizeRedraw = true; }
    }

    // 列表：跳过系统默认的"先擦背景"，背景在双缓冲里和各行一起画好，一次显示，不闪
    class BufferedListView : ListView
    {
        public BufferedListView() { DoubleBuffered = true; }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x14) { m.Result = (IntPtr)1; return; }   // WM_ERASEBKGND
            base.WndProc(ref m);
        }
    }

    class CyberColors : ProfessionalColorTable
    {
        static Color bg = Color.FromArgb(24, 11, 14), sel = Color.FromArgb(70, 20, 26), acc = Color.FromArgb(255, 95, 87);
        public override Color ToolStripDropDownBackground { get { return bg; } }
        public override Color ImageMarginGradientBegin { get { return bg; } }
        public override Color ImageMarginGradientMiddle { get { return bg; } }
        public override Color ImageMarginGradientEnd { get { return bg; } }
        public override Color MenuItemSelected { get { return sel; } }
        public override Color MenuItemSelectedGradientBegin { get { return sel; } }
        public override Color MenuItemSelectedGradientEnd { get { return sel; } }
        public override Color MenuItemBorder { get { return acc; } }
        public override Color MenuBorder { get { return acc; } }
        public override Color SeparatorDark { get { return Color.FromArgb(92, 30, 33); } }
        public override Color SeparatorLight { get { return bg; } }
    }
}
