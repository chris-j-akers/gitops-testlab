# Runbook: Migrating the `lab` cluster from Flannel to Cilium

## Prompt that Generated this Runbook

This is a GitOps repo that uses flux. It currently uses Flannel as the CNI but I want to migrate to Cilium. Can you write me a runbook in ./runbooks that will instruct me on how to do that? For each step include *why* I need to do what I'm doing. For specific Cilium helm chart values include an explanation in the comments what each value does and why. Ultimately, this runbook needs to be comprehensive. I don't want to just blindly follow a tick-list, I want to fully understand what I'm doing at each step and why I'm doing it. God speed.

## Audience and scope

This is written for the `lab` cluster as it actually exists in this repo today:
one control-plane node (`cakers-cp-1`) and three workers, built on VirtualBox
VMs running Rocky Linux, joined with kubeadm, networked over a host-only
segment (`192.168.56.0/24`, the same range MetalLB hands out addresses from),
GitOps'd by Flux from `ssh://git@github.com/chris-j-akers/gitops-testlab`.

Flannel currently runs as raw upstream manifests (not a Helm chart) under
[kubernetes/infrastructure/controllers/flannel/](../kubernetes/infrastructure/controllers/flannel/),
using the vxlan backend over pod CIDR `10.244.0.0/16`, pinned to the
`enp0s8` interface via a kustomize patch. That last detail matters: these VMs
have more than one NIC, and `enp0s8` is the one on the host-only network
where the other nodes actually live. Cilium needs to be told the same thing,
or it may pick the wrong interface and nodes won't be able to reach each
other.

Every step that can be done declaratively *is* done declaratively — through
Git commits that Flux reconciles. The one exception is cleaning up CNI
binaries/config files left behind on the node filesystem by Flannel; those
live outside the Kubernetes API entirely, so no manifest can touch them. That
part is called out explicitly where it happens, and is scripted/idempotent
rather than ad hoc.

---

## 1. Why move off Flannel at all

Flannel does exactly one job: give every pod an IP and get packets between
nodes, via a VXLAN overlay. It does that job reliably, which is why it's been
fine for this lab so far. But it stops there — there is no policy
enforcement, no visibility into traffic, and no way to remove kube-proxy from
the data path. Three concrete things this cluster already has, but can't use
properly, are the motivation:

- **NetworkPolicy objects already exist in this repo and are silently
  no-ops.** Flux's own bootstrap manifests
  ([gotk-components.yaml](../kubernetes/clusters/lab/flux-system/gotk-components.yaml))
  ship three `NetworkPolicy` resources in `flux-system`
  (`allow-egress`, `allow-scraping`, `allow-webhooks`). Flannel has no policy
  engine, so the Kubernetes API happily stores these objects and nothing
  enforces them — `kubectl get networkpolicy -n flux-system` returns objects
  that do nothing. Cilium implements the standard `NetworkPolicy` API, so the
  moment it's installed, these existing objects start being *actually
  enforced* for the first time, with no extra manifests needed. That's a
  concrete, low-risk proof that this migration changes real behaviour, not
  just the label on the CNI.
- **No traffic observability.** Right now, debugging "why can't pod A reach
  pod B" means reasoning about iptables and vxlan by hand. Cilium ships
  Hubble, which gives a live, queryable record of every connection its eBPF
  programs see — allowed/denied, latency, DNS answers, drops and the reason
  for the drop. That's directly useful alongside the LGTM/Grafana Alloy stack
  this lab is already building toward.
- **kube-proxy is still doing Service routing via iptables.** Flannel can't
  change that; it only owns the pod network. Cilium *can* take over Service
  routing with an eBPF dataplane, removing an entire layer of iptables chains
  that grows with every Service in the cluster. This runbook deliberately
  does **not** do that yet (see "Why kube-proxy stays, for now" below) — it's
  flagged here as the reason this is worth coming back to later.

None of this is about Flannel being broken. It's about Cilium making
currently-latent capabilities (policy enforcement, observability,
kube-proxy-free routing) actually available, in a cluster that exists
specifically to practice this kind of thing.

### A note on the "Beyla" TODO

