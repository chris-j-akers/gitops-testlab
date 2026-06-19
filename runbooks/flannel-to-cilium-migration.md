# Runbook: Migrating the `lab` cluster from Flannel to Cilium (live, node-by-node)

## Prompt that generated this runbook

Original ask: a GitOps repo using Flux, currently on Flannel, wants to move to
Cilium, with the *why* explained at every step and every Helm value commented.
A first pass of this runbook used a simple clean-cutover (take the whole
cluster's pod network down, bring it back up on Cilium) — that version is
preserved at
[flannel-to-cilium-migration-clean-cutover-backup.md](flannel-to-cilium-migration-clean-cutover-backup.md).
This version replaces it with the harder, more realistic approach: migrate
node by node with both CNIs live simultaneously, no cluster-wide pod-network
outage. The reasoning for the switch is in Section 1.

## Audience and scope

Same cluster as before: one control-plane node (`cakers-cp-1`) and three
workers (`cakers-worker-1/2/3`), VirtualBox VMs on Rocky Linux, joined with
kubeadm, on a host-only network (`192.168.56.0/24`) reachable via `enp0s8`,
GitOps'd by Flux from `ssh://git@github.com/chris-j-akers/gitops-testlab`.
Flannel runs as raw upstream manifests + a Kustomize patch under
[kubernetes/infrastructure/controllers/flannel/](../kubernetes/infrastructure/controllers/flannel/),
vxlan backend, pod CIDR `10.244.0.0/16`.

**A note on how version-sensitive this runbook is.** The ordinary Helm values
used in the previous (clean-cutover) version are stable, well-documented chart
options that don't change much between Cilium releases. The mechanism this
version relies on — running Flannel and Cilium simultaneously and controlling,
per node, which one kubelet uses — leans on a more specialised part of
Cilium's API (`CiliumNodeConfig`, the `cni.exclusive` flag, the operator's
unmanaged-pod-watcher behaviour) that is more likely to shift in field name or
default between minor versions. Treat the *shape* of what follows — install
passively everywhere, flip nodes one at a time, validate cross-CNI traffic,
finalise — as solid. Treat the exact field names as "verify against Cilium's
official 'Migrating a cluster to Cilium' guide for whatever version you pin in
Section 6.1, before you run anything." That's not a hedge to cover a guess —
it's the correct way to treat any CRD-level API in a fast-moving project, and
worth internalising as a habit independent of this specific migration.

---

## 1. Why a live migration, and why this is realistic

The clean-cutover version of this runbook took the position that a brief,
deliberate, whole-cluster pod-network outage was an acceptable trade for
simplicity, since this lab has no live traffic that can't tolerate it. That's
still true, and the clean-cutover document remains a legitimate approach for a
cluster in that position — it's kept as a backup specifically because it's
still the right call *if* the goal were just "get to Cilium with the least
risk." It isn't here: the goal is to learn how this is actually done on a
cluster that *can't* take that outage, because most real ones can't.

This is a documented, real production technique, not a hypothetical. Cilium
ships an official guide for migrating a live cluster from another CNI
(including Flannel) without disrupting existing pods, because organisations
running Cilium today overwhelmingly got there by migrating off something
else — Flannel, Calico, kops' kubenet, cloud-provider default CNIs — on
clusters that were already carrying production traffic. The technique below
is the shape of that guide, adapted to this cluster's specifics.

The core trade-off, stated precisely: a clean cutover converts "the whole
cluster's pod network is briefly down" into nothing, by instead converting it
into "each node's pod network briefly cycles, one node at a time, while every
other node keeps working." It does **not** eliminate complexity — it adds a
new kind of complexity (two CNIs alive at once, needing to interoperate)
in exchange for shrinking the blast radius of the outage from
"every pod, all at once" down to "the pods on one node, briefly, while you're
actively working on it." That's the realistic trade production operators
actually make, and it's the one worth understanding properly.

The motivations for moving to Cilium at all — policy enforcement actually
working on the `NetworkPolicy` objects Flux already ships in `flux-system`,
Hubble's flow observability, the option to drop kube-proxy later — are
unchanged from the previous version and still the reasons this is worth
doing. The "Beyla" coexistence note from the previous version is also
unchanged and still applies; it isn't repeated in full here.

---

## 2. How the live migration actually works

