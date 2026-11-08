# watchDog

一组 Windows 小工具，用来发现和处理常见软件的内存泄漏，并用一个可视化窗口查看内存 / CPU 是否正常。

纯 PowerShell 实现，不需要安装任何依赖（Windows 10 / 11 自带的 Windows PowerShell 5.1 即可）。

## 包含什么

| 文件 | 作用 |
|---|---|
| `MemMonitor.bat` / `MemMonitor.ps1` | **可视化监控窗口**：内存、CPU、看门狗状态，疑似内存泄漏的程序，以及每个程序最近 24 小时的内存曲线 |
| `MemWatchdog.ps1` | **看门狗**：检查已知会泄漏的程序/服务，超过上限自动重启；同时记录历史数据给监控窗口用 |
| `Install-Watchdog.ps1` | 把看门狗安装为计划任务（每 10 分钟 + 登录时运行）。加 `-Uninstall` 卸载 |
| `SonicStudio.ps1` / `SonicStudio-On.bat` / `SonicStudio-Off.bat` | 一键开关华硕 Sonic Studio（Nahimic / A-Volute）。关闭时会释放 Windows 音频服务泄漏的内存 |
| `Fix-NvTopps.ps1` | 修复 NVIDIA 显示容器（NVDisplay.Container）占用几个 GB 内存、持续读写硬盘的问题：重建膨胀的 `nvtopps.db3` 数据库 |

## 使用

1. 双击 `MemMonitor.bat` 打开监控窗口。
2. 右键 `Install-Watchdog.ps1` → 用 PowerShell 运行，确认管理员权限，安装看门狗。
3. 看门狗运行约 2 小时后，窗口开始判断"疑似内存泄漏"。

需要调整监控的程序或上限，修改 `MemWatchdog.ps1` 开头的配置即可。

## 如何判断"疑似内存泄漏"

不是看占用大不大，而是看是否**持续稳定地上涨**：

- 至少 2 小时的数据（只看最近一次重启之后）
- 每小时上涨 ≥ 50 MB，累计上涨 ≥ 300 MB
- 上涨趋势稳定（线性回归 R² ≥ 0.6），忽高忽低的不算

占用大但平稳的程序标记为"占用较大"，不会被当成泄漏。

## 自身不会泄漏

- 看门狗每次运行几秒，检查完就退出，不常驻内存。
- 监控窗口只在打开时运行，最小化时暂停刷新，所有临时数据每次刷新整体替换；底部实时显示窗口自身占用。
- 自测：`MemMonitor.ps1 -SelfTest -Loops 300` 连续刷新 300 次，前后自身内存稳定在约 100 MB。
- 历史数据每天约 260 KB，只保留 7 天。

## 已知的泄漏来源（作者电脑上实测）

- **NVIDIA NVDisplay.Container**：`C:\ProgramData\NVIDIA Corporation\nvtopps\nvtopps.db3` 膨胀到 2 GB+，导致容器占用 8 GB 内存并持续读写硬盘。重建数据库后降到约 24 MB。
- **Windows 音频服务（Audiosrv）**：装有 Sonic Studio / Nahimic 时长时间运行可涨到 2 GB+。
- **罗技 G HUB 托盘程序**（`lghub_system_tray`）：长时间运行可涨到数 GB。只重启托盘，不影响设备设置。
