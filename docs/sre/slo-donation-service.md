# SLIs e SLOs — donation-service

O `donation-service` é o **hot path** da plataforma: é ele que recebe a doação,
valida a ONG no `ngo-service`, persiste no PostgreSQL e publica o evento no SQS.
Indisponibilidade ou lentidão aqui significa doação perdida — por isso os SLOs
formais da SolidaryTech são definidos sobre ele.

## De onde vêm os dados

O serviço emite o histograma `http.server.duration` (instrumentação `otelhttp`,
ver [`donation-service/otel.go`](../../donation-service/otel.go)) via OTLP para o
OTel Collector, que o expõe no exporter Prometheus com namespace `solidarytech`.
No Prometheus a métrica chega como:

```
solidarytech_http_server_duration_milliseconds_{bucket,sum,count}
```

com os labels relevantes:

| Label | Valor | Origem |
|---|---|---|
| `job` | `solidarytech/donation-service` | `service.namespace`/`service.name` (exporter do Collector, preservado com `honorLabels: true` no ServiceMonitor) |
| `http_route` | `/donations` | `otelhttp.WithRouteTag` no mux — permite excluir `/health` dos SLIs |
| `http_status_code` | `201`, `400`, `503`, `500`... | otelhttp |
| `instance` | nome do pod | `service.instance.id` injetado via fieldRef no Deployment |

Duas decisões de engenharia importam aqui:

1. **Bucket alinhado ao SLO** — os buckets do histograma foram redefinidos via
   *View* no SDK para incluir a fronteira de **300ms**. Assim o SLI de latência é
   uma contagem exata (`le="300"`), não uma interpolação do
   `histogram_quantile`, que distorce perto das bordas de bucket.
2. **`/health` fora do SLI** — probes de liveness/readiness são requisições
   rápidas e sempre-200 que inflariam artificialmente os dois SLIs. Todos os
   SLIs filtram `http_route="/donations"`.

## SLI 1 — Latência (Golden Metric: Latency)

**Definição:** fração das requisições a `/donations` concluídas em **menos de
300ms**, medida no servidor.

```promql
sum(rate(solidarytech_http_server_duration_milliseconds_bucket{job="solidarytech/donation-service", http_route="/donations", le="300"}[5m]))
/
sum(rate(solidarytech_http_server_duration_milliseconds_count{job="solidarytech/donation-service", http_route="/donations"}[5m]))
```

Recording rule: `donation:sli_latency:ratio_rate5m`.

A p99 (para diagnóstico, não para o SLO — quantis não se agregam nem viram
budget de forma limpa):

```promql
histogram_quantile(0.99, sum by (le) (rate(solidarytech_http_server_duration_milliseconds_bucket{job="solidarytech/donation-service", http_route="/donations"}[5m])))
```

Recording rule: `donation:latency_p99:5m`.

**SLO:** **99.9%** das requisições em < 300ms, janela rolante de **30 dias**.

> O threshold de 300ms cobre o caminho completo: validação síncrona no
> ngo-service (timeout de 3s no client), INSERT no Postgres e publish no SQS.
> Em operação normal a p99 fica bem abaixo disso; o SLO protege contra
> degradação (pool de conexões esgotado, ngo-service lento, throttling do SQS).

## SLI 2 — Disponibilidade / taxa de sucesso (Golden Metric: Errors)

**Definição:** fração das requisições a `/donations` respondidas **sem erro do
servidor (5xx)**. Erros 4xx (payload inválido, `ngo_id` inexistente) são culpa
do cliente e não contam contra o serviço.

```promql
1 - (
  (sum(rate(solidarytech_http_server_duration_milliseconds_count{job="solidarytech/donation-service", http_route="/donations", http_status_code=~"5.."}[5m])) or vector(0))
  /
  sum(rate(solidarytech_http_server_duration_milliseconds_count{job="solidarytech/donation-service", http_route="/donations"}[5m]))
)
```

