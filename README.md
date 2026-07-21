# 🚀 SolidaryTech — Hackathon Fase 5

Bem-vindo ao repositório oficial da **SolidaryTech**.

Este monorepo contém os microsserviços que compõem a plataforma da ONG e servirá como base para os desafios do Hackathon Fase 5.

O objetivo principal deste projeto é aplicar conceitos modernos de:

- SRE (Site Reliability Engineering)
- FinOps
- Multicloud
- ITSM
- Observabilidade
- Resiliência
- Kubernetes & GitOps
- Infraestrutura como Código (IaC)

---

# 🏗️ Arquitetura dos Microsserviços

O ecossistema é composto por **3 microsserviços independentes**, desenvolvidos com tecnologias diferentes para simular um ambiente corporativo distribuído.

---

## 1️⃣ NGO Service — Cadastro de ONGs

| Item | Valor |
|---|---|
| Linguagem | Python 3.9+ |
| Framework | Flask |
| Banco de Dados | PostgreSQL |
| Porta Local | `8081` |

### 📌 Descrição
Responsável pelo gerenciamento e cadastro das ONGs parceiras da plataforma.

---

## 2️⃣ Donation Service — Processamento de Doações

| Item | Valor |
|---|---|
| Linguagem | Go 1.21+ |
| Banco de Dados | PostgreSQL |
| Mensageria | AWS SQS |
| Porta Local | `8082` |

### 📌 Descrição
Este é o **Hot Path** da aplicação.

Responsável pelo processamento das doações e publicação de eventos assíncronos em filas para processamento posterior.

---

## 3️⃣ Volunteer Service — Gestão de Voluntários

| Item | Valor |
|---|---|
| Linguagem | Python 3.9+ |
| Framework | Flask |
| Banco de Dados | AWS DynamoDB |
| Porta Local | `8083` |

### 📌 Descrição
Gerencia o cadastro e inscrição de voluntários interessados em apoiar as ONGs parceiras.

Utiliza armazenamento NoSQL nativo da AWS com foco em escalabilidade.

---

# 📁 Estrutura do Repositório

```text
.
├── ngo-service/          # Código Python e scripts SQL do serviço de ONGs
├── donation-service/     # Código Go e scripts SQL do serviço de doações
└── volunteer-service/    # Código Python do serviço de voluntários
```

---

# 🚀 Executando Localmente

Antes de realizar deploy em Kubernetes e automatizações CI/CD, recomenda-se validar todo o ambiente localmente.

---

# ✅ Pré-requisitos

Certifique-se de possuir os seguintes itens instalados:

- Python 3.9+
- Go 1.21+
- Docker (opcional, mas recomendado)
- PostgreSQL
- AWS CLI configurado
- Credenciais AWS válidas

---

# 🛠️ Passo 1 — Preparação da Infraestrutura

## PostgreSQL

Crie dois bancos de dados independentes:

### Banco `ngo_db`

Execute:

```sql
ngo-service/db/init.sql
```

### Banco `donation_db`

Execute:

```sql
donation-service/db/init.sql
```

---

## AWS DynamoDB

Crie a tabela:

| Configuração | Valor |
|---|---|
| Nome da Tabela | `SolidaryTechVolunteers` |
| Partition Key | `volunteer_id` |
| Tipo | `String` |

---

## AWS SQS

Crie uma fila do tipo **Standard Queue**.

Exemplo:

```text
https://sqs.us-east-1.amazonaws.com/1234567890/solidary-donations
```

Guarde a URL da fila para utilizar nas variáveis de ambiente.

---

# ⚙️ Passo 2 — Variáveis de Ambiente

Crie um arquivo `.env` dentro de cada microsserviço.

---

## 📄 ngo-service/.env

```env
PORT=8081
DATABASE_URL="postgres://SEU_USUARIO:SUA_SENHA@localhost:5432/ngo_db"
```

---

## 📄 donation-service/.env

```env
PORT=8082
DATABASE_URL="postgres://SEU_USUARIO:SUA_SENHA@localhost:5432/donation_db"

AWS_REGION="us-east-1"
AWS_SQS_URL="SUA_URL_DA_FILA_SQS"
```

---

## 📄 volunteer-service/.env

```env
PORT=8083

AWS_REGION="us-east-1"
AWS_DYNAMODB_TABLE="SolidaryTechVolunteers"
```

---

# ▶️ Passo 3 — Inicializando os Serviços

Abra **3 terminais separados**.

---

## 🟣 Terminal 1 — NGO Service

```bash
cd ngo-service

pip install -r requirements.txt

gunicorn --bind 0.0.0.0:8081 app:app
```

---

## 🟠 Terminal 2 — Donation Service

