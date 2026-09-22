# 各コンポーネントリポジトリを repos/ に clone / pull する(Windows PowerShell版)。
# 命名の考え方は sync-repos.sh の冒頭コメントを参照(リポジトリ名とディレクトリ名を分離する)。
$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ReposDir = Join-Path $RootDir "repos"
$EnvPath = Join-Path $RootDir ".env"
$GitHubBase = "https://github.com"

if (Test-Path $EnvPath) {
  Get-Content $EnvPath | ForEach-Object {
    if ($_ -match '^\s*#') { return }
    if ($_ -match '^\s*$') { return }
    $parts = $_ -split '=', 2
    if ($parts.Length -eq 2) {
      [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), 'Process')
    }
  }
}

New-Item -ItemType Directory -Force -Path $ReposDir | Out-Null

function Sync-Repo($Dir, $Slug, $Branch) {
  $Url = "$GitHubBase/$Slug.git"
  $Path = Join-Path $ReposDir $Dir
  $GitDir = Join-Path $Path ".git"

  if (Test-Path $GitDir) {
    Write-Host "Updating $Dir <- $Slug ($Branch)..."
    git -C $Path fetch origin $Branch
    git -C $Path checkout $Branch
    git -C $Path pull --ff-only origin $Branch
  } else {
    Write-Host "Cloning $Dir <- $Slug ($Branch)..."
    git clone --branch $Branch $Url $Path
  }

  $PyProject = Join-Path $Path "pyproject.toml"
  if ((Test-Path $PyProject) -and (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Host "uv sync: $Dir"
    Push-Location $Path
    try { uv sync } catch { Write-Warning "$Dir の uv sync に失敗(後で確認してください)" }
    Pop-Location
  }
}

function Get-BranchEnv($VarName, $Default) {
  $v = [Environment]::GetEnvironmentVariable($VarName)
  if ([string]::IsNullOrEmpty($v)) { return $Default } else { return $v }
}

Sync-Repo "petit-mcp"     "TeamPuchi/petit-mcp"     (Get-BranchEnv "PETIT_MCP_BRANCH" "main")
# TODO(なぎ確認): ダッシュボードの正本は TeamPuchi/m5-petit-app か TeamPuchi/petit-app か。
Sync-Repo "petit-app"     "TeamPuchi/m5-petit-app"  (Get-BranchEnv "PETIT_APP_BRANCH" "main")
Sync-Repo "petit-memory"  "TeamPuchi/petit-memory"  (Get-BranchEnv "PETIT_MEMORY_BRANCH" "main")
Sync-Repo "petit-desire"  "TeamPuchi/petit-desire"  (Get-BranchEnv "PETIT_DESIRE_BRANCH" "main")
Sync-Repo "petit-scripts" "TeamPuchi/petit-scripts" (Get-BranchEnv "PETIT_SCRIPTS_BRANCH" "main")

$WithSpeech = Get-BranchEnv "WITH_SPEECH" "0"
if ($WithSpeech -eq "1") {
  # TeamPuchi に fork が無いため上流を指している。
  Sync-Repo "petit-speech"            "PetitOnes/m5-petit-speech"            (Get-BranchEnv "PETIT_SPEECH_BRANCH" "main")
  Sync-Repo "petit-voice-recognition" "PetitOnes/m5-petit-voice-recognition" (Get-BranchEnv "PETIT_VOICE_RECOGNITION_BRANCH" "main")
}

Write-Host "sync-repos.ps1 完了"