The README's TODO list flags a concern: *"Beyler configured in cluster
(might clash with Cilium?)"* — presumably Grafana Beyla, the eBPF
auto-instrumentation agent. Beyla isn't deployed anywhere in this repo yet,
so there's nothing to conflict with today. For when it is: Cilium and Beyla
generally coexist, because they attach to different eBPF hook points (Cilium
mostly works in the networking/XDP/tc layer and at the socket layer; Beyla
attaches uprobes/kprobes to application binaries and the network namespace).
The thing to actually watch for is contention over the same tracepoints if
Beyla's network-instrumentation feature is enabled, and BTF type
availability on the node kernel, which both agents rely on. Worth a
five-minute check against current Cilium/Beyla docs before deploying Beyla,
not a blocker for this migration.

---

## 2. Key decisions, and why each one was made

These are the choices baked into the Helm values below. Each one is a place
where a different cluster might reasonably choose differently — they're
called out so you know *why* this cluster chose what it chose, not just
what the value is.

### Clean cutover, not a live/hybrid migration

Cilium's upstream docs describe a zero-downtime migration path: run Flannel
and Cilium side by side, label nodes to move them over one at a time, and use
a `CiliumNodeConfig` / migration-mode setting to control which CNI handles
new pods per node. It's the right tool when a cluster has live traffic that
can't tolerate any interruption.

This cluster doesn't have that constraint — it's a 4-node lab whose explicit
purpose is practicing exactly this kind of operation, and a few minutes of
pod-network downtime costs nothing real. The hybrid approach trades a chunk
of *additional* complexity (running two CNIs simultaneously, node-by-node
state tracking, two failure domains active at once) for a benefit (zero
downtime) that isn't needed here. So this runbook takes the simpler path: take
the network down deliberately, bring it back up on Cilium, verify, move on.
That simplicity is also why each stage below is its own Git commit — if
something looks wrong, it's obvious which change caused it.

### Why kube-proxy stays, for now

`kubeProxyReplacement: true` is one of Cilium's headline features — it
removes kube-proxy and routes Service traffic via eBPF instead of iptables.
It's also a structurally different change from swapping the pod-network
plugin: it touches how *every* Service in the cluster (including the
Kubernetes API Service itself) gets routed, and a misconfiguration there can
take down API access cluster-wide, not just pod-to-pod traffic.

This runbook installs Cilium with `kubeProxyReplacement: false` first:
kube-proxy keeps doing what it's always done, and Cilium only takes over the
pod network. That isolates the blast radius of *this* change to "can pods
reach each other," which is the thing actually being changed. Once Cilium is
confirmed stable, flipping on kube-proxy replacement becomes a single,
separable, easily-rolled-back follow-up change (see "Phase 2" at the very
end) — not bundled into the same change where, if something breaks, you'd be
debugging two unrelated unknowns at once.

### Why overlay (vxlan tunnel) mode, not native routing

Cilium can run in `routingMode: native`, where it skips encapsulation
entirely and relies on the underlying network to route pod-CIDR traffic
between nodes (either via directly-connected routes or BGP). That's faster
and simpler on the wire, but it requires the network fabric to actually know
how to get a packet to `10.244.x.0/24` on a specific node.

