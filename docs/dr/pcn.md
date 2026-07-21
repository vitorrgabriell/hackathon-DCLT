# Plano de Continuidade de Negócios (PCN) — SolidaryTech

**Documento executivo · Versão 1.0 · 2026-07-21**
Responsável técnico: Plataforma/SRE · Classificação: Interno

---

## 1. Sumário executivo

A SolidaryTech intermedeia **doações financeiras** de doadores para ONGs
parceiras. O ativo mais crítico da plataforma é o **registro de doações** — cada
linha na base representa dinheiro efetivamente doado. Perder esse dado significa
perda financeira direta, quebra de confiança do doador e impossibilidade de
prestar contas às ONGs.

Este plano define os objetivos de recuperação (**RTO** e **RPO**) para os dados
de doação, a estratégia de Disaster Recovery (DR) que os sustenta, e comprova —
com evidências reais coletadas no ambiente — que a estratégia funciona.

O `donation-service` é o **hot path** e recebe o maior rigor de continuidade.

---

## 2. Objetivos de recuperação

| Camada | Ativo | **RPO** (perda máx. de dados) | **RTO** (tempo máx. de indisponibilidade) |
|---|---|---|---|
| **Dados** | Doações (RDS PostgreSQL) | **5 minutos** | **1 hora** |
| **Aplicação** | Estado do cluster K8s (manifestos/config) | **0** (efetivo) | **30 minutos** |

### 2.1 Justificativa técnica do RPO de 5 min (dados de doação)

- Uma doação é uma **transação financeira**. O RPO responde: "quanto de doação
  podemos aceitar perder num desastre?" A resposta de negócio é: **o mínimo
  tecnicamente viável sem custo proibitivo**.
- O mecanismo que entrega isso é o **Point-In-Time Recovery (PITR)** do RDS:
  com backups automáticos habilitados (`backup_retention_period = 7` dias), o
  RDS **arquiva os transaction logs (WAL) continuamente** no S3 gerenciado.
  Isso permite restaurar o banco para **qualquer instante** dentro da janela de
  retenção, com granularidade de ~5 minutos (`LatestRestorableTime` avança
  continuamente).
- **Por que não RPO = 0?** RPO zero exigiria replicação síncrona (ex.: Multi-AZ
  com commit síncrono ou réplica de leitura síncrona), que ~dobra o custo do
  RDS. Para o volume atual da SolidaryTech, o custo não se justifica; 5 minutos
  de exposição é um risco aceito conscientemente pelo negócio.
- **Descoberta relevante (corrigida por este plano):** a auditoria de DR
  encontrou o RDS com `backup_retention_period = 0` — ou seja, **sem backup
  nenhum, RPO efetivamente infinito**. A correção (habilitar retenção de 7 dias
  via Terraform) é o item de maior valor deste PCN. Ver evidência em
  [`dr-drill-evidence.md`](dr-drill-evidence.md).

### 2.2 Justificativa técnica do RTO de 1h (dados de doação)

- O RTO soma: detecção do incidente + decisão de failover + tempo de restauração
  do RDS + reconexão da aplicação.
- Restaurar um snapshot ou fazer PITR de um `db.t3.micro` de 20 GB leva
  tipicamente **15–30 min** (provisão de nova instância + replay de logs).
- A detecção é rápida por causa da stack de observabilidade: os alertas de
  burn rate do SLO de disponibilidade (ver [`../sre/mttr.md`](../sre/mttr.md))
  disparam em **~7 min**. A aplicação (stateless) reconecta assim que o endpoint
  novo sobe.
- Folga deliberada dentro de 1h para a decisão humana de failover (restaurar é
  irreversível quanto ao ponto no tempo escolhido — exige julgamento).

### 2.3 Justificativa do RPO efetivo 0 / RTO 30min (camada de aplicação)

- Os 3 microsserviços são **stateless** — não há PVCs no cluster (todo estado
  durável vive em RDS/DynamoDB/SQS). Confirmado: `kubectl get pvc -A` → vazio.
- Os manifestos são **versionados em Git** e aplicados por **ArgoCD**
  (`selfHeal`). Logo, o estado desejado do cluster é reconstruível a partir do
  Git a qualquer momento → RPO efetivo **0** para a camada de config.
- O **Velero** adiciona uma camada de backup point-in-time do estado *vivo* do
  cluster (inclusive objetos criados fora do Git, como Secrets renderizados) num
  bucket S3 **externo ao cluster** — sobrevive à perda total do EKS e permite
  restaurar num cluster novo. O drill mediu restauração completa da namespace em
  **~1 min** (35 objetos), pods prontos em ~30s.

