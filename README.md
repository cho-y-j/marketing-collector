# marketing-collector

Marketing Intelligence Platform 의 **집 미니 PC 분산 수집 워커**.

회사 mk_postgres + mk_redis 에 Tailscale VPN 으로 접속해 Bull Queue 를 공유 → 회사 워커와 자동 분담으로 키워드 풀 수집을 병렬 처리.

## 왜 분산하나

- 풀 10만+ 확장 시 회사 한 대로 매일 사이클 못 함 (분당 30 × 24h = 4.3만 한계)
- Vercel/AWS 같은 데이터센터 IP = 네이버 차단 1순위
- **다른 ISP 의 가정용 IP** 만 진짜 분산 효과 → 집 미니 PC 가 정답
- 자세한 배경: 본 marketing repo 의 `plan.md` Phase 14-23 참조

## 동작 방식

```
[회사 PC]                       [집 미니 PC]
mk_api (전체)             ←→    home_collector (수집만)
  - 분석/AI/Web/UI                - keyword-pool processor
  - keyword-pool processor        - 회사 mk_redis 에 Bull 공유 connect
mk_postgres (master)      ─→    home_postgres_replica (실시간 백업)
                                 home_uptime_kuma (모니터링 + 다운 알림)
        │                                 │
        └──── Tailscale VPN + 같은 Bull Queue ─── 자동 분담 ──┘
```

**미니 PC 1대 = 4개 컨테이너 동시 가동**:
1. **collector** — 네이버 분산 IP 로 키워드 풀 수집 (회사와 작업 분담)
2. **postgres-replica** — 회사 master 의 hot standby (회사 SSD 사망 시 데이터 0 손실 보험)
3. **uptime-kuma** — 회사 endpoint 1분마다 체크 + 다운 시 텔레그램 알림
4. **watchtower** — collector 자동 갱신 (본 marketing 빌드 시)

회사 코드를 그대로 재사용 (`ghcr.io/cho-y-j/marketing-api:latest`) → **코드 중복 0**. 본 marketing 의 `COLLECTOR_ONLY=true` ENV 분기로 keyword-pool 만 활성.

## 셋업 — 5단계

자세한 단계는 `SETUP.md` 참조.

1. 미니 PC 준비 (Beelink N100 / Minisforum / Intel NUC — 4코어 16GB 권장)
2. Ubuntu Server 24.04 LTS 또는 Debian 12 설치
3. Docker + Docker Compose 설치
4. Tailscale 설치 + 회사 PC 와 한 tailnet 으로 연결
5. 이 repo clone → `.env` 작성 → `docker compose up -d`

## 빠른 시작

```bash
git clone https://github.com/cho-y-j/marketing-collector.git
cd marketing-collector
cp .env.example .env
# .env 의 DATABASE_URL / REDIS_URL 을 회사 PC 의 Tailscale IP 로 수정
docker compose up -d
docker compose logs -f
```

5분 안에 수집 로그가 보이면 정상:
```
[collector] keyword-pool 분산 워커 가동 (WORKER_NAME=home_seoul)
[KeywordPoolCollectProcessor] [pool-collect] 30개 키워드 수집 시작 (cycle=2026-05-09)
[KeywordPoolCollectProcessor] [pool-collect] 처리 완료 — 성공 30 / 실패 0
```

## 운영

- **자동 갱신**: Watchtower 가 5분마다 GHCR `:latest` 폴링 → 본 marketing 빌드되면 collector 도 자동 재시작
- **로그**: `docker compose logs -f collector`
- **재시작**: `docker compose restart collector`
- **중지**: `docker compose down`

## 모니터링

- 회사 측 `/admin/keyword-pool` 페이지의 `processedThisCycle` 가 분당 60 (회사 30 + 집 30) 페이스로 증가하면 정상 분산
- `errorCount` 가 평소보다 늘어나면 차단 신호 — collector 일단 중지하고 회사만 가동 권장

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| collector 부팅 즉시 죽음 | DATABASE_URL/REDIS_URL 불통 | Tailscale 내부 IP 확인. 회사 PC 의 mk_postgres/mk_redis ports 노출 확인 |
| 부팅은 되는데 처리 0건 | Bull Queue 못 잡음 | REDIS_URL 이 회사와 동일한지. queue 이름 일치 (KEYWORD_POOL_COLLECT) |
| 회사와 같은 키워드 중복 호출 | Bull lock 동작 안 함 | Redis 동일 인스턴스인지. 다른 인스턴스면 lock 무효 |
| `errorCount` 폭증 | 네이버 차단 | 즉시 collector 중지 + 회사 단독 운영. IP 다양화 (4G 라우터) |

## 관련 문서

- 본 marketing repo: https://github.com/cho-y-j/marketing
- Phase 14-23 계획: 본 repo `plan.md` 의 14-23 섹션
- Tailscale 가이드: 본 repo `SETUP.md`