This is the part worth understanding deeply before touching anything, because
it's the part that's easy to wave hands at ("the two CNIs coexist") without
actually explaining *how* a packet gets from a Flannel-managed pod to a
Cilium-managed pod while both are live. Walking through it concretely:

### Both CNIs keep running on every node until the very end

The instinct "migrate a node" suggests is "rip Flannel off it, put Cilium on
it." That's wrong, and it's the single most important correction to make
before starting: **flanneld keeps running on every node, including ones
already switched over, until every pod in the cluster has moved.** What
actually changes per node is narrower — just *which CNI plugin kubelet invokes
when creating a brand new pod sandbox on that node.* Both daemons keep doing
their other job throughout: maintaining routes and vxlan forwarding-database
entries for their own pod CIDR, on every node, regardless of whether that node
is "migrated" yet.

This is *why* cross-CNI traffic works at all. A pod's packets leave its veth
into the node's root network namespace, and from there it's just normal
kernel routing — the kernel doesn't know or care which CNI plugged in the
source pod, it only matches the destination IP against the routing table.
Flannel's `flannel.1` vxlan interface (with `--kube-subnet-mgr`, which this
cluster already uses — see
[kube-flannel.yaml:131-132](../kubernetes/infrastructure/controllers/flannel/kube-flannel.yaml#L131-L132))
keeps installing routes for every node's Flannel-allocated subnet, watched
straight off each `Node` object's `.spec.podCIDR`. Cilium's own tunnel mesh
(`cilium_vxlan`) does the equivalent for every node it knows about via its own
control plane (`CiliumNode` objects), independent of whether that node is
"exclusive" for new pod creation yet. So a node that hasn't been migrated yet
still has a working route to every already-migrated node's Cilium pod CIDR,
because cilium-agent is already running there and already participating in
the mesh — "not migrated" only means "not yet the plugin kubelet calls for new
pods," not "not running."

### Why this requires a second, non-overlapping pod CIDR

Flannel's `10.244.0.0/16` allocation is already "owned," in the sense that
kube-controller-manager wrote it into `.spec.podCIDR` on every `Node` object
at cluster-bootstrap time, and Flannel's bookkeeping depends on that
assignment not changing under it while it's still active. Reusing it for
Cilium (`ipam.mode: kubernetes`, what the clean-cutover version did) only
makes sense when Flannel is already gone and there's no ambiguity about who
allocated what. With both CNIs live, Cilium needs its own, genuinely
non-overlapping range to hand out from, specifically so the routing-table
entries each daemon installs for its own pod CIDR (described above) can never
collide or be ambiguous. This runbook uses `10.245.0.0/16` — adjacent to
Flannel's range, easy to keep straight, guaranteed not to overlap.

This also means: this migration **does not preserve pod IPs**. Every pod that
moves to a node after that node migrates gets a `10.245.x.x` address instead
of `10.244.x.x`. Nothing in this cluster hardcodes pod IPs (Services are
addressed by ClusterIP/DNS name, never by pod IP directly), so this has no
practical effect — it's called out because it's a real, visible difference
from the clean-cutover version, not a side effect to be surprised by later.

### Why the VXLAN UDP port has to be moved

Flannel's vxlan backend and Cilium's vxlan tunnel both default to UDP port
8472. That's fine when only one of them is actually encapsulating traffic on
a given node — but during this migration, *both* daemons are alive
simultaneously on every node, each maintaining its own vxlan device
(`flannel.1` and `cilium_vxlan`). Two UDP listeners can't bind the same port
on the same node. Cilium's chart exposes `tunnelPort` for exactly this
situation — set to `8473` here, simply to not collide with Flannel's
already-claimed `8472`. There's no reason to ever move it back once Flannel
is gone; leaving it on `8473` permanently costs nothing.

### The per-node switch: `cni.exclusive` and `CiliumNodeConfig`

By default, the moment cilium-agent starts on a node, it aggressively writes
its own CNI conflist and expects to be the only CNI kubelet uses there
(`cni.exclusive: true`, the chart default) — that's the "big bang, every node
at once" behaviour this migration is specifically avoiding. Installing with
`cni.exclusive: false` cluster-wide means every cilium-agent comes up
*passively*: present, fully participating in the routing mesh described
above, but not taking over new pod creation anywhere yet. Flannel's conflist
keeps winning on every node, and the cluster behaves exactly as it did before
Cilium was installed.

The `CiliumNodeConfig` CRD lets that default be overridden per node (matched
by label or by name). To migrate a specific node, you apply a
`CiliumNodeConfig` scoped to it that flips `cni-exclusive` to `true` *for that
node only*, then cycle its cilium-agent pod so it picks up the new config.
From that point, new pod sandboxes on that node go through Cilium; everywhere
else is untouched.

### The operator's unmanaged-pod-watcher has to be told to stand down

Cilium's operator has a feature that actively restarts pods it considers
"unmanaged" — running, but without a Cilium identity — on the assumption that
something's stuck and a restart will fix it. During this migration, every pod
on a not-yet-migrated node is, by definition, exactly that: running, fine, and
deliberately not Cilium's responsibility yet. Left on, the operator would
fight the migration by forcibly cycling pods on nodes that haven't been
touched on purpose. `operator.unmanagedPodWatcher.restart: false` turns that
behaviour off for the duration of the migration. There's no reason to turn it
back on afterward either — once every node is migrated, there's nothing left
for it to act on.

### Why kube-proxy staying out of this is now even more load-bearing

The clean-cutover version's reasoning for leaving kube-proxy alone (isolate
blast radius, one change at a time) still applies, but there's a second,
more concrete reason here: kube-proxy's Service routing is keyed entirely off
`Endpoints`/`EndpointSlice` objects listing backend pod IPs — it has no
concept of which CNI or which CIDR a backend IP belongs to. That's what makes
Services keep working *transparently* throughout this migration, across a mix
of `10.244.x.x` and `10.245.x.x` backends, with zero extra configuration —
provided routing to both ranges works on every node, which Section 2's
"both CNIs keep running" point guarantees. Touching kube-proxy at the same
time would remove that free transparency and reintroduce exactly the
complexity this migration is trying to keep contained to one layer at a time.

