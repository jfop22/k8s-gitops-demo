# Local Kubernetes + Argo CD + nginx demo (explained)

```
browser ──► localhost:80 ──► [kind cluster, inside a Docker container]
                               nginx ingress ──/──►    portal (nginx, static page)
                                             ──/api──► api    (Python, 2 replicas)
                             Argo CD watches this git repo's ./deploy folder
```

## Glossary

| Term | Plain meaning |
|---|---|
| **Image** | A frozen, packaged app plus everything it needs. Built from a `Dockerfile`. Like an installer. |
| **Container** | A running image, isolated from everything else. Like a running program. |
| **Cluster / node** | A set of machines (nodes) that Kubernetes manages as one big computer. |
| **kind** | "Kubernetes IN Docker". Runs a real cluster where each node is a Docker container. Fast, disposable, meant for dev/test. |
| **minikube** | Another tool with the same purpose (local cluster), heavier, more built-in add-ons. Not used here. |
| **kubectl** | Command-line remote control for a cluster. |
| **Pod** | The smallest runnable unit: one (or a few) containers. Pods are disposable; they get replaced, not repaired. |
| **Deployment** | "Keep N identical pods of this image running, and roll out updates gently." |
| **Service** | A stable internal name + address in front of a changing set of pods (pods die and get new IPs; the Service doesn't). |
| **Ingress** | Routing rules for HTTP coming from outside the cluster. |
| **Ingress controller** | The program that enforces Ingress rules. Here: nginx. |
| **Namespace** | A folder inside the cluster to group things. We use `demo`, `argocd`, `ingress-nginx`. |
| **Manifest** | A YAML file describing desired state. |
| **Argo CD** | Runs in the cluster, compares git with the cluster, and makes the cluster match git. |

**The GitOps rule:** you never `kubectl apply` the app by hand. You commit to git; Argo CD applies it.
Why: git gives you history, review and easy rollback, and the cluster can be rebuilt from the repo alone.

---

## Step 0 - Prerequisites

Start **Docker Desktop** and wait for "Engine running".
```powershell
winget install Kubernetes.kind
```
- **What:** Docker Desktop is the engine that builds images and runs containers. kind is the tool that creates the cluster using Docker.
- **Why:** kind needs Docker; without a running engine nothing else works.
- **Enables:** a real Kubernetes cluster on your PC without servers or a cloud account.

Open a **new** terminal afterwards (PATH only refreshes in new terminals). Verify: `kind version`, `docker ps`.

## Step 1 - Create the cluster

```powershell
cd k8s-gitops-demo
kind create cluster --config kind-config.yaml
kubectl get nodes
```
- **What:** kind starts one Docker container that runs Kubernetes inside it. The config file (`kind-config.yaml`) does two things: labels the node `ingress-ready` (so the nginx controller knows it may run there) and forwards your PC's ports 80/443 into that container.
- **Why the port forwarding:** the cluster lives inside a container with its own private network. Without a forwarded port, your browser cannot reach anything in it.
- **Enables:** an empty, working cluster. It also points `kubectl` at it automatically (a "context" called `kind-demo`).
- **Check:** the node shows `Ready`.

## Step 2 - Install the nginx ingress controller

```powershell
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml
kubectl wait -n ingress-nginx --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s
```
- **What:** `kubectl apply -f <url>` sends a YAML file to the cluster saying "make this exist". This file defines the nginx controller (plus its permissions and config). The `kind` variant is pre-set to listen on the node's ports 80/443, which step 1 exposed.
- **Why:** an Ingress object is only a rule; something has to enforce it. Kubernetes ships with no controller.
- **Enables:** traffic path `your browser → localhost:80 → nginx → the right Service`. Later our `deploy/ingress.yaml` tells it which service gets which URL path.
- **Note:** `wait` simply blocks until the pod is up, so the next steps don't race it.

## Step 3 - Build the images and load them into the cluster

```powershell
docker build -t demo-api:v1 apps/api
docker build -t demo-portal:v1 apps/portal
kind load docker-image demo-api:v1 demo-portal:v1 --name demo
```
- **What:** `docker build` follows each `Dockerfile` and produces an image tagged `name:version`. `kind load` copies the images into the kind node.
- **Why load:** the cluster is its own little world with its own image store; it cannot see images on your PC. Normally you'd push to a registry (Docker Hub, GHCR) and the cluster would pull. Loading skips the registry for simplicity. That's also why the manifests use `imagePullPolicy: IfNotPresent`: "don't try to download, it's already here".
- **Enables:** the cluster can start our apps. The tag (`v1`) matters later: changing it in git is how you deploy a new version.

## Step 4 - Install Argo CD

```powershell
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait -n argocd --for=condition=ready pod -l app.kubernetes.io/name=argocd-server --timeout=300s
```
- **What:** creates a namespace (a folder) and installs Argo CD into it: a controller that does the git-vs-cluster comparison, a repo server that reads git, and a web UI/API.
- **Why `--server-side`:** Argo's definitions are so large that the default client-side apply fails with an "annotation too long" error.
- **Enables:** the GitOps engine. It's installed but doing nothing yet, because we haven't told it which repo to watch (step 6).

Make the UI reachable at **http://argocd.localhost** through the nginx ingress:
```powershell
kubectl patch cm argocd-cmd-params-cm -n argocd --patch-file argocd/insecure-patch.yaml
kubectl rollout restart deploy argocd-server -n argocd
kubectl apply -f argocd/ingress.yaml
```
- **What:** the first command turns off Argo's own HTTPS (it serves a self-signed certificate, awkward behind an ingress), the second restarts the server to pick that up, the third adds an Ingress routing the host `argocd.localhost` to the Argo server.
- **Why:** the UI is only reachable inside the cluster by default. This uses the same front door as the demo app, so it is permanent: no terminal to keep open, and it survives restarts. Browsers resolve `*.localhost` to your own machine automatically.
- **Local lab only:** plain HTTP is fine on your own PC. A real setup terminates TLS at the ingress with a real certificate.
- **Fallback** if that ever misbehaves: `kubectl port-forward svc/argocd-server -n argocd 8080:80`, then http://localhost:8080 (keep that terminal open).

Open http://argocd.localhost. User `admin`; password:
```powershell
$p = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
```
- **What:** Argo generated a random password and stored it in a Kubernetes *Secret* (base64-encoded, which is encoding, not encryption). This reads and decodes it.

## Step 5 - Put this folder in a git repo on GitHub

```powershell
git init -b main
git add .
git commit -m "Initial demo"
git remote add origin https://github.com/YOUR-USER/k8s-gitops-demo.git
git push -u origin main
```
(create an empty **public** repo on github.com first)
- **What:** this folder becomes a git repo, pushed to GitHub.
- **Why GitHub and not just local git:** Argo CD runs *inside* the cluster, a different network than your PC's folders. It needs a URL it can clone from. Public means no credentials to set up.
- **Enables:** git becomes the single source of truth. Anything in `deploy/` on `main` is "what should be running".

Then edit `repoURL` in `argocd/application.yaml` to your repo, commit, push.

## Step 6 - Tell Argo CD to watch the repo

```powershell
kubectl apply -f argocd/application.yaml
```
- **What:** creates one Argo CD `Application` object, which says: source = your repo, folder `deploy`, branch `main`; destination = this cluster, namespace `demo`. Policy:
  - `automated` = apply changes without clicking Sync
  - `prune` = if you delete a file from git, delete it from the cluster too
  - `selfHeal` = if someone changes the cluster by hand, revert it
  - `CreateNamespace` = create the `demo` namespace if missing
- **Why manual, just this once:** something has to bootstrap the loop. After this, everything flows through git.
- **Enables:** Argo clones the repo, finds `api.yaml`, `portal.yaml`, `ingress.yaml`, and creates them. Watch it happen in the UI.

Open **http://localhost**. The page loads from the portal pod, and its JavaScript calls `/api/hello`, which nginx routes to the api pods. The JSON shows `pod` names, and reloading shows load balancing between the 2 replicas.

### What the manifests in `deploy/` do
- `api.yaml`: a Deployment (2 pods of `demo-api:v1`, with a readiness probe so traffic only goes to pods that are ready) and a Service named `api`.
- `portal.yaml`: same pattern, 1 pod.
- `ingress.yaml`: `/api` → service `api`, everything else → service `portal`. This is the "way in".
- Services matter because pods get new IPs when replaced; other things refer to the stable service name instead.

## Step 7 - Try the GitOps loop

1. Edit `deploy/api.yaml`: change `GREETING`, set `replicas: 3`.
2. `git commit -am "change greeting" ; git push`
3. Argo polls git about every 3 minutes (or press *Refresh* in the UI). It sees git differs from the cluster and syncs. Reload http://localhost.

- **Self-heal experiment:** `kubectl scale deploy/api -n demo --replicas=1`. Argo notices the drift and sets it back. This is why you don't change things by hand.
- **Rollback:** `git revert HEAD ; git push` and the cluster follows.
- **Shipping new code:** change app code → `docker build -t demo-api:v2 apps/api` → `kind load docker-image demo-api:v2 --name demo` → change `image:` to `demo-api:v2` in `deploy/api.yaml` → commit, push. (In real projects a CI pipeline builds/pushes the image and updates that tag automatically.)

## Cleanup
```powershell
kind delete cluster --name demo
```
Removes the cluster completely. Your repo and images remain, so you can recreate everything from step 1.

## Debugging cheat sheet
```powershell
kubectl get pods -A                       # everything, all namespaces
kubectl get all -n demo
kubectl describe pod <name> -n demo       # events; first stop for "stuck" pods
kubectl logs deploy/api -n demo
kubectl get applications -n argocd        # Argo's view: Synced/Healthy?
```
Common errors: `ImagePullBackOff` / `ErrImagePull` = image tag not loaded with `kind load`, or typo. `Pending` = see `describe` events. `OutOfSync` = git differs from cluster (normal for a moment).
