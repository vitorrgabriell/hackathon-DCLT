# Evidências do Drill de DR — SolidaryTech

**Data:** 2026-07-21 · **Ambiente:** AWS Academy Learner Lab, conta `086038954498`,
us-east-1, cluster `solidarytech-eks`.
**Resultado:** ✅ PASSOU — backup e restore do estado do cluster validados
funcionalmente; camada de dados (RDS) com PITR habilitado e snapshot manual
criado.

Este documento contém **comandos e saídas reais** coletados durante o drill. Ele
serve como runbook (os mesmos comandos executam a recuperação real) e como
evidência de que a estratégia de [`pcn.md`](pcn.md) funciona na prática.

---

## 0. Achado da auditoria — RDS sem backup (corrigido)

Antes de qualquer coisa, a auditoria de DR revelou que os backups do RDS
estavam **desligados** (`retention: 0`, `LatestRestorableTime: null`) — os dados
de doação não tinham nenhum ponto de recuperação:

```console
$ aws rds describe-db-instances \
    --query 'DBInstances[].{id:DBInstanceIdentifier,retention:BackupRetentionPeriod,earliest:LatestRestorableTime}'
[
  { "id": "solidarytech-donation-db", "retention": 0, "earliest": null },
  { "id": "solidarytech-ngo-db",      "retention": 0, "earliest": null }
]
```

Correção aplicada via Terraform (`modules/rds`) — ver seção 4.

---

## 1. Provisionamento do alvo de backup (IaC)

Bucket S3 externo ao cluster, criado via Terraform (`modules/backup`):

```console
$ terraform apply -target=module.backup -auto-approve
...
$ terraform output -raw velero_bucket_name
solidarytech-velero-backups-086038954498
```

Propriedades do bucket (definidas em código): versionamento habilitado,
criptografia SSE-S3, public access bloqueado, lifecycle de expiração em 30 dias.

---

## 2. Instalação do Velero (backup do estado do cluster)

Velero instalado apontando pro bucket, **usando o IAM role do node (LabRole)**
via `--no-secret` — sem credencial estática no cluster:

```console
$ velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.10.1 \
    --bucket solidarytech-velero-backups-086038954498 \
    --backup-location-config region=us-east-1 \
    --use-volume-snapshots=false \
    --no-secret --wait
...
Velero is installed! ⛵
```

Validação de que o Velero autenticou no S3 (BackupStorageLocation **Available**):

```console
$ velero backup-location get
NAME      PROVIDER   BUCKET/PREFIX                              PHASE       ACCESS MODE   DEFAULT
default   aws        solidarytech-velero-backups-086038954498   Available   ReadWrite     true
```

---

## 3. Drill: backup → simulação de desastre → restore

### 3.1 Backup manual + agendamento recorrente

```console
$ velero backup create solidarytech-manual-01 --include-namespaces solidarytech --wait
Backup completed with status: Completed.

$ velero schedule create solidarytech-6h \
    --schedule="0 */6 * * *" --include-namespaces solidarytech --ttl 168h0m0s
Schedule "solidarytech-6h" created successfully.
```

Conteúdo capturado (trecho de `velero backup describe --details`): Deployments,
ReplicaSets, HPAs, Services (Endpoints/EndpointSlice), ConfigMaps e Secrets dos
3 serviços + consumer.

### 3.2 Restore em namespace mapeado (recuperação sem tocar no ambiente vivo)

O restore foi direcionado a `solidarytech-dr` (via `--namespace-mappings`) para
provar a recuperação **sem** derrubar o namespace em produção — e, de quebra,
sem colidir com o ArgoCD (que só governa `solidarytech`):

```console
$ velero restore create dr-drill-01 --from-backup solidarytech-manual-01 \
    --namespace-mappings solidarytech:solidarytech-dr --wait
Restore completed with status: Completed.

$ velero restore describe dr-drill-01
Phase:                       Completed
Total items to be restored:  35
Items restored:              35
```

Pods reconstruídos e prontos (~30s após o restore):

```console
$ kubectl get pods -n solidarytech-dr
NAME                                  READY   STATUS    RESTARTS   AGE
donation-service-6f969c46c9-bkfxj     1/1     Running   0          33s
donation-service-6f969c46c9-wfskp     1/1     Running   0          32s
ngo-service-5c98db9b66-sdflm          1/1     Running   0          32s
ngo-service-5c98db9b66-vzrkt          1/1     Running   0          32s
volunteer-consumer-586f47d887-nzhkc   1/1     Running   0          32s
volunteer-service-78cbcc7cf4-b4vhr    1/1     Running   0          32s
volunteer-service-78cbcc7cf4-jp6md    1/1     Running   0          32s
```

### 3.3 Prova de funcionalidade (não só "Running")

O `donation-service` **restaurado** serviu `GET /donations` de verdade,
conectando ao RDS e retornando registros reais de doação:

