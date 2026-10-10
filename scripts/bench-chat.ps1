<#
.SYNOPSIS
    Strata 多轮对话基准：模拟真实使用，测量 KV cache 复用对每轮 TTFT 的影响。

.DESCRIPTION
    与 bench3-strata.ps1 相反：bench3 用唯一 nonce **故意禁止**前缀复用（为了测纯 prefill 能力），
    而真实对话恰恰依赖复用——第 2 轮起前面所有内容都在 KV cache 里，只有新增部分需要预填充。

    本脚本每轮发送**累积的 messages 数组**（和真实客户端一样），记录每轮的：
      prompt_tokens  该轮总输入
      cache_n        复用的 token 数（越大越省）
      prompt_n       真正需要预填充的 token 数
      prompt_ms      TTFT 近似
      decode         该轮的生成速度

.EXAMPLE
    .\bench-chat.ps1 -Config D:\AI\Strata\strata-q2_0-dual-q40.json -Label "chat-q40"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$Label,
    [int]$DocChars = 20000,
    [int]$GenTokens = 250,
    [int]$Warmups = 3,
    [int]$ReadyTimeoutSec = 600,
    [double]$MemReleaseTargetGiB = 26.0,
    [string]$OutFile = 'D:\AI\Strata\bench-chat.csv'
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

# 发送累积的 messages，返回 timings + usage + 助手回复
function Chat($Messages, [int]$MaxTokens) {
    $body = @{
        model = $Model; messages = $Messages
        max_tokens = $MaxTokens; temperature = 0
    } | ConvertTo-Json -Depth 8
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method Post `
            -Body $body -ContentType 'application/json' -TimeoutSec 1800
    $sw.Stop()
    return [pscustomobject]@{
        T       = $r.timings
        Usage   = $r.usage
        Content = $r.choices[0].message.content
        Wall    = $sw.Elapsed.TotalSeconds
    }
}

# ------------------------------------------------------------------ main

Write-Host ''
Write-Host ('=== 多轮对话基准: {0} ===' -f $Label) -ForegroundColor Cyan
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

$kv = ''; $chunk = ''; $slots = ''
if (Test-Path -LiteralPath $log) {
    $lines = Get-Content -LiteralPath $log
    $m = $lines | Select-String -Pattern 'prompt chunk auto: ([0-9]+) tokens' | Select-Object -First 1
    if ($m) { $chunk = $m.Matches[0].Groups[1].Value }
    $m = $lines | Select-String -Pattern 'expert cache auto: [0-9.]+ GiB free.*-> ([0-9]+) slots' | Select-Object -First 1
    if ($m) { $slots = $m.Matches[0].Groups[1].Value }
    $m = $lines | Select-String -Pattern '--kv ([a-z0-9_]+)' | Select-Object -First 1
    if ($m) { $kv = $m.Matches[0].Groups[1].Value }
}
Write-Host ('  kv={0} chunk={1} slots={2}' -f $kv, $chunk, $slots) -ForegroundColor DarkGray

Write-Host ('  热身 {0} 次 ...' -f $Warmups)
1..$Warmups | ForEach-Object {
    $n = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $null = Chat @(@{ role = 'user'; content = "（编号 $n）用一句话介绍你自己。" }) 96
}

# 构造初始「长文档」：模拟用户粘贴一段材料
$unit = '混合专家架构通过稀疏激活降低计算量，路由网络为每个 token 选择少量专家，从而在推理时只激活参数的一部分；这种设计让模型总参数量可以很大，而单次前向计算量保持较低。'
$repeat = [math]::Max(1, [int][math]::Ceiling($DocChars / $unit.Length))
$doc = '以下是一份技术材料：' + ($unit * $repeat)

$turns = @(
    '请阅读上面的材料，然后用中文总结三个要点。',
    '请把第二点展开详细说明，给出具体的技术细节。',
    '针对你刚才提到的内容，给一个可运行的 Python 代码示例。',
    '请把前面讨论的内容整理成一个表格。',
    'Now answer the first question again, in English.'
)
$genPerTurn = @(250, 300, 350, 300, 250)

$messages = @()
$rows = @()
for ($i = 0; $i -lt $turns.Count; $i++) {
    $userText = if ($i -eq 0) { $doc + "`n`n" + $turns[$i] } else { $turns[$i] }
    $messages += @{ role = 'user'; content = $userText }

    $res = Chat $messages $genPerTurn[$i]
    $t = $res.T
    $u = $res.Usage

    Write-Host ('  第 {0} 轮 | 输入 {1,6} tok (复用 {2,6} / 新读 {3,5}) | TTFT {4,7:N0} ms | 生成 {5,4} tok @ {6,5:N1} tok/s | 墙钟 {7,5:N1}s' -f `
        ($i + 1), $u.prompt_tokens, $t.cache_n, $t.prompt_n, $t.prompt_ms, $t.predicted_n, $t.predicted_per_second, $res.Wall) -ForegroundColor Green

    $rows += [pscustomobject]@{
        Label        = $Label
        KvType       = $kv
        Turn         = $i + 1
        PromptTokens = $u.prompt_tokens
        CacheN       = $t.cache_n
        PromptN      = $t.prompt_n
        TtftMs       = [math]::Round($t.prompt_ms, 0)
        GenTokens    = $t.predicted_n
        DecodeTokS   = [math]::Round($t.predicted_per_second, 1)
        WallSec      = [math]::Round($res.Wall, 1)
        ReadySec     = $readySec
        CacheSlots   = $slots
        PromptChunk  = $chunk
    }

    $messages += @{ role = 'assistant'; content = $res.Content }
}

Write-Host ''
Write-Host ('  首轮 TTFT {0:N0} ms  ->  末轮 TTFT {1:N0} ms' -f $rows[0].TtftMs, $rows[-1].TtftMs) -ForegroundColor Cyan

@($rows) | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Append -Encoding UTF8
Write-Host ('  结果已追加到 {0}' -f $OutFile) -ForegroundColor Green
Stop-Strata | Out-Null
Write-Host ('=== {0} 完成 ===' -f $Label) -ForegroundColor Cyan
