# Ansible — ciclo de vida dos workers K3s

Este repositório mantém a configuração e o ciclo de vida dos nós do laboratório K3s.

Os workers são iniciados e desligados **manualmente**. Não há agendamento automático. Ao ligar as VMs, o `k3s-agent` permanece desabilitado no boot e só é iniciado pelo procedimento controlado deste repositório.

## Início rápido

Execute os scripts abaixo em um **PowerShell aberto como Administrador**.

### Subir os workers

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File 'C:\ProgramData\LabLifecycle\Start-LabWorkers.ps1'
```

### Descer os workers

Antes da descida, encerre os workloads comuns, especialmente o Oracle. O script bloqueia o desligamento se ainda houver algum workload que não seja `DaemonSet` associado aos workers.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File 'C:\ProgramData\LabLifecycle\Stop-LabWorkers.ps1'
```

## Topologia

| Nó | IP | SSH | Função | Observações |
|---|---:|---:|---|---|
| `k3s-lab-01` | `192.168.0.115` | `22222` | Control plane | Registry local em `192.168.0.115:5000` |
| `k3s-lab-02` | `192.168.0.116` | `22222` | Worker / workload pesado | Label `workload=heavy`; armazena o PV local do Oracle |
| `k3s-lab-03` | `192.168.0.117` | `22` | Worker | Capacidade adicional |

Contexto Kubernetes: `lab-k3s`  
Inventário Ansible: `inventory/lab.ini`

## Estado operacional esperado

Depois da subida controlada:

- VMs `k3s-lab-02` e `k3s-lab-03`: `Running`;
- nós: `Ready,SchedulingDisabled`;
- `k3s-agent`: `active` e `disabled`;
- workers cordonados;
- taints de proteção presentes;
- apenas pods `DaemonSet` podem aparecer automaticamente.

Proteções aplicadas:

```text
lab.matera/standin=true:NoSchedule
lab.lifecycle/hold=true:NoSchedule
node.kubernetes.io/unschedulable
```

O estado `active/disabled` do agente é proposital: o serviço participa do cluster durante a sessão atual, mas não inicia sozinho após reboot da VM.

## Como funciona a subida

O script `Start-LabWorkers.ps1`:

1. confirma que os nós existem no cluster;
2. aplica `cordon` e os taints de proteção;
3. bloqueia a execução se encontrar workloads comuns associados aos workers;
4. inicia as VMs em Hyper-V;
5. aguarda o SSH de cada VM por até 180 segundos;
6. executa `playbooks/k3s-workers-start.yml` pelo WSL/Ansible;
7. aguarda os dois nós ficarem `Ready`;
8. exibe estado, cordon e taints.

O script **não libera os workers para agendamento geral**.

## Como funciona a descida

O script `Stop-LabWorkers.ps1`:

1. cordona os workers e reaplica os taints;
2. bloqueia a execução se encontrar workloads que não sejam `DaemonSet`;
3. para o `k3s-agent` por Ansible, mantendo-o desabilitado;
4. solicita o desligamento das VMs pelo Hyper-V;
5. aguarda até 180 segundos por VM;
6. exibe o estado final das VMs.

Nunca force o desligamento se o script indicar workloads associados a um worker. Identifique e encerre cada workload primeiro.

## Oracle `labmatera-oracle-clean`

O Oracle usa armazenamento `local-path` no `k3s-lab-02`. O banco deve ser encerrado antes de desligar o node.

### Descer o Oracle antes dos workers

Execute no WSL:

```bash
# Impedir que o Argo CD reverta temporariamente replicas=0.
kubectl --context lab-k3s -n argocd \
  annotate application labmatera \
  argocd.argoproj.io/skip-reconcile=true \
  --overwrite

# Encerrar o banco de forma limpa.
kubectl --context lab-k3s -n matera-legacy \
  exec labmatera-oracle-clean-0 -- bash -lc \
  'printf "shutdown immediate;\nexit;\n" | sqlplus -L -s "/ as sysdba"'

# Remover o pod e manter o StatefulSet parado durante a descida.
kubectl --context lab-k3s -n matera-legacy \
  scale statefulset labmatera-oracle-clean --replicas=0

kubectl --context lab-k3s -n matera-legacy \
  wait --for=delete pod/labmatera-oracle-clean-0 \
  --timeout=600s
```

