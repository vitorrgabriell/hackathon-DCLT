#!/usr/bin/env bash
# Coleta o consumo REAL de CPU/memória dos pods dos 3 serviços a partir do
# Prometheus (kube-prometheus-stack) e imprime, por serviço, os percentis que
# embasam o rightsizing de requests/limits — para NÃO chutar valores.
#
# Heurística (estilo VPA / Google SRE Workbook):
#   - CPU request    = p95 do uso  (HPA escala sobre isso; p95 evita flapping)
#   - Memory request = p95 do working set
#   - Memory limit   = max working set * 1.2  (memória é incompressível: pouca
#                      folga = OOMKill; por isso teto acima do pico observado)
#   - CPU limit      = mantido generoso/removido (CPU é compressível: throttle,
#                      não morte) — decisão documentada no relatório
#
# Pré-requisitos: cluster no ar, kubeconfig apontado (aws eks update-kubeconfig),
# jq. Gere tráfego representativo ANTES de rodar (ex: k6/hey nos 3 endpoints) e
# deixe rodar pelo menos ~30-60min pra janela ter dados.
set -euo pipefail
export LC_NUMERIC=C   # printf %f usa ponto decimal, independente do locale

NS="${NS:-solidarytech}"
PROM_SVC="${PROM_SVC:-kube-prometheus-stack-prometheus}"
PROM_NS="${PROM_NS:-monitoring}"
PROM_PORT="${PROM_PORT:-9090}"
WINDOW="${WINDOW:-1h}"   # janela de análise; suba pra 24h/7d com mais histórico

command -v jq >/dev/null || { echo "ERRO: jq não encontrado."; exit 1; }

echo "==> port-forward Prometheus ($PROM_NS/$PROM_SVC:$PROM_PORT)..."
kubectl -n "$PROM_NS" port-forward "svc/$PROM_SVC" "$PROM_PORT:9090" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 4

q() {
  # query instantânea; retorna só o valor escalar (ou "NaN")
  curl -sG "http://localhost:${PROM_PORT}/api/v1/query" \
    --data-urlencode "query=$1" \
    | jq -r '.data.result[0].value[1] // "NaN"'
}

printf "\n%-20s %12s %12s %12s %12s\n" "SERVIÇO" "CPU p95" "CPU max" "MEM p95" "MEM max"
printf "%-20s %12s %12s %12s %12s\n" "" "(mCPU)" "(mCPU)" "(Mi)" "(Mi)"
printf '%.0s-' {1..72}; echo

for svc in ngo-service donation-service volunteer-service; do
  # soma dos containers do pod (exclui o pause container), agregada por serviço
  base_cpu="sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\", pod=~\"${svc}-.*\", container!=\"\", container!=\"POD\"}[5m]))"
  base_mem="sum(container_memory_working_set_bytes{namespace=\"$NS\", pod=~\"${svc}-.*\", container!=\"\", container!=\"POD\"})"

  cpu_p95=$(q "quantile_over_time(0.95, ${base_cpu}[${WINDOW}:1m]) * 1000")
  cpu_max=$(q "max_over_time(${base_cpu}[${WINDOW}:1m]) * 1000")
  mem_p95=$(q "quantile_over_time(0.95, ${base_mem}[${WINDOW}:1m]) / 1024 / 1024")
  mem_max=$(q "max_over_time(${base_mem}[${WINDOW}:1m]) / 1024 / 1024")

  printf "%-20s %12.1f %12.1f %12.1f %12.1f\n" "$svc" \
    "${cpu_p95}" "${cpu_max}" "${mem_p95}" "${mem_max}"
done

echo
echo "==> Sugestão de valores (aplique com folga, ver heurística no topo):"
echo "    CPU request  ≈ CPU p95   | Memory request ≈ MEM p95"
echo "    Memory limit ≈ MEM max * 1.2"
echo "==> Confira também o throttling atual pra não sub-dimensionar CPU:"
echo "    rate(container_cpu_cfs_throttled_periods_total{namespace=\"$NS\"}[5m])"