```bash
cd donation-service

go mod tidy

go run .
```

---

## 🔵 Terminal 3 — Volunteer Service

```bash
cd volunteer-service

pip install -r requirements.txt

gunicorn --bind 0.0.0.0:8083 app:app
```

---

# 🌐 Portas Locais

| Serviço | URL |
|---|---|
| NGO Service | http://localhost:8081 |
| Donation Service | http://localhost:8082 |
| Volunteer Service | http://localhost:8083 |

---

# 🎯 Objetivos do Hackathon

O código fornecido representa apenas a base do software.

O verdadeiro desafio está na engenharia, operação e resiliência da plataforma.

---

# 📦 Conteinerização

- Criar Dockerfiles
- Otimizar imagens
- Implementar estratégias multi-stage build
- Reduzir vulnerabilidades

---

# ☁️ Infraestrutura como Código (Terraform)

Provisionar:

- Amazon EKS
- Amazon RDS
- Amazon ElastiCache
- Amazon SQS
- Amazon DynamoDB
- VPC, Subnets e Security Groups

## 💰 FinOps

Implementar:

- Tags estruturadas
- Controle de custos
- Rightsizing
- Budgets e alertas financeiros

### Implementado

- **Política de tags obrigatória** via `default_tags` no provider AWS
  ([`infra/backend.tf`](infra/backend.tf)): `Project=SolidaryTech`,
  `Environment=Production`, `CostCenter=NGO-Core` em todos os recursos.
- **Rightsizing baseado em uso real** — requests/limits dos 3 serviços
  ajustados a partir do working set/CPU medidos no Prometheus
  ([`scripts/rightsizing-metrics.sh`](scripts/rightsizing-metrics.sh) coleta os
  percentis; reserva de CPU do cluster caiu ~46%).
- **Forecast de custo mensal + otimização** (Spot como recomendação principal,
  ~26% de economia): [`docs/finops/cost-forecast.md`](docs/finops/cost-forecast.md).

---

# 🔄 CI/CD & GitOps

Automatizar:

- Testes
- Security Scans
- Build de imagens
- Deploy em Kubernetes

Ferramentas sugeridas:

- GitHub Actions
- ArgoCD
- FluxCD

## Implementado: pipelines GitHub Actions

Um workflow reutilizável (`.github/workflows/ci-reusable.yml`) chamado por um
wrapper fino por serviço (`ci-ngo.yml`, `ci-donation.yml`,
`ci-volunteer.yml`), cada um disparado só quando o path daquele serviço muda.
Cada pipeline roda, nessa ordem: **testes** → **Sonar (SAST de código)** em
paralelo → **build da imagem Docker** → **Trivy (scan da imagem)** → **push
no ECR** → **update-gitops** (só em push na `main`; PRs param no scan). O
pipeline **falha** se o Trivy achar vulnerabilidade `CRITICAL` ou `HIGH` — a
imagem não chega a ser publicada nesse caso, e o `update-gitops` nem roda.

### Secrets necessários (Settings → Secrets and variables → Actions)

| Secret | Descrição |
|---|---|
| `AWS_ACCESS_KEY_ID` | Credencial AWS Academy |
| `AWS_SECRET_ACCESS_KEY` | Credencial AWS Academy |
| `AWS_SESSION_TOKEN` | Token de sessão AWS Academy — **expira em poucas horas**; se o job `build-and-push` começar a falhar com erro de autenticação, é isso, reexporte as 3 credenciais novas |
| `SONAR_TOKEN` | Token de autenticação no SonarCloud/SonarQube |
| `SONAR_HOST_URL` | Só necessário se usar SonarQube self-hosted (SonarCloud não precisa) |
| `SONAR_ORGANIZATION` | Só usado pelo SonarCloud |
| `GITOPS_TOKEN` | PAT do GitHub (escopo `repo`) com push no repo `solidarytech-gitops` |

### GitOps — ArgoCD

