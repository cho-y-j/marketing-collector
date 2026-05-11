#!/bin/bash
# marketing-collector Native Install — macOS
# Docker 없이 Node.js + PM2 로 직접 실행.
#
# 전제:
#   - Node.js 20 LTS 설치 (https://nodejs.org/ — 한 번)
#   - Tailscale 설치 + 회사 PC 와 한 tailnet
#
# 사용법:
#   cd ~/marketing-collector
#   ./scripts/native/install-mac.sh
#
# 결과:
#   ~/marketing-collector-app/  ← marketing 본 repo clone + 빌드
#   .env 작성 프롬프트
#   PM2 startup 등록 (재부팅 시 자동 가동)

set -e

# 색상
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== marketing-collector Native Install (macOS) ===${NC}"

# ─── 1. Node.js 확인 ──────────────────────────────────────────────────
if ! command -v node &> /dev/null; then
  echo -e "${RED}❌ Node.js 미설치${NC}"
  echo "https://nodejs.org/ 에서 Node 20 LTS 다운로드 + 설치 후 다시 실행"
  exit 1
fi
NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [ "$NODE_VERSION" -lt 20 ]; then
  echo -e "${RED}❌ Node $NODE_VERSION — 20 LTS+ 필요${NC}"
  exit 1
fi
echo -e "${GREEN}✓ Node $(node -v)${NC}"

# ─── 2. pnpm + PM2 ────────────────────────────────────────────────────
if ! command -v pnpm &> /dev/null; then
  echo "pnpm 설치 중..."
  npm install -g pnpm@9
fi
echo -e "${GREEN}✓ pnpm $(pnpm -v)${NC}"

if ! command -v pm2 &> /dev/null; then
  echo "pm2 설치 중..."
  npm install -g pm2
fi
echo -e "${GREEN}✓ pm2 $(pm2 -v)${NC}"

# ─── 3. Tailscale ─────────────────────────────────────────────────────
if ! command -v tailscale &> /dev/null && [ ! -d "/Applications/Tailscale.app" ]; then
  echo -e "${YELLOW}⚠ Tailscale 미설치 — App Store 또는 https://tailscale.com/download 에서 설치 후 다시 실행${NC}"
  exit 1
fi
echo -e "${GREEN}✓ Tailscale${NC}"

# ─── 4. marketing 본 repo clone ───────────────────────────────────────
APP_DIR="$HOME/marketing-collector-app"
if [ ! -d "$APP_DIR/.git" ]; then
  echo "marketing repo clone 중..."
  git clone --depth 1 https://github.com/cho-y-j/marketing.git "$APP_DIR"
else
  echo "marketing repo 갱신 중..."
  cd "$APP_DIR" && git pull origin main && cd -
fi
echo -e "${GREEN}✓ marketing repo at $APP_DIR${NC}"

# ─── 5. 의존성 + 빌드 ─────────────────────────────────────────────────
cd "$APP_DIR"
echo "의존성 설치 중 (~2분)..."
pnpm install --prod=false 2>&1 | tail -3

echo "Prisma client generate..."
pnpm --filter api exec prisma generate 2>&1 | tail -3

echo "빌드 중 (~30초)..."
pnpm --filter api build 2>&1 | tail -3
echo -e "${GREEN}✓ build done${NC}"

# ─── 6. .env 작성 ─────────────────────────────────────────────────────
ENV_FILE="$APP_DIR/packages/api/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo ""
  echo -e "${YELLOW}=== .env 작성 ===${NC}"
  read -p "WORKER_NAME (예: home_seoul_macbook): " WORKER_NAME
  read -p "회사 PC Tailscale IP (예: 100.88.194.96): " COMPANY_IP
  read -p "REDIS_PASSWORD (회사 .env.server 의 REDIS_PASSWORD): " REDIS_PW
  read -p "DATASET_API_TOKEN (회사에서 발급한 mkd_...): " DATASET_TOKEN

  cat > "$ENV_FILE" <<EOF