This lab's nodes sit on a flat VirtualBox host-only network with no router
doing that — which is exactly why Flannel was configured with
`Backend.Type: vxlan` in the first place
([kube-flannel.yaml:82-89](../kubernetes/infrastructure/controllers/flannel/kube-flannel.yaml#L82-L89)).
Cilium needs to solve the same problem the same way: `routingMode: tunnel`
with `tunnelProtocol: vxlan` encapsulates pod traffic in a vxlan packet
addressed node-to-node, so it doesn't matter that the host-only network has no
idea what a pod CIDR is. Native routing is worth revisiting only if the
network topology changes (e.g. a real L3 switch/router fronting the nodes).

### Why IPAM mode is `kubernetes`, not `cluster-pool`

Cilium has its own IPAM (`cluster-pool`) that carves up a CIDR and hands out
ranges to nodes itself. This cluster doesn't need that: kubeadm already
allocated a `/24` out of `10.244.0.0/16` to each node (visible as
`.spec.podCIDR` on every `Node` object) when the cluster was bootstrapped,
and that's the exact range Flannel has been using. Setting `ipam.mode:
kubernetes` tells Cilium to read and reuse those existing per-node
allocations instead of inventing new ones.

This is what makes the cutover a drop-in replacement rather than a
cluster-wide re-IP: no node needs a new pod range, nothing about Service or
pod addressing changes from the outside, and there's nothing extra to
reconcile between kube-controller-manager's idea of node CIDRs and Cilium's.

### Why `bpf.masquerade: true`

Flannel's DaemonSet is started with `--ip-masq`
([kube-flannel.yaml:131](../kubernetes/infrastructure/controllers/flannel/kube-flannel.yaml#L131)),
which SNATs pod-to-external traffic so it leaves each node looking like it
came from the node's own IP — necessary because `10.244.x.x` addresses mean
nothing outside the cluster and have no return path. `bpf.masquerade: true`
is Cilium's equivalent, enforced via an eBPF program instead of an iptables
`MASQUERADE` rule. Without it, pods would keep their pod-CIDR source address
on the way out to the internet (e.g. pulling images, NTP, anything external)
and replies would have nowhere to come back to.

### Why `operator.replicas: 1`

The Cilium chart defaults `operator.replicas` to `2`, for HA in clusters
where that matters. This lab has one control-plane node and three workers
with no availability requirement for the operator specifically — the
`cilium-operator` only handles CRD/IPAM reconciliation; the per-node
`cilium-agent` DaemonSet is what actually keeps pods networked, and it keeps
working even if the operator is briefly unavailable. Running 2 replicas here
just means a second pod sitting idle on a fourth node for no benefit.

### Why Hubble is enabled

This is the most direct payoff of the whole migration (see Section 1). It
costs two boolean flags to turn on (`hubble.relay.enabled`,
`hubble.ui.enabled`) and provides the live network-flow visibility Flannel
could never offer. Wiring Hubble's own Prometheus metrics into the existing
Grafana Alloy / Mimir pipeline is a natural next step but is **out of scope**
for this runbook — it's a dashboarding task, not a CNI migration task, and
bundling it in would blur what each Git commit is actually responsible for.

### Why MetalLB is untouched

Cilium *can* replace MetalLB (via its own LB-IPAM and L2-announcement or BGP
features), but this runbook leaves
[kubernetes/infrastructure/controllers/metallb/](../kubernetes/infrastructure/controllers/metallb/)
exactly as it is. MetalLB's job — claiming a `LoadBalancer` Service's
external IP from the `192.168.56.200-210` pool and ARP-announcing it on the
host-only network — sits a layer above whatever is handling pod networking
and Service routing underneath. Whether that underlying layer is Flannel +
kube-proxy or Cilium + kube-proxy (this runbook's end state) or eventually
Cilium replacing kube-proxy too (Phase 2), MetalLB's job doesn't change.
Consolidating onto Cilium's own LB-IPAM is a legitimate future simplification
(one fewer controller to run), but it's an unrelated change with its own
blast radius and doesn't belong in a CNI swap.

---

## 3. What does **not** change

Worth stating explicitly, because it's most of what could make this feel
riskier than it is:

- **The control plane stays up throughout.** `kube-apiserver`, `etcd`,
  `kube-controller-manager` and `kube-scheduler` run as static pods with
  `hostNetwork: true` — they talk directly over the node's network interface,
  not through the pod network. A total absence of CNI (the state the cluster
  is deliberately put into between Stage 1 and Stage 2 below) does not take
  down `kubectl` access or cluster control-plane functions. It only blocks
  *new* pod sandboxes from being created.
- Pod CIDR stays `10.244.0.0/16`. Node IPs, hostnames, and the
  `enp0s8`/host-only network setup stay the same.
- MetalLB, Sealed Secrets, Flux itself, and every app under
  [kubernetes/apps/](../kubernetes/apps/) are unmodified by this runbook.
- The Flux reconciliation chain (`infra-repositories → infra-controllers →
  infra-configs → apps`, see
  [infrastructure.yaml](../kubernetes/clusters/lab/infrastructure.yaml)) is
  unchanged — Cilium just becomes another resource Flux applies as part of
  `infra-controllers`, the same tier Flannel currently occupies.

---

## 4. Pre-flight checks

Run these yourself before touching anything — they're read-only, and they
confirm the assumptions this runbook is built on instead of trusting them
blindly.

```bash
# Kubernetes server version - check against Cilium's compatibility matrix
# (https://docs.cilium.io/en/stable/operations/system_requirements/)
# before picking a chart version in Stage 2.
kubectl version

# Container runtime in use on each node - Cilium supports containerd and
# CRI-O, but the values/CLI flags differ slightly. kubeadm defaults to
# containerd, which is almost certainly what's running here, but confirm it.
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}'

# Kernel version on each node - Cilium's eBPF dataplane needs a reasonably
# modern kernel. Rocky Linux 9's kernel (5.14, with RHEL's BTF backports) is
# fine for everything in this runbook; Rocky Linux 8's 4.18 kernel is fine for
# the basic dataplane used here but matters a lot more if/when kube-proxy
# replacement (Phase 2) is enabled later, since that leans on newer eBPF
# features. SSH to each node and check, or:
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.nodeInfo.kernelVersion}{"\n"}{end}'

