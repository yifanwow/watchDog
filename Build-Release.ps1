# Build the download package for GitHub Releases: release\WatchDog-v<version>.zip
# Contains the exe and the scripts it needs, nothing personal (no data\, logs, your rules, notes, avatar or profile).
#   .\Build-Release.ps1 -Version 1.0.0
param([string]$Version = '1.0.0')
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

# Fresh exe (Build-Exe.ps1 closes a running WatchDog first and reopens it afterwards)
& (Join-Path $dir 'Build-Exe.ps1')
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) { throw 'Build-Exe.ps1 failed' }

$name = "WatchDog-v$Version"
$out = Join-Path $dir 'release'
$stage = Join-Path $out $name
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null

# Only these files go into the package (an allow-list, so personal files can never slip in)
$files = 'WatchDog.exe', 'MemWatchdog.ps1', 'Install-Watchdog.ps1', 'Fix-NvTopps.ps1', 'Restart-ServiceHard.ps1',
         'rules.json', 'rules.local.example.json', 'README.md'
foreach ($f in $files) { Copy-Item (Join-Path $dir $f) $stage }
New-Item -ItemType Directory -Path (Join-Path $stage 'extras') | Out-Null
Copy-Item (Join-Path $dir 'extras\*') (Join-Path $stage 'extras')

@"
WatchDog v$Version  —  Windows 内存泄漏"体检 + 修复"工具
https://watchdog.yifanovo.com

1. 把整个文件夹解压到一个固定的位置（比如 D:\Tools\WatchDog），以后不要再挪：
   看门狗的计划任务会记住这个位置。
2. 双击 WatchDog.exe 打开监控窗口。
   第一次打开时 Windows 可能提示"已保护你的电脑"（因为这个程序没有付费签名）：
   点"更多信息" → "仍要运行"。
3. 在右侧"操作"里点"安装看门狗"，确认管理员权限：之后每 10 分钟在后台检查一次。
4. 点关闭只是缩到托盘，在后台继续记录。要退出：右键托盘图标 → 退出。

需要 Windows 10 / 11（自带 .NET Framework 4.8 和 PowerShell，不用另外安装任何东西）。
所有记录都只存在这个文件夹的 data\ 里，不会上传。
详细说明见 README.md。
"@ | Set-Content (Join-Path $stage '先看我.txt') -Encoding UTF8

$zip = Join-Path $out "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip
Write-Host "Package: $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"
Get-ChildItem $stage -Recurse -File | ForEach-Object { Write-Host ('  ' + $_.FullName.Substring($stage.Length + 1)) }
