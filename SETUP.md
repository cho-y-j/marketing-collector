# 집 미니 PC 셋업 가이드

본 marketing 의 keyword-pool 수집을 분산하는 collector 워커를 집 미니 PC 에 배포하는 단계별 가이드.

## 1. 하드웨어 (한 번 30~50만원)

### 권장 사양
- CPU: Intel N100 / N305 또는 AMD Ryzen 5 5500 이상 (4코어+)
- RAM: **16GB** 권장 (collector 자체는 ~500MB 쓰지만 여유)
- SSD: 256GB (OS + Docker)
- 네트워크: 유선 1Gbps 권장 (Wi-Fi 도 가능하지만 안정성 차이)

### 추천 모델
- **Beelink Mini S12 Pro N100** (~25만원) — 가장 저렴, 충분
- **Minisforum UM560** (~50만원) — Ryzen 5, 여유
- **Intel NUC 13 N100** (~40만원) — 안정성, 사후지원

### 전력
- idle 5W / load 15W
- **24/7 가동 시 월 전기료 약 3,000~5,000원**

## 2. OS 설치

### 권장 — Ubuntu Server 24.04 LTS
- minimal install 선택 (GUI 없음, 헤드리스 운영)
- SSH 활성화
- 자동 보안 업데이트 활성화

### 초기 셋업
```bash
# 시간대 한국
sudo timedatectl set-timezone Asia/Seoul

# 방화벽 — Tailscale 외 차단
sudo ufw enable
sudo ufw allow 22/tcp  # SSH (필요 시)
sudo ufw allow in on tailscale0  # Tailscale 인터페이스 통과

# swap 4GB (메모리 여유 마진)
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 3. Docker 설치

```bash
# 공식 스크립트
curl -fsSL https://get.docker.com | sudo sh

# 일반 사용자에 docker 그룹 추가 (재로그인 필요)
sudo usermod -aG docker $USER

# 자동 시작
sudo systemctl enable --now docker

# 확인
docker --version
docker compose version
```

## 4. Tailscale 셋업

회사 PC 와 집 PC 를 한 tailnet 으로 묶어 mk_postgres / mk_redis 에 안전 접속.

### 회사 PC 에 Tailscale 설치 (이미 했으면 skip)
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# 브라우저에서 인증 → 같은 Tailscale 계정으로 로그인
```

### 회사 PC 의 Tailscale IP 확인
```bash
tailscale ip -4
# 출력 예: 100.64.0.5  ← 이 값을 집 PC 의 .env 에 넣음
```

### 회사 PC 의 mk_postgres / mk_redis 호스트 노출 확인
```bash
docker ps | grep -E "mk_postgres|mk_redis"
# 출력에 0.0.0.0:5433->5432, 0.0.0.0:6379->6379 같은 포트 매핑 있어야 함.
# 없으면 docker-compose.server.yml 의 ports 섹션 추가 + 재시작.
```

회사 PC 가 방화벽으로 5433/6379 차단 시 Tailscale 인터페이스만 통과하도록:
```bash
sudo ufw allow in on tailscale0 to any port 5433
sudo ufw allow in on tailscale0 to any port 6379
```

### 집 PC 에 Tailscale 설치
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# 회사와 같은 계정으로 로그인 → 자동 연결
```

### 연결 확인 (집 PC 에서)
```bash
# 회사 PC 의 Tailscale IP 로 ping
ping 100.64.0.5

# Postgres 연결 확인
nc -zv 100.64.0.5 5433

# Redis 연결 확인
nc -zv 100.64.0.5 6379
```

## 5. Collector 배포

### Repo clone
```bash
cd ~
git clone https://github.com/cho-y-j/marketing-collector.git
cd marketing-collector
```

### .env 작성
```bash
cp .env.example .env
nano .env
```

채워야 할 값:
- `WORKER_NAME` — 식별용 (예: `home_seoul`, `home_busan`)
- `DATABASE_URL` — 회사 PC Tailscale IP + 5433 포트
- `REDIS_URL` — 회사 PC Tailscale IP + 6379 포트
- `NEXTAUTH_SECRET`, `ENCRYPTION_KEY` — 32자+ 임의 문자열 (collector 안 쓰지만 요구됨)

### 가동
```bash
docker compose up -d
docker compose logs -f collector
```

다음 로그가 30~60초 안에 보이면 정상:
```
[collector] keyword-pool 분산 워커 가동 (WORKER_NAME=home_seoul)
[Nest] InstanceLoader  KeywordPoolModule dependencies initialized
[KeywordPoolCronJob] [bootstrap] cron 등록 — 매 1분
[KeywordPoolCollectProcessor] [pool-collect] 30개 키워드 수집 시작
[KeywordPoolCollectProcessor] [pool-collect] 처리 완료 — 성공 30 / 실패 0
```

### 회사 측 검증
회사 mk_api 컨테이너에서 `processedThisCycle` 추이 확인:
```bash
# 회사 PC 에서
docker logs mk_api --tail 50 | grep pool-collect
# 분당 처리량이 30 → 60 으로 늘어났으면 분산 성공
```

또는 어드민 페이지 `/admin/keyword-pool` 의 진척률 카드가 평소보다 2배 빠르게 증가하면 OK.

## 5-A. PostgreSQL Streaming Replica 셋업 (자산 백업)

회사 SSD 사망 시 데이터 0 손실을 위해 hot standby replica 운영.

### 회사 PC (master) 사전 작업

#### 1) postgresql.conf 수정
회사 mk_postgres 의 conf 파일 편집 — 컨테이너 안 또는 volume mount 위치:
```bash
docker exec -it mk_postgres sh
echo "wal_level = replica" >> /var/lib/postgresql/data/postgresql.conf
echo "max_wal_senders = 10" >> /var/lib/postgresql/data/postgresql.conf
echo "max_replication_slots = 10" >> /var/lib/postgresql/data/postgresql.conf
echo "hot_standby = on" >> /var/lib/postgresql/data/postgresql.conf
exit
```

#### 2) pg_hba.conf — Tailscale 대역 허용
```bash
docker exec -it mk_postgres sh -c \
  'echo "host replication replicator 100.64.0.0/10 scram-sha-256" >> /var/lib/postgresql/data/pg_hba.conf'
