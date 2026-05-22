# GitOps Lab Runbook

A complete guide to rebuilding this environment from scratch: what every file does, why each setting exists, and how everything connects.

---

## Table of Contents

1. [What This Environment Is](#1-what-this-environment-is)
2. [Cluster Overview](#2-cluster-overview)
3. [How GitOps Works Here](#3-how-gitops-works-here)
4. [Repository Structure](#4-repository-structure)
5. [Step-by-Step: Building From Scratch](#5-step-by-step-building-from-scratch)
   - [5.1 Prerequisites](#51-prerequisites)
   - [5.2 Prepare the Nodes](#52-prepare-the-nodes)
   - [5.3 Bootstrap Flux](#53-bootstrap-flux)
   - [5.4 What Flux Bootstrap Did](#54-what-flux-bootstrap-did)
6. [File-by-File Reference](#6-file-by-file-reference)
   - [clusters/lab/flux-system/](#clusterslab-flux-system)
   - [clusters/lab/kustomization.yaml](#clusterslabkustomizationyaml)
   - [clusters/lab/infrastructure.yaml](#clusterslabinfrastructureyaml)
   - [clusters/lab/apps.yaml](#clusterslabappsyaml)
   - [infrastructure/repositories/](#infrastructurerepositories)
   - [infrastructure/controllers/](#infrastructurecontrollers)
   - [infrastructure/configs/](#infrastructureconfigs)
   - [apps/](#apps)
7. [How the Files Relate to Each Other](#7-how-the-files-relate-to-each-other)
8. [Verification Commands](#8-verification-commands)
9. [Troubleshooting](#9-troubleshooting)
10. [Future: Image Tag Automation](#10-future-image-tag-automation)

---

## 1. What This Environment Is

This is a **GitOps lab** — a Kubernetes cluster where the desired state of every application and piece of infrastructure is declared in YAML files in this git repository, and a tool called **Flux** watches the repository and automatically applies any changes to the cluster.

The core principle is: **git is the single source of truth**. You never `kubectl apply` anything directly in production. Instead, you commit a change, push it, and Flux reconciles the cluster to match.

This lab runs:
- **Flux v2.3.0** — the GitOps engine
- **MetalLB v0.15.3** — a software load balancer (gives `LoadBalancer`-type services real IPs on a bare-metal cluster)
- **Artifactory OSS v107.133.12** — a self-hosted artifact registry (for Docker images, Helm charts, packages, etc.)

---

## 2. Cluster Overview

| Node | Role | IP |
|---|---|---|
| `cakers-cp-1.lab.local` | Control plane | `192.168.56.10` |
| `cakers-worker-1.lab.local` | Worker | `192.168.56.11` |
| `cakers-worker-2.lab.local` | Worker | `192.168.56.12` |
| `cakers-worker-3.lab.local` | Worker | `192.168.56.13` |

- **Kubernetes:** v1.32.13
- **Container runtime:** containerd v2.2.1
- **OS:** Rocky Linux 10.1
- **CNI (network plugin):** required before Flux bootstrap (Flannel, Calico, Cilium, etc.)
- **MetalLB IP pool:** `192.168.56.200–192.168.56.210` (layer2 mode, same subnet as nodes)

---

## 3. How GitOps Works Here

Understanding this loop is the key to understanding every file in this repo.

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your laptop                              │
│   edit YAML → git commit → git push → GitHub                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                │ SSH (every 1 minute)
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
                                │ kubectl apply
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes cluster                           │
│   Namespaces, Deployments, Services, PVs, etc.                 │
└─────────────────────────────────────────────────────────────────┘
```

**Three controllers do all the work:**

| Controller | Job |
|---|---|
| `source-controller` | Polls git repos and Helm chart repos for changes; stores downloaded artifacts |
| `kustomize-controller` | Reads `Kustomization` objects and applies the referenced YAML to the cluster |
| `helm-controller` | Reads `HelmRelease` objects and runs Helm install/upgrade/rollback |

### Two types of Kustomization

This is a common source of confusion. There are **two completely different things** called `Kustomization` in this setup:

| Kind | API group | What it is |
|---|---|---|
| `Kustomization` | `kustomize.config.k8s.io/v1beta1` | A plain kustomize manifest list — just lists which YAML files to include |
| `Kustomization` | `kustomize.toolkit.fluxcd.io/v1` | A Flux CRD — tells the kustomize-controller to fetch and apply a path from git, with intervals, health checks, and `dependsOn` |

In this repo, `clusters/lab/kustomization.yaml` is the first kind (a list). The files it lists — `infrastructure.yaml` and `apps.yaml` — contain the second kind (Flux objects that independently reconcile parts of the cluster).

---

## 4. Repository Structure

```
gitops-testlab/
│
├── clusters/
│   └── lab/                          # One directory per cluster
│       ├── kustomization.yaml        # Kustomize list: points at infrastructure.yaml + apps.yaml
│       ├── infrastructure.yaml       # Flux Kustomization objects for infrastructure (with dependsOn)
│       ├── apps.yaml                 # Flux Kustomization object for apps (dependsOn infra)
│       └── flux-system/              # Flux's own config — managed by bootstrap, do not edit
│           ├── gotk-components.yaml
│           ├── gotk-sync.yaml
│           └── kustomization.yaml
│
├── infrastructure/
│   ├── repositories/                 # Helm chart registries (HelmRepository objects)
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
│   └── configs/                      # CRD-based config objects (depend on controllers/)
│       ├── kustomization.yaml
│       └── metallb/
│           ├── metallb-config.yaml
│           └── kustomization.yaml
│
└── apps/
    ├── kustomization.yaml            # Top-level list of all apps
    └── artifactory/
        ├── namespace.yaml
        ├── artifactory-pv.yaml
        ├── postgresql-pv.yaml
        ├── helmrelease.yaml
        └── kustomization.yaml
```

### Why this layout?

**`clusters/`** contains one directory per cluster. Everything in `clusters/lab/` is specific to this cluster. The `infrastructure/` and `apps/` directories are cluster-agnostic — if you added a second cluster (`clusters/staging/`), it could reference the same infrastructure and app definitions using overlays.

**`infrastructure/` is split into three layers** with an explicit dependency chain:

```
repositories/ ← controllers/ ← configs/
```

- `repositories/` registers Helm chart sources. Everything else depends on these existing first.
- `controllers/` installs the controllers themselves via Helm. These install CRDs (custom resource types) into the cluster as a side effect.
- `configs/` creates objects that *use* those CRDs. This layer cannot be applied before `controllers/` has finished, because the CRD types won't exist yet.

**`apps/`** sits behind the full infrastructure dependency chain. Apps depend on load balancers, registries, and config being ready before they deploy.

---

## 5. Step-by-Step: Building From Scratch

### 5.1 Prerequisites

On your **laptop/workstation** you need:
- `kubectl` configured to talk to the cluster
- `flux` CLI (`brew install fluxcd/tap/flux` or see [fluxcd.io](https://fluxcd.io/flux/installation/))
- A GitHub account and a **Personal Access Token** with `repo` scope
- `git` configured with SSH keys for GitHub

On the **cluster nodes** you need:
- Kubernetes already running (kubeadm, k3s, etc.)
- A CNI plugin installed (Flannel, Calico, Cilium — Kubernetes won't schedule pods without one)
- The nodes able to reach the internet (to pull images from Docker Hub, JFrog registry, GitHub)

### 5.2 Prepare the Nodes

Artifactory and PostgreSQL use **hostPath** persistent volumes — directories on the worker node's local filesystem. These must exist before Flux tries to deploy Artifactory, otherwise the pods will be stuck in `Pending`.

Run this on **whichever worker node will host the Artifactory pod** (in this lab, `cakers-worker-1`):

```bash
sudo mkdir -p /mnt/data/artifactory-data
sudo mkdir -p /mnt/data/postgres-data
sudo chmod 777 /mnt/data/artifactory-data
sudo chmod 777 /mnt/data/postgres-data
```

> **Why `chmod 777`?** Artifactory and PostgreSQL run as non-root users inside the container (uid 1030 and 1001 respectively). The hostPath directories need to be writable by those UIDs. In a production environment you'd set specific ownership; for a lab, `777` is simpler.

### 5.3 Bootstrap Flux

Bootstrapping installs Flux into the cluster **and** sets up this git repo as the source of truth in one command. Run this on your laptop:

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
| `--owner` | Your GitHub username (or org name) |
| `--repository` | The repo name — will be created if it doesn't exist |
| `--branch` | Branch Flux will watch |
| `--path` | The directory inside the repo Flux treats as the root of cluster config |
| `--personal` | Token belongs to a personal account (not an organisation) |

**What bootstrap actually does:**
1. Creates the `flux-system` namespace in the cluster
2. Generates `gotk-components.yaml` (all Flux controller manifests) and `gotk-sync.yaml` (the `GitRepository` and `Kustomization` pointing at this repo)
3. Applies them to the cluster
4. Commits and pushes both files to this repo
5. Generates a deploy key, adds it to the GitHub repo, and stores it as a Kubernetes Secret called `flux-system` — this is how Flux authenticates over SSH

After bootstrap, Flux is running and watching the repo. From this point on, **everything is done by committing YAML**.

### 5.4 What Flux Bootstrap Did

Bootstrap created two files under `clusters/lab/flux-system/`:

**`gotk-sync.yaml`** — tells Flux where to find its own config:
```yaml
# GitRepository: where is the git repo?
kind: GitRepository
spec:
  interval: 1m0s          # check for new commits every minute
  ref:
    branch: main
  secretRef:
    name: flux-system     # the deploy key Secret bootstrap created
  url: ssh://git@github.com/chris-j-akers/gitops-testlab

# Kustomization: what path in the repo to apply?
kind: Kustomization
spec:
  interval: 10m0s         # re-apply everything every 10 minutes (drift correction)
  path: ./clusters/lab    # start here when reading the repo
  prune: true             # delete cluster objects that are removed from git
  sourceRef:
    kind: GitRepository
    name: flux-system
```

**`gotk-components.yaml`** — the actual Flux controller Deployments, CRDs, RBAC rules, and NetworkPolicies. This file is ~570KB and auto-generated. **Do not manually edit it.** To upgrade Flux, run `flux bootstrap` again with the newer version.

---

## 6. File-by-File Reference

### `clusters/lab/flux-system/`

These files are managed by `flux bootstrap`. The `gotk-sync.yaml` Flux `Kustomization` has `path: ./clusters/lab`, which causes the kustomize-controller to read `clusters/lab/kustomization.yaml` on every sync. That is the entry point for everything else.

---

### `clusters/lab/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - infrastructure.yaml
  - apps.yaml
```

This is a **kustomize** `Kustomization` (not a Flux one). Its sole job is to tell kustomize which files to include when the kustomize-controller processes this directory. It no longer points directly at infrastructure paths — instead it lists the two Flux `Kustomization` definition files that sit alongside it. Those Flux objects then independently manage their respective parts of the cluster.

---

### `clusters/lab/infrastructure.yaml`

This file contains three **Flux** `Kustomization` objects. Each one instructs the kustomize-controller to independently reconcile a path in the repo, with explicit ordering enforced by `dependsOn`.

```yaml
# 1. Register Helm repositories — no dependencies
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

# 2. Install controllers (MetalLB, etc.) — must come after repositories
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-controllers
  namespace: flux-system
spec:
  dependsOn:
    - name: infra-repositories   # wait until HelmRepositories are ready
  interval: 1h
  retryInterval: 1m
  timeout: 10m                   # controllers take time; Helm waits for pods
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure/controllers
  prune: true
  wait: true                     # don't mark ready until all resources are healthy

# 3. Apply CRD-based config — must come after controllers have installed the CRDs
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-configs
  namespace: flux-system
spec:
  dependsOn:
    - name: infra-controllers    # wait until MetalLB (and its CRDs) are installed
  interval: 1h
  retryInterval: 1m
  timeout: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure/configs
  prune: true
```

**Why `dependsOn` matters here:** `IPAddressPool` and `L2Advertisement` (in `configs/`) are custom resource types installed by the MetalLB Helm chart (in `controllers/`). If `configs/` were applied before MetalLB was installed, Kubernetes would reject the objects with "no matches for kind IPAddressPool". `dependsOn` prevents this.

**`wait: true` on `infra-controllers`** tells the kustomize-controller to wait until all resources in that Kustomization (including the MetalLB HelmRelease) report as healthy before marking it done. Without this, `infra-configs` could start immediately after the HelmRelease object is *created*, before MetalLB has actually finished installing.

**`interval: 1h`** — infrastructure changes rarely. Checking every hour is enough. The 10-minute drift-correction interval from `gotk-sync.yaml` already re-applies `clusters/lab/`, which creates/updates these Kustomization objects themselves. The `interval` here controls how often the kustomize-controller re-applies the infrastructure paths even if nothing in git changed.

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
    - name: infra-controllers    # MetalLB must be running (LoadBalancer IPs)
    - name: infra-configs        # IP pools must exist before Services get IPs
  interval: 30m
  retryInterval: 1m
  timeout: 15m                   # Artifactory takes several minutes to start
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps
  prune: true
```

Apps depend on both `infra-controllers` and `infra-configs` because an app's `LoadBalancer` Service needs MetalLB to be running *and* an `IPAddressPool` to exist before it can receive an IP address.

**`interval: 30m`** — apps reconcile less often than infrastructure. Changes to app config (e.g. image tag updates) will still be picked up quickly because the `flux-system` Kustomization re-applies `clusters/lab/` every 10 minutes, updating the `apps` Kustomization object itself, which triggers an immediate reconcile.

---

### `infrastructure/repositories/`

Before the helm-controller can install a chart, the source-controller needs to know where to find it. `HelmRepository` objects are like `helm repo add`.

**`jfrog.yaml`**
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: jfrog
  namespace: flux-system    # HelmRepositories always live in flux-system
spec:
  interval: 10m             # re-fetch the chart index every 10 minutes
  url: https://charts.jfrog.io/
```

**`metallb.yaml`**
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: metallb
  namespace: flux-system
spec:
  interval: 1h              # MetalLB releases infrequently; 1h is sufficient
  url: https://metallb.github.io/metallb
```

**Why `namespace: flux-system`?** All source objects (`HelmRepository`, `GitRepository`, `OCIRepository`) live in `flux-system` by convention because that is where the source-controller manages them. Charts pulled from these repositories can still be *deployed* to other namespaces.

**Why `apiVersion: source.toolkit.fluxcd.io/v1`?** This is the stable, generally-available API. The older `v1beta2` is deprecated and should not be used in new resources.

---

### `infrastructure/controllers/`

Controllers are Helm-installed components that extend Kubernetes. They are separated from `configs/` because they install CRDs — which must exist before anything tries to create objects of those custom types.

**`kustomization.yaml`** (top-level, kustomize kind):
```yaml
resources:
  - metallb/    # descend into metallb/ and apply its kustomization.yaml
```

Adding a new controller (e.g. cert-manager) means creating a `cert-manager/` subdirectory and adding it here.

---

**`controllers/metallb/namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
```

Although the HelmRelease has `install.createNamespace: true` (a safety net), declaring the namespace explicitly in git means Flux owns it and will ensure it exists independently of the Helm install.

---

**`controllers/metallb/helmrelease.yaml`**
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: metallb
  namespace: metallb-system
spec:
  interval: 15m            # re-check desired state every 15 minutes
  chart:
    spec:
      chart: metallb
      version: "0.15.3"    # always pin versions to avoid unexpected upgrades
      sourceRef:
        kind: HelmRepository
        name: metallb       # must match HelmRepository metadata.name in repositories/
        namespace: flux-system
  install:
    createNamespace: true
    crds: CreateReplace    # install CRDs on first install, replace on upgrade
  upgrade:
    crds: CreateReplace    # keep CRDs current when chart version changes
```

**`crds: CreateReplace`** is essential for MetalLB. Without it, Flux installs the CRDs on first install but never updates them when you bump the chart version. This leads to CRD/API drift and broken reconciliation.

**`sourceRef.name: metallb`** cross-references the `HelmRepository` named `metallb` in `infrastructure/repositories/metallb.yaml`. These names must match exactly.

---

### `infrastructure/configs/`

Config objects are resources whose *types* (CRDs) were installed by the controllers layer. They cannot be applied before their CRDs exist.

**`kustomization.yaml`** (top-level, kustomize kind):
```yaml
resources:
  - metallb/
```

---

**`configs/metallb/metallb-config.yaml`**
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
    - 192.168.56.200-192.168.56.210   # IPs MetalLB may assign to Services

---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
    - default    # advertise IPs from the "default" pool via ARP (layer2)
```

**Why CRDs, not a ConfigMap?** MetalLB dropped ConfigMap-based configuration entirely at v0.13. Version 0.15.x requires CRD-based config only.

**Layer2 mode** works by having one MetalLB speaker pod respond to ARP requests for any IP from the pool. Traffic arrives at that node and is forwarded to the Service. It is simpler than BGP and works on a standard LAN. The IP range must:
- Be in the same subnet as the nodes (`192.168.56.0/24`)
- Not overlap with your router's DHCP range

**`L2Advertisement.spec.ipAddressPools: [default]`** must match `IPAddressPool.metadata.name: default`. Changing one without the other leaves the pool unannounced and no IPs will be assigned.

---

### `apps/`

**`apps/kustomization.yaml`** (top-level, kustomize kind):
```yaml
resources:
  - artifactory/
```

The `apps` Flux Kustomization (in `clusters/lab/apps.yaml`) points `path` at `./apps`. It reads this file, which lists each application subdirectory. Adding a new application means creating a new subdirectory and listing it here — no changes to `clusters/lab/` required.

---

**`apps/artifactory/namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: artifactory
```

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
    - ReadWriteOnce         # only one node can mount this at a time
  volumeMode: Filesystem
  persistentVolumeReclaimPolicy: Retain  # keep data if PVC is deleted
  storageClassName: ""      # empty = static provisioning; no StorageClass
  hostPath:
    path: /mnt/data/artifactory-data    # must exist on the target node
```

**`storageClassName: ""`** is critical. Without an explicitly empty string, Kubernetes may use a default StorageClass and try dynamic provisioning instead of binding to this PV. The empty string opts out of dynamic provisioning entirely.

**`persistentVolumeReclaimPolicy: Retain`** means deleting the PVC (e.g. when uninstalling Artifactory) will not delete this PV or its data. You must manually release or delete it.

**How PV binding works:** The Artifactory Helm chart creates a PVC requesting `20Gi` with `ReadWriteOnce` and `storageClassName: ""`. Kubernetes finds a PV matching all three fields and binds them. If no matching PV exists, the PVC stays `Pending` and the pod never starts.

---

**`apps/artifactory/postgresql-pv.yaml`** — storage for Artifactory's database
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgres-pv-0
spec:
  capacity:
    storage: 200Gi          # must be >= what the chart's PVC requests
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /mnt/data/postgres-data
```

Same pattern as the Artifactory PV. The chart's bundled PostgreSQL sub-chart creates a PVC named `data-artifactory-oss-postgresql-0` requesting `200Gi`. This PV satisfies that claim.

> To find what a chart's PVC requests: `helm show values artifactory-oss --repo https://charts.jfrog.io` and look for `postgresql.primary.persistence`. Or inspect after first install: `kubectl get pvc -n artifactory -o yaml`.

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
      version: "107.133.12"   # Artifactory app version is encoded in chart version
      sourceRef:
        kind: HelmRepository
        name: jfrog            # must match HelmRepository metadata.name in repositories/
        namespace: flux-system
```

**`version: "107.133.12"`** — always pin Helm chart versions. Without a pin, the next chart index refresh could auto-deploy a new Artifactory version. The chart version `107.x.x` maps directly to Artifactory application version `7.x.x`.

**`interval: 5m`** — any manual `helm upgrade` on the cluster will be reverted within 5 minutes. This enforces the GitOps contract: changes go through git, not the CLI.

---

**`apps/artifactory/kustomization.yaml`** (kustomize kind):
```yaml
resources:
  - namespace.yaml
  - postgresql-pv.yaml
  - artifactory-pv.yaml
  - helmrelease.yaml    # last: namespace and PVs must exist before install starts
```

---

## 7. How the Files Relate to Each Other

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

### What each Flux Kustomization reconciles

```
infra-repositories
  path: ./infrastructure/repositories
    → HelmRepository "jfrog"    (source for Artifactory chart)
    → HelmRepository "metallb"  (source for MetalLB chart)

infra-controllers  [waits for infra-repositories]
  path: ./infrastructure/controllers
    → Namespace "metallb-system"
    → HelmRelease "metallb"
         → helm-controller installs MetalLB chart
              → MetalLB pods running
              → CRDs installed: IPAddressPool, L2Advertisement, BGPPeer, etc.

infra-configs  [waits for infra-controllers + its wait:true]
  path: ./infrastructure/configs
    → IPAddressPool "default"       (192.168.56.200–210)
    → L2Advertisement "default"     (advertise via ARP from metallb-system)

apps  [waits for infra-controllers + infra-configs]
  path: ./apps
    → Namespace "artifactory"
    → PersistentVolume "artifactory-pv-0"
    → PersistentVolume "postgres-pv-0"
    → HelmRelease "artifactory-oss"
         → helm-controller installs artifactory-oss chart
              → PVCs created and bound to PVs above
              → Service "artifactory-oss-artifactory-nginx" (type: LoadBalancer)
                   → MetalLB assigns 192.168.56.200
              → Artifactory reachable at http://192.168.56.200
```

### Cross-references that must stay consistent

| This field | Must match |
|---|---|
| `HelmRelease (metallb).spec.chart.spec.sourceRef.name: metallb` | `HelmRepository.metadata.name: metallb` |
| `HelmRelease (artifactory-oss).spec.chart.spec.sourceRef.name: jfrog` | `HelmRepository.metadata.name: jfrog` |
| Both `sourceRef.namespace: flux-system` | `HelmRepository.metadata.namespace: flux-system` |
| `PersistentVolume.spec.storageClassName: ""` | PVC `storageClassName: ""` (chart default) |
| `PersistentVolume.spec.capacity.storage: 200Gi` | PVC requested size (chart default) |
| `IPAddressPool.metadata.name: default` | `L2Advertisement.spec.ipAddressPools[0]: default` |
| `infra-controllers` in `apps.yaml dependsOn` | `Kustomization.metadata.name: infra-controllers` in `infrastructure.yaml` |

---

## 8. Verification Commands

Run these after rebuilding to confirm everything is healthy. All `flux` commands run from `kubeadmin@cakers-cp-1`.

**Check all Flux Kustomizations:**
```bash
flux get kustomizations -A
# Should show: flux-system, infra-repositories, infra-controllers, infra-configs, apps
# All READY=True, SUSPENDED=False
```

**Check git is synced to latest commit:**
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
# Both artifactory-oss and metallb should be READY=True
```

**Check Artifactory pods:**
```bash
kubectl get pods -n artifactory
# artifactory-oss-0:                         9/9 Running
# artifactory-oss-artifactory-nginx-*:       1/1 Running
# artifactory-oss-postgresql-0:              1/1 Running
```

**Check PVs are bound:**
```bash
kubectl get pv
# artifactory-pv-0 and postgres-pv-0 should show STATUS: Bound
```

**Check MetalLB assigned an IP:**
```bash
kubectl get svc -n artifactory
# artifactory-oss-artifactory-nginx: EXTERNAL-IP should be 192.168.56.200
```

**Access Artifactory:**
```
http://192.168.56.200
Default credentials: admin / password  (change immediately after first login)
```

---

## 9. Troubleshooting

### Flux hasn't picked up a push

```bash
flux get source git flux-system -n flux-system
```

Check `REVISION` matches your latest git commit SHA. The `GitRepository` polls every 1 minute. Force an immediate sync:

```bash
flux reconcile source git flux-system -n flux-system
```

### A Kustomization is stuck READY=False

```bash
flux get kustomizations -A
flux describe kustomization <name> -n flux-system
```

If the message says `dependsOn condition not met`, the upstream Kustomization it depends on isn't ready yet. Fix the upstream first.

### HelmRelease stuck with `RetriesExceeded`

Flux stops retrying after exhausting the configured retry count. The cluster resources may actually be healthy — the timeout just happened during a restart. Reset the retry counter:

```bash
flux suspend helmrelease <name> -n <namespace>
flux resume helmrelease <name> -n <namespace>
```

Or force a reconcile (which also resets retries):

```bash
flux reconcile helmrelease <name> -n <namespace> --with-source
```

If `flux` CLI is not available locally, use the annotation method via `kubectl`:

```bash
kubectl annotate helmrelease <name> -n <namespace> \
  reconcile.fluxcd.io/requestedAt="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --overwrite
```

### PVC stuck in Pending

```bash
kubectl describe pvc <name> -n <namespace>
```

Common causes:
- The `hostPath` directory doesn't exist on the node → create it with `mkdir`
- `storageClassName` mismatch → both PV and PVC must have `storageClassName: ""`
- Size mismatch → PV `capacity.storage` must be >= PVC requested size

### MetalLB not assigning IPs

```bash
kubectl get pods -n metallb-system
kubectl logs -n metallb-system -l app=metallb,component=speaker
```

Common causes:
- `infra-configs` applied before `infra-controllers` finished → wait for controllers, then `flux reconcile kustomization infra-configs`
- IP range overlaps with DHCP server on the network
- `L2Advertisement.spec.ipAddressPools` name doesn't match `IPAddressPool.metadata.name`

### Artifactory startup probe failures

Artifactory takes 2–5 minutes to initialise from a cold start. Startup probe failures in the first few minutes are normal. Only investigate if they persist beyond 10 minutes:

```bash
kubectl describe pod artifactory-oss-0 -n artifactory
kubectl logs artifactory-oss-0 -n artifactory -c artifactory
```

---

## 10. Future: Image Tag Automation

The goal is: push a new image to Artifactory → Flux detects the new tag → updates the image tag in a HelmRelease → auto-deploys.

### What's missing

The current `gotk-components.yaml` only deploys four controllers: `source-controller`, `kustomize-controller`, `helm-controller`, and `notification-controller`. Image automation requires two more:

| Controller | Job |
|---|---|
| `image-reflector-controller` | Scans a container registry, fetches available image tags |
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

This regenerates `gotk-components.yaml` with the two extra controllers and pushes the update to the repo.

### Step 2: Add image automation resources

For each application image you want to track, add three objects. Create them under `apps/<appname>/`:

**`image-repository.yaml`** — scan your Artifactory registry for new tags:
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
    name: artifactory-regcred    # imagePullSecret for your Artifactory instance
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
      range: ">=1.0.0"    # or use alphabetical: {} for date-based tags
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

The `image-automation-controller` reads this marker, replaces the tag value with whatever `ImagePolicy` selected, and commits the change. The `GitRepository` detects the new commit within 1 minute, the `apps` Kustomization reconciles, and the HelmRelease upgrades — completing the loop automatically.