O último job do pipeline (`update-gitops`) atualiza a tag da imagem em
[`solidarytech-gitops`](https://github.com/vitorrgabriell/solidarytech-gitops)
(`apps/<service>/deployment.yaml`) e dá push. O ArgoCD, rodando no cluster
EKS com `syncPolicy.automated` (`prune` + `selfHeal`), detecta o commit e
aplica sozinho — fluxo completo (diagrama, estrutura, bootstrap) documentado
no README daquele repo. **A partir daqui, [`k8s/`](k8s/) neste repo deixou de
ser a fonte de verdade do cluster** — fica só como referência/ponto de
partida (ver aviso no topo de [`k8s/README.md`](k8s/README.md)).

---

# 📊 Observabilidade

Instrumentar os serviços utilizando:

- OpenTelemetry
- Distributed Tracing
- Métricas
- Logs estruturados

Ferramentas sugeridas:

- Grafana
- Prometheus
- Datadog
- New Relic

## Implementado

Mesma arquitetura da Fase 4 (`togglemaster`): OTel Collector como hub
central (`memory_limiter` + `batch` + `resource` processors), métricas via
kube-prometheus-stack, logs via loki-stack (Loki + Promtail), APM
**Datadog**. Stack completa (Helm charts via ArgoCD Application, conta de
capacidade do cluster leaner lab) documentada em
[`solidarytech-gitops/monitoring/README.md`](https://github.com/vitorrgabriell/solidarytech-gitops/blob/main/monitoring/README.md).

- **ngo-service** e **volunteer-service**: auto-instrumentados
  (`opentelemetry-distro` + `opentelemetry-instrument`, sem código manual —
  ver Dockerfiles).
- **donation-service** (hot path): instrumentação manual —
  `otelhttp.NewHandler` no handler HTTP, span dedicado
  (`db.insert_donation`) em volta do insert no Postgres, e
  `otelhttp.NewTransport` na chamada ao ngo-service.

**Uma requisição de doação atravessa os 3 serviços num trace só:**
`donation-service` valida o `ngo_id` chamando `GET /ngos/{id}` no
`ngo-service` (hop síncrono, trace propagado via header HTTP `traceparent`)
e publica um evento no SQS com o trace context injetado como *message
attributes*; o `volunteer-consumer` (processo novo, mesma imagem do
`volunteer-service`) extrai esse contexto e abre um span
`process_donation_event` como filho do mesmo trace — ver o passo a passo
completo em
[`monitoring/README.md`](https://github.com/vitorrgabriell/solidarytech-gitops/blob/main/monitoring/README.md#como-o-trace-atravessa-os-3-serviços).

Localmente (`docker-compose.yml`), o Jaeger substitui o Datadog como
backend de visualização de traces — não precisa de API key pra validar a
propagação de ponta a ponta na sua máquina.

---

# 🛡️ SRE & Resiliência

Definir:

- SLIs
- SLOs
- Error Budgets
- Estratégias de Disaster Recovery
- Alertas inteligentes
- Health Checks
- Auto Healing

## 🔥 Foco Principal

O `donation-service` deve ser tratado como componente crítico da plataforma.

## Implementado

- **SLIs/SLOs do donation-service** (hot path): 2 SLIs sobre as Golden Metrics
  — latência (99.9% < 300ms) e disponibilidade (99.9% sem 5xx), janela de 30d,
  error budget de 0.1% (43m12s). Definições, queries PromQL e racional em
  [`docs/sre/slo-donation-service.md`](docs/sre/slo-donation-service.md).
- **Recording rules + alertas multi-window/multi-burn-rate** (padrão Google
  SRE Workbook) e **dashboard Grafana dedicado a SRE** (`SRE — donation-service
  SLOs`: conformidade dos SLOs, error budget restante e burn rate) —
  provisionados via GitOps em
  [`solidarytech-gitops/monitoring/dashboards/`](https://github.com/vitorrgabriell/solidarytech-gitops/tree/main/monitoring/dashboards).
- **MTTR**: como a stack de observabilidade + alertas reduz detecção/resposta a
  incidentes — [`docs/sre/mttr.md`](docs/sre/mttr.md).
- **Plano de Continuidade de Negócios (PCN) + DR**: RTO/RPO dos dados de doação
  (RPO 5min via PITR do RDS, RTO 1h) com justificativa técnica
  ([`docs/dr/pcn.md`](docs/dr/pcn.md)) e a estratégia de DR implementada —
  **Velero → S3** pro estado do cluster ([`scripts/install-velero.sh`](scripts/install-velero.sh))
  + backups automáticos/PITR do RDS ([`infra/modules/rds`](infra/modules/rds) e
  [`infra/modules/backup`](infra/modules/backup)). Evidências reais do drill
  (backup, restore funcional, PITR) em
  [`docs/dr/dr-drill-evidence.md`](docs/dr/dr-drill-evidence.md).

---

# 📚 Tecnologias Envolvidas

- Python
- Flask
- Go
- PostgreSQL
- DynamoDB
- AWS SQS
- Docker
- Kubernetes
- Terraform
- GitOps
- OpenTelemetry

---

# 🤝 Contribuição

Este projeto foi criado exclusivamente para fins educacionais e execução do Hackathon Fase 5.

Sinta-se livre para evoluir a arquitetura, melhorar a observabilidade e implementar boas práticas de engenharia de plataforma.

---

# 🏁 Boa sorte!

Bom Hackathon 🚀

Faça a diferença com a **SolidaryTech** 💙