# Confirm the per-node pod CIDR allocations that ipam.mode=kubernetes will
# reuse - these should already exist from when the cluster was kubeadm-init'd.
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.podCIDR}{"\n"}{end}'

# The reachable control-plane address Cilium needs for k8sServiceHost - this
# should match the `server:` line in your kubeconfig.
grep server ~/.kube/config
```

If the pod CIDR command above returns nothing for any node, stop — that
means `ipam.mode: kubernetes` won't have anything to read, and Cilium would
need `cluster-pool` IPAM with a fresh range instead. That's not expected
given how this cluster was bootstrapped, but it's the one assumption worth
confirming rather than discovering mid-migration.

---

## 5. Stage 1 — Remove Flannel cleanly

The goal of this stage is a cluster with **no CNI installed at all**,
deliberately, with old Flannel artifacts wiped off every node. That sounds
alarming, but per Section 3 it does not affect control-plane availability —
it only means no *new* pod sandboxes can be created until Stage 2 installs
Cilium. Keeping this as its own commit, separate from installing Cilium,
gives a clean checkpoint: you can confirm Flannel is fully and cleanly gone
before introducing anything new, rather than debugging two changes at once if
something looks wrong.

### 5.1 Remove Flannel from the Flux-managed resources

Edit [kubernetes/infrastructure/controllers/kustomization.yaml](../kubernetes/infrastructure/controllers/kustomization.yaml)
and remove the `flannel/` entry:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - metallb/
  - sealed-secrets/
```