---

## 3. Estratégia de DR — arquitetura em duas camadas

```
┌─────────────────────────────────────────────────────────────┐
│ CAMADA DE DADOS (crítica)          CAMADA DE APLICAÇÃO       │
│                                                               │
│  RDS PostgreSQL (donation_db)       Estado do cluster K8s     │
│    ├─ Backups automáticos (PITR)      ├─ Git + ArgoCD         │
│    │    retenção 7d, RPO ~5min        │    (fonte de verdade) │
│    └─ Snapshots manuais                └─ Velero → S3 externo  │
│         (marcos/pré-mudança)               (backup 6/6h,      │
│                                             TTL 7d)           │
│                                                               │
│  DynamoDB: PITR nativo (on-demand)                            │
│  SQS: mensagens efêmeras (idempotência no consumer)           │
└─────────────────────────────────────────────────────────────┘
                          │
                   Bucket S3 de DR
            solidarytech-velero-backups-*
        (versionado, criptografado, lifecycle 30d)
```

- **Dados de doação → RDS PITR + snapshots.** Backups automáticos dão o RPO de
  5 min; snapshots manuais marcam pontos de recuperação antes de mudanças de
  risco (deploy de schema, migração).
- **Estado do cluster → Git/ArgoCD (primário) + Velero (secundário).** Provisão
  do cluster via `terraform apply` + `redeploy-after-apply.sh` reconstrói tudo;
  Velero acelera e cobre o que não está no Git.
- **Bucket S3 externo ao cluster** (Terraform `modules/backup`): versionamento
  (anti-corrupção), criptografia SSE, e lifecycle de 30d (FinOps).

---

## 4. Cenários de desastre e resposta

| Cenário | Camada afetada | Resposta | RTO esperado |
|---|---|---|---|
| Corrupção/exclusão lógica de doações | Dados | PITR do RDS para instante anterior ao incidente | < 1h |
| Perda de instância RDS | Dados | Restore do último snapshot automático / PITR | < 1h |
| Exclusão acidental de recursos no namespace | Aplicação | `velero restore` ou re-sync do ArgoCD | < 30min |
| Perda total do cluster EKS | Aplicação | `terraform apply` novo cluster + `velero restore` | < 1h |
| Perda de uma AZ | Infra | RDS single-AZ recria em AZ sadia (aceito: janela); nodes reagendados pelo ASG | < 1h |

> **Limite conhecido (risco aceito):** o RDS é **single-AZ** e há **1 NAT
> Gateway** (decisão de FinOps do lab). Uma falha de AZ inteira gera uma janela
> de indisponibilidade até o RDS ser recriado. Em produção, a recomendação é
> Multi-AZ (RPO/RTO de AZ ~0) — trade-off de custo documentado em
> [`../finops/cost-forecast.md`](../finops/cost-forecast.md).

---

## 5. Ativação e papéis

1. **Detecção:** alertas de SLO (burn rate) no Alertmanager + dashboards Grafana
   de SRE. On-call recebe o page.
2. **Classificação:** on-call determina a camada afetada (dados vs aplicação) e
   consulta a tabela da seção 4.
3. **Decisão de failover de dados:** restauração de RDS é decisão do responsável
   técnico de plantão (escolha do ponto-no-tempo é irreversível).
4. **Execução:** runbooks operacionais em [`dr-drill-evidence.md`](dr-drill-evidence.md)
   (comandos reais já validados).
5. **Comunicação:** status para ONGs afetadas; pós-incidente com base no error
   budget consumido.

---

## 6. Testes de continuidade (drills)

- **Cadência:** trimestral, ou a cada mudança estrutural de infra.
- **Escopo mínimo do drill:** (a) `velero backup` + `velero restore` num
  namespace mapeado, verificando pods funcionais; (b) validação de que
  `LatestRestorableTime` do RDS avança (PITR ativo); (c) criação de snapshot
  manual.
- **Último drill:** 2026-07-21 — **PASSOU**. Evidências completas (comandos +
  saídas reais) em [`dr-drill-evidence.md`](dr-drill-evidence.md).

---

## 7. Manutenção do plano

Revisão semestral ou a cada mudança relevante de arquitetura. Toda a estratégia
é **Infrastructure as Code**: retenção de backup do RDS em `modules/rds`, bucket
de DR em `modules/backup`, instalação do Velero e Schedules versionadas —
nenhuma etapa depende de ação manual não-documentada.
