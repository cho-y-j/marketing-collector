# marketing-collector Native Install — Windows (PowerShell)
# Docker 없이 Node.js + PM2 로 직접 실행.
#
# 전제:
#   - Node.js 20 LTS 설치 (https://nodejs.org/)
#   - Tailscale 설치 + 회사 PC 와 한 tailnet
#   - Git for Windows 설치
#
# 사용법:
#   PowerShell 관리자 권한으로 실행
#   cd C:\marketing-collector
#   .\scripts\native\install-windows.ps1
#
# 결과:
#   C:\marketing-collector-app\  ← marketing 본 repo clone + 빌드
#   PM2 자동시작 등록

$ErrorActionPreference = "Stop"

function Write-OK([string]$msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "⚠ $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg) { Write-Host "✗ $msg" -ForegroundColor Red }

Write-Host "=== marketing-collector Native Install (Windows) ===" -ForegroundColor Cyan

# ─── 1. Node.js 확인 ───
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Err "Node.js 미설치"
    Write-Host "https://nodejs.org/ 에서 Node 20 LTS Windows installer 다운로드 + 설치 후 다시 실행"
    exit 1
}
$nodeVer = [int]((node -v) -replace 'v','' -split '\.' | Select-Object -First 1)
if ($nodeVer -lt 20) {
    Write-Err "Node $nodeVer — 20 LTS+ 필요"
    exit 1
}
Write-OK "Node $(node -v)"

# ─── 2. pnpm + PM2 ───
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Host "pnpm 설치 중..."
    npm install -g pnpm@9
}
Write-OK "pnpm $(pnpm -v)"

if (-not (Get-Command pm2 -ErrorAction SilentlyContinue)) {
    Write-Host "pm2 설치 중..."
    npm install -g pm2 pm2-windows-startup
}
Write-OK "pm2 $(pm2 -v)"

# ─── 3. Tailscale 확인 ───
$tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
if (-not $tailscale) {
    Write-Warn "Tailscale 미설치 — https://tailscale.com/download/windows 에서 설치 후 다시 실행"
    exit 1
}
Write-OK "Tailscale"

# ─── 4. Git 확인 ───
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Err "Git 미설치 — https://git-scm.com/download/win 에서 설치 후 다시 실행"
    exit 1
}
Write-OK "Git"

# ─── 5. marketing 본 repo clone ───
$appDir = "$env:USERPROFILE\marketing-collector-app"
if (-not (Test-Path "$appDir\.git")) {
    Write-Host "marketing repo clone 중..."
    git clone --depth 1 https://github.com/cho-y-j/marketing.git $appDir
} else {
    Write-Host "marketing repo 갱신 중..."
    Set-Location $appDir
    git pull origin main
}
Write-OK "marketing repo at $appDir"

# ─── 6. 의존성 + 빌드 ───
Set-Location $appDir
Write-Host "의존성 설치 중 (~2분)..."
pnpm install --prod=false

Write-Host "Prisma client generate..."
pnpm --filter api exec prisma generate

Write-Host "빌드 중 (~30초)..."
pnpm --filter api build
Write-OK "build done"

# ─── 7. .env 작성 ───
$envFile = "$appDir\packages\api\.env"
if (-not (Test-Path $envFile)) {
    Write-Host ""
    Write-Host "=== .env 작성 ===" -ForegroundColor Yellow
    $workerName = Read-Host "WORKER_NAME (예: home_seoul_windows)"
    $companyIp = Read-Host "회사 PC Tailscale IP (예: 100.88.194.96)"
    $redisPw = Read-Host "REDIS_PASSWORD"
    $datasetToken = Read-Host "DATASET_API_TOKEN (회사에서 발급한 mkd_...)"

    $envContent = @"
# Phase 14-24 — Native collector
COLLECTOR_ONLY=true
WORKER_NAME=$workerName
NODE_ENV=production
TZ=Asia/Seoul
PORT=4001

DATABASE_URL=postgresql://admin:admin1234@${companyIp}:5433/marketing_intelligence
REDIS_URL=redis://:${redisPw}@${companyIp}:6382

DATASET_API_URL=http://${companyIp}:5000/api/v1
DATASET_API_TOKEN=$datasetToken
DATASET_SOURCE_PROGRAM=marketing

DISABLE_KEYWORD_POOL_SEED=true
DISABLE_AI=true

NEXTAUTH_SECRET=collector_native_dummy_at_least_32_chars_xx
ENCRYPTION_KEY=collector_native_dummy_at_least_32_chars_xx
"@
    Set-Content -Path $envFile -Value $envContent -Encoding UTF8
    Write-OK ".env 작성 완료 ($envFile)"
} else {
    Write-OK ".env 이미 존재"
}

# ─── 8. PM2 시작 + 자동 등록 ───
Write-Host ""
Write-Host "PM2 collector 시작..."
Set-Location $appDir
pm2 delete collector 2>$null
pm2 start "packages\api\dist\main.js" --name collector --env production
pm2 save

# Windows 자동시작
Write-Host ""
Write-Host "=== 자동시작 등록 ===" -ForegroundColor Yellow
pm2-startup install

Write-Host ""
Write-Host "=== 설치 완료 ===" -ForegroundColor Green
Write-Host ""
Write-Host "유용한 명령:"
Write-Host "  pm2 logs collector   # 실시간 로그"
Write-Host "  pm2 status           # 가동 상태"
Write-Host "  pm2 restart collector"
Write-Host "  pm2 stop collector"
Write-Host ""
Write-Host "코드 업데이트:"
Write-Host "  cd $appDir; git pull; pnpm install --prod=false; pnpm --filter api build; pm2 restart collector"
