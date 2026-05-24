# GitOps Lab Runbook

A complete guide to building this environment from scratch: provisioning the Kubernetes cluster, installing Flux, and understanding every file in this repo.

---

## Table of Contents

1. [What This Environment Is](#1-what-this-environment-is)
2. [Cluster Overview](#2-cluster-overview)
3. [The Big Picture: What You're Building](#3-the-big-picture-what-youre-building)
4. [OPTIONAL: Tear Down an Existing Cluster](#4-optional-tear-down-an-existing-cluster)
5. [Phase 1: Build the Kubernetes Cluster](#5-phase-1-build-the-kubernetes-cluster)
   - [5.1 Pre-flight: Every Node](#51-pre-flight-every-node)
   - [5.2 Install the Container Runtime (containerd)](#52-install-the-container-runtime-containerd)
   - [5.3 Install kubeadm, kubelet, kubectl](#53-install-kubeadm-kubelet-kubectl)
   - [5.4 Initialise the Control Plane](#54-initialise-the-control-plane)
   - [5.5 Install a CNI (Flannel)](#55-install-a-cni-flannel)
   - [5.6 Join the Worker Nodes](#56-join-the-worker-nodes)
   - [5.7 Verify the Cluster](#57-verify-the-cluster)
6. [Phase 2: Prepare Nodes for Applications](#6-phase-2-prepare-nodes-for-applications)
   - [6.1 Create hostPath directories](#61-create-hostpath-directories)
   - [6.2 Create the database credentials Secret](#62-create-the-database-credentials-secret)
7. [Phase 3: Bootstrap Flux (GitOps)](#7-phase-3-bootstrap-flux-gitops)
8. [How GitOps Works Here](#8-how-gitops-works-here)
9. [Repository Structure](#9-repository-structure)
10. [File-by-File Reference](#10-file-by-file-reference)
11. [How the Files Relate to Each Other](#11-how-the-files-relate-to-each-other)
12. [Verification Commands](#12-verification-commands)
13. [Troubleshooting](#13-troubleshooting)
14. [Future: Image Tag Automation](#14-future-image-tag-automation)

---

## 1. What This Environment Is

This is a **GitOps lab** — a self-hosted Kubernetes cluster where the desired state of every application and piece of infrastructure is declared in YAML files in this git repository, and a tool called **Flux** watches the repository and automatically applies any changes to the cluster.

The core principle: **git is the single source of truth**. You never `kubectl apply` anything directly. Instead, you commit a change, push it, and Flux reconciles the cluster to match.

This lab runs:
- **Flux v2.3.0** — the GitOps engine
- **MetalLB v0.15.3** — a software load balancer (gives `LoadBalancer`-type Services real IPs on a bare-metal cluster, the way a cloud provider would)
- **Artifactory OSS v107.133.12** — a self-hosted artifact registry (Docker images, Helm charts, packages, etc.)

---

## 2. Cluster Overview

| Node | Role | IP |
|---|---|---|
| `cakers-cp-1.lab.local` | Control plane | `192.168.56.10` |
| `cakers-worker-1.lab.local` | Worker | `192.168.56.11` |
| `cakers-worker-2.lab.local` | Worker | `192.168.56.12` |
| `cakers-worker-3.lab.local` | Worker | `192.168.56.13` |

- **Kubernetes:** v1.32
- **Container runtime:** containerd v2.x
- **OS:** Rocky Linux 10.1
- **CNI (network plugin):** Flannel (installed manually after `kubeadm init`)
- **MetalLB IP pool:** `192.168.56.200–192.168.56.210` (layer2/ARP mode, same subnet as nodes)

---

## 3. The Big Picture: What You're Building

If you've used OpenShift or a managed Kubernetes service (EKS, GKE, etc.), you've always had the cluster handed to you. Here, you're building it yourself. Think of it in three phases:

```
Phase 1: Bare nodes → Working Kubernetes cluster
           (kubeadm does what the OpenShift installer does, but manually)

Phase 2: Prepare nodes for stateful apps
           (create the directories that Artifactory's storage will use)

Phase 3: Bootstrap Flux → Everything else deploys automatically
           (Flux is like OpenShift GitOps / ArgoCD — same idea, different CRDs)
```

After Phase 3, you never `kubectl apply` again. Every change goes through git.

---

## 4. OPTIONAL: Tear Down an Existing Cluster

> **Skip this section if you're building from scratch on fresh nodes.**
>
> Use this if you want to wipe an existing cluster and start completely clean.

### On every worker node (run as root or with sudo)

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete cni0 2>/dev/null || true
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
```

### On the control plane node

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete cni0 2>/dev/null || true
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
rm -rf ~/.kube
```

### Delete the credentials Secret

The `artifactory-db-credentials` Secret is not in git, so `kubeadm reset` won't touch it — but it lives in the `artifactory` namespace which disappears with the cluster anyway. Nothing to do here; just remember to re-create it when you rebuild (Phase 2.2).

### Clean up Flux from GitHub

Flux creates a deploy key on your GitHub repo so it can pull over SSH. If you re-bootstrap, it regenerates this key. To avoid a conflict, delete the old one first:

1. Go to your GitHub repo → **Settings → Deploy keys**
2. Delete the key named `flux-system`

> You do **not** need to delete anything from the repo itself. The `clusters/lab/flux-system/` directory can stay — `flux bootstrap` will overwrite it.

### Clean up application data (optional)

The Artifactory and PostgreSQL data directories on `cakers-worker-1` persist across resets (they're just directories on disk). If you want a truly clean start:

```bash
# On cakers-worker-1
sudo rm -rf /mnt/data/artifactory-data /mnt/data/postgres-data
```

Now proceed to Phase 1 as if the nodes are fresh.

---

## 5. Phase 1: Build the Kubernetes Cluster

> **Run all commands in this phase as root, or prefix with `sudo`.**
>
> Unless stated otherwise, run each step on **all four nodes** (control plane + three workers).

### 5.1 Pre-flight: Every Node

Kubernetes has a few hard requirements that Rocky Linux doesn't satisfy by default.

**Disable swap.** Kubernetes refuses to start if swap is on. It wants full control of memory allocation.

```bash
sudo swapoff -a
# Make it permanent across reboots:
sudo sed -i '/\bswap\b/d' /etc/fstab
```

**Set SELinux to permissive.** For a lab, permissive is the path of least resistance. In production you'd configure SELinux policies properly.

```bash
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

**Disable the firewall.** These are VMs on an isolated network. Firewalld would block inter-node traffic (etcd, kubelet, Flannel VXLAN, etc.).

```bash
sudo systemctl disable --now firewalld
```

**Load kernel modules.** Kubernetes networking depends on two kernel modules that aren't loaded by default:

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

- `overlay` — needed by containerd for layered container filesystems
- `br_netfilter` — needed so iptables can see bridged traffic (how pods talk to each other and to Services)

**Configure kernel networking settings:**

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

These tell the kernel to pass bridged network traffic through iptables — without this, Kubernetes Service routing breaks completely.

---

### 5.2 Install the Container Runtime (containerd)

Kubernetes doesn't run containers itself. It delegates to a **container runtime**. This lab uses **containerd** — the same runtime used by Docker and by most managed Kubernetes services.

> **OpenShift analogy:** containerd here is equivalent to CRI-O in OpenShift. Both implement the Container Runtime Interface (CRI) that kubelet talks to.

**Add the Docker repository** (containerd is distributed via Docker's repo):

```bash
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
```

**Install containerd:**

```bash
sudo dnf install -y containerd.io
```

**Configure containerd.** The default config has a problem: it uses the `cgroupfs` cgroup driver, but Kubernetes expects `systemd`. Mismatched drivers cause subtle, hard-to-debug failures.

```bash
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
```

Now edit the config to enable the `systemd` cgroup driver. Find the `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]` section and set `SystemdCgroup = true`:

```bash
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

Verify the change took effect:

```bash
grep -i SystemdCgroup /etc/containerd/config.toml
# Should output: SystemdCgroup = true
```

**Start and enable containerd:**

```bash
sudo systemctl enable --now containerd
```

---

### 5.3 Install kubeadm, kubelet, kubectl

These three tools are what actually make Kubernetes run on the node:

| Tool | What it does |
|---|---|
| `kubelet` | The agent that runs on every node. It talks to the API server and manages pod lifecycle. Think of it as the node's brain. |
| `kubeadm` | A one-shot installer. You use it to initialise the control plane and join workers. After that, it's mostly idle. |
| `kubectl` | Your CLI for talking to the cluster. Same tool you've always used. |

**Add the Kubernetes repository:**

```bash
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
```

**Install:**

```bash
sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
```

**Enable kubelet.** It won't fully start yet (it needs the cluster to exist), but enabling it now means it starts automatically after `kubeadm init` or `kubeadm join`:

```bash
sudo systemctl enable kubelet
```

---

### 5.4 Initialise the Control Plane

> **Control plane node only (`cakers-cp-1`)**

This is the equivalent of running the OpenShift installer's control-plane phase. `kubeadm init` sets up the API server, etcd, the scheduler, and the controller manager — everything that *is* the Kubernetes control plane.

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.56.10
```

**What these flags do:**

- `--pod-network-cidr=10.244.0.0/16` — the IP range pods will get addresses from. The value `10.244.0.0/16` is what Flannel (the CNI we'll install next) expects. It must match.
- `--apiserver-advertise-address=192.168.56.10` — the IP the API server listens on and advertises to other nodes. Use the control plane node's IP, not `localhost`.

**This takes about 2 minutes.** At the end, the output contains two things you need:

1. **The `kubeadm join` command** — save this. You'll use it on each worker node. It looks like:
   ```
   kubeadm join 192.168.56.10:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
   ```

2. **Instructions to copy your kubeconfig** — run these now on the control plane node:
   ```bash
   mkdir -p $HOME/.kube
   sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
   sudo chown $(id -u):$(id -g) $HOME/.kube/config
   ```

Also copy the kubeconfig to your **laptop** so you can run `kubectl` and `flux` from there:

```bash
# On your laptop:
mkdir -p ~/.kube
scp cakers-cp-1.lab.local:/etc/kubernetes/admin.conf ~/.kube/config
# (adjust the hostname/IP and path if needed)
```

> **If you lose the join command**, regenerate it at any time from the control plane:
> ```bash
> kubeadm token create --print-join-command
> ```

---

### 5.5 Install a CNI (Flannel)

> **Control plane node only, but run immediately after init**

Without a CNI, pods cannot communicate with each other. This is why nodes show `NotReady` right after `kubeadm init` — Kubernetes is running, but networking isn't wired up yet.

> **OpenShift analogy:** In OpenShift, OVN-Kubernetes is the CNI and it comes pre-installed. Here you pick one and install it yourself.

Install Flannel — the simplest CNI that just works for a lab:

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

Flannel creates a `flannel.1` overlay network interface on each node and handles all pod-to-pod routing. It uses the `10.244.0.0/16` CIDR you specified in `kubeadm init`.

Wait for the control plane node to become ready (usually takes 30–60 seconds):

```bash
kubectl get nodes
# NAME                 STATUS   ROLES           AGE   VERSION
# cakers-cp-1          Ready    control-plane   2m    v1.32.x
```

---

### 5.6 Join the Worker Nodes

> **On each worker node: `cakers-worker-1`, `cakers-worker-2`, `cakers-worker-3`**

Run the `kubeadm join` command you saved from the init output. Prefix with `sudo`:

```bash
sudo kubeadm join 192.168.56.10:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

Run this on each worker. It takes 30–60 seconds per node. The node downloads its config from the control plane, starts kubelet, and registers itself.

---

### 5.7 Verify the Cluster

Run this from your laptop (or the control plane node):

```bash
kubectl get nodes -o wide
```

Expected output:

```
NAME                      STATUS   ROLES           AGE   VERSION    INTERNAL-IP      OS-IMAGE
cakers-cp-1.lab.local     Ready    control-plane   10m   v1.32.x    192.168.56.10    Rocky Linux 10.1
cakers-worker-1.lab.local Ready    <none>          5m    v1.32.x    192.168.56.11    Rocky Linux 10.1
cakers-worker-2.lab.local Ready    <none>          4m    v1.32.x    192.168.56.12    Rocky Linux 10.1
cakers-worker-3.lab.local Ready    <none>          3m    v1.32.x    192.168.56.13    Rocky Linux 10.1
```

All four nodes should show `Ready`. If any shows `NotReady`, the CNI hasn't finished starting on that node yet — wait another minute and check again.

```bash
kubectl get pods -n kube-system
# All should be Running or Completed
```

You now have a working Kubernetes cluster. On to Phase 2.

---

## 6. Phase 2: Prepare Nodes for Applications

### 6.1 Create hostPath directories

Artifactory and PostgreSQL need persistent storage. Rather than setting up a storage provisioner, this lab uses **hostPath volumes** — directories on the worker node's local filesystem that pods mount directly.

The directories must exist before Flux tries to deploy Artifactory, otherwise the PersistentVolumeClaims will be stuck in `Pending` and the pods will never start.

> **Run this on all worker nodes** (`cakers-worker-1`, `cakers-worker-2`, `cakers-worker-3`). The Kubernetes scheduler decides which node each pod lands on — because the hostPath PVs have no `nodeAffinity`, you cannot predict which worker will be chosen. Creating the directories everywhere avoids a startup failure if the pod doesn't land where you expected.

```bash
sudo mkdir -p /mnt/data/artifactory-data
sudo mkdir -p /mnt/data/postgres-data
sudo chmod 777 /mnt/data/artifactory-data
sudo chmod 777 /mnt/data/postgres-data
```

> **Why `chmod 777`?** Artifactory and PostgreSQL run as non-root users inside the container (UID 1030 and 1001 respectively). They need to write to these directories, but the directories are owned by root. `777` is the simplest fix for a lab. In production, you'd use `chown` with the specific UIDs.

---

### 6.2 Create the database credentials Secret

The Artifactory Helm chart includes a bundled PostgreSQL instance. By default, the chart generates a **random password on every Helm install or upgrade**. Because Flux reconciles the HelmRelease on a regular interval, this means the password in the cluster Secret gets silently replaced — while the on-disk PostgreSQL database still expects the original password. The result is `FATAL: password authentication failed` and every Artifactory sidecar crash-looping.

The fix is to create a Secret with fixed credentials and tell the HelmRelease to use them via `valuesFrom`. The Secret is created **imperatively and never committed to git** — it is the one piece of state that lives only in the cluster.

Run this once from your laptop (or anywhere with `kubectl` access):

```bash
kubectl create secret generic artifactory-db-credentials \
  -n artifactory \
  --from-literal=password="<choose-a-strong-password>" \
  --from-literal=postgresPassword="<choose-a-strong-postgres-password>"
```

> **These credentials are not stored in git.** If you tear down and rebuild the cluster you must re-run this command before bootstrapping Flux. If you lose the passwords, you will need to wipe the PostgreSQL data directory and reinitialise (see [Troubleshooting](#postgresql-password-mismatch)).

The HelmRelease in `apps/artifactory/helmrelease.yaml` references this Secret via `valuesFrom` — see the [file reference](#appsartifactoryhelmreleaseyaml) for details.

---

## 7. Phase 3: Bootstrap Flux (GitOps)

From this point on, you stop applying things manually. Flux takes over.

### Prerequisites on your laptop

- `kubectl` configured to talk to the cluster (done in Phase 1)
- `flux` CLI — install it with:
  ```bash
  brew install fluxcd/tap/flux      # macOS
  # or
  curl -s https://fluxcd.io/install.sh | sudo bash   # Linux
  ```
- A GitHub **Personal Access Token** with `repo` scope — create one at GitHub → Settings → Developer Settings → Personal access tokens

### Run the bootstrap

```bash
export GITHUB_TOKEN=<your-personal-access-token>

flux bootstrap github \
  --owner=chris-j-akers \
  --repository=gitops-testlab \
  --branch=main \
  --path=clusters/lab \
  --personal
```

**What each flag means:**

| Flag | Meaning |
|---|---|
| `--owner` | Your GitHub username |
| `--repository` | The repo Flux will watch — created if it doesn't exist |
| `--branch` | Branch Flux watches for changes |
| `--path` | The directory inside the repo Flux treats as the root of cluster config |
| `--personal` | Token belongs to a personal account, not a GitHub organisation |

**What bootstrap actually does, step by step:**

1. Creates the `flux-system` namespace in the cluster
2. Generates `gotk-components.yaml` — all Flux controller Deployments, CRDs, and RBAC rules
3. Generates `gotk-sync.yaml` — a `GitRepository` object (pointing at this repo) and a `Kustomization` object (pointing at `clusters/lab/`)
4. Applies both files to the cluster
5. Commits and pushes both files to this repo
6. Generates an SSH deploy key, adds it to the GitHub repo as a deploy key, and stores it in the cluster as a Secret called `flux-system` — this is how Flux authenticates to pull from GitHub

After bootstrap completes, **Flux is running and watching the repo**. It will immediately start reconciling everything under `clusters/lab/` — installing MetalLB, configuring it, and deploying Artifactory. The whole stack takes 5–10 minutes to fully come up.

Watch it happen in real time:

```bash
flux get kustomizations -A --watch
```

---

## 8. How GitOps Works Here

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your laptop                              │
│   edit YAML → git commit → git push → GitHub                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                │ SSH poll (every 1 minute)
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Flux (in flux-system namespace)              │
│                                                                 │
│  source-controller ──── watches GitRepository                  │
│       │                 detects new commits                     │
│       │ notifies                                                │
│       ▼                                                         │
│  kustomize-controller ── reads Kustomization objects           │
│       │                  applies resources in dependency order  │
│       │ creates/updates                                         │
│       ▼                                                         │
│  helm-controller ──── reads HelmRelease objects                │
│                        installs/upgrades Helm charts           │
└─────────────────────────────────────────────────────────────────┘
                                │
                                │ kubectl apply (internally)
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes cluster                           │
│   Namespaces, Deployments, Services, PVs, etc.                 │
└─────────────────────────────────────────────────────────────────┘
```

**Three Flux controllers do all the work:**

| Controller | Job |
|---|---|
| `source-controller` | Polls git repos and Helm chart repos for changes; caches downloaded artifacts locally |
| `kustomize-controller` | Reads `Kustomization` objects and applies the referenced YAML to the cluster |
| `helm-controller` | Reads `HelmRelease` objects and runs Helm install/upgrade/rollback |

### Two things called "Kustomization" — and why it's confusing

There are **two completely different things** called `Kustomization` in this setup:

| Kind | API group | What it is |
|---|---|---|
| `Kustomization` | `kustomize.config.k8s.io/v1beta1` | A plain kustomize manifest list — just says "include these files" |
| `Kustomization` | `kustomize.toolkit.fluxcd.io/v1` | A Flux CRD — tells the kustomize-controller to fetch and apply a path from git, with intervals, health checks, and `dependsOn` ordering |

In this repo, `clusters/lab/kustomization.yaml` is the first kind (a list). The files it lists — `infrastructure.yaml` and `apps.yaml` — contain the second kind (Flux objects that independently reconcile parts of the cluster). Every time you see a `Kustomization`, check the `apiVersion` to know which one you're dealing with.

---

## 9. Repository Structure

```
gitops-testlab/
│
├── clusters/
│   └── lab/                          # One directory per cluster
│       ├── kustomization.yaml        # [kustomize kind] list: points at infrastructure.yaml + apps.yaml
│       ├── infrastructure.yaml       # [Flux kind] three Kustomization objects for infra layers
│       ├── apps.yaml                 # [Flux kind] one Kustomization object for applications
│       └── flux-system/              # Flux's own config — managed by bootstrap, do not edit
│           ├── gotk-components.yaml  # All Flux controller manifests (~570KB, auto-generated)
│           ├── gotk-sync.yaml        # GitRepository + Kustomization pointing at this repo
│           └── kustomization.yaml    # [kustomize kind] lists gotk-components + gotk-sync
│
├── infrastructure/
│   ├── repositories/                 # HelmRepository objects (like `helm repo add`)
│   │   ├── jfrog.yaml
│   │   ├── metallb.yaml
│   │   └── kustomization.yaml
│   │
│   ├── controllers/                  # Helm charts that install controllers + their CRDs
│   │   ├── kustomization.yaml
│   │   └── metallb/
│   │       ├── namespace.yaml
│   │       ├── helmrelease.yaml
│   │       └── kustomization.yaml
│   │
│   └── configs/                      # CRD-based config (depends on controllers/ having run first)
│       ├── kustomization.yaml
│       └── metallb/
│           ├── metallb-config.yaml
│           └── kustomization.yaml
│
└── apps/
    ├── kustomization.yaml            # [kustomize kind] list of all apps
    └── artifactory/
        ├── namespace.yaml
        ├── artifactory-pv.yaml
        ├── postgresql-pv.yaml
        ├── helmrelease.yaml
        └── kustomization.yaml
```

### Why this layout?

**`clusters/`** contains one directory per cluster. Everything in `clusters/lab/` is specific to this cluster. The `infrastructure/` and `apps/` directories are cluster-agnostic — a second cluster (`clusters/staging/`) could reference the same definitions with different overlays.

**`infrastructure/` is split into three layers** because of a hard ordering constraint:

```
repositories/ ← controllers/ ← configs/
```

- `repositories/` — registers Helm chart sources. Everything depends on these existing first.
- `controllers/` — installs controllers (MetalLB) via Helm. As a side effect, this installs the MetalLB **Custom Resource Definitions** (CRDs) into the cluster.
- `configs/` — creates objects whose *types* were just installed by controllers. This layer cannot run before `controllers/` finishes, because the CRD types won't exist yet and Kubernetes will reject the objects.

**`apps/`** waits for the entire infrastructure chain. Artifactory needs MetalLB running (for its `LoadBalancer` Service IP) and the IP pool configured (so MetalLB knows which IPs to hand out).

---

## 10. File-by-File Reference

### `clusters/lab/flux-system/`

These files are managed entirely by `flux bootstrap`. The `gotk-sync.yaml` Flux `Kustomization` points `path: ./clusters/lab`, which makes the kustomize-controller read `clusters/lab/kustomization.yaml` on every sync — that file is the entry point for everything else.

**Do not manually edit files in `flux-system/`.** To upgrade Flux, run `flux bootstrap` again with the newer Flux version.

---

### `clusters/lab/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - infrastructure.yaml
  - apps.yaml
```

This is a **kustomize** Kustomization (not a Flux one — note the `apiVersion`). Its only job is to tell kustomize: "when processing this directory, also include these two files." It makes no decisions about ordering or health — that's handled by the Flux Kustomization objects inside those files.

---

### `clusters/lab/infrastructure.yaml`

Contains three **Flux** `Kustomization` objects, each independently managing a layer of infrastructure, with `dependsOn` enforcing the correct order:

```yaml
# 1. Register Helm repositories — no dependencies, runs immediately
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-repositories
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 1m
  timeout: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure/repositories
  prune: true

---
# 2. Install controllers — waits for repositories to be ready
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-controllers
  namespace: flux-system
spec:
  dependsOn:
    - name: infra-repositories
  interval: 1h
  retryInterval: 1m
  timeout: 10m             # controllers take time; Helm waits for pods to be healthy
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure/controllers
  prune: true
  wait: true               # don't mark this ready until all resources are healthy

---
# 3. Apply CRD-based config — waits for controllers to have installed the CRDs
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-configs
  namespace: flux-system
spec:
  dependsOn:
    - name: infra-controllers
  interval: 1h
  retryInterval: 1m
  timeout: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure/configs
  prune: true
```

**Why `dependsOn` is critical here:** `IPAddressPool` and `L2Advertisement` (in `configs/`) are custom resource types that are installed by the MetalLB Helm chart (in `controllers/`). If `configs/` were applied before MetalLB was installed, Kubernetes would reject the objects with `no matches for kind IPAddressPool`. `dependsOn` prevents this race condition.

**`wait: true` on `infra-controllers`** tells the kustomize-controller to wait until all resources — including the MetalLB HelmRelease — are fully healthy before marking this Kustomization as ready. Without `wait: true`, `infra-configs` could start immediately after the HelmRelease *object* is created, before MetalLB has actually finished deploying. The CRDs wouldn't exist yet and the config apply would fail.

---

### `clusters/lab/apps.yaml`

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  dependsOn:
    - name: infra-controllers    # MetalLB must be running to handle LoadBalancer Services
    - name: infra-configs        # IP pool must exist before a Service can get an IP
  interval: 30m
  retryInterval: 1m
  timeout: 15m                   # Artifactory takes several minutes to start cold
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps
  prune: true
```

Apps depend on both `infra-controllers` and `infra-configs` because a `LoadBalancer` Service needs MetalLB to be running *and* an `IPAddressPool` to exist. If either is missing, MetalLB won't assign an IP and the Service will sit in `<pending>` forever.

---

### `infrastructure/repositories/`

Before the helm-controller can install a chart, the source-controller needs to know where to find it. `HelmRepository` objects are the GitOps equivalent of `helm repo add`.

**`jfrog.yaml`** — the chart repo for Artifactory:
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: jfrog
  namespace: flux-system
spec:
  interval: 10m
  url: https://charts.jfrog.io/
```

**`metallb.yaml`** — the chart repo for MetalLB:
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: metallb
  namespace: flux-system
spec:
  interval: 1h
  url: https://metallb.github.io/metallb
```

All `HelmRepository` objects live in `flux-system` — that's where the source-controller manages them. The charts they serve can still be deployed to any namespace.

---

### `infrastructure/controllers/`

Controllers are Helm-installed components that extend Kubernetes with new capabilities. They live in a separate layer from `configs/` because they install CRDs — which must exist before anything tries to create objects of those custom types.

**`controllers/metallb/namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
```

Although the HelmRelease has `install.createNamespace: true` as a safety net, declaring the namespace in git means Flux owns it and ensures it exists independently of the Helm install lifecycle.

**`controllers/metallb/helmrelease.yaml`**
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: metallb
  namespace: metallb-system
spec:
  interval: 15m
  chart:
    spec:
      chart: metallb
      version: "0.15.3"    # always pin versions — unpinned = surprise upgrades
      sourceRef:
        kind: HelmRepository
        name: metallb        # must match HelmRepository metadata.name exactly
        namespace: flux-system
  install:
    createNamespace: true
    crds: CreateReplace      # install CRDs on first install, replace (update) on upgrade
  upgrade:
    crds: CreateReplace
```

**`crds: CreateReplace`** is essential. Without it, Flux installs the CRDs on first install but never updates them when you bump the chart version. This leads to CRD/API drift and broken reconciliation as MetalLB evolves.

---

### `infrastructure/configs/`

Config objects use the CRD types that were installed by the controllers layer. They cannot be applied before their CRDs exist — hence the `dependsOn` in `infrastructure.yaml`.

**`configs/metallb/metallb-config.yaml`**
```yaml
# Defines the pool of IPs MetalLB is allowed to hand out
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
    - 192.168.56.200-192.168.56.210

---
# Tells MetalLB to advertise those IPs via ARP (layer2 mode)
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
    - default    # must match IPAddressPool.metadata.name above
```

**Layer2 mode** works by having one MetalLB speaker pod respond to ARP requests for any IP in the pool. Traffic arrives at that node and is forwarded to the Service — no BGP or router config required. It just works on a standard LAN.

The IP range must:
- Be in the same subnet as the nodes (`192.168.56.0/24`)
- Not overlap with your router/DHCP server's range

**Why CRDs, not a ConfigMap?** MetalLB dropped ConfigMap-based config entirely at v0.13. v0.15 only supports CRD-based config.

---

### `apps/`

**`apps/kustomization.yaml`** (kustomize kind):
```yaml
resources:
  - artifactory/
```

The `apps` Flux Kustomization in `clusters/lab/apps.yaml` points `path` at `./apps`. It reads this file, which lists each application subdirectory. Adding a new app means creating a new subdirectory and listing it here — no changes to `clusters/lab/` required.

---

**`apps/artifactory/artifactory-pv.yaml`** — storage for Artifactory data
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: artifactory-pv-0
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  persistentVolumeReclaimPolicy: Retain   # keep data even if the PVC is deleted
  storageClassName: ""                    # empty = static provisioning, no StorageClass
  hostPath:
    path: /mnt/data/artifactory-data      # must exist on the node (see Phase 2)
```

**`storageClassName: ""`** is critical. If this field is absent or set to a real StorageClass name, Kubernetes will try dynamic provisioning instead of binding to this manually-defined PV. The empty string explicitly opts out of dynamic provisioning.

**How PV binding works:** The Artifactory Helm chart creates a PVC requesting `20Gi`, `ReadWriteOnce`, and `storageClassName: ""`. Kubernetes searches for a PV matching all three criteria and binds them. If no matching PV exists, the PVC stays `Pending` and the pod never starts.

---

**`apps/artifactory/postgresql-pv.yaml`** — storage for Artifactory's database
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgres-pv-0
spec:
  capacity:
    storage: 200Gi        # must be >= the PVC the chart creates (200Gi)
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /mnt/data/postgres-data
```

Same pattern as the Artifactory PV. The bundled PostgreSQL sub-chart creates a PVC named `data-artifactory-oss-postgresql-0` requesting `200Gi`. This PV satisfies that claim.

> To inspect what a chart's PVCs request: `helm show values artifactory-oss --repo https://charts.jfrog.io` and look for `postgresql.primary.persistence`. Or after first install: `kubectl get pvc -n artifactory -o yaml`.

---

**`apps/artifactory/helmrelease.yaml`**
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: artifactory-oss
  namespace: artifactory
spec:
  interval: 5m
  chart:
    spec:
      chart: artifactory-oss
      version: "107.133.12"   # chart version 107.x.x = Artifactory app version 7.x.x
      sourceRef:
        kind: HelmRepository
        name: jfrog
        namespace: flux-system
  valuesFrom:
    - kind: Secret
      name: artifactory-db-credentials
      valuesKey: password
      targetPath: postgresql.auth.password
    - kind: Secret
      name: artifactory-db-credentials
      valuesKey: postgresPassword
      targetPath: postgresql.auth.postgresPassword
```

**`interval: 5m`** means any manual `helm upgrade` on the cluster will be reverted within 5 minutes. This enforces the GitOps contract: all changes go through git, not the CLI.

**`valuesFrom`** pulls values from a Kubernetes Secret and injects them into the Helm chart at the specified `targetPath`. This is how Flux passes sensitive config to a chart without putting secrets in git. The Secret `artifactory-db-credentials` must already exist in the `artifactory` namespace before the HelmRelease reconciles — create it manually as described in [Phase 2.2](#62-create-the-database-credentials-secret).

The two `targetPath` values map to the Bitnami PostgreSQL subchart's configuration:
- `postgresql.auth.password` — the password for the `artifactory` database user
- `postgresql.auth.postgresPassword` — the password for the `postgres` superuser

By pinning these here, every Flux reconcile passes the same credentials to Helm rather than letting the chart generate new random ones.

---

## 11. How the Files Relate to Each Other

### The reconciliation chain

```
gotk-sync.yaml (Flux Kustomization "flux-system")
  │
  │  path: ./clusters/lab
  ▼
clusters/lab/kustomization.yaml  [kustomize kind — just a list]
  │
  ├── infrastructure.yaml  ─── creates three Flux Kustomization objects:
  │                               • infra-repositories
  │                               • infra-controllers  (dependsOn: infra-repositories)
  │                               • infra-configs      (dependsOn: infra-controllers)
  │
  └── apps.yaml  ─────────── creates one Flux Kustomization object:
                                  • apps  (dependsOn: infra-controllers, infra-configs)
```

### What each Flux Kustomization deploys

```
infra-repositories
  path: ./infrastructure/repositories
    → HelmRepository "jfrog"    (source for Artifactory chart)
    → HelmRepository "metallb"  (source for MetalLB chart)

infra-controllers  [waits for: infra-repositories]
  path: ./infrastructure/controllers
    → Namespace "metallb-system"
    → HelmRelease "metallb"
         → helm-controller installs MetalLB chart
              → MetalLB pods running
              → CRDs installed: IPAddressPool, L2Advertisement, etc.

infra-configs  [waits for: infra-controllers + wait:true]
  path: ./infrastructure/configs
    → IPAddressPool "default"       (192.168.56.200–210)
    → L2Advertisement "default"     (announce via ARP)

apps  [waits for: infra-controllers + infra-configs]
  path: ./apps
    → Namespace "artifactory"
    → PersistentVolume "artifactory-pv-0"
    → PersistentVolume "postgres-pv-0"
    → HelmRelease "artifactory-oss"
         → helm-controller installs artifactory-oss chart
              → PVCs bound to PVs above
              → Service "artifactory-oss-artifactory-nginx" (type: LoadBalancer)
                   → MetalLB assigns 192.168.56.200
              → Artifactory reachable at http://192.168.56.200
```

### Cross-references that must stay consistent

If any of these get out of sync, things silently break:

| This field | Must match |
|---|---|
| `HelmRelease (metallb).spec.chart.spec.sourceRef.name: metallb` | `HelmRepository.metadata.name: metallb` |
| `HelmRelease (artifactory-oss).spec.chart.spec.sourceRef.name: jfrog` | `HelmRepository.metadata.name: jfrog` |
| Both `sourceRef.namespace: flux-system` | `HelmRepository.metadata.namespace: flux-system` |
| `PersistentVolume.spec.storageClassName: ""` | PVC `storageClassName: ""` (chart default) |
| `PersistentVolume.spec.capacity.storage: 200Gi` | PVC requested size (chart default for postgres) |
| `IPAddressPool.metadata.name: default` | `L2Advertisement.spec.ipAddressPools[0]: default` |
| `infra-controllers` in `apps.yaml dependsOn` | `Kustomization.metadata.name: infra-controllers` in `infrastructure.yaml` |

---

## 12. Verification Commands

Run these after a rebuild to confirm everything is healthy. `flux` commands can run from your laptop or from `cakers-cp-1`.

**Check all Flux Kustomizations are healthy:**
```bash
flux get kustomizations -A
# Should show: flux-system, infra-repositories, infra-controllers, infra-configs, apps
# All READY=True, SUSPENDED=False
```

**Check git is synced to the latest commit:**
```bash
flux get source git flux-system -n flux-system
# REVISION should match: git log --oneline -1
```

**Check HelmRepositories:**
```bash
flux get sources helm -A
# jfrog and metallb should be READY=True
```

**Check HelmReleases:**
```bash
kubectl get helmrelease -A
# Both artifactory-oss and metallb should show READY=True
```

**Check Artifactory pods:**
```bash
kubectl get pods -n artifactory
# artifactory-oss-0                        9/9 Running
# artifactory-oss-artifactory-nginx-*      1/1 Running
# artifactory-oss-postgresql-0             1/1 Running
```

**Check PVs are bound:**
```bash
kubectl get pv
# artifactory-pv-0 and postgres-pv-0 should show STATUS: Bound
```

**Check MetalLB assigned an IP:**
```bash
kubectl get svc -n artifactory
# artifactory-oss-artifactory-nginx  EXTERNAL-IP: 192.168.56.200
```

**Access Artifactory:**
```
http://192.168.56.200
Default credentials: admin / password  (change immediately after first login)
```

---

## 13. Troubleshooting

### Flux hasn't picked up a push

```bash
flux get source git flux-system -n flux-system
```

Check `REVISION` matches your latest git commit SHA. Flux polls every 1 minute. Force an immediate sync:

```bash
flux reconcile source git flux-system -n flux-system
```

### A Kustomization is stuck READY=False

```bash
flux get kustomizations -A
flux describe kustomization <name> -n flux-system
```

If the message says `dependsOn condition not met`, the upstream Kustomization it depends on isn't ready yet. Fix the upstream first, then this one will unblock automatically.

### HelmRelease stuck with `RetriesExceeded`

Flux stops retrying after exhausting its configured retry count. The cluster resources may actually be healthy — it just hit a timeout during startup. Reset the retry counter:

```bash
flux suspend helmrelease <name> -n <namespace>
flux resume helmrelease <name> -n <namespace>
```

Or force a reconcile (also resets retries):

```bash
flux reconcile helmrelease <name> -n <namespace> --with-source
```

If the `flux` CLI isn't available, use `kubectl` annotations:

```bash
kubectl annotate helmrelease <name> -n <namespace> \
  reconcile.fluxcd.io/requestedAt="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --overwrite
```

### PVC stuck in Pending

```bash
kubectl describe pvc <name> -n <namespace>
```

Common causes:
- The `hostPath` directory doesn't exist on the node → create it (see Phase 2)
- `storageClassName` mismatch → both PV and PVC must have `storageClassName: ""`
- Size mismatch → PV `capacity.storage` must be >= PVC requested size

### MetalLB not assigning IPs

```bash
kubectl get pods -n metallb-system
kubectl logs -n metallb-system -l app=metallb,component=speaker
```

Common causes:
- `infra-configs` applied before `infra-controllers` finished → wait for controllers, then `flux reconcile kustomization infra-configs -n flux-system`
- IP range overlaps with your DHCP server
- `L2Advertisement.spec.ipAddressPools` name doesn't match `IPAddressPool.metadata.name`

### PostgreSQL password mismatch

**Symptoms:** Multiple Artifactory sidecars (`topology`, `metadata`, `access`) in `CrashLoopBackOff`. Logs show `FATAL: password authentication failed for user "artifactory"`.

**Cause:** The Bitnami PostgreSQL subchart generates a random password on every Helm install or upgrade. If the `artifactory-db-credentials` Secret is missing, Flux lets the chart manage its own secret (`artifactory-oss-postgresql`). On the next reconcile, the chart regenerates a new random value in that secret — but the PostgreSQL data directory was initialised with the original password. The two are now out of sync.

**Diagnose:**
```bash
# Decode the current secret
kubectl get secret artifactory-oss-postgresql -n artifactory \
  -o jsonpath='{.data}' | \
  python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k+':', base64.b64decode(v).decode()) for k,v in d.items()]"

# Test if the password actually works
kubectl exec -n artifactory artifactory-oss-postgresql-0 -- \
  env PGPASSWORD=<password-from-above> psql -U artifactory -d artifactory -c "SELECT 1;"
```

**Fix:**

1. Make sure `artifactory-db-credentials` exists with your chosen passwords (create it if it doesn't — see Phase 2.2):
   ```bash
   kubectl create secret generic artifactory-db-credentials \
     -n artifactory \
     --from-literal=password="<your-password>" \
     --from-literal=postgresPassword="<your-postgres-password>"
   ```

2. Scale down everything so no process is writing to PostgreSQL:
   ```bash
   kubectl scale statefulset artifactory-oss -n artifactory --replicas=0
   kubectl scale statefulset artifactory-oss-postgresql -n artifactory --replicas=0
   kubectl wait --for=delete pod/artifactory-oss-postgresql-0 -n artifactory --timeout=60s
   ```

3. Wipe the stale PostgreSQL data directory on whichever worker the postgres pod was running on (`kubectl get pods -n artifactory -o wide` to find the node):
   ```bash
   ssh kubeadmin@<worker-node> "sudo rm -rf /mnt/data/postgres-data/*"
   ```

4. Scale back up — PostgreSQL will reinitialise from scratch using your credentials from `artifactory-db-credentials`:
   ```bash
   kubectl scale statefulset artifactory-oss-postgresql -n artifactory --replicas=1
   kubectl wait --for=condition=ready pod/artifactory-oss-postgresql-0 -n artifactory --timeout=120s
   kubectl scale statefulset artifactory-oss -n artifactory --replicas=1
   ```

5. Force a Flux reconcile to apply the latest HelmRelease spec:
   ```bash
   ssh kubeadmin@cakers-cp-1.lab.local \
     "flux reconcile helmrelease artifactory-oss -n artifactory --with-source"
   ```

### Artifactory startup probe failures

Artifactory takes 2–5 minutes to initialise from a cold start. Startup probe failures in the first few minutes are normal. Only investigate if they persist beyond 10 minutes:

```bash
kubectl describe pod artifactory-oss-0 -n artifactory
kubectl logs artifactory-oss-0 -n artifactory -c artifactory
```

### Node showing NotReady after join

Usually the CNI hasn't fully started on that node yet. Check:

```bash
kubectl get pods -n kube-flannel
kubectl describe node <node-name>
```

If the Flannel pod on that node is `CrashLoopBackOff`, check it wasn't already configured from a previous cluster reset — run the teardown commands from Section 4 on that node and re-join.

---

## 14. Future: Image Tag Automation

The goal: push a new image to Artifactory → Flux detects the new tag → updates the image tag in a HelmRelease → auto-deploys.

### What's missing

The current `gotk-components.yaml` deploys four controllers: `source-controller`, `kustomize-controller`, `helm-controller`, and `notification-controller`. Image automation needs two more:

| Controller | Job |
|---|---|
| `image-reflector-controller` | Scans a container registry and fetches available image tags |
| `image-automation-controller` | Commits updated image tags back to git |

### Step 1: Re-bootstrap with extra components

```bash
flux bootstrap github \
  --owner=chris-j-akers \
  --repository=gitops-testlab \
  --branch=main \
  --path=clusters/lab \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller
```

This regenerates `gotk-components.yaml` with the two extra controllers and pushes the update.

### Step 2: Add image automation resources

For each image you want to track, create three objects under `apps/<appname>/`:

**`image-repository.yaml`** — scan Artifactory for new tags:
```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: myapp
  namespace: flux-system
spec:
  image: 192.168.56.200/myapp/myapp
  interval: 1m
  secretRef:
    name: artifactory-regcred
```

**`image-policy.yaml`** — define which tag to select:
```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: myapp
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: myapp
  policy:
    semver:
      range: ">=1.0.0"
```

**`image-update-automation.yaml`** — commit the selected tag back to git:
```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta1
kind: ImageUpdateAutomation
metadata:
  name: myapp
  namespace: flux-system
spec:
  interval: 1m
  sourceRef:
    kind: GitRepository
    name: flux-system
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: Flux
        email: flux@lab.local
      messageTemplate: "chore: update myapp to {{range .Updated.Images}}{{println .}}{{end}}"
    push:
      branch: main
  update:
    path: ./apps/myapp
    strategy: Setters
```

### Step 3: Mark the field to update

Add a marker comment next to the image tag in the HelmRelease `values:`:

```yaml
spec:
  values:
    image:
      repository: 192.168.56.200/myapp/myapp
      tag: "1.0.0" # {"$imagepolicy": "flux-system:myapp:tag"}
```

The `image-automation-controller` reads this marker, replaces the tag with whatever `ImagePolicy` selected, and commits the change. The `GitRepository` detects the new commit within 1 minute, the `apps` Kustomization reconciles, the HelmRelease upgrades — and the loop is complete.
