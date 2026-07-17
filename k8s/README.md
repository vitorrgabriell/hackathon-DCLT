# Manifests Kubernetes — SolidaryTech

> **Desde a configuração do GitOps, esta pasta não é mais a fonte de
> verdade do cluster.** O deploy contínuo (pipeline → ECR → ArgoCD) usa o
> repo separado
> [`solidarytech-gitops`](https://github.com/vitorrgabriell/solidarytech-gitops),
> sincronizado automaticamente pelo ArgoCD — é lá que se edita o que
> realmente está rodando em produção. Estes YAMLs aqui continuam servindo
> como referência/ponto de partida (foi daqui que os manifests do
> `solidarytech-gitops` nasceram) e para quem quiser aplicar manualmente
> num cluster sem ArgoCD, mas os dois podem divergir com o tempo se só um
> lado for atualizado — trate o `solidarytech-gitops` como autoritativo.

Deployment, Service, ConfigMap, Secret e HPA para os 3 microsserviços,
pensados para rodar no cluster EKS provisionado em [`../infra`](../infra).

## Antes de aplicar

Estes YAMLs têm placeholders que precisam ser preenchidos com valores reais
do Terraform — **não dê `kubectl apply -f` na pasta inteira sem passar por
aqui antes**:

| Placeholder | Onde | Como preencher |
|---|---|---|
| `<AWS_ACCOUNT_ID>` | `*/deployment.yaml` (campo `image`) | `terraform output -raw aws_account_id` (em `infra/`) |
| `DATABASE_URL` (`CHANGE-ME`) | `ngo-service/secret.yaml`, `donation-service/secret.yaml` | `terraform output -json rds_endpoints` + a senha do `terraform.tfvars` |
| `AWS_SQS_URL` (`CHANGE-ME`) | `donation-service/configmap.yaml` | `terraform output -raw sqs_queue_url` |

O script [`render-secrets.sh`](render-secrets.sh) automatiza os dois últimos
itens direto a partir do state do Terraform (sem nunca escrever a senha em
disco):

```bash
export TF_VAR_db_password="a-mesma-senha-do-terraform.tfvars"
./k8s/render-secrets.sh
```

Para o `<AWS_ACCOUNT_ID>` no `image:` de cada Deployment, ainda não há
templating automático (são YAMLs simples, não Helm/Kustomize) — troque à
mão ou com `sed`:

```bash
ACCOUNT_ID=$(cd infra && terraform output -raw aws_account_id)
sed -i "s/<AWS_ACCOUNT_ID>/${ACCOUNT_ID}/" k8s/*/deployment.yaml
```

## Aplicando

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/ngo-service/
kubectl apply -f k8s/donation-service/
kubectl apply -f k8s/volunteer-service/
```

(a ordem importa pouco, exceto o `namespace.yaml` que precisa vir primeiro —
o `render-secrets.sh` já cuida disso.)

## Decisões de design

- **`volunteer-service` não tem Secret.** Não há senha de banco (usa
  DynamoDB) nem chave de API própria no código atual — as credenciais AWS
  vêm do node (ver nota de segurança abaixo). Se um dia o serviço passar a
  precisar de algum segredo de verdade, crie o Secret ali seguindo o mesmo
  padrão dos outros dois.
- **Sem `AWS_ACCESS_KEY_ID`/`SECRET` em nenhum manifest.** No AWS Academy
  não é possível criar uma IAM role dedicada por Service Account (IRSA),
  então os pods herdam a `LabRole` anexada ao node via IMDS — é assim que
  `donation-service` fala com o SQS e `volunteer-service` com o DynamoDB em
  produção. **Isso é uma concessão ao Academy, não best practice:** qualquer
  pod rodando no node consegue as mesmas permissões amplas da `LabRole`,
  não só o serviço que precisa delas. Fora do Academy (conta AWS normal),
  troque isso por IRSA com uma role por serviço.
  As variáveis `AWS_SQS_ENDPOINT`/`AWS_DYNAMODB_ENDPOINT` que existem no
  `docker-compose.yml` local (pra apontar pro LocalStack) foram deixadas de
  fora de propósito destes manifests — sem elas, o SDK resolve o endpoint
  real da AWS.
- **`readOnlyRootFilesystem: true` + `runAsNonRoot`.** Os 3 Dockerfiles já
  rodam como usuário não-root; os manifests reforçam isso e travam o
  filesystem raiz. `ngo-service`/`volunteer-service` ganham um `emptyDir`
  em `/tmp` como válvula de escape (Flask/gunicorn podem querer escrever
  ali); `donation-service` (binário Go estático) não precisa.
- **HPA do `donation-service` mais agressivo** (`maxReplicas: 6`,
  `target: 60%` vs. `4`/`70%` dos outros dois): o README raiz trata esse
  serviço como o *hot path* crítico da plataforma.
- **Requests/limits são chute inicial**, não medição real — combinado no
  pedido original ("ajustar rightsizing depois com dados reais"). Depois de
  rodar com tráfego de verdade, olhe `kubectl top pods` / métricas do
  `metrics-server` e ajuste.

## Pré-requisito: `metrics-server`

O HPA depende do `metrics-server` pra ler CPU dos pods. Ele é instalado
automaticamente pelo Terraform como addon do EKS (`aws_eks_addon.metrics_server`
em `infra/modules/eks/main.tf`). Se você aplicar esses manifests num cluster
que não passou por esse Terraform, instale-o manualmente antes, senão o HPA
fica com `<unknown>` nas métricas.
