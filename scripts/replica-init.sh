#!/bin/bash
# PostgreSQL Streaming Replica 초기화 스크립트.
# 첫 부팅 시 회사 master 의 base backup 을 끌어오고 standby 모드로 전환.
#
# 전제 조건 (회사 master 에서 미리 설정):
#   1. postgresql.conf:
#      wal_level = replica
#      max_wal_senders = 10
#      max_replication_slots = 10
#      hot_standby = on
#   2. pg_hba.conf:
#      host replication replicator 100.64.0.0/10 scram-sha-256
#   3. CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD '<강력한 패스워드>';
#   4. SELECT pg_create_physical_replication_slot('home_replica_slot');
#
# 환경변수 (집 PC .env):
#   MASTER_HOST=100.64.0.5            # 회사 PC Tailscale IP
#   MASTER_PORT=5433                   # 회사 mk_postgres 호스트 포트
#   REPLICATOR_USER=replicator
#   REPLICATOR_PASSWORD=<위에서 만든 패스워드>

set -e

# 이미 초기화된 경우 skip (재시작 시 덮어쓰기 방지)
if [ -f "$PGDATA/standby.signal" ]; then
  echo "[replica-init] 이미 standby 모드 — skip"
  exit 0
fi

if [ -f "$PGDATA/postgresql.conf" ]; then
  echo "[replica-init] PGDATA 비어있지 않음 — 기존 데이터 보존 (수동 재초기화 필요 시 volume 삭제)"
  exit 0
fi

echo "[replica-init] 회사 master ${MASTER_HOST}:${MASTER_PORT} 에서 base backup 시작"

PGPASSWORD="${REPLICATOR_PASSWORD}" pg_basebackup \
  -h "${MASTER_HOST}" \
  -p "${MASTER_PORT}" \
  -U "${REPLICATOR_USER}" \
  -D "$PGDATA" \
  -P -v -R -X stream \
  -S home_replica_slot

echo "[replica-init] base backup 완료. standby 모드 활성"

# 추가 설정 — hot standby + recovery 옵션
cat >> "$PGDATA/postgresql.conf" <<EOF

# Streaming replica 설정 (Phase 14-23)
hot_standby = on
hot_standby_feedback = on
primary_conninfo = 'host=${MASTER_HOST} port=${MASTER_PORT} user=${REPLICATOR_USER} password=${REPLICATOR_PASSWORD} application_name=home_replica'
primary_slot_name = 'home_replica_slot'
EOF

echo "[replica-init] 설정 완료. 부팅 후 streaming replication 시작"
