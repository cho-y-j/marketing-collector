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

## ⭐ 한 줄 설치 (Phase 14-25)

신규 PC = Tailscale + Docker 만 설치돼 있으면 **명령 한 줄**로 끝. 토큰·IP·이름 입력 0개.

**Mac / Linux**
```bash
curl -fsSL http://100.88.194.96:5000/api/v1/install.sh | sh
```

**Windows** (관리자 PowerShell)
```powershell
iwr -useb http://100.88.194.96:5000/api/v1/install.ps1 | iex
```

서버가 호출자의 hostname 으로 자동 등록 → 토큰 발급 → docker run 까지 한 번에. 같은 PC 에서 재실행해도 안전 (기존 토큰 자동 폐기 + 신규 발급).

**전제 조건** (사전 1회만):
1. Tailscale 설치 + 같은 tailnet 가입 ( https://tailscale.com/download )
2. Docker Desktop (Win/Mac) 또는 Docker Engine (Linux)

설치 후 확인:
```
docker logs -f marketing-collector
```

## 고급 셋업 — postgres-replica + uptime-kuma

집 미니 PC 가 백업 + 모니터링 역할까지 겸하는 경우만 필요. `docker-compose.yml` 참조 + `SETUP.md` 단계 진행. 일반 분산 수집만 원하면 위 한 줄 설치로 충분.

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
