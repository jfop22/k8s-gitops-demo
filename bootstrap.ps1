<#
.SYNOPSIS
  Builds the whole local environment: cluster, ingress, images, Argo CD, and the demo app.

.DESCRIPTION
  Safe to run repeatedly: every stage checks what already exists and skips or re-applies it.
  Mirrors the manual steps in README.md, in the same order.

.PARAMETER Recreate
  Delete the existing cluster first and rebuild everything from scratch.

.EXAMPLE
  .\bootstrap.ps1             # create or repair the environment
  .\bootstrap.ps1 -Recreate   # throw away the cluster and build a fresh one
#>
param([switch]$Recreate)

$ClusterName  = 'demo'
$IngressUrl   = 'https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml'
$ArgoUrl      = 'https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml'

# Everything below uses relative paths, so always run from this script's folder.
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }

# Run a native command and stop the script if it fails (PowerShell does not do this by itself).
function Run {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "'$Exe $($Arguments -join ' ')' failed (exit code $LASTEXITCODE)" }
}

# ---------------------------------------------------------------------------
# 0. Preflight. Fail early with a clear message instead of halfway through.
# ---------------------------------------------------------------------------
Step 'Checking prerequisites'

# winget installs kind into a folder that new terminals have on PATH, but older sessions may not.
$wingetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
if (-not (Get-Command kind -ErrorAction SilentlyContinue) -and (Test-Path $wingetLinks)) {
    $env:PATH += ";$wingetLinks"
}
foreach ($tool in 'docker', 'kind', 'kubectl') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' was not found. Install it (kind: winget install Kubernetes.kind) and open a new terminal."
    }
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker is not running. Start Docker Desktop and wait for "Engine running".' }
Write-Host 'docker, kind and kubectl found; Docker engine is running.'

# ---------------------------------------------------------------------------
# 1. The cluster: one Docker container that runs Kubernetes (kind).
#    kind-config.yaml forwards host ports 80/443 into it.
# ---------------------------------------------------------------------------
$existing = @(kind get clusters 2>$null)
if ($Recreate -and ($existing -contains $ClusterName)) {
    Step "Deleting existing cluster '$ClusterName' (-Recreate)"
    Run kind @('delete', 'cluster', '--name', $ClusterName)
    $existing = @()
}

if ($existing -contains $ClusterName) {
    Step "Cluster '$ClusterName' already exists, reusing it"
    # Make sure kubectl talks to it even if you switched to another cluster in between.
    Run kubectl @('config', 'use-context', "kind-$ClusterName")
} else {
    Step "Creating cluster '$ClusterName'"
    Run kind @('create', 'cluster', '--config', 'kind-config.yaml')
}
Run kubectl @('wait', '--for=condition=Ready', 'node', '--all', '--timeout=180s')

# ---------------------------------------------------------------------------
# 2. nginx ingress controller: turns Ingress rules into actual routing.
# ---------------------------------------------------------------------------
Step 'Installing the nginx ingress controller'
Run kubectl @('apply', '-f', $IngressUrl)
# 'rollout status' waits for the Deployment itself, so it works right after apply
# (a 'wait' on pods can fail because the pod object does not exist yet).
Run kubectl @('rollout', 'status', 'deployment/ingress-nginx-controller', '-n', 'ingress-nginx', '--timeout=240s')

# ---------------------------------------------------------------------------
# 3. Build the app images and load them into the cluster's own image store.
#    The image names/tags are read from deploy/*.yaml, so bumping a tag in git
#    and re-running this script builds exactly what the manifests ask for.
# ---------------------------------------------------------------------------
Step 'Building and loading app images'
$apps = @{ api = 'deploy/api.yaml'; portal = 'deploy/portal.yaml' }
$images = @()
foreach ($app in $apps.Keys) {
    $match = Select-String -Path $apps[$app] -Pattern '^\s*image:\s*(\S+)' | Select-Object -First 1
    if (-not $match) { throw "No 'image:' line found in $($apps[$app])" }
    $image = $match.Matches[0].Groups[1].Value
    Write-Host "Building $image from apps/$app"
    Run docker @('build', '-t', $image, "apps/$app")
    $images += $image
}
Run kind (@('load', 'docker-image') + $images + @('--name', $ClusterName))

# ---------------------------------------------------------------------------
# 4. Argo CD: the GitOps engine that keeps the cluster equal to the git repo.
# ---------------------------------------------------------------------------
Step 'Installing Argo CD'
# Create the namespace only if missing ('create' alone fails on a second run).
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw 'Could not create namespace argocd' }
# --server-side: Argo CD's definitions are too large for a normal client-side apply.
Run kubectl @('apply', '-n', 'argocd', '--server-side', '--force-conflicts', '-f', $ArgoUrl)

# Plain HTTP inside the cluster so the nginx ingress can expose the UI (local lab only).
Run kubectl @('patch', 'configmap', 'argocd-cmd-params-cm', '-n', 'argocd', '--patch-file', 'argocd/insecure-patch.yaml')
Run kubectl @('rollout', 'restart', 'deployment/argocd-server', '-n', 'argocd')

Run kubectl @('rollout', 'status', 'deployment/argocd-server', '-n', 'argocd', '--timeout=300s')
Run kubectl @('rollout', 'status', 'statefulset/argocd-application-controller', '-n', 'argocd', '--timeout=300s')
Run kubectl @('rollout', 'status', 'deployment/argocd-repo-server', '-n', 'argocd', '--timeout=300s')

# UI at http://argocd.localhost (replaces the manual port-forward).
Run kubectl @('apply', '-f', 'argocd/ingress.yaml')

# ---------------------------------------------------------------------------
# 5. Hand the git repo to Argo CD. From here on, changes go through git.
# ---------------------------------------------------------------------------
Step 'Registering the demo application with Argo CD'
Run kubectl @('apply', '-f', 'argocd/application.yaml')

Step 'Waiting for Argo CD to sync the app from git (up to 5 minutes)'
$deadline = (Get-Date).AddMinutes(5)
$ready = $false
while ((Get-Date) -lt $deadline) {
    $sync   = kubectl get application demo -n argocd -o jsonpath='{.status.sync.status}' 2>$null
    $health = kubectl get application demo -n argocd -o jsonpath='{.status.health.status}' 2>$null
    Write-Host "  sync=$sync health=$health"
    if ($sync -eq 'Synced' -and $health -eq 'Healthy') { $ready = $true; break }
    Start-Sleep -Seconds 5
}
if (-not $ready) {
    Write-Warning 'The app did not become Synced/Healthy in time. Check: kubectl get applications -n argocd'
}

# ---------------------------------------------------------------------------
# Done. The admin password goes to the clipboard, not the screen.
# ---------------------------------------------------------------------------
$b64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>$null
if ($b64) {
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | Set-Clipboard
    $pwNote = 'The admin password is on your clipboard (paste it into the login form).'
} else {
    $pwNote = 'The initial admin secret no longer exists (it is removed if you changed the password).'
}

Write-Host "`nDone." -ForegroundColor Green
Write-Host '  Demo app : http://localhost'
Write-Host '  Argo CD  : http://argocd.localhost   (user: admin)'
Write-Host "  $pwNote"
Write-Host '  Note     : the cluster can be stopped/started with docker stop|start demo-control-plane'