---

## 3. Key decisions carried over unchanged

These are unrelated to clean-cutover vs. live migration and apply equally
here — see the previous version
([flannel-to-cilium-migration-clean-cutover-backup.md](flannel-to-cilium-migration-clean-cutover-backup.md))
for the full reasoning behind each:

- `devices: enp0s8` — same multi-NIC reasoning as Flannel's `iface-patch.yaml`.
- `routingMode: tunnel` / `tunnelProtocol: vxlan` — same flat-host-only-network
  reasoning; native routing still isn't viable here.
- `bpf.masquerade: true` — same equivalent to Flannel's `--ip-masq`.
- `operator.replicas: 1` — same no-HA-requirement-for-the-operator reasoning.
- `hubble.relay.enabled` / `hubble.ui.enabled` — same observability payoff.
- MetalLB, Sealed Secrets, Flux's own mechanics, and every app under
  `kubernetes/apps/` — all untouched, for the same reasons as before.
- `kubeProxyReplacement: false` — kept false, reasoning strengthened above.

What's different this time, covered in Section 2: `ipam.mode: cluster-pool`
with a fresh CIDR (not `kubernetes`), `tunnelPort: 8473` (not the default),
`cni.exclusive: false` plus per-node `CiliumNodeConfig` overrides (not a
single global value), and `operator.unmanagedPodWatcher.restart: false`.

---

## 4. Pre-flight checks

Same checks as the clean-cutover version's Section 4 (Kubernetes version,
container runtime, kernel version) still apply — run those first. One
addition specific to this approach:

```bash
# Confirm nothing already uses 10.245.0.0/16 - this is about to become
# Cilium's pod CIDR during the migration, and it must be genuinely free.
# Nothing in this cluster should claim it today, but worth confirming rather
# than assuming.
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.podCIDR}{"\n"}{end}'
ip route show | grep 10.245 || echo "10.245.0.0/16 not in use - good"
```

---

## 5. Install Cilium passively, cluster-wide

This is one Git commit: Cilium gets installed everywhere, but configured to
take over nowhere yet. Nothing about Flannel changes in this step — the
cluster's actual behaviour is identical before and after, by design.

### 5.1 Add the Cilium Helm repository

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

### 5.2 Create the Cilium namespace and HelmRelease

