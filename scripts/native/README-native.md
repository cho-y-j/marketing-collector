# Native 설치 가이드 (Docker 불필요)

저사양 노트북 + Mac mini 외 Mac/Windows PC 에 직접 Node.js 로 collector 가동.

## 사전 준비 (한 번만)

### 모든 OS 공통
1. **Node.js 20 LTS** — https://nodejs.org/
2. **Tailscale** — https://tailscale.com/download
   - 회사 PC 의 Tailscale 계정과 같은 tailnet 가입
3. **Git** (Windows 만) — https://git-scm.com/download/win

### 회사 PC 에서 사장님이 미리 준비
1. **REDIS_PASSWORD** — 회사 `.env.server` 의 `REDIS_PASSWORD` 값
2. **DATASET_API_TOKEN** — admin secret 으로 발급:
   ```bash
   # 회사 PC 에서
   ADMIN_SECRET=$(grep DATASET_ADMIN_SECRET /home/cho/pro/marketing/.env.server | cut -d= -f2)
   curl -s -X POST http://localhost:5000/api/v1/auth/tokens \
     -H "Content-Type: application/json" \
     -H "x-admin-secret: $ADMIN_SECRET" \
     -d '{"name":"collector-laptop-N","scopes":["pool:read","pool:write","snapshot:read","snapshot:write","place:read","place:write","worker:write"]}'
   ```
   → 응답의 `token` 필드 (mkd_...) 메모해서 노트북에 전달
3. **Tailscale IP** — `tailscale ip -4` 출력 (예: 100.88.194.96)

## 설치 — Mac

```bash
# 1. 노트북에서 marketing-collector repo 받기
cd ~
git clone https://github.com/cho-y-j/marketing-collector.git
cd marketing-collector

# 2. install 스크립트 실행
chmod +x scripts/native/install-mac.sh
./scripts/native/install-mac.sh

# 3. 프롬프트에 답:
#    - WORKER_NAME (예: home_seoul_macbook)
#    - 회사 Tailscale IP
#    - REDIS_PASSWORD
#    - DATASET_API_TOKEN

# 4. 마지막에 표시되는 `sudo launchctl ...` 명령을 복사해서 실행 (재부팅 시 자동 가동)
```

## 설치 — Windows

PowerShell **관리자 권한**으로 실행:

```powershell
# 1. 노트북에서 marketing-collector repo 받기
cd C:\
git clone https://github.com/cho-y-j/marketing-collector.git
cd marketing-collector

# 2. 실행 정책 (1회만)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 3. install 스크립트 실행
.\scripts\native\install-windows.ps1

# 4. 프롬프트 응답 (Mac 동일)
```

## 가동 후 — 로그 확인

```bash
pm2 logs collector
# 출력 예시:
# [collector] keyword-pool 분산 워커 가동 (WORKER_NAME=home_seoul_macbook)
# [pool-collect] 30개 키워드 수집 시작 (cycle=2026-05-11)
# [pool-collect] 처리 완료 — 성공 30 / 실패 0
```

## 회사 측에서 검증

```bash
# 회사 PC 에서 — 워커 heartbeat 확인
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:5000/api/v1/workers
```

## 운영

| 작업 | 명령 |
|---|---|
| 상태 | `pm2 status` |
| 로그 | `pm2 logs collector` |
| 재시작 | `pm2 restart collector` |
| 중지 | `pm2 stop collector` |
| 시작 | `pm2 start collector` |
| 코드 갱신 | `cd ~/marketing-collector-app && git pull && pnpm install --prod=false && pnpm --filter api build && pm2 restart collector` |
| 제거 | `pm2 delete collector && pm2 unstartup` |

## 트러블슈팅

### Tailscale 연결 안 됨
```bash
# Mac/Linux
tailscale status
ping <회사 Tailscale IP>

# Windows (PowerShell)
tailscale status
Test-Connection <회사 Tailscale IP>
```

### Redis 연결 거부
회사 `.env.server` 의 `REDIS_PASSWORD` 정확한지 확인. 노트북 .env 와 일치해야.

### PostgreSQL 연결 거부
회사 mk_postgres 의 호스트 포트 매핑 확인:
```bash
# 회사에서
docker port mk_postgres
# 출력: 5432/tcp -> 0.0.0.0:5433
```
`0.0.0.0:5433` 또는 `100.88.x.x:5433` 노출이면 OK.

### sleep 모드 (Mac)
사양 낮은 노트북에서 sleep 들어가면 수집 멈춤:
```bash
sudo pmset -a sleep 0 disksleep 0 powernap 0
```

### 자동시작 작동 안 함 (Windows)
PowerShell 관리자 권한으로:
```powershell
pm2-startup install
pm2 save
```