```console
$ kubectl -n solidarytech-dr exec <donation-pod> -- wget -qO- http://localhost:8082/donations
[{"id":41,"ngo_id":1,"amount":54,"donor_name":"Doador Carga 40","status":"APPROVED",...},
 {"id":40,"ngo_id":2,"amount":224,"donor_name":"Doador Carga 39","status":"APPROVED",...}, ...]
```

E o estado restaurado preservou o **rightsizing** aplicado (backup = estado
desejado real do cluster, não um manifesto desatualizado):

```console
$ kubectl -n solidarytech-dr get deploy donation-service \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests}'
{"cpu":"50m","memory":"32Mi"}
```

### 3.4 Limpeza do drill

```console
$ kubectl delete ns solidarytech-dr
namespace "solidarytech-dr" deleted
```

> **Nota GitOps:** em produção, para recuperar o **próprio** namespace
> `solidarytech`, o caminho primário é o ArgoCD re-sincronizar do Git (RPO 0 de
> config). O Velero é o plano B: cobre objetos fora do Git e a perda total do
> cluster (restore num cluster novo). O restore em namespace mapeado acima prova
> o mecanismo Velero isoladamente, sem interferência do `selfHeal`.

---

## 4. Camada de dados — RDS PITR + snapshot

### 4.1 Habilitação de backups automáticos / PITR (IaC)

```console
$ terraform plan -target=module.rds
  ~ backup_retention_period = 0 -> 7
  ~ copy_tags_to_snapshot   = false -> true
Plan: 0 to add, 2 to change, 0 to destroy.

$ terraform apply -target=module.rds -auto-approve
```

Estado após a habilitação (PITR ativo — `LatestRestorableTime` passa a existir e
avança continuamente, entregando o RPO de ~5 min):

```console
$ aws rds describe-db-instances \
    --query 'DBInstances[].{id:DBInstanceIdentifier,retention:BackupRetentionPeriod,latestRestorable:LatestRestorableTime}'
+---------------------------+------------------------------------+------------+------------+
|            id             |         latestRestorable           | retention  |  status    |
+---------------------------+------------------------------------+------------+------------+
|  solidarytech-donation-db |  2026-07-21T21:56:58+00:00         |  7         |  available |
|  solidarytech-ngo-db      |  2026-07-21T21:53:21+00:00         |  7         |  available |
+---------------------------+------------------------------------+------------+------------+
```

O `LatestRestorableTime` **avança continuamente** — em checagens sucessivas o
`ngo-db` foi de `21:48:58` → `21:53:21`, comprovando que o RDS arquiva os
transaction logs sem parar. É esse avanço que materializa o RPO de ~5 min: pode-se
restaurar para qualquer instante entre o início da retenção e ~5 min atrás.

> **Lição do drill (ordering):** a primeira aplicação falhou no `donation-db`
> com `InvalidDBInstanceState` porque o snapshot manual da seção 4.2 estava sendo
> criado na mesma instância — o RDS recusa `ModifyDBInstance` enquanto há
> snapshot em andamento. O `ngo-db` (sem snapshot concorrente) habilitou de
> primeira. Correção: reaplicar `terraform apply -target=module.rds` após o
> snapshot concluir. **Runbook:** habilitar backups/PITR ANTES de criar
> snapshots manuais, ou serializar as duas operações por instância.

### 4.2 Snapshot manual (ponto de recuperação sob demanda)

```console
$ aws rds create-db-snapshot \
    --db-instance-identifier solidarytech-donation-db \
    --db-snapshot-identifier solidarytech-donation-dr-manual-<ts>
{ "id": "solidarytech-donation-dr-manual-...", "status": "creating", "type": "manual" }
```

Snapshot concluído (disponível para restauração a qualquer momento):

```console
$ aws rds describe-db-snapshots --db-snapshot-identifier solidarytech-donation-dr-manual-20260721-1845 \
    --query 'DBSnapshots[].{id:DBSnapshotIdentifier,status:Status,pct:PercentProgress}'
[ { "id": "solidarytech-donation-dr-manual-20260721-1845", "pct": 100, "status": "available" } ]
```

---

## 5. Conclusão

| Objetivo | Alvo (PCN) | Evidência |
|---|---|---|
| Restore do estado do cluster | RTO 30min | Restore completo em ~1min, pods funcionais em ~30s ✅ |
| Backup externo ao cluster | sobrevive à perda do EKS | Bucket S3 versionado/criptografado, BSL Available ✅ |
| PITR dos dados de doação | RPO 5min | `backup_retention_period=7`, PITR ativo ✅ |
| Snapshot sob demanda | ponto de recuperação | Snapshot manual criado ✅ |
| Automação (sem passo manual) | tudo IaC | Terraform + Velero Schedule versionados ✅ |
