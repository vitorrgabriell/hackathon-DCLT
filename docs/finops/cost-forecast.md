# Relatório de Forecast de Custo Mensal — SolidaryTech

> **Metodologia.** Inventário levantado por consulta direta à conta AWS
> (`086038954498`, us-east-1) com a infra provisionada e no ar em 2026-07-21 —
> não é estimativa de arquitetura, são os recursos reais. Preços = **on-demand
> list price us-east-1**, mês de **730h**. AWS Academy Learner Lab não fatura de
> verdade (crédito educacional); os valores abaixo são o que **esta mesma
> arquitetura custaria numa conta paga**, que é o objetivo do forecast.

## 1. Inventário provisionado (real)

| Recurso | Qtd | Spec | Origem no Terraform |
|---|---|---|---|
| EKS control plane | 1 | k8s 1.31 | `modules/eks` |
| EC2 worker nodes | 3 | t3.medium (2 vCPU / 4 GiB), on-demand | `modules/eks` (`eks_node_desired=3`) |
| EBS (root dos nodes) | 3 | 20 GB gp3 cada (60 GB) | AMI EKS default |
| NAT Gateway | 1 | single-NAT (não 1/AZ) | `modules/networking` |
| RDS PostgreSQL | 2 | db.t3.micro, single-AZ, 20 GB gp2 cada | `modules/rds` |
| DynamoDB | 1 | `SolidaryTechVolunteers`, **PAY_PER_REQUEST** | `modules/dynamodb` |
| SQS | 1 | Standard queue | `modules/sqs` |
| ECR | 3 | imagens: Go 21 MB, ngo 136 MB, volunteer 99 MB | `modules/ecr` |
| ELB/ALB | 0 | services são ClusterIP (acesso via port-forward) | — |

## 2. Forecast mensal

### Custo fixo (independe de tráfego)

| Item | Cálculo | Mensal (US$) |
|---|---|---:|
| EKS control plane | 1 × $0,10/h × 730 | **73,00** |
| EC2 3× t3.medium (on-demand) | 3 × $0,0416/h × 730 | **91,10** |
| EBS gp3 (60 GB) | 60 × $0,08/GB | 4,80 |
| NAT Gateway (horas) | $0,045/h × 730 | **32,85** |
| RDS 2× db.t3.micro | 2 × $0,018/h × 730 | **26,28** |
| RDS storage gp2 (40 GB) | 40 × $0,115/GB | 4,60 |
| **Subtotal fixo** | | **232,63** |

### Custo variável (tráfego leve — estimado)

| Item | Cálculo | Mensal (US$) |
|---|---|---:|
| NAT data processing | ~5 GB × $0,045 | 0,23 |
| DynamoDB on-demand | ~poucos milhares de req | ~0,30 |
| SQS | dentro do free tier (1M req) | ~0,00 |
| ECR storage | ~0,26 GB × $0,10 | 0,03 |
| Data transfer out | ~10 GB × $0,09 | ~0,90 |
| **Subtotal variável** | | **~1,46** |

### 🧾 Total estimado: **≈ US$ 234 / mês**

## 3. Maiores drivers de custo

```
EC2 nodes (3× t3.medium)  ████████████████████  $91,10   39%
EKS control plane         ███████████████        $73,00   31%
NAT Gateway               ███████                $33,08   14%
RDS (2 instâncias+storage)███████                $30,88   13%
Resto (EBS/Dynamo/ECR/DT) ██                      $ 6,32    3%
```

Dois terços do custo são **EC2 + EKS control plane**. O control plane ($73) é
uma taxa fixa por cluster — sem alavanca a não ser rodar menos clusters. Logo,
**a maior alavanca real é o custo dos worker nodes** — que é justamente onde as
otimizações abaixo atacam.

## 4. Impacto do rightsizing (já aplicado)

Requests/limits foram ajustados com base no consumo real medido no Prometheus
(ver [`scripts/rightsizing-metrics.sh`](../../scripts/rightsizing-metrics.sh) e
o commit de rightsizing no gitops). Efeito na **reserva de CPU** do cluster:

| | CPU requests somados | Memória limits somados |
|---|---:|---:|
| Antes | 650m | 1408 Mi |
| Depois | 350m (**-46%**) | 1024 Mi (**-27%**) |

Isso **não muda a fatura sozinho** (nodes já estão pagos por hora), mas melhora
o bin-packing: a reserva agregada de CPU dos apps caiu para ~350m contra ~6000m
alocáveis nos 3 nodes. Isso **habilita** as otimizações de node abaixo — em
especial rodar menos/mais-baratos nodes sem apertar os pods.

