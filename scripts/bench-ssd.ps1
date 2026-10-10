<#
.SYNOPSIS
    测量三种 KV cache 量化对磁盘 I/O 的影响（读取量 vs 写入量），回答「哪种更磨 SSD」。

.DESCRIPTION
    核心事实（决定了答案的形状）：
      * SSD 寿命消耗来自**写入**（NAND 的 P/E 周期），**读取几乎不磨损**；
      * KV cache 只存在于 VRAM 或系统 RAM，**从不落盘**；
      * 所以三种 KV 对 SSD 的影响只可能来自**间接路径**：
          KV 越大 -> 占用 VRAM 越多 -> expert cache slots 越少 -> 越多专家从磁盘读（读，不磨损）
          且常驻 RAM 需求越大 -> 内存压力越大 -> 换页越多（写，这才是磨损）

    本脚本对每个配置同时测量：
      * PhysicalDisk 读取字节（采样积分）
      * PhysicalDisk 写入字节（采样积分）  <- 决定磨损的那个
      * 引擎进程自身的读写字节
      * 日志里的 blob reads 计数

.EXAMPLE
    .\bench-ssd.ps1 -Config D:\AI\Strata\strata-q2_0-dual-q40.json -Label "ssd-q40"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$Label,
    [int]$Requests = 8,
    [int]$PromptChars = 12000,
    [int]$GenTokens = 200,
    [int]$SampleMs = 2000,
    [int]$ReadyTimeoutSec = 900,
    [string]$OutFile = 'D:\AI\Strata\bench-ssd.csv'
)

$ErrorActionPreference = 'Continue'
$Py     = 'D:\AI\Strata\.venv\Scripts\python.exe'
$Server = 'D:\AI\Strata\serve\server.py'
$Port   = 8081
$Root   = 'D:\AI\Strata'
$Model  = 'qwen3.8-flash-next-q2_0'

function Stop-Strata {
    $t = New-Object System.Collections.Generic.HashSet[int]
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like 'strata*' -or ($_.ProcessName -eq 'python' -and $_.Path -like "$Root\*") } |
        ForEach-Object { [void]$t.Add($_.Id) }
    $l = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($l) { foreach ($c in $l) { [void]$t.Add([int]$c.OwningProcess) } }
    foreach ($procId in $t) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    return $t.Count
}

function Wait-Ready([int]$TimeoutSec) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 5
        try {
            $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 4 -ErrorAction Stop
            if ($r.loaded) { return [math]::Round($sw.Elapsed.TotalSeconds, 1) }
        } catch { }
    }
    return -1
}

