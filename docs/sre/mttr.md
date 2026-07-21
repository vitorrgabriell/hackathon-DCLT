# Relatório — Redução de MTTR com a stack de observabilidade

## O que compõe o MTTR

MTTR (Mean Time To Repair) não é um número único — é a soma de quatro fases, e
cada peça da stack ataca uma delas:

```
incidente ──▶ detectar ──▶ diagnosticar ──▶ mitigar ──▶ resolver
              (MTTD)       (localizar a      (parar o    (correção
                            causa)            sangramento) definitiva)
```

Sem instrumentação, as duas primeiras fases dominam o MTTR: o incidente é
detectado por reclamação de usuário (minutos a horas depois de começar) e
diagnosticado por SSH + grep em logs espalhados. A stack implementada ataca
exatamente esses gargalos.

## Fase 1 — Detecção (MTTD): alertas por burn rate, não por causa

Os alertas do `donation-service` são **baseados em sintoma** (SLO/burn rate),
não em causa (CPU alta, pod restartando):

- O alerta crítico (`burn 1h > 14.4 e burn 5m > 14.4`) dispara quando o error
  budget está sendo consumido rápido o bastante para esgotar em ~2 dias — na
  prática, **minutos após o início de uma degradação real**, com `for: 2m`.
  O MTTD cai de "quando o usuário reclamar" para **~7 minutos no pior caso**
  (janela de 5m + 2m de confirmação).
- A combinação de janela longa + curta elimina falsos positivos (um blip de 30s
  não sustenta o burn na janela de 1h) e alarmes atrasados (a janela curta
  garante que o problema ainda está ativo). Menos falso positivo = on-call que
  confia no pager = resposta imediata em vez de "deve ser flake".
- Alertas por causa continuam existindo (kube-prometheus-stack: pod
  CrashLooping, node com pressão de memória), mas são **warning/ticket** — só o
  sintoma pageia. Isso evita fadiga de alerta, que é o maior inflador de MTTD
  em times reais.
- `DonationServiceNoMetrics` cobre o meta-caso: se o pipeline de telemetria
  quebrar, o time é avisado de que está voando cego, em vez de descobrir isso
  durante o próximo incidente.

## Fase 2 — Diagnóstico: do alerta à causa em 3 saltos

Aqui é onde a stack integrada (Prometheus + Grafana + Loki + tracing
distribuído) corta o tempo de forma mais agressiva:

1. **Dashboard SRE (`SRE — donation-service SLOs`)** — o link no alerta cai
   direto nele. Em uma tela o on-call responde: *qual SLO está queimando
   (latência ou erro)? desde quando? qual a taxa?* Os thresholds de alerta
   desenhados nos gráficos de burn rate mostram a severidade sem precisar
   lembrar números.
2. **Golden metrics de diagnóstico** — no mesmo dashboard, o tráfego quebrado
   por status HTTP distingue imediatamente os modos de falha típicos:
   - `503` subindo → dependência síncrona (ngo-service) fora ou lenta;
   - `500` subindo → Postgres/SQS ou bug no próprio serviço;
   - p99 estourando com erro estável → saturação (pool de conexões, CPU
     throttling, HPA no teto).
3. **Trace distribuído** — a requisição de doação atravessa os 3 serviços num
   trace só (`donation-service` → HTTP síncrono → `ngo-service`; → SQS com
   contexto propagado → `volunteer-consumer`). Com o span dedicado
   `db.insert_donation` e o `otelhttp.NewTransport` na chamada ao ngo-service,
   o trace **aponta o hop lento/com erro por inspeção**, eliminando a fase de
   "adivinhar qual serviço investigar" — que em arquiteturas distribuídas é
   onde o diagnóstico costuma se perder.
4. **Logs correlacionados (Loki/Promtail)** — confirmada a suspeita no trace, o
   log do pod específico está a um query de distância no mesmo Grafana
   (`{namespace="solidarytech", pod=~"donation-service.*"}`), sem SSH, sem
   procurar em qual node o pod estava.

O fluxo alerta → dashboard → trace → log acontece inteiro dentro do Grafana/
Datadog, em minutos, com contexto preservado em cada salto.

## Fase 3 — Mitigação: auto-healing primeiro, humano depois

Boa parte dos incidentes se resolve **sem humano no loop** — MTTR efetivo de
segundos:

- **Probes de liveness/readiness**: pod travado é reiniciado; pod não-pronto
  sai do endpoint do Service e para de receber tráfego (com 2 réplicas, a
  outra absorve).
- **HPA**: saturação por pico de tráfego escala horizontalmente antes de virar
  violação de SLO.
- **ArgoCD `selfHeal`**: drift manual no cluster é revertido automaticamente
  para o estado declarado no git.

Quando o humano precisa agir, o **GitOps encurta a mitigação**: se o incidente
coincide com um deploy (caso mais comum na indústria), a mitigação é um
`git revert` no repo `solidarytech-gitops` — o ArgoCD converge o cluster de
volta em segundos, sem acesso manual ao kubectl, e o revert fica auditado no
histórico.

## Fase 4 — Resolução e aprendizado

- O **error budget** objetiva a decisão pós-incidente: budget estourado →
  próximo ciclo prioriza confiabilidade (ex.: circuit breaker na chamada ao
  ngo-service) em vez de feature nova. Sem briga de opinião — o número decide.
- As recording rules mantêm o histórico de SLI barato de consultar para o
  postmortem (o que aconteceu com o burn rate nas 6h anteriores ao page?).

## Resumo do impacto

| Fase | Sem a stack | Com a stack |
|---|---|---|
| Detecção | Reclamação de usuário (30min–horas) | Page por burn rate em ~7min |
| Diagnóstico | SSH + grep multi-serviço (horas) | Alerta → dashboard → trace → log (minutos) |
| Mitigação | Intervenção manual no cluster | Auto-healing (s) ou `git revert` + ArgoCD |
| Resolução | Priorização por opinião | Priorização por error budget |

O efeito composto: o MTTR deixa de ser dominado por "descobrir que existe um
problema e onde ele está" e passa a ser dominado pelo tempo de aplicar a
correção — que é a única fase que engenharia nenhuma elimina.