Create `kubernetes/infrastructure/controllers/cilium/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cilium
```

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
                           # for the latest stable, and re-read Cilium's own
                           # "Migrating a cluster to Cilium" guide for whatever
                           # version you land on - the CiliumNodeConfig/
                           # cni.exclusive mechanism this runbook relies on is
                           # exactly the kind of API that's worth re-checking
                           # per version (see "A note on how version-sensitive
                           # this runbook is" at the top of this document).
      sourceRef:
        kind: HelmRepository
        name: cilium
        namespace: flux-system
  install:
    createNamespace: true
  upgrade:
    crds: CreateReplace
  values:
    devices: enp0s8

    k8sServiceHost: cakers-cp-1.lab.local
    k8sServicePort: 6443

    routingMode: tunnel
    tunnelProtocol: vxlan

    # Moved off Flannel's default (8472) because both vxlan devices
    # (flannel.1 and cilium_vxlan) are alive on every node simultaneously
    # during this migration, and two UDP listeners can't share a port on the
    # same node. See "Why the VXLAN UDP port has to be moved" above.
    tunnelPort: 8473

    # --- IPAM ---
    # A fresh, non-overlapping CIDR rather than reusing Flannel's
    # 10.244.0.0/16 via ipam.mode: kubernetes. With both CNIs live, each
    # needs an unambiguous range to maintain its own routes/FDB entries for -
    # see "Why this requires a second, non-overlapping pod CIDR" above.
    # /24 per node matches what kubeadm/Flannel already hand out, so node
    # capacity (max pods per node) doesn't change.
    ipam:
      mode: cluster-pool
      operator:
        clusterPoolIPv4PodCIDRList:
          - "10.245.0.0/16"
        clusterPoolIPv4MaskSize: 24

    bpf:
      masquerade: true

    kubeProxyReplacement: false

    # Passive everywhere by default. Individual nodes get switched to
    # exclusive (i.e. actually used for new pod sandboxes) one at a time via
    # a per-node CiliumNodeConfig in Section 6 - see "The per-node switch"
    # above. Until that happens, this is a no-op cluster-wide: Flannel's
    # conflist keeps winning everywhere, and the cluster behaves exactly as
    # it did before this commit.
    cni:
      exclusive: false

    operator:
      replicas: 1
      # Stops cilium-operator from forcibly restarting pods it sees running
      # without a Cilium identity - which, during this migration, is every
      # pod on every not-yet-migrated node, by design. See "The operator's
      # unmanaged-pod-watcher" above.
      unmanagedPodWatcher:
        restart: false

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

### 5.3 Register Cilium with the controllers Kustomization

Edit [kubernetes/infrastructure/controllers/kustomization.yaml](../kubernetes/infrastructure/controllers/kustomization.yaml)
to add Cilium **alongside** Flannel — this is the key structural difference
from the clean-cutover version. Both are listed; nothing is being pruned yet:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cilium/
  - flannel/
  - metallb/
  - sealed-secrets/
```

Commit and push:

```bash
git add kubernetes/infrastructure/repositories/cilium.yaml \
        kubernetes/infrastructure/repositories/kustomization.yaml \
        kubernetes/infrastructure/controllers/cilium/ \
        kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "Install Cilium alongside Flannel, passive on every node"
git push
```

### 5.4 Verify it's actually passive

```bash
# Every node should have a Running cilium-agent now, plus one
# cilium-operator. Flannel's DaemonSet should also still be Running,
# unaffected, on every node.
kubectl get pods -n cilium -o wide
kubectl get pods -n kube-flannel -o wide

# Nothing should have restarted because of this change - same pod ages as
# before this commit, modulo Cilium's own new pods.
kubectl get pods -A -o wide | grep -v Running

# Confirm Flannel's conflist is still the one kubelet would use - Cilium's
# should exist on disk (cilium-agent writes it even when not exclusive) but
# Flannel's still has lexical priority (10-flannel.conflist sorts after
# Cilium's 05-cilium.conflist by name, but cni.exclusive: false means Cilium
# deliberately isn't asserting itself yet regardless of file naming).
ssh cakers-worker-1 ls /etc/cni/net.d/
```

If anything restarted, or any pod's IP changed, stop and investigate before
proceeding — the entire premise of this stage is "Cilium being present
changes nothing yet."

---

## 6. Migrate one node

Repeat this section once per node. Order: workers first, one at a time,
control-plane node last — not because the control plane is technically at
more risk here (its `hostNetwork: true` static pods are unaffected by any of
this, same as the clean-cutover version's Section 3 established), but because
keeping `kubectl` access maximally stable for as much of the process as
possible is a cheap, sensible convention to default to.

### 6.1 Check what's actually running there

```bash
NODE=cakers-worker-1
kubectl get pods -A -o wide --field-selector spec.nodeName=$NODE
```

Worth a glance for anything with only one replica, or a `PodDisruptionBudget`
that might make draining this node briefly painful elsewhere (standard node-
maintenance hygiene, not specific to this migration — but this is exactly the
kind of real-world consideration a clean cutover never forces you to think
about, because everything goes down and comes back up together).

### 6.2 Flip this node to Cilium-exclusive

Create a `CiliumNodeConfig` scoped to this one node:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNodeConfig
metadata:
  name: migrate-cakers-worker-1
  namespace: cilium
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: cakers-worker-1
  defaults:
    cni-exclusive: "true"
```

