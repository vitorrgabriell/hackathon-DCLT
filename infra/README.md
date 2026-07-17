# Infraestrutura — SolidaryTech (Terraform + AWS Academy Learner Lab)

Provisiona VPC, EKS, RDS (ngo-service + donation-service), DynamoDB
(volunteer-service), SQS e ECR para os 3 microsserviços. Estrutura modular
espelhada de [tech-challenge-fase-3-fiap](https://github.com/vitorrgabriell/tech-challenge-fase-3-fiap).

## Particularidades do AWS Academy Learner Lab (leia antes de rodar)

- **Sem IAM customizado.** O Learner Lab bloqueia `iam:CreateRole` /
  `CreatePolicy`. Todo recurso que precisa de uma role (cluster EKS, node
  group) reaproveita a `LabRole` já existente na conta — ver `data.tf`.
  Não tente adicionar módulos que criem IAM roles/policies próprias, vai
  dar `AccessDenied`.
- **Sem IRSA.** Como não dá pra criar uma IAM role nova para Service
  Accounts, os pods herdam as permissões da AWS **através do node** (a
  `LabRole` do node group, exposta via IMDS a qualquer pod rodando nele).
  Isso é menos isolado que o ideal (least-privilege por pod não existe
  aqui), mas é a única opção viável no Academy. Nos manifests k8s
  (`../k8s/`), `donation-service` e `volunteer-service` **não** recebem
  `AWS_ACCESS_KEY_ID`/`SECRET` — o SDK resolve as credenciais sozinho via
  IMDS do node.
- **Credenciais temporárias.** O Academy gera `AWS_ACCESS_KEY_ID` +
  `AWS_SECRET_ACCESS_KEY` + `AWS_SESSION_TOKEN` que expiram a cada sessão
  (tipicamente poucas horas). Exporte as 3 variáveis (ou configure um
  profile) antes de `terraform apply`; se a sessão expirar no meio do
  apply, reexporte as credenciais novas e rode `terraform apply` de novo
  (é idempotente).
- **Região fixa `us-east-1`.** É a única região liberada no Learner Lab.
- **Custo do control plane do EKS não depende do "leaner lab".** O EKS
  cobra ~US$0.10/h fixos pelo control plane independente do que você põe
  dentro dele. O resto (NAT único, 2x `t3.medium`, 2x `db.t3.micro`,
  DynamoDB `PAY_PER_REQUEST`) já está dimensionado pra ser o mais barato
  possível — não esqueça de rodar `terraform destroy` quando terminar de
  validar, pra não deixar isso rodando e estourar o crédito do lab.

## Pré-requisitos

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- AWS CLI configurado com as credenciais do AWS Academy
- Um bucket S3 para o remote state (passo 1 abaixo)

## 1. Criar o bucket de remote state

```bash
aws s3api create-bucket \
  --bucket solidarytech-terraform-state-<SEU-SUFIXO-UNICO> \
  --region us-east-1
```

Depois edite `backend.tf` e troque `solidarytech-terraform-state-CHANGE-ME`
pelo nome do bucket que você criou.

## 2. Configurar variáveis

```bash
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars e defina db_password
```

## 3. Inicializar e aplicar

```bash
terraform init
terraform plan
terraform apply
```

A criação completa (VPC → EKS → node group → RDS x2 → addon metrics-server)
leva uns 15-20 minutos, a maior parte esperando o EKS e os node groups
ficarem `ACTIVE`.

## 4. Configurar o kubeconfig

```bash
# o output eks_update_kubeconfig já traz o comando pronto:
terraform output -raw eks_update_kubeconfig | bash
```

## 5. Aplicar o schema nos bancos RDS

O Terraform cria as instâncias RDS vazias — ele não roda migrations. Como o
RDS fica em subnet privada (sem acesso público), rode os scripts
`../ngo-service/db/init.sql` e `../donation-service/db/init.sql` a partir de
dentro do cluster, por exemplo com um pod temporário:

```bash
kubectl run psql-client --rm -it --restart=Never --image=postgres:16-alpine \
  -n solidarytech -- psql "postgres://app:<SENHA>@<ENDPOINT_NGO>/ngo_db" \
  -f /dev/stdin < ../ngo-service/db/init.sql
```

(repita trocando o endpoint/arquivo para `donation_db`)

## 6. Deploy dos manifests k8s

Ver [`../k8s/README.md`](../k8s/README.md) — inclui como ligar os outputs
deste Terraform (`rds_endpoints`, `sqs_queue_url`, `ecr_repository_urls`,
`aws_account_id`) aos Secrets/ConfigMaps/Deployments.

## Automatizando os passos 4-6 (kubeconfig → schema SQL → build/push → gitops → monitoring)

```bash
GITOPS_DIR=../../solidarytech-gitops ./scripts/redeploy-after-apply.sh
```

Idempotente — pode rodar de novo a qualquer momento (ex: depois de recriar tudo com
`terraform apply` numa nova sessão do Learner Lab). Assume Docker, `jq` e AWS CLI já
configurados com credenciais válidas.

## Módulos

| Módulo | Recursos criados |
|---|---|
| `networking` | VPC, 2 subnets públicas, 2 privadas, IGW, 1 NAT Gateway, route tables |
| `eks` | Cluster EKS + Node Group (`t3.medium`) usando LabRole + addon `metrics-server` (necessário pro HPA) |
| `rds` | 2 instâncias PostgreSQL `db.t3.micro` (ngo_db, donation_db) |
| `dynamodb` | Tabela `SolidaryTechVolunteers` (`PAY_PER_REQUEST`, hash key `volunteer_id`) |
| `sqs` | Fila `solidary-donations` |
| `ecr` | 3 repositórios (ngo, donation, volunteer) com `scan_on_push` e lifecycle policy (últimas 10 imagens) |

## Destruir tudo

```bash
terraform destroy
```