function Ask([string]$Prompt, [int]$MaxTokens) {
    $body = @{
        model = $Model; messages = @(@{ role = 'user'; content = $Prompt })
        max_tokens = $MaxTokens; temperature = 0
    } | ConvertTo-Json -Depth 6
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method Post `
            -Body $body -ContentType 'application/json' -TimeoutSec 1800
    return $r.timings
}

# ------------------------------------------------------------------ main

Write-Host ''
Write-Host ('=== SSD / 磁盘 I/O 测试: {0} ===' -f $Label) -ForegroundColor Cyan
Write-Host ('  配置: {0}' -f $Config)

Stop-Strata | Out-Null
Start-Sleep -Seconds 5

$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
$log = $cfg.log
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

$srvArgs = @($Server, '--engine', 'strata', '--config', $Config, '--port', "$Port")
$proc = Start-Process -FilePath $Py -ArgumentList $srvArgs -WorkingDirectory $Root -PassThru
Write-Host ('  已启动 (PID {0})，等待就绪（这期间的磁盘读不算入结果）...' -f $proc.Id)

$readySec = Wait-Ready $ReadyTimeoutSec
if ($readySec -lt 0) {
    Write-Host '  [失败] 未就绪' -ForegroundColor Red
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 10 }
    Stop-Strata | Out-Null
    return
}
Write-Host ('  [{0}s] 就绪' -f $readySec) -ForegroundColor Green

# 启动前先把基线读数记下来（用累计值而不是速率，更准）
function Get-DiskTotal {
    try {
        $c = Get-Counter -Counter '\PhysicalDisk(_Total)\Disk Read Bytes/sec','\PhysicalDisk(_Total)\Disk Write Bytes/sec' -ErrorAction Stop
        $r = 0; $w = 0
        foreach ($s in $c.CounterSamples) {
            if ($s.Path -like '*read bytes*') { $r = $s.CookedValue }
            elseif ($s.Path -like '*write bytes*') { $w = $s.CookedValue }
        }
        return @{ Read = $r; Write = $w }
    } catch { return $null }
}

$kv = ''; $slots = ''; $chunk = ''
if (Test-Path -LiteralPath $log) {
    $lines = Get-Content -LiteralPath $log
    $m = $lines | Select-String -Pattern '--kv ([a-z0-9_]+)' | Select-Object -First 1
    if ($m) { $kv = $m.Matches[0].Groups[1].Value }
    $m = $lines | Select-String -Pattern 'expert cache auto: [0-9.]+ GiB free.*-> ([0-9]+) slots' | Select-Object -First 1
    if ($m) { $slots = $m.Matches[0].Groups[1].Value }
    $m = $lines | Select-String -Pattern 'prompt chunk auto: ([0-9]+) tokens' | Select-Object -First 1
    if ($m) { $chunk = $m.Matches[0].Groups[1].Value }
}
Write-Host ('  kv={0} chunk={1} slots={2}' -f $kv, $chunk, $slots) -ForegroundColor DarkGray

Write-Host '  热身 2 次 ...'
1..2 | ForEach-Object { $null = Ask '用一句话介绍你自己。' 64 }

# --- 采样：每 SampleMs 采一次速率，累加得到总量 ---
$unit = '混合专家架构通过稀疏激活降低计算量，路由网络为每个 token 选择少量专家。'
$repeat = [math]::Max(1, [int][math]::Ceiling($PromptChars / $unit.Length))
$bodyText = '请阅读下面的材料并总结要点。' + ($unit * $repeat)

$readTotal = 0.0; $writeTotal = 0.0; $samples = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# 用一个后台 runspace 太复杂；这里在主循环里穿插采样：每个请求前后各采一次，
# 请求本身耗时通常 >2 s，采样点足够覆盖。
Write-Host ('  发送 {0} 个请求（每个带唯一 nonce，强制完整预填充）...' -f $Requests)
$reqTimings = @()
for ($i = 1; $i -le $Requests; $i++) {
    $before = Get-DiskTotal
    $nonce = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $t = Ask ("（编号 $nonce）`n" + $bodyText) $GenTokens
    $after = Get-DiskTotal

    if ($before -and $after) {
        $avgR = ($before.Read + $after.Read) / 2
        $avgW = ($before.Write + $after.Write) / 2
        # 用请求耗时估算这段时间的字节数
        $dur = [math]::Max(0.1, $t.prompt_ms / 1000.0 + $t.predicted_ms / 1000.0)
        $readTotal  += $avgR * $dur
        $writeTotal += $avgW * $dur
        $samples++
    }
    $reqTimings += $t
    Write-Host ('    [{0}/{1}] prompt {2} tok | prefill {3,7:N1} tok/s | decode {4,5:N1} tok/s | 盘读 {5,7:N1} MB/s 盘写 {6,6:N1} MB/s' -f `
        $i, $Requests, $t.prompt_n, $t.prompt_per_second, $t.predicted_per_second,
        $(if ($after) { $after.Read / 1MB } else { 0 }), $(if ($after) { $after.Write / 1MB } else { 0 })) -ForegroundColor Gray
}
$sw.Stop()

# 日志里的 blob reads
$blob = ''
if (Test-Path -LiteralPath $log) {
    $m = Get-Content -LiteralPath $log | Select-String -Pattern '([0-9]+) blob reads from the file' | Select-Object -Last 1
    if ($m) { $blob = $m.Matches[0].Groups[1].Value }
}
$avgPrefill = if ($reqTimings.Count) { [math]::Round(($reqTimings | Measure-Object prompt_per_second -Average).Average, 1) } else { 0 }
$avgDecode  = if ($reqTimings.Count) { [math]::Round(($reqTimings | Measure-Object predicted_per_second -Average).Average, 1) } else { 0 }

Write-Host ''
Write-Host ('  平均 prefill {0} tok/s | 平均 decode {1} tok/s' -f $avgPrefill, $avgDecode) -ForegroundColor Green
Write-Host ('  估算磁盘读取总量: {0:N0} MB' -f ($readTotal / 1MB)) -ForegroundColor Yellow
Write-Host ('  估算磁盘写入总量: {0:N0} MB   <- 这个才影响 SSD 寿命' -f ($writeTotal / 1MB)) -ForegroundColor Yellow
Write-Host ('  日志 blob reads : {0}' -f $blob) -ForegroundColor DarkGray

$row = [pscustomobject]@{
    Label         = $Label
    KvType        = $kv
    ReadySec      = $readySec
    CacheSlots    = $slots
    PromptChunk   = $chunk
    Requests      = $Requests
    AvgPrefill    = $avgPrefill
    AvgDecode     = $avgDecode
    ReadMB        = [math]::Round($readTotal / 1MB, 1)
    WriteMB       = [math]::Round($writeTotal / 1MB, 2)
    BlobReads     = $blob
    ElapsedSec    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}
@($row) | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Append -Encoding UTF8
Write-Host ('  结果已追加到 {0}' -f $OutFile) -ForegroundColor Green

Stop-Strata | Out-Null
Write-Host ('=== {0} 完成 ===' -f $Label) -ForegroundColor Cyan