> Nota de honestidade: o tráfego de teste foi leve (41 requisições, depois
> idle), então o **CPU** medido reflete estado quase-idle — por isso o request
> de CPU foi reduzido só a 50m (não ao idle de 1-7m), preservando headroom de
> burst. A **memória** (working set) é medida confiável idle ou sob carga, e é
> onde o corte foi feito com convicção.

## 5. Recomendações de otimização nativa de nuvem

### ⭐ Principal — Spot Instances nos worker nodes

Os 3 t3.medium on-demand ($91,10/mês) são o maior item controlável. Trocar o
node group por **Spot** custa, em us-east-1, ~$0,0135/h (≈ **68% de desconto**):

| | On-demand | Spot |
|---|---:|---:|
| 3× t3.medium/mês | $91,10 | **$29,57** |
| **Economia** | | **~$61,53/mês (-68%)** |

**Por que essa arquitetura é candidata natural a Spot:** os 3 serviços são
*stateless* — todo estado vive em RDS/DynamoDB/SQS. Já há **HPA + 2 réplicas**
por serviço, e a instrução de doação é idempotente do ponto de vista de fila.
Uma interrupção de Spot só reagenda pods; nenhum dado se perde.
**Mitigação recomendada:** node group Spot com *diversificação* de tipos
(`t3.medium`, `t3a.medium`, `t2.medium`) para reduzir a chance de interrupção
simultânea, `PodDisruptionBudget` de `minAvailable: 1` por serviço, e opção de
manter **1 node on-demand + 2 Spot** (mixed) se quiser um piso garantido —
nesse caso a economia cai para ~$41/mês, ainda relevante.

### Alternativa de menor risco — Compute Savings Plan

Se interrupção de Spot for indesejada, um **Compute Savings Plan de 1 ano
(no upfront)** dá ~27% off no EC2 sem risco de interrupção:
$91,10 → ~$66,50 = **~$24,60/mês** de economia. Cobre EC2/Fargate/Lambda (não
cobre a taxa do EKS control plane). Trade-off: compromisso de 1 ano.

### Alavancas adicionais (combináveis)

- **Graviton (ARM):** `t4g.medium` é ~19% mais barato que `t3.medium` e melhor
  preço/desempenho. Exige imagens multi-arch (o serviço Go compila para ARM
  trivialmente; os Python idem). **Spot + Graviton** empurra o custo dos nodes
  para ~$24/mês.
- **VPC Gateway Endpoints (S3 e DynamoDB):** são **gratuitos** e tiram o
  tráfego pra esses serviços do NAT Gateway (reduz o data processing de $0,045/GB).
- **Consolidar RDS:** as 2 instâncias db.t3.micro poderiam virar 1 com 2
  bancos (schemas), economizando ~$13/mês — porém a separação por serviço é
  intencional (isolamento de blast radius). Alternativa sem abrir mão disso:
  **RDS Reserved Instances 1 ano** (~34% off, ~$9/mês) ou migrar para
  `db.t4g.micro` (Graviton, ~10% mais barato).
- **Redução de nodes 3→2:** o rightsizing liberou reserva suficiente, mas
  atenção: os 3 nodes foram dimensionados para não bater o teto de ~17 pods/node
  do t3.medium (limite de ENI/IP, não CPU) — com os DaemonSets de monitoring,
  cair para 2 nodes pode reencostar nesse teto. Recomendado só se validado com
  `kubectl get pods -A -o wide` por node.

## 6. Cenário otimizado

Aplicando **apenas a recomendação principal (Spot nos 3 nodes)**, mantendo todo
o resto:

| | Atual | Com Spot |
|---|---:|---:|
| Total mensal | **~$234** | **~$172** |
| Redução | | **~26%** |

Somando Graviton + Gateway Endpoints + RDS Graviton, o total realista chega
próximo de **~$150/mês** (-36%) sem perda de disponibilidade relevante para a
carga atual.

## 7. Ressalvas

- Preços são **list price on-demand us-east-1** na data do relatório; descontos
  por volume, Free Tier de conta nova e créditos não estão considerados.
- Custo variável (data transfer, DynamoDB, SQS) é estimado para tráfego de
  hackathon; sob carga de produção real, DynamoDB on-demand e data transfer
  escalam linearmente com o volume — reavaliar com dados reais de produção.
- Números conferem com uma estimativa independente no **AWS Pricing
  Calculator** / **Infracost** (`infracost breakdown --path infra/`) — os itens
  fixos (EKS, EC2, NAT, RDS) são determinísticos e batem com esta tabela.
