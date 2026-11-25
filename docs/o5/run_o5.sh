#!/usr/bin/env bash
# O5：HAProxy 替换 lbd。手工启动 3 个 enrolld，HAProxy 监听 8080；
# C1 做 kill/pause，C3 做变慢；轮询 HAProxy stats 记录 UP/DOWN。
set -u
cd /root/lab3 || exit 1
O5=/root/o5
mkdir -p "$O5"
log(){ echo "[$(date +%H:%M:%S)] $*"; }

stop_all(){
  pkill -x haproxy 2>/dev/null || true
  pkill -x scaler 2>/dev/null || true
  pkill -x lbd 2>/dev/null || true
  scripts/cleanup.sh >/dev/null 2>&1 || true
}

start_instances(){
  stop_all
  for p in 8101 8102 8103; do
    systemctl reset-failed lab3-inst-$p 2>/dev/null || true
    systemd-run --unit=lab3-inst-$p -p CPUQuota=25% -p MemoryMax=128M -p MemorySwapMax=0 \
      -p AllowedCPUs=1 "$PWD/bin/enrolld" -addr 127.0.0.1:$p -data "$PWD/data/inst-$p" \
      -warmup 60s -work 1000000
  done
  for i in $(seq 1 40); do
    ok=1
    for p in 8101 8102 8103; do
      curl -fsS -m 1 "http://127.0.0.1:$p/readyz" >/dev/null 2>&1 || ok=0
    done
    [ "$ok" = 1 ] && { log "instances ready after ~$((i*3))s"; return 0; }
    sleep 3
  done
  log "TIMEOUT waiting instances"; return 1
}

start_haproxy(){
  pkill -x haproxy 2>/dev/null || true
  sleep 1
  nohup haproxy -f "$O5/haproxy.cfg" -db >"$O5/haproxy.log" 2>&1 &
  sleep 2
  curl -fsS -m 2 http://127.0.0.1:8404/stats >/dev/null || { log "haproxy stats not ready"; return 1; }
  log "haproxy ready"
}

poll_status(){
  local name=$1
  (
    echo "unix_ms,s1,s2,s3" >"$O5/$name-status.csv"
    while :; do
      ts=$(date +%s%3N)
      csv=$(curl -s -m 1 http://127.0.0.1:8404/stats\;csv 2>/dev/null || true)
      s1=$(printf '%s\n' "$csv" | awk -F, '$1=="be"&&$2=="s1"{print $18}')
      s2=$(printf '%s\n' "$csv" | awk -F, '$1=="be"&&$2=="s2"{print $18}')
      s3=$(printf '%s\n' "$csv" | awk -F, '$1=="be"&&$2=="s3"{print $18}')
      echo "$ts,${s1:-?},${s2:-?},${s3:-?}" >>"$O5/$name-status.csv"
      sleep 0.2
    done
  ) &
  POLL_PID=$!
}

run_case(){
  local name=$1
  log "=== $name start ==="
  bin/loadgen -url http://127.0.0.1:8080/api/courses/1 -plan 168@240s -slo 0.2s \
    -out "$O5/$name-steps.csv" -timeline "$O5/$name-timeline.csv" >"$O5/$name-loadgen.log" 2>&1
  log "=== $name done rc=$? ==="
}

# C1：kill 8102、pause 8103 20s
start_instances || exit 1
start_haproxy || exit 1
poll_status c1
( sleep 60; scripts/inject.sh kill 8102 ) & I1=$!
( sleep 160; scripts/inject.sh pause 8103 20 ) & I2=$!
run_case c1
wait $I1 $I2
kill $POLL_PID 2>/dev/null || true
cp data/marks.csv "$O5/c1-marks.csv" 2>/dev/null || true

# C3：8102 降到 14%，不摘除
start_instances || exit 1
start_haproxy || exit 1
poll_status c3
( sleep 60; scripts/inject.sh slow 8102 14 ) & I1=$!
( sleep 180; scripts/inject.sh restore 8102 25 ) & I2=$!
run_case c3
wait $I1 $I2
kill $POLL_PID 2>/dev/null || true
cp data/marks.csv "$O5/c3-marks.csv" 2>/dev/null || true

log "O5 DONE"