# Phase 14-24 — Native collector
COLLECTOR_ONLY=true
WORKER_NAME=${WORKER_NAME}
# 풀 분리 — 서브 워커는 EXTRA (확장 시드). CORE 는 회사 mk_api 책임.
WORKER_TIER=EXTRA
NODE_ENV=production
TZ=Asia/Seoul
PORT=4001

DATABASE_URL=postgresql://admin:admin1234@${COMPANY_IP}:5433/marketing_intelligence
REDIS_URL=redis://:${REDIS_PW}@${COMPANY_IP}:6382

DATASET_API_URL=http://${COMPANY_IP}:5000/api/v1
DATASET_API_TOKEN=${DATASET_TOKEN}
DATASET_SOURCE_PROGRAM=marketing

DISABLE_KEYWORD_POOL_SEED=true
DISABLE_AI=true

NEXTAUTH_SECRET=collector_native_dummy_at_least_32_chars_xx
ENCRYPTION_KEY=collector_native_dummy_at_least_32_chars_xx
EOF
  chmod 600 "$ENV_FILE"
  echo -e "${GREEN}✓ .env 작성 완료 ($ENV_FILE)${NC}"
else
  echo -e "${GREEN}✓ .env 이미 존재${NC}"
fi

# ─── 7. PM2 시작 + 자동 등록 ─────────────────────────────────────────
echo ""
echo "PM2 collector 시작..."
cd "$APP_DIR"
pm2 delete collector 2>/dev/null || true
pm2 start "packages/api/dist/main.js" --name collector --env production --cwd "$APP_DIR/packages/api"
pm2 save

echo ""
echo -e "${YELLOW}=== 자동시작 등록 (1회만) ===${NC}"
echo "다음 명령을 ${RED}복사해서${NC} 터미널에 붙여넣으세요 (sudo 비번 입력 후 자동 실행):"
echo ""
pm2 startup 2>&1 | grep -E "sudo|launchctl" | head -1
echo ""

# ─── 자동 git pull cron (매일 KST 13:50 — 14:00 사이클 시작 직전) ─────
UPDATE_SCRIPT="$APP_DIR/auto-update.sh"
cat > "$UPDATE_SCRIPT" <<UPDATEEOF
#!/bin/bash
# Phase 14-24 자동 갱신 — 매일 KST 13:50 (사이클 시작 14:00 직전)
cd "$APP_DIR" || exit 1
{
  echo "=== \$(date -Iseconds) 자동 갱신 시작 ==="
  git fetch origin main 2>&1
  LOCAL=\$(git rev-parse HEAD)
  REMOTE=\$(git rev-parse origin/main)
  if [ "\$LOCAL" = "\$REMOTE" ]; then
    echo "변경 없음 — skip"
  else
    git pull origin main 2>&1
    $(command -v pnpm) install --prod=false 2>&1 | tail -3
    $(command -v pnpm) --filter api build 2>&1 | tail -3
    $(command -v pm2) restart collector 2>&1
    echo "갱신 완료 — \$REMOTE"
  fi
} >> "$APP_DIR/auto-update.log" 2>&1
UPDATEEOF
chmod +x "$UPDATE_SCRIPT"

# crontab 등록 (KST 13:50)
( crontab -l 2>/dev/null | grep -v "auto-update.sh"; echo "50 13 * * * $UPDATE_SCRIPT" ) | crontab -
echo -e "${GREEN}✓ 자동 갱신 cron 등록 (매일 KST 13:50)${NC}"
echo "  로그: $APP_DIR/auto-update.log"
echo ""
echo -e "${GREEN}=== 설치 완료 ===${NC}"
echo ""
echo "유용한 명령:"
echo "  pm2 logs collector   # 실시간 로그"
echo "  pm2 status           # 가동 상태"
echo "  pm2 restart collector"
echo "  pm2 stop collector"
echo "  cd $APP_DIR && git pull && pnpm install --prod=false && pnpm --filter api build && pm2 restart collector"
echo "    ↑ 코드 업데이트"