Depois execute `Stop-LabWorkers.ps1` no PowerShell elevado.

### Subir novamente o Oracle

Primeiro execute `Start-LabWorkers.ps1` no PowerShell elevado. Depois, no WSL:

```bash
# Liberar somente a etapa de agendamento no node que contém o PV.
kubectl --context lab-k3s uncordon k3s-lab-02

kubectl --context lab-k3s -n matera-legacy \
  scale statefulset labmatera-oracle-clean --replicas=1

# Aguardar o pod ser atribuído ao lab02 e proteger o node novamente.
until [ "$(kubectl --context lab-k3s -n matera-legacy \
  get pod labmatera-oracle-clean-0 \
  -o jsonpath='{.spec.nodeName}' 2>/dev/null)" = "k3s-lab-02" ]; do
  sleep 2
done

kubectl --context lab-k3s cordon k3s-lab-02

kubectl --context lab-k3s -n matera-legacy \
  wait --for=condition=Ready \
  pod/labmatera-oracle-clean-0 \
  --timeout=1800s

# Retomar a reconciliação do Argo CD.
kubectl --context lab-k3s -n argocd \
  annotate application labmatera \
  argocd.argoproj.io/skip-reconcile- \
  argocd.argoproj.io/refresh=hard \
  --overwrite
```

Validação do banco:

```bash
kubectl --context lab-k3s -n matera-legacy \
  exec labmatera-oracle-clean-0 -- bash -lc \
  'printf "set lines 200 pages 100\nselect instance_name,status from v\$instance;\nselect name,open_mode from v\$pdbs;\nexit;\n" | sqlplus -L -s "/ as sysdba"'
```

Resultado esperado:

```text
LABCDB    OPEN
LABMATERA READ WRITE
```

### Armazenamento local do Oracle

PV principal:

```text
pvc-d3a86878-176b-4108-a39b-af505219c01c
```

Caminho no `k3s-lab-02`:

```text
/var/lib/rancher/k3s/storage/pvc-d3a86878-176b-4108-a39b-af505219c01c_matera-legacy_labmatera-oradata-clean
```

Tamanho utilizado na última restauração: aproximadamente `22 GiB`.

Backup validado:

```text
S:\digio\lab\backups\lab02-local-path-20260921.tar.gz
```

> O PV é local. Não remova, recrie ou mova o `k3s-lab-02` sem validar esse diretório e o backup.

## Validações rápidas

### Windows / PowerShell elevado

```powershell
Get-VM -Name 'k3s-lab-02','k3s-lab-03' |
  Select-Object Name,State,AutomaticStartAction,AutomaticStopAction

kubectl --context lab-k3s get nodes
```

Configuração esperada do Hyper-V:

```text
AutomaticStartAction = Nothing
AutomaticStopAction  = ShutDown
AutomaticCheckpointsEnabled = False
```

### WSL

```bash
kubectl --context lab-k3s get nodes \
  -o custom-columns='NODE:.metadata.name,READY:.status.conditions[-1].status,UNSCHEDULABLE:.spec.unschedulable,TAINTS:.spec.taints[*].key'

cd ~/ansible

ansible -i inventory/lab.ini k3s_workers \
  -m shell \
  -a 'printf "active="; systemctl is-active k3s-agent; printf "enabled="; systemctl is-enabled k3s-agent || true'
```

## Execução manual via Ansible

Use somente quando os scripts do Windows não puderem concluir a etapa Ansible.

### Iniciar agentes

```bash
cd ~/ansible
ansible-playbook -i inventory/lab.ini \
  playbooks/k3s-workers-start.yml
```

### Parar agentes

```bash
cd ~/ansible
ansible-playbook -i inventory/lab.ini \
  playbooks/k3s-workers-stop.yml
```

Para operar apenas um worker:

```bash
ansible-playbook -i inventory/lab.ini \
  playbooks/k3s-workers-start.yml \
  --limit k3s-lab-02
```

## Arquivos principais

