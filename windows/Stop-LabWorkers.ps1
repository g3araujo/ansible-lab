#Requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Context = 'lab-k3s'
$Kubectl = (Get-Command kubectl -ErrorAction Stop).Source
$Wsl     = "$env:SystemRoot\System32\wsl.exe"

$Workers = @(
    [pscustomobject]@{ VM = 'k3s-lab-02'; Node = 'k3s-lab-02' }
    [pscustomobject]@{ VM = 'k3s-lab-03'; Node = 'k3s-lab-03' }
)

foreach ($Worker in $Workers) {
    & $Kubectl --context $Context cordon $Worker.Node
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao cordonar $($Worker.Node)"
    }

    & $Kubectl --context $Context taint node $Worker.Node `
        'lab.matera/standin=true:NoSchedule' `
        'lab.lifecycle/hold=true:NoSchedule' `
        --overwrite

    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao proteger $($Worker.Node)"
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

        throw "Desligamento bloqueado. Workloads em $($Worker.Node): $($Names -join ', ')"
    }
}

$RunningWorkers = @(
    $Workers | Where-Object {
        (Get-VM -Name $_.VM).State -eq 'Running'
    }
)

if ($RunningWorkers.Count -gt 0) {
    $Limit = ($RunningWorkers.Node -join ',')

    $AnsibleCommand = "cd /home/g/ansible && ansible-playbook -i inventory/lab.ini playbooks/k3s-workers-stop.yml --limit '$Limit'"

    & $Wsl -d Ubuntu -- bash -lc $AnsibleCommand

    if ($LASTEXITCODE -ne 0) {
        throw 'Falha ao parar os agentes K3s via Ansible.'
    }
}

foreach ($Worker in $RunningWorkers) {
    Write-Host "Desligando $($Worker.VM)..."
    Stop-VM -Name $Worker.VM -Confirm:$false

    $Stopped = $false

    for ($Attempt = 1; $Attempt -le 60; $Attempt++) {
        if ((Get-VM -Name $Worker.VM).State -eq 'Off') {
            $Stopped = $true
            break
        }

        Start-Sleep -Seconds 3
    }

    if (-not $Stopped) {
        throw "$($Worker.VM) não desligou em 180 segundos."
    }
}

Get-VM -Name ($Workers.VM) |
    Select-Object Name,State,AutomaticStopAction