This is the one object in this runbook applied directly with `kubectl`
rather than through Flux/Git. That's deliberate, not an oversight: each of
these is a transient, per-node, one-shot control used only for the duration
of this migration and removed again in Section 7 once nothing needs it —
exactly the kind of short-lived operational state that doesn't belong
checked into Git as a steady-state desired configuration. Everything that
*is* steady-state (the HelmRelease, the eventual removal of Flannel) goes
through Git, same as always.

```bash
kubectl apply -f migrate-cakers-worker-1.yaml

# Cycle this node's cilium-agent so it picks up the new per-node config -
# it doesn't watch CiliumNodeConfig changes live for its own CNI mode.
kubectl delete pod -n cilium -l k8s-app=cilium --field-selector spec.nodeName=$NODE
kubectl get pods -n cilium -o wide --field-selector spec.nodeName=$NODE   # wait for Running
```

Confirm it actually flipped:

```bash
ssh $NODE cat /etc/cni/net.d/05-cilium.conflist   # should now exist and be
                                                    # what kubelet will use
```

### 6.3 Cycle the node's workloads onto Cilium

```bash
kubectl cordon $NODE
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
```

Draining moves this node's existing pods to other (still-Flannel) nodes,
where they come up exactly as before — this step is about safely emptying
the node before its CNI changes underneath anything, not about testing
Cilium yet.

```bash
kubectl uncordon $NODE
```

To actually see a pod land on Cilium here, either wait for normal scheduling
pressure to put something on this node, or force it directly for validation:

```bash
kubectl run cilium-test-$NODE --image=busybox --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"$NODE\"}}" -- sleep 3600
kubectl get pod cilium-test-$NODE -o wide   # should show a 10.245.x.x IP
```

### 6.4 Validate cross-CNI connectivity, in both directions

This is the actual point of this whole exercise — confirming Section 2's
explanation holds up in practice, not just in theory:

```bash
# Find a pod still on a Flannel node (10.244.x.x) to test against.
kubectl get pods -A -o wide | grep 10.244 | head -1

# From the new Cilium pod (10.245.x.x), reach a Flannel pod (10.244.x.x):
kubectl exec cilium-test-$NODE -- ping -c3 <flannel-pod-ip>

# And the reverse direction - from an existing Flannel pod, reach the new
# Cilium pod:
kubectl exec <some-flannel-pod> -- ping -c3 <cilium-test-pod-ip>

# And confirm Service routing is still transparent across the CIDR split -
# pick any ClusterIP Service and hit it from the new Cilium pod.
kubectl exec cilium-test-$NODE -- wget -qO- http://kubernetes.default.svc.cluster.local:443 --no-check-certificate
```

If either `ping` fails, stop here — don't migrate the next node with a known
cross-CNI connectivity gap unresolved. Re-check `tunnelPort`, `devices`, and
that `cni.exclusive` actually flipped on the right node before continuing.

Clean up the test pod, then repeat Section 6 for the next node.

```bash
kubectl delete pod cilium-test-$NODE
```

---

## 7. Finalise: every node migrated

Once all four nodes have been through Section 6:

### 7.1 Remove the per-node migration overrides

```bash
kubectl delete ciliumnodeconfig -n cilium --all
```

These were always meant to be transient — with every node already flipped to
exclusive individually, there's nothing left for them to override.

### 7.2 Make exclusivity the cluster-wide default

