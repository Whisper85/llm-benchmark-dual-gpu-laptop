<#
.SYNOPSIS
    Strata 基准测试 v3：每个测点重复 N 次取中位数，并用唯一 nonce 强制绕过 prompt cache。

.DESCRIPTION
    v1 的问题：每个测点只测一次，实测波动高达 8 倍。
    v2 的问题：重复发送同一 prompt 时 server 复用 KV cache，第二次起 prompt_n 从 1259 掉到 5。
    v3 的改进：
      1. 每次请求在开头插入唯一 nonce，强制完整预填充（并记录 cache_n 以便核查）；
      2. 每个测点重复 -Repeats 次，取中位数并记录极差；
      3. 启动前等待可用内存回到基线（上一实例释放 22 GiB 需要时间）；
      4. 热身更充分。

.EXAMPLE
    .\bench3-strata.ps1 -Config D:\AI\Strata\strata-q2_0-single.json -Label "v3-single" -Repeats 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$Label,
    [int[]]$PromptChars = @(2000, 8000, 30000),
    [int]$GenTokens = 200,
    [int]$Repeats = 3,
    [int]$Warmups = 4,
    [int]$ReadyTimeoutSec = 600,
    [double]$MemReleaseTargetGiB = 26.0,
    [string]$OutFile = 'D:\AI\Strata\bench-results3.csv'
)

$ErrorActionPreference = 'Continue'
$Py     = 'D:\AI\Strata\.venv\Scripts\python.exe'
$Server = 'D:\AI\Strata\serve\server.py'
$Port   = 8081
$Root   = 'D:\AI\Strata'
$Model  = 'qwen3.8-flash-next-q2_0'

function Get-AvailGiB {
    try { return [math]::Round((Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue / 1024, 2) }
    catch { return -1 }
}

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
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method Post `
            -Body $body -ContentType 'application/json' -TimeoutSec 1800
    $sw.Stop()
    return [pscustomobject]@{ T = $r.timings; Wall = $sw.Elapsed.TotalSeconds }
}

function Get-Median($Values) {
    $s = @($Values | Sort-Object)
    if ($s.Count -eq 0) { return 0 }
    if ($s.Count % 2 -eq 1) { return $s[[int](($s.Count - 1) / 2)] }
    return ($s[$s.Count / 2 - 1] + $s[$s.Count / 2]) / 2
}

# ------------------------------------------------------------------ main

Write-Host ''
Write-Host ('=== 基准 v3: {0} ===' -f $Label) -ForegroundColor Cyan
Write-Host ('  配置: {0}' -f $Config)

$killed = Stop-Strata
if ($killed -gt 0) { Write-Host ('  停止了 {0} 个旧进程' -f $killed) }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 90) {
    if ((Get-AvailGiB) -ge $MemReleaseTargetGiB) { break }
    Start-Sleep -Seconds 3
}
Write-Host ('  启动前可用内存: {0:N2} GiB' -f (Get-AvailGiB))

$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
$log = $cfg.log
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

$srvArgs = @($Server, '--engine', 'strata', '--config', $Config, '--port', "$Port")
$proc = Start-Process -FilePath $Py -ArgumentList $srvArgs -WorkingDirectory $Root -PassThru
Write-Host ('  已启动 (PID {0})，等待就绪 ...' -f $proc.Id)

$readySec = Wait-Ready $ReadyTimeoutSec
if ($readySec -lt 0) {
    Write-Host '  [失败] 未就绪' -ForegroundColor Red
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 12 }
    Stop-Strata | Out-Null
    return
}
Write-Host ('  [{0}s] 就绪' -f $readySec) -ForegroundColor Green

$meta = [ordered]@{}
if (Test-Path -LiteralPath $log) {
    $lines = Get-Content -LiteralPath $log
    foreach ($p in @(
        @{ K = 'resident';     R = 'resident RAM mode: ([0-9.]+) GiB of experts in RAM' },
        @{ K = 'notfit';       R = 'whole resident RAM mode does not fit' },
        @{ K = 'slots';        R = 'expert cache auto: [0-9.]+ GiB free.*-> ([0-9]+) slots' },
        @{ K = 'prompt_chunk'; R = 'prompt chunk auto: ([0-9]+) tokens' }
    )) {
        $m = $lines | Select-String -Pattern $p.R | Select-Object -First 1
        $meta[$p.K] = if ($m) { $m.Matches[0].Groups[1].Value } else { '' }
    }
}
Write-Host ('  启动信息: {0}' -f (($meta.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')) -ForegroundColor DarkGray

Write-Host ('  热身 {0} 次（每次带唯一 nonce）...' -f $Warmups)
1..$Warmups | ForEach-Object {
    $n = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $null = Ask "（编号 $n）用一句话介绍你自己。" 128
}

$unit = '人工智能的混合专家架构通过稀疏激活来降低计算量，从而在消费级硬件上运行大模型。'
$rows = @()
foreach ($chars in $PromptChars) {
    $repeat = [math]::Max(1, [int][math]::Ceiling($chars / $unit.Length))
    $body_ = '请阅读下面的文字，然后用中文写一段总结。' + ($unit * $repeat)

    $pre = @(); $dec = @(); $ttft = @(); $cache = @(); $ptok = @()
    for ($k = 1; $k -le $Repeats; $k++) {
        # 唯一 nonce 放在最前面：让 KV cache 无法匹配前缀，强制完整预填充
        $nonce = [guid]::NewGuid().ToString('N').Substring(0, 10)
        $prompt = "【本轮请求编号 $nonce，请忽略这个编号】`n" + $body_
        $res = Ask $prompt $GenTokens
        $t = $res.T
        $pre   += [double]$t.prompt_per_second
        $dec   += [double]$t.predicted_per_second
        $ttft  += [double]$t.prompt_ms
        $cache += [int]$t.cache_n
        $ptok  += [int]$t.prompt_n
    }
    $mp = Get-Median $pre; $md = Get-Median $dec; $mt = Get-Median $ttft
    $mpTok = Get-Median $ptok; $mcache = Get-Median $cache
    $pRange = ($pre | Measure-Object -Maximum).Maximum - ($pre | Measure-Object -Minimum).Minimum
    $dRange = ($dec | Measure-Object -Maximum).Maximum - ($dec | Measure-Object -Minimum).Minimum

    Write-Host ('    prompt {0,6} tok (cache {1,5}) | prefill 中位 {2,7:N1} 极差 {3,6:N1} | TTFT 中位 {4,6:N0} ms | decode 中位 {5,5:N1} 极差 {6,5:N1}' -f `
        $mpTok, $mcache, $mp, $pRange, $mt, $md, $dRange) -ForegroundColor Green

    $rows += [pscustomobject]@{
        Label       = $Label
        ReadySec    = $readySec
        PromptChunk = $meta['prompt_chunk']
        CacheSlots  = $meta['slots']
        ResidentGiB = $meta['resident']
        NotFit      = $meta['notfit']
        PromptChars = $chars
        PromptTok   = $mpTok
        CacheN      = $mcache
        Reps        = $Repeats
        PrefillMed  = [math]::Round($mp, 1)
        PrefillRange= [math]::Round($pRange, 1)
        TtftMedMs   = [math]::Round($mt, 0)
        DecodeMed   = [math]::Round($md, 1)
        DecodeRange = [math]::Round($dRange, 1)
    }
}

@($rows) | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Append -Encoding UTF8
Write-Host ('  结果已追加到 {0}' -f $OutFile) -ForegroundColor Green
Stop-Strata | Out-Null
Write-Host ('=== {0} 完成 ===' -f $Label) -ForegroundColor Cyan