Recording rule: `donation:sli_availability:ratio_rate5m`. (O `or vector(0)`
cobre o caso feliz de zero 5xx na janela, que senão retornaria vazio.)

Nota: o `503` devolvido quando o ngo-service está inacessível **conta contra o
SLO** de propósito — do ponto de vista do doador, a doação falhou. Isso torna o
SLO do donation-service um guarda-chuva sobre suas dependências síncronas.

**SLO:** **99.9%** de sucesso, janela rolante de **30 dias**.

## Error budget

Com alvo de 99.9% em 30 dias, o error budget é **0.1%** — o equivalente a
**43min12s** de indisponibilidade total, ou 1 requisição ruim a cada 1.000.

**Burn rate** é a velocidade de consumo do budget: burn 1x = consumir
exatamente o budget em 30d; 14.4x = esgotá-lo em ~2 dias.

```promql
# burn rate de disponibilidade na janela de 1h (recording rule donation:slo_availability:burn_rate1h)
(
  (sum(rate(...count{...http_status_code=~"5.."}[1h])) or vector(0))
  /
  sum(rate(...count{...}[1h]))
) / 0.001
```

Recording rules materializam o burn rate nas janelas 5m, 30m, 1h, 2h, 6h e 1d
para os dois SLIs (`donation:slo_{availability,latency}:burn_rate<janela>`), em
[`solidarytech-gitops/monitoring/dashboards/donation-slo-rules.yaml`](https://github.com/vitorrgabriell/solidarytech-gitops/blob/main/monitoring/dashboards/donation-slo-rules.yaml).

### Alertas multi-window / multi-burn-rate (Google SRE Workbook)

Cada alerta exige a janela **longa** (burn sustentado, não um blip) **e** a
**curta** (ainda está acontecendo — não acorda ninguém para incidente já
resolvido):

| Alerta | Condição | Budget esgota em | Ação |
|---|---|---|---|
| `Donation*BurnRateCritical` | burn 1h > 14.4 **e** burn 5m > 14.4 | ~2 dias | **Page** imediato |
| `Donation*BurnRateHigh` | burn 6h > 6 **e** burn 30m > 6 | ~5 dias | **Page** |
| `Donation*BurnRateWarning` | burn 1d > 3 **e** burn 2h > 3 | ~10 dias | Ticket / horário comercial |
| `DonationServiceNoMetrics` | série ausente por 15m | — | Ticket: SLO está cego |

(`*` = `Availability` e `Latency` — 6 alertas de burn + 1 de pipeline.)

## Dashboard SRE

Dashboard dedicado **"SRE — donation-service SLOs"** (uid `donation-slo`),
provisionado via ConfigMap em
[`monitoring/dashboards/donation-slo-dashboard.yaml`](https://github.com/vitorrgabriell/solidarytech-gitops/blob/main/monitoring/dashboards/donation-slo-dashboard.yaml):

- **Linha 1 — o que importa numa olhada:** conformidade dos 2 SLOs na janela do
  dashboard (verde ≥ 99.9%) e gauges de **error budget restante** (negativo =
  SLO violado), mais o tráfego atual.
- **Linha 2 — burn rate:** as janelas 5m/1h/6h de cada SLI com as linhas de
  threshold dos alertas (3 / 6 / 14.4) desenhadas no gráfico — dá pra ver um
  page se aproximando antes de ele disparar.
- **Linha 3 — golden metrics de diagnóstico:** p50/p99 contra a linha de 300ms,
  taxa de 5xx contra a linha de 0.1%, e tráfego por status HTTP.

> **Limitação do lab:** o Prometheus roda com `retention: 3d` (custo do AWS
> Academy), então os painéis de conformidade avaliam a janela do dashboard
> (default 24h), não os 30d formais do SLO. Em produção real bastaria subir a
> retenção (ou usar Thanos/Mimir) — as queries não mudam.
