<#
.SYNOPSIS
    把 D:\AI\bench-publish 发布到 GitHub（填空即用）。

.DESCRIPTION
    你只需要改下面两行：$GitHubUser 和 $RepoName。
    脚本会依次完成：设置提交身份 -> 提交 -> 关联远程 -> 推送。

    推送时会弹出 GitHub 登录窗口（浏览器授权），这是 GitHub 的凭证机制，不是脚本在要密码。
    如果没有弹出，说明你还没在 Git Credential Manager 里登录过 GitHub——
    先运行一次 `git push`，按提示在浏览器里授权即可（只需授权一次，之后都免密）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\publish.ps1
#>

# ============ 改成你自己的信息 ============
$GitHubUser = 'Whisper85'      # 例如 'onlmo'
$RepoName   = 'llm-benchmark-dual-gpu-laptop'
$CommitMsg  = '本地大模型基准测试：四轮方法论与实测数据'
# =========================================

$ErrorActionPreference = 'Stop'
$RepoDir = 'D:\AI\bench-publish'

if ($GitHubUser -eq 'YOUR_GITHUB_USERNAME') {
    Write-Host ''
    Write-Host '  [!] 请先用记事本打开本文件，把 $GitHubUser 改成你的 GitHub 用户名。' -ForegroundColor Red
    Write-Host '      仓库名 $RepoName 也可以按喜好改。' -ForegroundColor Red
    Write-Host ''
    exit 1
}

Set-Location $RepoDir

Write-Host ''
Write-Host '=== 1/5 设置提交身份 ===' -ForegroundColor Cyan
# 用 GitHub 提供的 noreply 邮箱，避免把真实邮箱写进公开的提交记录
$email = "$GitHubUser@users.noreply.github.com"
git config user.name  $GitHubUser
git config user.email $email
Write-Host ("  user.name  = {0}" -f $GitHubUser)
Write-Host ("  user.email = {0}" -f $email)

Write-Host ''
Write-Host '=== 2/5 提交 ===' -ForegroundColor Cyan
git add -A
$staged = (git diff --cached --name-only | Measure-Object).Count
if ($staged -eq 0) {
    Write-Host '  没有新改动需要提交' -ForegroundColor DarkGray
} else {
    git commit -m $CommitMsg
    Write-Host ("  已提交 {0} 个文件" -f $staged) -ForegroundColor Green
}

Write-Host ''
Write-Host '=== 3/5 关联远程仓库 ===' -ForegroundColor Cyan
$url = "https://github.com/$GitHubUser/$RepoName.git"
$existing = git remote 2>$null
if ($existing -contains 'origin') {
    git remote set-url origin $url
    Write-Host ("  已更新 origin -> {0}" -f $url)
} else {
    git remote add origin $url
    Write-Host ("  已添加 origin -> {0}" -f $url)
}

Write-Host ''
Write-Host '=== 4/5 确保分支为 main ===' -ForegroundColor Cyan
git branch -M main
Write-Host '  当前分支: main'

Write-Host ''
Write-Host '=== 5/5 推送 ===' -ForegroundColor Cyan
Write-Host '  如果弹出 GitHub 登录窗口，请在浏览器里完成授权 ...'
git push -u origin main

Write-Host ''
Write-Host '=== 完成 ===' -ForegroundColor Green
Write-Host ("  仓库地址: https://github.com/{0}/{1}" -f $GitHubUser, $RepoName)
Write-Host ''
Write-Host '  提醒：先在 GitHub 网页上创建一个【空仓库】（不要勾选 README / .gitignore / License），'
Write-Host '        否则推送会因为「远程有本地没有的提交」而被拒绝。'
Write-Host ''