| Arquivo | Finalidade |
|---|---|
| `inventory/lab.ini` | Inventário do control plane e workers |
| `playbooks/base.yml` | Baseline do sistema operacional e SSH |
| `playbooks/baseline.yml` | Coleta e exibição de informações do host |
| `playbooks/k3s-workers-prepare.yml` | Swap, registry, taints e labels persistentes |
| `playbooks/k3s-worker.yml` | Instalação do agente K3s |
| `playbooks/k3s-registry.yml` | Configuração do registry local |
| `playbooks/k3s-workers-start.yml` | Inicia agentes sem habilitar no boot |
| `playbooks/k3s-workers-stop.yml` | Para agentes e os mantém desabilitados |
| `playbooks/node-protection.yml` | Proteções auxiliares dos workers |
| `windows/Start-LabWorkers.ps1` | Fonte versionada da subida controlada |
| `windows/Stop-LabWorkers.ps1` | Fonte versionada da descida controlada |

Scripts implantados no Windows:

```text
C:\ProgramData\LabLifecycle\Start-LabWorkers.ps1
C:\ProgramData\LabLifecycle\Stop-LabWorkers.ps1
```

Depois de alterar um script em `windows/`, copie a versão validada para `C:\ProgramData\LabLifecycle` usando um PowerShell elevado.

## Troubleshooting

### `Desligamento bloqueado. Workloads em ...`

Liste os workloads associados ao node:

```bash
kubectl --context lab-k3s get pods -A \
  --field-selector spec.nodeName=k3s-lab-02 \
  -o custom-columns='NAMESPACE:.metadata.namespace,POD:.metadata.name,STATUS:.status.phase,OWNER:.metadata.ownerReferences[0].kind'
```

Encerre o workload indicado. Não use `Stop-VM -TurnOff` para contornar o bloqueio.

### Node não fica `Ready`

```powershell
Get-VM -Name 'k3s-lab-02','k3s-lab-03' |
  Select-Object Name,State,Status

Test-NetConnection 192.168.0.116 -Port 22222
Test-NetConnection 192.168.0.117 -Port 22
```

```bash
cd ~/ansible

ansible -i inventory/lab.ini k3s_workers -m ping

ansible -i inventory/lab.ini k3s_workers \
  -m shell \
  -a 'systemctl status k3s-agent --no-pager; journalctl -u k3s-agent -n 80 --no-pager'
```

### `k3s-agent` está `disabled`

Isso é esperado. O serviço deve estar:

```text
active=active
enabled=disabled
```

### Pods `DaemonSet` aparecem em nodes cordonados

Isso também é esperado. Cordon impede novos workloads comuns, mas componentes de infraestrutura gerenciados por `DaemonSet` podem executar nos workers.

### Argo CD não atualiza a aplicação

Confira se a reconciliação foi deixada pausada:

```bash
kubectl --context lab-k3s -n argocd \
  get application labmatera \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/skip-reconcile}{"\n"}'
```

Para retomar:

```bash
kubectl --context lab-k3s -n argocd \
  annotate application labmatera \
  argocd.argoproj.io/skip-reconcile- \
  argocd.argoproj.io/refresh=hard \
  --overwrite
```

## Fluxo Git

O repositório está publicado em:

```text
ssh://forgejo-lab/garaujo/ansible.git
```

Versione apenas os arquivos relacionados à mudança:

```bash
git status --short
git diff --check
git diff

git add <arquivos>
git commit -m "descricao objetiva"
git push
```

## Princípios operacionais

- nenhuma subida ou descida semanal é agendada;
- as VMs não iniciam automaticamente com o Windows;
- o agente K3s não inicia automaticamente com a VM;
- workers entram protegidos, cordonados e com taints;
- workloads comuns devem ser tratados explicitamente;
- o Oracle deve ser encerrado de forma limpa;
- o PV local do Oracle exige preservação do disco do `k3s-lab-02`.


ansible all -m ping

ansible-playbook playbooks/01-baseline.yml

ansible-playbook playbooks/02-healthcheck.yml

ansible-playbook playbooks/03-k3s-server.yml

ansible-playbook playbooks/04-k3s-agent.yml