**Why this is enough to remove every Flannel object:** the parent Flux
`Kustomization` (`infra-controllers`) is defined with `prune: true`
([infrastructure.yaml:30](../kubernetes/clusters/lab/infrastructure.yaml#L30)).
Flux computes the set of objects it's responsible for from what's listed in
the kustomization tree; anything previously applied that's no longer listed
gets deleted on the next reconcile. Deleting the `flannel/` directory's
*reference* here is enough — Flux will delete the `kube-flannel` namespace,
ServiceAccount, ClusterRole(Binding), ConfigMap and DaemonSet for you. You
don't need to (and shouldn't) `kubectl delete` any of this by hand; let Flux
do the deleting it's already responsible for.

You can leave the actual `flannel/` directory and its manifests in the repo
for now (consistent with how this repo already keeps the old Artifactory
manifests around after removing them from `kubernetes/apps/kustomization.yaml`
— see the comment there) until Cilium is confirmed working, then delete it
in a follow-up commit.

Commit and push:

```bash
git add kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "Remove Flannel from Flux-managed controllers"
git push
```

### 5.2 Watch Flux prune it

```bash
flux get kustomization infra-controllers --watch
# or:
kubectl get pods -n kube-flannel --watch
```

Wait until the `kube-flannel` namespace and everything in it is gone:

```bash
kubectl get namespace kube-flannel
# Error from server (NotFound): namespaces "kube-flannel" not found
```

### 5.3 Clean up host-level CNI artifacts on every node

This is the one part of this runbook that can't go through Git, because
these files live on the node's filesystem, not in the Kubernetes API. The
Flannel CNI plugin wrote a config file and binary directly onto each host,
and deleting the Kubernetes objects above does **not** remove them.

Run this on the control-plane node and all three workers (e.g. over SSH, one
node at a time):

```bash
# The conflist kubelet reads to find a CNI plugin for new pod sandboxes.
sudo rm -f /etc/cni/net.d/10-flannel.conflist

# The flannel CNI binary itself.
sudo rm -f /opt/cni/bin/flannel

# Cached per-pod network state from the old CNI.
sudo rm -rf /var/lib/cni/*
```

Then **reboot the node**. A full reboot, rather than trying to surgically
delete every interface (`flannel.1`, `cni0`) and iptables rule Flannel left
behind, is the deliberate choice here: it's the only way to be *certain*
nothing stale survives (routes, conntrack entries, bridge state), and it's
cheap and safe to do in this lab. Trying to hand-pick every piece of leftover
network state to remove is exactly the kind of fiddly, error-prone manual
work this runbook is trying to avoid.

Reboot workers first, one at a time, confirming each comes back `Ready`
before moving to the next — `kubectl` stays available throughout since it
talks to the control-plane node, which you haven't touched yet:

```bash
ssh cakers-worker-1 sudo reboot
kubectl get node cakers-worker-1 --watch   # wait for Ready... it won't go fully Ready
                                            # until Stage 2 installs a CNI - that's expected.
```

Note: after this reboot, the node will report `Ready` for the node condition
itself once kubelet is back, but `kube-system` pods like CoreDNS and any
other non-hostNetwork pods will sit in `ContainerCreating` / ` NetworkNotReady`
until Cilium is installed in Stage 2 — there's no CNI for kubelet to call.
That's expected and is the whole point of this stage.

Repeat for `cakers-worker-2`, `cakers-worker-3`, then reboot the control
plane last:

```bash
ssh cakers-cp-1 sudo reboot
```

`kubectl` will be briefly unavailable while the control-plane node reboots
(static pods restart along with kubelet) — this is the only window in the
whole migration where that happens, and it's no different from rebooting the
control-plane node for any other reason.

---

## 6. Stage 2 — Install Cilium via Flux

### 6.1 Add the Cilium Helm repository

Create `kubernetes/infrastructure/repositories/cilium.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: cilium
  namespace: flux-system
spec:
  interval: 1h
  url: https://helm.cilium.io/
```

Add it to [kubernetes/infrastructure/repositories/kustomization.yaml](../kubernetes/infrastructure/repositories/kustomization.yaml):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  # Not curently using artifactory, OSS version is too limited. Switched to Harbor
  # - jfrog.yaml
  - harbor.yaml
  - metallb.yaml
  - grafana-alloy.yaml
  - sealed-secrets.yaml
  - cilium.yaml
```

This mirrors exactly how `metallb` and `sealed-secrets` register their Helm
repos — `HelmRepository` objects live in `repositories/`, `HelmRelease`
objects that reference them live in `controllers/`, applied in that order
because `infra-controllers` `dependsOn: [infra-repositories]`
([infrastructure.yaml:22-23](../kubernetes/clusters/lab/infrastructure.yaml#L22-L23)).

### 6.2 Create the Cilium namespace and HelmRelease

Create `kubernetes/infrastructure/controllers/cilium/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cilium
```

A dedicated `cilium` namespace (rather than the commonly-used `kube-system`)
keeps this consistent with how every other controller in this repo is
isolated into its own namespace — `kube-flannel`, `metallb-system`,
`sealed-secrets` — and the Cilium chart has no requirement to live in
`kube-system`; that's a documentation convention upstream, not a technical
one.

Create `kubernetes/infrastructure/controllers/cilium/helmrelease.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cilium
  namespace: cilium
spec:
  interval: 15m
  chart:
    spec:
      chart: cilium
      version: "1.16.5"   # pin this - check https://github.com/cilium/cilium/releases
                           # for the latest stable, and check it against
                           # https://docs.cilium.io/en/stable/operations/system_requirements/
                           # for your kubernetes/kernel version before bumping it.
      sourceRef:
        kind: HelmRepository
        name: cilium
        namespace: flux-system
  install:
    createNamespace: true
  upgrade:
    # Cilium ships its own CRDs (CiliumNode, CiliumEndpoint,
    # CiliumNetworkPolicy, etc.) that the chart manages directly. Keeping
    # them in sync with the chart version (rather than leaving stale CRDs
    # from a previous version around) mirrors how metallb's HelmRelease
    # already handles its own CRDs in this repo.
    crds: CreateReplace
  values:
    # The interface the other nodes are actually reachable on. These VMs
    # have more than one NIC; Flannel was explicitly pinned to enp0s8 via
    # iface-patch.yaml for the same reason - without this, Cilium could
    # autodetect the wrong device and nodes would fail to reach each other.
    devices: enp0s8

    # --- API server reachability ---
    # Cilium agents talk to the Kubernetes API directly during their own
    # startup, and this becomes a hard requirement once kube-proxy is
    # replaced (see "Phase 2" at the end of this runbook) rather than an
    # optional one. Setting it now means that future change is a single
    # flag flip instead of a structural one. Use the same host/port as the
    # `server:` line in your kubeconfig, without the https:// prefix.
    k8sServiceHost: cakers-cp-1.lab.local
    k8sServicePort: 6443

    # --- Datapath mode ---
    # vxlan-over-tunnel is the direct equivalent of Flannel's
    # Backend.Type: vxlan. This host-only VirtualBox network has no router
    # capable of routing pod-CIDR traffic between nodes on its own, which is
    # exactly why Flannel needed an overlay in the first place - Cilium needs
    # the same overlay to solve the same problem. (Native routing, which
    # skips encapsulation, is only viable if that changes - e.g. a real L3
    # switch/router in front of the nodes, or a BGP-speaking fabric.)
    routingMode: tunnel
    tunnelProtocol: vxlan

    # --- IPAM ---
    # Reuse the per-node pod CIDR ranges kubeadm already allocated out of
    # 10.244.0.0/16 (visible as .spec.podCIDR on each Node) instead of having
    # Cilium hand out its own ranges. This is what makes the swap a drop-in
    # replacement rather than a cluster-wide re-IP of every node's pod range.
    ipam:
      mode: kubernetes

    # --- Masquerading ---
    # Equivalent to Flannel's --ip-masq flag: SNATs pod-to-external traffic
    # so replies have somewhere to come back to. Without this, anything a pod
    # does outside the cluster (pulling images, DNS, NTP) breaks, because
    # 10.244.x.x addresses mean nothing outside the pod network.
    bpf:
      masquerade: true

    # --- kube-proxy ---
    # Left running for now. kube-proxy keeps handling ClusterIP/NodePort
    # routing exactly as before; Cilium only takes over the pod network in
    # this change. See "Why kube-proxy stays, for now" in this runbook for
    # the reasoning - this keeps the blast radius of this specific change
    # limited to pod-to-pod connectivity.
    kubeProxyReplacement: false

    # --- Operator replicas ---
    # Defaults to 2, for HA. This lab has no availability requirement for
    # cilium-operator specifically (the per-node agent DaemonSet is what
    # actually keeps pods networked) - one replica avoids scheduling a second,
    # permanently-idle pod for no benefit on a 4-node cluster.
    operator:
      replicas: 1

    # --- Hubble (flow observability) ---
    # The main payoff of this migration: a live, queryable record of every
    # connection Cilium's eBPF programs see. Flannel has no equivalent.
    # Wiring its Prometheus metrics into the existing Grafana Alloy/Mimir
    # pipeline is a deliberate follow-up, not part of this change.
    hubble:
      relay:
        enabled: true
      ui:
        enabled: true
```

Create `kubernetes/infrastructure/controllers/cilium/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrelease.yaml
```

### 6.3 Register Cilium with the controllers Kustomization

Edit [kubernetes/infrastructure/controllers/kustomization.yaml](../kubernetes/infrastructure/controllers/kustomization.yaml)
again:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cilium/
  - metallb/
  - sealed-secrets/
```

Commit and push:

```bash
git add kubernetes/infrastructure/repositories/cilium.yaml \
        kubernetes/infrastructure/repositories/kustomization.yaml \
        kubernetes/infrastructure/controllers/cilium/ \
        kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "Install Cilium as the cluster CNI"
git push
```

### 6.4 Why no further pod restarts are needed

Most CNI-migration guides spend significant effort on a step like "now
restart every pod in every namespace so it picks up the new CNI" — because
on a live cluster, pods that were already running keep their old
CNI-managed network namespace until something forces a new sandbox to be
created. This runbook doesn't need that step, and it's worth understanding
why: the node reboot in Stage 1 already destroyed every pod sandbox on every
node (containerd doesn't preserve running containers across a reboot).
Kubelet will have been retrying sandbox creation for everything since the
moment each node came back — and failing, because there was deliberately no
CNI installed yet. The instant Cilium's agent comes up and writes a working
CNI conflist, kubelet succeeds on its next retry, for every pod, automatically.
That's a direct consequence of choosing the clean-cutover-with-reboot
approach in Section 2, rather than a separate thing to remember to do.

---

## 7. Validation

All of this is read-only — interrogating the cluster to confirm it's healthy,
not changing anything.

```bash
# Cilium pods should be Running on every node (one cilium-agent per node,
# one cilium-operator).
kubectl get pods -n cilium -o wide

# Every node should report Ready, including the pod-network-related
# conditions kubelet exposes.
kubectl get nodes

# Things that were stuck in ContainerCreating since the Stage 1 reboot
# should now be Running - CoreDNS is the most useful one to check, since
# nothing else works without DNS.
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

Install the Cilium CLI locally (a standalone diagnostic binary, not anything
applied to the cluster) and run its built-in health checks:

```bash
# https://github.com/cilium/cilium-cli - install instructions there.
cilium status --wait
```

`cilium status` should report the agent and operator healthy, the configured
datapath mode (`Tunnel: vxlan`), and IPAM mode (`Kubernetes`) matching what
was just set in the HelmRelease.

For a deeper check, `cilium connectivity test` spins up a temporary set of
test pods/Services across namespaces and verifies pod-to-pod, pod-to-Service
and cross-node connectivity end to end, then cleans itself up. It's slower
and noisier than the checks above, so treat it as optional verification
rather than something to run by default:

```bash
cilium connectivity test
```

Finally, confirm the things this migration specifically claimed wouldn't
break:

```bash
# The flux-system NetworkPolicy objects mentioned in Section 1 are now
# actually enforced - this should still work, since allow-scraping permits
# ingress from any namespace on port 8080.
kubectl exec -n flux-system deploy/source-controller -- true  # sanity: pod is reachable/healthy

# A LoadBalancer-typed Service backed by MetalLB should still resolve and
# respond on its 192.168.56.x address - pick any app under kubernetes/apps/
# that exposes one (e.g. Harbor).
kubectl get svc -A | grep LoadBalancer

# External egress through bpf.masquerade should work - exec into any pod
# and confirm it can reach the internet.
kubectl run -it --rm masq-test --image=busybox --restart=Never -- wget -qO- https://1.1.1.1
```

---

## 8. Update the README

This repo tracks its own progress in [README.md](../README.md)'s TODO list.
Once the above is verified, update it the same way Artifactory's removal was
recorded:

```diff
 - K8s
-    - Flannel
+    - Cilium
     - Metallb
```

```diff
-[ ] Replace Flannel with Cilium
+[X] Replace Flannel with Cilium
```

And once you're confident enough not to need a quick revert (give it a few
days of normal use), delete the old `kubernetes/infrastructure/controllers/flannel/`
directory in its own commit — there's no reason to keep dead manifests around
once Cilium has proven itself, beyond the short safety window right after
the cutover.

---

## 9. Rollback plan

Because IPAM mode `kubernetes` means both Flannel and Cilium read the same
per-node pod CIDRs, rolling back doesn't involve any address renumbering —
it's the same procedure in reverse:

1. `git revert` the commit from Section 6 (removes Cilium from
   `infra-controllers`; Flux prunes it the same way it pruned Flannel).
2. On every node, remove Cilium's host-level artifacts and reboot, mirroring
   Section 5.3:
   ```bash
   sudo rm -f /etc/cni/net.d/05-cilium.conflist
   sudo rm -rf /var/lib/cni/*
   sudo reboot
   ```
3. `git revert` the commit from Section 5.1 (restores `flannel/` to
   `infra-controllers`; Flux re-applies it).

Because each stage was its own commit, both reverts are independent and
unambiguous — there's no risk of partially reverting a change that bundled
unrelated edits together.

---

## 10. Phase 2 (separate, future change): kube-proxy replacement

Not part of this runbook, deliberately (see "Why kube-proxy stays, for now"
in Section 2) — documented here only so it isn't forgotten as the natural
next step once Cilium has been running stably for a while.

The change itself is small: flip `kubeProxyReplacement: false` to `true` in
the HelmRelease from Section 6.2. The `k8sServiceHost`/`k8sServicePort`
values are already in place specifically so that this is the *only* line
that needs to change. What makes it worth a separate runbook rather than a
one-line diff here is the verification: once kube-proxy is gone, *every*
Service in the cluster (ClusterIP, NodePort, and the `kubernetes` API Service
itself) routes through Cilium's eBPF instead of iptables, and that needs to
be verified Service-by-service, with kube-proxy's DaemonSet (and its
manifests, if it's Flux-managed, or kubeadm's static config if not) removed
as a deliberate, separate cleanup step.