```

#### 3) replicator 사용자 + replication slot 생성
```bash
docker exec -it mk_postgres psql -U admin -d marketing_intelligence
```
```sql
CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD '강력한_패스워드_입력';
SELECT pg_create_physical_replication_slot('home_replica_slot');
\q
```

#### 4) mk_postgres 재시작 (설정 적용)
```bash
docker restart mk_postgres
```

### 집 PC (replica) 부팅
`.env` 의 `MASTER_HOST` / `REPLICATOR_PASSWORD` 등 채운 후:
```bash
docker compose up -d postgres-replica
docker compose logs -f postgres-replica
```
다음 로그 보이면 정상:
```
[replica-init] 회사 master 100.64.0.5:5433 에서 base backup 시작
[replica-init] base backup 완료. standby 모드 활성
LOG:  database system is ready to accept read-only connections
LOG:  started streaming WAL from primary at ...
```

### 검증
회사 master 에서 replica 연결 확인:
```bash
docker exec mk_postgres psql -U admin -d marketing_intelligence -c "SELECT * FROM pg_stat_replication;"
```
`application_name=home_replica` row 가 있고 `state=streaming` 이면 정상.

### 사고 시 master 승격 (수동)
회사 PC 사망 시 집 replica 를 master 로:
```bash
# 집 PC 에서
docker exec home_postgres_replica psql -U admin -c "SELECT pg_promote();"
```
이후 `DATABASE_URL` 을 집 PC 의 Tailscale IP 로 변경하면 서비스 재개.

## 5-B. Uptime Kuma 셋업 (모니터링 + 알림)

### 가동
```bash
docker compose up -d uptime-kuma
```

### Web UI 접속
브라우저에서 집 PC 의 Tailscale IP + 3001 포트:
```
http://<집PC_Tailscale_IP>:3001
```
처음 접속 시 admin 계정 생성.

### 모니터링 추가 (회사 endpoint)

**Monitor 1 — 회사 mk_api**
- Type: HTTP(s)
- URL: `http://100.64.0.5:4000/api/health` (또는 회사 endpoint)
- Heartbeat: 60초

**Monitor 2 — 회사 mk_web**
- Type: HTTP(s)
- URL: `http://100.64.0.5:3200`
- Heartbeat: 60초

**Monitor 3 — 회사 mk_postgres**
- Type: TCP
- Hostname: `100.64.0.5`
- Port: `5433`
- Heartbeat: 60초

**Monitor 4 — 외부 도메인 (사용자 관점)**
- Type: HTTP(s)
- URL: `http://1.221.158.115:3200`
- Heartbeat: 60초
- → 외부 사용자가 보는 URL 다운 시 즉시 감지

### 알림 채널 셋업 (Settings > Notifications)
권장: **카카오톡 친구톡 (Bizppurio)** 또는 **텔레그램 봇**

텔레그램이 가장 간단:
1. @BotFather 에 `/newbot` → 봇 생성, 토큰 발급
2. 본인이 봇과 첫 메시지 보내기 → @userinfobot 으로 chat_id 확인
3. Uptime Kuma 의 Notifications 에 Telegram 추가
4. 모든 Monitor 에 이 알림 연결

다운 발생 시 → 텔레그램 즉시 알림 (5초 안에 도착).

## 6. 자동 운영

- **재시작**: 미니 PC 재부팅 → Docker 자동 시작 → collector 자동 가동
- **자동 업데이트**: Watchtower 가 5분마다 GHCR :latest 폴링. 본 marketing 빌드되면 자동 갱신
- **장애 알림**: 본 marketing 의 `errorCount` 모니터링 (별도 알림 시스템은 추후)

## 7. 차단 발생 시 대응

만약 네이버 차단 신호 감지 (집 PC 의 errorCount 폭증):

```bash
# 즉시 집 PC collector 중지
docker compose down

# 회사 단독으로 정상 가동 확인 후, 집 PC 의 IP 회복 (24~48시간 대기) 후 재가동
```

다음 단계 옵션:
- 집 인터넷 회선 IP 갱신 (공유기 재시작 / ISP DHCP 갱신)
- 4G 라우터 추가 (KT egg / SKT 포켓파이) — 집 PC 가 LTE 망으로 전환
- 가족·지인 집에 collector 추가 배포 (다른 ISP IP)

## 부록 — 자주 하는 실수

- ❌ `localhost:5433` 으로 DATABASE_URL 설정 — 집 PC 자체로 접속하려 함. **Tailscale IP 사용 필수**.
- ❌ 회사 docker-compose 의 mk_postgres ports 가 `127.0.0.1:5433:5432` 로 묶여있음 — 외부 인터페이스에서 접근 불가. `5433:5432` (앞 IP 생략 = 0.0.0.0) 로 수정.
- ❌ 회사 mk_redis 가 비밀번호 없이 노출 — Tailscale 인터페이스만 허용 ufw 룰 필수.
- ❌ NEXTAUTH_SECRET 비워둠 — 부팅 실패. 더미 32자 채워야 함.