Edit the HelmRelease from Section 5.2: change `cni.exclusive` from `false` to
`true`. This doesn't change behaviour on any of the four existing nodes
(they're already individually exclusive from Section 6.2) — it changes what
happens if a *fifth* node ever joins this cluster, so it correctly defaults
to Cilium-exclusive immediately instead of needing the same manual dance
again.

```bash
git add kubernetes/infrastructure/controllers/cilium/helmrelease.yaml
git commit -m "Make Cilium CNI-exclusive cluster-wide now that migration is complete"
git push
```

### 7.3 Remove Flannel

Edit [kubernetes/infrastructure/controllers/kustomization.yaml](../kubernetes/infrastructure/controllers/kustomization.yaml)
to drop the `flannel/` entry — the same `prune: true` mechanism from the
clean-cutover version's Section 5.1 applies here unchanged:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cilium/
  - metallb/
  - sealed-secrets/
```

```bash
git add kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "Remove Flannel - migration to Cilium complete"
git push
```

This is safe specifically because, by this point, zero pods anywhere in the
cluster still have a `10.244.x.x` address — every pod was either cycled
through a drain in Section 6 or freshly scheduled since, so all of them are
already on Cilium's `10.245.0.0/16`. Flannel has nothing left to do.

### 7.4 Clean up host-level Flannel artifacts

Unlike the clean-cutover version, **no reboot is required** here — nothing
live depends on Flannel's dataplane by this point, so this is pure
filesystem hygiene rather than a correctness requirement:

```bash
for NODE in cakers-worker-1 cakers-worker-2 cakers-worker-3 cakers-cp-1; do
  ssh $NODE "sudo rm -f /etc/cni/net.d/10-flannel.conflist /opt/cni/bin/flannel && sudo rm -rf /var/lib/cni/flannel*"
done
```

### 7.5 Re-confirm operator unmanaged-pod-watcher restart isn't needed long-term

Leaving `operator.unmanagedPodWatcher.restart: false` permanently is harmless
(there's nothing left for it to act on once every pod is Cilium-managed), so
there's no need to flip it back — same "don't bother undoing a working,
harmless change" logic as `tunnelPort` above.

---

## 8. Validation

Same checks as the clean-cutover version's Section 7 apply unchanged:
`cilium status --wait`, optional `cilium connectivity test`, confirming the
`flux-system` `NetworkPolicy` objects are now enforced, confirming MetalLB's
`LoadBalancer` Services (e.g. Harbor) still resolve, confirming external
egress works through `bpf.masquerade`. Add one specific to this approach:

```bash
# Every pod in the cluster should now be on 10.245.0.0/16 - none should
# remain on Flannel's old 10.244.0.0/16 range.
kubectl get pods -A -o wide | awk '{print $7}' | grep -c '^10\.244\.' # should print 0
```

---

## 9. Update the README

Same as the clean-cutover version's Section 8 — check off
`[X] Replace Flannel with Cilium`, swap `Flannel` for `Cilium` under
`Deployed so Far`, and delete the dead `flannel/` manifests directory in its
own follow-up commit once you're confident you won't need to revert.

---

## 10. Rollback plan

Rollback is more nuanced here than in the clean-cutover version, because the
right approach depends on how far the migration got:

**Mid-migration (some nodes flipped, some not):** drain the affected node,
delete its `CiliumNodeConfig` override (or re-create one explicitly forcing
`cni-exclusive: "false"` for it), cycle its cilium-agent pod, uncordon. It
reverts to using Flannel for new pods, same as any not-yet-migrated node. Both
CNIs are still installed and both still work cluster-wide throughout, by
design — that's the whole point of doing this node by node instead of all at
once.

**After Section 7 (Flannel removed):** this is now structurally the same
position the clean-cutover version's Section 9 describes, with one
difference: pods are on `10.245.0.0/16`, not the original `10.244.0.0/16`.
`git revert` the commits from Section 7 (restores Flannel to
`infra-controllers`) and Section 5 (removes Cilium), in that order, then
clean up Cilium's host-level artifacts (`/etc/cni/net.d/05-cilium.conflist`,
`/opt/cni/bin/cilium*`) and reboot each node — once Cilium is fully gone,
falling back to a clean reboot to guarantee no stale state is the same
pragmatic choice the clean-cutover version made for the forward direction.

---

## 11. Phase 2 (separate, future change): kube-proxy replacement

Unchanged from the clean-cutover version's Section 10 — still deliberately
out of scope here, for the same reasoning (isolate blast radius, one change
at a time), now reinforced by Section 2's point about kube-proxy being what
makes Service routing transparent across the two pod CIDRs during this
exact migration. `k8sServiceHost`/`k8sServicePort` are already set, so it
remains a single flag flip whenever you're ready, with its own
Service-by-Service verification pass.
