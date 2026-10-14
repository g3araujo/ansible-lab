#Requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Context  = 'lab-k3s'
$Kubectl  = (Get-Command kubectl -ErrorAction Stop).Source
$Wsl      = "$env:SystemRoot\System32\wsl.exe"

$Workers = @(
    [pscustomobject]@{
        VM      = 'k3s-lab-02'
        Node    = 'k3s-lab-02'
        Address = '192.168.0.116'
        SSHPort = 22222
    }
    [pscustomobject]@{
        VM      = 'k3s-lab-03'
        Node    = 'k3s-lab-03'
        Address = '192.168.0.117'
        SSHPort = 22
    }
)

foreach ($Worker in $Workers) {
    & $Kubectl --context $Context get node $Worker.Node *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Node não encontrado no cluster: $($Worker.Node)"
    }

    & $Kubectl --context $Context cordon $Worker.Node
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao cordonar $($Worker.Node)"
    }

    & $Kubectl --context $Context taint node $Worker.Node `
        'lab.matera/standin=true:NoSchedule' `
        'lab.lifecycle/hold=true:NoSchedule' `
        --overwrite

    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao proteger $($Worker.Node) com taints"
    }

    $PodList = & $Kubectl --context $Context get pods -A `
        --field-selector "spec.nodeName=$($Worker.Node)" `
        -o json | ConvertFrom-Json

    $Workloads = @(
        $PodList.items | Where-Object {
            $_.status.phase -notin @('Succeeded', 'Failed') -and
            (
                -not $_.metadata.ownerReferences -or
                $_.metadata.ownerReferences[0].kind -ne 'DaemonSet'
            )
        }
    )

    if ($Workloads.Count -gt 0) {
        $Names = $Workloads |
            ForEach-Object {
                "$($_.metadata.namespace)/$($_.metadata.name)"
            }

        throw "Workloads comuns ainda associados a $($Worker.Node): $($Names -join ', ')"
    }
}

foreach ($Worker in $Workers) {
    $VM = Get-VM -Name $Worker.VM

    if ($VM.State -ne 'Running') {
        Write-Host "Iniciando $($Worker.VM)..."
        Start-VM -Name $Worker.VM
    }

    $SSHReady = $false

    for ($Attempt = 1; $Attempt -le 90; $Attempt++) {
        if (Test-NetConnection $Worker.Address `
                -Port $Worker.SSHPort `
                -InformationLevel Quiet `
                -WarningAction SilentlyContinue) {
            $SSHReady = $true
            break
        }

        Start-Sleep -Seconds 2
    }

    if (-not $SSHReady) {
        throw "$($Worker.VM) não disponibilizou SSH em 180 segundos."
    }
}

& $Wsl -d Ubuntu -- bash -lc `
    'cd /home/g/ansible && ansible-playbook -i inventory/lab.ini playbooks/k3s-workers-start.yml'

if ($LASTEXITCODE -ne 0) {
    throw 'Falha ao iniciar os agentes K3s via Ansible.'
}

foreach ($Worker in $Workers) {
    & $Kubectl --context $Context wait `
        --for=condition=Ready `
        "node/$($Worker.Node)" `
        --timeout=120s

    if ($LASTEXITCODE -ne 0) {
        throw "$($Worker.Node) não ficou Ready."
    }
}

& $Kubectl --context $Context get nodes `
    k3s-lab-02 k3s-lab-03 `
    -o custom-columns='NODE:.metadata.name,READY:.status.conditions[-1].status,UNSCHEDULABLE:.spec.unschedulable,TAINTS:.spec.taints[*].key'
